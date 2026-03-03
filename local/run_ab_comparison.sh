#!/usr/bin/env bash
# run_ab_comparison.sh - A/B comparison of two VerneMQ versions in Docker.
#
# Uses the transport abstraction (BENCH_TRANSPORT=docker) to run the same
# cloud scenarios in Docker. Supports building from git refs or pre-built images.
#
# Usage:
#   ./run_ab_comparison.sh --baseline-ref main --candidate-ref feature-x
#   ./run_ab_comparison.sh --baseline-image img-a --candidate-image img-b --scenarios 01,04

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCENARIO_DIR="${BENCH_DIR}/scenarios"

# ---------------------------------------------------------------------------
# Exclusive lock — prevent concurrent local benchmark runs
# ---------------------------------------------------------------------------

LOCKFILE="${SCRIPT_DIR}/.bench.lock"

cleanup_lock() {
    rm -f "$LOCKFILE"
}

cleanup() {
    echo "[$(date -u '+%H:%M:%S')] Cleaning up..."
    cd "$SCRIPT_DIR"
    docker compose down -v 2>/dev/null || true
    cleanup_lock
}

if [ -f "$LOCKFILE" ]; then
    OTHER_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
    if [ -n "$OTHER_PID" ] && kill -0 "$OTHER_PID" 2>/dev/null; then
        echo "ERROR: Another local benchmark is already running (PID ${OTHER_PID})."
        echo "If this is stale, remove ${LOCKFILE} and retry."
        exit 1
    fi
    rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

BASELINE_REF=""
CANDIDATE_REF=""
BASELINE_REPO=""
CANDIDATE_REPO=""
BASELINE_IMAGE=""
CANDIDATE_IMAGE=""
SCENARIOS="standard"
CATEGORY="all"
NUM_NODES=3
MONITORING=0
DURATION="${DURATION:-180}"
LOCAL_SCALE="${LOCAL_SCALE:-0.4}"
PROFILE="local"
LB=0
AUTH=1
AUTH_USER=""
AUTH_PASS=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Build from git refs:
  --baseline-ref REF       Git ref for baseline
  --candidate-ref REF      Git ref for candidate
  --baseline-repo URL      Git repo for baseline (default: current tree)
  --candidate-repo URL     Git repo for candidate (default: current tree)

Or use pre-built images:
  --baseline-image IMG     Pre-built image for baseline
  --candidate-image IMG    Pre-built image for candidate

Options:
  --scenarios LIST         Scenario selection (default: standard)
  --category CAT           core/integration/all (default: all)
  --nodes N                Cluster size (default: 3)
  --monitoring             Include Prometheus + Grafana
  --duration SECS          Phase duration (default: 180)
  --scale FACTOR           LOCAL_SCALE (default: 0.4)
  --lb                     Include HAProxy load balancer
  --no-auth                Disable MQTT authentication
  --auth-user USER         Override auth username (default: benchuser)
  --auth-pass PASS         Override auth password (default: auto-generated)
  -h, --help               Show this help

Examples:
  $(basename "$0") --baseline-ref main --candidate-ref feature-x
  $(basename "$0") --baseline-image vmq:v2.1.2 --candidate-image vmq:feature --scenarios 01,04
  $(basename "$0") --baseline-ref v2.1.2 --candidate-ref main --nodes 5 --monitoring
USAGE
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --baseline-ref)    BASELINE_REF="$2"; shift 2 ;;
        --candidate-ref)   CANDIDATE_REF="$2"; shift 2 ;;
        --baseline-repo)   BASELINE_REPO="$2"; shift 2 ;;
        --candidate-repo)  CANDIDATE_REPO="$2"; shift 2 ;;
        --baseline-image)  BASELINE_IMAGE="$2"; shift 2 ;;
        --candidate-image) CANDIDATE_IMAGE="$2"; shift 2 ;;
        --scenarios)       SCENARIOS="$2"; shift 2 ;;
        --category)        CATEGORY="$2"; shift 2 ;;
        --nodes)           NUM_NODES="$2"; shift 2 ;;
        --monitoring)      MONITORING=1; shift ;;
        --duration)        DURATION="$2"; shift 2 ;;
        --scale)           LOCAL_SCALE="$2"; shift 2 ;;
        --lb)          LB=1; shift ;;
        --no-auth)     AUTH=0; shift ;;
        --auth-user)   AUTH_USER="$2"; shift 2 ;;
        --auth-pass)   AUTH_PASS="$2"; shift 2 ;;
        -h|--help)         usage ;;
        *)                 echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate
