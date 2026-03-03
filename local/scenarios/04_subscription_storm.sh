#!/usr/bin/env bash
# 04_subscription_storm.sh - Subscription storm benchmark (local Docker)
#
# Critical regression test — validates routing offload fix.
# Tests reg_trie_workers=1, 8, 16.
# Per worker count: unique topic subs -> wildcard subs -> cross-node pub/sub sync
# 60s per phase, tracks cluster_bytes_dropped sum.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common_local.sh"

SCENARIO_NAME="04_subscription_storm"
PHASE_DURATION="${PHASE_DURATION:-60}"

set_reg_trie_workers() {
    local workers="$1"
    log_info "Setting reg_trie_workers=$workers on all nodes"
    local -a containers
    read -ra containers <<< "$VMQ_CONTAINERS"
    for i in "${!containers[@]}"; do
        exec_vmq "$i" "$VMQ_ADMIN" set reg_trie_workers="$workers" || true
    done
}

run_sub_storm_phases() {
    local worker_count="$1"
    local tag_prefix="w${worker_count}"
    local hosts
    hosts=$(vmq_host_list)
    local total_nodes
    total_nodes=$(vmq_node_count)

    log_info "=== Run with reg_trie_workers=$worker_count ==="
    set_reg_trie_workers "$worker_count"
    sleep 5

    assert_cluster_healthy "pre-w${worker_count}" 60 || \
        log_error "WARNING: cluster not fully healthy before w${worker_count} run"

    # Phase 1: Unique topic subscriptions (scaled down)
    local sub_conns
    sub_conns=$(scale_load_local 80000 8)
    log_phase "${tag_prefix}_phase1" "${sub_conns} unique topic subscriptions (workers=$worker_count)"
    collect_metrics "${tag_prefix}_p1_before"

    start_emqtt_bench \
        "sub -h ${hosts} \
         -c ${sub_conns} \
         -t 'storm/unique/%i/%c'"
    sleep "$PHASE_DURATION"
    collect_metrics "${tag_prefix}_p1_after"
    phase_cleanup "${tag_prefix}_p1"

    # Phase 2: Wildcard subscriptions (scaled down)
    local wc_conns
    wc_conns=$(scale_load_local 20000 8)
    log_phase "${tag_prefix}_phase2" "${wc_conns} wildcard subscriptions (workers=$worker_count)"
    collect_metrics "${tag_prefix}_p2_before"

    start_emqtt_bench \
        "sub -h ${hosts} \
         -c ${wc_conns} \
         -t 'sensor/+/temperature'"
    sleep "$PHASE_DURATION"
    collect_metrics "${tag_prefix}_p2_after"
    phase_cleanup "${tag_prefix}_p2"

    # Phase 3: Subscribe/unsubscribe loop (scaled down)
    local loop_conns
    loop_conns=$(scale_load_local 30000 8)
    log_phase "${tag_prefix}_phase3" "${loop_conns} sub/unsub loop x10 (workers=$worker_count)"
    collect_metrics "${tag_prefix}_p3_before"

    for cycle in $(seq 1 10); do
        log_info "Cycle $cycle/10"
        start_emqtt_bench \
            "sub -h ${hosts} \
             -c ${loop_conns} \
             -t 'storm/loop/%i/%c'"
        sleep 10
        stop_all_emqtt_bench
        sleep 2
    done
    collect_metrics "${tag_prefix}_p3_after"
    phase_cleanup "${tag_prefix}_p3"

    # Phase 4: Shared topics concurrently (scaled down)
    local shared_conns
    shared_conns=$(scale_load_local 10000 8)
    log_phase "${tag_prefix}_phase4" "${shared_conns} clients on 100 shared topics (workers=$worker_count)"
    collect_metrics "${tag_prefix}_p4_before"

    start_emqtt_bench \
        "sub -h ${hosts} \
         -c ${shared_conns} \
         -t 'storm/shared/%i'"
    sleep "$PHASE_DURATION"
    collect_metrics "${tag_prefix}_p4_after"
    phase_cleanup "${tag_prefix}_p4"

    # Phase 5: Shared subscriptions + publish load (scaled down)
    local shared_sub_conns
    shared_sub_conns=$(scale_load_local 2000 8)
    local pub_rate
    pub_rate=$(scale_load_local 20000 8)
    log_phase "${tag_prefix}_phase5" "${shared_sub_conns} shared subs, ${pub_rate} msg/s (workers=$worker_count)"
    collect_metrics "${tag_prefix}_p5_before"

    start_emqtt_bench \
        "sub -h ${hosts} \
         -c ${shared_sub_conns} \
         -t '\$share/group1/storm/shared/+'"
    sleep 5

    # Publishers
    local pub_conns=$(( pub_rate / 10 ))
    (( pub_conns < 1 )) && pub_conns=1
    start_emqtt_bench \
        "pub -h ${hosts} \
         -c ${pub_conns} \
         -I 100 \
         -t 'storm/shared/%i' \
         -q 0 \
         -s 128"
    sleep "$PHASE_DURATION"
    collect_metrics "${tag_prefix}_p5_after"
    phase_cleanup "${tag_prefix}_p5"

    # Phase 6: Cross-node sync latency (sub on node 0, pub on last node)
    local last_node_idx=$(( total_nodes - 1 ))
    log_phase "${tag_prefix}_phase6" "Cross-node sync: sub on node 0, pub on node ${last_node_idx} (workers=$worker_count)"
    collect_metrics "${tag_prefix}_p6_before"

    local host_node0
    host_node0=$(vmq_host_subset 0)
    local host_node_last
    host_node_last=$(vmq_host_subset "$last_node_idx")

    # Subscribe on node 0
    start_emqtt_bench \
        "sub -h ${host_node0} \
         -c 100 \
         -t 'sync/test/%i'"
    sleep 5

    # Publish on last node
    local sync_start
    sync_start=$(date +%s%N)
    start_emqtt_bench \
        "pub -h ${host_node_last} \
         -c 10 \
         -I 100 \
         -t 'sync/test/%i' \
         -q 1 \
         -s 64"
    sleep 30
    local sync_end
    sync_end=$(date +%s%N)
    echo "sync_latency_ns,$(( sync_end - sync_start ))" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/${tag_prefix}_sync.csv"

    collect_metrics "${tag_prefix}_p6_after"
    phase_cleanup "${tag_prefix}_p6"

    # Report cluster_bytes_dropped for this worker run
    local drops
    drops=$(get_vmq_metric_sum "cluster_bytes_dropped")
    log_info "cluster_bytes_dropped (workers=$worker_count): $drops"
    echo "w${worker_count}_cluster_bytes_dropped,$drops" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/summary.csv"
}

main() {
    init_scenario "$SCENARIO_NAME"

    for workers in 1 8 16; do
        run_sub_storm_phases "$workers"
    done

    # Final summary
    log_info "=== cluster_bytes_dropped summary ==="
    if [[ -f "${RESULTS_DIR}/${SCENARIO_TAG}/summary.csv" ]]; then
        cat "${RESULTS_DIR}/${SCENARIO_TAG}/summary.csv"
    fi

    finish_scenario
}

main "$@"
