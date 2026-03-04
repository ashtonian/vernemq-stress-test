#!/usr/bin/env bash
# run_local_bench.sh - Build, start N-node cluster, run scenarios, collect results.
#
# Uses the transport abstraction (BENCH_TRANSPORT=docker) to run the same
# cloud scenarios in Docker with zero code duplication.
#
# Usage:
#   ./run_local_bench.sh                                    # Build + standard scenarios
#   ./run_local_bench.sh --ref v2.1.2 --scenarios all       # Build from git ref
#   ./run_local_bench.sh --nodes 5 --monitoring --category core
#   ./run_local_bench.sh --repo https://github.com/vernemq/vernemq.git --ref main
#   ./run_local_bench.sh --skip-build --scenarios 01,04,06

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

if [ -f "$LOCKFILE" ]; then
    OTHER_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
    if [ -n "$OTHER_PID" ] && kill -0 "$OTHER_PID" 2>/dev/null; then
        echo "ERROR: Another local benchmark is already running (PID ${OTHER_PID})."
        echo "If this is stale, remove ${LOCKFILE} and retry."
        exit 1
    fi
    # Stale lock — previous run crashed
    rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

REPO=""
REF=""
SKIP_BUILD=0
NUM_NODES=3
MONITORING=0
SCENARIOS="standard"
CATEGORY="all"
PROFILE="local"
DURATION=""
LOCAL_SCALE="${LOCAL_SCALE:-0.8}"
KEEP=0
LB=0
AUTH=1
AUTH_USER=""
AUTH_PASS=""
EXPORT_PROM=0
TAG=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Options:
  --repo URL           Git repo to build from (default: current tree)
  --ref REF            Git ref to checkout (uses worktrees)
  --skip-build         Reuse existing Docker images
  --nodes N            VerneMQ cluster size (default: 3)
  --monitoring         Include Prometheus + Grafana containers
  --scenarios LIST     Numbers, "all", "standard", "core", "integration" (default: standard)
  --category CAT       core/integration/all (default: all)
  --profile VER        Version profile (default: local)
  --duration SECS      Phase duration override
  --scale FACTOR       LOCAL_SCALE (default: 0.4)
  --keep               Don't tear down after
  --lb               Include HAProxy load balancer
  --no-auth          Disable MQTT authentication
  --auth-user USER   Override auth username (default: benchuser)
  --auth-pass PASS   Override auth password (default: auto-generated)
  --export-prom        Export Prometheus snapshot (requires --monitoring)
  --tag TAG            Results label
  -h, --help           Show this help

Examples:
  $(basename "$0")                                          # Build + standard scenarios
  $(basename "$0") --ref v2.1.2 --scenarios all             # Build from git ref
  $(basename "$0") --nodes 5 --monitoring --category core   # 5-node cluster with monitoring
  $(basename "$0") --skip-build --scenarios 01,04,06        # Specific scenarios, reuse images
USAGE
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)        REPO="$2"; shift 2 ;;
        --ref)         REF="$2"; shift 2 ;;
        --skip-build)  SKIP_BUILD=1; shift ;;
        --nodes)       NUM_NODES="$2"; shift 2 ;;
        --monitoring)  MONITORING=1; shift ;;
        --scenarios)   SCENARIOS="$2"; shift 2 ;;
        --category)    CATEGORY="$2"; shift 2 ;;
        --profile)     PROFILE="$2"; shift 2 ;;
        --duration)    DURATION="$2"; shift 2 ;;
        --scale)       LOCAL_SCALE="$2"; shift 2 ;;
        --keep)        KEEP=1; shift ;;
        --lb)          LB=1; shift ;;
        --no-auth)     AUTH=0; shift ;;
        --auth-user)   AUTH_USER="$2"; shift 2 ;;
        --auth-pass)   AUTH_PASS="$2"; shift 2 ;;
        --export-prom) EXPORT_PROM=1; shift ;;
        --tag)         TAG="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *)             echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    echo "[$(date -u '+%H:%M:%S')] $*"
}

