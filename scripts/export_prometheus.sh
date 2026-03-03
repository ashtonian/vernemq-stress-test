#!/usr/bin/env bash
# export_prometheus.sh - Full Prometheus data export
#
# Exports TSDB snapshot and range queries for key VerneMQ metrics from
# Prometheus.  Converts JSON results to CSV via prom_to_csv.py.
#
# Usage:
#   ./export_prometheus.sh --prometheus-url http://monitor:9090 \
#       --results-dir ./results/run1 --start-epoch 1700000000 --end-epoch 1700003600

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

PROMETHEUS_URL="${PROMETHEUS_URL:-http://monitor:9090}"
RESULTS_DIR="${RESULTS_DIR:-./results}"
START_EPOCH=""
END_EPOCH=""
MONITOR_HOST="${MONITOR_HOST:-monitor}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-}"
STEP=15

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Options:
  --prometheus-url URL   Prometheus base URL (default: http://monitor:9090)
  --results-dir DIR      Results output directory (required)
  --start-epoch N        Start timestamp (unix epoch, default: now - 1 hour)
  --end-epoch N          End timestamp (unix epoch, default: now)
  --monitor-host HOST    Hostname/IP of the Prometheus server for SCP (default: monitor)
  --ssh-user USER        SSH user for SCP (default: ubuntu)
  --ssh-key PATH         SSH private key path (optional)
  -h, --help             Show this help
USAGE
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prometheus-url) PROMETHEUS_URL="$2"; shift 2 ;;
        --results-dir)    RESULTS_DIR="$2"; shift 2 ;;
        --start-epoch)    START_EPOCH="$2"; shift 2 ;;
        --end-epoch)      END_EPOCH="$2"; shift 2 ;;
        --monitor-host)   MONITOR_HOST="$2"; shift 2 ;;
        --ssh-user)       SSH_USER="$2"; shift 2 ;;
        --ssh-key)        SSH_KEY="$2"; shift 2 ;;
        -h|--help)        usage ;;
        *)                echo "Unknown option: $1"; usage ;;
    esac
done

# Default time range: last hour
NOW_EPOCH=$(date +%s)
START_EPOCH="${START_EPOCH:-$(( NOW_EPOCH - 3600 ))}"
END_EPOCH="${END_EPOCH:-$NOW_EPOCH}"

EXPORT_DIR="${RESULTS_DIR}/prometheus_export"
JSON_DIR="${EXPORT_DIR}/json"
CSV_DIR="${EXPORT_DIR}/csv"
mkdir -p "$JSON_DIR" "$CSV_DIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

ts() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
    echo "[$(ts)] $*"
}

ssh_opts() {
    local opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
    if [[ -n "$SSH_KEY" ]]; then
        opts="$opts -i $SSH_KEY"
    fi
    echo "$opts"
}

# ---------------------------------------------------------------------------
# Step 1: TSDB Snapshot
# ---------------------------------------------------------------------------

tsdb_snapshot() {
    log "Step 1: Creating Prometheus TSDB snapshot"

    local snap_response
    snap_response=$(curl -sf --max-time 60 -X POST \
        "${PROMETHEUS_URL}/api/v1/admin/tsdb/snapshot" 2>/dev/null) || {
        log "WARNING: TSDB snapshot request failed (Prometheus admin API may be disabled)"
        return 0
    }

    local snap_name
    snap_name=$(echo "$snap_response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('data', {}).get('name', ''))" 2>/dev/null) || true

    if [[ -z "$snap_name" ]]; then
        log "WARNING: Could not parse snapshot name from response"
        return 0
    fi

    log "Snapshot created: $snap_name"
    log "Copying snapshot from ${MONITOR_HOST}..."

    local snap_dir="${EXPORT_DIR}/tsdb_snapshot"
    mkdir -p "$snap_dir"

    # SCP the snapshot tarball from the monitor host
    local prom_data_dir="/var/lib/prometheus/snapshots"
    # shellcheck disable=SC2086
    if scp -r $(ssh_opts) \
        "${SSH_USER}@${MONITOR_HOST}:${prom_data_dir}/${snap_name}" \
        "$snap_dir/" 2>/dev/null; then
        log "Snapshot copied to ${snap_dir}/${snap_name}"

        # Create tarball for portability
        tar -czf "${snap_dir}/tsdb_snapshot_${snap_name}.tar.gz" \
            -C "$snap_dir" "$snap_name" 2>/dev/null && \
            log "Snapshot archived: tsdb_snapshot_${snap_name}.tar.gz"
    else
        log "WARNING: Failed to SCP snapshot from ${MONITOR_HOST}"
    fi
}

