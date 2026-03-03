#!/usr/bin/env bash
# 03_netsplit_recovery.sh - Network partition and recovery benchmark
#
# Tests cluster behavior under progressive node failures with quorum-based
# health tracking. Measures degraded-mode behavior, recovery convergence,
# and dead-node cleanup. Adapts to the actual cluster size.
#
# Required environment:
#   BENCH_NODES  - space-separated bench node IPs
#   VMQ_NODES    - space-separated VerneMQ node IPs (4+ required)
#   RESULTS_DIR  - output directory
#
# Cluster config: quorum=0.6, dead_node_cleanup_timeout=120
#
# Metrics collected:
#   cluster_readiness, netsplit/degraded counters, message loss,
#   recovery time, gossip convergence

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
SCENARIO_LB_MODE="direct_only"

SCENARIO_NAME="03_netsplit_recovery"
HEALTHY_DURATION="${HEALTHY_DURATION:-300}"  # 5 min healthy baseline
PHASE_SETTLE="${PHASE_SETTLE:-30}"
DEAD_NODE_TIMEOUT=120

collect_cluster_status() {
    local tag="$1"
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}/${tag}"
    mkdir -p "$out_dir"

    ssh_vmq 0 "$VMQ_ADMIN cluster show" \
        > "$out_dir/cluster_show.txt" 2>/dev/null || true

    # Collect health tier metrics
    local -a nodes
    read -ra nodes <<< "$VMQ_NODES"
    for i in "${!nodes[@]}"; do
        ssh_vmq "$i" "$VMQ_ADMIN metrics show" 2>/dev/null \
            | grep -E "(cluster_readiness|netsplit|degraded|gossip)" \
            > "$out_dir/cluster_metrics_node${i}.txt" || true
    done
}

count_delivered_messages() {
    local tag="$1"
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}/${tag}"
    mkdir -p "$out_dir"

    local -a nodes
    read -ra nodes <<< "$VMQ_NODES"
    local total=0
    for i in "${!nodes[@]}"; do
        local count
        count=$(get_vmq_metric_raw "$i" "mqtt_publish_sent")
        echo "node${i},$count" >> "$out_dir/delivered.csv"
        (( total += count )) || true
    done
    echo "total,$total" >> "$out_dir/delivered.csv"
    echo "$total"
}

