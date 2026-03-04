#!/usr/bin/env bash
# 05_node_failure_recovery.sh - Node failure and recovery benchmark
#
# Tests cluster resilience under various failure modes: single node kill,
# restart with reconnect, rolling restart, and multi-node simultaneous failure.
# Compares behavior with different outgoing_clustering_connection_count values.
# Adapts to the actual cluster size.
#
# Required environment:
#   BENCH_NODES  - space-separated bench node IPs
#   VMQ_NODES    - space-separated VerneMQ node IPs (3+ required)
#   RESULTS_DIR  - output directory
#
# Metrics collected:
#   delivery latency, message loss, reconnect histogram,
#   pool throughput, CPU

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
SCENARIO_LB_MODE="direct_only"

SCENARIO_NAME="05_node_failure_recovery"
WARMUP_DURATION="${WARMUP_DURATION:-300}"  # 5 min warm-up
SETTLE="${SETTLE:-60}"
ROLLING_GAP=30

set_connection_count() {
    local count="$1"
    reconfigure_and_restart "outgoing_clustering_connection_count" "$count"
}

count_qos1_delivered() {
    local tag="$1"
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}/${tag}"
    mkdir -p "$out_dir"

    local -a nodes
    read -ra nodes <<< "$VMQ_NODES"
    local total=0
    for i in "${!nodes[@]}"; do
        local count
        count=$(get_vmq_metric_raw "$i" "mqtt_puback_sent")
        echo "node${i},$count" >> "$out_dir/puback.csv"
        (( total += count )) || true
    done
    echo "$total"
}

run_failure_phases() {
    local pool_size="$1"
    local tag_prefix="pool${pool_size}"
    local hosts
    hosts=$(vmq_host_list)
    local -a bench_nodes
    read -ra bench_nodes <<< "$BENCH_NODES"
    local num_bench=${#bench_nodes[@]}
    local total_nodes
    total_nodes=$(vmq_node_count)

    log_info "=== Run with outgoing_clustering_connection_count=$pool_size ==="
    set_connection_count "$pool_size"

    # Phase 1: Warm-up with scaled load (reference: 10 nodes)
    local total_conns
    total_conns=$(scale_load 80000 10)
    local total_rate
    total_rate=$(scale_load 20000 10)
    log_phase "${tag_prefix}_phase1" "${total_conns} conns, ${total_rate} msg/s QoS 1 warm-up (pool=$pool_size)"
    collect_all_metrics "${tag_prefix}_p1_before"

    local conns_per=$(( total_conns / num_bench ))
    local rate_per=$(( total_rate / num_bench ))

    # Subscribers
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "sub -h ${hosts} \
             -c $(( conns_per / 2 )) \
             -t 'failure/t/%i' \
             -q 1"
    done

    # Wait for subscription metadata propagation across cluster
    local sub_settle="${SUB_SETTLE_TIME:-30}"
    log_info "Waiting ${sub_settle}s for subscription metadata propagation..."
    sleep "$sub_settle"

    # Publishers
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "pub -h ${hosts} \
             -c $(( conns_per / 2 )) \
             -I $(( 1000 * conns_per / 2 / rate_per )) \
             -t 'failure/t/%i' \
             -q 1 \
             -s 256"
    done

    sleep "$WARMUP_DURATION"
    collect_all_metrics "${tag_prefix}_p1_after"
    local msgs_baseline
    msgs_baseline=$(count_qos1_delivered "${tag_prefix}_p1_delivered")

    # Phase 2: SIGKILL node at midpoint
    local mid_idx=$(( total_nodes / 2 ))
    log_phase "${tag_prefix}_phase2" "SIGKILL node ${mid_idx} (pool=$pool_size)"
    local kill_start
    kill_start=$(date +%s)
    kill_vmq_node "$mid_idx"
    sleep "$SETTLE"

    collect_all_metrics "${tag_prefix}_p2_after"
    local detection_time=$(( $(date +%s) - kill_start ))
    echo "${tag_prefix}_detection_seconds,$detection_time" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/timing.csv"

    # Phase 3: Restart killed node
    log_phase "${tag_prefix}_phase3" "Restart node ${mid_idx}, measure reconnect (pool=$pool_size)"
    local restart_start
    restart_start=$(date +%s)
    start_vmq_node "$mid_idx"
    wait_cluster_ready "$total_nodes" 120
    local reconnect_time=$(( $(date +%s) - restart_start ))
    echo "${tag_prefix}_reconnect_seconds,$reconnect_time" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/timing.csv"
    sleep "$SETTLE"
    collect_all_metrics "${tag_prefix}_p3_after"

    # Phase 4: Rolling restart all nodes
    log_phase "${tag_prefix}_phase4" "Rolling restart all ${total_nodes} nodes, ${ROLLING_GAP}s gap (pool=$pool_size)"
    local rolling_start
    rolling_start=$(date +%s)
    for idx in $(seq 0 $(( total_nodes - 1 ))); do
        log_info "Rolling restart: node $idx"
        kill_vmq_node "$idx"
        sleep 5
        start_vmq_node "$idx"
        sleep "$ROLLING_GAP"
    done
    wait_cluster_ready "$total_nodes" 180
    local rolling_time=$(( $(date +%s) - rolling_start ))
    echo "${tag_prefix}_rolling_seconds,$rolling_time" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/timing.csv"
    sleep "$SETTLE"
    collect_all_metrics "${tag_prefix}_p4_after"

    # Phase 5: Kill tail nodes simultaneously (last 3 or fewer if small cluster)
    local kill_count=3
    if (( kill_count > total_nodes - 1 )); then
        kill_count=$(( total_nodes - 1 ))
    fi
    local kill_start_idx=$(( total_nodes - kill_count ))
    log_phase "${tag_prefix}_phase5" "Kill ${kill_count} tail nodes simultaneously (pool=$pool_size)"
    local multi_start
    multi_start=$(date +%s)
    for idx in $(seq "$kill_start_idx" $(( total_nodes - 1 ))); do
        kill_vmq_node "$idx" &
    done
    wait
    sleep "$SETTLE"
    collect_all_metrics "${tag_prefix}_p5_killed"

    # Restart them
    for idx in $(seq "$kill_start_idx" $(( total_nodes - 1 ))); do
        start_vmq_node "$idx"
    done
    wait_cluster_ready "$total_nodes" 180
    local multi_time=$(( $(date +%s) - multi_start ))
    echo "${tag_prefix}_multi_failure_seconds,$multi_time" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/timing.csv"
    sleep "$SETTLE"
    collect_all_metrics "${tag_prefix}_p5_recovered"

    local msgs_final
    msgs_final=$(count_qos1_delivered "${tag_prefix}_p5_delivered")

    phase_cleanup "${tag_prefix}_final"

    # Summary for this pool size
    {
        echo "${tag_prefix}_msgs_baseline,$msgs_baseline"
        echo "${tag_prefix}_msgs_final,$msgs_final"
    } >> "${RESULTS_DIR}/${SCENARIO_TAG}/summary.csv"
}

main() {
    require_min_vmq_nodes 3 "failure scenarios need at least 3 nodes for meaningful tests"
    check_scenario_compat 05

    init_scenario "$SCENARIO_NAME"

    for pool_size in "${PROFILE_POOL_SIZES[@]}"; do
        run_failure_phases "$pool_size"
    done

    finish_scenario
}

main "$@"
