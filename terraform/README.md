# Terraform — Infrastructure

Three independent modules with separate state files, applied in order:

| Module | Resources | Destroy frequency |
|--------|-----------|-------------------|
| `network/` | VPC, subnets, IGW, NAT, route tables, placement group | Rarely |
| `monitoring/` | Monitor EC2 instance, Prometheus, Grafana (HTTPS), password | Between campaigns |
| `compute/` | VerneMQ nodes, bench nodes, security groups, Ansible inventory | Between runs |

The `iam/` module is a one-time bootstrap step and is not part of the regular apply/destroy cycle. See [IAM Bootstrap](#iam-bootstrap) below.

## Quick Start

```bash
# Provision everything (recommended)
../scripts/infra_up.sh

# Tear down compute only
../scripts/infra_down.sh

# Tear down everything
../scripts/infra_down.sh --all
```

## Manual Module Management

```bash
# Copy and edit shared variables
cp shared.tfvars.example shared.tfvars

# Apply in order: network → monitoring → compute
terraform -chdir=network  init && terraform -chdir=network  apply -var-file=../shared.tfvars
terraform -chdir=monitoring init && terraform -chdir=monitoring apply -var-file=../shared.tfvars
terraform -chdir=compute  init && terraform -chdir=compute  apply -var-file=../shared.tfvars

# Destroy a single module
terraform -chdir=compute destroy -var-file=../shared.tfvars
```

## Workspaces (Multi-Cluster)

The `compute/` module supports Terraform workspaces for running multiple clusters simultaneously (used by `run_matrix.sh --parallel`):

```bash
../scripts/infra_up.sh --cluster-id cluster-a
../scripts/infra_up.sh --cluster-id cluster-b
../scripts/infra_down.sh --cluster-id cluster-a
```

Each workspace gets its own state and generates a separate Ansible inventory file at `ansible/inventory/hosts.<cluster-id>`.

## State

State files are stored locally under `state/` (gitignored). For team use, configure remote backends in each module's `backend.tf`.

## IAM Bootstrap

The `iam/` module creates a scoped IAM user (`vernemq-bench-operator`) with only the EC2/VPC permissions needed by the network, monitoring, and compute modules. No S3, Lambda, or RDS access is granted.

### Automated Setup (Recommended)

```bash
# Run from the repo root — uses your admin profile to create the operator user
./scripts/bootstrap.sh --profile <your-admin-profile>
```

The script will:
1. Create the IAM user and access key via Terraform
2. Configure an AWS CLI profile named `vernemq-bench`
3. Generate `shared.tfvars` with the new profile and your key pair name

### Manual Setup

```bash
# 1. Create the IAM user
terraform -chdir=iam init
terraform -chdir=iam apply -var 'aws_profile=<your-admin-profile>'

# 2. Extract credentials
terraform -chdir=iam output access_key_id
terraform -chdir=iam output -raw secret_access_key

# 3. Configure AWS CLI profile
aws configure set aws_access_key_id     <key-id>     --profile vernemq-bench
aws configure set aws_secret_access_key <secret-key> --profile vernemq-bench
aws configure set region                us-east-1    --profile vernemq-bench

# 4. Create shared.tfvars
cp shared.tfvars.example shared.tfvars
# Edit shared.tfvars — set key_pair_name and aws_profile = "vernemq-bench"
```

### Teardown

```bash
terraform -chdir=iam destroy -var 'aws_profile=<your-admin-profile>'
```

This removes the IAM user and access key. Remember to also delete the AWS CLI profile from `~/.aws/credentials` and `~/.aws/config`.

## Configuration

All modules share variables via `shared.tfvars`. See `shared.tfvars.example` for the full list. Key variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `key_pair_name` | *(required)* | AWS EC2 key pair name |
| `aws_region` | `us-east-1` | AWS region |
| `aws_profile` | `default` | AWS CLI profile |
| `vmq_node_count` | `3` | VerneMQ cluster size (1–50) |
| `bench_node_count` | `1` | Benchmark client nodes (1–20) |
| `instance_type_vmq` | `c6i.2xlarge` | VerneMQ instance type |
| `instance_type_bench` | `c6i.2xlarge` | Bench instance type |
| `instance_type_monitor` | `c6i.xlarge` | Monitor instance type |
| `project_name` | `vernemq-bench` | Resource tagging prefix |
| `allowed_ssh_cidr` | `0.0.0.0/0` | CIDR for SSH/Grafana access |
| `enable_lb` | `false` | Deploy internal NLB for MQTT load balancing |
| `enable_auth` | `true` | Generate MQTT credentials for benchmark auth |
| `bench_username` | `benchuser` | MQTT username for benchmark clients |

### Bench Node Sizing

A single `c6i.2xlarge` (8 vCPU) handles ~120-150k active emqtt-bench connections. Scale `bench_node_count` or `instance_type_bench` for large clusters:

- **1-3 VMQ nodes, LOAD_MULTIPLIER=1**: 1x `c6i.2xlarge` (default)
- **5+ VMQ nodes or LOAD_MULTIPLIER>1**: upsize to `c6i.4xlarge` (~250-300k) or add bench nodes
- **10 VMQ nodes, LOAD_MULTIPLIER=3**: 3x `c6i.4xlarge` or 2x `c6i.8xlarge`

See the main [README](../README.md#bench-node-sizing) for the full sizing table.
