#!/usr/bin/env bash
# run_comparison.sh - Run A/B benchmark comparison
#
# Deploys baseline VerneMQ from a git repo+ref, runs benchmarks, then deploys
# candidate from another repo+ref, runs the same benchmarks, and saves both
# result sets.
#
# Usage:
#   ./run_comparison.sh --baseline-repo https://github.com/vernemq/vernemq.git --baseline-ref v2.1.2 \
#       --candidate-repo https://github.com/user/vernemq.git --candidate-ref feature-branch \
#       --scenarios standard --cluster-size 3 --load-multiplier 3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ANSIBLE_DIR="${BENCH_DIR}/ansible"

source "${SCRIPT_DIR}/lib.sh"

# Defaults
BASELINE_REPO=""
BASELINE_REF=""
CANDIDATE_REPO=""
CANDIDATE_REF=""
SCENARIOS="standard"
CATEGORY="all"
CLUSTER_SIZE=""
LOAD_MULTIPLIER=3
RESULTS_BASE="${BENCH_DIR}/results"
DURATION="${DURATION:-180}"
STABILITY_DURATION="${STABILITY_DURATION:-300}"

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Options:
  --baseline-repo URL    Git repository URL for baseline (required)
  --baseline-ref REF     Git ref for baseline: tag, branch, or commit (required)
  --candidate-repo URL   Git repository URL for candidate (required)
  --candidate-ref REF    Git ref for candidate: tag, branch, or commit (required)
  --scenarios LIST       Scenario selection (default: standard)
  --category CAT         Scenario category: core, integration, or all (default: all)
  --cluster-size N       Number of VMQ nodes (default: auto from inventory)
  --load-multiplier N    Scale all loads by N (default: 3)
  --duration SECS        Duration per phase (default: 180)
  --lb                   Route traffic through load balancer
  -h, --help             Show this help

Examples:
  $(basename "$0") --baseline-repo https://github.com/vernemq/vernemq.git --baseline-ref v2.1.2 \\
      --candidate-repo https://github.com/user/vernemq.git --candidate-ref feature-branch
  $(basename "$0") --baseline-repo https://github.com/vernemq/vernemq.git --baseline-ref main \\
      --candidate-repo https://github.com/vernemq/vernemq.git --candidate-ref v2.2.0 \\
      --scenarios 01,03 --category core
USAGE
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --baseline-repo)    BASELINE_REPO="$2"; shift 2 ;;
        --baseline-ref)     BASELINE_REF="$2"; shift 2 ;;
        --candidate-repo)   CANDIDATE_REPO="$2"; shift 2 ;;
        --candidate-ref)    CANDIDATE_REF="$2"; shift 2 ;;
        --scenarios)        SCENARIOS="$2"; shift 2 ;;
        --category)         CATEGORY="$2"; shift 2 ;;
        --cluster-size)     CLUSTER_SIZE="$2"; shift 2 ;;
        --load-multiplier)  LOAD_MULTIPLIER="$2"; shift 2 ;;
        --duration)         DURATION="$2"; shift 2 ;;
        --lb)               export BENCH_USE_LB=1; shift ;;
        -h|--help)          usage ;;
        *)                  echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$BASELINE_REPO" ]]; then
    echo "ERROR: --baseline-repo is required"
    usage
fi

if [[ -z "$BASELINE_REF" ]]; then
    echo "ERROR: --baseline-ref is required"
    usage
fi

if [[ -z "$CANDIDATE_REPO" ]]; then
    echo "ERROR: --candidate-repo is required"
    usage
fi

if [[ -z "$CANDIDATE_REF" ]]; then
    echo "ERROR: --candidate-ref is required"
    usage
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# =========================================================================
# Run A: Baseline
# =========================================================================
run_baseline() {
    local tag="baseline-${BASELINE_REF}-${TIMESTAMP}"
    local results_dir="${RESULTS_BASE}/${tag}"
    mkdir -p "$results_dir"

    log "========================================="
    log "RUN A: Baseline (${BASELINE_REPO}@${BASELINE_REF})"
    log "========================================="

    # Teardown any previous
    run_ansible "teardown_cluster.yml" || true

    # Deploy via git clone
    local ansible_auth_args=()
    if [[ -n "${BENCH_MQTT_USERNAME:-}" && -n "${BENCH_MQTT_PASSWORD:-}" ]]; then
        ansible_auth_args=(
            -e "bench_auth_enabled=true"
            -e "bench_mqtt_username=${BENCH_MQTT_USERNAME}"
            -e "bench_mqtt_password=${BENCH_MQTT_PASSWORD}"
        )
    fi
    run_ansible "deploy_vernemq.yml" \
        -e "build_mode=git_clone" \
        -e "vernemq_git_repo=${BASELINE_REPO}" \
        -e "vernemq_git_ref=${BASELINE_REF}" \
        ${ansible_auth_args[@]+"${ansible_auth_args[@]}"}

    run_ansible "deploy_bench.yml"
    run_ansible "deploy_monitoring.yml" || true
    run_ansible "configure_cluster.yml"

    # Run scenarios
    log "Running baseline scenarios..."
    export RESULTS_DIR="$results_dir"
    export VMQ_VERSION="$BASELINE_REF"
    export LOAD_MULTIPLIER
    export DURATION
    export STABILITY_DURATION
    export BENCH_COMPARISON_MODE=1
    export EXPORT_PROM=0

    run_scenarios

    log "Baseline complete: $results_dir"
    echo "$tag" > "${RESULTS_BASE}/.baseline_tag"
}

