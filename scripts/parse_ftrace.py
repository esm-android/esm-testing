#!/usr/bin/env python3
"""
parse_ftrace.py - Parse ftrace output to extract input event latency

Parses kernel ftrace output to calculate the time between:
- IRQ handler entry (touchscreen interrupt)
- Input event delivery to userspace

Usage:
    python3 parse_ftrace.py trace.txt
    python3 parse_ftrace.py trace.txt --aggregate  # For multi-event traces
"""

import sys
import re
import argparse
from dataclasses import dataclass
from typing import List, Optional, Tuple


@dataclass
class TraceEvent:
    """Represents a single ftrace event."""
    timestamp: float      # Timestamp in seconds
    cpu: int             # CPU number
    task: str            # Task name
    pid: int             # Process ID
    event_type: str      # Event type (irq_handler_entry, input_event, etc.)
    details: str         # Event-specific details


def parse_ftrace_line(line: str) -> Optional[TraceEvent]:
    """
    Parse a single ftrace line.

    Example formats:
    InputReader-1234 [002] ....  1234.567890: irq_handler_entry: irq=123 name=fts_touch
    InputReader-1234 [002] ....  1234.567890: input_event: type=3 code=53 value=500

    """
    # Skip comment lines and empty lines
    if line.startswith('#') or not line.strip():
        return None

    # ftrace format: task-pid [cpu] flags timestamp: event: details
    pattern = r'^\s*(.+?)-(\d+)\s+\[(\d+)\]\s+[\w.]+\s+([\d.]+):\s+(\w+):\s*(.*)$'
    match = re.match(pattern, line)

    if not match:
        return None

    return TraceEvent(
        task=match.group(1).strip(),
        pid=int(match.group(2)),
        cpu=int(match.group(3)),
        timestamp=float(match.group(4)),
        event_type=match.group(5),
        details=match.group(6)
    )


def is_touch_irq(event: TraceEvent) -> bool:
    """Check if this is a touchscreen IRQ event."""
    if event.event_type != 'irq_handler_entry':
        return False

    # Common touchscreen controller names
    touch_names = ['fts', 'touch', 'sec_ts', 'synaptics', 'goodix', 'atmel', 'nt36']

    details_lower = event.details.lower()
    return any(name in details_lower for name in touch_names)


def is_input_event(event: TraceEvent) -> bool:
    """Check if this is an input_event trace."""
    return event.event_type == 'input_event'


def is_esm_event(event: TraceEvent) -> bool:
    """Check if this is an ESM-related event."""
    return 'esm' in event.event_type.lower()


def calculate_single_latency(events: List[TraceEvent]) -> Optional[float]:
    """
    Calculate latency for a single touch event.

    Returns latency in milliseconds from first IRQ to last input_event.
    """
    irq_events = [e for e in events if is_touch_irq(e)]
    input_events = [e for e in events if is_input_event(e)]

    if not irq_events or not input_events:
        return None

    # Get first IRQ and last input event
    first_irq = min(irq_events, key=lambda e: e.timestamp)
    last_input = max(input_events, key=lambda e: e.timestamp)

    # Calculate latency in milliseconds
    latency_ms = (last_input.timestamp - first_irq.timestamp) * 1000

    # Sanity check - latency should be positive and reasonable
    if latency_ms < 0 or latency_ms > 1000:
        return None

    return latency_ms


def calculate_aggregate_latency(events: List[TraceEvent]) -> Optional[float]:
    """
    Calculate aggregate latency for multi-event traces (scrolls, swipes).

    Returns the total time from first IRQ to last input_event.
    """
    irq_events = [e for e in events if is_touch_irq(e)]
    input_events = [e for e in events if is_input_event(e)]

    if not irq_events or not input_events:
        return None

    first_irq = min(irq_events, key=lambda e: e.timestamp)
    last_input = max(input_events, key=lambda e: e.timestamp)

    latency_ms = (last_input.timestamp - first_irq.timestamp) * 1000

    if latency_ms < 0 or latency_ms > 10000:  # Allow up to 10s for gestures
        return None

    return latency_ms


