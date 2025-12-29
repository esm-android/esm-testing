#!/usr/bin/env python3
"""
parse_ftrace_latency.py - Parse ftrace text output for input latency

Calculates latency from:
- T1: input_event ftrace timestamp (kernel receives input)
- T2: sched_wakeup for InputDispatcher (userspace wakeup)
- Latency = T2 - T1

This measures the epoll/ESM critical path.
"""

import argparse
import csv
import os
import re
import sys
from pathlib import Path
from typing import List, Dict, Tuple


def parse_ftrace_file(trace_path: str) -> List[Dict]:
    """Parse a single ftrace text file and extract latency measurements."""

    results = []

    # Regex patterns for ftrace lines
    # Format: <task>-<pid> [<cpu>] <flags> <timestamp>: <event>: <data>
    input_event_pattern = re.compile(
        r'\s*\S+-\d+\s+\[\d+\]\s+\S+\s+(\d+\.\d+):\s+input_event:\s+dev=(\S+)\s+type=(\d+)\s+code=(\d+)\s+value=(\d+)'
    )

    sched_wakeup_pattern = re.compile(
        r'\s*\S+-\d+\s+\[\d+\]\s+\S+\s+(\d+\.\d+):\s+sched_wakeup:\s+comm=(\S+)\s+pid=(\d+)'
    )

    input_events = []  # (timestamp, type, code, value)
    wakeup_events = []  # (timestamp, comm)

    try:
        with open(trace_path, 'r') as f:
            for line in f:
                # Parse input_event
                match = input_event_pattern.search(line)
                if match:
                    ts = float(match.group(1))
                    ev_type = int(match.group(3))
                    code = int(match.group(4))
                    value = int(match.group(5))
                    input_events.append((ts, ev_type, code, value))
                    continue

                # Parse sched_wakeup for InputDispatcher
                match = sched_wakeup_pattern.search(line)
                if match:
                    ts = float(match.group(1))
                    comm = match.group(2)
                    if 'InputDispatcher' in comm or 'InputReader' in comm:
                        wakeup_events.append((ts, comm))

    except Exception as e:
        print(f"Error parsing {trace_path}: {e}", file=sys.stderr)
        return results

    if not input_events:
        print(f"No input_event found in {trace_path}", file=sys.stderr)
        return results

    if not wakeup_events:
        print(f"No InputDispatcher wakeups found in {trace_path}", file=sys.stderr)
        return results

    # Group input events into gestures
    # A gesture starts with BTN_TOUCH press (type=1, code=330, value=1)
    gesture_starts = []

    for ts, ev_type, code, value in input_events:
        # BTN_TOUCH press indicates start of touch
        if ev_type == 1 and code == 330 and value == 1:
            gesture_starts.append(ts)

    # For each gesture start, find the next InputDispatcher wakeup
    for t1 in gesture_starts:
        for t2, comm in wakeup_events:
            if t2 > t1:
                latency_ms = (t2 - t1) * 1000  # Convert to ms
                if 0 < latency_ms < 50:  # Reasonable range
                    results.append({
                        'kernel_ts': t1,
                        'wakeup_ts': t2,
                        'latency_ms': latency_ms,
                        'wakeup_thread': comm
                    })
                break

    return results


def get_scenario_from_filename(filename: str) -> str:
    """Extract test scenario from trace filename."""
    filename_lower = filename.lower()
    if 'tap' in filename_lower:
        return 'single_tap'
    elif 'scroll' in filename_lower:
        return 'scroll'
    elif 'swipe' in filename_lower:
        return 'fast_swipe'
    return 'unknown'


def main():
    parser = argparse.ArgumentParser(
        description='Parse ftrace text files for input latency analysis'
    )
    parser.add_argument('traces_dir', help='Directory containing ftrace .txt files')
    parser.add_argument('output_csv', help='Output CSV file path')

    args = parser.parse_args()

    traces_dir = Path(args.traces_dir)
    if not traces_dir.exists():
        print(f"Traces directory not found: {traces_dir}", file=sys.stderr)
        sys.exit(1)

    # Find all trace files
    trace_files = list(traces_dir.glob('*.txt'))

    if not trace_files:
        print(f"No trace files found in: {traces_dir}", file=sys.stderr)
        with open(args.output_csv, 'w', newline='') as f:
            writer = csv.writer(f)
            writer.writerow(['scenario', 'sample', 'latency_ms'])
        sys.exit(0)

    print(f"Found {len(trace_files)} trace files")

    all_results = []

    for trace_file in trace_files:
        scenario = get_scenario_from_filename(trace_file.name)
        print(f"Analyzing: {trace_file.name} ({scenario})")

        results = parse_ftrace_file(str(trace_file))
        print(f"  Found {len(results)} latency measurements")

        for i, result in enumerate(results, 1):
            all_results.append({
                'scenario': scenario,
                'sample': i,
                'latency_ms': result['latency_ms']
            })

    # Write CSV output
    with open(args.output_csv, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['scenario', 'sample', 'latency_ms'])

        for result in all_results:
            writer.writerow([
                result['scenario'],
                result['sample'],
                f"{result['latency_ms']:.3f}"
            ])

    print(f"\nResults written to: {args.output_csv}")

    # Print summary
    from collections import defaultdict
    by_scenario = defaultdict(list)
    for r in all_results:
        by_scenario[r['scenario']].append(r['latency_ms'])

    print("\nSummary:")
    for scenario, latencies in sorted(by_scenario.items()):
        if latencies:
            mean = sum(latencies) / len(latencies)
            min_lat = min(latencies)
            max_lat = max(latencies)
            print(f"  {scenario}: n={len(latencies)}, mean={mean:.3f}ms, min={min_lat:.3f}ms, max={max_lat:.3f}ms")


if __name__ == '__main__':
    main()
