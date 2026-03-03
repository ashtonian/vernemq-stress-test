#!/usr/bin/env python3
"""
report.py - Generate comparison report for VerneMQ benchmark results.

Compares two benchmark runs (baseline vs. candidate) and generates a markdown
report with tables, charts, and pass/fail criteria evaluation.

Supports N-way comparison via --run DIR (repeatable).

Usage:
    # 2-way:
    python3 report.py --baseline results/release-2.1.2 \
                      --candidate results/candidate-test \
                      --output results/comparison-report

    # N-way:
    python3 report.py --run results/v2.1.2 --run results/main --run results/feat-x \
                      --output results/nway-report
"""

import argparse
import json
import os
import sys
from pathlib import Path

try:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker

    HAS_MATPLOTLIB = True
except ImportError:
    HAS_MATPLOTLIB = False
    print("WARNING: matplotlib not available, charts will be skipped", file=sys.stderr)


# ---------------------------------------------------------------------------
# Pass/fail thresholds
# ---------------------------------------------------------------------------

CRITERIA = {
    "01_baseline_throughput": {
        "description": "Baseline throughput >100K msg/s, p99 <50ms",
        "min_msg_rate": 100000,
        "max_p99_ms": 50,
    },
    "02_cluster_rebalance": {
        "description": "Rebalance within 20% of average in 5 min",
        "max_imbalance_pct": 20,
        "max_rebalance_seconds": 300,
    },
    "03_netsplit_recovery": {
        "description": "Zero msg loss in degraded, recovery <30s",
        "max_msg_loss_pct": 0,
        "max_recovery_seconds": 30,
    },
    "04_subscription_storm": {
        "description": "8-worker >3x single-worker throughput",
        "min_worker_speedup": 3.0,
    },
    "05_node_failure_recovery": {
        "description": "<0.1% message loss for QoS 1",
        "max_msg_loss_pct": 0.1,
    },
    "06_connection_storm": {
        "description": ">10K connections/sec accept rate",
        "min_conn_rate": 10000,
    },
    "07_node_flapping": {
        "description": "Cluster recovers from 3 flap cycles",
    },
    "08_graceful_shutdown": {
        "description": "Zero message loss during graceful drain",
        "max_msg_loss_pct": 0,
    },
    "09_network_partition": {
        "description": "Recovery after iptables partition",
    },
    "10_slow_node": {
        "description": "Slow node doesn't degrade cluster >10%",
        "max_degradation_pct": 10,
    },
    "11_rolling_upgrade": {
        "description": "Zero downtime rolling upgrade",
        "max_msg_loss_pct": 0,
    },
}

REGRESSION_THRESHOLD_PCT = 5  # Flag >5% worse than baseline

NWAY_COLORS = [
    "#1f77b4",  # blue
    "#ff7f0e",  # orange
    "#2ca02c",  # green
    "#d62728",  # red
    "#9467bd",  # purple
    "#8c564b",  # brown
    "#e377c2",  # pink
    "#7f7f7f",  # gray
    "#bcbd22",  # olive
    "#17becf",  # cyan
]


# ---------------------------------------------------------------------------
# Data loading helpers
# ---------------------------------------------------------------------------


def load_json(path):
    """Load a JSON file, return empty dict on failure."""
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def load_csv_pairs(path):
    """Load a CSV file with key,value pairs into a dict."""
    result = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if "," in line:
                    key, value = line.split(",", 1)
                    result[key.strip()] = value.strip()
    except FileNotFoundError:
        pass
    return result


def find_scenario_dirs(results_dir):
    """Find scenario result directories within a run directory."""
    results_path = Path(results_dir)
    scenarios = {}
    for d in sorted(results_path.iterdir()):
        if d.is_dir() and d.name[:2].isdigit():
            scenarios[d.name] = d
    return scenarios


def load_metadata(results_dir):
    """Load run-level metadata (profile, version, etc.).

    Checks each scenario dir for metadata.csv, returns first found.
    """
    results_path = Path(results_dir)
    for d in sorted(results_path.iterdir()):
        meta_path = d / "metadata.csv"
        if meta_path.exists():
            return load_csv_pairs(meta_path)
    return {}


def extract_metric_value(prom_json):
    """Extract a numeric value from a Prometheus instant query result."""
    try:
        results = prom_json.get("data", {}).get("result", [])
        if results:
            return float(results[0]["value"][1])
    except (KeyError, IndexError, ValueError, TypeError):
        pass
    return None


