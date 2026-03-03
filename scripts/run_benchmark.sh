#!/usr/bin/env bash
# run_benchmark.sh - Main benchmark orchestration script
#
# Deploys VerneMQ (release or source), configures the cluster, runs selected
# benchmark scenarios, and collects results.
#
# Usage:
#   ./run_benchmark.sh --version 2.1.2 --tag release-2.1.2 --scenarios all
#   ./run_benchmark.sh --version integration --source /path/to/vernemq --tag int-test
#   ./run_benchmark.sh --version integration --source . --scenarios 01,03,05

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCENARIO_DIR="${BENCH_DIR}/scenarios"
ANSIBLE_DIR="${BENCH_DIR}/ansible"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

VERSION=""
SOURCE_PATH=""
TAG=""
SCENARIOS="all"
RESULTS_BASE="${BENCH_DIR}/results"
CLUSTER_SIZE=""
PROFILE_PATH=""
EXPORT_PROM=0

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Options:
  --version VERSION    VerneMQ version: release number (e.g. 2.1.2) or "integration"
  --source PATH        Path to VerneMQ source (required when --version=integration)
  --tag TAG            Label for this benchmark run (used in results directory)
  --scenarios LIST     Comma-separated scenario numbers/names, or "all", "standard", "chaos" (default: all)
  --cluster-size N     Number of VMQ nodes (default: auto-detect from inventory)
  --profile PATH       Apply tunable profile before running (triggers redeploy)
  --export-prom        Export full Prometheus data after all scenarios
  -h, --help           Show this help

Examples:
  $(basename "$0") --version 2.1.2 --tag baseline
  $(basename "$0") --version integration --source ../vernemq --tag feature-xyz --scenarios 01,03
  $(basename "$0") --version 2.1.2 --tag tuned --profile profiles/high_throughput.yaml --export-prom
  $(basename "$0") --version 2.1.2 --tag chaos-run --scenarios chaos
  $(basename "$0") --version 2.1.2 --tag selective --scenarios baseline,rebalance,flapping
USAGE
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)      VERSION="$2"; shift 2 ;;
        --source)       SOURCE_PATH="$2"; shift 2 ;;
        --tag)          TAG="$2"; shift 2 ;;
        --scenarios)    SCENARIOS="$2"; shift 2 ;;
        --cluster-size) CLUSTER_SIZE="$2"; shift 2 ;;
        --profile)      PROFILE_PATH="$2"; shift 2 ;;
        --export-prom)  EXPORT_PROM=1; shift ;;
        -h|--help)      usage ;;
        *)              echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "ERROR: --version is required"
    usage
fi

if [[ "$VERSION" == "integration" && -z "$SOURCE_PATH" ]]; then
    echo "ERROR: --source is required when --version=integration"
    usage
fi

# Resolve SOURCE_PATH to absolute for Ansible (which runs from a different cwd)
if [[ -n "$SOURCE_PATH" ]]; then
    SOURCE_PATH="$(cd "$SOURCE_PATH" && pwd)"
fi

if [[ -z "$TAG" ]]; then
    TAG="${VERSION}-$(date +%Y%m%d-%H%M%S)"
fi

# ---------------------------------------------------------------------------
# Version dispatch
# ---------------------------------------------------------------------------

case "$VERSION" in
    integration)
        BUILD_MODE="source"
        VERSION_FAMILY="integration"
        ;;
    1.*)
        BUILD_MODE="release"
        VERSION_FAMILY="1.x"
        ;;
    *)
        BUILD_MODE="release"
        VERSION_FAMILY="2.x"
        ;;
esac

export VMQ_VERSION="$VERSION"
export EXPORT_PROM

RESULTS_DIR="${RESULTS_BASE}/${TAG}"
mkdir -p "$RESULTS_DIR"
LOG_FILE="${RESULTS_DIR}/run.log"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    echo "[$ts] $*" | tee -a "$LOG_FILE"
}

