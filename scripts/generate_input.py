#!/usr/bin/env python3
"""
generate_input.py - Automated input event generation for ESM testing

This module provides functions to generate touch events via ADB for
reproducible performance testing. Events are generated using the
Android input command which injects events at the framework level.

Usage:
    from generate_input import InputGenerator
    gen = InputGenerator()
    gen.single_tap(100)  # Generate 100 single taps
    gen.scroll(20)       # Generate 20 scroll gestures
    gen.fast_swipe(20)   # Generate 20 fast swipes
"""

import subprocess
import time
import random
import sys
import argparse
from typing import Tuple, Optional
from dataclasses import dataclass


@dataclass
class TouchConfig:
    """Configuration for touch event generation."""
    screen_width: int = 1080      # Pixel 5 screen width
    screen_height: int = 2340     # Pixel 5 screen height
    safe_margin: int = 100        # Margin from screen edges
    tap_delay_ms: int = 100       # Delay between taps
    scroll_duration_ms: int = 500 # Duration of scroll gesture
    swipe_duration_ms: int = 200  # Duration of fast swipe


class InputGenerator:
    """Generate automated input events via ADB."""

    def __init__(self, config: Optional[TouchConfig] = None):
        self.config = config or TouchConfig()
        self._verify_connection()

    def _verify_connection(self) -> None:
        """Verify ADB connection is available."""
        result = subprocess.run(
            ['adb', 'devices'],
            capture_output=True,
            text=True
        )
        if 'device' not in result.stdout:
            raise RuntimeError("No ADB device connected")

    def _run_adb(self, cmd: str) -> subprocess.CompletedProcess:
        """Run an ADB shell command."""
        return subprocess.run(
            ['adb', 'shell', cmd],
            capture_output=True,
            text=True
        )

    def _random_point(self) -> Tuple[int, int]:
        """Generate a random point within safe screen area."""
        x = random.randint(
            self.config.safe_margin,
            self.config.screen_width - self.config.safe_margin
        )
        y = random.randint(
            self.config.safe_margin + 200,  # Avoid status bar
            self.config.screen_height - self.config.safe_margin - 200  # Avoid nav bar
        )
        return x, y

    def tap(self, x: int, y: int) -> None:
        """Generate a single tap at specified coordinates."""
        self._run_adb(f'input tap {x} {y}')

    def swipe(self, x1: int, y1: int, x2: int, y2: int, duration_ms: int) -> None:
        """Generate a swipe gesture."""
        self._run_adb(f'input swipe {x1} {y1} {x2} {y2} {duration_ms}')

    def single_tap(self, count: int = 1, delay_ms: Optional[int] = None) -> int:
        """
        Generate multiple single tap events.

        Args:
            count: Number of taps to generate
            delay_ms: Delay between taps (default from config)

        Returns:
            Number of taps generated
        """
        delay = (delay_ms or self.config.tap_delay_ms) / 1000.0

        for i in range(count):
            x, y = self._random_point()
            self.tap(x, y)
            if i < count - 1:
                time.sleep(delay)

            if (i + 1) % 10 == 0:
                print(f"  Generated {i + 1}/{count} taps", file=sys.stderr)

        return count

    def scroll(self, count: int = 1, events_per_scroll: int = 50) -> int:
        """
        Generate scroll gestures (vertical swipes).

        Each scroll generates approximately 50 input events.

        Args:
            count: Number of scroll gestures
            events_per_scroll: Target events per gesture (affects duration)

        Returns:
            Approximate total events generated
        """
        # Longer duration = more events
        duration = self.config.scroll_duration_ms

        for i in range(count):
            x = self.config.screen_width // 2
            # Alternate scroll direction
            if i % 2 == 0:
                y1, y2 = 1500, 500   # Scroll up
            else:
                y1, y2 = 500, 1500   # Scroll down

            self.swipe(x, y1, x, y2, duration)
            time.sleep(0.5)  # Wait between scrolls

            if (i + 1) % 5 == 0:
                print(f"  Generated {i + 1}/{count} scrolls", file=sys.stderr)

        return count * events_per_scroll

    def fast_swipe(self, count: int = 1, events_per_swipe: int = 100) -> int:
        """
        Generate fast swipe gestures.

        Each fast swipe generates approximately 100 input events.

        Args:
            count: Number of swipe gestures
            events_per_swipe: Target events per gesture

        Returns:
            Approximate total events generated
        """
        # Faster swipe = more events in shorter time
        duration = self.config.swipe_duration_ms

        for i in range(count):
            x = self.config.screen_width // 2
            # Long vertical swipe
            y1, y2 = 1800, 200
            if i % 2 == 1:
                y1, y2 = y2, y1  # Alternate direction

            self.swipe(x, y1, x, y2, duration)
            time.sleep(0.3)  # Brief pause between swipes

            if (i + 1) % 5 == 0:
                print(f"  Generated {i + 1}/{count} fast swipes", file=sys.stderr)

        return count * events_per_swipe

    def mixed_interaction(self, duration_seconds: int = 60) -> dict:
        """
        Generate a mixed interaction pattern for CPU testing.

        Simulates realistic user interaction: taps, scrolls, and swipes
        distributed over the specified duration.

        Args:
            duration_seconds: Total duration of interaction

        Returns:
            Dictionary with counts of each event type
        """
        stats = {'taps': 0, 'scrolls': 0, 'swipes': 0, 'total_events': 0}

        start_time = time.time()
        end_time = start_time + duration_seconds

        print(f"Starting {duration_seconds}s mixed interaction...", file=sys.stderr)

        while time.time() < end_time:
            elapsed = time.time() - start_time
            remaining = duration_seconds - elapsed

            if remaining < 1:
                break

            # Randomly choose action type
            action = random.choice(['tap', 'tap', 'scroll', 'swipe'])

            if action == 'tap':
                x, y = self._random_point()
                self.tap(x, y)
                stats['taps'] += 1
                stats['total_events'] += 1
                time.sleep(0.1)

            elif action == 'scroll':
                x = self.config.screen_width // 2
                direction = random.choice([(1500, 500), (500, 1500)])
                self.swipe(x, direction[0], x, direction[1], 500)
                stats['scrolls'] += 1
                stats['total_events'] += 50
                time.sleep(0.6)

            elif action == 'swipe':
                x = self.config.screen_width // 2
                direction = random.choice([(1800, 200), (200, 1800)])
                self.swipe(x, direction[0], x, direction[1], 200)
                stats['swipes'] += 1
                stats['total_events'] += 100
                time.sleep(0.4)

            # Progress update every 10 seconds
            if int(elapsed) % 10 == 0 and int(elapsed) > 0:
                print(f"  {int(elapsed)}s elapsed, {int(remaining)}s remaining",
                      file=sys.stderr)

        print(f"Completed: {stats}", file=sys.stderr)
        return stats


