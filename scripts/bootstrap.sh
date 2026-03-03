#!/usr/bin/env bash
#
# bootstrap.sh — One-time setup for vernemq-bench AWS infrastructure.
#
# Creates a scoped IAM user, configures an AWS CLI profile, and generates
# terraform/shared.tfvars so you can start provisioning immediately.
#
# Usage:
#   ./scripts/bootstrap.sh --profile <admin-profile>
#
# The --profile flag specifies which AWS CLI profile has IAM admin permissions
# (used only during bootstrap to create the scoped operator user).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IAM_DIR="$REPO_ROOT/terraform/iam"
SHARED_TFVARS="$REPO_ROOT/terraform/shared.tfvars"
SHARED_TFVARS_EXAMPLE="$REPO_ROOT/terraform/shared.tfvars.example"

ADMIN_PROFILE="default"
AWS_REGION="us-east-1"
OPERATOR_PROFILE="vernemq-bench"
BENCH_ENV="$REPO_ROOT/bench.env"
DESTROY=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Bootstrap vernemq-bench AWS infrastructure.

Options:
  --profile PROFILE    AWS CLI profile with IAM admin permissions (default: default)
  --region REGION      AWS region (default: us-east-1)
  --operator-profile   Name for the new AWS CLI profile (default: vernemq-bench)
  --destroy            Tear down: destroy IAM user and remove bench.env + shared.tfvars
  -h, --help           Show this help message

Example:
  $(basename "$0") --profile home-ops
  $(basename "$0") --destroy --profile home-ops
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      ADMIN_PROFILE="$2"
      shift 2
      ;;
    --region)
      AWS_REGION="$2"
      shift 2
      ;;
    --operator-profile)
      OPERATOR_PROFILE="$2"
      shift 2
      ;;
    --destroy)
      DESTROY=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Destroy mode
# ---------------------------------------------------------------------------

if $DESTROY; then
  echo "==> Destroying bootstrap artifacts..."

  # Destroy IAM user via Terraform
  if [[ -d "$IAM_DIR" ]]; then
    echo "    Destroying IAM user..."
    terraform -chdir="$IAM_DIR" destroy -input=false -auto-approve \
      -var "aws_profile=$ADMIN_PROFILE" \
      -var "aws_region=$AWS_REGION" || echo "WARNING: IAM destroy had errors"
  fi

  # Remove local artifacts
  for f in "$BENCH_ENV" "$SHARED_TFVARS"; do
    if [[ -f "$f" ]]; then
      rm -f "$f"
      echo "    Removed $(basename "$f")"
    fi
  done

  echo ""
  echo "  Bootstrap artifacts destroyed."
  echo "  AWS CLI profile '$OPERATOR_PROFILE' was NOT removed (run 'aws configure' to clean up)."
  exit 0
fi

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

echo "==> Checking prerequisites..."

missing=()
command -v terraform >/dev/null 2>&1 || missing+=("terraform")
command -v aws >/dev/null 2>&1       || missing+=("aws (AWS CLI v2)")

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: Missing required tools: ${missing[*]}" >&2
  exit 1
fi

echo "    terraform: $(terraform version -json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || terraform version | head -1)"
echo "    aws cli:   $(aws --version 2>&1 | awk '{print $1}')"

# Verify the admin profile works
if ! aws sts get-caller-identity --profile "$ADMIN_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "ERROR: AWS profile '$ADMIN_PROFILE' is not configured or lacks permissions." >&2
  echo "       Run 'aws configure --profile $ADMIN_PROFILE' first." >&2
  exit 1
fi

echo "    admin profile '$ADMIN_PROFILE': OK"

# ---------------------------------------------------------------------------
# Terraform: create IAM user
# ---------------------------------------------------------------------------

echo ""
echo "==> Creating scoped IAM operator user..."

terraform -chdir="$IAM_DIR" init -input=false

terraform -chdir="$IAM_DIR" apply -input=false -auto-approve \
  -var "aws_profile=$ADMIN_PROFILE" \
  -var "aws_region=$AWS_REGION"

# ---------------------------------------------------------------------------
# Extract credentials from Terraform output
# ---------------------------------------------------------------------------

ACCESS_KEY_ID="$(terraform -chdir="$IAM_DIR" output -raw access_key_id)"
SECRET_ACCESS_KEY="$(terraform -chdir="$IAM_DIR" output -raw secret_access_key)"
IAM_USER="$(terraform -chdir="$IAM_DIR" output -raw user_name)"

echo ""
echo "==> Configuring AWS CLI profile '$OPERATOR_PROFILE'..."

aws configure set aws_access_key_id     "$ACCESS_KEY_ID"     --profile "$OPERATOR_PROFILE"
aws configure set aws_secret_access_key "$SECRET_ACCESS_KEY" --profile "$OPERATOR_PROFILE"
aws configure set region                "$AWS_REGION"        --profile "$OPERATOR_PROFILE"