# ---------------------------------------------------------------------------
# Step 2: Range queries for key metrics
# ---------------------------------------------------------------------------

# Map of output_name -> PromQL query
declare -A METRICS=(
    # MQTT throughput
    ["mqtt_publish_received_rate"]='rate(mqtt_publish_received_total[1m])'
    ["mqtt_publish_sent_rate"]='rate(mqtt_publish_sent_total[1m])'
    ["mqtt_connack_sent"]='mqtt_connack_sent_total'
    ["mqtt_puback_sent_rate"]='rate(mqtt_puback_sent_total[1m])'
    ["mqtt_subscribe_received_rate"]='rate(mqtt_subscribe_received_total[1m])'
    ["mqtt_socket_open"]='mqtt_socket_open'
    ["mqtt_socket_close"]='mqtt_socket_close'

    # System resources
    ["process_memory_bytes"]='process_resident_memory_bytes'
    ["process_cpu_rate"]='rate(process_cpu_seconds_total[1m])'
    ["node_memory_available"]='node_memory_MemAvailable_bytes'

    # Cluster
    ["cluster_bytes_sent"]='vmq_cluster_bytes_sent_total'
    ["cluster_bytes_received"]='vmq_cluster_bytes_received_total'
    ["cluster_readiness"]='vmq_cluster_readiness'
    ["cluster_netsplit"]='vmq_cluster_netsplit_detected_total'

    # Balance
    ["balance_is_accepting"]='vmq_balance_is_accepting'
    ["balance_rejections"]='vmq_balance_rejections_total'

    # Latency percentiles
    ["latency_p50"]='histogram_quantile(0.50, rate(mqtt_publish_latency_seconds_bucket[1m]))'
    ["latency_p95"]='histogram_quantile(0.95, rate(mqtt_publish_latency_seconds_bucket[1m]))'
    ["latency_p99"]='histogram_quantile(0.99, rate(mqtt_publish_latency_seconds_bucket[1m]))'

    # Queue
    ["queue_message_drop"]='vmq_queue_message_drop_total'
    ["queue_message_in"]='vmq_queue_message_in_total'
)

query_range_metrics() {
    log "Step 2: Running range queries (${START_EPOCH} to ${END_EPOCH}, step=${STEP}s)"
    log "Querying ${#METRICS[@]} metrics"

    local success=0
    local failed=0

    for name in $(echo "${!METRICS[@]}" | tr ' ' '\n' | sort); do
        local query="${METRICS[$name]}"
        local out_file="${JSON_DIR}/${name}.json"

        log "  Querying: ${name}"
        if curl -sf --max-time 60 \
            "${PROMETHEUS_URL}/api/v1/query_range" \
            --data-urlencode "query=${query}" \
            --data-urlencode "start=${START_EPOCH}" \
            --data-urlencode "end=${END_EPOCH}" \
            --data-urlencode "step=${STEP}s" \
            -o "$out_file" 2>/dev/null; then
            success=$((success + 1))
        else
            log "  WARNING: Failed to query ${name}"
            echo '{"status":"error","data":{"resultType":"","result":[]}}' > "$out_file"
            failed=$((failed + 1))
        fi
    done

    log "Range queries complete: ${success} succeeded, ${failed} failed"
}

# ---------------------------------------------------------------------------
# Step 3: Per-scenario windows from metadata.csv
# ---------------------------------------------------------------------------