def extract_metric_values_by_instance(prom_json):
    """Extract per-instance values from a Prometheus query result."""
    values = {}
    try:
        for result in prom_json.get("data", {}).get("result", []):
            instance = result["metric"].get("instance", "unknown")
            values[instance] = float(result["value"][1])
    except (KeyError, ValueError, TypeError):
        pass
    return values


def extract_time_series(prom_json):
    """Extract time series data from a Prometheus range query result."""
    series = []
    try:
        for result in prom_json.get("data", {}).get("result", []):
            instance = result["metric"].get("instance", "unknown")
            timestamps = []
            values = []
            for ts, val in result["values"]:
                timestamps.append(float(ts))
                values.append(float(val))
            series.append({"instance": instance, "timestamps": timestamps, "values": values})
    except (KeyError, ValueError, TypeError):
        pass
    return series


# ---------------------------------------------------------------------------
# Chart generation (2-way, existing)
# ---------------------------------------------------------------------------


def chart_throughput(baseline_dir, integration_dir, output_dir):
    """Generate throughput over time comparison chart."""
    if not HAS_MATPLOTLIB:
        return None

    fig, ax = plt.subplots(figsize=(12, 5))

    for label, results_dir, color in [
        ("Baseline", baseline_dir, "#1f77b4"),
        ("Integration", integration_dir, "#ff7f0e"),
    ]:
        metrics_dirs = sorted(Path(results_dir).glob("metrics_*"))
        if not metrics_dirs:
            continue
        ts_file = metrics_dirs[-1] / "ts_publish_rate.json"
        data = load_json(ts_file)
        for s in extract_time_series(data):
            if s["timestamps"]:
                t0 = s["timestamps"][0]
                times = [(t - t0) / 60 for t in s["timestamps"]]
                ax.plot(times, s["values"], color=color, alpha=0.6, linewidth=1)
        # Add label entry
        ax.plot([], [], color=color, label=label, linewidth=2)

    ax.set_xlabel("Time (minutes)")
    ax.set_ylabel("Messages/sec")
    ax.set_title("Publish Throughput Over Time")
    ax.legend()
    ax.grid(True, alpha=0.3)
    ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x:,.0f}"))

    path = output_dir / "throughput_over_time.png"
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    return path.name


def chart_latency_distribution(baseline_dir, integration_dir, output_dir):
    """Generate latency percentile comparison chart."""
    if not HAS_MATPLOTLIB:
        return None

    percentiles = ["p50", "p95", "p99"]
    baseline_vals = []
    integration_vals = []

    for results_dir, vals in [(baseline_dir, baseline_vals), (integration_dir, integration_vals)]:
        metrics_dirs = sorted(Path(results_dir).glob("metrics_*"))
        if not metrics_dirs:
            vals.extend([0, 0, 0])
            continue
        md = metrics_dirs[-1]
        for p in percentiles:
            data = load_json(md / f"latency_{p}.json")
            v = extract_metric_value(data)
            vals.append((v or 0) * 1000)  # Convert to ms

    fig, ax = plt.subplots(figsize=(8, 5))
    x = range(len(percentiles))
    width = 0.35
    ax.bar([i - width / 2 for i in x], baseline_vals, width, label="Baseline", color="#1f77b4")
    ax.bar([i + width / 2 for i in x], integration_vals, width, label="Integration", color="#ff7f0e")
    ax.set_xlabel("Percentile")
    ax.set_ylabel("Latency (ms)")
    ax.set_title("Publish Latency Distribution")
    ax.set_xticks(list(x))
    ax.set_xticklabels(percentiles)
    ax.legend()
    ax.grid(True, alpha=0.3, axis="y")

    path = output_dir / "latency_distribution.png"
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    return path.name


