#!/usr/bin/env bash
# 07_node_flapping.sh - Node flapping chaos benchmark
#
# Tests cluster stability under repeated node kill/restart cycles of
# increasing severity: single, double, and triple simultaneous flaps.
#
# Tags: chaos,stability
# Min nodes: 5
#
# Required environment:
#   BENCH_NODES  - space-separated bench node IPs
#   VMQ_NODES    - space-separated VerneMQ node IPs (5+ expected)
#   RESULTS_DIR  - output directory
#
# Metrics collected:
#   convergence time per flap cycle, message throughput before/after,
#   cluster readiness

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

SCENARIO_NAME="07_node_flapping"
FLAP_DOWN_DURATION="${FLAP_DOWN_DURATION:-10}"
BASELINE_DURATION="${BASELINE_DURATION:-120}"  # 2 min baseline warmup
SETTLE="${SETTLE:-30}"

SINGLE_FLAP_CYCLES="${SINGLE_FLAP_CYCLES:-10}"
DOUBLE_FLAP_CYCLES="${DOUBLE_FLAP_CYCLES:-5}"
TRIPLE_FLAP_CYCLES="${TRIPLE_FLAP_CYCLES:-3}"

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
            | grep "mqtt_publish_received " | awk '{print $NF}' || echo 0)
        echo "node${i},$count" >> "$out_dir/publish_received.csv"
        (( total += count )) || true
    done
    echo "$total"
}

run_flap_cycle() {
    local cycle="$1" flap_type="$2" num_nodes_to_kill="$3"
    local total_nodes
    total_nodes=$(vmq_node_count)

    log_phase "flap_${flap_type}_cycle${cycle}" \
        "${flap_type} flap: kill ${num_nodes_to_kill} node(s), cycle ${cycle}"

    # Get tail node indices to kill
    local -a kill_indices
    mapfile -t kill_indices < <(tail_node_indices "$num_nodes_to_kill")

    local msgs_before
    msgs_before=$(count_messages "flap_${flap_type}_c${cycle}_before")

    # Kill nodes
    local flap_start
    flap_start=$(date +%s)
    for idx in "${kill_indices[@]}"; do
        kill_vmq_node "$idx" &
    done
    wait

    local kill_done
    kill_done=$(date +%s)

    # Wait with nodes down
    sleep "$FLAP_DOWN_DURATION"

    # Restart nodes
    for idx in "${kill_indices[@]}"; do
        start_vmq_node "$idx"
    done

    local restart_done
    restart_done=$(date +%s)

    # Wait for cluster convergence
    wait_cluster_ready "$total_nodes" 120
    local converge_done
    converge_done=$(date +%s)

    local convergence_seconds=$(( converge_done - restart_done ))

    collect_metrics "flap_${flap_type}_c${cycle}_after"

    local msgs_after
    msgs_after=$(count_messages "flap_${flap_type}_c${cycle}_after_msgs")

    # Write CSV row
    echo "${cycle},${flap_type},$(( kill_done - flap_start )),$(( restart_done - kill_done )),${convergence_seconds},${msgs_before},${msgs_after}" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/flap_results.csv"

    log_info "Flap cycle ${cycle} (${flap_type}): convergence=${convergence_seconds}s"

    sleep "$SETTLE"
}

main() {
    require_min_vmq_nodes 5 "node flapping"
    init_scenario "$SCENARIO_NAME"

    local total_nodes
    total_nodes=$(vmq_node_count)
    local hosts
    hosts=$(vmq_host_list)
    local -a bench_nodes
    read -ra bench_nodes <<< "$BENCH_NODES"
    local num_bench=${#bench_nodes[@]}

    # CSV header
    echo "cycle,type,kill_time,restart_time,convergence_seconds,msgs_before,msgs_after" \
        > "${RESULTS_DIR}/${SCENARIO_TAG}/flap_results.csv"

    # Baseline load
    log_phase "baseline" "Establishing baseline load"
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
             -t 'flap/t/#' \
             -q 1"
    done
    sleep 5

    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "pub -h ${hosts} \
             -c $(( conns_per / 2 )) \
             -I $(( 1000 * conns_per / 2 / rate_per )) \
             -t 'flap/t/%i' \
             -q 1 \
             -s 256"
    done

    sleep "$BASELINE_DURATION"
    collect_metrics "baseline"

    # Single node flap cycles
    log_info "=== Single Node Flap (${SINGLE_FLAP_CYCLES} cycles) ==="
    for (( c=1; c<=SINGLE_FLAP_CYCLES; c++ )); do
        run_flap_cycle "$c" "single" 1
    done

    # Double node flap cycles
    log_info "=== Double Node Flap (${DOUBLE_FLAP_CYCLES} cycles) ==="
    for (( c=1; c<=DOUBLE_FLAP_CYCLES; c++ )); do
        run_flap_cycle "$c" "double" 2
    done

    # Triple node flap cycles
    log_info "=== Triple Node Flap (${TRIPLE_FLAP_CYCLES} cycles) ==="
    for (( c=1; c<=TRIPLE_FLAP_CYCLES; c++ )); do
        run_flap_cycle "$c" "triple" 3
    done

    finish_scenario
}

main "$@"
