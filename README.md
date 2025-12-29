# ESM Performance Testing Framework

Scientific measurement of Event Stream Model (ESM) performance for Android 12.

## Overview

This testing framework measures ESM performance improvements across the following metrics:

| Metric | Description |
|--------|-------------|
| Input latency | Time from kernel input event to InputReader wakeup |
| CPU usage | system_server and total CPU during interaction |
| Syscall count | Number of syscalls per batch of input events |
| Wakeups/sec | CPU wakeups during interactive use |
| Power consumption | Battery drain in idle and active scenarios |

ESM replaces Android's epoll-based input polling with push-based event delivery. This framework provides rigorous A/B testing to quantify any performance differences.

## Prerequisites

### Hardware
- Google Pixel 5 (redfin) with unlocked bootloader
- USB cable for ADB connection

### Software
- Linux host machine (Ubuntu 20.04+ recommended)
- Android SDK Platform-tools (ADB, fastboot)
- Python 3.8+
- Two Android 12 builds:
  1. **Baseline**: Stock AOSP android-12.0.0_r3
  2. **ESM**: AOSP with ESM patches applied

### Kernel Requirement
Both builds must include the custom `input_event` ftrace tracepoint added to the evdev driver. See the paper's methodology section for tracepoint implementation details.

### Build Requirements
Both builds must be `userdebug` variant for debugging capabilities:
```bash
lunch aosp_redfin-userdebug
```

## Quick Start

### 1. Run Baseline Tests
```bash
# Flash stock AOSP to device
fastboot flashall -w

# Run baseline test suite
cd testing/scripts
./run_full_suite.sh baseline
```

### 2. Run ESM Tests
```bash
# Flash ESM-modified AOSP to device
fastboot flashall -w

# Run ESM test suite
./run_full_suite.sh esm
```

### 3. Generate Report
```bash
# Generate comparison report
./run_full_suite.sh analyze

# View results
cat ../report.md
```

## Directory Structure

```
testing/
├── scripts/
│   ├── setup_device.sh        # Device preparation
│   ├── generate_input.py      # Automated input generation
│   ├── run_latency_test.sh    # Latency measurement (ftrace-based)
│   ├── run_cpu_test.sh        # CPU usage measurement
│   ├── run_syscall_test.sh    # Syscall counting
│   ├── run_wakeup_test.sh     # Wakeup measurement
│   ├── run_power_test.sh      # Power consumption (idle + active)
│   ├── parse_ftrace_latency.py # ftrace trace parser
│   ├── analyze_results.py     # Statistical analysis
│   └── run_full_suite.sh      # Master test runner
├── results/
│   ├── baseline/              # Stock AOSP results
│   │   ├── latency.csv
│   │   ├── cpu.csv
│   │   ├── syscalls.csv
│   │   ├── wakeups.csv
│   │   ├── power.csv
│   │   └── traces/            # ftrace trace files
│   └── esm/                   # ESM build results
│       ├── latency.csv
│       ├── cpu.csv
│       ├── syscalls.csv
│       ├── wakeups.csv
│       ├── power.csv
│       └── traces/            # ftrace trace files
├── logs/                      # Raw test logs
├── report.md                  # Final analysis report
└── README.md                  # This file
```

## Physical Touch Requirements

**IMPORTANT**: Some tests require PHYSICAL touch input on the device screen. Automated input injection via `adb shell input tap` or `sendevent` **does not work** for these tests because:

1. Injected events follow a loopback path (userspace → kernel → userspace)
2. This bypasses the hardware interrupt path that ESM optimizes
3. Only physical touch from actual hardware traverses the correct kernel→userspace path

### Tests Requiring Physical Touch
- **Latency tests**: All tap, scroll, and swipe latency measurements
- **Power tests (active)**: Active power consumption during touch interaction

