#!/usr/bin/env bash
# 10_slow_node.sh - Slow/degraded node chaos benchmark
#
# Uses Linux tc/netem to inject network latency, jitter, and packet loss
# on a single node and measures the impact on cluster throughput and latency.
#
# Tags: chaos,latency
# Min nodes: 3
#
# Required environment:
#   BENCH_NODES  - space-separated bench node IPs
#   VMQ_NODES    - space-separated VerneMQ node IPs (3+ expected)
#   RESULTS_DIR  - output directory
#
# Metrics collected:
#   throughput, latency_p99 per degradation level

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

SCENARIO_NAME="10_slow_node"
BASELINE_DURATION="${BASELINE_DURATION:-120}"
PHASE_DURATION="${PHASE_DURATION:-120}"  # 2 min per degradation level
SETTLE="${SETTLE:-30}"

# ---------------------------------------------------------------------------
# Network degradation helpers
# ---------------------------------------------------------------------------

add_network_delay() {
    local idx="$1" delay_ms="$2" jitter_ms="${3:-0}" loss_pct="${4:-0}"
    log_info "Adding network delay on node ${idx}: delay=${delay_ms}ms jitter=${jitter_ms}ms loss=${loss_pct}%"
    ssh_vmq "$idx" "sudo tc qdisc add dev eth0 root netem delay ${delay_ms}ms ${jitter_ms}ms loss ${loss_pct}%" || true
}

remove_network_delay() {
    local idx="$1"
    log_info "Removing network delay on node ${idx}"
    ssh_vmq "$idx" "sudo tc qdisc del dev eth0 root netem" 2>/dev/null || true
}

get_throughput() {
    local tag="$1"
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}/${tag}"
    mkdir -p "$out_dir"

    local -a nodes
    read -ra nodes <<< "$VMQ_NODES"
    local total=0
    for i in "${!nodes[@]}"; do
        local count
        count=$(ssh_vmq "$i" "$VMQ_ADMIN metrics show" 2>/dev/null \
            | grep "mqtt_publish_received " | awk '{print $NF}' || echo 0)
        echo "node${i},$count" >> "$out_dir/publish_received.csv"
        (( total += count )) || true
    done
    echo "$total"
}

get_latency_p99() {
    # Collect p99 publish latency from Prometheus if available
    local tag="$1"
    if [[ -n "$PROMETHEUS_URL" ]]; then
        local p99
        p99=$(curl -s "${PROMETHEUS_URL}/api/v1/query?query=histogram_quantile(0.99,rate(mqtt_publish_latency_bucket[1m]))" 2>/dev/null \
            | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['data']['result'][0]['value'][1] if r['data']['result'] else '0')" 2>/dev/null \
            || echo "0")
        echo "$p99"
    else
        echo "0"
    fi
}

run_degradation_phase() {
    local phase_name="$1" delay_ms="$2" jitter_ms="$3" loss_pct="$4" target_idx="$5"

    log_phase "$phase_name" "delay=${delay_ms}ms jitter=${jitter_ms}ms loss=${loss_pct}%"

    add_network_delay "$target_idx" "$delay_ms" "$jitter_ms" "$loss_pct"

    collect_metrics "${phase_name}_before"
    local throughput_before
    throughput_before=$(get_throughput "${phase_name}_t_before")

    sleep "$PHASE_DURATION"

    collect_metrics "${phase_name}_after"
    local throughput_after
    throughput_after=$(get_throughput "${phase_name}_t_after")
    local latency_p99
    latency_p99=$(get_latency_p99 "$phase_name")

    # Approximate throughput as delta during the phase
    local throughput=$(( throughput_after - throughput_before ))

    # Write CSV row
    echo "${phase_name},${delay_ms},${jitter_ms},${loss_pct},${throughput},${latency_p99}" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/slow_node_results.csv"

    log_info "Phase ${phase_name}: throughput=${throughput}, p99=${latency_p99}"
}

main() {
    require_min_vmq_nodes 3 "slow node"
    init_scenario "$SCENARIO_NAME"

    local total_nodes
    total_nodes=$(vmq_node_count)
    local hosts
    hosts=$(vmq_host_list)
    local -a bench_nodes
    read -ra bench_nodes <<< "$BENCH_NODES"
    local num_bench=${#bench_nodes[@]}

    # Use last tail node as the degraded node
    local -a target_indices
    mapfile -t target_indices < <(tail_node_indices 1)
    local target_idx="${target_indices[0]}"
    log_info "Target slow node: index ${target_idx}"

    # CSV header
    echo "phase,delay_ms,jitter_ms,loss_pct,throughput,latency_p99" \
        > "${RESULTS_DIR}/${SCENARIO_TAG}/slow_node_results.csv"

    # Baseline load
    log_phase "baseline" "Establishing baseline load on all ${total_nodes} nodes"
    local conns
    conns=$(scale_load 80000 10)
    local rate
    rate=$(scale_load 20000 10)
    local conns_per=$(( conns / num_bench ))
    local rate_per=$(( rate / num_bench ))

    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "sub -h ${hosts} \
             -c $(( conns_per / 2 )) \
             -t 'slow/t/#' \
             -q 1"
    done
    sleep 5

    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "pub -h ${hosts} \
             -c $(( conns_per / 2 )) \
             -I $(( 1000 * conns_per / 2 / rate_per )) \
             -t 'slow/t/%i' \
             -q 1 \
             -s 256"
    done

    sleep "$BASELINE_DURATION"
    collect_metrics "baseline"

    # Record baseline throughput
    local baseline_throughput
    baseline_throughput=$(get_throughput "baseline_throughput")
    local baseline_p99
    baseline_p99=$(get_latency_p99 "baseline")
    echo "baseline,0,0,0,${baseline_throughput},${baseline_p99}" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/slow_node_results.csv"

    # Degradation phases on target node
    run_degradation_phase "delay_50ms" 50 10 0 "$target_idx"
    run_degradation_phase "delay_200ms_loss1" 200 50 1 "$target_idx"

    # Remove before applying next level (netem replaces don't stack cleanly)
    remove_network_delay "$target_idx"
    sleep 5

    run_degradation_phase "delay_500ms_loss5" 500 100 5 "$target_idx"

    # Recovery: remove all degradation
    log_phase "recovery" "Removing all network degradation"
    remove_network_delay "$target_idx"
    sleep "$PHASE_DURATION"
    collect_metrics "recovery"

    local recovery_throughput
    recovery_throughput=$(get_throughput "recovery_throughput")
    local recovery_p99
    recovery_p99=$(get_latency_p99 "recovery")
    echo "recovery,0,0,0,${recovery_throughput},${recovery_p99}" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/slow_node_results.csv"

    log_info "Recovery: throughput=${recovery_throughput}, p99=${recovery_p99}"

    finish_scenario
}

main "$@"
