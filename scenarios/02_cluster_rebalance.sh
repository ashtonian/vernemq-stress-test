#!/usr/bin/env bash
# 02_cluster_rebalance.sh - Cluster connection rebalancing benchmark
#
# Tests connection rebalancing across a growing cluster. Starts with imbalanced
# load on 2 nodes, triggers rebalance, then progressively expands the cluster
# using available tail nodes.
#
# Required environment:
#   BENCH_NODES  - space-separated bench node IPs
#   VMQ_NODES    - space-separated VerneMQ node IPs (5+ required; extras used for expansion)
#   RESULTS_DIR  - output directory
#
# Metrics collected:
#   balance_is_accepting per node, rejections, disconnections, rounds,
#   connection heatmap, redistribution time

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

SCENARIO_NAME="02_cluster_rebalance"
SETTLE_TIME="${SETTLE_TIME:-60}"
REBALANCE_WAIT="${REBALANCE_WAIT:-300}"  # 5 min for rebalance

collect_balance_status() {
    local tag="$1"
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}/${tag}"
    mkdir -p "$out_dir"

    local -a nodes
    read -ra nodes <<< "$VMQ_NODES"
    for i in "${!nodes[@]}"; do
        local status
        status=$(check_balance_health "$i")
        echo "node${i},$status" >> "$out_dir/balance_health.csv"
        log_info "Node $i balance health: HTTP $status"
    done

    # Collect connection counts per node
    for i in "${!nodes[@]}"; do
        local count
        count=$(ssh_vmq "$i" "$VMQ_ADMIN metrics show" 2>/dev/null \
            | grep "mqtt_connack_sent" | head -1 || echo "unavailable")
        echo "node${i},$count" >> "$out_dir/connection_counts.csv"
    done
}

poll_balance_health() {
    local duration="$1" interval="${2:-10}" tag="$3"
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}/${tag}"
    mkdir -p "$out_dir"
    local elapsed=0

    while (( elapsed < duration )); do
        local ts
        ts=$(_ts)
        local -a nodes
        read -ra nodes <<< "$VMQ_NODES"
        for i in "${!nodes[@]}"; do
            local status
            status=$(check_balance_health "$i")
            echo "$ts,node${i},$status" >> "$out_dir/balance_health_timeline.csv"
        done
        sleep "$interval"
        (( elapsed += interval ))
    done
}

main() {
    require_min_vmq_nodes 5 "rebalance requires at least 5 initial nodes"
    require_feature balance

    init_scenario "$SCENARIO_NAME"

    local total_nodes
    total_nodes=$(vmq_node_count)

    local hosts_1_2
    hosts_1_2=$(vmq_host_subset 0 1)
    local -a bench_nodes
    read -ra bench_nodes <<< "$BENCH_NODES"
    local num_bench=${#bench_nodes[@]}

    # Phase 1: Route all 50K connections to vmq1+vmq2 only
    local total_conns
    total_conns=$(scale_load 50000 10)
    log_phase "phase1" "${total_conns} connections to vmq1+vmq2 only (imbalanced)"
    collect_metrics "p1_before"

    local conns_per
    conns_per=$(( total_conns / num_bench ))
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "conn -h ${hosts_1_2} \
             -c ${conns_per}"
    done
    sleep "$SETTLE_TIME"
    collect_metrics "p1_loaded"
    collect_balance_status "p1_health"

    # Phase 2: Monitor balance-health (expect 503 on vmq1/vmq2)
    log_phase "phase2" "Monitor balance-health on all nodes"
    poll_balance_health 60 5 "p2_monitor" &
    local poll_pid=$!
    sleep 60
    wait "$poll_pid" || true
    collect_balance_status "p2_health"

    # Phase 3: Trigger rebalance
    log_phase "phase3" "Trigger vmq-admin balance rebalance"
    collect_metrics "p3_before"
    local rebalance_start
    rebalance_start=$(date +%s)
    ssh_vmq 0 "$VMQ_ADMIN balance rebalance"

    # Poll until balanced or timeout
    poll_balance_health "$REBALANCE_WAIT" 10 "p3_rebalance" &
    poll_pid=$!
    sleep "$REBALANCE_WAIT"
    wait "$poll_pid" || true
    local rebalance_end
    rebalance_end=$(date +%s)
    echo "rebalance_seconds,$(( rebalance_end - rebalance_start ))" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/timing.csv"
    collect_metrics "p3_after"
    collect_balance_status "p3_health"

    # Phase 4: Verify steady state on initial nodes
    log_phase "phase4" "Verify steady state"
    collect_balance_status "p4_steady"
    collect_metrics "p4_steady"

    # Phase 5: Expand cluster using tail nodes (if available)
    # With 10 nodes: first 5 active initially -> expand by adding tail nodes
    if (( total_nodes > 5 )); then
        # Calculate expansion: add ~60% of remaining nodes first
        local remaining=$(( total_nodes - 5 ))
        local first_batch=$(( remaining * 3 / 5 ))
        if (( first_batch < 1 )); then first_batch=1; fi
        local second_batch=$(( remaining - first_batch ))

        # First expansion batch
        local expand_target=$(( 5 + first_batch ))
        log_phase "phase5" "Start ${first_batch} expansion nodes - observe auto-rebalance to ${expand_target} nodes"
        local expand_indices
        expand_indices=$(tail_node_indices "$remaining" | head -n "$first_batch")
        for idx in $expand_indices; do
            start_vmq_node "$idx"
        done
        wait_cluster_ready "$expand_target"
        poll_balance_health "$REBALANCE_WAIT" 10 "p5_expand" &
        poll_pid=$!
        sleep "$REBALANCE_WAIT"
        wait "$poll_pid" || true
        collect_metrics "p5_after"
        collect_balance_status "p5_health"

        # Second expansion batch (if there are more nodes)
        if (( second_batch > 0 )); then
            log_phase "phase6" "Start remaining ${second_batch} nodes - observe redistribution to ${total_nodes} nodes"
            local second_indices
            second_indices=$(tail_node_indices "$remaining" | tail -n "$second_batch")
            for idx in $second_indices; do
                start_vmq_node "$idx"
            done
            wait_cluster_ready "$total_nodes"
            poll_balance_health "$REBALANCE_WAIT" 10 "p6_expand" &
            poll_pid=$!
            sleep "$REBALANCE_WAIT"
            wait "$poll_pid" || true
            collect_metrics "p6_after"
            collect_balance_status "p6_health"
        fi
    fi

    finish_scenario
}

main "$@"
