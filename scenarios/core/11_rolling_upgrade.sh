#!/usr/bin/env bash
# 11_rolling_upgrade.sh - Rolling upgrade benchmark
#
# Performs a rolling upgrade of all cluster nodes while under load,
# measuring per-node downtime and cluster rejoin time.
#
# Supports three upgrade modes:
#   1. Package version (UPGRADE_TO_VERSION) - yum/apt install
#   2. Local package (UPGRADE_TO_SOURCE) - rpm/dpkg from file
#   3. Git repo+ref (UPGRADE_TO_REPO + UPGRADE_TO_REF) - build from source
#
# For git mode, the target version is pre-built once on node 0 before the
# rolling upgrade loop. Each node upgrade just extracts the pre-built tarball.
#
# Tags: upgrade
# Min nodes: 3
#
# Required environment:
#   BENCH_NODES         - space-separated bench node IPs
#   VMQ_NODES           - space-separated VerneMQ node IPs (3+ expected)
#   RESULTS_DIR         - output directory
#
#   One of:
#   UPGRADE_TO_VERSION  - target VerneMQ package version (e.g. "2.0.1")
#   UPGRADE_TO_SOURCE   - path/URL to VerneMQ package to install
#   UPGRADE_TO_REPO + UPGRADE_TO_REF - git repo URL and ref to build
#
# Metrics collected:
#   per-node stop/deploy/start/rejoin times, throughput before/during/after

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
SCENARIO_LB_MODE="supported"

SCENARIO_NAME="11_rolling_upgrade"
BASELINE_DURATION="${BASELINE_DURATION:-120}"
POST_UPGRADE_DURATION="${POST_UPGRADE_DURATION:-300}"  # 5 min post-upgrade steady state
SETTLE="${SETTLE:-30}"

# VerneMQ install directory (must match ansible vernemq role default)
VMQ_INSTALL_DIR="${VMQ_INSTALL_DIR:-/opt/vernemq}"

# ---------------------------------------------------------------------------
# Pre-build the upgrade tarball from git (runs once before rolling upgrade)
# ---------------------------------------------------------------------------

UPGRADE_TARBALL="/tmp/vernemq-upgrade.tar.gz"

prebuild_git_upgrade() {
    local repo="$1" ref="$2"
    local build_dir="/opt/vernemq-upgrade-src"

    log_info "Pre-building upgrade from ${repo} @ ${ref} on node 0..."

    # Clone, build, create tarball on build node (node 0)
    ssh_vmq 0 "sudo rm -rf ${build_dir} && \
        sudo git clone '${repo}' '${build_dir}' && \
        cd '${build_dir}' && \
        sudo git checkout '${ref}' && \
        make rel 2>&1" || {
        log_error "FATAL: Failed to build upgrade from ${repo}@${ref}"
        return 1
    }
    ssh_vmq 0 "sudo tar czf ${UPGRADE_TARBALL} -C '${build_dir}/_build/default/rel' vernemq"

    # Capture version
    local upgrade_version
    upgrade_version=$(ssh_vmq 0 "cd ${build_dir} && git describe --tags --always" 2>/dev/null || echo "unknown")
    log_info "Upgrade tarball built: version=${upgrade_version}"

    # Fetch tarball to controller for distribution
    local build_node
    build_node=$(_node_at VMQ_NODES 0)
    # shellcheck disable=SC2086
    scp ${SSH_OPTS} "${SSH_USER}@${build_node}:${UPGRADE_TARBALL}" "${UPGRADE_TARBALL}" 2>/dev/null

    echo "$upgrade_version"
}

deploy_upgrade() {
    local idx="$1"
    if [[ -n "${UPGRADE_TO_VERSION:-}" ]]; then
        log_info "Upgrading node ${idx} to version ${UPGRADE_TO_VERSION}"
        ssh_vmq "$idx" "sudo yum install -y vernemq-${UPGRADE_TO_VERSION} 2>/dev/null || \
                        sudo apt-get install -y vernemq=${UPGRADE_TO_VERSION} 2>/dev/null || \
                        sudo rpm -Uvh /tmp/vernemq-${UPGRADE_TO_VERSION}.rpm 2>/dev/null" || true
    elif [[ -n "${UPGRADE_TO_SOURCE:-}" ]]; then
        log_info "Upgrading node ${idx} from package: ${UPGRADE_TO_SOURCE}"
        ssh_vmq "$idx" "sudo rpm -Uvh ${UPGRADE_TO_SOURCE} 2>/dev/null || \
                        sudo dpkg -i ${UPGRADE_TO_SOURCE} 2>/dev/null" || true
    elif [[ -n "${UPGRADE_TO_REPO:-}" ]]; then
        log_info "Upgrading node ${idx} from pre-built git tarball"
        local target_node
        target_node=$(_node_at VMQ_NODES "$idx")
        # Copy pre-built tarball to target node
        # shellcheck disable=SC2086
        scp ${SSH_OPTS} "${UPGRADE_TARBALL}" "${SSH_USER}@${target_node}:${UPGRADE_TARBALL}" 2>/dev/null
        # Extract over existing install (preserving config and data)
        ssh_vmq "$idx" "sudo tar xzf ${UPGRADE_TARBALL} -C '${VMQ_INSTALL_DIR}' --strip-components=1 \
            --exclude='etc/vernemq.conf' --exclude='data'" || true
    fi
}

