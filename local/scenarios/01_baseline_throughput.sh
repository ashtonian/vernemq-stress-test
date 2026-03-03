#!/usr/bin/env bash
# 01_baseline_throughput.sh - Scaled-down baseline throughput for local Docker
#
# QoS 0 then QoS 1, 60s per phase.
# ~1250 conns, ~625 msg/s (scaled from 10k/5k @ 8 nodes via LOCAL_SCALE=0.125)
# Subs on vmq2,vmq3; pubs on vmq1 — forces cross-node routing.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common_local.sh"

SCENARIO_NAME="01_baseline_throughput"
DURATION="${DURATION:-60}"

run_load_phase() {
    local phase="$1" conns="$2" rate="$3" qos="$4" tag="$5"
    local total_nodes
    total_nodes=$(vmq_node_count)

    log_phase "$phase" "${conns} pub+sub conns, ${rate} msg/s, QoS ${qos} (cross-node)"
    collect_metrics "${tag}_before"

    # Split nodes: first ceil(N/2) for publishers, rest for subscribers
    local pub_node_count=$(( (total_nodes + 1) / 2 ))
    local sub_node_count=$(( total_nodes - pub_node_count ))
    if (( sub_node_count < 1 )); then
        sub_node_count=1
        pub_node_count=1
    fi
    local pub_hosts
    pub_hosts=$(vmq_host_first_n "$pub_node_count")
    local sub_hosts=""
    local sub_start=$(( total_nodes - sub_node_count ))
    for (( si=sub_start; si<total_nodes; si++ )); do
        local node
        node=$(_vmq_container_at "$si")
        if [[ -n "$sub_hosts" ]]; then
            sub_hosts="${sub_hosts},${node}"
        else
            sub_hosts="${node}"
        fi
    done

    # Start subscribers
    start_emqtt_bench \
        "sub -h ${sub_hosts} \
         -c ${conns} \
         -t 'bench/t/%i' \
         -q ${qos}"

    # Wait for subscriptions to propagate
    log_info "Waiting 10s for subscription metadata propagation..."
    sleep 10
    wait_subscriptions_converged 60 5 || \
        log_error "WARNING: subscriptions may not be fully converged"

    # Start publishers — interval = 1000 * conns / rate (ms between msgs per client)
    local interval_ms
    if (( rate > 0 )); then
        interval_ms=$(( 1000 * conns / rate ))
        (( interval_ms < 1 )) && interval_ms=1
    else
        interval_ms=1000
    fi
    start_emqtt_bench \
        "pub -h ${pub_hosts} \
         -c ${conns} \
         -I ${interval_ms} \
         -t 'bench/t/%i' \
         -q ${qos} \
         -s 256"

    log_info "Load running for ${DURATION}s..."
    sleep "$DURATION"

    collect_metrics "${tag}_after"
    phase_cleanup "$phase"
}

main() {
    init_scenario "$SCENARIO_NAME"

    # --- QoS 0 runs (load scaled via LOCAL_SCALE) ---
    log_info "=== QoS 0 Runs ==="
    run_load_phase "phase1_qos0" "$(scale_load_local 10000 8)" "$(scale_load_local 5000 8)" 0 "p1_qos0"
    run_load_phase "phase2_qos0" "$(scale_load_local 50000 8)" "$(scale_load_local 25000 8)" 0 "p2_qos0"
    run_load_phase "phase3_qos0" "$(scale_load_local 100000 8)" "$(scale_load_local 50000 8)" 0 "p3_qos0"

    # --- QoS 1 runs ---
    log_info "=== QoS 1 Runs ==="
    run_load_phase "phase1_qos1" "$(scale_load_local 10000 8)" "$(scale_load_local 5000 8)" 1 "p1_qos1"
    run_load_phase "phase2_qos1" "$(scale_load_local 50000 8)" "$(scale_load_local 25000 8)" 1 "p2_qos1"
    run_load_phase "phase3_qos1" "$(scale_load_local 100000 8)" "$(scale_load_local 50000 8)" 1 "p3_qos1"

    finish_scenario
}

main "$@"