def chart_connection_heatmap(results_dir, output_dir, label):
    """Generate connection distribution heatmap for a single run."""
    if not HAS_MATPLOTLIB:
        return None

    # Look for connection stats in rebalance scenario
    rebalance_dir = None
    for d in Path(results_dir).iterdir():
        if d.is_dir() and d.name.startswith("02_"):
            rebalance_dir = d
            break

    if not rebalance_dir:
        return None

    # Collect balance health timeline data
    timeline_files = sorted(rebalance_dir.glob("*/balance_health_timeline.csv"))
    if not timeline_files:
        return None

    # Parse timeline: ts,nodeN,status_code
    nodes = set()
    timestamps = []
    data_points = {}
    for tf in timeline_files:
        for line in tf.read_text().strip().split("\n"):
            parts = line.split(",")
            if len(parts) >= 3:
                ts, node, status = parts[0], parts[1], parts[2]
                nodes.add(node)
                if ts not in data_points:
                    timestamps.append(ts)
                    data_points[ts] = {}
                data_points[ts][node] = 1 if status == "200" else 0

    if not timestamps or not nodes:
        return None

    nodes_sorted = sorted(nodes)
    matrix = []
    for node in nodes_sorted:
        row = [data_points.get(ts, {}).get(node, 0) for ts in timestamps]
        matrix.append(row)

    fig, ax = plt.subplots(figsize=(14, 4))
    ax.imshow(matrix, aspect="auto", cmap="RdYlGn", vmin=0, vmax=1)
    ax.set_yticks(range(len(nodes_sorted)))
    ax.set_yticklabels(nodes_sorted)
    ax.set_xlabel("Time")
    ax.set_title(f"Connection Balance Health ({label})")

    # Thin x-axis labels
    step = max(1, len(timestamps) // 10)
    ax.set_xticks(range(0, len(timestamps), step))
    ax.set_xticklabels([timestamps[i][-8:] for i in range(0, len(timestamps), step)], rotation=45)

    path = output_dir / f"connection_heatmap_{label.lower().replace(' ', '_')}.png"
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    return path.name


def chart_resource_usage(baseline_dir, integration_dir, output_dir):
    """Generate CPU and memory comparison chart."""
    if not HAS_MATPLOTLIB:
        return None

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 5))

    for label, results_dir, color in [
        ("Baseline", baseline_dir, "#1f77b4"),
        ("Integration", integration_dir, "#ff7f0e"),
    ]:
        metrics_dirs = sorted(Path(results_dir).glob("metrics_*"))
        if not metrics_dirs:
            continue
        md = metrics_dirs[-1]

        # CPU
        for s in extract_time_series(load_json(md / "ts_cpu.json")):
            if s["timestamps"]:
                t0 = s["timestamps"][0]
                times = [(t - t0) / 60 for t in s["timestamps"]]
                ax1.plot(times, s["values"], color=color, alpha=0.5, linewidth=1)

        # Memory
        for s in extract_time_series(load_json(md / "ts_memory.json")):
            if s["timestamps"]:
                t0 = s["timestamps"][0]
                times = [(t - t0) / 60 for t in s["timestamps"]]
                mem_mb = [v / (1024 * 1024) for v in s["values"]]
                ax2.plot(times, mem_mb, color=color, alpha=0.5, linewidth=1)

        ax1.plot([], [], color=color, label=label, linewidth=2)
        ax2.plot([], [], color=color, label=label, linewidth=2)

    ax1.set_xlabel("Time (minutes)")
    ax1.set_ylabel("CPU Usage (cores)")
    ax1.set_title("CPU Usage Over Time")
    ax1.legend()
    ax1.grid(True, alpha=0.3)

    ax2.set_xlabel("Time (minutes)")
    ax2.set_ylabel("Memory (MB)")
    ax2.set_title("Memory Usage Over Time")
    ax2.legend()
    ax2.grid(True, alpha=0.3)

    path = output_dir / "resource_usage.png"
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    return path.name


# ---------------------------------------------------------------------------
# N-way chart generation
# ---------------------------------------------------------------------------


def chart_throughput_nway(run_dirs, run_labels, output_dir):
    """Generate throughput over time chart for N versions."""
    if not HAS_MATPLOTLIB:
        return None

    fig, ax = plt.subplots(figsize=(14, 6))

    for idx, (results_dir, label) in enumerate(zip(run_dirs, run_labels)):
        color = NWAY_COLORS[idx % len(NWAY_COLORS)]
        metrics_dirs = sorted(Path(results_dir).glob("metrics_*"))
        if not metrics_dirs:
            continue
        ts_file = metrics_dirs[-1] / "ts_publish_rate.json"
        data = load_json(ts_file)
        for s in extract_time_series(data):
            if s["timestamps"]:
                t0 = s["timestamps"][0]
                times = [(t - t0) / 60 for t in s["timestamps"]]
                ax.plot(times, s["values"], color=color, alpha=0.6, linewidth=1)
        ax.plot([], [], color=color, label=label, linewidth=2)

    ax.set_xlabel("Time (minutes)")
    ax.set_ylabel("Messages/sec")
    ax.set_title("Publish Throughput Over Time (N-Way)")
    ax.legend()
    ax.grid(True, alpha=0.3)
    ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x:,.0f}"))

    path = output_dir / "throughput_over_time_nway.png"
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    return path.name


