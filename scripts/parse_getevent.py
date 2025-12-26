#!/usr/bin/env python3
"""
parse_getevent.py - Parse getevent output to extract input event latency

Parses Android getevent -lt output to calculate the time spread of input events.
This provides a measurement of how long it takes to process a gesture from
first touch to last event.

getevent -lt format:
[    1234.567890] /dev/input/event2: 0003 0039 00000001

Usage:
    python3 parse_getevent.py getevent_output.txt
    python3 parse_getevent.py getevent_output.txt --verbose
"""

import sys
import re
import argparse
from typing import List, Optional, Tuple


def parse_getevent_line(line: str) -> Optional[Tuple[float, str, str, str]]:
    """
    Parse a single getevent -lt line.

    Returns (timestamp, device, type_code, value) or None if parse fails.

    Example line:
    [    1234.567890] /dev/input/event2: 0003 0039 00000001
    """
    # Pattern for getevent -lt output
    pattern = r'\[\s*(\d+\.\d+)\]\s+(/dev/input/event\d+):\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)'
    match = re.match(pattern, line.strip())

    if not match:
        return None

    timestamp = float(match.group(1))
    device = match.group(2)
    event_type = match.group(3)
    event_code = match.group(4)
    event_value = match.group(5)

    return (timestamp, device, f"{event_type}:{event_code}", event_value)


def parse_getevent_file(filepath: str) -> List[Tuple[float, str, str, str]]:
    """Parse entire getevent output file."""
    events = []

    try:
        with open(filepath, 'r') as f:
            for line in f:
                event = parse_getevent_line(line)
                if event:
                    events.append(event)
    except FileNotFoundError:
        return []

    return events


def calculate_latency(events: List[Tuple[float, str, str, str]]) -> Optional[float]:
    """
    Calculate latency (time spread) from first to last event.

    Returns latency in milliseconds.
    """
    if len(events) < 2:
        return None

    timestamps = [e[0] for e in events]
    first_ts = min(timestamps)
    last_ts = max(timestamps)

    latency_ms = (last_ts - first_ts) * 1000

    # Sanity check - latency should be reasonable
    if latency_ms < 0 or latency_ms > 10000:
        return None

    return latency_ms


def calculate_event_stats(events: List[Tuple[float, str, str, str]]) -> dict:
    """Calculate statistics about the events."""
    if not events:
        return {'count': 0}

    timestamps = [e[0] for e in events]

    # Count event types
    event_types = {}
    for _, _, type_code, _ in events:
        event_types[type_code] = event_types.get(type_code, 0) + 1

    # Calculate inter-event timing
    if len(timestamps) > 1:
        sorted_ts = sorted(timestamps)
        deltas = [sorted_ts[i+1] - sorted_ts[i] for i in range(len(sorted_ts)-1)]
        avg_delta = sum(deltas) / len(deltas) * 1000  # ms
        max_delta = max(deltas) * 1000
        min_delta = min(deltas) * 1000
    else:
        avg_delta = max_delta = min_delta = 0

    return {
        'count': len(events),
        'first_ts': min(timestamps),
        'last_ts': max(timestamps),
        'duration_ms': (max(timestamps) - min(timestamps)) * 1000,
        'event_types': event_types,
        'avg_inter_event_ms': avg_delta,
        'max_inter_event_ms': max_delta,
        'min_inter_event_ms': min_delta,
    }


def main():
    parser = argparse.ArgumentParser(
        description='Parse getevent output to extract input event latency'
    )
    parser.add_argument('getevent_file', help='Path to getevent output file')
    parser.add_argument('--verbose', '-v', action='store_true',
                       help='Print detailed analysis')

    args = parser.parse_args()

    events = parse_getevent_file(args.getevent_file)

    if not events:
        # No events captured - this is normal if no touch occurred
        if args.verbose:
            print(f"No events found in {args.getevent_file}", file=sys.stderr)
        sys.exit(0)

    latency = calculate_latency(events)

    if args.verbose:
        stats = calculate_event_stats(events)
        print(f"Event Analysis: {args.getevent_file}")
        print(f"  Total events: {stats['count']}")
        print(f"  Duration: {stats['duration_ms']:.2f} ms")
        print(f"  First timestamp: {stats['first_ts']:.6f}")
        print(f"  Last timestamp: {stats['last_ts']:.6f}")
        print(f"  Event types: {stats['event_types']}")
        print(f"  Avg inter-event: {stats['avg_inter_event_ms']:.3f} ms")
        print(f"  Min inter-event: {stats['min_inter_event_ms']:.3f} ms")
        print(f"  Max inter-event: {stats['max_inter_event_ms']:.3f} ms")
        if latency is not None:
            print(f"  Latency: {latency:.2f} ms")
    else:
        # Simple output for script consumption
        if latency is not None:
            print(f"{latency:.2f}")


if __name__ == '__main__':
    main()
