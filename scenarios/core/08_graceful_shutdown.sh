#!/usr/bin/env bash
# 08_graceful_shutdown.sh - Graceful vs ungraceful shutdown comparison
#
# Compares message loss and recovery time between graceful (systemctl stop)
# and ungraceful (SIGKILL) node shutdown under load.
#
# Message loss is measured by comparing the expected publish rate (measured
# during baseline) against actual deliveries during the shutdown window.
#
# Tags: chaos,graceful
# Min nodes: 3
#
# Required environment:
#   BENCH_NODES  - space-separated bench node IPs
#   VMQ_NODES    - space-separated VerneMQ node IPs (3+ expected)
#   RESULTS_DIR  - output directory
#
# Metrics collected:
#   drain time, message loss, recovery time per shutdown type

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
SCENARIO_LB_MODE="direct_only"

SCENARIO_NAME="08_graceful_shutdown"
BASELINE_DURATION="${BASELINE_DURATION:-120}"
SETTLE="${SETTLE:-30}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-120}"
MEASUREMENT_WINDOW="${MEASUREMENT_WINDOW:-60}"  # seconds to measure delivery rate

count_delivered() {
    # Count mqtt_publish_sent (messages delivered to subscribers) across all live nodes
    local -a nodes
    read -ra nodes <<< "$VMQ_NODES"
    local total=0
    for i in "${!nodes[@]}"; do
        local count
        count=$(get_vmq_metric_raw "$i" "mqtt_publish_sent")
        (( total += count )) || true
    done
    echo "$total"
}

count_published() {
    # Count mqtt_publish_received (messages published by clients) across all live nodes
    local -a nodes
    read -ra nodes <<< "$VMQ_NODES"
    local total=0
    for i in "${!nodes[@]}"; do
        local count
        count=$(get_vmq_metric_raw "$i" "mqtt_publish_received")
        (( total += count )) || true
    done
    echo "$total"
}

wait_node_stopped() {
    local idx="$1" timeout="$2"
    local elapsed=0
    while (( elapsed < timeout )); do
        if ! ssh_vmq "$idx" "pgrep -f beam.smp" >/dev/null 2>&1; then
            echo "$elapsed"
            return 0
        fi
        sleep 2
        (( elapsed += 2 ))
    done
    echo "$timeout"
}

# Measure delivery rate over a window (msgs delivered per second)
measure_delivery_rate() {
    local window="$1"
    local d1 d2
    d1=$(count_delivered)
    sleep "$window"
    d2=$(count_delivered)
    echo $(( (d2 - d1) / window ))
}

run_shutdown_test() {
    local shutdown_type="$1" expected_rate="$2"
    local total_nodes
    total_nodes=$(vmq_node_count)

    # Use last tail node
    local -a target_indices
    mapfile -t target_indices < <(tail_node_indices 1)
    local target_idx="${target_indices[0]}"

    log_phase "${shutdown_type}_shutdown" "${shutdown_type} shutdown of node ${target_idx}"
    collect_all_metrics "${shutdown_type}_before"

    # Snapshot counters before shutdown
    local published_before delivered_before
    published_before=$(count_published)
    delivered_before=$(count_delivered)

    local stop_start
    stop_start=$(date +%s)

    if [[ "$shutdown_type" == "graceful" ]]; then
        ssh_vmq "$target_idx" "sudo systemctl stop vernemq"
        local drain_seconds
        drain_seconds=$(wait_node_stopped "$target_idx" "$DRAIN_TIMEOUT")
    else
        kill_vmq_node "$target_idx"
        local drain_seconds=0
    fi

    local stop_done
    stop_done=$(date +%s)
    local stop_time=$(( stop_done - stop_start ))

    # Measure delivery during degraded state
    log_info "Measuring delivery rate during degraded state (${MEASUREMENT_WINDOW}s)..."
    local degraded_rate
    degraded_rate=$(measure_delivery_rate "$MEASUREMENT_WINDOW")

    collect_all_metrics "${shutdown_type}_degraded"

    # Snapshot counters after degraded window
    local published_during delivered_during
    published_during=$(count_published)
    delivered_during=$(count_delivered)

    local total_published=$(( published_during - published_before ))
    local total_delivered=$(( delivered_during - delivered_before ))
    local msgs_lost=$(( total_published - total_delivered ))
    (( msgs_lost < 0 )) && msgs_lost=0

    # Restart node
    log_phase "${shutdown_type}_recovery" "Restarting node ${target_idx} after ${shutdown_type} shutdown"
    local recovery_start
    recovery_start=$(date +%s)
    start_vmq_node "$target_idx"
    wait_cluster_ready "$total_nodes" 180
    local recovery_done
    recovery_done=$(date +%s)
    local recovery_seconds=$(( recovery_done - recovery_start ))

    # Wait for traffic to stabilize after recovery
    sleep "$SETTLE"
    collect_all_metrics "${shutdown_type}_recovered"

    # Measure restored delivery rate
    local restored_rate
    restored_rate=$(measure_delivery_rate 15)

    # Write CSV row
    echo "${shutdown_type},${drain_seconds},${stop_time},${total_published},${total_delivered},${msgs_lost},${degraded_rate},${restored_rate},${recovery_seconds}" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/shutdown_results.csv"

    log_info "${shutdown_type}: drain=${drain_seconds}s stop=${stop_time}s published=${total_published} delivered=${total_delivered} lost=${msgs_lost} degraded=${degraded_rate}msg/s restored=${restored_rate}msg/s recovery=${recovery_seconds}s"
}