run_ansible() {
    local playbook="$1"; shift
    log "Running Ansible playbook: $playbook $*"
    (cd "${ANSIBLE_DIR}" && ansible-playbook "${playbook}" "$@") 2>&1 | tee -a "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Resolve scenarios
# ---------------------------------------------------------------------------

resolve_scenarios() {
    local input="$1"
    local all_scenarios
    all_scenarios=$(ls "${SCENARIO_DIR}"/[0-9]*.sh 2>/dev/null | sort)

    case "$input" in
        all)
            echo "$all_scenarios"
            return
            ;;
        standard)
            # Use suite.sh to get curated list for current cluster size
            local suite_list
            suite_list=$(bash "${SCENARIO_DIR}/suite.sh" "${CLUSTER_SIZE:-10}" "${VERSION}")
            # Resolve the comma-sep numbers
            resolve_scenarios "$suite_list"
            return
            ;;
        chaos)
            # Find scenarios tagged chaos
            grep -rl "# Tags:.*chaos" "${SCENARIO_DIR}"/[0-9]*.sh 2>/dev/null | sort
            return
            ;;
    esac

    # Try comma-separated: could be numbers (01,03) or names (baseline,rebalance,flapping)
    local result=""
    IFS=',' read -ra items <<< "$input"
    for item in "${items[@]}"; do
        item=$(echo "$item" | xargs)  # trim whitespace
        # Try as number first
        if [[ "$item" =~ ^[0-9]+$ ]]; then
            local padded
            padded=$(printf "%02d" "$item")
            local match
            match=$(echo "$all_scenarios" | grep "/${padded}_" || true)
            if [[ -n "$match" ]]; then
                result="${result:+$result
}$match"
                continue
            fi
        fi
        # Try as name substring
        local match
        match=$(echo "$all_scenarios" | grep -i "$item" || true)
        if [[ -n "$match" ]]; then
            result="${result:+$result
}$match"
        else
            log "WARNING: No scenario found matching: $item"
        fi
    done
    echo "$result"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    local RUN_START_EPOCH
    RUN_START_EPOCH=$(date +%s)

    log "========================================="
    log "VerneMQ Benchmark Run"
    log "========================================="
    log "Version:    $VERSION"
    log "Family:     $VERSION_FAMILY"
    log "Build mode: $BUILD_MODE"
    log "Source:     ${SOURCE_PATH:-N/A}"
    log "Tag:        $TAG"
    log "Scenarios:  $SCENARIOS"
    log "Cluster:    ${CLUSTER_SIZE:-auto}"
    log "Profile:    ${PROFILE_PATH:-none}"
    log "Prom export:${EXPORT_PROM}"
    log "Results:    $RESULTS_DIR"
    log "========================================="

    # Step 1: Teardown any previous deployment
    log "Step 1: Teardown previous deployment"
    run_ansible "teardown_cluster.yml" || log "WARNING: Teardown had errors (may be first run)"

    # Step 2: Deploy VerneMQ
    log "Step 2: Deploy VerneMQ ($VERSION)"
    if [[ "$VERSION" == "integration" ]]; then
        run_ansible "deploy_vernemq.yml" \
            -e "build_mode=source" \
            -e "vernemq_local_src_dir=${SOURCE_PATH}" \
            -e "vernemq_version_family=${VERSION_FAMILY}"
    else
        run_ansible "deploy_vernemq.yml" \
            -e "build_mode=release" \
            -e "vernemq_version=${VERSION}" \
            -e "vernemq_version_family=${VERSION_FAMILY}"
    fi
    run_ansible "deploy_bench.yml"
    run_ansible "deploy_monitoring.yml"

    # Step 3: Configure cluster
    log "Step 3: Configure cluster"
    run_ansible "configure_cluster.yml"

    # Step 3b: Apply profile if specified
    if [[ -n "$PROFILE_PATH" ]]; then
        log "Step 3b: Applying profile: $PROFILE_PATH"
        bash "${SCRIPT_DIR}/apply_profile.sh" \
            --profile "$PROFILE_PATH" \
            --ansible-dir "$ANSIBLE_DIR" 2>&1 | tee -a "$LOG_FILE"
    fi

    # Step 4: Run selected scenarios
    log "Step 4: Running scenarios"
    local scenario_list
    scenario_list=$(resolve_scenarios "$SCENARIOS")

    if [[ -z "$scenario_list" ]]; then
        log "ERROR: No scenarios resolved from: $SCENARIOS"
        exit 1
    fi

    local scenario_count=0
    local scenario_pass=0
    local scenario_fail=0

    while IFS= read -r scenario_script; do
        [[ -z "$scenario_script" ]] && continue
        local scenario_name
        scenario_name=$(basename "$scenario_script" .sh)

        log "--- Running scenario: $scenario_name ---"
        scenario_count=$((scenario_count + 1))

        export RESULTS_DIR
        export SCENARIO_TAG="${scenario_name}"
        # Pass through key env vars for consistency
        export DURATION="${DURATION:-}"
        export LOAD_MULTIPLIER="${LOAD_MULTIPLIER:-1}"

        if bash "$scenario_script" 2>&1 | tee -a "$LOG_FILE"; then
            log "--- Scenario $scenario_name: PASSED ---"
            scenario_pass=$((scenario_pass + 1))
        else
            log "--- Scenario $scenario_name: FAILED ---"
            scenario_fail=$((scenario_fail + 1))
        fi
    done <<< "$scenario_list"

    # Step 5: Collect final metrics
    log "Step 5: Collecting final metrics"
    if [[ -n "${PROMETHEUS_URL:-}" ]]; then
        bash "${SCRIPT_DIR}/collect_metrics.sh" \
            --prometheus-url "${PROMETHEUS_URL}" \
            --results-dir "$RESULTS_DIR" \
            --tag "final" 2>&1 | tee -a "$LOG_FILE" || true
    fi

    # Step 5b: Export Prometheus data
    if (( EXPORT_PROM )); then
        log "Step 5b: Exporting Prometheus data"
        local run_end_epoch
        run_end_epoch=$(date +%s)
        bash "${SCRIPT_DIR}/export_prometheus.sh" \
            --prometheus-url "${PROMETHEUS_URL:-http://monitor:9090}" \
            --results-dir "$RESULTS_DIR" \
            --start-epoch "$RUN_START_EPOCH" \
            --end-epoch "$run_end_epoch" 2>&1 | tee -a "$LOG_FILE" || true
    fi

    # Step 6: Print summary
    log "========================================="
    log "Benchmark Run Complete"
    log "========================================="
    log "Tag:        $TAG"
    log "Scenarios:  $scenario_count total, $scenario_pass passed, $scenario_fail failed"
    log "Results:    $RESULTS_DIR"
    log "========================================="

    # Save summary
    {
        echo "tag,$TAG"
        echo "version,$VERSION"
        echo "version_family,$VERSION_FAMILY"
        echo "total_scenarios,$scenario_count"
        echo "passed,$scenario_pass"
        echo "failed,$scenario_fail"
        echo "timestamp,$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "${RESULTS_DIR}/run_summary.csv"

    if (( scenario_fail > 0 )); then
        exit 1
    fi
}

main "$@"
