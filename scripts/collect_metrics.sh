#!/usr/bin/env bash
# collect_metrics.sh - Scrape Prometheus metrics and save as JSON
#
# Collects key VerneMQ and system metrics from Prometheus for consumption
# by report.py.
#
# Usage:
#   ./collect_metrics.sh --prometheus-url http://monitor:9090 --results-dir ./results/run1 --tag final

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

PROMETHEUS_URL="${PROMETHEUS_URL:-http://monitor:9090}"
RESULTS_DIR="${RESULTS_DIR:-./results}"
TAG="${TAG:-snapshot}"
START_EPOCH=""
END_EPOCH=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prometheus-url) PROMETHEUS_URL="$2"; shift 2 ;;
        --results-dir)    RESULTS_DIR="$2"; shift 2 ;;
        --tag)            TAG="$2"; shift 2 ;;
        --start-epoch)    START_EPOCH="$2"; shift 2 ;;
        --end-epoch)      END_EPOCH="$2"; shift 2 ;;
        *)                echo "Unknown option: $1"; exit 1 ;;
    esac
done

OUT_DIR="${RESULTS_DIR}/metrics_${TAG}"
mkdir -p "$OUT_DIR"

ts() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
    echo "[$(ts)] $*"
}

# ---------------------------------------------------------------------------
# Prometheus query helper
# ---------------------------------------------------------------------------

prom_query() {
    local query="$1" output="$2"
    log "Querying: $query"
    curl -sf --max-time 30 \
        "${PROMETHEUS_URL}/api/v1/query?query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")" \
        -o "$output" 2>/dev/null || {
        log "WARNING: Failed to query: $query"
        echo '{"status":"error","data":{"resultType":"","result":[]}}' > "$output"
    }
}

prom_query_range() {
    local query="$1" output="$2" start="$3" end="$4" step="${5:-15}"
    log "Range query: $query (${start} to ${end}, step=${step}s)"
    curl -sf --max-time 60 \
        "${PROMETHEUS_URL}/api/v1/query_range" \
        --data-urlencode "query=$query" \
        --data-urlencode "start=$start" \
        --data-urlencode "end=$end" \
        --data-urlencode "step=${step}s" \
        -o "$output" 2>/dev/null || {
        log "WARNING: Failed range query: $query"
        echo '{"status":"error","data":{"resultType":"","result":[]}}' > "$output"
    }
}

# ---------------------------------------------------------------------------
# Collect metrics
# ---------------------------------------------------------------------------

main() {
    log "Collecting metrics from $PROMETHEUS_URL"
    log "Output directory: $OUT_DIR"

    local now
    now=$(date +%s)
    local start_ts="${START_EPOCH:-$(( now - 3600 ))}"
    local end_ts="${END_EPOCH:-$now}"

    # Instant queries - current state
    prom_query 'up{job="vernemq"}' "$OUT_DIR/up.json"
    prom_query 'mqtt_publish_received_total' "$OUT_DIR/publish_received.json"
    prom_query 'mqtt_publish_sent_total' "$OUT_DIR/publish_sent.json"
    prom_query 'mqtt_connack_sent_total' "$OUT_DIR/connack_sent.json"
    prom_query 'mqtt_puback_sent_total' "$OUT_DIR/puback_sent.json"
    prom_query 'mqtt_subscribe_received_total' "$OUT_DIR/subscribe_received.json"

    # Latency percentiles
    prom_query 'histogram_quantile(0.50, rate(mqtt_publish_latency_seconds_bucket[5m]))' \
        "$OUT_DIR/latency_p50.json"
    prom_query 'histogram_quantile(0.95, rate(mqtt_publish_latency_seconds_bucket[5m]))' \
        "$OUT_DIR/latency_p95.json"
    prom_query 'histogram_quantile(0.99, rate(mqtt_publish_latency_seconds_bucket[5m]))' \
        "$OUT_DIR/latency_p99.json"

    # Connection counts
    prom_query 'mqtt_socket_open - mqtt_socket_close' "$OUT_DIR/active_connections.json"

    # System resources
    prom_query 'process_resident_memory_bytes{job="vernemq"}' "$OUT_DIR/memory_bytes.json"
    prom_query 'rate(process_cpu_seconds_total{job="vernemq"}[5m])' "$OUT_DIR/cpu_rate.json"
    prom_query 'node_memory_MemAvailable_bytes' "$OUT_DIR/system_memory.json"

    # VerneMQ-specific counters
    prom_query 'vmq_cluster_bytes_received_total' "$OUT_DIR/cluster_bytes_recv.json"
    prom_query 'vmq_cluster_bytes_sent_total' "$OUT_DIR/cluster_bytes_sent.json"
    prom_query 'vmq_queue_message_drop_total' "$OUT_DIR/queue_msg_drop.json"
    prom_query 'vmq_queue_message_in_total' "$OUT_DIR/queue_msg_in.json"

    # Balance metrics
    prom_query 'vmq_balance_is_accepting' "$OUT_DIR/balance_accepting.json"
    prom_query 'vmq_balance_rejections_total' "$OUT_DIR/balance_rejections.json"

    # Cluster health
    prom_query 'vmq_cluster_readiness' "$OUT_DIR/cluster_readiness.json"
    prom_query 'vmq_cluster_netsplit_detected_total' "$OUT_DIR/netsplit_count.json"

    # Range queries - time series for charts
    log "Collecting time-series data (${start_ts} to ${end_ts})"

    prom_query_range 'rate(mqtt_publish_received_total[1m])' \
        "$OUT_DIR/ts_publish_rate.json" "$start_ts" "$end_ts" 15

    prom_query_range 'histogram_quantile(0.99, rate(mqtt_publish_latency_seconds_bucket[1m]))' \
        "$OUT_DIR/ts_latency_p99.json" "$start_ts" "$end_ts" 15

    prom_query_range 'mqtt_socket_open - mqtt_socket_close' \
        "$OUT_DIR/ts_connections.json" "$start_ts" "$end_ts" 15

    prom_query_range 'rate(process_cpu_seconds_total{job="vernemq"}[1m])' \
        "$OUT_DIR/ts_cpu.json" "$start_ts" "$end_ts" 15

    prom_query_range 'process_resident_memory_bytes{job="vernemq"}' \
        "$OUT_DIR/ts_memory.json" "$start_ts" "$end_ts" 15

    # Write metadata
    {
        echo "{\"timestamp\": \"$(ts)\","
        echo " \"prometheus_url\": \"$PROMETHEUS_URL\","
        echo " \"tag\": \"$TAG\","
        echo " \"range_start\": $start_ts,"
        echo " \"range_end\": $end_ts}"
    } > "$OUT_DIR/metadata.json"

    log "Metrics collection complete. Files in $OUT_DIR"
    ls -la "$OUT_DIR" | tail -n +2
}

main "$@"
