#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_BASE="${BENCH_DIR}/profiles/default.yaml"
ANSIBLE_DIR="${BENCH_DIR}/ansible"
PROFILE=""
BASE="${DEFAULT_BASE}"

usage() {
    cat <<EOF
Usage: $(basename "$0") --profile PATH [--base PATH] [--ansible-dir PATH]

Apply a VerneMQ tuning profile via Ansible.

Options:
  --profile PATH       Path to the overlay profile YAML (required)
  --base PATH          Path to the base profile YAML (default: profiles/default.yaml)
  --ansible-dir PATH   Path to the Ansible directory (default: bench/ansible)
  -h, --help           Show this help message
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --base)
            BASE="$2"
            shift 2
            ;;
        --ansible-dir)
            ANSIBLE_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            usage
            ;;
    esac
done

if [[ -z "${PROFILE}" ]]; then
    echo "Error: --profile is required" >&2
    usage
fi

if [[ ! -f "${BASE}" ]]; then
    echo "Error: Base profile not found: ${BASE}" >&2
    exit 1
fi

if [[ ! -f "${PROFILE}" ]]; then
    echo "Error: Overlay profile not found: ${PROFILE}" >&2
    exit 1
fi

if [[ ! -d "${ANSIBLE_DIR}" ]]; then
    echo "Error: Ansible directory not found: ${ANSIBLE_DIR}" >&2
    exit 1
fi

MERGED_VARS="$(mktemp "${ANSIBLE_DIR}/merged_vars.XXXXXX.json")"
trap 'rm -f "${MERGED_VARS}"' EXIT

echo "Merging profiles:"
echo "  Base:    ${BASE}"
echo "  Overlay: ${PROFILE}"

python3 -c "
import yaml, json, sys

with open(sys.argv[1]) as f:
    base = yaml.safe_load(f)
with open(sys.argv[2]) as f:
    overlay = yaml.safe_load(f)

base_tunables = base.get('tunables', {})
overlay_tunables = overlay.get('tunables', {})

merged = {**base_tunables, **overlay_tunables}

with open(sys.argv[3], 'w') as f:
    json.dump(merged, f, indent=2)

overlay_meta = overlay.get('metadata', {})
print(f\"  Profile: {overlay_meta.get('name', 'unknown')}\")
print(f\"  Description: {overlay_meta.get('description', 'N/A')}\")
print(f\"  Merged {len(merged)} tunables ({len(overlay_tunables)} overrides)\")
" "${BASE}" "${PROFILE}" "${MERGED_VARS}"

echo ""
echo "Generated merged vars: ${MERGED_VARS}"
echo ""

echo "Deploying VerneMQ with merged configuration..."
(cd "${ANSIBLE_DIR}" && ansible-playbook -i "${ANSIBLE_INVENTORY:-${ANSIBLE_DIR}/inventory/hosts}" deploy_vernemq.yml -e "@${MERGED_VARS}")

echo ""
echo "Configuring cluster..."
(cd "${ANSIBLE_DIR}" && ansible-playbook -i "${ANSIBLE_INVENTORY:-${ANSIBLE_DIR}/inventory/hosts}" configure_cluster.yml)

echo ""
echo "Profile applied successfully."