def chart_latency_nway(run_dirs, run_labels, output_dir):
    """Generate latency percentile grouped bar chart for N versions."""
    if not HAS_MATPLOTLIB:
        return None

    percentiles = ["p50", "p95", "p99"]
    n = len(run_dirs)

    all_vals = []
    for results_dir in run_dirs:
        vals = []
        metrics_dirs = sorted(Path(results_dir).glob("metrics_*"))
        if not metrics_dirs:
            vals.extend([0, 0, 0])
        else:
            md = metrics_dirs[-1]
            for p in percentiles:
                data = load_json(md / f"latency_{p}.json")
                v = extract_metric_value(data)
                vals.append((v or 0) * 1000)
        all_vals.append(vals)

    fig, ax = plt.subplots(figsize=(10, 6))
    total_width = 0.8
    bar_width = total_width / n
    x = range(len(percentiles))

    for idx, (vals, label) in enumerate(zip(all_vals, run_labels)):
        color = NWAY_COLORS[idx % len(NWAY_COLORS)]
        offset = (idx - n / 2 + 0.5) * bar_width
        ax.bar([i + offset for i in x], vals, bar_width, label=label, color=color)

    ax.set_xlabel("Percentile")
    ax.set_ylabel("Latency (ms)")
    ax.set_title("Publish Latency Distribution (N-Way)")
    ax.set_xticks(list(x))
    ax.set_xticklabels(percentiles)
    ax.legend()
    ax.grid(True, alpha=0.3, axis="y")

    path = output_dir / "latency_distribution_nway.png"
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    return path.name


def chart_resources_nway(run_dirs, run_labels, output_dir):
    """Generate CPU and memory comparison chart for N versions."""
    if not HAS_MATPLOTLIB:
        return None

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(16, 6))

    for idx, (results_dir, label) in enumerate(zip(run_dirs, run_labels)):
        color = NWAY_COLORS[idx % len(NWAY_COLORS)]
        metrics_dirs = sorted(Path(results_dir).glob("metrics_*"))
        if not metrics_dirs:
            continue
        md = metrics_dirs[-1]

        # CPU
        for s in extract_time_series(load_json(md / "ts_cpu.json")):
            if s["timestamps"]:
                t0 = s["timestamps"][0]
                times = [(t - t0) / 60 for t in s["timestamps"]]
                ax1.plot(times, s["values"], color=color, alpha=0.5, linewidth=1)

        # Memory
        for s in extract_time_series(load_json(md / "ts_memory.json")):
            if s["timestamps"]:
                t0 = s["timestamps"][0]
                times = [(t - t0) / 60 for t in s["timestamps"]]
                mem_mb = [v / (1024 * 1024) for v in s["values"]]
                ax2.plot(times, mem_mb, color=color, alpha=0.5, linewidth=1)

        ax1.plot([], [], color=color, label=label, linewidth=2)
        ax2.plot([], [], color=color, label=label, linewidth=2)

    ax1.set_xlabel("Time (minutes)")
    ax1.set_ylabel("CPU Usage (cores)")
    ax1.set_title("CPU Usage Over Time (N-Way)")
    ax1.legend()
    ax1.grid(True, alpha=0.3)

    ax2.set_xlabel("Time (minutes)")
    ax2.set_ylabel("Memory (MB)")
    ax2.set_title("Memory Usage Over Time (N-Way)")
    ax2.legend()
    ax2.grid(True, alpha=0.3)

    path = output_dir / "resource_usage_nway.png"
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    return path.name


# ---------------------------------------------------------------------------
# Comparison logic
# ---------------------------------------------------------------------------


def compare_scenario(scenario_name, baseline_dir, integration_dir):
    """Compare a single scenario between baseline and integration."""
    bl_summary = load_csv_pairs(baseline_dir / "summary.csv") if baseline_dir else {}
    int_summary = load_csv_pairs(integration_dir / "summary.csv") if integration_dir else {}
    bl_timing = load_csv_pairs(baseline_dir / "timing.csv") if baseline_dir else {}
    int_timing = load_csv_pairs(integration_dir / "timing.csv") if integration_dir else {}

    return {
        "name": scenario_name,
        "baseline_summary": bl_summary,
        "integration_summary": int_summary,
        "baseline_timing": bl_timing,
        "integration_timing": int_timing,
    }


def evaluate_criteria(scenario_name, comparison):
    """Evaluate pass/fail criteria for a scenario."""
    criteria = CRITERIA.get(scenario_name, {})
    if not criteria:
        return {"status": "N/A", "description": "No criteria defined"}

    description = criteria.get("description", "")
    # In a real run, values would be extracted from collected metrics.
    # Here we provide the evaluation framework.
    return {"status": "PENDING", "description": description}


