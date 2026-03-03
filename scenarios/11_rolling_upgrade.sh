#!/usr/bin/env bash
# 11_rolling_upgrade.sh - Rolling upgrade benchmark
#
# Performs a rolling upgrade of all cluster nodes while under load,
# measuring per-node downtime and cluster rejoin time.
#
# Tags: upgrade
# Min nodes: 3
#
# Required environment:
#   BENCH_NODES         - space-separated bench node IPs
#   VMQ_NODES           - space-separated VerneMQ node IPs (3+ expected)
#   RESULTS_DIR         - output directory
#   UPGRADE_TO_VERSION  - target VerneMQ package version (e.g. "2.0.1")
#     or
#   UPGRADE_TO_SOURCE   - path/URL to VerneMQ package to install
#
# Metrics collected:
#   per-node stop/deploy/start/rejoin times

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

SCENARIO_NAME="11_rolling_upgrade"
BASELINE_DURATION="${BASELINE_DURATION:-120}"
POST_UPGRADE_DURATION="${POST_UPGRADE_DURATION:-300}"  # 5 min post-upgrade steady state
SETTLE="${SETTLE:-30}"

deploy_upgrade() {
    local idx="$1"
    if [[ -n "${UPGRADE_TO_VERSION:-}" ]]; then
        log_info "Upgrading node ${idx} to version ${UPGRADE_TO_VERSION}"
        ssh_vmq "$idx" "sudo yum install -y vernemq-${UPGRADE_TO_VERSION} || \
                        sudo apt-get install -y vernemq=${UPGRADE_TO_VERSION} || \
                        sudo rpm -Uvh /tmp/vernemq-${UPGRADE_TO_VERSION}.rpm" 2>/dev/null || true
    elif [[ -n "${UPGRADE_TO_SOURCE:-}" ]]; then
        log_info "Upgrading node ${idx} from source: ${UPGRADE_TO_SOURCE}"
        ssh_vmq "$idx" "sudo rpm -Uvh ${UPGRADE_TO_SOURCE} || \
                        sudo dpkg -i ${UPGRADE_TO_SOURCE}" 2>/dev/null || true
    fi
}

main() {
    require_min_vmq_nodes 3 "rolling upgrade"

    # Require upgrade target
    if [[ -z "${UPGRADE_TO_VERSION:-}" && -z "${UPGRADE_TO_SOURCE:-}" ]]; then
        log_error "Either UPGRADE_TO_VERSION or UPGRADE_TO_SOURCE must be set"
        exit 1
    fi

    init_scenario "$SCENARIO_NAME"

    local total_nodes
    total_nodes=$(vmq_node_count)
    local hosts
    hosts=$(vmq_host_list)
    local -a bench_nodes
    read -ra bench_nodes <<< "$BENCH_NODES"
    local num_bench=${#bench_nodes[@]}

    # CSV header
    echo "node_idx,stop_time,deploy_time,start_time,rejoin_seconds" \
        > "${RESULTS_DIR}/${SCENARIO_TAG}/upgrade_results.csv"

    # Baseline load
    log_phase "baseline" "Establishing baseline load on ${total_nodes} nodes"
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
             -t 'upgrade/t/#' \
             -q 1"
    done
    sleep 5

    for i in "${!bench_nodes[@]}"; do
        start_emqtt_bench "$i" \
            "pub -h ${hosts} \
             -c $(( conns_per / 2 )) \
             -I $(( 1000 * conns_per / 2 / rate_per )) \
             -t 'upgrade/t/%i' \
             -q 1 \
             -s 256"
    done

    sleep "$BASELINE_DURATION"
    collect_metrics "baseline"

    # Rolling upgrade: upgrade each node serially
    log_info "=== Starting rolling upgrade of ${total_nodes} nodes ==="
    for (( idx=0; idx<total_nodes; idx++ )); do
        log_phase "upgrade_node${idx}" "Upgrading node ${idx}"

        # Stop node
        local stop_start
        stop_start=$(date +%s)
        ssh_vmq "$idx" "sudo systemctl stop vernemq"
        local stop_done
        stop_done=$(date +%s)
        local stop_time=$(( stop_done - stop_start ))

        # Deploy new version
        local deploy_start
        deploy_start=$(date +%s)
        deploy_upgrade "$idx"
        local deploy_done
        deploy_done=$(date +%s)
        local deploy_time=$(( deploy_done - deploy_start ))

        # Start node
        local start_start
        start_start=$(date +%s)
        start_vmq_node "$idx"
        local start_done
        start_done=$(date +%s)
        local start_time=$(( start_done - start_start ))

        # Wait for cluster rejoin
        local rejoin_start
        rejoin_start=$(date +%s)
        wait_cluster_ready "$total_nodes" 180
        local rejoin_done
        rejoin_done=$(date +%s)
        local rejoin_seconds=$(( rejoin_done - rejoin_start ))

        collect_metrics "upgrade_node${idx}_done"

        # Write CSV row
        echo "${idx},${stop_time},${deploy_time},${start_time},${rejoin_seconds}" \
            >> "${RESULTS_DIR}/${SCENARIO_TAG}/upgrade_results.csv"

        log_info "Node ${idx} upgraded: stop=${stop_time}s deploy=${deploy_time}s start=${start_time}s rejoin=${rejoin_seconds}s"
    done

    # Post-upgrade steady state
    log_phase "post_upgrade" "Post-upgrade steady state measurement (${POST_UPGRADE_DURATION}s)"
    sleep "$POST_UPGRADE_DURATION"
    collect_metrics "post_upgrade"

    # Summary
    {
        echo "total_nodes,$total_nodes"
        echo "upgrade_target,${UPGRADE_TO_VERSION:-${UPGRADE_TO_SOURCE:-unknown}}"
    } >> "${RESULTS_DIR}/${SCENARIO_TAG}/summary.csv"

    finish_scenario
}

main "$@"