main() {
    require_min_vmq_nodes 4 "netsplit scenario needs progressive failure room"
    check_scenario_compat 03

    init_scenario "$SCENARIO_NAME"

    local total_nodes
    total_nodes=$(vmq_node_count)
    local hosts
    hosts=$(vmq_host_list)
    local -a bench_nodes
    read -ra bench_nodes <<< "$BENCH_NODES"
    local num_bench=${#bench_nodes[@]}

    # Phase 1: Healthy baseline (load scaled from 10-node reference)
    local total_conns
    total_conns=$(scale_load 80000 10)
    local total_rate
    total_rate=$(scale_load 20000 10)
    log_phase "phase1" "${total_conns} connections, ${total_rate} msg/s - healthy baseline"
    collect_all_metrics "p1_before"

    local conns_per=$(( total_conns / num_bench ))
    local rate_per=$(( total_rate / num_bench ))

    # Split VMQ nodes for cross-node routing: pubs on first half, subs on second half
    local pub_node_count=$(( (total_nodes + 1) / 2 ))
    local pub_hosts
    pub_hosts=$(vmq_host_first_n "$pub_node_count")
    local sub_hosts=""
    for (( si=pub_node_count; si<total_nodes; si++ )); do
        local node
        node=$(_node_at VMQ_NODES "$si")
        sub_hosts="${sub_hosts:+${sub_hosts},}${node}"
    done
    # Fallback to all hosts if only 1-2 nodes
    if [[ -z "$sub_hosts" ]]; then sub_hosts="$hosts"; fi

    # Subscribers first on all bench nodes, targeting sub VMQ nodes
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "sub -h ${sub_hosts} \
             -c ${conns_per} \
             -t 'netsplit/t/%i' \
             -q 1"
    done

    # Wait for subscription metadata propagation across cluster
    local sub_settle="${SUB_SETTLE_TIME:-30}"
    log_info "Waiting ${sub_settle}s for subscription metadata propagation..."
    sleep "$sub_settle"

    # Publishers on all bench nodes, targeting pub VMQ nodes
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "pub -h ${pub_hosts} \
             -c ${conns_per} \
             -I $(( 1000 * conns_per / rate_per )) \
             -t 'netsplit/t/%i' \
             -q 1 \
             -s 256"
    done

    sleep "$HEALTHY_DURATION"
    collect_all_metrics "p1_healthy"
    collect_cluster_status "p1_cluster"
    local msgs_before
    msgs_before=$(count_delivered_messages "p1_delivered")

    # Phase 2: Kill last node -> degraded
    local last_idx=$(( total_nodes - 1 ))
    log_phase "phase2" "Kill node $last_idx -> degraded ($((total_nodes-1))/${total_nodes} nodes)"
    kill_vmq_node "$last_idx"
    sleep "$PHASE_SETTLE"
    collect_all_metrics "p2_degraded1"
    collect_cluster_status "p2_cluster"

    # Phase 3: Kill two more nodes from tail -> still degraded if above quorum
    local kill_idx_1=$(( total_nodes - 3 ))
    local kill_idx_2=$(( total_nodes - 2 ))
    if (( kill_idx_1 >= 0 && kill_idx_2 >= 0 )); then
        local remaining=$(( total_nodes - 3 ))
        log_phase "phase3" "Kill nodes ${kill_idx_1},${kill_idx_2} -> ${remaining}/${total_nodes} nodes"
        kill_vmq_node "$kill_idx_1"
        kill_vmq_node "$kill_idx_2"
        sleep "$PHASE_SETTLE"
        collect_all_metrics "p3_degraded2"
        collect_cluster_status "p3_cluster"
    fi

    # Phase 4: Kill one more -> approach quorum boundary
    local kill_idx_3=$(( total_nodes - 4 ))
    if (( kill_idx_3 >= 0 )); then
        local remaining=$(( total_nodes - 4 ))
        log_phase "phase4" "Kill node ${kill_idx_3} -> ${remaining}/${total_nodes} (quorum boundary)"
        kill_vmq_node "$kill_idx_3"
        sleep "$PHASE_SETTLE"
        collect_all_metrics "p4_partitioned"
        collect_cluster_status "p4_cluster"
    fi

    # Phase 5: Restart all killed nodes -> recovery
    log_phase "phase5" "Restart killed nodes -> healthy recovery"
    local recovery_start
    recovery_start=$(date +%s)

    for idx in $(seq "$kill_idx_3" "$last_idx"); do
        start_vmq_node "$idx"
    done

    wait_cluster_ready "$total_nodes" 180
    local recovery_end
    recovery_end=$(date +%s)
    local recovery_time=$(( recovery_end - recovery_start ))
    echo "recovery_seconds,$recovery_time" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/timing.csv"
    log_info "Recovery time: ${recovery_time}s"

    sleep "$PHASE_SETTLE"
    collect_all_metrics "p5_recovered"
    collect_cluster_status "p5_cluster"
    local msgs_after
    msgs_after=$(count_delivered_messages "p5_delivered")

    # Phase 6: Kill last node permanently, wait for dead node cleanup
    # Only run the full cleanup wait if dead_node_cleanup feature is available
    if has_feature dead_node_cleanup; then
        log_phase "phase6" "Kill node ${last_idx} permanently, wait ${DEAD_NODE_TIMEOUT}s for cleanup"
        kill_vmq_node "$last_idx"
        log_info "Waiting ${DEAD_NODE_TIMEOUT}s for dead_node_cleanup_timeout..."
        sleep $(( DEAD_NODE_TIMEOUT + 30 ))
        collect_all_metrics "p6_cleanup"
        collect_cluster_status "p6_cluster"

        # Verify dead node was cleaned up
        local cluster_out
        cluster_out=$(ssh_vmq 0 "$VMQ_ADMIN cluster show" 2>/dev/null || echo "")
        local -a all_nodes
        read -ra all_nodes <<< "$VMQ_NODES"
        local dead_node="${all_nodes[$last_idx]}"
        if echo "$cluster_out" | grep -q "$dead_node"; then
            log_info "Dead node $dead_node still visible in cluster (may not be cleaned yet)"
        else
            log_info "Dead node $dead_node cleaned from cluster"
        fi
    else
        log_info "Skipping Phase 6 (dead_node_cleanup not available in profile '${PROFILE_NAME}')"
    fi

    phase_cleanup "final"

    # Summary
    local out="${RESULTS_DIR}/${SCENARIO_TAG}"
    {
        echo "msgs_before_failures,$msgs_before"
        echo "msgs_after_recovery,$msgs_after"
        echo "recovery_time_seconds,$recovery_time"
    } >> "$out/summary.csv"

    finish_scenario
}

main "$@"
