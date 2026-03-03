#!/usr/bin/env bash
# 06_connection_storm.sh - Connection storm benchmark
#
# Tests cluster resilience under rapid connection churn from "bad actor" devices
# while maintaining a steady baseline of real pub/sub traffic. Measures the
# impact of TCP connection storms on legitimate message throughput and latency.
#
# Design:
#   1. Establish baseline pub/sub load (mixed QoS 0 + QoS 1) — runs throughout
#   2. Overlay escalating connection churn: rapid connect/disconnect cycles
#   3. Measure baseline degradation during each churn intensity
#   4. Recovery measurement after churn stops
#
# Min nodes: 3
#
# Required environment:
#   BENCH_NODES  - space-separated bench node IPs
#   VMQ_NODES    - space-separated VerneMQ node IPs (3+ required)
#   RESULTS_DIR  - output directory
#
# Metrics collected:
#   baseline throughput before/during/after churn, latency p50/p95/p99,
#   CONNACK rate, socket open/close rates, memory, CPU

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
SCENARIO_LB_MODE="supported"

SCENARIO_NAME="06_connection_storm"
BASELINE_WARMUP="${BASELINE_WARMUP:-120}"       # 2 min baseline warmup
CHURN_PHASE_DURATION="${CHURN_PHASE_DURATION:-120}"  # 2 min per churn level
CHURN_HOLD="${CHURN_HOLD:-5}"                   # seconds to hold churn connections before killing
RECOVERY_DURATION="${RECOVERY_DURATION:-120}"    # 2 min recovery observation

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Snapshot of throughput counters (publish_received total across cluster)
snapshot_throughput() {
    local tag="$1"
    get_vmq_metric_sum "mqtt_publish_received"
}

# Run a single churn burst: connect N clients rapidly, hold briefly, kill them.
# Uses targeted PID kill instead of stop_emqtt_bench to avoid killing baseline traffic.
run_churn_burst() {
    local bench_idx="$1" hosts="$2" count="$3" rate="$4" hold="$5" prefix="$6"
    local churn_pid
    churn_pid=$(start_emqtt_bench "$bench_idx" \
        "conn -h ${hosts} \
         -c ${count} \
         -R ${rate} \
         --prefix '${prefix}'")
    sleep "$hold"
    stop_emqtt_bench_pid "$bench_idx" "$churn_pid"
    # Brief pause for TCP teardown
    sleep 1
}

# Run repeated churn cycles for a duration, collecting metrics periodically
run_churn_phase() {
    local phase_name="$1" hosts="$2" conns_per_burst="$3" burst_rate="$4" hold_time="$5" duration="$6"
    local -a bench_arr
    read -ra bench_arr <<< "$BENCH_NODES"
    local num_bench=${#bench_arr[@]}
    local burst_per=$(( conns_per_burst / num_bench ))
    local rate_per=$(( burst_rate / num_bench ))

    local elapsed=0
    local cycle=0

    log_info "Churn phase ${phase_name}: ${conns_per_burst} conns/burst at ${burst_rate}/s, hold=${hold_time}s"

    while (( elapsed < duration )); do
        (( cycle++ )) || true

        # Launch churn burst on all bench nodes simultaneously
        for i in "${!bench_arr[@]}"; do
            run_churn_burst "$i" "$hosts" "$burst_per" "$rate_per" "$hold_time" "churn_${phase_name}_c${cycle}_" &
        done
        wait

        # Periodic metrics collection (every ~4 cycles)
        if (( cycle % 4 == 0 )); then
            collect_all_metrics "${phase_name}_c${cycle}"
        fi

        local cycle_time=$(( hold_time + 2 ))  # hold + teardown pause
        (( elapsed += cycle_time ))
    done

    log_info "Churn phase ${phase_name} complete: ${cycle} cycles in ~${elapsed}s"
}

collect_connection_stats() {
    local tag="$1"
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}/${tag}"
    mkdir -p "$out_dir"

    local -a nodes
    read -ra nodes <<< "$VMQ_NODES"
    for i in "${!nodes[@]}"; do
        ssh_vmq "$i" "$VMQ_ADMIN metrics show" 2>/dev/null \
            | grep -E "(mqtt_connack|socket_open|socket_close)" \
            > "$out_dir/conn_metrics_node${i}.txt" || true
    done
}

# Record baseline traffic health: throughput delta over a short window
measure_baseline_health() {
    local tag="$1" window="${2:-10}"
    local t1 t2
    t1=$(snapshot_throughput "${tag}_t1")
    sleep "$window"
    t2=$(snapshot_throughput "${tag}_t2")
    local rate=$(( (t2 - t1) / window ))
    echo "${tag},${rate},${t1},${t2}" >> "${RESULTS_DIR}/${SCENARIO_TAG}/baseline_health.csv"
    log_info "Baseline health [${tag}]: ~${rate} msg/s"
    echo "$rate"
}