HAS_BASELINE=0
HAS_CANDIDATE=0
[[ -n "$BASELINE_REF" || -n "$BASELINE_IMAGE" ]] && HAS_BASELINE=1
[[ -n "$CANDIDATE_REF" || -n "$CANDIDATE_IMAGE" ]] && HAS_CANDIDATE=1

if (( ! HAS_BASELINE || ! HAS_CANDIDATE )); then
    echo "ERROR: Must specify baseline and candidate via --*-ref or --*-image"
    echo "Run with --help for usage."
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    echo "[$(date -u '+%H:%M:%S')] $*"
}

build_from_ref() {
    local ref="$1" repo="$2" image_name="$3"
    local build_context

    if [[ -n "$repo" && "$repo" != "." ]]; then
        build_context="/tmp/vmq-bench-${image_name}-$$"
        log "Cloning ${repo}@${ref} into ${build_context}..."
        git clone --depth 1 --branch "$ref" "$repo" "$build_context"
        mkdir -p "${build_context}/bench/local"
        cp "${SCRIPT_DIR}/Dockerfile" "${build_context}/bench/local/Dockerfile"
        cp "${SCRIPT_DIR}/entrypoint.sh" "${build_context}/bench/local/entrypoint.sh"
    else
        build_context="/tmp/vmq-bench-${image_name}-$$"
        log "Creating worktree for ${ref}..."
        git -C "$PROJECT_ROOT" worktree remove "$build_context" 2>/dev/null || true
        rm -rf "$build_context"
        git -C "$PROJECT_ROOT" worktree add "$build_context" "$ref"
        mkdir -p "${build_context}/bench/local"
        cp "${SCRIPT_DIR}/Dockerfile" "${build_context}/bench/local/Dockerfile"
        cp "${SCRIPT_DIR}/entrypoint.sh" "${build_context}/bench/local/entrypoint.sh"
    fi

    log "Building image ${image_name} from ${ref}..."
    docker build -t "$image_name" -f "${build_context}/bench/local/Dockerfile" "$build_context"

    # Cleanup
    if [[ -z "$repo" || "$repo" == "." ]]; then
        git -C "$PROJECT_ROOT" worktree remove "$build_context" 2>/dev/null || true
    else
        rm -rf "$build_context"
    fi
}

# Build VMQ node list
VMQ_NODE_LIST=""
for (( i=1; i<=NUM_NODES; i++ )); do
    VMQ_NODE_LIST="${VMQ_NODE_LIST:+$VMQ_NODE_LIST }vmq${i}"
done

# ---------------------------------------------------------------------------
# Build images
# ---------------------------------------------------------------------------

if [[ -n "$BASELINE_REF" ]]; then
    BASELINE_IMAGE="vmq-ab-baseline"
    build_from_ref "$BASELINE_REF" "$BASELINE_REPO" "$BASELINE_IMAGE"
fi

if [[ -n "$CANDIDATE_REF" ]]; then
    CANDIDATE_IMAGE="vmq-ab-candidate"
    build_from_ref "$CANDIDATE_REF" "$CANDIDATE_REPO" "$CANDIDATE_IMAGE"
fi

# Ensure emqtt-bench image exists
if ! docker image inspect emqtt-bench-local >/dev/null 2>&1; then
    log "Building emqtt-bench image..."
    docker build -t emqtt-bench-local -f "${SCRIPT_DIR}/Dockerfile.bench" "$SCRIPT_DIR"
fi

# Generate compose file
log "Generating docker-compose.yml (${NUM_NODES} nodes)..."
COMPOSE_ARGS=(--nodes "$NUM_NODES")
if (( MONITORING )); then
    COMPOSE_ARGS+=(--monitoring)
fi
if (( LB )); then
    COMPOSE_ARGS+=(--lb)
fi
if (( AUTH )); then
    AUTH_USER="${AUTH_USER:-benchuser}"
    AUTH_PASS="${AUTH_PASS:-$(openssl rand -base64 18)}"
    COMPOSE_ARGS+=(--auth --auth-user "$AUTH_USER" --auth-pass "$AUTH_PASS")
else
    COMPOSE_ARGS+=(--no-auth)
fi
bash "${SCRIPT_DIR}/generate_compose.sh" "${COMPOSE_ARGS[@]}"

