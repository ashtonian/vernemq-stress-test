#!/usr/bin/env bash
# run_ab_comparison.sh - A/B comparison of two branches/images.
#
# Usage:
#   ./run_ab_comparison.sh --branch-a main --branch-b integration_test --scenarios 04
#   ./run_ab_comparison.sh --image-a vmq-main --image-b vmq-integration --scenarios 01,04

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Defaults
BRANCH_A=""
BRANCH_B=""
IMAGE_A=""
IMAGE_B=""
SCENARIOS="${SCENARIOS:-04}"
LOCAL_SCALE="${LOCAL_SCALE:-0.125}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch-a) BRANCH_A="$2"; shift 2 ;;
        --branch-b) BRANCH_B="$2"; shift 2 ;;
        --image-a)  IMAGE_A="$2"; shift 2 ;;
        --image-b)  IMAGE_B="$2"; shift 2 ;;
        --scenarios) SCENARIOS="$2"; shift 2 ;;
        --scale)    LOCAL_SCALE="$2"; shift 2 ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]

Build from branches (uses git worktrees, safe for dirty working tree):
  --branch-a REF     Git ref for variant A (e.g. main)
  --branch-b REF     Git ref for variant B (e.g. integration_test)

Or use pre-built images:
  --image-a IMAGE    Docker image for variant A
  --image-b IMAGE    Docker image for variant B

Options:
  --scenarios LIST   Comma-separated scenario numbers (default: 04)
  --scale FACTOR     LOCAL_SCALE override (default: 0.125)
  -h, --help         Show this help
EOF
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

log() {
    echo "[$(date -u '+%H:%M:%S')] $*"
}

# ---------------------------------------------------------------------------
# Validate args
# ---------------------------------------------------------------------------
if [[ -z "$BRANCH_A" && -z "$IMAGE_A" ]] || [[ -z "$BRANCH_B" && -z "$IMAGE_B" ]]; then
    echo "ERROR: Must specify either --branch-a/--branch-b or --image-a/--image-b"
    echo "Run with --help for usage."
    exit 1
fi

# ---------------------------------------------------------------------------
# Build images from branches (using git worktrees for safety)
# ---------------------------------------------------------------------------
build_from_branch() {
    local ref="$1" image_name="$2"
    local worktree_dir="/tmp/vmq-bench-${image_name}"

    log "Creating worktree for ${ref} at ${worktree_dir}..."
    # Clean up any stale worktree
    git -C "$PROJECT_ROOT" worktree remove "$worktree_dir" 2>/dev/null || true
    rm -rf "$worktree_dir"

    git -C "$PROJECT_ROOT" worktree add "$worktree_dir" "$ref"

    # Copy bench/local files into worktree (the target branch may not have them)
    mkdir -p "${worktree_dir}/bench/local"
    cp "${SCRIPT_DIR}/Dockerfile" "${worktree_dir}/bench/local/Dockerfile"
    cp "${SCRIPT_DIR}/entrypoint.sh" "${worktree_dir}/bench/local/entrypoint.sh"

    log "Building image ${image_name} from ${ref}..."
    docker build -t "$image_name" -f "${worktree_dir}/bench/local/Dockerfile" "$worktree_dir"

    log "Removing worktree ${worktree_dir}..."
    git -C "$PROJECT_ROOT" worktree remove "$worktree_dir"
}

if [[ -n "$BRANCH_A" ]]; then
    IMAGE_A="vmq-ab-a"
    build_from_branch "$BRANCH_A" "$IMAGE_A"
fi

if [[ -n "$BRANCH_B" ]]; then
    IMAGE_B="vmq-ab-b"
    build_from_branch "$BRANCH_B" "$IMAGE_B"
fi

# Ensure emqtt-bench image exists
if ! docker image inspect emqtt-bench-local >/dev/null 2>&1; then
    log "Building emqtt-bench image..."
    docker build -t emqtt-bench-local -f "${SCRIPT_DIR}/Dockerfile.bench" "$SCRIPT_DIR"
fi

