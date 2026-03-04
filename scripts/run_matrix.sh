#!/usr/bin/env bash
# run_matrix.sh - N-version parallel benchmark orchestrator
#
# Benchmarks N versions of VerneMQ, either sequentially on one cluster or
# in parallel on N separate clusters.
#
# Usage:
#   # Sequential (single cluster, deploy-run-deploy-run):
#   ./scripts/run_matrix.sh \
#     --version https://github.com/vernemq/vernemq.git@v2.1.2 \
#     --version https://github.com/vernemq/vernemq.git@main \
#     --version https://github.com/user/vernemq.git@feature-x \
#     --scenarios standard
#
#   # Parallel (N clusters, simultaneous):
#   ./scripts/run_matrix.sh \
#     --version https://github.com/vernemq/vernemq.git@v2.1.2 \
#     --version https://github.com/vernemq/vernemq.git@main \
#     --parallel --provision --teardown

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ANSIBLE_DIR="${BENCH_DIR}/ansible"

source "${SCRIPT_DIR}/lib.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

declare -a VERSIONS=()
PARALLEL=false
PROVISION=false
TEARDOWN=false
SCENARIOS="standard"
CATEGORY="all"
DURATION="${DURATION:-180}"
STABILITY_DURATION="${STABILITY_DURATION:-300}"
LOAD_MULTIPLIER=3
RESULTS_BASE="${BENCH_DIR}/results"
CLUSTER_SIZE=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Options:
  --version REPO@REF    Version spec (repeatable, min 2, first = baseline)
  --parallel            Run on separate clusters simultaneously
  --provision           Auto-provision clusters before parallel run
  --teardown            Auto-destroy clusters after parallel run
  --scenarios LIST      Scenario selection (default: standard)
  --category CAT        core/integration/all (default: all)
  --duration SECS       Seconds per phase (default: 180)
  --load-multiplier N   Scale factor (default: 3)
  --cluster-size N      Number of VMQ nodes (default: auto from inventory)
  --lb                  Route traffic through load balancer
  -h, --help            Show this help

Examples:
  # Sequential comparison of 3 versions:
  $(basename "$0") \\
    --version https://github.com/vernemq/vernemq.git@v2.1.2 \\
    --version https://github.com/vernemq/vernemq.git@main \\
    --version https://github.com/user/vernemq.git@feature-x

  # Parallel run with auto-provisioning:
  $(basename "$0") \\
    --version https://github.com/vernemq/vernemq.git@v2.1.2 \\
    --version https://github.com/vernemq/vernemq.git@main \\
    --parallel --provision --teardown
USAGE
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)          VERSIONS+=("$2"); shift 2 ;;
        --parallel)         PARALLEL=true; shift ;;
        --provision)        PROVISION=true; shift ;;
        --teardown)         TEARDOWN=true; shift ;;
        --scenarios)        SCENARIOS="$2"; shift 2 ;;
        --category)         CATEGORY="$2"; shift 2 ;;
        --duration)         DURATION="$2"; shift 2 ;;
        --load-multiplier)  LOAD_MULTIPLIER="$2"; shift 2 ;;
        --cluster-size)     CLUSTER_SIZE="$2"; shift 2 ;;
        --lb)               export BENCH_USE_LB=1; shift ;;
        -h|--help)          usage ;;
        *)                  echo "Unknown option: $1"; usage ;;
    esac
done

