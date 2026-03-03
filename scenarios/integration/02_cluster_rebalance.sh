#!/usr/bin/env bash
# 02_cluster_rebalance.sh - Cluster connection rebalancing benchmark
#
# Tests connection rebalancing across a growing cluster. Starts with imbalanced
# load on 2 nodes, triggers rebalance, then progressively expands the cluster
# using available tail nodes. Runs continuous pub/sub traffic throughout to
# measure the impact of rebalancing on message throughput.
#
# Tags: integration,balance
# Min nodes: 5
#
# Required environment:
#   BENCH_NODES  - space-separated bench node IPs
#   VMQ_NODES    - space-separated VerneMQ node IPs (5+ required; extras used for expansion)
#   RESULTS_DIR  - output directory
#
# Metrics collected:
#   balance_is_accepting per node, rejections, disconnections, rounds,
#   connection heatmap, redistribution time, message throughput per phase

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
SCENARIO_LB_MODE="supported"

SCENARIO_NAME="02_cluster_rebalance"
SETTLE_TIME="${SETTLE_TIME:-60}"
REBALANCE_WAIT="${REBALANCE_WAIT:-300}"  # 5 min for rebalance
BASELINE_DURATION="${BASELINE_DURATION:-60}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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
        count=$(get_vmq_metric_raw "$i" "mqtt_connack_sent")
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

# Measure throughput delta over a window
measure_throughput() {
    local tag="$1" window="${2:-15}"
    local t1 t2
    t1=$(get_vmq_metric_sum "mqtt_publish_received")
    sleep "$window"
    t2=$(get_vmq_metric_sum "mqtt_publish_received")
    local rate=$(( (t2 - t1) / window ))
    echo "${tag},${rate}" >> "${RESULTS_DIR}/${SCENARIO_TAG}/throughput_timeline.csv"
    log_info "Throughput [${tag}]: ~${rate} msg/s"
    echo "$rate"
}

