#!/usr/bin/env bash
# vmq_metrics_poller_docker.sh - Background poller for vmq-admin metrics via Docker
#
# Same structure as vmq_metrics_poller.sh but uses docker exec instead of SSH.
#
# Usage:
#   ./vmq_metrics_poller_docker.sh --containers "vmq1 vmq2 vmq3" --output /tmp/metrics.csv

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

CONTAINERS=""
INTERVAL="${METRICS_POLL_INTERVAL:-10}"
OUTPUT=""
VMQ_ADMIN="${VMQ_ADMIN:-/opt/vernemq/bin/vmq-admin}"

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
  --containers "NAMES"  Space-separated list of Docker container names (required)
  --interval N          Poll interval in seconds (default: 10, env METRICS_POLL_INTERVAL)
  --output PATH         Output CSV file path (required)
  --vmq-admin CMD       vmq-admin command inside container (default: /opt/vernemq/bin/vmq-admin)
  -h, --help            Show this help

Output CSV format:
  timestamp,node_index,metric_name,value
USAGE
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --containers) CONTAINERS="$2"; shift 2 ;;
        --interval)   INTERVAL="$2"; shift 2 ;;
        --output)     OUTPUT="$2"; shift 2 ;;
        --vmq-admin)  VMQ_ADMIN="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *)            echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$CONTAINERS" ]]; then
    echo "ERROR: --containers is required"
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
    log "Shutting down docker metrics poller (PID $$)"
}

trap cleanup SIGTERM SIGINT

# ---------------------------------------------------------------------------
# Main polling loop
# ---------------------------------------------------------------------------

main() {
    log "Starting docker metrics poller (interval=${INTERVAL}s, containers=${CONTAINERS})"
    log "Output: $OUTPUT"

    # Write CSV header
    echo "timestamp,node_index,metric_name,value" > "$OUTPUT"

    local filter_pattern
    filter_pattern=$(build_filter_pattern)

    # Convert containers string to array
    read -ra container_array <<< "$CONTAINERS"

    while $RUNNING; do
        local poll_ts
        poll_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

        local node_idx=0
        for container in "${container_array[@]}"; do
            if ! $RUNNING; then break; fi

            # Poll vmq-admin metrics via docker exec
            local raw_output
            raw_output=$(docker exec "$container" \
                "${VMQ_ADMIN}" metrics show 2>/dev/null) || {
                log "WARNING: Failed to poll container $container (index=$node_idx)"
                node_idx=$((node_idx + 1))
                continue
            }

            # Parse vmq-admin output and emit CSV rows
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

    log "Docker metrics poller stopped. Wrote $(wc -l < "$OUTPUT") lines to $OUTPUT"
}

main "$@"
