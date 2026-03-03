#!/usr/bin/env bash
# run_comparison.sh - Run A/B benchmark comparison
#
# Deploys stock VerneMQ release, runs benchmarks, then deploys integration
# branch from source, runs the same benchmarks, and saves both result sets.
#
# Usage:
#   ./run_comparison.sh --baseline-version 2.1.2 --source /path/to/vernemq \
#       --scenarios standard --cluster-size 3 --load-multiplier 3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ANSIBLE_DIR="${BENCH_DIR}/ansible"

# Defaults
BASELINE_VERSION=""
SOURCE_PATH=""
SCENARIOS="standard"
CLUSTER_SIZE=""
LOAD_MULTIPLIER=3
RESULTS_BASE="${BENCH_DIR}/results"
DURATION="${DURATION:-180}"
STABILITY_DURATION="${STABILITY_DURATION:-300}"

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Options:
  --baseline-version VER  Stock VerneMQ version for baseline (e.g. 2.1.2)
  --source PATH           Path to integration branch source
  --scenarios LIST        Scenario selection (default: standard)
  --cluster-size N        Number of VMQ nodes (default: auto from inventory)
  --load-multiplier N     Scale all loads by N (default: 3)
  --duration SECS         Duration per phase (default: 180)
  -h, --help              Show this help
USAGE
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --baseline-version) BASELINE_VERSION="$2"; shift 2 ;;
        --source)           SOURCE_PATH="$2"; shift 2 ;;
        --scenarios)        SCENARIOS="$2"; shift 2 ;;
        --cluster-size)     CLUSTER_SIZE="$2"; shift 2 ;;
        --load-multiplier)  LOAD_MULTIPLIER="$2"; shift 2 ;;
        --duration)         DURATION="$2"; shift 2 ;;
        -h|--help)          usage ;;
        *)                  echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$BASELINE_VERSION" ]]; then
    echo "ERROR: --baseline-version is required"
    usage
fi

if [[ -z "$SOURCE_PATH" ]]; then
    echo "ERROR: --source is required"
    usage
fi

SOURCE_PATH="$(cd "$SOURCE_PATH" && pwd)"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
INVENTORY="${ANSIBLE_DIR}/inventory/hosts"

log() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

run_ansible() {
    local playbook="$1"; shift
    log "Ansible: $playbook $*"
    (cd "${ANSIBLE_DIR}" && ansible-playbook -i inventory/hosts "${playbook}" "$@") 2>&1
}

# =========================================================================
# Parse inventory for node IPs and set environment
# =========================================================================
setup_env_from_inventory() {
    if [[ ! -f "$INVENTORY" ]]; then
        log "ERROR: Inventory not found at $INVENTORY"
        exit 1
    fi

    # Extract VMQ node IPs (lines under [vmq_nodes] section)
    local vmq_ips=""
    local in_vmq=false
    while IFS= read -r line; do
        if [[ "$line" == "[vmq_nodes]" ]]; then
            in_vmq=true; continue
        elif [[ "$line" == "["* ]]; then
            in_vmq=false; continue
        fi
        if $in_vmq && [[ -n "$line" && "$line" != "#"* ]]; then
            local ip
            ip=$(echo "$line" | awk '{print $1}')
            if [[ -n "$ip" ]]; then
                vmq_ips="${vmq_ips:+$vmq_ips }${ip}"
            fi
        fi
    done < "$INVENTORY"

    # Extract bench node IPs
    local bench_ips=""
    local in_bench=false
    while IFS= read -r line; do
        if [[ "$line" == "[bench_nodes]" ]]; then
            in_bench=true; continue
        elif [[ "$line" == "["* ]]; then
            in_bench=false; continue
        fi
        if $in_bench && [[ -n "$line" && "$line" != "#"* ]]; then
            local ip
            ip=$(echo "$line" | awk '{print $1}')
            if [[ -n "$ip" ]]; then
                bench_ips="${bench_ips:+$bench_ips }${ip}"
            fi
        fi
    done < "$INVENTORY"

    # Extract monitor IP
    local monitor_ip=""
    local in_monitor=false
    while IFS= read -r line; do
        if [[ "$line" == "[monitor]" ]]; then
            in_monitor=true; continue
        elif [[ "$line" == "["* ]]; then
            in_monitor=false; continue
        fi
        if $in_monitor && [[ -n "$line" && "$line" != "#"* ]]; then
            monitor_ip=$(echo "$line" | awk '{print $1}')
            break
        fi
    done < "$INVENTORY"

    export VMQ_NODES="$vmq_ips"
    export BENCH_NODES="$bench_ips"
    export MONITOR_HOST="$monitor_ip"
    export SSH_KEY="${SSH_KEY:-${HOME}/.ssh/vernemq-bench-home-ops.pem}"
    export SSH_USER="${SSH_USER:-ec2-user}"

    # Auto-detect cluster size if not specified
    if [[ -z "$CLUSTER_SIZE" ]]; then
        local -a nodes
        read -ra nodes <<< "$VMQ_NODES"
        CLUSTER_SIZE="${#nodes[@]}"
    fi

    log "VMQ_NODES:   $VMQ_NODES"
    log "BENCH_NODES: $BENCH_NODES"
    log "MONITOR:     $MONITOR_HOST"
    log "CLUSTER_SIZE: $CLUSTER_SIZE"
}

