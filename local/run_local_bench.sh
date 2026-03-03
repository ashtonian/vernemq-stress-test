#!/usr/bin/env bash
# run_local_bench.sh - Build, start 3-node cluster, run scenarios, collect results.
#
# Usage:
#   ./run_local_bench.sh                          # Build + run all scenarios
#   ./run_local_bench.sh --scenarios 01,04        # Specific scenarios
#   ./run_local_bench.sh --skip-build             # Reuse existing images
#   ./run_local_bench.sh --keep                   # Don't tear down after
#   ./run_local_bench.sh --scale 0.125            # Override LOCAL_SCALE (default 0.125)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Defaults
SCENARIOS="01,04,06"
SKIP_BUILD=0
KEEP=0
LOCAL_SCALE="${LOCAL_SCALE:-0.125}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenarios)
            SCENARIOS="$2"; shift 2 ;;
        --skip-build)
            SKIP_BUILD=1; shift ;;
        --keep)
            KEEP=1; shift ;;
        --scale)
            LOCAL_SCALE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--scenarios 01,04,06] [--skip-build] [--keep] [--scale 0.125]"
            exit 0 ;;
        *)
            echo "Unknown option: $1"; exit 1 ;;
    esac
done

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
}

# ---------------------------------------------------------------------------
# 1. Build images
# ---------------------------------------------------------------------------
if [[ "$SKIP_BUILD" -eq 0 ]]; then
    log "Building VerneMQ image from current source..."
    docker build -t vmq-local-bench -f "${SCRIPT_DIR}/Dockerfile" "$PROJECT_ROOT"

    log "Building emqtt-bench image..."
    docker build -t emqtt-bench-local -f "${SCRIPT_DIR}/Dockerfile.bench" "$SCRIPT_DIR"
else
    log "Skipping build (--skip-build)"
fi

# ---------------------------------------------------------------------------
# 2. Start cluster
# ---------------------------------------------------------------------------
cd "$SCRIPT_DIR"
log "Starting 3-node VerneMQ cluster..."
docker compose up -d

# ---------------------------------------------------------------------------
# 3. Wait for healthy cluster
# ---------------------------------------------------------------------------
log "Waiting for cluster to form (3 healthy nodes)..."
MAX_WAIT=180
ELAPSED=0
while (( ELAPSED < MAX_WAIT )); do
    RUNNING=$(docker exec vmq1 /opt/vernemq/bin/vmq-admin cluster show 2>/dev/null \
        | grep -c "true" || echo 0)
    if (( RUNNING >= 3 )); then
        log "Cluster ready: $RUNNING/3 nodes"
        break
    fi
    log "Cluster: $RUNNING/3 nodes ready, waiting..."
    sleep 5
    (( ELAPSED += 5 ))
done

if (( ELAPSED >= MAX_WAIT )); then
    log "ERROR: Cluster did not form within ${MAX_WAIT}s"
    docker exec vmq1 /opt/vernemq/bin/vmq-admin cluster show 2>/dev/null || true
    cleanup
    exit 1
fi

# Show cluster status
docker exec vmq1 /opt/vernemq/bin/vmq-admin cluster show

# ---------------------------------------------------------------------------
# 4. Create results directory
# ---------------------------------------------------------------------------
mkdir -p "${SCRIPT_DIR}/results"

# ---------------------------------------------------------------------------
# 5. Run scenarios
# ---------------------------------------------------------------------------
IFS=',' read -ra SCENARIO_LIST <<< "$SCENARIOS"
FAILED=0

for scenario_num in "${SCENARIO_LIST[@]}"; do
    # Find matching scenario script
    SCENARIO_SCRIPT=$(ls "${SCRIPT_DIR}/scenarios/${scenario_num}"_*.sh 2>/dev/null | head -1)
    if [[ -z "$SCENARIO_SCRIPT" ]]; then
        log "WARNING: No scenario script found for '${scenario_num}', skipping"
        continue
    fi

    SCENARIO_BASENAME=$(basename "$SCENARIO_SCRIPT")
    log "=========================================="
    log "Running scenario: ${SCENARIO_BASENAME}"
    log "=========================================="

    if LOCAL_SCALE="$LOCAL_SCALE" \
        RESULTS_DIR="${SCRIPT_DIR}/results" \
        SCENARIO_TAG="${scenario_num}_$(date +%Y%m%d_%H%M%S)" \
        bash "${SCENARIO_SCRIPT}"; then
        log "Scenario ${scenario_num} completed successfully"
    else
        log "ERROR: Scenario ${scenario_num} failed (exit code $?)"
        FAILED=$((FAILED + 1))
    fi
done

# ---------------------------------------------------------------------------
# 6. Final summary
# ---------------------------------------------------------------------------
log "=========================================="
log "RESULTS SUMMARY"
log "=========================================="

# Report cluster_bytes_dropped across all nodes
for i in 1 2 3; do
    DROPS=$(docker exec "vmq${i}" /opt/vernemq/bin/vmq-admin metrics show 2>/dev/null \
        | grep "cluster_bytes_dropped" | awk -F' = ' '{print $2}' | head -1 || echo "N/A")
    log "vmq${i} cluster_bytes_dropped: ${DROPS}"
done

log "Results saved to: ${SCRIPT_DIR}/results/"
log "Scenarios run: ${#SCENARIO_LIST[@]}, Failed: ${FAILED}"

# ---------------------------------------------------------------------------
# 7. Cleanup
# ---------------------------------------------------------------------------
cleanup

if (( FAILED > 0 )); then
    exit 1
fi
