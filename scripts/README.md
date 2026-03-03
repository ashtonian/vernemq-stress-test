# Scripts — Orchestration & Utilities

## Main Entry Points

| Script | Purpose |
|--------|---------|
| `bootstrap.sh` | First-time setup: IAM user, AWS profile, `bench.env` with SSH key |
| `run_benchmark.sh` | Deploy a VerneMQ version, run scenarios, collect results (`--lb` for LB) |
| `run_comparison.sh` | A/B comparison — run the same scenarios against two versions (`--lb` for LB) |
| `run_matrix.sh` | N-version benchmarking — sequential or parallel across clusters (`--lb` for LB) |
| `infra_up.sh` | Provision AWS infrastructure (network → monitoring → compute) |
| `infra_down.sh` | Tear down infrastructure (`--all` for everything, default compute only) |

## Supporting Scripts

| Script | Purpose |
|--------|---------|
| `lib.sh` | Shared functions: logging, Ansible wrappers, inventory parsing, preflight checks, cluster reset |
| `apply_profile.sh` | Apply a YAML tuning profile to the cluster via Ansible |
| `collect_metrics.sh` | Query Prometheus and save metrics snapshots |
| `export_prometheus.sh` | Export full Prometheus TSDB snapshot for offline analysis |
| `vmq_metrics_poller.sh` | Poll VerneMQ-specific metrics during a scenario run (SSH) |
| `vmq_metrics_poller_docker.sh` | Poll VerneMQ-specific metrics via `docker exec` (local) |
| `prom_to_csv.py` | Convert Prometheus query results to CSV |
| `report.py` | Generate comparison reports from benchmark results |

## Typical Workflow

Run from the `scripts/` directory, or prefix with `scripts/` from the repo root.

```bash
# 1. Provision infrastructure
./infra_up.sh

# 2. Run benchmarks
./run_benchmark.sh --repo https://github.com/vernemq/vernemq.git --ref v2.1.2 --tag baseline

# 3. Or do an A/B comparison
./run_comparison.sh \
    --baseline-repo https://github.com/vernemq/vernemq.git --baseline-ref v2.1.2 \
    --candidate-repo https://github.com/user/vernemq.git --candidate-ref feature-x

# 4. Or benchmark multiple versions
./run_matrix.sh \
    --version https://github.com/vernemq/vernemq.git@v2.0.0 \
    --version https://github.com/vernemq/vernemq.git@v2.1.2 \
    --version https://github.com/vernemq/vernemq.git@main

# 5. Tear down
./infra_down.sh
```

## lib.sh Functions

| Function | Description |
|----------|-------------|
| `log()` | Timestamped logging to file and stdout |
| `run_ansible()` | Execute an Ansible playbook with the correct inventory and SSH key |
| `preflight_check()` | Validate required tools, inventory file, and SSH key before running |
| `setup_env_from_inventory()` | Parse inventory for node IPs, LB host, auth credentials; set `VMQ_NODES`, `BENCH_NODES`, `LB_HOST`, `BENCH_MQTT_USERNAME`, etc. |
| `reset_cluster_state()` | Kill benchmarks, restart cluster, re-apply profile, wait for stabilization |
| `run_scenarios()` | Shared scenario runner loop (used by comparison and matrix scripts) |
| `cleanup_on_exit()` | Trap handler to stop all running benchmarks |