# Auth setup
if (( AUTH )); then
    AUTH_USER="${AUTH_USER:-benchuser}"
    AUTH_PASS="${AUTH_PASS:-$(openssl rand -base64 18)}"
    export BENCH_MQTT_USERNAME="$AUTH_USER"
    export BENCH_MQTT_PASSWORD="$AUTH_PASS"
    export VMQ_AUTH_ENABLED="true"
    export VMQ_AUTH_USERNAME="$AUTH_USER"
    export VMQ_AUTH_PASSWORD="$AUTH_PASS"
    log "Auth: enabled (user: $AUTH_USER)"
fi

if (( LB )); then
    export LB_HOST="haproxy"
    export BENCH_USE_LB="1"
    log "LB: enabled (haproxy)"
fi

# ---------------------------------------------------------------------------
# Run variant
# ---------------------------------------------------------------------------

run_variant() {
    local variant_name="$1" image_name="$2"
    local results_tag="ab_${variant_name}_$(date +%Y%m%d_%H%M%S)"
    local results_dir="${SCRIPT_DIR}/results/${results_tag}"
    mkdir -p "$results_dir"

    log "========================================="
    log "Running variant: ${variant_name} (image: ${image_name})"
    log "========================================="

    cd "$SCRIPT_DIR"

    # Tag the variant image so docker-compose uses it
    docker tag "$image_name" vmq-local-bench
    docker compose up -d

    # Wait for cluster
    log "Waiting for cluster formation..."
    local max_wait=180 elapsed=0
    while (( elapsed < max_wait )); do
        local running
        running=$(docker exec vmq1 /opt/vernemq/bin/vmq-admin cluster show 2>/dev/null \
            | grep -c "true" || echo 0)
        if (( running >= NUM_NODES )); then
            log "Cluster ready: ${running}/${NUM_NODES} nodes"
            break
        fi
        sleep 5
        (( elapsed += 5 ))
    done

    if (( elapsed >= max_wait )); then
        log "ERROR: Cluster did not form for variant ${variant_name}"
        docker compose down -v 2>/dev/null || true
        return 1
    fi

    # Resolve scenarios using suite.sh
    local scenario_scripts
    scenario_scripts=$(resolve_scenario_scripts)

    # Run scenarios
    local scenario_pass=0 scenario_fail=0
    while IFS= read -r scenario_script; do
        [[ -z "$scenario_script" ]] && continue
        local sname
        sname=$(basename "$scenario_script" .sh)

        log "--- Running: ${sname} for ${variant_name} ---"
        if BENCH_TRANSPORT=docker \
            VMQ_NODES="$VMQ_NODE_LIST" \
            BENCH_NODES="bench" \
            VMQ_ADMIN="/opt/vernemq/bin/vmq-admin" \
            VMQ_VERSION="$PROFILE" \
            RESULTS_DIR="$results_dir" \
            SCENARIO_TAG="${sname}" \
            LOCAL_SCALE="$LOCAL_SCALE" \
            PROMETHEUS_URL="$([ "$MONITORING" -eq 1 ] && echo 'http://prometheus:9090' || echo '')" \
            MONITOR_HOST="" \
            DURATION="$DURATION" \
            LOAD_MULTIPLIER="1" \
            BENCH_COMPARISON_MODE=1 \
            BENCH_MQTT_USERNAME="${BENCH_MQTT_USERNAME:-}" \
            BENCH_MQTT_PASSWORD="${BENCH_MQTT_PASSWORD:-}" \
            LB_HOST="${LB_HOST:-}" \
            BENCH_USE_LB="${BENCH_USE_LB:-0}" \
            bash "$scenario_script"; then
            log "--- ${sname}: PASSED ---"
            scenario_pass=$((scenario_pass + 1))
        else
            log "--- ${sname}: FAILED ---"
            scenario_fail=$((scenario_fail + 1))
        fi
    done <<< "$scenario_scripts"

    # Collect final cluster_bytes_dropped
    local drops_file="${results_dir}/cluster_drops.txt"
    local total_drops=0
    for (( i=1; i<=NUM_NODES; i++ )); do
        local d
        d=$(docker exec "vmq${i}" /opt/vernemq/bin/vmq-admin metrics show 2>/dev/null \
            | grep "cluster_bytes_dropped" | awk -F' = ' '{print $2}' | head -1 || echo 0)
        total_drops=$(( total_drops + d ))
        echo "vmq${i}: ${d}" >> "$drops_file"
    done
    echo "total: ${total_drops}" >> "$drops_file"
    log "Variant ${variant_name} total cluster_bytes_dropped: ${total_drops}"

    # Save summary
    {
        echo "variant,${variant_name}"
        echo "image,${image_name}"
        echo "scenarios_passed,${scenario_pass}"
        echo "scenarios_failed,${scenario_fail}"
        echo "cluster_bytes_dropped,${total_drops}"
        echo "timestamp,$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "${results_dir}/variant_summary.csv"

    # Tear down
    docker compose down -v 2>/dev/null || true

    echo "$results_tag"
}

resolve_scenario_scripts() {
    local input="${1:-$SCENARIOS}"
    local all_scenarios=""

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
            suite_list=$(bash "${SCENARIO_DIR}/suite.sh" "$NUM_NODES" "$PROFILE")
            resolve_scenario_scripts "$suite_list"
            return
            ;;
        core)
            CATEGORY="core"
            resolve_scenario_scripts "all"
            return
            ;;
        integration)
            CATEGORY="integration"
            resolve_scenario_scripts "all"
            return
            ;;
    esac

    # Comma-separated numbers or name patterns
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

