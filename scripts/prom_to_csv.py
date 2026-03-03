#!/usr/bin/env python3
"""prom_to_csv.py - Convert Prometheus range query JSON to flat CSV.

Reads Prometheus API JSON responses (from /api/v1/query_range) and writes
flat CSV files with columns: timestamp, metric_name, instance, value.

Supports single-file mode and batch directory mode.

Usage:
    # Single file
    ./prom_to_csv.py --input result.json --output result.csv

    # Batch directory
    ./prom_to_csv.py --input-dir ./json/ --output-dir ./csv/
"""

import argparse
import csv
import glob
import json
import os
import sys
from datetime import datetime, timezone


def parse_prometheus_json(data):
    """Parse Prometheus range query JSON and yield CSV rows.

    Expected format:
    {
        "status": "success",
        "data": {
            "resultType": "matrix",
            "result": [
                {
                    "metric": {"__name__": "...", "instance": "...", ...},
                    "values": [[timestamp, "value"], ...]
                },
                ...
            ]
        }
    }

    Yields:
        Tuples of (timestamp_iso, metric_name, instance, value).
    """
    if data.get("status") != "success":
        return

    results = data.get("data", {}).get("result", [])

    for series in results:
        metric_labels = series.get("metric", {})
        metric_name = metric_labels.get("__name__", "unknown")
        instance = metric_labels.get("instance", "")

        values = series.get("values", [])
        for ts_epoch, value in values:
            ts_iso = datetime.fromtimestamp(
                float(ts_epoch), tz=timezone.utc
            ).strftime("%Y-%m-%dT%H:%M:%SZ")
            yield (ts_iso, metric_name, instance, value)


def convert_file(input_path, output_path):
    """Convert a single Prometheus JSON file to CSV."""
    try:
        with open(input_path, "r") as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(f"WARNING: Failed to read {input_path}: {e}", file=sys.stderr)
        return 0

    rows = list(parse_prometheus_json(data))

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)

    with open(output_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["timestamp", "metric_name", "instance", "value"])
        writer.writerows(rows)

    return len(rows)


def convert_directory(input_dir, output_dir):
    """Convert all .json files in a directory to .csv files."""
    os.makedirs(output_dir, exist_ok=True)

    json_files = sorted(glob.glob(os.path.join(input_dir, "*.json")))
    if not json_files:
        print(f"No .json files found in {input_dir}", file=sys.stderr)
        return

    total_rows = 0
    converted = 0

    for json_path in json_files:
        basename = os.path.splitext(os.path.basename(json_path))[0]
        csv_path = os.path.join(output_dir, f"{basename}.csv")

        rows = convert_file(json_path, csv_path)
        total_rows += rows
        converted += 1

    print(
        f"Converted {converted} files ({total_rows} total data points) "
        f"from {input_dir} to {output_dir}",
        file=sys.stderr,
    )


def main():
    parser = argparse.ArgumentParser(
        description="Convert Prometheus range query JSON to flat CSV"
    )

    # Single file mode
    parser.add_argument(
        "--input", metavar="FILE", help="Input JSON file (single file mode)"
    )
    parser.add_argument(
        "--output", metavar="FILE", help="Output CSV file (single file mode)"
    )

    # Batch directory mode
    parser.add_argument(
        "--input-dir", metavar="DIR", help="Input directory with .json files (batch mode)"
    )
    parser.add_argument(
        "--output-dir", metavar="DIR", help="Output directory for .csv files (batch mode)"
    )

    args = parser.parse_args()

    # Validate arguments
    single_mode = args.input is not None or args.output is not None
    batch_mode = args.input_dir is not None or args.output_dir is not None

    if single_mode and batch_mode:
        parser.error("Cannot mix single file mode (--input/--output) with batch mode (--input-dir/--output-dir)")

    if single_mode:
        if not args.input or not args.output:
            parser.error("Single file mode requires both --input and --output")
        rows = convert_file(args.input, args.output)
        print(f"Wrote {rows} rows to {args.output}", file=sys.stderr)

    elif batch_mode:
        if not args.input_dir or not args.output_dir:
            parser.error("Batch mode requires both --input-dir and --output-dir")
        convert_directory(args.input_dir, args.output_dir)

    else:
        parser.error("Specify --input/--output (single file) or --input-dir/--output-dir (batch)")


if __name__ == "__main__":
    main()
