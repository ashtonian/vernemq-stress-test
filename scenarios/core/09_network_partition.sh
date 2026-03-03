#!/usr/bin/env bash
# 09_network_partition.sh - Network partition (netsplit) chaos benchmark
#
# Simulates a network partition by using iptables DROP rules to isolate
# two groups of nodes, then heals the partition and measures convergence.
#
# Tags: chaos,netsplit
# Min nodes: 5
#
# Required environment:
#   BENCH_NODES  - space-separated bench node IPs
#   VMQ_NODES    - space-separated VerneMQ node IPs (5+ expected)
#   RESULTS_DIR  - output directory
#
# Metrics collected:
#   partition duration, convergence time, message counts per group

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
SCENARIO_LB_MODE="direct_only"

SCENARIO_NAME="09_network_partition"
BASELINE_DURATION="${BASELINE_DURATION:-120}"
PARTITION_DURATION="${PARTITION_DURATION:-120}"  # 2 min partition hold
SETTLE="${SETTLE:-30}"

# ---------------------------------------------------------------------------
# Partition helpers (uses dedicated chain to avoid flushing other rules)
# ---------------------------------------------------------------------------

PARTITION_CHAIN="VMQ_BENCH_PARTITION"

setup_partition_chain() {
    # Create a dedicated iptables chain on all nodes for partition rules
    local total
    total=$(vmq_node_count)
    for (( i=0; i<total; i++ )); do
        ssh_vmq "$i" "sudo iptables -N ${PARTITION_CHAIN} 2>/dev/null || sudo iptables -F ${PARTITION_CHAIN}; \
                       sudo iptables -C INPUT -j ${PARTITION_CHAIN} 2>/dev/null || sudo iptables -I INPUT -j ${PARTITION_CHAIN}; \
                       sudo iptables -C OUTPUT -j ${PARTITION_CHAIN} 2>/dev/null || sudo iptables -I OUTPUT -j ${PARTITION_CHAIN}" || true
    done
}

partition_nodes() {
    # Block traffic between group A and group B nodes using iptables DROP.
    # Arguments: two space-separated lists of node indices.
    local a_indices="$1" b_indices="$2"

    local -a nodes
    read -ra nodes <<< "$VMQ_NODES"

    log_info "Creating partition: group_a=[$a_indices] <-X-> group_b=[$b_indices]"

    for a_idx in $a_indices; do
        for b_idx in $b_indices; do
            local b_ip="${nodes[$b_idx]}"
            ssh_vmq "$a_idx" "sudo iptables -A ${PARTITION_CHAIN} -s ${b_ip} -j DROP && \
                              sudo iptables -A ${PARTITION_CHAIN} -d ${b_ip} -j DROP" || true
        done
    done

    for b_idx in $b_indices; do
        for a_idx in $a_indices; do
            local a_ip="${nodes[$a_idx]}"
            ssh_vmq "$b_idx" "sudo iptables -A ${PARTITION_CHAIN} -s ${a_ip} -j DROP && \
                              sudo iptables -A ${PARTITION_CHAIN} -d ${a_ip} -j DROP" || true
        done
    done
}

heal_partition() {
    # Flush only our partition chain rules, leave other iptables rules intact.
    local total
    total=$(vmq_node_count)

    log_info "Healing partition: flushing ${PARTITION_CHAIN} chain on all $total nodes"
    for (( i=0; i<total; i++ )); do
        ssh_vmq "$i" "sudo iptables -F ${PARTITION_CHAIN}" || true
    done
}

cleanup_partition_chain() {
    # Remove the partition chain entirely (call on exit)
    local total
    total=$(vmq_node_count)
    for (( i=0; i<total; i++ )); do
        ssh_vmq "$i" "sudo iptables -D INPUT -j ${PARTITION_CHAIN} 2>/dev/null; \
                       sudo iptables -D OUTPUT -j ${PARTITION_CHAIN} 2>/dev/null; \
                       sudo iptables -F ${PARTITION_CHAIN} 2>/dev/null; \
                       sudo iptables -X ${PARTITION_CHAIN} 2>/dev/null" || true
    done
}

verify_partition() {
    # Verify that nodes in group A cannot reach nodes in group B.
    local a_indices="$1" b_indices="$2"
    local -a nodes
    read -ra nodes <<< "$VMQ_NODES"
    local blocked=0 total=0

    for a_idx in $a_indices; do
        for b_idx in $b_indices; do
            local b_ip="${nodes[$b_idx]}"
            (( total++ )) || true
            if ! ssh_vmq "$a_idx" "ping -c 1 -W 2 ${b_ip}" >/dev/null 2>&1; then
                (( blocked++ )) || true
            fi
        done
    done

    log_info "Partition verification: ${blocked}/${total} connections blocked"
    if (( blocked == total )); then
        return 0
    else
        log_error "Partition incomplete: only ${blocked}/${total} blocked"
        return 1
    fi
}

