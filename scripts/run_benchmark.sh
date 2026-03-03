#!/usr/bin/env bash
# run_benchmark.sh - Main benchmark orchestration script
#
# Deploys VerneMQ via git clone + build, configures the cluster, runs selected
# benchmark scenarios, and collects results.
#
# Usage:
#   ./run_benchmark.sh --repo https://github.com/vernemq/vernemq.git --ref v2.1.2 --tag baseline
#   ./run_benchmark.sh --repo https://github.com/user/vernemq.git --ref feature-branch --tag feature-test --category core
#   ./run_benchmark.sh --repo https://github.com/vernemq/vernemq.git --ref main --tag comparison --scenarios 01,03

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCENARIO_DIR="${BENCH_DIR}/scenarios"
ANSIBLE_DIR="${BENCH_DIR}/ansible"

source "${SCRIPT_DIR}/lib.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

REPO=""
REF=""
TAG=""
SCENARIOS="all"
CATEGORY="all"
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
  --repo URL           Git repository URL (required)
  --ref REF            Git ref: tag, branch, or commit (required)
  --tag TAG            Label for this benchmark run (used in results directory)
  --scenarios LIST     Comma-separated scenario numbers/names, or "all", "standard", "chaos" (default: all)
  --category CAT       Scenario category: core, integration, or all (default: all)
  --cluster-size N     Number of VMQ nodes (default: auto-detect from inventory)
  --profile PATH       Apply tunable profile before running (triggers redeploy)
  --duration SECS      Duration per scenario phase in seconds
  --export-prom        Export full Prometheus TSDB snapshot after all scenarios
  --lb                 Route traffic through load balancer
  -h, --help           Show this help

Examples:
  $(basename "$0") --repo https://github.com/vernemq/vernemq.git --ref v2.1.2 --tag baseline
  $(basename "$0") --repo https://github.com/user/vernemq.git --ref feature-branch --tag feature-test --category core
  $(basename "$0") --repo https://github.com/vernemq/vernemq.git --ref main --tag comparison --scenarios 01,03
USAGE
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)         REPO="$2"; shift 2 ;;
        --ref)          REF="$2"; shift 2 ;;
        --tag)          TAG="$2"; shift 2 ;;
        --scenarios)    SCENARIOS="$2"; shift 2 ;;
        --category)     CATEGORY="$2"; shift 2 ;;
        --cluster-size) CLUSTER_SIZE="$2"; shift 2 ;;
        --profile)      PROFILE_PATH="$2"; shift 2 ;;
        --duration)     DURATION="$2"; shift 2 ;;
        --export-prom)  EXPORT_PROM=1; shift ;;
        --lb)           export BENCH_USE_LB=1; shift ;;
        -h|--help)      usage ;;
        *)              echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$REPO" ]]; then
    echo "ERROR: --repo is required"
    usage
fi

if [[ -z "$REF" ]]; then
    echo "ERROR: --ref is required"
    usage
fi

if [[ -z "$TAG" ]]; then
    TAG="${REF}-$(date +%Y%m%d-%H%M%S)"
fi

export VMQ_VERSION="$REF"
export EXPORT_PROM

RESULTS_DIR="${RESULTS_BASE}/${TAG}"
mkdir -p "$RESULTS_DIR"
LOG_FILE="${RESULTS_DIR}/run.log"

# ---------------------------------------------------------------------------
# Resolve scenarios
# ---------------------------------------------------------------------------

resolve_scenarios() {
    local input="$1"
    local all_scenarios=""

    # Build scenario list based on category
    case "$CATEGORY" in
        core)
            all_scenarios=$(ls "${SCENARIO_DIR}/core/"[0-9]*.sh 2>/dev/null | sort)
            ;;
        integration)
            all_scenarios=$(ls "${SCENARIO_DIR}/integration/"[0-9]*.sh 2>/dev/null | sort)
            ;;
        all|*)
            all_scenarios=$(ls "${SCENARIO_DIR}/core/"[0-9]*.sh "${SCENARIO_DIR}/integration/"[0-9]*.sh 2>/dev/null | sort)
            ;;
    esac

    case "$input" in
        all)
            echo "$all_scenarios"
            return
            ;;
        standard)
            local suite_list
            suite_list=$(bash "${SCENARIO_DIR}/suite.sh" "${CLUSTER_SIZE:-3}" "${REF}")
            resolve_scenarios "$suite_list"
            return
            ;;
        chaos)
            echo "$all_scenarios" | while read -r f; do
                grep -l "# Tags:.*chaos" "$f" 2>/dev/null || true
            done
            return
            ;;
    esac

    # Try comma-separated: could be numbers or names
    local result=""
    IFS=',' read -ra items <<< "$input"
    for item in "${items[@]}"; do
        item=$(echo "$item" | xargs)
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
        local match
        match=$(echo "$all_scenarios" | grep -Fi "$item" || true)
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

    preflight_check
    setup_env_from_inventory
    export PROMETHEUS_URL
    export SSH_KEY
    export SSH_USER
    export SSH_OPTS

    # Export LB and auth configuration
    export LB_HOST
    export BENCH_USE_LB="${BENCH_USE_LB:-0}"
    export BENCH_MQTT_USERNAME
    export BENCH_MQTT_PASSWORD

    log "========================================="
    log "VerneMQ Benchmark Run"
    log "========================================="
    log "Repo:       $REPO"
    log "Ref:        $REF"
    log "Build mode: git_clone"
    log "Tag:        $TAG"
    log "Scenarios:  $SCENARIOS"
    log "Category:   $CATEGORY"
    log "Cluster:    ${CLUSTER_SIZE:-auto}"
    log "Profile:    ${PROFILE_PATH:-none}"
    log "Prom export:${EXPORT_PROM}"
    log "Results:    $RESULTS_DIR"
    log "LB:         ${LB_HOST:+$LB_HOST (BENCH_USE_LB=$BENCH_USE_LB)}${LB_HOST:-disabled}"
    log "Auth:       ${BENCH_MQTT_USERNAME:+enabled (user: $BENCH_MQTT_USERNAME)}${BENCH_MQTT_USERNAME:-disabled}"
    log "========================================="

    # Step 1: Teardown any previous deployment
    log "Step 1: Teardown previous deployment"
    run_ansible "teardown_cluster.yml" || log "WARNING: Teardown had errors (may be first run)"

    # Step 2: Deploy VerneMQ
    log "Step 2: Deploy VerneMQ (${REPO}@${REF})"
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
        -e "vernemq_git_repo=${REPO}" \
        -e "vernemq_git_ref=${REF}" \
        ${ansible_auth_args[@]+"${ansible_auth_args[@]}"}
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

    local first_scenario=true
    while IFS= read -r scenario_script; do
        [[ -z "$scenario_script" ]] && continue

        # Reset cluster between scenarios (not before first)
        if [[ "$first_scenario" == "true" ]]; then
            first_scenario=false
        else
            reset_cluster_state
        fi

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
        echo "version,$REF"
        echo "repo,$REPO"
        echo "ref,$REF"
        echo "category,$CATEGORY"
        echo "total_scenarios,$scenario_count"
        echo "passed,$scenario_pass"
        echo "failed,$scenario_fail"
        echo "timestamp,$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "${RESULTS_DIR}/run_summary.csv"

    if (( scenario_fail > 0 )); then
        exit 1
    fi
}

trap cleanup_on_exit EXIT
main "$@"
