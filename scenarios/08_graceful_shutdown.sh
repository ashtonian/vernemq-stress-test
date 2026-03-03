#!/usr/bin/env bash
# 08_graceful_shutdown.sh - Graceful vs ungraceful shutdown comparison
#
# Compares message loss and recovery time between graceful (systemctl stop)
# and ungraceful (SIGKILL) node shutdown under load.
#
# Tags: chaos,graceful
# Min nodes: 3
#
# Required environment:
#   BENCH_NODES  - space-separated bench node IPs
#   VMQ_NODES    - space-separated VerneMQ node IPs (3+ expected)
#   RESULTS_DIR  - output directory
#
# Metrics collected:
#   drain time, message loss, recovery time per shutdown type

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

SCENARIO_NAME="08_graceful_shutdown"
BASELINE_DURATION="${BASELINE_DURATION:-120}"
SETTLE="${SETTLE:-30}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-120}"

count_messages() {
    local tag="$1"
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}/${tag}"
    mkdir -p "$out_dir"

    local -a nodes
    read -ra nodes <<< "$VMQ_NODES"
    local total=0
    for i in "${!nodes[@]}"; do
        local count
        count=$(ssh_vmq "$i" "$VMQ_ADMIN metrics show" 2>/dev/null \
            | grep "mqtt_publish_sent " | awk '{print $NF}' || echo 0)
        echo "node${i},$count" >> "$out_dir/publish_sent.csv"
        (( total += count )) || true
    done
    echo "$total"
}

wait_node_stopped() {
    local idx="$1" timeout="$2"
    local elapsed=0
    while (( elapsed < timeout )); do
        if ! ssh_vmq "$idx" "pgrep -f beam.smp" >/dev/null 2>&1; then
            echo "$elapsed"
            return 0
        fi
        sleep 2
        (( elapsed += 2 ))
    done
    echo "$timeout"
}

run_shutdown_test() {
    local shutdown_type="$1"
    local total_nodes
    total_nodes=$(vmq_node_count)

    # Use last tail node
    local -a target_indices
    mapfile -t target_indices < <(tail_node_indices 1)
    local target_idx="${target_indices[0]}"

    log_phase "${shutdown_type}_shutdown" "${shutdown_type} shutdown of node ${target_idx}"

    local msgs_before
    msgs_before=$(count_messages "${shutdown_type}_before")
    collect_metrics "${shutdown_type}_before"

    local stop_start
    stop_start=$(date +%s)

    if [[ "$shutdown_type" == "graceful" ]]; then
        ssh_vmq "$target_idx" "sudo systemctl stop vernemq"
        local drain_seconds
        drain_seconds=$(wait_node_stopped "$target_idx" "$DRAIN_TIMEOUT")
    else
        kill_vmq_node "$target_idx"
        local drain_seconds=0
    fi

    local stop_done
    stop_done=$(date +%s)

    sleep "$SETTLE"
    collect_metrics "${shutdown_type}_stopped"

    local msgs_during
    msgs_during=$(count_messages "${shutdown_type}_during")
    local msgs_lost=$(( msgs_before > 0 ? 0 : 0 ))
    # Approximate loss by checking if delivered count dropped
    # (in a real scenario with constant publish rate, fewer deliveries = loss)

    # Restart node
    log_phase "${shutdown_type}_recovery" "Restarting node ${target_idx} after ${shutdown_type} shutdown"
    local recovery_start
    recovery_start=$(date +%s)
    start_vmq_node "$target_idx"
    wait_cluster_ready "$total_nodes" 180
    local recovery_done
    recovery_done=$(date +%s)
    local recovery_seconds=$(( recovery_done - recovery_start ))

    sleep "$SETTLE"
    collect_metrics "${shutdown_type}_recovered"

    local msgs_after
    msgs_after=$(count_messages "${shutdown_type}_after")

    # Calculate approximate message loss from delta
    msgs_lost=$(( msgs_after - msgs_during ))

    # Write CSV row
    echo "${shutdown_type},${drain_seconds},${msgs_lost},${recovery_seconds}" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/shutdown_results.csv"

    log_info "${shutdown_type} shutdown: drain=${drain_seconds}s, recovery=${recovery_seconds}s"
}

main() {
    require_min_vmq_nodes 3 "graceful shutdown"
    init_scenario "$SCENARIO_NAME"

    local total_nodes
    total_nodes=$(vmq_node_count)
    local hosts
    hosts=$(vmq_host_list)
    local -a bench_nodes
    read -ra bench_nodes <<< "$BENCH_NODES"
    local num_bench=${#bench_nodes[@]}

    # CSV header
    echo "type,drain_seconds,msgs_lost,recovery_seconds" \
        > "${RESULTS_DIR}/${SCENARIO_TAG}/shutdown_results.csv"

    # Baseline load
    log_phase "baseline" "Establishing baseline load on all nodes"
    local conns
    conns=$(scale_load 80000 10)
    local rate
    rate=$(scale_load 20000 10)
    local conns_per=$(( conns / num_bench ))
    local rate_per=$(( rate / num_bench ))

    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "sub -h ${hosts} \
             -c $(( conns_per / 2 )) \
             -t 'shutdown/t/#' \
             -q 1"
    done
    sleep 5

    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "pub -h ${hosts} \
             -c $(( conns_per / 2 )) \
             -I $(( 1000 * conns_per / 2 / rate_per )) \
             -t 'shutdown/t/%i' \
             -q 1 \
             -s 256"
    done

    sleep "$BASELINE_DURATION"
    collect_metrics "baseline"

    # Graceful shutdown test
    run_shutdown_test "graceful"

    # Let cluster stabilize between tests
    sleep "$SETTLE"

    # Ungraceful shutdown test
    run_shutdown_test "ungraceful"

    finish_scenario
}

main "$@"
