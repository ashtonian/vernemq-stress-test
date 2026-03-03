#!/usr/bin/env bash
# infra_up.sh - Provision all benchmark infrastructure
#
# Orchestrates terraform init && apply for: network → monitoring → compute.
# Pass -var-file=../shared.tfvars to share common variables across modules.
#
# Usage:
#   ./scripts/infra_up.sh
#   ./scripts/infra_up.sh --auto-approve
#   ./scripts/infra_up.sh --cluster-id cluster-1 --auto-approve

set -euo pipefail

if ! command -v terraform &>/dev/null; then
    echo "ERROR: terraform not found in PATH"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${BENCH_DIR}/terraform"

AUTO_APPROVE=""
CLUSTER_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto-approve)  AUTO_APPROVE="-auto-approve"; shift ;;
        --cluster-id)    CLUSTER_ID="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--auto-approve] [--cluster-id ID]"
            echo ""
            echo "  --auto-approve  Skip interactive approval"
            echo "  --cluster-id ID Provision only compute in a named workspace"
            echo ""
            echo "Without --cluster-id, all three modules are provisioned."
            exit 0
            ;;
        *)  echo "Unknown option: $1"; exit 1 ;;
    esac
done

log() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

tf_apply() {
    local module="$1"
    local module_dir="${TF_DIR}/${module}"

    log "=== ${module}: init ==="
    terraform -chdir="$module_dir" init -input=false

    local var_file_arg=""
    if [[ -f "${TF_DIR}/shared.tfvars" ]]; then
        var_file_arg="-var-file=../shared.tfvars"
    fi

    log "=== ${module}: apply ==="
    # shellcheck disable=SC2086
    terraform -chdir="$module_dir" apply $var_file_arg $AUTO_APPROVE
}

if [[ -n "$CLUSTER_ID" ]]; then
    # ---- Workspace-scoped compute only ----
    log "========================================="
    log "Provisioning compute cluster: ${CLUSTER_ID}"
    log "========================================="

    local_compute_dir="${TF_DIR}/compute"

    terraform -chdir="$local_compute_dir" init -input=false
    terraform -chdir="$local_compute_dir" workspace select -or-create "$CLUSTER_ID"

    local var_file_arg=""
    if [[ -f "${TF_DIR}/shared.tfvars" ]]; then
        var_file_arg="-var-file=../shared.tfvars"
    fi

    log "=== compute (workspace: ${CLUSTER_ID}): apply ==="
    # shellcheck disable=SC2086
    terraform -chdir="$local_compute_dir" apply $var_file_arg $AUTO_APPROVE

    INVENTORY_PATH="${BENCH_DIR}/ansible/inventory/hosts-${CLUSTER_ID}"
    log "========================================="
    log "Cluster ${CLUSTER_ID} ready"
    log "Inventory: ${INVENTORY_PATH}"
    log "========================================="
else
    # ---- Full provisioning: network → monitoring → compute ----
    log "========================================="
    log "Provisioning benchmark infrastructure"
    log "========================================="

    # Apply order matters: network → monitoring → compute
    tf_apply "network"
    tf_apply "monitoring"
    tf_apply "compute"

    # Print useful outputs
    log "========================================="
    log "Infrastructure ready"
    log "========================================="

    MONITOR_IP=$(terraform -chdir="${TF_DIR}/monitoring" output -raw monitor_public_ip 2>/dev/null || echo "unknown")
    GRAFANA_URL=$(terraform -chdir="${TF_DIR}/monitoring" output -raw grafana_url 2>/dev/null || echo "unknown")

    log "Monitor IP:  ${MONITOR_IP}"
    log "Grafana URL: ${GRAFANA_URL}"
    log "Inventory:   ansible/inventory/hosts"
    log ""
    log "Retrieve Grafana password:"
    log "  terraform -chdir=terraform/monitoring output -raw grafana_admin_password"

    # SSH connectivity smoke test
    if [[ -f "${BENCH_DIR}/bench.env" ]]; then
        # shellcheck disable=SC1091
        source "${BENCH_DIR}/bench.env"
    fi

    if [[ -n "${SSH_KEY:-}" && "$MONITOR_IP" != "unknown" ]]; then
        log ""
        log "=== SSH connectivity check ==="
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
               -o BatchMode=yes -i "$SSH_KEY" \
               "ec2-user@${MONITOR_IP}" "echo ok" >/dev/null 2>&1; then
            log "Monitor: OK"
        else
            log "Monitor: FAILED"
            log ""
            log "Troubleshooting:"
            log "  - Instance may still be booting (wait 1-2 minutes and retry)"
            log "  - Security group may not allow SSH from your IP"
            log "  - Key pair mismatch: verify '$SSH_KEY' matches the key pair in shared.tfvars"
            log "  - Try manually: ssh -i $SSH_KEY ec2-user@${MONITOR_IP}"
        fi
    elif [[ -z "${SSH_KEY:-}" ]]; then
        log ""
        log "WARNING: SSH_KEY not set — skipping connectivity check."
        log "         Run ./scripts/bootstrap.sh or export SSH_KEY=/path/to/key.pem"
    fi
fi