def calculate_per_event_latencies(events: List[TraceEvent]) -> List[float]:
    """
    Calculate individual latencies for each IRQ->input_event pair.

    Useful for detailed analysis of multi-event traces.
    """
    irq_events = sorted([e for e in events if is_touch_irq(e)],
                       key=lambda e: e.timestamp)
    input_events = sorted([e for e in events if is_input_event(e)],
                         key=lambda e: e.timestamp)

    latencies = []

    # Match IRQ events to subsequent input events
    input_idx = 0
    for irq in irq_events:
        # Find first input event after this IRQ
        while input_idx < len(input_events):
            inp = input_events[input_idx]
            if inp.timestamp > irq.timestamp:
                latency = (inp.timestamp - irq.timestamp) * 1000
                if 0 < latency < 100:  # Reasonable single-event latency
                    latencies.append(latency)
                break
            input_idx += 1

    return latencies


def parse_trace_file(filepath: str) -> List[TraceEvent]:
    """Parse entire trace file."""
    events = []

    with open(filepath, 'r') as f:
        for line in f:
            event = parse_ftrace_line(line)
            if event:
                events.append(event)

    return events


def analyze_trace(filepath: str, aggregate: bool = False) -> dict:
    """
    Analyze a trace file and return statistics.

    Args:
        filepath: Path to ftrace output file
        aggregate: If True, calculate aggregate latency for entire trace
                  If False, calculate per-event latencies

    Returns:
        Dictionary with analysis results
    """
    events = parse_trace_file(filepath)

    results = {
        'total_events': len(events),
        'irq_events': len([e for e in events if is_touch_irq(e)]),
        'input_events': len([e for e in events if is_input_event(e)]),
        'esm_events': len([e for e in events if is_esm_event(e)]),
    }

    if aggregate:
        latency = calculate_aggregate_latency(events)
        results['aggregate_latency_ms'] = latency
    else:
        latencies = calculate_per_event_latencies(events)
        if latencies:
            results['latencies_ms'] = latencies
            results['mean_latency_ms'] = sum(latencies) / len(latencies)
            results['min_latency_ms'] = min(latencies)
            results['max_latency_ms'] = max(latencies)

    return results


def main():
    parser = argparse.ArgumentParser(
        description='Parse ftrace output to extract input event latency'
    )
    parser.add_argument('trace_file', help='Path to ftrace output file')
    parser.add_argument('--aggregate', action='store_true',
                       help='Calculate aggregate latency for entire trace')
    parser.add_argument('--verbose', '-v', action='store_true',
                       help='Print detailed analysis')

    args = parser.parse_args()

    try:
        results = analyze_trace(args.trace_file, args.aggregate)
    except FileNotFoundError:
        print(f"Error: File not found: {args.trace_file}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error parsing trace: {e}", file=sys.stderr)
        sys.exit(1)

    if args.verbose:
        print(f"Trace Analysis: {args.trace_file}")
        print(f"  Total events: {results['total_events']}")
        print(f"  IRQ events: {results['irq_events']}")
        print(f"  Input events: {results['input_events']}")
        print(f"  ESM events: {results['esm_events']}")

        if 'aggregate_latency_ms' in results:
            if results['aggregate_latency_ms'] is not None:
                print(f"  Aggregate latency: {results['aggregate_latency_ms']:.2f} ms")
            else:
                print("  Aggregate latency: Could not calculate")

        if 'mean_latency_ms' in results:
            print(f"  Mean latency: {results['mean_latency_ms']:.2f} ms")
            print(f"  Min latency: {results['min_latency_ms']:.2f} ms")
            print(f"  Max latency: {results['max_latency_ms']:.2f} ms")
            print(f"  Sample count: {len(results['latencies_ms'])}")
    else:
        # Simple output for script consumption
        if args.aggregate:
            latency = results.get('aggregate_latency_ms')
            if latency is not None:
                print(f"{latency:.2f}")
        else:
            mean = results.get('mean_latency_ms')
            if mean is not None:
                print(f"{mean:.2f}")


if __name__ == '__main__':
    main()