main() {
    require_min_vmq_nodes 5 "rebalance requires at least 5 initial nodes"
    require_feature balance
    check_scenario_compat 02

    init_scenario "$SCENARIO_NAME"

    # LB support: warn if running without LB
    if ! should_use_lb; then
        log_info "WARNING: Rebalance scenario runs without LB — disconnected clients will reconnect to same nodes. Enable LB for realistic redistribution."
    fi

    local total_nodes
    total_nodes=$(vmq_node_count)

    local hosts_1_2
    hosts_1_2=$(vmq_host_subset 0 1)
    local all_hosts
    all_hosts=$(resolve_bench_hosts)
    local -a bench_nodes
    read -ra bench_nodes <<< "$BENCH_NODES"
    local num_bench=${#bench_nodes[@]}

    # CSV headers
    echo "phase,throughput_msg_per_sec" \
        > "${RESULTS_DIR}/${SCENARIO_TAG}/throughput_timeline.csv"

    # =====================================================================
    # Start continuous pub/sub traffic across all active nodes
    # This runs throughout the entire test to measure rebalancing impact
    # =====================================================================
    log_phase "traffic_setup" "Starting continuous pub/sub traffic on initial cluster"
    local traffic_conns
    traffic_conns=$(scale_load 20000 10)
    local traffic_rate
    traffic_rate=$(scale_load 5000 10)
    local traffic_conns_per=$(( traffic_conns / num_bench ))
    local traffic_rate_per=$(( traffic_rate / num_bench ))

    # Subscribers on all initial nodes
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "sub -h ${all_hosts} \
             -c $(( traffic_conns_per / 2 )) \
             -t 'rebalance/t/%i' \
             -q 1 \
             --prefix 'rebal_sub_'"
    done

    # Wait for subscription propagation
    local sub_settle="${SUB_SETTLE_TIME:-20}"
    log_info "Waiting ${sub_settle}s for subscription propagation..."
    sleep "$sub_settle"
    wait_subscriptions_converged 90 10 || \
        log_error "WARNING: subscriptions may not be fully converged"

    # Publishers targeting nodes 0+1 (where connections will be concentrated)
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "pub -h ${hosts_1_2} \
             -c $(( traffic_conns_per / 2 )) \
             -I $(( 1000 * traffic_conns_per / 2 / traffic_rate_per )) \
             -t 'rebalance/t/%i' \
             -q 1 \
             -s 256 \
             --prefix 'rebal_pub_'"
    done

    sleep "$BASELINE_DURATION"
    collect_all_metrics "traffic_baseline"

    # Verify traffic is flowing
    local baseline_rate
    baseline_rate=$(measure_throughput "baseline" 15)
    if (( baseline_rate < 100 )); then
        log_error "FATAL: baseline traffic not flowing (${baseline_rate} msg/s). Aborting."
        finish_scenario
        exit 1
    fi

    # =====================================================================
    # Phase 1: Route 50K connections to vmq1+vmq2 only (imbalanced)
    # =====================================================================
    local total_conns
    total_conns=$(scale_load 50000 10)
    log_phase "phase1" "${total_conns} connections to vmq1+vmq2 only (imbalanced)"
    collect_all_metrics "p1_before"

    local conns_per
    conns_per=$(( total_conns / num_bench ))
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "conn -h ${hosts_1_2} \
             -c ${conns_per} \
             --prefix 'rebal_conn_'"
    done
    sleep "$SETTLE_TIME"
    collect_all_metrics "p1_loaded"
    collect_balance_status "p1_health"
    measure_throughput "p1_loaded" 15

    # Phase 2: Monitor balance-health (expect 503 on vmq1/vmq2)
    log_phase "phase2" "Monitor balance-health on all nodes"
    poll_balance_health 60 5 "p2_monitor" &
    local poll_pid=$!
    sleep 60
    wait "$poll_pid" || true
    collect_balance_status "p2_health"
    measure_throughput "p2_monitor" 15

    # Phase 3: Trigger rebalance
    log_phase "phase3" "Trigger vmq-admin balance rebalance"
    collect_all_metrics "p3_before"
    local rebalance_start
    rebalance_start=$(date +%s)
    ssh_vmq 0 "$VMQ_ADMIN balance rebalance"

    # Poll until balanced or timeout, measuring throughput periodically
    poll_balance_health "$REBALANCE_WAIT" 10 "p3_rebalance" &
    poll_pid=$!

    local rebal_elapsed=0
    local rebal_interval=60
    while (( rebal_elapsed < REBALANCE_WAIT )); do
        sleep "$rebal_interval"
        (( rebal_elapsed += rebal_interval ))
        measure_throughput "p3_t${rebal_elapsed}" 10
        collect_all_metrics "p3_t${rebal_elapsed}"
    done

    wait "$poll_pid" || true
    local rebalance_end
    rebalance_end=$(date +%s)
    echo "rebalance_seconds,$(( rebalance_end - rebalance_start ))" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/timing.csv"
    collect_all_metrics "p3_after"
    collect_balance_status "p3_health"
    measure_throughput "p3_after" 15

    # When LB is active, restart connection clients through LB for redistribution
    if should_use_lb; then
        log_phase "phase3b" "Restarting connection clients through LB for redistribution"
        local lb_hosts
        lb_hosts=$(resolve_bench_hosts)
        # Stop existing connection-only clients and restart via LB
        for i in "${!bench_nodes[@]}"; do
            ssh_bench "$i" "pkill -f 'emqtt_bench conn' || true"
        done
        sleep 5
        for i in "${!bench_nodes[@]}"; do
            start_emqtt_bench "$i" \
                "conn -h ${lb_hosts} \
                 -c ${conns_per} \
                 --prefix 'rebal_conn_'"
        done
        sleep "$SETTLE_TIME"
        collect_all_metrics "p3b_redistributed"
        collect_balance_status "p3b_health"
        measure_throughput "p3b_redistributed" 15
    fi

    # Phase 4: Verify steady state on initial nodes
    log_phase "phase4" "Verify steady state"
    collect_balance_status "p4_steady"
    collect_all_metrics "p4_steady"
    measure_throughput "p4_steady" 15

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
        local exp_elapsed=0
        while (( exp_elapsed < REBALANCE_WAIT )); do
            sleep "$rebal_interval"
            (( exp_elapsed += rebal_interval ))
            measure_throughput "p5_t${exp_elapsed}" 10
        done
        wait "$poll_pid" || true
        collect_all_metrics "p5_after"
        collect_balance_status "p5_health"
        measure_throughput "p5_after" 15

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
            exp_elapsed=0
            while (( exp_elapsed < REBALANCE_WAIT )); do
                sleep "$rebal_interval"
                (( exp_elapsed += rebal_interval ))
                measure_throughput "p6_t${exp_elapsed}" 10
            done
            wait "$poll_pid" || true
            collect_all_metrics "p6_after"
            collect_balance_status "p6_health"
            measure_throughput "p6_after" 15
        fi
    fi

    # Summary
    {
        echo "baseline_throughput,$baseline_rate"
        echo "total_connection_load,$total_conns"
        echo "total_nodes,$total_nodes"
    } >> "${RESULTS_DIR}/${SCENARIO_TAG}/summary.csv"

    finish_scenario
}

main "$@"
