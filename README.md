# ESM Performance Testing Framework

Scientific validation of Event Stream Model (ESM) performance claims for Android 12.

## Overview

This testing framework validates the following ESM performance claims:

| Metric | Claimed (epoll → ESM) | Claimed Improvement |
|--------|----------------------|---------------------|
| Single tap latency | 2.3 ms → 1.8 ms | 21% faster |
| Scroll (50 events) | 15.7 ms → 11.2 ms | 29% faster |
| Fast swipe (100 events) | 32.4 ms → 22.1 ms | 32% faster |
| system_server CPU | 18.2% → 15.7% | 13.7% less |
| Total system CPU | 42.6% → 39.1% | 8.2% less |
| Syscalls (100 events) | 300 → 5 | 98% fewer |
| Wakeups/sec | 142 → 98 | 31% fewer |

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
│   ├── setup_device.sh       # Device preparation
│   ├── generate_input.py     # Automated input generation
│   ├── run_latency_test.sh   # Latency measurement
│   ├── run_cpu_test.sh       # CPU usage measurement
│   ├── run_syscall_test.sh   # Syscall counting
│   ├── run_wakeup_test.sh    # Wakeup measurement
│   ├── parse_ftrace.py       # ftrace output parser
│   ├── analyze_results.py    # Statistical analysis
│   └── run_full_suite.sh     # Master test runner
├── results/
│   ├── baseline/             # Stock AOSP results
│   │   ├── latency.csv
│   │   ├── cpu.csv
│   │   ├── syscalls.csv
│   │   └── wakeups.csv
│   └── esm/                  # ESM build results
│       ├── latency.csv
│       ├── cpu.csv
│       ├── syscalls.csv
│       └── wakeups.csv
├── logs/                     # Raw test logs
├── report.md                 # Final analysis report
└── README.md                 # This file
```

## Individual Tests

### Latency Test
Measures time from hardware IRQ to InputFlinger event processing using ftrace.

```bash
./run_latency_test.sh baseline  # or 'esm'
```

Output: `results/<build>/latency.csv`

### CPU Test
Measures system_server and total CPU usage during 60-second interaction sessions.

```bash
./run_cpu_test.sh baseline  # or 'esm'
```

Output: `results/<build>/cpu.csv`

### Syscall Test
Counts syscalls (epoll_wait, read, esm_wait) while processing 100 input events.

```bash
./run_syscall_test.sh baseline  # or 'esm'
```

Output: `results/<build>/syscalls.csv`

### Wakeup Test
Measures CPU wakeups per second during 5-minute interaction sessions.

```bash
./run_wakeup_test.sh baseline  # or 'esm'
```

Output: `results/<build>/wakeups.csv`

## Automated Input Generation

The `generate_input.py` script provides automated touch event generation:

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

## Statistical Analysis

The analysis script calculates:

- **Descriptive statistics**: Mean, standard deviation, 95% CI
- **Hypothesis testing**: Welch's t-test for unequal variances
- **Effect size**: Cohen's d with interpretation

### Validation Criteria

Claims are **validated** if:
- p-value < 0.05 (statistically significant)
- Improvement direction matches claim
- Effect size is medium or large (Cohen's d > 0.5)

Claims are **refuted** if:
- No significant improvement (p > 0.05)
- Results show regression
- Improvement less than 50% of claim

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

### "strace not found"
strace should be available on userdebug builds. If missing:
```bash
# Check if strace exists
adb shell which strace

# Alternative: use /proc-based syscall counting
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
- Latency tests: 30 minutes
- CPU tests: 15 minutes
- Syscall tests: 15 minutes
- Wakeup tests: 45 minutes
- **Total per build**: ~2 hours

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