query_scenario_windows() {
    local metadata_csv="${RESULTS_DIR}/metadata.csv"
    if [[ ! -f "$metadata_csv" ]]; then
        log "Step 3: No metadata.csv found, skipping per-scenario exports"
        return 0
    fi

    log "Step 3: Exporting per-scenario time windows from metadata.csv"

    # metadata.csv format: scenario_name,start_epoch,end_epoch,...
    while IFS=',' read -r scenario_name scenario_start scenario_end _rest; do
        # Skip header or empty lines
        [[ "$scenario_name" == "scenario"* ]] && continue
        [[ -z "$scenario_name" || -z "$scenario_start" || -z "$scenario_end" ]] && continue

        log "  Scenario: ${scenario_name} (${scenario_start} to ${scenario_end})"

        local scenario_json_dir="${JSON_DIR}/scenario_${scenario_name}"
        local scenario_csv_dir="${CSV_DIR}/scenario_${scenario_name}"
        mkdir -p "$scenario_json_dir" "$scenario_csv_dir"

        for name in $(echo "${!METRICS[@]}" | tr ' ' '\n' | sort); do
            local query="${METRICS[$name]}"
            local out_file="${scenario_json_dir}/${name}.json"

            curl -sf --max-time 60 \
                "${PROMETHEUS_URL}/api/v1/query_range" \
                --data-urlencode "query=${query}" \
                --data-urlencode "start=${scenario_start}" \
                --data-urlencode "end=${scenario_end}" \
                --data-urlencode "step=${STEP}s" \
                -o "$out_file" 2>/dev/null || {
                echo '{"status":"error","data":{"resultType":"","result":[]}}' > "$out_file"
            }
        done

        # Convert scenario JSON to CSV
        if [[ -x "${SCRIPT_DIR}/prom_to_csv.py" ]]; then
            python3 "${SCRIPT_DIR}/prom_to_csv.py" \
                --input-dir "$scenario_json_dir" \
                --output-dir "$scenario_csv_dir" 2>/dev/null || \
                log "  WARNING: CSV conversion failed for scenario ${scenario_name}"
        fi
    done < "$metadata_csv"
}

# ---------------------------------------------------------------------------
# Step 4: Convert JSON to CSV
# ---------------------------------------------------------------------------

convert_to_csv() {
    log "Step 4: Converting JSON results to CSV"

    if [[ ! -x "${SCRIPT_DIR}/prom_to_csv.py" ]]; then
        log "WARNING: prom_to_csv.py not found or not executable, skipping CSV conversion"
        return 0
    fi

    python3 "${SCRIPT_DIR}/prom_to_csv.py" \
        --input-dir "$JSON_DIR" \
        --output-dir "$CSV_DIR" || {
        log "WARNING: CSV conversion had errors"
    }

    log "CSV files written to $CSV_DIR"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    log "========================================="
    log "Prometheus Export"
    log "========================================="
    log "Prometheus URL: $PROMETHEUS_URL"
    log "Results dir:    $RESULTS_DIR"
    log "Time range:     $START_EPOCH to $END_EPOCH"
    log "Export dir:     $EXPORT_DIR"
    log "========================================="

    tsdb_snapshot
    query_range_metrics
    query_scenario_windows
    convert_to_csv

    # Write export metadata
    {
        echo "{\"timestamp\": \"$(ts)\","
        echo " \"prometheus_url\": \"$PROMETHEUS_URL\","
        echo " \"start_epoch\": $START_EPOCH,"
        echo " \"end_epoch\": $END_EPOCH,"
        echo " \"step\": $STEP,"
        echo " \"metrics_count\": ${#METRICS[@]}}"
    } > "${EXPORT_DIR}/export_metadata.json"

    log "========================================="
    log "Prometheus export complete"
    log "========================================="
    log "JSON files: $(find "$JSON_DIR" -name '*.json' -maxdepth 1 | wc -l | tr -d ' ')"
    log "CSV files:  $(find "$CSV_DIR" -name '*.csv' -maxdepth 1 | wc -l | tr -d ' ')"
    log "Output:     $EXPORT_DIR"
}

main "$@"