# ---------------------------------------------------------------------------
# Run scenarios for a given variant
# ---------------------------------------------------------------------------
run_variant() {
    local variant_name="$1" image_name="$2"
    local results_tag="ab_${variant_name}_$(date +%Y%m%d_%H%M%S)"

    log "=========================================="
    log "Running variant: ${variant_name} (image: ${image_name})"
    log "=========================================="

    cd "$SCRIPT_DIR"

    # Tag the variant image as vmq-local-bench so docker-compose uses it
    docker tag "$image_name" vmq-local-bench
    docker compose up -d

    # Wait for cluster
    log "Waiting for cluster formation..."
    local max_wait=180 elapsed=0
    while (( elapsed < max_wait )); do
        local running
        running=$(docker exec vmq1 /opt/vernemq/bin/vmq-admin cluster show 2>/dev/null \
            | grep -c "true" || echo 0)
        if (( running >= 3 )); then
            log "Cluster ready: $running/3 nodes"
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

    # Run scenarios
    mkdir -p "${SCRIPT_DIR}/results"
    IFS=',' read -ra SCENARIO_LIST <<< "$SCENARIOS"
    for scenario_num in "${SCENARIO_LIST[@]}"; do
        local script_name
        script_name=$(ls "${SCRIPT_DIR}/scenarios/${scenario_num}"_*.sh 2>/dev/null | head -1)
        if [[ -z "$script_name" ]]; then
            log "WARNING: No scenario ${scenario_num}, skipping"
            continue
        fi
        local basename
        basename=$(basename "$script_name")

        log "Running scenario ${basename} for variant ${variant_name}..."
        LOCAL_SCALE="$LOCAL_SCALE" \
            RESULTS_DIR="${SCRIPT_DIR}/results" \
            SCENARIO_TAG="${results_tag}_${scenario_num}" \
            bash "${SCRIPT_DIR}/scenarios/${basename}" || true
    done

    # Collect final cluster_bytes_dropped
    local drops_file="${SCRIPT_DIR}/results/${variant_name}_drops.txt"
    local total_drops=0
    for i in 1 2 3; do
        local d
        d=$(docker exec "vmq${i}" /opt/vernemq/bin/vmq-admin metrics show 2>/dev/null \
            | grep "cluster_bytes_dropped" | awk -F' = ' '{print $2}' | head -1 || echo 0)
        total_drops=$(( total_drops + d ))
        echo "vmq${i}: ${d}" >> "$drops_file"
    done
    echo "total: ${total_drops}" >> "$drops_file"
    log "Variant ${variant_name} total cluster_bytes_dropped: ${total_drops}"

    # Tear down
    docker compose down -v 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Run both variants
# ---------------------------------------------------------------------------
LABEL_A="${BRANCH_A:-$(echo "$IMAGE_A" | tr ':/' '_')}"
LABEL_B="${BRANCH_B:-$(echo "$IMAGE_B" | tr ':/' '_')}"

run_variant "$LABEL_A" "$IMAGE_A"
run_variant "$LABEL_B" "$IMAGE_B"

# ---------------------------------------------------------------------------
# Comparison report
# ---------------------------------------------------------------------------
log "=========================================="
log "A/B COMPARISON RESULTS"
log "=========================================="

DROPS_A="${SCRIPT_DIR}/results/${LABEL_A}_drops.txt"
DROPS_B="${SCRIPT_DIR}/results/${LABEL_B}_drops.txt"

log ""
log "Variant A (${LABEL_A}):"
if [[ -f "$DROPS_A" ]]; then
    cat "$DROPS_A" | while read -r line; do log "  $line"; done
else
    log "  (no data)"
fi

log ""
log "Variant B (${LABEL_B}):"
if [[ -f "$DROPS_B" ]]; then
    cat "$DROPS_B" | while read -r line; do log "  $line"; done
else
    log "  (no data)"
fi

TOTAL_A=$(grep "^total:" "$DROPS_A" 2>/dev/null | awk '{print $2}' || echo "N/A")
TOTAL_B=$(grep "^total:" "$DROPS_B" 2>/dev/null | awk '{print $2}' || echo "N/A")

log ""
log "cluster_bytes_dropped comparison:"
log "  A (${LABEL_A}): ${TOTAL_A}"
log "  B (${LABEL_B}): ${TOTAL_B}"

if [[ "$TOTAL_A" != "N/A" && "$TOTAL_B" != "N/A" ]]; then
    if (( TOTAL_A == 0 && TOTAL_B == 0 )); then
        log "  -> Both variants: zero drops"
    elif (( TOTAL_A > 0 && TOTAL_B == 0 )); then
        log "  -> Variant B fixed the regression (A had ${TOTAL_A} bytes dropped)"
    elif (( TOTAL_A == 0 && TOTAL_B > 0 )); then
        log "  -> WARNING: Variant B has regression (${TOTAL_B} bytes dropped)"
    else
        log "  -> Both variants show drops (A: ${TOTAL_A}, B: ${TOTAL_B})"
    fi
fi

log ""
log "Full results in: ${SCRIPT_DIR}/results/"