LABEL_A="${BASELINE_REF:-$(echo "$BASELINE_IMAGE" | tr ':/' '_')}"
LABEL_B="${CANDIDATE_REF:-$(echo "$CANDIDATE_IMAGE" | tr ':/' '_')}"

log "========================================="
log "VerneMQ A/B Comparison (Docker)"
log "========================================="
log "Baseline:    ${BASELINE_IMAGE:-${BASELINE_REF}}"
log "Candidate:   ${CANDIDATE_IMAGE:-${CANDIDATE_REF}}"
log "Nodes:       ${NUM_NODES}"
log "Scenarios:   ${SCENARIOS}"
log "Category:    ${CATEGORY}"
log "Duration:    ${DURATION}s per phase"
log "Scale:       ${LOCAL_SCALE}"
log "========================================="

baseline_tag=$(run_variant "$LABEL_A" "$BASELINE_IMAGE")
candidate_tag=$(run_variant "$LABEL_B" "$CANDIDATE_IMAGE")

# ---------------------------------------------------------------------------
# Comparison report
# ---------------------------------------------------------------------------

BASELINE_DIR="${SCRIPT_DIR}/results/${baseline_tag}"
CANDIDATE_DIR="${SCRIPT_DIR}/results/${candidate_tag}"

# Try generating report with report.py
if [[ -f "${BENCH_DIR}/scripts/report.py" ]]; then
    log "Generating comparison report..."
    python3 "${BENCH_DIR}/scripts/report.py" \
        --baseline "$BASELINE_DIR" \
        --candidate "$CANDIDATE_DIR" \
        --output "${SCRIPT_DIR}/results/comparison-$(date +%Y%m%d-%H%M%S)" \
        2>&1 || log "WARNING: Report generation failed"
fi

log "========================================="
log "A/B COMPARISON COMPLETE"
log "========================================="
log "Baseline results:  ${BASELINE_DIR}"
log "Candidate results: ${CANDIDATE_DIR}"

# Simple drops comparison
DROPS_A=$(grep "^total:" "${BASELINE_DIR}/cluster_drops.txt" 2>/dev/null | awk '{print $2}' || echo "N/A")
DROPS_B=$(grep "^total:" "${CANDIDATE_DIR}/cluster_drops.txt" 2>/dev/null | awk '{print $2}' || echo "N/A")

log "cluster_bytes_dropped:"
log "  Baseline  (${LABEL_A}): ${DROPS_A}"
log "  Candidate (${LABEL_B}): ${DROPS_B}"

if [[ "$DROPS_A" != "N/A" && "$DROPS_B" != "N/A" ]]; then
    if (( DROPS_A == 0 && DROPS_B == 0 )); then
        log "  -> Both variants: zero drops"
    elif (( DROPS_A > 0 && DROPS_B == 0 )); then
        log "  -> Candidate fixed the regression (baseline had ${DROPS_A} bytes dropped)"
    elif (( DROPS_A == 0 && DROPS_B > 0 )); then
        log "  -> WARNING: Candidate has regression (${DROPS_B} bytes dropped)"
    else
        log "  -> Both variants show drops (baseline: ${DROPS_A}, candidate: ${DROPS_B})"
    fi
fi

log "Full results in: ${SCRIPT_DIR}/results/"
