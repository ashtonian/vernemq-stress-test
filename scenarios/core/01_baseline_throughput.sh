#!/usr/bin/env bash
# 01_baseline_throughput.sh - Baseline throughput benchmark
#
# Measures raw throughput and latency on a cluster with all features
# at their defaults. Runs increasing load levels with both QoS 0 and QoS 1.
# Load scales dynamically based on the number of VMQ nodes available.
#
# Required environment:
#   BENCH_NODES  - space-separated bench node IPs
#   VMQ_NODES    - space-separated VerneMQ node IPs (1+ required)
#   RESULTS_DIR  - output directory
#
# Metrics collected:
#   msgs/sec, publish latency p50/p95/p99, CPU, memory per node

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
SCENARIO_LB_MODE="supported"

SCENARIO_NAME="01_baseline_throughput"
DURATION="${DURATION:-300}"  # 5 minutes per phase

run_load_phase() {
    local phase="$1" conns="$2" rate="$3" qos="$4" tag="$5"
    local -a bench_nodes
    read -ra bench_nodes <<< "$BENCH_NODES"
    local num_bench=${#bench_nodes[@]}
    local total_nodes
    total_nodes=$(vmq_node_count)

    log_phase "$phase" "${conns} pub+sub conns, ${rate} msg/s, QoS ${qos} (cross-node)"
    collect_all_metrics "${tag}_before"

    # Split VMQ nodes: first ceil(N/2) for publishers, rest for subscribers
    # This forces all message delivery to cross the cluster
    local pub_node_count=$(( (total_nodes + 1) / 2 ))
    local sub_node_count=$(( total_nodes - pub_node_count ))
    if (( sub_node_count < 1 )); then
        # Single node: pub and sub on same node
        sub_node_count=1
        pub_node_count=1
    fi
    local pub_hosts
    pub_hosts=$(vmq_host_first_n "$pub_node_count")
    local sub_hosts=""
    local sub_start=$(( total_nodes - sub_node_count ))
    for (( si=sub_start; si<total_nodes; si++ )); do
        local node
        node=$(_node_at VMQ_NODES "$si")
        if [[ -n "$sub_hosts" ]]; then
            sub_hosts="${sub_hosts},${node}"
        else
            sub_hosts="${node}"
        fi
    done

    local conns_per=$(( conns / num_bench ))
    local rate_per=$(( rate / num_bench ))

    # Start subscribers first on all bench nodes, targeting sub VMQ nodes
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "sub -h ${sub_hosts} \
             -c ${conns_per} \
             -t 'bench/t/%i' \
             -q ${qos}"
    done

    # Wait for subscription metadata to propagate across cluster via SWC gossip.
    # First wait a minimum settle time, then verify convergence via metrics.
    local sub_settle="${SUB_SETTLE_TIME:-15}"
    log_info "Waiting ${sub_settle}s minimum for subscription metadata propagation..."
    sleep "$sub_settle"
    wait_subscriptions_converged 90 10 || \
        log_error "WARNING: subscriptions may not be fully converged, continuing..."

    # Start publishers on all bench nodes, targeting pub VMQ nodes
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "pub -h ${pub_hosts} \
             -c ${conns_per} \
             -I $(( 1000 * conns_per / rate_per )) \
             -t 'bench/t/%i' \
             -q ${qos} \
             -s 256"
    done

    log_info "Load running for ${DURATION}s..."
    sleep "$DURATION"

    collect_all_metrics "${tag}_after"
    phase_cleanup "$phase"
}

main() {
    require_min_vmq_nodes 1
    check_scenario_compat 01

    init_scenario "$SCENARIO_NAME"

    # --- QoS 0 runs (load scaled from 8-node reference) ---
    log_info "=== QoS 0 Runs ==="

    run_load_phase "phase1_qos0" "$(scale_load 10000 8)" "$(scale_load 5000 8)" 0 "p1_qos0"
    run_load_phase "phase2_qos0" "$(scale_load 50000 8)" "$(scale_load 25000 8)" 0 "p2_qos0"
    run_load_phase "phase3_qos0" "$(scale_load 100000 8)" "$(scale_load 50000 8)" 0 "p3_qos0"

    # --- QoS 1 runs ---
    log_info "=== QoS 1 Runs ==="

    run_load_phase "phase1_qos1" "$(scale_load 10000 8)" "$(scale_load 5000 8)" 1 "p1_qos1"
    run_load_phase "phase2_qos1" "$(scale_load 50000 8)" "$(scale_load 25000 8)" 1 "p2_qos1"
    run_load_phase "phase3_qos1" "$(scale_load 100000 8)" "$(scale_load 50000 8)" 1 "p3_qos1"

    finish_scenario
}

main "$@"