def detect_regressions(baseline_metrics, integration_metrics):
    """Detect metrics that regressed more than the threshold."""
    regressions = []
    for key in set(baseline_metrics) & set(integration_metrics):
        try:
            bl_val = float(baseline_metrics[key])
            int_val = float(integration_metrics[key])
            if bl_val > 0:
                change_pct = ((int_val - bl_val) / bl_val) * 100
                # Negative change = regression for throughput metrics
                if "latency" in key or "loss" in key or "time" in key:
                    # Higher is worse
                    if change_pct > REGRESSION_THRESHOLD_PCT:
                        regressions.append((key, bl_val, int_val, change_pct))
                else:
                    # Lower is worse
                    if change_pct < -REGRESSION_THRESHOLD_PCT:
                        regressions.append((key, bl_val, int_val, change_pct))
        except (ValueError, ZeroDivisionError):
            pass
    return regressions


# ---------------------------------------------------------------------------
# Report generation (2-way, existing)
# ---------------------------------------------------------------------------


def generate_report(baseline_dir, integration_dir, output_dir):
    """Generate the full markdown comparison report."""
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    baseline_path = Path(baseline_dir)
    integration_path = Path(integration_dir)

    bl_scenarios = find_scenario_dirs(baseline_path)
    int_scenarios = find_scenario_dirs(integration_path)
    all_scenario_names = sorted(set(bl_scenarios) | set(int_scenarios))

    bl_run = load_csv_pairs(baseline_path / "run_summary.csv")
    int_run = load_csv_pairs(integration_path / "run_summary.csv")

    bl_meta = load_metadata(baseline_path)
    int_meta = load_metadata(integration_path)

    # Generate charts
    charts = {}
    charts["throughput"] = chart_throughput(baseline_path, integration_path, output_dir)
    charts["latency"] = chart_latency_distribution(baseline_path, integration_path, output_dir)
    charts["heatmap_bl"] = chart_connection_heatmap(baseline_path, output_dir, "Baseline")
    charts["heatmap_int"] = chart_connection_heatmap(integration_path, output_dir, "Integration")
    charts["resources"] = chart_resource_usage(baseline_path, integration_path, output_dir)

    # Build comparisons
    comparisons = []
    all_regressions = []
    for name in all_scenario_names:
        bl_dir = bl_scenarios.get(name)
        int_dir = int_scenarios.get(name)
        comp = compare_scenario(name, bl_dir, int_dir)
        comp["criteria"] = evaluate_criteria(name, comp)
        comparisons.append(comp)

        # Detect regressions
        regs = detect_regressions(comp["baseline_summary"], comp["integration_summary"])
        for r in regs:
            all_regressions.append((name, *r))

    # Write markdown
    report_path = output_dir / "report.md"
    with open(report_path, "w") as f:
        f.write("# VerneMQ Benchmark Comparison Report\n\n")

        # Executive summary
        f.write("## Executive Summary\n\n")
        f.write(f"- **Baseline**: {bl_run.get('version', 'unknown')} "
                f"(tag: {bl_run.get('tag', 'unknown')})\n")
        f.write(f"- **Integration**: {int_run.get('version', 'unknown')} "
                f"(tag: {int_run.get('tag', 'unknown')})\n")
        f.write(f"- **Baseline profile**: {bl_meta.get('profile', 'unknown')}\n")
        f.write(f"- **Integration profile**: {int_meta.get('profile', 'unknown')}\n")
        bl_pools = bl_meta.get("profile_pool_sizes", "")
        int_pools = int_meta.get("profile_pool_sizes", "")
        if bl_pools or int_pools:
            f.write(f"- **Pool sizes**: baseline=[{bl_pools}], "
                    f"integration=[{int_pools}]\n")
        bl_workers = bl_meta.get("profile_worker_counts", "")
        int_workers = int_meta.get("profile_worker_counts", "")
        if bl_workers or int_workers:
            f.write(f"- **Worker counts**: baseline=[{bl_workers}], "
                    f"integration=[{int_workers}]\n")
        f.write(f"- **Scenarios compared**: {len(all_scenario_names)}\n")
        f.write(f"- **Regressions detected**: {len(all_regressions)}\n\n")

        if all_regressions:
            f.write("**WARNING: Regressions detected (>5% worse than baseline)**\n\n")
            f.write("| Scenario | Metric | Baseline | Integration | Change |\n")
            f.write("|----------|--------|----------|-------------|--------|\n")
            for scenario, metric, bl_val, int_val, change in all_regressions:
                f.write(f"| {scenario} | {metric} | {bl_val:.2f} | "
                        f"{int_val:.2f} | {change:+.1f}% |\n")
            f.write("\n")
        else:
            f.write("No regressions detected. All metrics within acceptable thresholds.\n\n")

        # Charts section
        f.write("## Performance Charts\n\n")
        if charts.get("throughput"):
            f.write("### Throughput Over Time\n\n")
            f.write(f"![Throughput]({charts['throughput']})\n\n")
        if charts.get("latency"):
            f.write("### Latency Distribution\n\n")
            f.write(f"![Latency]({charts['latency']})\n\n")
        if charts.get("heatmap_bl") or charts.get("heatmap_int"):
            f.write("### Connection Distribution Heatmap\n\n")
            if charts.get("heatmap_bl"):
                f.write(f"![Heatmap Baseline]({charts['heatmap_bl']})\n\n")
            if charts.get("heatmap_int"):
                f.write(f"![Heatmap Integration]({charts['heatmap_int']})\n\n")
        if charts.get("resources"):
            f.write("### Resource Usage\n\n")
            f.write(f"![Resources]({charts['resources']})\n\n")

        # Per-scenario comparison
        f.write("## Per-Scenario Results\n\n")
        for comp in comparisons:
            name = comp["name"]
            f.write(f"### {name}\n\n")

            criteria = comp["criteria"]
            status_icon = {"PASS": "PASS", "FAIL": "FAIL", "PENDING": "PENDING"}.get(
                criteria["status"], "N/A"
            )
            f.write(f"**Criteria**: {criteria['description']} [{status_icon}]\n\n")

            # Summary table
            bl_s = comp["baseline_summary"]
            int_s = comp["integration_summary"]
            all_keys = sorted(set(bl_s) | set(int_s))

            if all_keys:
                f.write("| Metric | Baseline | Integration | Change |\n")
                f.write("|--------|----------|-------------|--------|\n")
                for key in all_keys:
                    bl_v = bl_s.get(key, "N/A")
                    int_v = int_s.get(key, "N/A")
                    change = ""
                    try:
                        bl_f = float(bl_v)
                        int_f = float(int_v)
                        if bl_f != 0:
                            pct = ((int_f - bl_f) / bl_f) * 100
                            change = f"{pct:+.1f}%"
                    except (ValueError, ZeroDivisionError):
                        pass
                    f.write(f"| {key} | {bl_v} | {int_v} | {change} |\n")
                f.write("\n")

            # Timing table
            bl_t = comp["baseline_timing"]
            int_t = comp["integration_timing"]
            time_keys = sorted(set(bl_t) | set(int_t))

            if time_keys:
                f.write("**Timing:**\n\n")
                f.write("| Metric | Baseline | Integration | Change |\n")
                f.write("|--------|----------|-------------|--------|\n")
                for key in time_keys:
                    bl_v = bl_t.get(key, "N/A")
                    int_v = int_t.get(key, "N/A")
                    change = ""
                    try:
                        bl_f = float(bl_v)
                        int_f = float(int_v)
                        if bl_f != 0:
                            pct = ((int_f - bl_f) / bl_f) * 100
                            change = f"{pct:+.1f}%"
                    except (ValueError, ZeroDivisionError):
                        pass
                    f.write(f"| {key} | {bl_v}s | {int_v}s | {change} |\n")
                f.write("\n")

        # Feature highlights (dynamic based on profile metadata)
        int_features = int_meta.get("profile_features", "")
        if int_features:
            f.write("## Integration Features\n\n")
            f.write("Features enabled in integration profile:\n\n")
            for feat in int_features.split():
                f.write(f"- `{feat}`\n")
            f.write("\n")

        # Pass/fail summary
        f.write("## Pass/Fail Summary\n\n")
        f.write("| Scenario | Criteria | Status |\n")
        f.write("|----------|----------|--------|\n")
        for comp in comparisons:
            name = comp["name"]
            criteria = comp["criteria"]
            f.write(f"| {name} | {criteria['description']} | {criteria['status']} |\n")
        f.write("\n")

        f.write("---\n\n")
        f.write("*Report generated by bench/scripts/report.py*\n")

    print(f"Report written to {report_path}")
    return report_path


