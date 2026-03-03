# VerneMQ Benchmark Suite

Automated benchmark and chaos-testing framework for [VerneMQ](https://vernemq.com/) MQTT broker clusters. Provisions infrastructure on AWS with Terraform, configures nodes with Ansible, and runs reproducible scenario-based benchmarks using [emqtt-bench](https://github.com/emqx/emqtt-bench). Also supports a fully local Docker mode that runs the same scenarios on a single machine without any cloud resources.

Supports A/B comparison, N-version matrix benchmarking, and targets any git repos/refs (tags, branches, or commits).

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Terraform | >= 1.14 | AWS infrastructure provisioning |
| Ansible | >= 2.20 | Node configuration and deployment |
| AWS CLI | v2 | Credentials and profile management |
| Python 3 | >= 3.11 | Helper scripts (matplotlib optional for charts) |
| Docker + Compose | latest | Local/single-machine benchmarks |

You also need an AWS key pair created in your target region (default: `us-east-1`).

## AWS Setup (First Time)

The benchmark suite requires an AWS IAM user with scoped EC2/VPC permissions. Run the bootstrap script once to create everything automatically:

```bash
# Creates a scoped IAM user, configures an AWS CLI profile, and generates shared.tfvars
./scripts/bootstrap.sh --profile <your-admin-profile>
```

This uses your existing admin profile to create a dedicated `vernemq-bench` operator user with only the permissions needed. See [terraform/README.md](terraform/README.md) for details and manual setup instructions.

## Quick Start — AWS

```bash
# 0. Bootstrap (once — creates IAM user + AWS profile + bench.env with SSH key)
./scripts/bootstrap.sh --profile <your-admin-profile>

# 1. (Optional) Install Python dependencies for chart generation
pip install -r requirements.txt

# 2. Provision infrastructure (network → monitoring → compute)
./scripts/infra_up.sh

# 3. Run benchmarks against any VerneMQ git ref (tag, branch, or commit)
./scripts/run_benchmark.sh \
    --repo https://github.com/your-org/vernemq.git \
    --ref my-feature-branch \
    --tag my-first-run

# 4. Tear down compute when done (monitoring stays for data review)
./scripts/infra_down.sh

# 5. Destroy everything when fully done
./scripts/infra_down.sh --all
```

## Quick Start — Local (Docker)

Run the same cloud scenarios on a single machine without any AWS resources. The Docker path uses a transport abstraction (`BENCH_TRANSPORT=docker`) that replaces SSH with `docker exec`, so all 11 cloud scenarios run unmodified (3 are skipped because they need host-level networking).

```bash
cd local

# Build + run standard scenarios on a 3-node cluster (auth on by default)
./run_local_bench.sh

# With load balancer (HAProxy)
./run_local_bench.sh --lb --scenarios 01,02 --nodes 5

# Without authentication
./run_local_bench.sh --no-auth

# Build from a custom repo and branch
./run_local_bench.sh --repo https://github.com/your-org/vernemq.git --ref my-feature-branch --scenarios all

# 5-node cluster with Prometheus + Grafana + LB
./run_local_bench.sh --nodes 5 --monitoring --lb --category core

# A/B comparison: upstream tag vs your fork's branch
./run_ab_comparison.sh \
    --baseline-repo https://github.com/vernemq/vernemq.git \
    --baseline-ref v2.1.2 \
    --candidate-repo https://github.com/your-org/vernemq.git \
    --candidate-ref my-feature-branch

# Reuse existing images, run specific scenarios
./run_local_bench.sh --skip-build --scenarios 01,04,06
```

See [local/README.md](local/README.md) for full CLI reference and scenario compatibility.

## Infrastructure Lifecycle

Terraform is split into three independent modules with separate state files:

| Module | Resources | Destroy frequency |
|--------|-----------|-------------------|
| `terraform/iam/` | Scoped IAM operator user + access key | Never (bootstrap only) |
| `terraform/network/` | VPC, subnets, IGW, NAT, route tables, placement group | Rarely |
| `terraform/monitoring/` | Prometheus, Grafana, monitor EC2, Grafana password | Between campaigns |
| `terraform/compute/` | VerneMQ nodes, bench nodes, security groups, inventory | Between runs |

**Apply order:** `network` → `monitoring` → `compute`

```bash
# Provision all at once
./scripts/infra_up.sh

# Destroy compute only (monitoring stays alive for data review)
./scripts/infra_down.sh

# Destroy everything
./scripts/infra_down.sh --all

# Or target a single module
terraform -chdir=terraform/compute destroy -var-file=../shared.tfvars
```

## Grafana (HTTPS)

Grafana is served over HTTPS with a self-signed certificate and a strong auto-generated password.

```bash
# Get the Grafana URL
terraform -chdir=terraform/monitoring output grafana_url

# Retrieve the admin password
terraform -chdir=terraform/monitoring output -raw grafana_admin_password
```

The certificate is self-signed, so you'll need to accept the browser warning on first visit.

## Running Benchmarks

Point the benchmark runner at any VerneMQ git repository and ref:

```bash
# Run all scenarios against an upstream release tag
./scripts/run_benchmark.sh \
    --repo https://github.com/vernemq/vernemq.git \
    --ref v2.1.2 \
    --tag baseline

# Run core scenarios against a feature branch on your fork
./scripts/run_benchmark.sh \
    --repo https://github.com/your-org/vernemq.git \
    --ref my-feature-branch \
    --tag feature-test \
    --category core

# Run specific scenarios against a commit hash
./scripts/run_benchmark.sh \
    --repo https://github.com/your-org/vernemq.git \
    --ref abc1234 \
    --scenarios 01,05,06

# Apply a tuning profile and export full Prometheus data
./scripts/run_benchmark.sh \
    --repo https://github.com/your-org/vernemq.git \
    --ref my-feature-branch \
    --tag tuned \
    --profile profiles/high_throughput.yaml \
    --export-prom
```

### CLI Reference

| Flag | Required | Description |
|------|----------|-------------|
| `--repo URL` | Yes | Git repository URL |
| `--ref REF` | Yes | Git ref: tag, branch, or commit hash |
| `--tag TAG` | No | Label for this run (default: `<ref>-<timestamp>`) |
| `--scenarios LIST` | No | Comma-separated numbers/names, or `all`, `standard`, `chaos` (default: `all`) |
| `--category CAT` | No | `core`, `integration`, or `all` (default: `all`) |
| `--cluster-size N` | No | Override auto-detected node count |
| `--profile PATH` | No | Apply a tuning profile YAML |
| `--duration SECS` | No | Override phase duration in seconds |
| `--export-prom` | No | Export full Prometheus TSDB snapshot |
| `--lb` | No | Force load balancer usage for supported scenarios |

Between each scenario, the cluster state is automatically reset (services restarted, cluster reformed, health verified) to ensure clean baselines.

## A/B Comparison

Compare any two git refs side by side:

```bash
# Compare an upstream tag against your fork's branch
./scripts/run_comparison.sh \
    --baseline-repo https://github.com/vernemq/vernemq.git \
    --baseline-ref v2.1.2 \
    --candidate-repo https://github.com/your-org/vernemq.git \
    --candidate-ref my-feature-branch \
    --scenarios standard \
    --load-multiplier 3 \
    --duration 180

# Compare two branches on the same repo
./scripts/run_comparison.sh \
    --baseline-repo https://github.com/your-org/vernemq.git \
    --baseline-ref main \
    --candidate-repo https://github.com/your-org/vernemq.git \
    --candidate-ref refactor-routing \
    --category core
```

Results are saved in `results/baseline-<ref>-<timestamp>/` and `results/candidate-<ref>-<timestamp>/`.

### CLI Reference

| Flag | Required | Description |
|------|----------|-------------|
| `--baseline-repo URL` | Yes | Git repository URL for baseline |
| `--baseline-ref REF` | Yes | Git ref for baseline |
| `--candidate-repo URL` | Yes | Git repository URL for candidate |
| `--candidate-ref REF` | Yes | Git ref for candidate |
| `--scenarios LIST` | No | Scenario selection (default: `standard`) |
| `--category CAT` | No | `core`, `integration`, or `all` (default: `all`) |
| `--duration SECS` | No | Seconds per phase (default: `180`) |
| `--load-multiplier N` | No | Scale factor for load (default: `3`) |
| `--cluster-size N` | No | Override auto-detected node count |
| `--lb` | No | Force load balancer usage for supported scenarios |

## N-Version Matrix

Benchmark N versions of VerneMQ, either sequentially on one cluster or in parallel on separate clusters:

```bash
# Sequential: compare a release tag, upstream main, and your feature branch
./scripts/run_matrix.sh \
    --version https://github.com/vernemq/vernemq.git@v2.1.2 \
    --version https://github.com/your-org/vernemq.git@main \
    --version https://github.com/your-org/vernemq.git@my-feature-branch \
    --scenarios standard

# Parallel (N clusters, simultaneous) — mix repos, tags, and commits
./scripts/run_matrix.sh \
    --version https://github.com/vernemq/vernemq.git@v2.1.2 \
    --version https://github.com/your-org/vernemq.git@abc1234 \
    --parallel --provision --teardown
```

| Flag | Required | Description |
|------|----------|-------------|
| `--version REPO@REF` | Yes (min 2) | Version spec (first = baseline) |
| `--parallel` | No | Run on separate clusters simultaneously |
| `--provision` | No | Auto-provision clusters before parallel run |
| `--teardown` | No | Auto-destroy clusters after parallel run |
| `--scenarios LIST` | No | Scenario selection (default: `standard`) |
| `--category CAT` | No | `core`, `integration`, or `all` (default: `all`) |
| `--duration SECS` | No | Seconds per phase (default: `180`) |
| `--load-multiplier N` | No | Scale factor for load (default: `3`) |
| `--cluster-size N` | No | Override auto-detected node count |
| `--lb` | No | Force load balancer usage for supported scenarios |

## Load Balancer & Authentication

### MQTT Authentication

By default, benchmarks run with auto-generated MQTT credentials (`allow_anonymous = off`). VerneMQ nodes are configured with a `vmq_passwd` file and ACL granting the bench user access to all topics.

- **AWS**: Set `enable_auth = true` (default) in `shared.tfvars`. Credentials are generated by Terraform and passed through the Ansible inventory.
- **Docker**: Auth is on by default. Use `--no-auth` to disable, or `--auth-user`/`--auth-pass` to override.

### Load Balancer (Optional)

An optional load balancer distributes client connections across VerneMQ nodes. This is especially useful for scenario 02 (cluster rebalance), where disconnected clients need to redistribute on reconnect.

- **AWS**: Set `enable_lb = true` in `shared.tfvars` to deploy an internal NLB. Then pass `--lb` to the benchmark script.
- **Docker**: Pass `--lb` to `run_local_bench.sh` to include an HAProxy container.

Each scenario declares an LB mode (`supported` or `direct_only`). Scenarios that target specific nodes (kill, partition, slow) always use direct connections regardless of the `--lb` flag.

```bash
# AWS: deploy with LB, run benchmarks through it
# In shared.tfvars: enable_lb = true
./scripts/run_benchmark.sh --repo ... --ref ... --tag ... --lb

# Docker: LB + auth (default)
cd local && ./run_local_bench.sh --lb --scenarios 01,02

# Docker: LB without auth
cd local && ./run_local_bench.sh --lb --no-auth
```

## SSH Configuration

Bootstrap automatically generates a `bench.env` file that sets `SSH_KEY` for all scripts. No manual `export` is needed if you used `bootstrap.sh`.

To configure manually (e.g. if you skip bootstrap):

- `SSH_KEY` environment variable: `export SSH_KEY=~/.ssh/my-key.pem`
- Ansible: `--private-key` flag or `ANSIBLE_PRIVATE_KEY_FILE` env var
- SSH agent: `ssh-add ~/.ssh/my-key.pem`

## Project Structure

```
.
├── terraform/
│   ├── iam/                   # Scoped IAM user (bootstrap only)
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── backend.tf
│   ├── network/               # VPC, subnets, gateways, placement group
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── backend.tf
│   ├── monitoring/            # Monitor EC2, Grafana password
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── backend.tf
│   ├── compute/               # VerneMQ + bench EC2 instances
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── backend.tf
│   │   └── templates/inventory.tpl
│   ├── state/                 # Terraform state files (gitignored)
│   └── shared.tfvars.example  # Shared variables template
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/             # Generated by Terraform (gitignored)
│   ├── roles/
│   │   ├── bench/             # emqtt-bench + node_exporter
│   │   ├── monitoring/        # Prometheus + Grafana (HTTPS) + node_exporter
│   │   └── vernemq/           # VerneMQ (release, source, or git_clone mode)
│   ├── deploy_vernemq.yml
│   ├── deploy_bench.yml
│   ├── deploy_monitoring.yml
│   ├── configure_cluster.yml
│   ├── restart_cluster.yml    # Lightweight reset between scenarios
│   └── teardown_cluster.yml
├── scenarios/
│   ├── common.sh              # Shared helpers (SSH, metrics, assertions)
│   ├── transport_docker.sh    # Docker exec transport backend
│   ├── suite.sh               # Scenario selection by cluster size + category
│   ├── core/                  # Universal scenarios (any VerneMQ version)
│   │   └── 01,05–11_*.sh
│   ├── integration/           # Require unmerged features
│   │   └── 02,03,04_*.sh
│   └── profiles/              # Version-specific compatibility & tuning
│       ├── integration.sh     # All features enabled (default fallback)
│       ├── local.sh           # Docker/local (skip 09/10/11)
│       ├── v1.x.sh
│       ├── v2.0.sh
│       └── v2.1.sh
├── scripts/
│   ├── run_benchmark.sh       # Main entry point (--repo/--ref/--category)
│   ├── run_comparison.sh      # A/B comparison runner
│   ├── run_matrix.sh          # N-version parallel benchmarking
│   ├── infra_up.sh            # Provision all infrastructure
│   ├── infra_down.sh          # Destroy compute (or --all)
│   ├── bootstrap.sh           # First-time IAM + profile setup
│   ├── lib.sh                 # Shared shell functions
│   ├── export_prometheus.sh
│   ├── vmq_metrics_poller.sh
│   ├── vmq_metrics_poller_docker.sh  # Docker variant (docker exec)
│   ├── collect_metrics.sh
│   ├── apply_profile.sh
│   ├── prom_to_csv.py
│   └── report.py
├── profiles/                  # VerneMQ tuning profiles (YAML)
│   ├── default.yaml
│   ├── high_throughput.yaml
│   ├── balanced_cluster.yaml
│   └── netsplit_tolerant.yaml
├── local/                     # Docker-based local benchmarks
│   ├── Dockerfile             # VerneMQ multi-stage build
│   ├── Dockerfile.bench       # emqtt-bench multi-stage build
│   ├── entrypoint.sh          # VerneMQ container startup + cluster join + auth
│   ├── generate_compose.sh    # Dynamic docker-compose generation (--lb for HAProxy)
│   ├── run_local_bench.sh     # Full CLI (--nodes/--monitoring/--lb/--no-auth)
│   ├── run_ab_comparison.sh   # A/B comparison runner (--lb/--no-auth)
│   ├── docker-compose.yml     # Generated by generate_compose.sh
│   ├── haproxy/               # Generated HAProxy config (when --lb)
│   └── monitoring/            # Generated Prometheus config
├── Makefile                   # make help for all targets
├── requirements.txt           # Optional Python dependencies
└── results/                   # Benchmark output (gitignored)
```

## Scenarios

### Core (any VerneMQ version)

| # | Name | Min Nodes | Description |
|---|------|-----------|-------------|
| 01 | Baseline Throughput | 1 | Raw throughput and latency at increasing load (QoS 0 & 1) |
| 05 | Node Failure Recovery | 3 | Single, rolling, and multi-node failure resilience |
| 06 | Connection Storm | 2 | High-rate and bursty connection acceptance |
| 07 | Node Flapping | 5 | Repeated kill/restart cycles of increasing severity |
| 08 | Graceful Shutdown | 3 | Graceful vs ungraceful shutdown message loss comparison |
| 09 | Network Partition | 5 | iptables-based partition with convergence measurement |
| 10 | Slow Node | 3 | tc/netem latency and packet loss injection |
| 11 | Rolling Upgrade | 3 | Rolling upgrade under load with per-node downtime tracking |

### Integration (require unmerged features)

| # | Name | Min Nodes | Requires | Description |
|---|------|-----------|----------|-------------|
| 02 | Cluster Rebalance | 5 | `balance` | Connection rebalancing across a growing cluster |
| 03 | Netsplit Recovery | 4 | `tiered_health` | Progressive failures with quorum-based health tracking |
| 04 | Subscription Storm | 2 | `reg_trie_workers` | Subscription trie stress under heavy concurrent modification |

Scenario selection is automatic based on cluster size — `suite.sh` only includes scenarios the cluster is large enough to run. Use `--category core` to run only universal scenarios, or `--category integration` for feature-specific ones. Version profiles in `scenarios/profiles/` control which scenarios are compatible with each VerneMQ release.

## Bench Node Sizing

emqtt-bench uses one Erlang process per MQTT connection. CPU is the real bottleneck, not memory:

| Instance Type | vCPUs | Approx. Active Connections |
|---------------|-------|---------------------------|
| `c6i.2xlarge` | 8 | ~120-150k |
| `c6i.4xlarge` | 16 | ~250-300k |
| `c6i.8xlarge` | 32 | ~500-600k |

Scenario 01 (baseline throughput) phase 3 is the heaviest standard load point: `scale_load(100000, 8)` conns + `scale_load(50000, 8)` pubs. On a 10-node cluster with `LOAD_MULTIPLIER=3`, that's **562k total connections** from a single bench node.

**Rule of thumb:** 1 bench node per 3-4 VMQ nodes at `LOAD_MULTIPLIER=1`. With `LOAD_MULTIPLIER=3`, use 1 bench node per 1-2 VMQ nodes, or upsize the instance.

| VMQ Nodes | LOAD_MULTIPLIER | Recommended Bench Config |
|-----------|-----------------|--------------------------|
| 3 | 1 | 1x `c6i.2xlarge` (default) |
| 5 | 1 | 1x `c6i.4xlarge` or 2x `c6i.2xlarge` |
| 10 | 1 | 2x `c6i.4xlarge` or 1x `c6i.8xlarge` |
| 3 | 3 | 1x `c6i.4xlarge` |
| 5 | 3 | 2x `c6i.4xlarge` |
| 10 | 3 | 3x `c6i.4xlarge` or 2x `c6i.8xlarge` |

The framework warns at scenario start if estimated connections exceed the per-node threshold. Override the threshold with `BENCH_CONN_WARN_THRESHOLD`.

## Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_profile` | `default` | AWS CLI profile name |
| `aws_region` | `us-east-1` | AWS region |
| `vmq_node_count` | `3` | VerneMQ cluster nodes |
| `bench_node_count` | `1` | Benchmark client nodes |
| `key_pair_name` | *(required)* | AWS key pair for SSH |
| `instance_type_vmq` | `c6i.2xlarge` | Instance type for VMQ nodes |
| `instance_type_bench` | `c6i.2xlarge` | Instance type for bench nodes |
| `instance_type_monitor` | `c6i.xlarge` | Instance type for monitor |
| `project_name` | `vernemq-bench` | Resource tagging prefix |
| `allowed_ssh_cidr` | `0.0.0.0/0` | CIDR for SSH/Grafana access |
| `enable_lb` | `false` | Deploy internal NLB for MQTT load balancing |
| `enable_auth` | `true` | Generate MQTT credentials for benchmarks |
| `bench_username` | `benchuser` | MQTT username for benchmark clients |

Set these in `terraform/shared.tfvars` (copied from `shared.tfvars.example`). Pass to each module with `-var-file=../shared.tfvars` or use `scripts/infra_up.sh` which handles this automatically.

## Cost Warning

This suite provisions multiple EC2 instances. A 3-node cluster with `c6i.2xlarge` instances costs roughly **$2–3/hour**. Larger clusters (10 VMQ + 3 bench) cost significantly more.

**Always destroy infrastructure when done:**

```bash
# Destroy compute only (cheapest resources)
./scripts/infra_down.sh

# Destroy everything
./scripts/infra_down.sh --all
```