echo "    Profile '$OPERATOR_PROFILE' configured."

# ---------------------------------------------------------------------------
# Generate shared.tfvars
# ---------------------------------------------------------------------------

if [[ -f "$SHARED_TFVARS" ]]; then
  echo ""
  echo "    terraform/shared.tfvars already exists — skipping generation."
  echo "    Make sure aws_profile is set to '$OPERATOR_PROFILE'."
else
  echo ""
  echo "==> Generating terraform/shared.tfvars..."

  # Prompt for key pair name
  read -rp "    AWS key pair name (in $AWS_REGION): " KEY_PAIR_NAME
  if [[ -z "$KEY_PAIR_NAME" ]]; then
    echo "ERROR: key_pair_name is required." >&2
    exit 1
  fi

  cat > "$SHARED_TFVARS" <<EOF
key_pair_name = "$KEY_PAIR_NAME"
aws_profile   = "$OPERATOR_PROFILE"
EOF

  echo "    Created terraform/shared.tfvars"
fi

# ---------------------------------------------------------------------------
# Prompt for SSH private key path and generate bench.env
# ---------------------------------------------------------------------------

if [[ -f "$BENCH_ENV" ]]; then
  echo ""
  echo "    bench.env already exists — skipping generation."
  echo "    Verify SSH_KEY path is correct in bench.env."
else
  echo ""
  echo "==> Configuring SSH key for benchmark scripts..."

  # Read key pair name from shared.tfvars if we didn't just prompt for it
  if [[ -z "${KEY_PAIR_NAME:-}" ]]; then
    KEY_PAIR_NAME=$(grep 'key_pair_name' "$SHARED_TFVARS" 2>/dev/null | sed 's/.*= *"\(.*\)"/\1/' || true)
  fi

  read -rp "    Path to SSH private key (.pem) for key pair '${KEY_PAIR_NAME:-unknown}': " SSH_KEY_PATH

  if [[ -z "$SSH_KEY_PATH" ]]; then
    echo "ERROR: SSH key path is required." >&2
    exit 1
  fi

  # Expand ~ to $HOME
  SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"

  if [[ ! -f "$SSH_KEY_PATH" ]]; then
    echo "ERROR: File not found: $SSH_KEY_PATH" >&2
    exit 1
  fi

  # Validate and auto-fix permissions
  local_perms=$(stat -f '%Lp' "$SSH_KEY_PATH" 2>/dev/null || stat -c '%a' "$SSH_KEY_PATH" 2>/dev/null || true)
  if [[ "$local_perms" != "600" && "$local_perms" != "400" ]]; then
    echo "    Fixing permissions on $SSH_KEY_PATH (was $local_perms, setting to 600)..."
    chmod 600 "$SSH_KEY_PATH"
  fi

  # Validate key pair exists in AWS (warn only, don't block)
  if [[ -n "${KEY_PAIR_NAME:-}" ]]; then
    if aws ec2 describe-key-pairs --key-names "$KEY_PAIR_NAME" \
        --profile "$OPERATOR_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
      echo "    Key pair '$KEY_PAIR_NAME' found in AWS ($AWS_REGION)"
    else
      echo "    WARNING: Key pair '$KEY_PAIR_NAME' not found in AWS ($AWS_REGION)."
      echo "             Make sure it exists before provisioning infrastructure."
    fi
  fi

  cat > "$BENCH_ENV" <<EOF
export SSH_KEY="$SSH_KEY_PATH"
export AWS_PROFILE="$OPERATOR_PROFILE"
export AWS_REGION="$AWS_REGION"
EOF

  echo "    Created bench.env"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "============================================"
echo "  Bootstrap complete!"
echo "============================================"
echo ""
echo "  IAM user:    $IAM_USER"
echo "  AWS profile: $OPERATOR_PROFILE"
echo "  Region:      $AWS_REGION"
echo "  SSH key:     sourced automatically from bench.env"
echo ""
echo "  Next steps:"
echo ""
echo "    # 1. Provision infrastructure"
echo "    ./scripts/infra_up.sh"
echo ""
echo "    # 2. Run a benchmark (SSH key is handled automatically)"
echo "    ./scripts/run_benchmark.sh \\"
echo "        --repo https://github.com/vernemq/vernemq.git \\"
echo "        --ref v2.1.2 --tag my-first-run"
echo ""
echo "    # 3. Tear down when done"
echo "    ./scripts/infra_down.sh --all"
echo ""
echo "  To destroy all bootstrap artifacts (IAM user + bench.env + shared.tfvars):"
echo "    ./scripts/bootstrap.sh --destroy --profile $ADMIN_PROFILE"
echo ""
