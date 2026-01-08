#!/bin/bash
#
# run_latency_test.sh - Measure input event latency using ftrace
#
# Uses kernel ftrace to measure input pipeline latency:
#   T1: kernel input_event (trace_input_event in evdev.c)
#   T2: sched_wakeup for InputReader/InputDispatcher
#   Latency = T2 - T1
#
# This captures the epoll/ESM difference in userspace event delivery.
# NOTE: Requires PHYSICAL touch input - automated input bypasses the measured path.
#
# Output: CSV file with latency measurements
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
LOGS_DIR="$SCRIPT_DIR/../logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Test configuration - can be overridden via environment
TAP_SAMPLES=${TAP_SAMPLES:-100}
SWIPE_SAMPLES=${SWIPE_SAMPLES:-20}

# Determine output directory based on build type
BUILD_TYPE="${1:-unknown}"
OUTPUT_DIR="$RESULTS_DIR/$BUILD_TYPE"
TRACES_DIR="$OUTPUT_DIR/traces"
mkdir -p "$OUTPUT_DIR" "$TRACES_DIR" "$LOGS_DIR"

OUTPUT_CSV="$OUTPUT_DIR/latency.csv"
LOG_FILE="$LOGS_DIR/latency_test_$TIMESTAMP.log"

# Touch device (auto-detected)
TOUCH_DEVICE=""
TOUCH_DEVICE_NUM=""

log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    log "ERROR: $1"
    exit 1
}

# Check device connection and root
check_device() {
    log "Checking device connection..."
    if ! adb devices | grep -q "device$"; then
        error "No device connected"
    fi

    log "Enabling root access..."
    adb root 2>/dev/null || log "Note: Could not get root"
    sleep 2
}

# Detect touchscreen device
detect_touch_device() {
    log "Detecting touchscreen device..."

    # Find device with multi-touch capability
    TOUCH_DEVICE=$(adb shell "getevent -pl 2>/dev/null" | grep -B10 "ABS_MT_POSITION" | grep "add device" | head -1 | awk '{print $4}')

    if [[ -z "$TOUCH_DEVICE" ]]; then
        TOUCH_DEVICE=$(adb shell "getevent -pl 2>/dev/null" | grep -B5 "BTN_TOUCH" | grep "add device" | head -1 | awk '{print $4}')
    fi

    if [[ -z "$TOUCH_DEVICE" ]]; then
        log "Warning: Could not auto-detect touchscreen, using /dev/input/event2"
        TOUCH_DEVICE="/dev/input/event2"
    fi

    # Extract device number for sendevent
    TOUCH_DEVICE_NUM=$(echo "$TOUCH_DEVICE" | grep -oP 'event\K\d+')

    log "Detected touchscreen: $TOUCH_DEVICE (event$TOUCH_DEVICE_NUM)"

    # Get device info for coordinate scaling
    log "Getting touchscreen properties..."
    adb shell "getevent -pl $TOUCH_DEVICE" > "$LOGS_DIR/touch_device_info.txt" 2>/dev/null || true
}

# Setup ftrace for input event tracing
setup_ftrace() {
    log "Setting up ftrace..."

    # Verify input_event tracepoint exists (requires kernel modification)
    if ! adb shell "test -d /sys/kernel/debug/tracing/events/input/input_event" 2>/dev/null; then
        error "Kernel input_event tracepoint not found. Kernel must include input ftrace tracepoint (see paper Section IV)."
    fi

    # Enable input and sched tracepoints
    # Use large buffer (128MB) to avoid sched_wakeup flooding dropping input events
    adb shell "
        echo 0 > /sys/kernel/debug/tracing/tracing_on
        echo > /sys/kernel/debug/tracing/trace
        echo 131072 > /sys/kernel/debug/tracing/buffer_size_kb
        echo 1 > /sys/kernel/debug/tracing/events/input/input_event/enable
        echo 1 > /sys/kernel/debug/tracing/events/sched/sched_wakeup/enable
    " || error "Failed to setup ftrace"

    log "ftrace ready (input_event + sched_wakeup enabled)"
}

# Start ftrace
start_ftrace() {
    local trace_name="$1"

    log "Starting ftrace: $trace_name"

    adb shell "
        echo > /sys/kernel/debug/tracing/trace
        echo 1 > /sys/kernel/debug/tracing/tracing_on
    "
}

# Stop ftrace and pull trace
stop_ftrace() {
    local trace_name="$1"
    local local_path="$2"

    log "Stopping ftrace..."

    adb shell "echo 0 > /sys/kernel/debug/tracing/tracing_on"

    # Pull trace
    adb shell "cat /sys/kernel/debug/tracing/trace" > "$local_path" || {
        log "Warning: Could not pull trace"
        return 1
    }

    log "Trace saved: $local_path"
}