# =========================================================================
# Run A: Baseline (stock release)
# =========================================================================
run_baseline() {
    local tag="baseline-${BASELINE_VERSION}-${TIMESTAMP}"
    local results_dir="${RESULTS_BASE}/${tag}"
    mkdir -p "$results_dir"

    log "========================================="
    log "RUN A: Baseline VerneMQ ${BASELINE_VERSION}"
    log "========================================="

    # Teardown any previous
    run_ansible "teardown_cluster.yml" || true

    # Deploy stock release
    run_ansible "deploy_vernemq.yml" \
        -e "build_mode=release" \
        -e "vernemq_version=${BASELINE_VERSION}" \
        -e "vernemq_version_family=2.x"

    run_ansible "deploy_bench.yml"
    run_ansible "deploy_monitoring.yml" || true
    run_ansible "configure_cluster.yml" \
        -e "vmq_admin_cmd=/usr/sbin/vmq-admin"

    # Run scenarios
    log "Running baseline scenarios..."
    export RESULTS_DIR="$results_dir"
    export VMQ_ADMIN="sudo /usr/sbin/vmq-admin"
    export VMQ_VERSION="$BASELINE_VERSION"
    export LOAD_MULTIPLIER
    export DURATION
    export STABILITY_DURATION
    export BENCH_COMPARISON_MODE=1
    export EXPORT_PROM=0

    run_scenarios

    log "Baseline complete: $results_dir"
    echo "$tag"
}

# =========================================================================
# Run B: Integration (source build)
# =========================================================================
run_integration() {
    local tag="integration-${TIMESTAMP}"
    local results_dir="${RESULTS_BASE}/${tag}"
    mkdir -p "$results_dir"

    log "========================================="
    log "RUN B: Integration branch (from source)"
    log "========================================="

    # Teardown previous
    run_ansible "teardown_cluster.yml" || true

    # Deploy from source
    run_ansible "deploy_vernemq.yml" \
        -e "build_mode=source" \
        -e "vernemq_local_src_dir=${SOURCE_PATH}" \
        -e "vernemq_version_family=integration"

    run_ansible "deploy_bench.yml"
    run_ansible "deploy_monitoring.yml" || true
    run_ansible "configure_cluster.yml" \
        -e "vmq_admin_cmd=/opt/vernemq/bin/vmq-admin"

    # Run scenarios
    log "Running integration scenarios..."
    export RESULTS_DIR="$results_dir"
    export VMQ_ADMIN="sudo /opt/vernemq/bin/vmq-admin"
    export VMQ_VERSION="integration"
    export LOAD_MULTIPLIER
    export DURATION
    export STABILITY_DURATION
    export BENCH_COMPARISON_MODE=1
    export EXPORT_PROM=0

    run_scenarios

    log "Integration complete: $results_dir"
    echo "$tag"
}

# =========================================================================
# Scenario runner
# =========================================================================
run_scenarios() {
    local scenario_dir="${BENCH_DIR}/scenarios"

    # Resolve scenario list
    local scenario_list
    case "$SCENARIOS" in
        standard)
            local suite
            suite=$(bash "${scenario_dir}/suite.sh" "${CLUSTER_SIZE:-3}" "${VMQ_VERSION}")
            IFS=',' read -ra nums <<< "$suite"
            ;;
        *)
            IFS=',' read -ra nums <<< "$SCENARIOS"
            ;;
    esac

    for num in "${nums[@]}"; do
        num=$(echo "$num" | xargs)
        local padded
        padded=$(printf "%02d" "$num")
        local script
        script=$(ls "${scenario_dir}/${padded}_"*.sh 2>/dev/null | head -1)
        if [[ -z "$script" ]]; then
            log "WARNING: No scenario matching ${padded}"
            continue
        fi

        local scenario_name
        scenario_name=$(basename "$script" .sh)
        export SCENARIO_TAG="$scenario_name"

        log "--- Running: $scenario_name ---"
        if bash "$script" 2>&1 | tee -a "${RESULTS_DIR}/run.log"; then
            log "--- $scenario_name: PASSED ---"
        else
            log "--- $scenario_name: FAILED ---"
        fi
    done
}

# =========================================================================
# Main
# =========================================================================

setup_env_from_inventory

log "========================================="
log "VerneMQ A/B Comparison"
log "========================================="
log "Baseline:    ${BASELINE_VERSION}"
log "Integration: source @ ${SOURCE_PATH}"
log "Multiplier:  ${LOAD_MULTIPLIER}x"
log "Scenarios:   ${SCENARIOS}"
log "Duration:    ${DURATION}s per phase"
log "Cluster:     ${CLUSTER_SIZE} nodes"
log "========================================="

baseline_tag=$(run_baseline)
integration_tag=$(run_integration)

log "========================================="
log "Comparison Complete"
log "========================================="
log "Baseline results:    ${RESULTS_BASE}/${baseline_tag}"
log "Integration results: ${RESULTS_BASE}/${integration_tag}"
log "========================================="