cleanup() {
    if [[ "$KEEP" -eq 0 ]]; then
        log "Tearing down cluster..."
        cd "$SCRIPT_DIR"
        docker compose down -v 2>/dev/null || true
    else
        log "Keeping cluster running (--keep). Tear down with: cd bench/local && docker compose down -v"
    fi

    # Clean up worktree if we created one
    if [[ -n "${WORKTREE_DIR:-}" && -d "${WORKTREE_DIR:-}" ]]; then
        log "Removing worktree ${WORKTREE_DIR}..."
        git -C "$PROJECT_ROOT" worktree remove "$WORKTREE_DIR" 2>/dev/null || true
    fi

    cleanup_lock
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Build VMQ node list
# ---------------------------------------------------------------------------

VMQ_NODE_LIST=""
for (( i=1; i<=NUM_NODES; i++ )); do
    VMQ_NODE_LIST="${VMQ_NODE_LIST:+$VMQ_NODE_LIST }vmq${i}"
done

# ---------------------------------------------------------------------------
# 1. Build images
# ---------------------------------------------------------------------------

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    BUILD_CONTEXT="$PROJECT_ROOT"

    # If --ref is specified, use a git worktree
    if [[ -n "$REF" ]]; then
        if [[ -n "$REPO" && "$REPO" != "." ]]; then
            # Clone external repo into temp dir
            BUILD_CONTEXT="/tmp/vmq-bench-build-$$"
            log "Cloning ${REPO}@${REF} into ${BUILD_CONTEXT}..."
            git clone --depth 1 --branch "$REF" "$REPO" "$BUILD_CONTEXT"
            WORKTREE_DIR=""  # not a worktree, just a clone
            # Copy bench files
            mkdir -p "${BUILD_CONTEXT}/bench/local"
            cp "${SCRIPT_DIR}/Dockerfile" "${BUILD_CONTEXT}/bench/local/Dockerfile"
            cp "${SCRIPT_DIR}/entrypoint.sh" "${BUILD_CONTEXT}/bench/local/entrypoint.sh"
        else
            # Use git worktree from current repo
            WORKTREE_DIR="/tmp/vmq-bench-worktree-$$"
            log "Creating worktree for ${REF} at ${WORKTREE_DIR}..."
            git -C "$PROJECT_ROOT" worktree remove "$WORKTREE_DIR" 2>/dev/null || true
            rm -rf "$WORKTREE_DIR"
            git -C "$PROJECT_ROOT" worktree add "$WORKTREE_DIR" "$REF"
            # Copy bench files into worktree
            mkdir -p "${WORKTREE_DIR}/bench/local"
            cp "${SCRIPT_DIR}/Dockerfile" "${WORKTREE_DIR}/bench/local/Dockerfile"
            cp "${SCRIPT_DIR}/entrypoint.sh" "${WORKTREE_DIR}/bench/local/entrypoint.sh"
            BUILD_CONTEXT="$WORKTREE_DIR"
        fi
    fi

    log "Building VerneMQ image from ${BUILD_CONTEXT}..."
    docker build -t vmq-local-bench -f "${BUILD_CONTEXT}/bench/local/Dockerfile" "$BUILD_CONTEXT"

    log "Building emqtt-bench image..."
    docker build -t emqtt-bench-local -f "${SCRIPT_DIR}/Dockerfile.bench" "$SCRIPT_DIR"
else
    log "Skipping build (--skip-build)"
fi

# ---------------------------------------------------------------------------
# 2. Generate docker-compose.yml
# ---------------------------------------------------------------------------

# Auto-detect version family from ref name
if [[ -z "${VMQ_VERSION_FAMILY:-}" ]]; then
    if [[ "${REF:-}" == *integration* ]]; then
        export VMQ_VERSION_FAMILY="integration"
    else
        export VMQ_VERSION_FAMILY="2.x"
    fi
fi
log "Version family: ${VMQ_VERSION_FAMILY}"

log "Generating docker-compose.yml (${NUM_NODES} nodes$([ "$MONITORING" -eq 1 ] && echo ' + monitoring'))..."
COMPOSE_ARGS=(--nodes "$NUM_NODES")
if (( MONITORING )); then
    COMPOSE_ARGS+=(--monitoring)
fi
if (( LB )); then
    COMPOSE_ARGS+=(--lb)
fi
if (( AUTH )); then
    # Ensure defaults before passing to generate_compose
    AUTH_USER="${AUTH_USER:-benchuser}"
    AUTH_PASS="${AUTH_PASS:-$(openssl rand -base64 18)}"
    COMPOSE_ARGS+=(--auth --auth-user "$AUTH_USER" --auth-pass "$AUTH_PASS")
else
    COMPOSE_ARGS+=(--no-auth)
fi
bash "${SCRIPT_DIR}/generate_compose.sh" "${COMPOSE_ARGS[@]}"

# ---------------------------------------------------------------------------
# Auth setup
# ---------------------------------------------------------------------------

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

# LB setup
if (( LB )); then
    export LB_HOST="haproxy"
    export BENCH_USE_LB="1"
    log "LB: enabled (haproxy)"
fi

# ---------------------------------------------------------------------------
# 3. Start cluster
# ---------------------------------------------------------------------------

cd "$SCRIPT_DIR"
log "Starting ${NUM_NODES}-node VerneMQ cluster..."
docker compose up -d

# ---------------------------------------------------------------------------
# 4. Wait for healthy cluster
# ---------------------------------------------------------------------------

log "Waiting for cluster to form (${NUM_NODES} healthy nodes)..."
MAX_WAIT=180
ELAPSED=0
while (( ELAPSED < MAX_WAIT )); do
    RUNNING=$(docker exec vmq1 /opt/vernemq/bin/vmq-admin cluster show 2>/dev/null \
        | grep -c "true" || echo 0)
    if (( RUNNING >= NUM_NODES )); then
        log "Cluster ready: ${RUNNING}/${NUM_NODES} nodes"
        break
    fi
    log "Cluster: ${RUNNING}/${NUM_NODES} nodes ready, waiting..."
    sleep 5
    (( ELAPSED += 5 ))
done

if (( ELAPSED >= MAX_WAIT )); then
    log "ERROR: Cluster did not form within ${MAX_WAIT}s"
    docker exec vmq1 /opt/vernemq/bin/vmq-admin cluster show 2>/dev/null || true
    exit 1
fi

docker exec vmq1 /opt/vernemq/bin/vmq-admin cluster show

# ---------------------------------------------------------------------------
# 5. Resolve scenarios
# ---------------------------------------------------------------------------

RESULTS_DIR="${SCRIPT_DIR}/results"
mkdir -p "$RESULTS_DIR"

if [[ -z "$TAG" ]]; then
    TAG="${REF:-local}-$(date +%Y%m%d-%H%M%S)"
fi

resolve_scenario_scripts() {
    local input="$1"
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

    # Comma-separated numbers
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

scenario_list=$(resolve_scenario_scripts "$SCENARIOS")

if [[ -z "$scenario_list" ]]; then
    log "ERROR: No scenarios resolved from: $SCENARIOS"
    exit 1
fi

# ---------------------------------------------------------------------------
# 6. Run scenarios via transport abstraction
# ---------------------------------------------------------------------------

log "========================================="
log "VerneMQ Local Benchmark"
log "========================================="
log "Nodes:      ${NUM_NODES}"
log "Scenarios:  ${SCENARIOS}"
log "Category:   ${CATEGORY}"
log "Profile:    ${PROFILE}"
log "Scale:      ${LOCAL_SCALE}"
log "Tag:        ${TAG}"
log "Monitoring: $([ "$MONITORING" -eq 1 ] && echo 'yes' || echo 'no')"
log "Auth:       $([ "$AUTH" -eq 1 ] && echo 'yes' || echo 'no')"
log "LB:         $([ "$LB" -eq 1 ] && echo 'yes' || echo 'no')"
log "========================================="

SCENARIO_COUNT=0
SCENARIO_PASS=0
SCENARIO_FAIL=0

while IFS= read -r scenario_script; do
    [[ -z "$scenario_script" ]] && continue

    scenario_name=$(basename "$scenario_script" .sh)
    SCENARIO_COUNT=$((SCENARIO_COUNT + 1))

    log "--- Running scenario: ${scenario_name} ---"

    # Export environment for the scenario (uses cloud common.sh via transport abstraction)
    if BENCH_TRANSPORT=docker \
        VMQ_NODES="$VMQ_NODE_LIST" \
        BENCH_NODES="bench" \
        VMQ_ADMIN="/opt/vernemq/bin/vmq-admin" \
        VMQ_VERSION="${PROFILE}" \
        RESULTS_DIR="${RESULTS_DIR}" \
        SCENARIO_TAG="${scenario_name}" \
        LOCAL_SCALE="$LOCAL_SCALE" \
        PROMETHEUS_URL="$([ "$MONITORING" -eq 1 ] && echo 'http://prometheus:9090' || echo '')" \
        MONITOR_HOST="" \
        DURATION="${DURATION:-}" \
        LOAD_MULTIPLIER="1" \
        BENCH_MQTT_USERNAME="${BENCH_MQTT_USERNAME:-}" \
        BENCH_MQTT_PASSWORD="${BENCH_MQTT_PASSWORD:-}" \
        LB_HOST="${LB_HOST:-}" \
        BENCH_USE_LB="${BENCH_USE_LB:-0}" \
        bash "$scenario_script"; then
        log "--- Scenario ${scenario_name}: PASSED ---"
        SCENARIO_PASS=$((SCENARIO_PASS + 1))
    else
        log "--- Scenario ${scenario_name}: FAILED ---"
        SCENARIO_FAIL=$((SCENARIO_FAIL + 1))
    fi
done <<< "$scenario_list"

# ---------------------------------------------------------------------------
# 7. Export Prometheus data if requested
# ---------------------------------------------------------------------------

if (( EXPORT_PROM && MONITORING )); then
    log "Exporting Prometheus snapshot..."
    bash "${BENCH_DIR}/scripts/export_prometheus.sh" \
        --prometheus-url "http://localhost:9090" \
        --results-dir "$RESULTS_DIR" \
        --start-epoch "$(date -d '-1 hour' +%s 2>/dev/null || date -v-1H +%s)" \
        --end-epoch "$(date +%s)" 2>&1 || \
        log "WARNING: Prometheus export failed"
fi

# ---------------------------------------------------------------------------
# 8. Summary
# ---------------------------------------------------------------------------

log "========================================="
log "RESULTS SUMMARY"
log "========================================="

for (( i=1; i<=NUM_NODES; i++ )); do
    DROPS=$(docker exec "vmq${i}" /opt/vernemq/bin/vmq-admin metrics show 2>/dev/null \
        | grep "cluster_bytes_dropped" | awk -F' = ' '{print $2}' | head -1 || echo "N/A")
    log "vmq${i} cluster_bytes_dropped: ${DROPS}"
done

log "Results:    ${RESULTS_DIR}"
log "Scenarios:  ${SCENARIO_COUNT} total, ${SCENARIO_PASS} passed, ${SCENARIO_FAIL} failed"
log "========================================="

if (( SCENARIO_FAIL > 0 )); then
    exit 1
fi