main() {
    require_min_vmq_nodes 3 "connection storm needs at least 3 nodes"
    check_scenario_compat 06

    init_scenario "$SCENARIO_NAME"

    local total_nodes
    total_nodes=$(vmq_node_count)
    local hosts
    hosts=$(vmq_host_list)
    local -a bench_nodes
    read -ra bench_nodes <<< "$BENCH_NODES"
    local num_bench=${#bench_nodes[@]}

    # Split VMQ nodes: first half for publishers, second half for subscribers
    local pub_count=$(( (total_nodes + 1) / 2 ))
    local pub_hosts
    pub_hosts=$(vmq_host_first_n "$pub_count")
    local sub_hosts=""
    for (( si=pub_count; si<total_nodes; si++ )); do
        local node
        node=$(_node_at VMQ_NODES "$si")
        sub_hosts="${sub_hosts:+${sub_hosts},}${node}"
    done
    [[ -z "$sub_hosts" ]] && sub_hosts="$hosts"

    # CSV headers
    echo "phase,rate_msgs_per_sec,counter_start,counter_end" \
        > "${RESULTS_DIR}/${SCENARIO_TAG}/baseline_health.csv"
    echo "phase,churn_conns,churn_rate,hold_time,cycles" \
        > "${RESULTS_DIR}/${SCENARIO_TAG}/churn_phases.csv"

    # =====================================================================
    # Phase 1: Establish baseline pub/sub traffic (mixed QoS, cross-node)
    # =====================================================================
    local base_conns
    base_conns=$(scale_load 40000 10)
    local base_rate
    base_rate=$(scale_load 10000 10)
    local conns_per=$(( base_conns / num_bench ))
    local rate_per=$(( base_rate / num_bench ))

    log_phase "baseline_setup" "Establishing baseline: ${base_conns} pub+sub, ${base_rate} msg/s mixed QoS (cross-node)"
    collect_all_metrics "baseline_before"

    # QoS 0 subscribers (half the sub connections)
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "sub -h ${sub_hosts} \
             -c $(( conns_per / 2 )) \
             -t 'storm/qos0/%i' \
             -q 0 \
             --prefix 'base_q0_sub_'"
    done

    # QoS 1 subscribers (other half)
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "sub -h ${sub_hosts} \
             -c $(( conns_per / 2 )) \
             -t 'storm/qos1/%i' \
             -q 1 \
             --prefix 'base_q1_sub_'"
    done

    # Wait for subscription propagation
    local sub_settle="${SUB_SETTLE_TIME:-20}"
    log_info "Waiting ${sub_settle}s for subscription propagation..."
    sleep "$sub_settle"
    wait_subscriptions_converged 90 10 || \
        log_error "WARNING: subscriptions may not be fully converged"

    # QoS 0 publishers (half the pub connections)
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "pub -h ${pub_hosts} \
             -c $(( conns_per / 4 )) \
             -I $(( 1000 * conns_per / 4 / (rate_per / 2) )) \
             -t 'storm/qos0/%i' \
             -q 0 \
             -s 256 \
             --prefix 'base_q0_pub_'"
    done

    # QoS 1 publishers (other half)
    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "pub -h ${pub_hosts} \
             -c $(( conns_per / 4 )) \
             -I $(( 1000 * conns_per / 4 / (rate_per / 2) )) \
             -t 'storm/qos1/%i' \
             -q 1 \
             -s 256 \
             --prefix 'base_q1_pub_'"
    done

    # Warmup: let baseline stabilize
    log_phase "baseline_warmup" "Warming up baseline for ${BASELINE_WARMUP}s"
    sleep "$BASELINE_WARMUP"
    collect_all_metrics "baseline_stable"
    collect_connection_stats "baseline_stable"

    # Verify baseline is actually delivering messages
    local baseline_rate
    baseline_rate=$(measure_baseline_health "baseline" 15)
    if (( baseline_rate < 100 )); then
        log_error "FATAL: baseline traffic not flowing (${baseline_rate} msg/s). Aborting."
        finish_scenario
        exit 1
    fi

    # =====================================================================
    # Phase 2: Moderate churn — bad actors connecting at moderate rate
    # =====================================================================
    local churn_conns_moderate
    churn_conns_moderate=$(scale_load 5000 10)
    local churn_rate_moderate
    churn_rate_moderate=$(scale_load 2000 10)
    log_phase "churn_moderate" "Moderate churn: ${churn_conns_moderate} conns/burst, ${churn_rate_moderate}/s, hold=${CHURN_HOLD}s"
    collect_all_metrics "churn_moderate_before"

    run_churn_phase "moderate" "$hosts" "$churn_conns_moderate" "$churn_rate_moderate" "$CHURN_HOLD" "$CHURN_PHASE_DURATION"

    collect_all_metrics "churn_moderate_after"
    collect_connection_stats "churn_moderate_stats"
    local moderate_rate
    moderate_rate=$(measure_baseline_health "during_moderate" 15)
    echo "moderate,${churn_conns_moderate},${churn_rate_moderate},${CHURN_HOLD}" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/churn_phases.csv"

    # =====================================================================
    # Phase 3: Heavy churn — rapid fire connections, very short hold
    # =====================================================================
    local churn_conns_heavy
    churn_conns_heavy=$(scale_load 15000 10)
    local churn_rate_heavy
    churn_rate_heavy=$(scale_load 8000 10)
    local heavy_hold=2
    log_phase "churn_heavy" "Heavy churn: ${churn_conns_heavy} conns/burst, ${churn_rate_heavy}/s, hold=${heavy_hold}s"
    collect_all_metrics "churn_heavy_before"

    run_churn_phase "heavy" "$hosts" "$churn_conns_heavy" "$churn_rate_heavy" "$heavy_hold" "$CHURN_PHASE_DURATION"

    collect_all_metrics "churn_heavy_after"
    collect_connection_stats "churn_heavy_stats"
    local heavy_rate
    heavy_rate=$(measure_baseline_health "during_heavy" 15)
    echo "heavy,${churn_conns_heavy},${churn_rate_heavy},${heavy_hold}" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/churn_phases.csv"

    # =====================================================================
    # Phase 4: Extreme burst — massive simultaneous connect attempts
    # =====================================================================
    local churn_conns_extreme
    churn_conns_extreme=$(scale_load 30000 10)
    local churn_rate_extreme
    churn_rate_extreme=$(scale_load 30000 10)  # all at once
    local extreme_hold=1
    log_phase "churn_extreme" "Extreme burst: ${churn_conns_extreme} conns at ${churn_rate_extreme}/s, hold=${extreme_hold}s"
    collect_all_metrics "churn_extreme_before"

    run_churn_phase "extreme" "$hosts" "$churn_conns_extreme" "$churn_rate_extreme" "$extreme_hold" "$CHURN_PHASE_DURATION"

    collect_all_metrics "churn_extreme_after"
    collect_connection_stats "churn_extreme_stats"
    local extreme_rate
    extreme_rate=$(measure_baseline_health "during_extreme" 15)
    echo "extreme,${churn_conns_extreme},${churn_rate_extreme},${extreme_hold}" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/churn_phases.csv"

    # =====================================================================
    # Phase 5: Recovery — churn stopped, measure baseline restoration
    # =====================================================================
    log_phase "recovery" "Churn stopped. Observing baseline recovery for ${RECOVERY_DURATION}s"
    collect_all_metrics "recovery_start"

    local recovery_elapsed=0
    local recovery_interval=30
    while (( recovery_elapsed < RECOVERY_DURATION )); do
        sleep "$recovery_interval"
        (( recovery_elapsed += recovery_interval ))
        measure_baseline_health "recovery_t${recovery_elapsed}" 10
    done

    collect_all_metrics "recovery_end"
    collect_connection_stats "recovery_stats"
    local recovery_rate
    recovery_rate=$(measure_baseline_health "recovery_final" 15)

    # =====================================================================
    # Summary
    # =====================================================================
    {
        echo "baseline_rate,$baseline_rate"
        echo "moderate_churn_rate,$moderate_rate"
        echo "heavy_churn_rate,$heavy_rate"
        echo "extreme_churn_rate,$extreme_rate"
        echo "recovery_rate,$recovery_rate"
        echo "baseline_degradation_moderate_pct,$(( baseline_rate > 0 ? (baseline_rate - moderate_rate) * 100 / baseline_rate : 0 ))"
        echo "baseline_degradation_heavy_pct,$(( baseline_rate > 0 ? (baseline_rate - heavy_rate) * 100 / baseline_rate : 0 ))"
        echo "baseline_degradation_extreme_pct,$(( baseline_rate > 0 ? (baseline_rate - extreme_rate) * 100 / baseline_rate : 0 ))"
        echo "recovery_vs_baseline_pct,$(( baseline_rate > 0 ? recovery_rate * 100 / baseline_rate : 0 ))"
    } >> "${RESULTS_DIR}/${SCENARIO_TAG}/summary.csv"

    log_info "========================================="
    log_info "Connection Storm Results"
    log_info "========================================="
    log_info "Baseline:  ${baseline_rate} msg/s"
    log_info "Moderate:  ${moderate_rate} msg/s (during churn)"
    log_info "Heavy:     ${heavy_rate} msg/s (during churn)"
    log_info "Extreme:   ${extreme_rate} msg/s (during churn)"
    log_info "Recovery:  ${recovery_rate} msg/s"
    log_info "========================================="

    finish_scenario
}

main "$@"