if [[ ${#VERSIONS[@]} -lt 2 ]]; then
    echo "ERROR: At least 2 --version arguments are required"
    usage
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

parse_version_spec() {
    # Parse "REPO@REF" into repo and ref components
    local spec="$1"
    local repo="${spec%@*}"
    local ref="${spec##*@}"
    if [[ "$repo" == "$spec" ]] || [[ -z "$ref" ]]; then
        echo "ERROR: Invalid version spec: $spec (expected REPO@REF)" >&2
        exit 1
    fi
    echo "$repo" "$ref"
}

deploy_and_run() {
    # Deploy a version and run scenarios
    local repo="$1"
    local ref="$2"
    local tag="$3"
    local results_dir="${RESULTS_BASE}/${tag}"
    mkdir -p "$results_dir"

    log "Deploying ${repo}@${ref} (tag: ${tag})..."

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
        -e "vernemq_git_repo=${repo}" \
        -e "vernemq_git_ref=${ref}" \
        ${ansible_auth_args[@]+"${ansible_auth_args[@]}"}

    run_ansible "deploy_bench.yml"
    run_ansible "deploy_monitoring.yml" || true
    run_ansible "configure_cluster.yml"

    # Run scenarios
    log "Running scenarios for ${ref}..."
    export RESULTS_DIR="$results_dir"
    export VMQ_VERSION="$ref"
    export LOAD_MULTIPLIER
    export DURATION
    export STABILITY_DURATION
    export SCENARIOS
    export BENCH_COMPARISON_MODE=1
    export EXPORT_PROM=0

    run_scenarios

    # Save run summary
    {
        echo "tag,$tag"
        echo "version,$ref"
        echo "repo,$repo"
        echo "ref,$ref"
        echo "category,$CATEGORY"
        echo "timestamp,$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "${results_dir}/run_summary.csv"

    log "Run complete for ${ref}: ${results_dir}"
}

run_on_cluster() {
    # Run a version on a specific cluster (for parallel mode)
    local cluster_id="$1"
    local repo="$2"
    local ref="$3"
    local tag="$4"
    local inventory="${ANSIBLE_DIR}/inventory/hosts-${cluster_id}"

    (
        # Subshell to isolate env vars
        setup_env_from_inventory "$inventory"
        export ANSIBLE_INVENTORY="$inventory"
        # Wait for freshly provisioned instances to become SSH-ready
        wait_for_ssh 180
        deploy_and_run "$repo" "$ref" "$tag"
    )
}

# ---------------------------------------------------------------------------
# Sequential mode
# ---------------------------------------------------------------------------

run_sequential() {
    log "========================================="
    log "N-Version Matrix Benchmark (Sequential)"
    log "========================================="
    log "Versions: ${#VERSIONS[@]}"
    for i in "${!VERSIONS[@]}"; do
        log "  [$((i+1))] ${VERSIONS[$i]}"
    done
    log "========================================="

    preflight_check
    setup_env_from_inventory

    export LB_HOST
    export BENCH_USE_LB="${BENCH_USE_LB:-0}"
    export BENCH_MQTT_USERNAME
    export BENCH_MQTT_PASSWORD

    local -a run_dirs=()
    local -a tags=()

    for i in "${!VERSIONS[@]}"; do
        local spec="${VERSIONS[$i]}"
        local repo ref
        read -r repo ref <<< "$(parse_version_spec "$spec")"

        local tag
        if [[ "$i" -eq 0 ]]; then
            tag="baseline-${ref}-${TIMESTAMP}"
        else
            tag="version-$((i+1))-${ref}-${TIMESTAMP}"
        fi

        log "========================================="
        log "Version $((i+1))/${#VERSIONS[@]}: ${repo}@${ref}"
        log "Tag: ${tag}"
        log "========================================="

        deploy_and_run "$repo" "$ref" "$tag"

        run_dirs+=("${RESULTS_BASE}/${tag}")
        tags+=("$tag")
    done

    generate_nway_report "${run_dirs[@]}"
}

# ---------------------------------------------------------------------------
# Parallel mode
# ---------------------------------------------------------------------------

run_parallel() {
    log "========================================="
    log "N-Version Matrix Benchmark (Parallel)"
    log "========================================="
    log "Versions: ${#VERSIONS[@]}"
    for i in "${!VERSIONS[@]}"; do
        log "  [$((i+1))] ${VERSIONS[$i]}"
    done
    log "========================================="

    local -a cluster_ids=()
    for i in "${!VERSIONS[@]}"; do
        cluster_ids+=("cluster-$((i+1))")
    done

    # Provision clusters if requested (sequential to avoid terraform state lock conflicts)
    if $PROVISION; then
        log "Provisioning ${#cluster_ids[@]} clusters (sequential)..."
        for cid in "${cluster_ids[@]}"; do
            log "Provisioning cluster: ${cid}"
            bash "${SCRIPT_DIR}/infra_up.sh" --cluster-id "$cid" --auto-approve
        done
        log "All clusters provisioned."
    fi

    # Run versions on their respective clusters
    local -a run_pids=()
    local -a run_dirs=()
    local -a tags=()

    for i in "${!VERSIONS[@]}"; do
        local spec="${VERSIONS[$i]}"
        local repo ref
        read -r repo ref <<< "$(parse_version_spec "$spec")"

        local tag
        if [[ "$i" -eq 0 ]]; then
            tag="baseline-${ref}-${TIMESTAMP}"
        else
            tag="version-$((i+1))-${ref}-${TIMESTAMP}"
        fi

        local cid="${cluster_ids[$i]}"

        log "Starting ${repo}@${ref} on ${cid} (tag: ${tag})..."
        run_on_cluster "$cid" "$repo" "$ref" "$tag" &
        run_pids+=($!)
        run_dirs+=("${RESULTS_BASE}/${tag}")
        tags+=("$tag")
    done

    # Wait for all runs to complete
    local run_failed=false
    for pid in "${run_pids[@]}"; do
        if ! wait "$pid"; then
            log "WARNING: Run failed (PID: $pid)"
            run_failed=true
        fi
    done

    if $run_failed; then
        log "WARNING: One or more benchmark runs failed"
    fi

    # Generate N-way report
    generate_nway_report "${run_dirs[@]}"

    # Teardown clusters if requested (sequential to avoid terraform state lock conflicts)
    if $TEARDOWN; then
        log "Tearing down ${#cluster_ids[@]} clusters (sequential)..."
        for cid in "${cluster_ids[@]}"; do
            log "Destroying cluster: ${cid}"
            bash "${SCRIPT_DIR}/infra_down.sh" --cluster-id "$cid" --auto-approve
        done
        log "All clusters destroyed."
    fi
}

# ---------------------------------------------------------------------------
# Report generation
# ---------------------------------------------------------------------------

generate_nway_report() {
    local -a dirs=("$@")
    local report_dir="${RESULTS_BASE}/matrix-${TIMESTAMP}"

    log "Generating N-way comparison report..."

    local -a run_args=()
    for d in "${dirs[@]}"; do
        run_args+=(--run "$d")
    done

    python3 "${SCRIPT_DIR}/report.py" \
        "${run_args[@]}" \
        --output "$report_dir" \
        2>&1 | tee -a "${RESULTS_BASE}/matrix.log" || \
        log "WARNING: Report generation failed (python3 or dependencies may be missing)"

    log "========================================="
    log "Matrix Benchmark Complete"
    log "========================================="
    for d in "${dirs[@]}"; do
        log "  Results: $d"
    done
    log "Report: ${report_dir}/report.md"
    log "========================================="
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

trap cleanup_on_exit EXIT

if $PARALLEL; then
    run_parallel
else
    run_sequential
fi