def main():
    """Command-line interface for input generation."""
    parser = argparse.ArgumentParser(
        description='Generate automated input events for ESM testing'
    )

    subparsers = parser.add_subparsers(dest='command', help='Command to run')

    # Single tap command
    tap_parser = subparsers.add_parser('tap', help='Generate single taps')
    tap_parser.add_argument('count', type=int, default=100, nargs='?',
                           help='Number of taps (default: 100)')
    tap_parser.add_argument('--delay', type=int, default=100,
                           help='Delay between taps in ms (default: 100)')

    # Scroll command
    scroll_parser = subparsers.add_parser('scroll', help='Generate scroll gestures')
    scroll_parser.add_argument('count', type=int, default=20, nargs='?',
                              help='Number of scrolls (default: 20)')

    # Fast swipe command
    swipe_parser = subparsers.add_parser('swipe', help='Generate fast swipes')
    swipe_parser.add_argument('count', type=int, default=20, nargs='?',
                             help='Number of swipes (default: 20)')

    # Mixed interaction command
    mixed_parser = subparsers.add_parser('mixed', help='Generate mixed interaction')
    mixed_parser.add_argument('duration', type=int, default=60, nargs='?',
                             help='Duration in seconds (default: 60)')

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return

    gen = InputGenerator()

    if args.command == 'tap':
        print(f"Generating {args.count} single taps...")
        count = gen.single_tap(args.count, args.delay)
        print(f"Generated {count} taps")

    elif args.command == 'scroll':
        print(f"Generating {args.count} scroll gestures...")
        events = gen.scroll(args.count)
        print(f"Generated ~{events} events")

    elif args.command == 'swipe':
        print(f"Generating {args.count} fast swipes...")
        events = gen.fast_swipe(args.count)
        print(f"Generated ~{events} events")

    elif args.command == 'mixed':
        print(f"Generating {args.duration}s of mixed interaction...")
        stats = gen.mixed_interaction(args.duration)
        print(f"Stats: {stats}")


if __name__ == '__main__':
    main()
