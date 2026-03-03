#!/usr/bin/env bash
# 06_connection_storm.sh - Connection storm benchmark
#
# Tests connection acceptance under high-rate and bursty load patterns,
# including balance-driven rejection and scale-out scenarios.
# Adapts to the actual cluster size, reserving 2 nodes for expansion.
#
# Required environment:
#   BENCH_NODES  - space-separated bench node IPs
#   VMQ_NODES    - space-separated VerneMQ node IPs (3+ required; last 2 reserved for expansion)
#   RESULTS_DIR  - output directory
#
# Metrics collected:
#   accept rate, rejection rate, health check latency, memory/conn,
#   balance time, CONNACK latency

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

SCENARIO_NAME="06_connection_storm"
STABILITY_DURATION="${STABILITY_DURATION:-600}"  # 10 min stability hold

collect_connection_stats() {
    local tag="$1"
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}/${tag}"
    mkdir -p "$out_dir"

    local -a nodes
    read -ra nodes <<< "$VMQ_NODES"
    for i in "${!nodes[@]}"; do
        local metrics
        metrics=$(ssh_vmq "$i" "$VMQ_ADMIN metrics show" 2>/dev/null || echo "")
        echo "$metrics" | grep -E "(mqtt_connack|socket_open|socket_close|balance)" \
            > "$out_dir/conn_metrics_node${i}.txt" || true

        local health_start health_end
        health_start=$(date +%s%N)
        check_balance_health "$i" > /dev/null
        health_end=$(date +%s%N)
        echo "node${i},$(( health_end - health_start ))" \
            >> "$out_dir/health_check_latency_ns.csv"
    done
}

main() {
    require_min_vmq_nodes 3 "connection storm needs at least 3 nodes"

    init_scenario "$SCENARIO_NAME"

    local total_nodes
    total_nodes=$(vmq_node_count)

    # For clusters with 5+ nodes, reserve 2 for expansion; otherwise use all
    local active_nodes
    if (( total_nodes >= 5 )); then
        active_nodes=$(( total_nodes - 2 ))
    else
        active_nodes=$total_nodes
    fi

    # Build host list for active nodes
    local hosts_active
    hosts_active=$(vmq_host_first_n "$active_nodes")
    local hosts_1_2
    hosts_1_2=$(vmq_host_subset 0 1)
    local -a bench_nodes
    read -ra bench_nodes <<< "$BENCH_NODES"
    local num_bench=${#bench_nodes[@]}

    # Phase 1: Ramp connections (scaled from 10-node reference where 8 were active)
    local total_conns
    total_conns=$(scale_load 100000 10)
    local ramp_rate
    ramp_rate=$(scale_load 10000 10)
    log_phase "phase1" "Ramp 0 to ${total_conns} connections at ${ramp_rate}/sec (${active_nodes} nodes)"
    collect_metrics "p1_before"

    local conns_per=$(( total_conns / num_bench ))

    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "conn -h ${hosts_active} \
             -c ${conns_per} \
             -R $(( ramp_rate / num_bench )) \
             -k 60"
    done

    # Wait for all connections to establish
    sleep 15
    collect_metrics "p1_after"
    collect_connection_stats "p1_stats"

    # Phase 2: Burst connections (scaled)
    local burst_conns
    burst_conns=$(scale_load 50000 10)
    local burst_rate=$(( burst_conns / 5 ))
    log_phase "phase2" "Burst ${burst_conns} connections in 5 seconds"
    collect_metrics "p2_before"

    local burst_per=$(( burst_conns / num_bench ))
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "conn -h ${hosts_active} \
             -c ${burst_per} \
             -R $(( burst_rate / num_bench )) \
             -k 60 \
             --prefix 'burst_'"
    done

    sleep 10
    collect_metrics "p2_after"
    collect_connection_stats "p2_stats"

    # Phase 3: Targeted connections to vmq1+vmq2 only (trigger rejection via balance)
    local targeted_conns
    targeted_conns=$(scale_load 30000 10)
    log_phase "phase3" "${targeted_conns} connections to vmq1+vmq2 only (expect rejection)"
    collect_metrics "p3_before"

    local targeted_per=$(( targeted_conns / num_bench ))
    local targeted_rate
    targeted_rate=$(scale_load 50000 10)
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "conn -h ${hosts_1_2} \
             -c ${targeted_per} \
             -R $(( targeted_rate / num_bench )) \
             -k 60 \
             --prefix 'targeted_'"
    done

    sleep 15
    collect_metrics "p3_after"
    collect_connection_stats "p3_stats"

    # Check rejection metrics
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}/p3_rejections"
    mkdir -p "$out_dir"
    for idx in 0 1; do
        ssh_vmq "$idx" "$VMQ_ADMIN metrics show" 2>/dev/null \
            | grep -i "reject" > "$out_dir/rejections_node${idx}.txt" || true
    done

    # Phase 4: Hold connections for stability test
    log_phase "phase4" "Hold connections for ${STABILITY_DURATION}s (stability)"
    collect_metrics "p4_start"

    local interval=60
    local elapsed=0
    while (( elapsed < STABILITY_DURATION )); do
        collect_connection_stats "p4_t${elapsed}"
        sleep "$interval"
        (( elapsed += interval ))
    done

    collect_metrics "p4_end"
    collect_connection_stats "p4_final"

    # Phase 5: Add expansion nodes, observe rebalance (only if nodes were reserved)
    if (( active_nodes < total_nodes )); then
        local expand_idx_1=$(( active_nodes ))
        local expand_idx_2=$(( active_nodes + 1 ))
        log_phase "phase5" "Add nodes ${expand_idx_1}+${expand_idx_2}, observe rebalance"
        collect_metrics "p5_before"

        local expand_start
        expand_start=$(date +%s)
        start_vmq_node "$expand_idx_1"
        start_vmq_node "$expand_idx_2"
        wait_cluster_ready "$total_nodes" 120

        # Monitor redistribution
        local expand_elapsed=0
        local expand_timeout=300
        while (( expand_elapsed < expand_timeout )); do
            collect_connection_stats "p5_t${expand_elapsed}"
            sleep 30
            (( expand_elapsed += 30 ))
        done

        local expand_time=$(( $(date +%s) - expand_start ))
        echo "expand_to_${total_nodes}_seconds,$expand_time" \
            >> "${RESULTS_DIR}/${SCENARIO_TAG}/timing.csv"
        collect_metrics "p5_after"
    else
        log_info "Skipping phase 5 (expansion): all $total_nodes nodes already active"
    fi

    phase_cleanup "final"
    finish_scenario
}

main "$@"
