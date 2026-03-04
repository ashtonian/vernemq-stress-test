#!/usr/bin/env bash
# infra_down.sh - Tear down benchmark infrastructure
#
# By default, destroys only the compute module (VerneMQ + bench nodes),
# leaving monitoring (Prometheus/Grafana) and network intact.
#
# Use --all to destroy everything (compute → monitoring → network).
# Use --cluster-id to destroy a specific workspace cluster.
#
# Usage:
#   ./scripts/infra_down.sh              # Destroy compute only
#   ./scripts/infra_down.sh --all        # Destroy everything
#   ./scripts/infra_down.sh --cluster-id cluster-1 --auto-approve
#   ./scripts/infra_down.sh --auto-approve

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${BENCH_DIR}/terraform"

DESTROY_ALL=false
AUTO_APPROVE=""
CLUSTER_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)           DESTROY_ALL=true; shift ;;
        --auto-approve)  AUTO_APPROVE="-auto-approve"; shift ;;
        --cluster-id)    CLUSTER_ID="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--all] [--auto-approve] [--cluster-id ID]"
            echo ""
            echo "  --all           Destroy all modules (compute + monitoring + network)"
            echo "  --auto-approve  Skip interactive approval"
            echo "  --cluster-id ID Destroy a specific workspace cluster and clean up"
            echo ""
            echo "Without --all or --cluster-id, only the default compute module is destroyed."
            exit 0
            ;;
        *)  echo "Unknown option: $1"; exit 1 ;;
    esac
done

log() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

tf_destroy() {
    local module="$1"
    local module_dir="${TF_DIR}/${module}"

    if [[ ! -d "$module_dir" ]]; then
        log "SKIP: ${module} directory not found"
        return 0
    fi

    local var_file_arg=""
    if [[ -f "${TF_DIR}/shared.tfvars" ]]; then
        var_file_arg="-var-file=../shared.tfvars"
    fi

    log "=== Destroying: ${module} ==="
    terraform -chdir="$module_dir" init -input=false > /dev/null 2>&1 || true
    # shellcheck disable=SC2086
    terraform -chdir="$module_dir" destroy $var_file_arg $AUTO_APPROVE
}

if [[ -n "$CLUSTER_ID" ]]; then
    # ---- Workspace-scoped destroy ----
    log "========================================="
    log "Destroying compute cluster: ${CLUSTER_ID}"
    log "========================================="

    local_compute_dir="${TF_DIR}/compute"

    terraform -chdir="$local_compute_dir" init -input=false
    terraform -chdir="$local_compute_dir" workspace select "$CLUSTER_ID"

    var_file_arg=""
    if [[ -f "${TF_DIR}/shared.tfvars" ]]; then
        var_file_arg="-var-file=../shared.tfvars"
    fi

    # shellcheck disable=SC2086
    terraform -chdir="$local_compute_dir" destroy $var_file_arg $AUTO_APPROVE

    # Switch back to default workspace and delete the cluster workspace
    terraform -chdir="$local_compute_dir" workspace select default
    terraform -chdir="$local_compute_dir" workspace delete "$CLUSTER_ID" || \
        log "WARNING: Could not delete workspace ${CLUSTER_ID}"

    # Remove inventory file
    INVENTORY_FILE="${BENCH_DIR}/ansible/inventory/hosts-${CLUSTER_ID}"
    if [[ -f "$INVENTORY_FILE" ]]; then
        rm -f "$INVENTORY_FILE"
        log "Removed inventory: ${INVENTORY_FILE}"
    fi

    log "Cluster ${CLUSTER_ID} destroyed and workspace cleaned up."
else
    # ---- Standard destroy ----
    log "========================================="
    if $DESTROY_ALL; then
        log "Destroying ALL infrastructure"
    else
        log "Destroying compute only (monitoring stays)"
    fi
    log "========================================="

    # Always destroy compute first
    tf_destroy "compute"

    if $DESTROY_ALL; then
        tf_destroy "monitoring"
        tf_destroy "network"
        log "All infrastructure destroyed"
    else
        log "Compute destroyed. Monitoring and network remain."
        log "To destroy everything: $0 --all"
    fi
fi
