# Local (Docker) Benchmarks

Run the full VerneMQ benchmark suite on a single machine using Docker. The local path uses a **transport abstraction** (`BENCH_TRANSPORT=docker`) that replaces SSH with `docker exec`, so all cloud scenarios run unmodified — no code duplication.

## Quick Start

```bash
# Build VerneMQ + emqtt-bench images, start 3-node cluster, run standard scenarios (auth on by default)
./run_local_bench.sh

# With HAProxy load balancer
./run_local_bench.sh --lb --nodes 5 --scenarios 01,02

# Without authentication
./run_local_bench.sh --no-auth

# Reuse existing images, specific scenarios
./run_local_bench.sh --skip-build --scenarios 01,04,06
```

## CLI Reference — `run_local_bench.sh`

| Flag | Default | Description |
|------|---------|-------------|
| `--repo URL` | current tree | Git repo to build from |
| `--ref REF` | — | Git ref to checkout (uses worktrees) |
| `--skip-build` | — | Reuse existing Docker images |
| `--nodes N` | 3 | VerneMQ cluster size |
| `--monitoring` | — | Include Prometheus + Grafana containers |
| `--scenarios LIST` | standard | Numbers, `all`, `standard`, `core`, `integration` |
| `--category CAT` | all | `core`, `integration`, or `all` |
| `--profile VER` | local | Version profile |
| `--duration SECS` | — | Phase duration override |
| `--scale FACTOR` | 0.4 | LOCAL_SCALE (load reduction for laptop) |
| `--keep` | — | Don't tear down after |
| `--export-prom` | — | Export Prometheus snapshot (requires `--monitoring`) |
| `--tag TAG` | — | Results label |
| `--lb` | — | Include HAProxy load balancer (port 11883) |
| `--no-auth` | — | Disable MQTT authentication |
| `--auth-user USER` | benchuser | Override auth username |
| `--auth-pass PASS` | auto-generated | Override auth password |

## CLI Reference — `run_ab_comparison.sh`

| Flag | Default | Description |
|------|---------|-------------|
| `--baseline-ref REF` | — | Git ref for baseline |
| `--candidate-ref REF` | — | Git ref for candidate |
| `--baseline-repo URL` | current tree | Git repo for baseline |
| `--candidate-repo URL` | current tree | Git repo for candidate |
| `--baseline-image IMG` | — | Pre-built image for baseline |
| `--candidate-image IMG` | — | Pre-built image for candidate |
| `--scenarios LIST` | standard | Scenario selection |
| `--category CAT` | all | `core`, `integration`, or `all` |
| `--nodes N` | 3 | Cluster size |
| `--monitoring` | — | Include Prometheus + Grafana |
| `--duration SECS` | 180 | Phase duration |
| `--scale FACTOR` | 0.4 | LOCAL_SCALE |
| `--lb` | — | Include HAProxy load balancer |
| `--no-auth` | — | Disable MQTT authentication |
| `--auth-user USER` | benchuser | Override auth username |
| `--auth-pass PASS` | auto-generated | Override auth password |

## Authentication

MQTT authentication is **on by default**. A random password is auto-generated for each run. VerneMQ is configured with `allow_anonymous = off` and a `vmq_passwd` file. All emqtt-bench commands automatically receive `-u` / `-P` flags.

- `--no-auth` — disables auth entirely (`allow_anonymous = on`)
- `--auth-user` / `--auth-pass` — override the auto-generated credentials

## Load Balancer

Pass `--lb` to include an HAProxy container that round-robins MQTT connections across all VMQ nodes. This is useful for scenario 02 (cluster rebalance) where disconnected clients need to redistribute on reconnect.

HAProxy listens on host port `11883` (mapped to container port `1883`). Only scenarios with `SCENARIO_LB_MODE="supported"` route through the LB; scenarios that target specific nodes always use direct connections.

```bash
# 5-node cluster with LB — scenario 02 gets realistic redistribution
./run_local_bench.sh --lb --nodes 5 --scenarios 01,02
```

## Scenario Compatibility

All 11 cloud scenarios are available. Three are skipped in Docker because they need host-level networking:

| # | Scenario | Docker | Notes |
|---|----------|--------|-------|
| 01 | Baseline Throughput | Full | |
| 02 | Cluster Rebalance | Full | Needs `--nodes 5` |
| 03 | Netsplit Recovery | Full | `docker kill`/`docker start` |
| 04 | Subscription Storm | Full | |
| 05 | Node Failure Recovery | Full | `docker kill`/`docker start` |
| 06 | Connection Storm | Full | |
| 07 | Node Flapping | Full | Needs `--nodes 5` |
| 08 | Graceful Shutdown | Full | `systemctl stop` → `docker stop --time=30` |
| 09 | Network Partition | **Skip** | Needs iptables on host network |
| 10 | Slow Node | **Skip** | Needs tc/netem kernel module |
| 11 | Rolling Upgrade | **Skip** | Needs per-node image swap |

## Monitoring

Add `--monitoring` to include Prometheus and Grafana:

```bash
./run_local_bench.sh --monitoring --nodes 5

# Access:
#   Prometheus: http://localhost:9090
#   Grafana:    http://localhost:3000 (admin / benchadmin)
```

## Cluster Sizing

- `--nodes 1`: Single-node, runs scenario 01 only
- `--nodes 3`: Default, runs 01, 04, 06
- `--nodes 5+`: Enables rebalance (02), flapping (07), and more
- `--nodes 10+`: Full suite (except skipped scenarios)

## How It Works

The transport abstraction (`scenarios/transport_docker.sh`) is sourced at the end of `common.sh` when `BENCH_TRANSPORT=docker` is set. It overrides:

- `ssh_vmq()` → `docker exec <container>`
- `ssh_bench()` → `docker exec <container>`
- `start_emqtt_bench()` → `docker exec -d <container>`
- `kill_vmq_node()` → `docker kill <container>`
- `start_vmq_node()` → `docker start <container>` + wait + re-apply settings
- `scale_load()` → Uses `LOCAL_SCALE` (0.4x by default, ~8-10k connections on a 3-node cluster)

The cloud scenarios in `scenarios/core/` and `scenarios/integration/` run completely unmodified.

## Relationship to Cloud Scenarios

There is **zero code duplication**. The local runner sets environment variables and calls the same scenario scripts as the cloud path:

```
Cloud:  run_benchmark.sh → SSH → scenarios/core/*.sh (common.sh)
Docker: run_local_bench.sh → docker exec → scenarios/core/*.sh (common.sh + transport_docker.sh)
```