# Count touches in live trace (BTN_TOUCH down = one tap)
count_live_touches() {
    # Count BTN_TOUCH down events (type=1/EV_KEY, code=330/BTN_TOUCH, value=1/down)
    # Each tap generates exactly one BTN_TOUCH down event
    local count=$(adb shell "cat /sys/kernel/debug/tracing/trace | grep -c 'input_event:.*type=1.*code=330.*value=1'" 2>/dev/null || echo "0")
    echo "${count//[^0-9]/}"  # Clean non-numeric chars
}

# Wait for N touches/gestures, monitoring the trace in real-time
wait_for_touches() {
    local target_count="$1"
    local gesture_type="$2"
    local check_interval=2
    local no_progress_timeout=30  # seconds without new input before warning
    local no_progress_count=0

    log ">>> PERFORM $target_count ${gesture_type}S ON THE SCREEN <<<"
    log ">>> Starting in 3 seconds... <<<"
    sleep 3

    local current_count=0
    local last_count=0

    while [[ $current_count -lt $target_count ]]; do
        sleep $check_interval

        # Check current touch count from live trace
        current_count=$(count_live_touches)

        if [[ $current_count -gt $last_count ]]; then
            log ">>> $current_count / $target_count ${gesture_type}s detected <<<"
            last_count=$current_count
            no_progress_count=0
        else
            no_progress_count=$((no_progress_count + check_interval))
            if [[ $no_progress_count -ge $no_progress_timeout ]]; then
                log ">>> WARNING: No input detected for ${no_progress_timeout}s <<<"
                log ">>> Got $current_count / $target_count - continuing with available samples <<<"
                break
            fi
        fi
    done

    if [[ $current_count -ge $target_count ]]; then
        log ">>> All $target_count ${gesture_type}s received! <<<"
    else
        log ">>> Proceeding with $current_count ${gesture_type}s (timeout) <<<"
    fi
}

# Run single tap test with ftrace
# IMPORTANT: Requires physical touch input - automated input tap bypasses evdev
test_single_tap() {
    log "Running single tap test ($TAP_SAMPLES samples)..."
    log "NOTE: This test requires PHYSICAL touch input on the device screen"

    local trace_file="$TRACES_DIR/tap_trace.txt"

    start_ftrace "tap_trace"

    # Wait for user to perform taps (counted in real-time)
    wait_for_touches "$TAP_SAMPLES" "TAP"

    stop_ftrace "tap_trace" "$trace_file"

    log "Single tap test complete"
}

# Run fast swipe test with ftrace
test_fast_swipe() {
    log "Running fast swipe test ($SWIPE_SAMPLES samples)..."
    log "NOTE: This test requires PHYSICAL fast swipes on the device screen"

    local trace_file="$TRACES_DIR/swipe_trace.txt"

    start_ftrace "swipe_trace"

    # Wait for user to perform swipes (counted in real-time)
    wait_for_touches "$SWIPE_SAMPLES" "SWIPE"

    stop_ftrace "swipe_trace" "$trace_file"

    log "Fast swipe test complete"
}

# Parse ftrace text files and generate CSV
analyze_traces() {
    log "Analyzing ftrace traces..."

    python3 "$SCRIPT_DIR/parse_ftrace_latency.py" "$TRACES_DIR" "$OUTPUT_CSV"

    log "Results saved to: $OUTPUT_CSV"
}

# Print summary statistics
print_summary() {
    log "=== Latency Test Summary ==="

    if [[ -f "$OUTPUT_CSV" ]]; then
        for scenario in "single_tap" "fast_swipe"; do
            values=$(grep "^$scenario," "$OUTPUT_CSV" 2>/dev/null | cut -d, -f3)
            if [[ -n "$values" ]]; then
                count=$(echo "$values" | wc -l)
                mean=$(echo "$values" | awk '{sum+=$1} END {if(NR>0) printf "%.2f", sum/NR; else print "N/A"}')
                log "  $scenario: n=$count, mean=${mean}ms"
            fi
        done
    else
        log "  No results file found"
    fi
}

# Main execution
main() {
    log "=========================================="
    log "ESM Latency Test (ftrace) - Build: $BUILD_TYPE"
    log "=========================================="

    if [[ "$BUILD_TYPE" == "unknown" ]]; then
        echo "Usage: $0 <baseline|esm>"
        echo "  baseline - Test stock AOSP with epoll"
        echo "  esm      - Test ESM-modified AOSP"
        echo ""
        echo "NOTE: This test requires PHYSICAL touch input on the device screen."
        echo ""
        echo "Environment variables:"
        echo "  TAP_SAMPLES   - Number of tap samples (default: 100)"
        echo "  SWIPE_SAMPLES - Number of swipe samples (default: 20)"
        exit 1
    fi

    check_device
    detect_touch_device
    setup_ftrace

    test_single_tap
    test_fast_swipe

    analyze_traces
    print_summary

    log "=========================================="
    log "Latency test complete!"
    log "Traces: $TRACES_DIR"
    log "Results: $OUTPUT_CSV"
    log "=========================================="
}

main "$@"