# Measure throughput delta over a window
measure_throughput() {
    local tag="$1" window="${2:-15}"
    local t1 t2
    t1=$(get_vmq_metric_sum "mqtt_publish_received")
    sleep "$window"
    t2=$(get_vmq_metric_sum "mqtt_publish_received")
    local rate=$(( (t2 - t1) / window ))
    echo "${tag},${rate}" >> "${RESULTS_DIR}/${SCENARIO_TAG}/throughput_timeline.csv"
    log_info "Throughput [${tag}]: ~${rate} msg/s"
    echo "$rate"
}

main() {
    require_min_vmq_nodes 3 "rolling upgrade"
    check_scenario_compat 11

    # Require upgrade target
    if [[ -z "${UPGRADE_TO_VERSION:-}" && -z "${UPGRADE_TO_SOURCE:-}" && -z "${UPGRADE_TO_REPO:-}" ]]; then
        log_error "One of UPGRADE_TO_VERSION, UPGRADE_TO_SOURCE, or UPGRADE_TO_REPO+UPGRADE_TO_REF must be set"
        exit 1
    fi

    if [[ -n "${UPGRADE_TO_REPO:-}" && -z "${UPGRADE_TO_REF:-}" ]]; then
        log_error "UPGRADE_TO_REF must be set when using UPGRADE_TO_REPO"
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

    # CSV headers
    echo "node_idx,stop_time,deploy_time,start_time,rejoin_seconds" \
        > "${RESULTS_DIR}/${SCENARIO_TAG}/upgrade_results.csv"
    echo "phase,throughput_msg_per_sec" \
        > "${RESULTS_DIR}/${SCENARIO_TAG}/throughput_timeline.csv"

    # Determine upgrade target label
    local upgrade_target="${UPGRADE_TO_VERSION:-${UPGRADE_TO_SOURCE:-unknown}}"

    # Pre-build git upgrade before starting load (expensive, don't want it during test)
    if [[ -n "${UPGRADE_TO_REPO:-}" ]]; then
        log_phase "prebuild" "Pre-building upgrade from git: ${UPGRADE_TO_REPO} @ ${UPGRADE_TO_REF}"
        upgrade_target=$(prebuild_git_upgrade "${UPGRADE_TO_REPO}" "${UPGRADE_TO_REF}")
        log_info "Upgrade pre-built: ${upgrade_target}"
    fi

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
             -t 'upgrade/t/%i' \
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
             -t 'upgrade/t/%i' \
             -q 1 \
             -s 256"
    done

    sleep "$BASELINE_DURATION"
    collect_all_metrics "baseline"

    # Verify baseline traffic is flowing
    local baseline_rate
    baseline_rate=$(measure_throughput "baseline" 15)
    if (( baseline_rate < 100 )); then
        log_error "FATAL: baseline traffic not flowing (${baseline_rate} msg/s). Aborting."
        finish_scenario
        exit 1
    fi

    # Rolling upgrade: upgrade each node serially
    log_info "=== Starting rolling upgrade of ${total_nodes} nodes ==="
    for (( idx=0; idx<total_nodes; idx++ )); do
        log_phase "upgrade_node${idx}" "Upgrading node ${idx}"

        # Measure throughput before this node upgrade
        measure_throughput "pre_node${idx}" 10

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

        collect_all_metrics "upgrade_node${idx}_done"

        # Measure throughput after this node upgrade
        measure_throughput "post_node${idx}" 10

        # Write CSV row
        echo "${idx},${stop_time},${deploy_time},${start_time},${rejoin_seconds}" \
            >> "${RESULTS_DIR}/${SCENARIO_TAG}/upgrade_results.csv"

        log_info "Node ${idx} upgraded: stop=${stop_time}s deploy=${deploy_time}s start=${start_time}s rejoin=${rejoin_seconds}s"
    done

    # Post-upgrade steady state
    log_phase "post_upgrade" "Post-upgrade steady state measurement (${POST_UPGRADE_DURATION}s)"
    sleep "$POST_UPGRADE_DURATION"
    collect_all_metrics "post_upgrade"

    local post_rate
    post_rate=$(measure_throughput "post_upgrade" 15)

    # Summary
    {
        echo "total_nodes,$total_nodes"
        echo "upgrade_target,$upgrade_target"
        echo "baseline_rate,$baseline_rate"
        echo "post_upgrade_rate,$post_rate"
    } >> "${RESULTS_DIR}/${SCENARIO_TAG}/summary.csv"

    finish_scenario
}

main "$@"