main() {
    require_min_vmq_nodes 3 "graceful shutdown"
    check_scenario_compat 08

    init_scenario "$SCENARIO_NAME"

    local total_nodes
    total_nodes=$(vmq_node_count)
    local hosts
    hosts=$(vmq_host_list)
    local -a bench_nodes
    read -ra bench_nodes <<< "$BENCH_NODES"
    local num_bench=${#bench_nodes[@]}

    # CSV header
    echo "type,drain_seconds,stop_time,total_published,total_delivered,msgs_lost,degraded_rate,restored_rate,recovery_seconds" \
        > "${RESULTS_DIR}/${SCENARIO_TAG}/shutdown_results.csv"

    # Baseline load (cross-node routing)
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

    log_phase "baseline" "Establishing baseline load (cross-node, QoS 1)"
    local conns
    conns=$(scale_load 80000 10)
    local rate
    rate=$(scale_load 20000 10)
    local conns_per=$(( conns / num_bench ))
    local rate_per=$(( rate / num_bench ))

    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "sub -h ${sub_hosts} \
             -c $(( conns_per / 2 )) \
             -t 'shutdown/t/%i' \
             -q 1"
    done

    # Wait for subscription propagation
    local sub_settle="${SUB_SETTLE_TIME:-20}"
    log_info "Waiting ${sub_settle}s for subscription propagation..."
    sleep "$sub_settle"
    wait_subscriptions_converged 90 10 || \
        log_error "WARNING: subscriptions may not be fully converged"

    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "pub -h ${pub_hosts} \
             -c $(( conns_per / 2 )) \
             -I $(( 1000 * conns_per / 2 / rate_per )) \
             -t 'shutdown/t/%i' \
             -q 1 \
             -s 256"
    done

    sleep "$BASELINE_DURATION"
    collect_all_metrics "baseline"

    # Measure baseline delivery rate
    log_info "Measuring baseline delivery rate..."
    local baseline_rate
    baseline_rate=$(measure_delivery_rate 15)
    log_info "Baseline delivery rate: ${baseline_rate} msg/s"

    if (( baseline_rate < 100 )); then
        log_error "FATAL: baseline traffic not flowing (${baseline_rate} msg/s). Aborting."
        finish_scenario
        exit 1
    fi

    echo "baseline_rate,${baseline_rate}" >> "${RESULTS_DIR}/${SCENARIO_TAG}/summary.csv"

    # Graceful shutdown test
    run_shutdown_test "graceful" "$baseline_rate"

    # Let cluster stabilize between tests
    sleep "$SETTLE"

    # Ungraceful shutdown test
    run_shutdown_test "ungraceful" "$baseline_rate"

    finish_scenario
}

main "$@"
