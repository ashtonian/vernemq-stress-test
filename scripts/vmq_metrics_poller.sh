#!/usr/bin/env bash
# vmq_metrics_poller.sh - Background poller for vmq-admin metrics
#
# Polls `vmq-admin metrics show` on all cluster nodes via SSH at a
# configurable interval and writes flat CSV output suitable for analysis.
#
# Usage:
#   ./vmq_metrics_poller.sh --nodes "10.0.0.1 10.0.0.2" --output /tmp/metrics.csv
#   METRICS_POLL_INTERVAL=5 ./vmq_metrics_poller.sh --nodes "10.0.0.1"

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

NODES=""
INTERVAL="${METRICS_POLL_INTERVAL:-10}"
OUTPUT=""
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o ConnectTimeout=5}"
SSH_USER="${SSH_USER:-ec2-user}"
VMQ_ADMIN="${VMQ_ADMIN:-sudo vmq-admin}"

# Focused metric set to collect
METRIC_FILTER=(
    mqtt_connack_sent
    mqtt_publish_received
    mqtt_publish_sent
    mqtt_puback_sent
    process_resident_memory_bytes
    process_cpu_seconds_total
    vmq_cluster_bytes_received
    vmq_cluster_bytes_sent
    vmq_queue_message_drop
    vmq_queue_message_in
    vmq_balance_is_accepting
    vmq_balance_rejections
    mqtt_socket_open
    mqtt_socket_close
)

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Options:
  --nodes "IPS"         Space-separated list of node IPs (required)
  --interval N          Poll interval in seconds (default: 10, env METRICS_POLL_INTERVAL)
  --output PATH         Output CSV file path (required)
  --ssh-opts "OPTS"     SSH options (default: "-o StrictHostKeyChecking=no -o ConnectTimeout=5")
  --ssh-user USER       SSH user (default: ec2-user)
  --vmq-admin CMD       vmq-admin command (default: "sudo vmq-admin")
  -h, --help            Show this help

Output CSV format:
  timestamp,node_index,metric_name,value
USAGE
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes)     NODES="$2"; shift 2 ;;
        --interval)  INTERVAL="$2"; shift 2 ;;
        --output)    OUTPUT="$2"; shift 2 ;;
        --ssh-opts)  SSH_OPTS="$2"; shift 2 ;;
        --ssh-user)  SSH_USER="$2"; shift 2 ;;
        --vmq-admin) VMQ_ADMIN="$2"; shift 2 ;;
        -h|--help)   usage ;;
        *)           echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$NODES" ]]; then
    echo "ERROR: --nodes is required"
    usage
fi

if [[ -z "$OUTPUT" ]]; then
    echo "ERROR: --output is required"
    usage
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

ts() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
    echo "[$(ts)] $*" >&2
}

# Build grep pattern from metric filter
build_filter_pattern() {
    local pattern=""
    for m in "${METRIC_FILTER[@]}"; do
        pattern="${pattern:+${pattern}|}${m}"
    done
    echo "$pattern"
}

RUNNING=true

cleanup() {
    RUNNING=false
    log "Shutting down metrics poller (PID $$)"
}

trap cleanup SIGTERM SIGINT

# ---------------------------------------------------------------------------
# Main polling loop
# ---------------------------------------------------------------------------

main() {
    log "Starting metrics poller (interval=${INTERVAL}s, nodes=${NODES})"
    log "Output: $OUTPUT"

    # Write CSV header
    echo "timestamp,node_index,metric_name,value" > "$OUTPUT"

    local filter_pattern
    filter_pattern=$(build_filter_pattern)

    # Convert nodes string to array
    read -ra node_array <<< "$NODES"

    while $RUNNING; do
        local poll_ts
        poll_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

        local node_idx=0
        for node_ip in "${node_array[@]}"; do
            if ! $RUNNING; then break; fi

            # Poll vmq-admin metrics via SSH
            local raw_output
            # shellcheck disable=SC2086
            raw_output=$(ssh $SSH_OPTS "${SSH_USER}@${node_ip}" \
                "${VMQ_ADMIN} metrics show" 2>/dev/null) || {
                log "WARNING: Failed to poll node $node_ip (index=$node_idx)"
                node_idx=$((node_idx + 1))
                continue
            }

            # Parse vmq-admin output: each line is "metric_name = value"
            # Filter to our focused metric set and emit CSV rows
            echo "$raw_output" | grep -E "^(${filter_pattern})" | while IFS= read -r line; do
                local metric_name metric_value
                metric_name=$(echo "$line" | sed 's/ *=.*$//')
                metric_value=$(echo "$line" | sed 's/^.*= *//')
                echo "${poll_ts},${node_idx},${metric_name},${metric_value}"
            done >> "$OUTPUT"

            node_idx=$((node_idx + 1))
        done

        # Sleep in small increments so we can respond to signals promptly
        local slept=0
        while $RUNNING && (( slept < INTERVAL )); do
            sleep 1
            slept=$((slept + 1))
        done
    done

    log "Metrics poller stopped. Wrote $(wc -l < "$OUTPUT") lines to $OUTPUT"
}

main "$@"