### Tests Using Automated Input
- **CPU tests**: Measures overall CPU usage (input path doesn't affect measurement)
- **Syscall tests**: Counts syscalls (strace captures regardless of input source)
- **Wakeup tests**: Measures interrupt counts (automated input is sufficient)
- **Power tests (idle)**: No input required

## Individual Tests

### Latency Test (PHYSICAL TOUCH REQUIRED)
Measures input event processing latency using kernel ftrace tracing.

**What is measured:**
- T1: Kernel `trace_input_event()` timestamp in evdev.c
- T2: `sched_wakeup` timestamp for InputReader thread
- Latency = T2 - T1 (the epoll/ESM critical path)

**Tracepoint placement (evdev.c):**
```c
static void evdev_events(...)
{
    /* T1: Tracepoint fires here - BEFORE both baseline/ESM paths */
    for (v = vals; v != vals + count; v++)
        trace_input_event(dev_name, v->type, v->code, v->value);

    /* Baseline: evdev_pass_values → wake_up_interruptible() */
    /* ESM: esm_push_event → wake_up() */
}
```

Both paths trigger `sched_wakeup` for InputReader, enabling fair comparison.

```bash
./run_latency_test.sh baseline  # or 'esm'
```

The script will prompt you to physically touch the device screen.

Output: `results/<build>/latency.csv`

### CPU Test
Measures system_server and total CPU usage during 60-second interaction sessions.

```bash
./run_cpu_test.sh baseline  # or 'esm'
```

Environment variables:
```bash
TEST_DURATION=60     # Test duration (seconds)
NUM_RUNS=10          # Number of test runs
```

Output: `results/<build>/cpu.csv`

### Syscall Test
Counts syscalls (epoll_wait, read, esm_wait) while processing 100 input events.

```bash
./run_syscall_test.sh baseline  # or 'esm'
```

Output: `results/<build>/syscalls.csv`

### Wakeup Test
Measures CPU wakeups per second during 2-minute interaction sessions.

```bash
./run_wakeup_test.sh baseline  # or 'esm'
```

Environment variables:
```bash
TEST_DURATION=120    # Test duration (seconds)
NUM_RUNS=10          # Number of test runs
```

Output: `results/<build>/wakeups.csv`

### Power Test (Active tests require PHYSICAL TOUCH)
Measures power consumption in two scenarios:

**Idle**: Screen on, no interaction for 15 minutes
- Measures baseline power draw with ESM/epoll waiting for events
- Lower is better (ESM should have fewer idle wakeups)

**Active** (PHYSICAL TOUCH REQUIRED): Continuous physical tapping for 15 minutes
- Measures power draw during sustained input processing
- Tests event delivery efficiency
- You will be prompted to tap the screen continuously

```bash
./run_power_test.sh baseline  # or 'esm'
```

Environment variables:
```bash
IDLE_DURATION=900             # Idle test duration (seconds, default 15 min)
ACTIVE_DURATION=900           # Active test duration (seconds, default 15 min)
CURRENT_SAMPLE_INTERVAL=10    # Current sampling interval (seconds)
NUM_RUNS=5                    # Number of test runs per scenario
```

Output: `results/<build>/power.csv`

## Automated Input Generation

The `generate_input.py` script provides automated touch event generation with seeded random for reproducibility:

```bash
# Generate 100 single taps
python3 generate_input.py tap 100

# Generate 20 scroll gestures
python3 generate_input.py scroll 20

# Generate 20 fast swipes
python3 generate_input.py swipe 20

# Generate 60 seconds of mixed interaction
python3 generate_input.py mixed 60
```

Note: Automated input is suitable for CPU, syscall, and wakeup tests, but NOT for latency or active power tests.

## Statistical Analysis

The analysis script calculates:

- **Descriptive statistics**: Mean, standard deviation, 95% CI
- **Hypothesis testing**: Welch's t-test for unequal variances
- **Effect size**: Cohen's d with interpretation

### Sample Size Justification

Sample sizes were determined using power analysis for 80% power at α=0.05:

| Test | Samples | Rationale |
|------|---------|-----------|
| Latency | 100 taps | Large effect detection (d=0.8) requires n≥25 |
| CPU | 10 runs × 60s | CLT ensures normality with 10 samples |
| Wakeup | 10 runs × 2min | Sufficient for interrupt rate estimation |
| Power | 5 runs × 15min | 90 current samples/run provides fine-grained data |

### Statistical Significance Criteria

Results are considered **statistically significant** if:
- p-value < 0.05 (statistically significant difference)
- Effect size is medium or large (Cohen's d > 0.5)

Results are **not significant** if:
- p-value ≥ 0.05 (no significant difference)
- Effect size is small or negligible (Cohen's d < 0.5)

## Troubleshooting

### "No device connected"
```bash
# Check ADB connection
adb devices

# If not authorized, check device for prompt
adb kill-server
adb start-server
```

### "Could not get root"
The device must be running a userdebug build:
```bash
adb shell getprop ro.build.type
# Should output: userdebug
```

### "Kernel input_event tracepoint not found"
The kernel must include the custom ftrace tracepoint. Verify it exists:
```bash
adb shell "test -d /sys/kernel/debug/tracing/events/input/input_event && echo OK"
# Should output: OK
```

If not present, the kernel needs to be rebuilt with the tracepoint modification.

### "strace not found"
strace should be available on userdebug builds. If missing:
```bash
# Check if strace exists
adb shell which strace
```

### Thermal throttling
If results are inconsistent, check for thermal throttling:
```bash
adb shell cat /sys/class/thermal/thermal_zone*/temp
```
Allow device to cool between test runs.

## Test Duration

Approximate test times:
- Setup: 3 minutes
- Latency tests (physical touch): ~3 minutes
- CPU tests: ~15 minutes
- Syscall tests: ~15 minutes
- Wakeup tests: ~25 minutes
- Power tests: ~3 hours (5 runs each of 15-min idle + 15-min active with cooldown)
- **Total per build**: ~4 hours

## Contributing

To improve the testing methodology:

1. Modify test scripts in `scripts/`
2. Run tests on both builds
3. Verify analysis produces valid results
4. Submit changes with test data

## License

MIT License - See main ESM repository for details.

## References

- [ESM Technical Documentation](../docs/ESM_TECHNICAL.md)
- [ESM Build Guide](../docs/ESM_BUILD_HOWTO.md)
- [ESM GitHub Organization](https://github.com/esm-android)