# ---------------------------------------------------------------------------
# N-way report generation
# ---------------------------------------------------------------------------


def generate_report_nway(run_dirs, output_dir):
    """Generate an N-way comparison markdown report.

    Args:
        run_dirs: List of result directory paths (first = baseline).
        output_dir: Path to output directory.
    """
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    run_paths = [Path(d) for d in run_dirs]
    n = len(run_paths)

    # Load metadata and run summaries for each version
    run_summaries = [load_csv_pairs(p / "run_summary.csv") for p in run_paths]
    run_metas = [load_metadata(p) for p in run_paths]

    # Build labels: "Baseline (ref)" for first, "Version N (ref)" for rest
    run_labels = []
    for i, rs in enumerate(run_summaries):
        ref = rs.get("version", rs.get("ref", f"run-{i+1}"))
        if i == 0:
            run_labels.append(f"Baseline ({ref})")
        else:
            run_labels.append(f"Version {i+1} ({ref})")

    # Discover all scenario dirs across all runs
    all_scenario_sets = [find_scenario_dirs(p) for p in run_paths]
    all_scenario_names = sorted(
        set().union(*(s.keys() for s in all_scenario_sets))
    )

    # Generate N-way charts
    charts = {}
    charts["throughput"] = chart_throughput_nway(run_paths, run_labels, output_dir)
    charts["latency"] = chart_latency_nway(run_paths, run_labels, output_dir)
    charts["resources"] = chart_resources_nway(run_paths, run_labels, output_dir)

    # Detect regressions for each non-baseline vs baseline
    all_regressions = []
    baseline_scenarios = all_scenario_sets[0] if all_scenario_sets else {}

    for scenario_name in all_scenario_names:
        bl_dir = baseline_scenarios.get(scenario_name)
        bl_summary = load_csv_pairs(bl_dir / "summary.csv") if bl_dir else {}

        for i in range(1, n):
            other_dir = all_scenario_sets[i].get(scenario_name)
            other_summary = load_csv_pairs(other_dir / "summary.csv") if other_dir else {}
            regs = detect_regressions(bl_summary, other_summary)
            for metric, bl_val, other_val, change in regs:
                all_regressions.append((scenario_name, run_labels[i], metric, bl_val, other_val, change))

    # Write markdown report
    report_path = output_dir / "report.md"
    with open(report_path, "w") as f:
        f.write("# VerneMQ N-Way Benchmark Comparison Report\n\n")

        # Executive summary table
        f.write("## Executive Summary\n\n")
        f.write("| | " + " | ".join(run_labels) + " |\n")
        f.write("|---|" + "|".join(["---"] * n) + "|\n")

        f.write("| **Tag** | " + " | ".join(
            rs.get("tag", "unknown") for rs in run_summaries
        ) + " |\n")
        f.write("| **Version** | " + " | ".join(
            rs.get("version", "unknown") for rs in run_summaries
        ) + " |\n")
        f.write("| **Profile** | " + " | ".join(
            rm.get("profile", "unknown") for rm in run_metas
        ) + " |\n")

        f.write(f"\n- **Versions compared**: {n}\n")
        f.write(f"- **Scenarios compared**: {len(all_scenario_names)}\n")
        f.write(f"- **Regressions detected**: {len(all_regressions)}\n\n")

        if all_regressions:
            f.write("**WARNING: Regressions detected (>5% worse than baseline)**\n\n")
            f.write("| Scenario | Version | Metric | Baseline | Value | Change |\n")
            f.write("|----------|---------|--------|----------|-------|--------|\n")
            for scenario, version, metric, bl_val, other_val, change in all_regressions:
                f.write(f"| {scenario} | {version} | {metric} | "
                        f"{bl_val:.2f} | {other_val:.2f} | {change:+.1f}% |\n")
            f.write("\n")
        else:
            f.write("No regressions detected. All metrics within acceptable thresholds.\n\n")

        # Charts section
        f.write("## Performance Charts\n\n")
        if charts.get("throughput"):
            f.write("### Throughput Over Time\n\n")
            f.write(f"![Throughput]({charts['throughput']})\n\n")
        if charts.get("latency"):
            f.write("### Latency Distribution\n\n")
            f.write(f"![Latency]({charts['latency']})\n\n")
        if charts.get("resources"):
            f.write("### Resource Usage\n\n")
            f.write(f"![Resources]({charts['resources']})\n\n")

        # Per-scenario N-column tables
        f.write("## Per-Scenario Results\n\n")
        for scenario_name in all_scenario_names:
            f.write(f"### {scenario_name}\n\n")

            # Evaluate criteria
            criteria = CRITERIA.get(scenario_name, {})
            if criteria:
                desc = criteria.get("description", "No criteria defined")
                f.write(f"**Criteria**: {desc}\n\n")

            # Collect summaries for all versions
            scenario_summaries = []
            for ss in all_scenario_sets:
                sdir = ss.get(scenario_name)
                scenario_summaries.append(
                    load_csv_pairs(sdir / "summary.csv") if sdir else {}
                )

            # Build N-column table
            all_keys = sorted(
                set().union(*(s.keys() for s in scenario_summaries))
            )

            if all_keys:
                f.write("| Metric | " + " | ".join(run_labels) + " |\n")
                f.write("|--------|" + "|".join(["--------"] * n) + "|\n")

                baseline_summary = scenario_summaries[0]
                for key in all_keys:
                    row = [f"| {key}"]
                    bl_v = baseline_summary.get(key, "N/A")
                    row.append(f" {bl_v}")

                    for i in range(1, n):
                        other_v = scenario_summaries[i].get(key, "N/A")
                        change_str = ""
                        try:
                            bl_f = float(bl_v)
                            other_f = float(other_v)
                            if bl_f != 0:
                                pct = ((other_f - bl_f) / bl_f) * 100
                                change_str = f" ({pct:+.1f}%)"
                        except (ValueError, ZeroDivisionError):
                            pass
                        row.append(f" {other_v}{change_str}")

                    f.write(" | ".join(row) + " |\n")
                f.write("\n")

            # Timing table
            scenario_timings = []
            for ss in all_scenario_sets:
                sdir = ss.get(scenario_name)
                scenario_timings.append(
                    load_csv_pairs(sdir / "timing.csv") if sdir else {}
                )

            time_keys = sorted(
                set().union(*(t.keys() for t in scenario_timings))
            )
            if time_keys:
                f.write("**Timing:**\n\n")
                f.write("| Metric | " + " | ".join(run_labels) + " |\n")
                f.write("|--------|" + "|".join(["--------"] * n) + "|\n")

                baseline_timing = scenario_timings[0]
                for key in time_keys:
                    row = [f"| {key}"]
                    bl_v = baseline_timing.get(key, "N/A")
                    row.append(f" {bl_v}s")

                    for i in range(1, n):
                        other_v = scenario_timings[i].get(key, "N/A")
                        change_str = ""
                        try:
                            bl_f = float(bl_v)
                            other_f = float(other_v)
                            if bl_f != 0:
                                pct = ((other_f - bl_f) / bl_f) * 100
                                change_str = f" ({pct:+.1f}%)"
                        except (ValueError, ZeroDivisionError):
                            pass
                        row.append(f" {other_v}s{change_str}")

                    f.write(" | ".join(row) + " |\n")
                f.write("\n")

        # Pass/fail summary
        f.write("## Pass/Fail Summary\n\n")
        f.write("| Scenario | Criteria | Status |\n")
        f.write("|----------|----------|--------|\n")
        for scenario_name in all_scenario_names:
            criteria = CRITERIA.get(scenario_name, {})
            desc = criteria.get("description", "No criteria defined")
            status = "PENDING" if criteria else "N/A"
            f.write(f"| {scenario_name} | {desc} | {status} |\n")
        f.write("\n")

        f.write("---\n\n")
        f.write("*Report generated by bench/scripts/report.py*\n")

    print(f"N-way report written to {report_path}")
    return report_path


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description="Generate VerneMQ benchmark comparison report"
    )
    parser.add_argument(
        "--baseline",
        help="Path to baseline results directory (2-way mode)",
    )
    parser.add_argument(
        "--candidate",
        dest="candidate",
        help="Path to candidate results directory (2-way mode)",
    )
    parser.add_argument(
        "--integration",
        dest="candidate",
        help=argparse.SUPPRESS,  # deprecated alias for --candidate
    )
    parser.add_argument(
        "--run",
        action="append",
        dest="run_dirs",
        metavar="DIR",
        help="Path to a run results directory (repeatable, N-way mode)",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Path to output directory for report and charts",
    )
    args = parser.parse_args()

    # Determine mode: N-way or legacy 2-way
    if args.run_dirs and len(args.run_dirs) >= 2:
        # N-way mode
        for d in args.run_dirs:
            if not os.path.isdir(d):
                print(f"ERROR: Run directory not found: {d}", file=sys.stderr)
                sys.exit(1)
        generate_report_nway(args.run_dirs, args.output)
    elif args.baseline and args.candidate:
        # Legacy 2-way mode
        if not os.path.isdir(args.baseline):
            print(f"ERROR: Baseline directory not found: {args.baseline}", file=sys.stderr)
            sys.exit(1)
        if not os.path.isdir(args.candidate):
            print(f"ERROR: Candidate directory not found: {args.candidate}", file=sys.stderr)
            sys.exit(1)
        generate_report(args.baseline, args.candidate, args.output)
    else:
        print(
            "ERROR: Provide either --baseline + --candidate (2-way) "
            "or 2+ --run arguments (N-way)",
            file=sys.stderr,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
