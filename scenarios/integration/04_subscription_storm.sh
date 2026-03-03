#!/usr/bin/env bash
# 04_subscription_storm.sh - Subscription storm benchmark
#
# Stress-tests the subscription trie under heavy concurrent modification.
# Compares performance with reg_trie_workers = 1, 8, and 16.
# Adapts to the actual cluster size.
#
# Required environment:
#   BENCH_NODES  - space-separated bench node IPs
#   VMQ_NODES    - space-separated VerneMQ node IPs (2+ required)
#   RESULTS_DIR  - output directory
#
# Metrics collected:
#   subscribe/unsubscribe latency, subscription accuracy, memory,
#   worker queue lengths

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
SCENARIO_LB_MODE="supported"

SCENARIO_NAME="04_subscription_storm"
PHASE_DURATION="${PHASE_DURATION:-120}"  # 2 min per phase

set_reg_trie_workers() {
    local workers="$1"
    log_info "Setting reg_trie_workers=$workers on all nodes"
    set_vmq_config "reg_trie_workers" "$workers" "all"
}

run_sub_storm_phases() {
    local worker_count="$1"
    local tag_prefix="w${worker_count}"
    local hosts
    hosts=$(vmq_host_list)
    local -a bench_nodes
    read -ra bench_nodes <<< "$BENCH_NODES"
    local num_bench=${#bench_nodes[@]}
    local total_nodes
    total_nodes=$(vmq_node_count)

    log_info "=== Run with reg_trie_workers=$worker_count ==="
    set_reg_trie_workers "$worker_count"
    sleep 10

    # Verify cluster healthy before starting this worker-count run
    assert_cluster_healthy "pre-w${worker_count}" 60 || \
        log_error "WARNING: cluster not fully healthy before w${worker_count} run"

    # Phase 1: Scaled clients subscribe to unique topics simultaneously
    local sub_conns
    sub_conns=$(scale_load 80000 8)
    log_phase "${tag_prefix}_phase1" "${sub_conns} unique topic subscriptions (workers=$worker_count)"
    collect_all_metrics "${tag_prefix}_p1_before"

    local conns_per=$(( sub_conns / num_bench ))
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "sub -h ${hosts} \
             -c ${conns_per} \
             -t 'storm/unique/%i/%c'"
    done
    sleep "$PHASE_DURATION"
    collect_all_metrics "${tag_prefix}_p1_after"
    phase_cleanup "${tag_prefix}_p1"

    # Phase 2: Wildcard subscriptions (scaled)
    local wc_conns
    wc_conns=$(scale_load 20000 8)
    log_phase "${tag_prefix}_phase2" "${wc_conns} wildcard subscriptions (workers=$worker_count)"
    collect_all_metrics "${tag_prefix}_p2_before"

    local wc_per=$(( wc_conns / num_bench ))
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "sub -h ${hosts} \
             -c ${wc_per} \
             -t 'sensor/+/temperature'"
    done
    sleep "$PHASE_DURATION"
    collect_all_metrics "${tag_prefix}_p2_after"
    phase_cleanup "${tag_prefix}_p2"

    # Phase 3: Subscribe/unsubscribe loop (scaled)
    local loop_conns
    loop_conns=$(scale_load 30000 8)
    log_phase "${tag_prefix}_phase3" "${loop_conns} sub/unsub loop x10 (workers=$worker_count)"
    collect_all_metrics "${tag_prefix}_p3_before"

    local loop_per=$(( loop_conns / num_bench ))
    for cycle in $(seq 1 10); do
        log_info "Cycle $cycle/10"
        for i in "${!bench_nodes[@]}"; do
            start_emqtt_bench "$i" \
                "sub -h ${hosts} \
                 -c ${loop_per} \
                 -t 'storm/loop/%i/%c'"
        done
        sleep 10
        stop_all_emqtt_bench
        sleep 2
    done
    collect_all_metrics "${tag_prefix}_p3_after"
    phase_cleanup "${tag_prefix}_p3"

    # Phase 4: Clients modify same shared topics concurrently (scaled)
    local shared_conns
    shared_conns=$(scale_load 10000 8)
    log_phase "${tag_prefix}_phase4" "${shared_conns} clients on 100 shared topics (workers=$worker_count)"
    collect_all_metrics "${tag_prefix}_p4_before"

    local shared_per=$(( shared_conns / num_bench ))
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "sub -h ${hosts} \
             -c ${shared_per} \
             -t 'storm/shared/%i'"
    done
    sleep "$PHASE_DURATION"
    collect_all_metrics "${tag_prefix}_p4_after"
    phase_cleanup "${tag_prefix}_p4"

    # Phase 5: Shared sub clients with pub load (scaled)
    local shared_sub_conns
    shared_sub_conns=$(scale_load 2000 8)
    local pub_rate
    pub_rate=$(scale_load 20000 8)
    log_phase "${tag_prefix}_phase5" "${shared_sub_conns} shared subs, ${pub_rate} msg/s (workers=$worker_count)"
    collect_all_metrics "${tag_prefix}_p5_before"

    local shared_sub_per=$(( shared_sub_conns / num_bench ))
    local rate_per=$(( pub_rate / num_bench ))
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "sub -h ${hosts} \
             -c ${shared_sub_per} \
             -t '\$share/group%i/storm/shared/+'"
    done
    local sub_settle="${SUB_SETTLE_TIME:-15}"
    sleep "$sub_settle"
    wait_subscriptions_converged 60 10 || \
        log_error "WARNING: shared subscriptions may not be fully converged"
    # Publishers
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "pub -h ${hosts} \
             -c $(( rate_per / 10 )) \
             -I 100 \
             -t 'storm/shared/%i' \
             -q 0 \
             -s 128"
    done
    sleep "$PHASE_DURATION"
    collect_all_metrics "${tag_prefix}_p5_after"
    phase_cleanup "${tag_prefix}_p5"

    # Phase 6: Cross-node sub sync latency (use first and last node)
    local last_node_idx=$(( total_nodes - 1 ))
    log_phase "${tag_prefix}_phase6" "Cross-node sync latency: sub on node 0, pub on node ${last_node_idx} (workers=$worker_count)"
    collect_all_metrics "${tag_prefix}_p6_before"

    local host_node0
    host_node0=$(vmq_host_subset 0)
    local host_node_last
    host_node_last=$(vmq_host_subset "$last_node_idx")

    # Subscribe on node 0
    start_emqtt_bench 0 \
        "sub -h ${host_node0} \
         -c 1000 \
         -t 'sync/test/%i'"

    sleep 5

    # Publish on last node
    local sync_start
    sync_start=$(date +%s%N)
    start_emqtt_bench 1 \
        "pub -h ${host_node_last} \
         -c 100 \
         -I 100 \
         -t 'sync/test/%i' \
         -q 1 \
         -s 64"

    sleep 30
    local sync_end
    sync_end=$(date +%s%N)
    echo "sync_latency_ns,$(( sync_end - sync_start ))" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/${tag_prefix}_sync.csv"

    collect_all_metrics "${tag_prefix}_p6_after"
    phase_cleanup "${tag_prefix}_p6"
}

main() {
    require_min_vmq_nodes 2 "cross-node sync test requires at least 2 nodes"
    require_min_bench_nodes 2 "Phase 6 uses bench nodes 0 and 1"
    check_scenario_compat 04

    init_scenario "$SCENARIO_NAME"

    for workers in "${PROFILE_WORKER_COUNTS[@]}"; do
        run_sub_storm_phases "$workers"
    done

    finish_scenario
}

main "$@"