count_messages_subset() {
    local tag="$1"; shift
    local indices=("$@")
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}/${tag}"
    mkdir -p "$out_dir"

    local total=0
    for idx in "${indices[@]}"; do
        local count
        count=$(get_vmq_metric_raw "$idx" "mqtt_publish_received")
        echo "node${idx},$count" >> "$out_dir/publish_received.csv"
        (( total += count )) || true
    done
    echo "$total"
}

main() {
    require_min_vmq_nodes 5 "network partition"
    check_scenario_compat 09

    init_scenario "$SCENARIO_NAME"

    # Ensure partition rules are cleaned up on exit (even on failure)
    trap 'cleanup_partition_chain' EXIT
    setup_partition_chain

    local total_nodes
    total_nodes=$(vmq_node_count)
    local hosts
    hosts=$(vmq_host_list)
    local -a bench_nodes
    read -ra bench_nodes <<< "$BENCH_NODES"
    local num_bench=${#bench_nodes[@]}

    # Split cluster into two halves
    local half_a=$(( total_nodes / 2 ))
    local half_b=$(( total_nodes - half_a ))

    local group_a_indices=""
    local group_b_indices=""
    local -a group_a_arr=()
    local -a group_b_arr=()

    for (( i=0; i<half_a; i++ )); do
        group_a_indices="${group_a_indices:+$group_a_indices }$i"
        group_a_arr+=("$i")
    done
    for (( i=half_a; i<total_nodes; i++ )); do
        group_b_indices="${group_b_indices:+$group_b_indices }$i"
        group_b_arr+=("$i")
    done

    log_info "Group A (${half_a} nodes): indices [${group_a_indices}]"
    log_info "Group B (${half_b} nodes): indices [${group_b_indices}]"

    # CSV header
    echo "phase,partition_duration,convergence_seconds,msgs_group_a,msgs_group_b" \
        > "${RESULTS_DIR}/${SCENARIO_TAG}/partition_results.csv"

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
             -t 'partition/t/%i' \
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
            "pub -h ${hosts} \
             -c $(( conns_per / 2 )) \
             -I $(( 1000 * conns_per / 2 / rate_per )) \
             -t 'partition/t/%i' \
             -q 1 \
             -s 256"
    done

    sleep "$BASELINE_DURATION"
    collect_all_metrics "baseline"

    local msgs_a_before
    msgs_a_before=$(count_messages_subset "baseline_group_a" "${group_a_arr[@]}")
    local msgs_b_before
    msgs_b_before=$(count_messages_subset "baseline_group_b" "${group_b_arr[@]}")

    # Phase: Create partition
    log_phase "partition" "Splitting cluster into two groups"
    local partition_start
    partition_start=$(date +%s)
    partition_nodes "$group_a_indices" "$group_b_indices"

    sleep 5
    verify_partition "$group_a_indices" "$group_b_indices" || true
    collect_all_metrics "partition_active"

    # Hold partition
    log_phase "partition_hold" "Holding partition for ${PARTITION_DURATION}s"
    sleep "$PARTITION_DURATION"

    collect_all_metrics "partition_end"
    local msgs_a_during
    msgs_a_during=$(count_messages_subset "partition_group_a" "${group_a_arr[@]}")
    local msgs_b_during
    msgs_b_during=$(count_messages_subset "partition_group_b" "${group_b_arr[@]}")

    local partition_end
    partition_end=$(date +%s)
    local partition_duration=$(( partition_end - partition_start ))

    # Phase: Heal partition
    log_phase "heal" "Healing network partition"
    local heal_start
    heal_start=$(date +%s)
    heal_partition

    wait_cluster_ready "$total_nodes" 180
    local heal_done
    heal_done=$(date +%s)
    local convergence_seconds=$(( heal_done - heal_start ))

    sleep "$SETTLE"
    collect_all_metrics "healed"

    local msgs_a_after
    msgs_a_after=$(count_messages_subset "healed_group_a" "${group_a_arr[@]}")
    local msgs_b_after
    msgs_b_after=$(count_messages_subset "healed_group_b" "${group_b_arr[@]}")

    # Write CSV row
    echo "partition,${partition_duration},${convergence_seconds},${msgs_a_during},${msgs_b_during}" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/partition_results.csv"
    echo "healed,0,0,${msgs_a_after},${msgs_b_after}" \
        >> "${RESULTS_DIR}/${SCENARIO_TAG}/partition_results.csv"

    log_info "Partition duration: ${partition_duration}s, convergence: ${convergence_seconds}s"

    # Summary
    {
        echo "partition_duration_seconds,$partition_duration"
        echo "convergence_seconds,$convergence_seconds"
        echo "msgs_group_a_before,$msgs_a_before"
        echo "msgs_group_b_before,$msgs_b_before"
        echo "msgs_group_a_after,$msgs_a_after"
        echo "msgs_group_b_after,$msgs_b_after"
    } >> "${RESULTS_DIR}/${SCENARIO_TAG}/summary.csv"

    finish_scenario
}

main "$@"
