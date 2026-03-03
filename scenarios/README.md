# Scenarios — Benchmark Tests

Each scenario is a self-contained shell script that runs against a live VerneMQ cluster using emqtt-bench. Between scenarios, the cluster is automatically reset to ensure clean baselines.

## Categories

**Core** (`core/`) — Work with any VerneMQ version:

| # | Name | Min Nodes | LB Mode | Description |
|---|------|-----------|---------|-------------|
| 01 | Baseline Throughput | 1 | supported | Raw throughput and latency at increasing load (QoS 0 & 1) |
| 05 | Node Failure Recovery | 3 | direct_only | Single, rolling, and multi-node failure resilience |
| 06 | Connection Storm | 2 | supported | High-rate and bursty connection acceptance |
| 07 | Node Flapping | 5 | direct_only | Repeated kill/restart cycles of increasing severity |
| 08 | Graceful Shutdown | 3 | direct_only | Graceful vs ungraceful shutdown message loss comparison |
| 09 | Network Partition | 5 | direct_only | iptables-based partition with convergence measurement |
| 10 | Slow Node | 3 | direct_only | tc/netem latency and packet loss injection |
| 11 | Rolling Upgrade | 3 | supported | Rolling upgrade under load with per-node downtime tracking |

**Integration** (`integration/`) — Require unmerged features:

| # | Name | Min Nodes | LB Mode | Requires | Description |
|---|------|-----------|---------|----------|-------------|
| 02 | Cluster Rebalance | 5 | supported | `balance` | Connection rebalancing across a growing cluster |
| 03 | Netsplit Recovery | 4 | direct_only | `tiered_health` | Progressive failures with quorum-based health tracking |
| 04 | Subscription Storm | 2 | supported | `reg_trie_workers` | Subscription trie stress under heavy concurrent modification |

## Suite Selection

`suite.sh` automatically selects which scenarios to run based on:

1. **Cluster size** — only includes scenarios the cluster is large enough to support
2. **Version profile** — skips scenarios incompatible with the target VerneMQ version
3. **Category filter** — `core`, `integration`, or `all`

```bash
# As a library
source suite.sh
scenarios=$(select_suite 5 v2.1 core)

# Directly
./suite.sh 10 integration all
```

## Version Profiles

Files in `profiles/` define per-version scenario compatibility and tuning parameters:

| Profile | Description |
|---------|-------------|
| `integration.sh` | All features enabled; default fallback for unknown versions |
| `v1.x.sh` | Skips scenarios 02, 04 (features unavailable in 1.x) |
| `v2.0.sh` | Skips scenario 02 |
| `v2.1.sh` | Skips scenario 02 |
| `local.sh` | Docker/local — skips scenarios 09, 10, 11 (need host networking) |

Profile resolution order: exact match → major.minor → major.x → `integration` (fallback). The `local.sh` profile is selected automatically when `BENCH_TRANSPORT=docker`.

## Load Balancer Modes

Each scenario declares a `SCENARIO_LB_MODE` that controls whether it can use a load balancer:

- **`supported`** — Scenario can route traffic through an LB when one is available and `BENCH_USE_LB=1`. Used by general tests (01, 04, 06) and scenarios that benefit from reconnect redistribution (02, 11).
- **`direct_only`** — Scenario always connects directly to specific nodes. Used by chaos/failure tests that target individual nodes (05, 07, 08, 09, 10) or simulate partitions (03).

The LB is **always optional** — no scenario requires it. Scenario 02 logs a warning when running without LB, noting that redistribution won't occur.

## Shared Helpers

`common.sh` is sourced by every scenario and provides:

- SSH configuration and node addressing (`VMQ_NODES`, `BENCH_NODES`, `MONITOR_HOST`)
- `load_profile()` — loads version-specific settings
- Prometheus query helpers
- Metric collection and assertion utilities
- emqtt-bench launch/stop helpers (with automatic auth credential injection)
- Load balancer support (`should_use_lb()`, `resolve_bench_hosts()`)

## Environment Variables

Scenarios expect these variables (set automatically by `run_benchmark.sh`):

| Variable | Description |
|----------|-------------|
| `RESULTS_DIR` | Output directory for this run |
| `SCENARIO_TAG` | Current scenario name |
| `VMQ_NODES` | Space-separated list of VerneMQ IPs |
| `BENCH_NODES` | Space-separated list of bench node IPs |
| `MONITOR_HOST` | Prometheus/Grafana IP |
| `PROMETHEUS_URL` | Full Prometheus base URL |
| `SSH_KEY` | Path to SSH private key |
| `SSH_USER` | SSH username (default: `ec2-user`) |
| `SSH_OPTS` | Common SSH options |
| `DURATION` | Phase duration override (seconds) |
| `LOAD_MULTIPLIER` | Load scaling factor |
| `LB_HOST` | Load balancer hostname (empty if no LB) |
| `BENCH_USE_LB` | Set to `1` to route through LB for supported scenarios |
| `BENCH_MQTT_USERNAME` | MQTT username for authentication (empty = anonymous) |
| `BENCH_MQTT_PASSWORD` | MQTT password for authentication (empty = anonymous) |
| `VMQ_VERSION` | VerneMQ version string for profile resolution |
| `BENCH_COMPARISON_MODE` | Set to `1` by comparison/matrix scripts to enforce DURATION |
| `BENCH_CONN_WARN_THRESHOLD` | Max connections per bench node before warning (default: 150000) |
| `LOCAL_SCALE` | Load scaling factor for Docker mode (default: 0.4) |
| `METRICS_POLL_INTERVAL` | Seconds between VerneMQ metric polls (default: 10) |