# =========================================================================
# Run B: Candidate
# =========================================================================
run_candidate() {
    local tag="candidate-${CANDIDATE_REF}-${TIMESTAMP}"
    local results_dir="${RESULTS_BASE}/${tag}"
    mkdir -p "$results_dir"

    log "========================================="
    log "RUN B: Candidate (${CANDIDATE_REPO}@${CANDIDATE_REF})"
    log "========================================="

    # Teardown previous
    run_ansible "teardown_cluster.yml" || true

    # Deploy via git clone
    local ansible_auth_args=()
    if [[ -n "${BENCH_MQTT_USERNAME:-}" && -n "${BENCH_MQTT_PASSWORD:-}" ]]; then
        ansible_auth_args=(
            -e "bench_auth_enabled=true"
            -e "bench_mqtt_username=${BENCH_MQTT_USERNAME}"
            -e "bench_mqtt_password=${BENCH_MQTT_PASSWORD}"
        )
    fi
    run_ansible "deploy_vernemq.yml" \
        -e "build_mode=git_clone" \
        -e "vernemq_git_repo=${CANDIDATE_REPO}" \
        -e "vernemq_git_ref=${CANDIDATE_REF}" \
        ${ansible_auth_args[@]+"${ansible_auth_args[@]}"}

    run_ansible "deploy_bench.yml"
    run_ansible "deploy_monitoring.yml" || true
    run_ansible "configure_cluster.yml"

    # Run scenarios
    log "Running candidate scenarios..."
    export RESULTS_DIR="$results_dir"
    export VMQ_VERSION="$CANDIDATE_REF"
    export LOAD_MULTIPLIER
    export DURATION
    export STABILITY_DURATION
    export BENCH_COMPARISON_MODE=1
    export EXPORT_PROM=0

    run_scenarios

    log "Candidate complete: $results_dir"
    echo "$tag" > "${RESULTS_BASE}/.candidate_tag"
}

# =========================================================================
# Main
# =========================================================================

trap cleanup_on_exit EXIT
preflight_check
setup_env_from_inventory

export LB_HOST
export BENCH_USE_LB="${BENCH_USE_LB:-0}"
export BENCH_MQTT_USERNAME
export BENCH_MQTT_PASSWORD

log "========================================="
log "VerneMQ A/B Comparison"
log "========================================="
log "Baseline:    ${BASELINE_REPO}@${BASELINE_REF}"
log "Candidate:   ${CANDIDATE_REPO}@${CANDIDATE_REF}"
log "Multiplier:  ${LOAD_MULTIPLIER}x"
log "Scenarios:   ${SCENARIOS}"
log "Category:    ${CATEGORY}"
log "Duration:    ${DURATION}s per phase"
log "Cluster:     ${CLUSTER_SIZE} nodes"
log "LB:          ${LB_HOST:+$LB_HOST (BENCH_USE_LB=$BENCH_USE_LB)}${LB_HOST:-disabled}"
log "Auth:        ${BENCH_MQTT_USERNAME:+enabled (user: $BENCH_MQTT_USERNAME)}${BENCH_MQTT_USERNAME:-disabled}"
log "========================================="

run_baseline
baseline_tag=$(cat "${RESULTS_BASE}/.baseline_tag")
run_candidate
candidate_tag=$(cat "${RESULTS_BASE}/.candidate_tag")

# Generate comparison report
log "Generating comparison report..."
python3 "${SCRIPT_DIR}/report.py" \
    --baseline "${RESULTS_BASE}/${baseline_tag}" \
    --candidate "${RESULTS_BASE}/${candidate_tag}" \
    --output "${RESULTS_BASE}/comparison-${TIMESTAMP}" \
    2>&1 | tee -a "${RESULTS_BASE}/comparison.log" || \
    log "WARNING: Report generation failed (python3 or dependencies may be missing)"

log "========================================="
log "Comparison Complete"
log "========================================="
log "Baseline results:  ${RESULTS_BASE}/${baseline_tag}"
log "Candidate results: ${RESULTS_BASE}/${candidate_tag}"
log "Report:            ${RESULTS_BASE}/comparison-${TIMESTAMP}/report.md"
log "========================================="
