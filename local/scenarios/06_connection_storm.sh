#!/usr/bin/env bash
# 06_connection_storm.sh - Connection storm benchmark (local Docker)
#
# Ramp -> burst -> stability hold (120s).
# Scaled ~8x down from remote scenario via LOCAL_SCALE.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common_local.sh"

SCENARIO_NAME="06_connection_storm"
STABILITY_DURATION="${STABILITY_DURATION:-120}"

collect_connection_stats() {
    local tag="$1"
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}/${tag}"
    mkdir -p "$out_dir"

    local -a containers
    read -ra containers <<< "$VMQ_CONTAINERS"
    for i in "${!containers[@]}"; do
        local metrics
        metrics=$(exec_vmq "$i" "$VMQ_ADMIN" metrics show 2>/dev/null || echo "")
        echo "$metrics" | grep -E "(mqtt_connack|socket_open|socket_close|balance)" \
            > "$out_dir/conn_metrics_node${i}.txt" || true
    done
}

main() {
    init_scenario "$SCENARIO_NAME"

    local total_nodes
    total_nodes=$(vmq_node_count)
    local hosts
    hosts=$(vmq_host_list)
    local hosts_1_2
    hosts_1_2=$(vmq_host_subset 0 1)

    # Phase 1: Ramp connections (scaled down)
    local total_conns
    total_conns=$(scale_load_local 100000 10)
    local ramp_rate
    ramp_rate=$(scale_load_local 10000 10)
    log_phase "phase1" "Ramp 0 to ${total_conns} connections at ${ramp_rate}/sec"
    collect_metrics "p1_before"

    start_emqtt_bench \
        "conn -h ${hosts} \
         -c ${total_conns} \
         -R ${ramp_rate} \
         -k 60"
    sleep 15
    collect_metrics "p1_after"
    collect_connection_stats "p1_stats"

    # Phase 2: Burst connections (scaled down)
    local burst_conns
    burst_conns=$(scale_load_local 50000 10)
    local burst_rate=$(( burst_conns / 5 ))
    (( burst_rate < 1 )) && burst_rate=1
    log_phase "phase2" "Burst ${burst_conns} connections in 5 seconds"
    collect_metrics "p2_before"

    start_emqtt_bench \
        "conn -h ${hosts} \
         -c ${burst_conns} \
         -R ${burst_rate} \
         -k 60 \
         --prefix 'burst_'"
    sleep 10
    collect_metrics "p2_after"
    collect_connection_stats "p2_stats"

    # Phase 3: Targeted connections to vmq1+vmq2 (may trigger rejection)
    local targeted_conns
    targeted_conns=$(scale_load_local 30000 10)
    log_phase "phase3" "${targeted_conns} connections to vmq1+vmq2 only"
    collect_metrics "p3_before"

    local targeted_rate
    targeted_rate=$(scale_load_local 50000 10)
    start_emqtt_bench \
        "conn -h ${hosts_1_2} \
         -c ${targeted_conns} \
         -R ${targeted_rate} \
         -k 60 \
         --prefix 'targeted_'"
    sleep 15
    collect_metrics "p3_after"
    collect_connection_stats "p3_stats"

    # Phase 4: Hold connections for stability
    log_phase "phase4" "Hold connections for ${STABILITY_DURATION}s (stability)"
    collect_metrics "p4_start"

    local interval=30
    local elapsed=0
    while (( elapsed < STABILITY_DURATION )); do
        collect_connection_stats "p4_t${elapsed}"
        sleep "$interval"
        (( elapsed += interval ))
    done

    collect_metrics "p4_end"
    collect_connection_stats "p4_final"

    phase_cleanup "final"
    finish_scenario
}

main "$@"
