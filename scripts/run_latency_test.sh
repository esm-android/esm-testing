#!/bin/bash
#
# run_latency_test.sh - Measure input event latency using Perfetto
#
# Uses Perfetto tracing to measure actual input pipeline latency:
#   kernel input_event → InputReader → InputDispatcher → App
#
# This captures the epoll/ESM difference in userspace event delivery.
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
SCROLL_SAMPLES=${SCROLL_SAMPLES:-20}
SWIPE_SAMPLES=${SWIPE_SAMPLES:-20}
TAP_DELAY=${TAP_DELAY:-1}
SCROLL_DELAY=${SCROLL_DELAY:-2}
SWIPE_DELAY=${SWIPE_DELAY:-2}

# Determine output directory based on build type
BUILD_TYPE="${1:-unknown}"
OUTPUT_DIR="$RESULTS_DIR/$BUILD_TYPE"
TRACES_DIR="$OUTPUT_DIR/traces"
mkdir -p "$OUTPUT_DIR" "$TRACES_DIR" "$LOGS_DIR"

OUTPUT_CSV="$OUTPUT_DIR/latency.csv"
LOG_FILE="$LOGS_DIR/latency_test_$TIMESTAMP.log"

# Perfetto config
PERFETTO_CFG="$SCRIPT_DIR/perfetto_input.cfg"

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
    adb shell "
        echo 0 > /sys/kernel/debug/tracing/tracing_on
        echo > /sys/kernel/debug/tracing/trace
        echo 32768 > /sys/kernel/debug/tracing/buffer_size_kb
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

# Generate tap using sendevent (low-level, goes through full kernel path)
# This is more accurate than `input tap` which bypasses some of the input stack
generate_tap() {
    local x="$1"
    local y="$2"

    # Use input tap for now - sendevent requires device-specific event codes
    # The key is that perfetto traces the full path regardless of injection method
    adb shell "input tap $x $y"
}

# Generate scroll gesture
generate_scroll() {
    local x="$1"
    local y1="$2"
    local y2="$3"
    local duration="$4"

    adb shell "input swipe $x $y1 $x $y2 $duration"
}

# Generate swipe gesture
generate_swipe() {
    local x="$1"
    local y1="$2"
    local y2="$3"
    local duration="$4"

    adb shell "input swipe $x $y1 $x $y2 $duration"
}

# Run single tap test with ftrace
# IMPORTANT: Requires physical touch input - automated input tap bypasses evdev
test_single_tap() {
    log "Running single tap test ($TAP_SAMPLES samples)..."
    log "NOTE: This test requires PHYSICAL touch input on the device screen"

    local trace_file="$TRACES_DIR/tap_trace.txt"

    start_ftrace "tap_trace"

    log ">>> TOUCH THE SCREEN $TAP_SAMPLES TIMES (1 tap every ${TAP_DELAY}s) <<<"
    log ">>> Starting in 3 seconds... <<<"
    sleep 3

    # Wait for user to perform taps
    local total_time=$((TAP_SAMPLES * TAP_DELAY + 5))
    log ">>> Waiting ${total_time}s for $TAP_SAMPLES taps... <<<"
    sleep $total_time

    stop_ftrace "tap_trace" "$trace_file"

    log "Single tap test complete"
}

# Run scroll test with ftrace
test_scroll() {
    log "Running scroll test ($SCROLL_SAMPLES samples)..."
    log "NOTE: This test requires PHYSICAL scroll gestures on the device screen"

    local trace_file="$TRACES_DIR/scroll_trace.txt"

    start_ftrace "scroll_trace"

    log ">>> SCROLL THE SCREEN $SCROLL_SAMPLES TIMES (1 scroll every ${SCROLL_DELAY}s) <<<"
    log ">>> Starting in 3 seconds... <<<"
    sleep 3

    local total_time=$((SCROLL_SAMPLES * SCROLL_DELAY + 5))
    log ">>> Waiting ${total_time}s for $SCROLL_SAMPLES scrolls... <<<"
    sleep $total_time

    stop_ftrace "scroll_trace" "$trace_file"

    log "Scroll test complete"
}

# Run fast swipe test with ftrace
test_fast_swipe() {
    log "Running fast swipe test ($SWIPE_SAMPLES samples)..."
    log "NOTE: This test requires PHYSICAL fast swipes on the device screen"

    local trace_file="$TRACES_DIR/swipe_trace.txt"

    start_ftrace "swipe_trace"

    log ">>> SWIPE THE SCREEN QUICKLY $SWIPE_SAMPLES TIMES (1 swipe every ${SWIPE_DELAY}s) <<<"
    log ">>> Starting in 3 seconds... <<<"
    sleep 3

    local total_time=$((SWIPE_SAMPLES * SWIPE_DELAY + 5))
    log ">>> Waiting ${total_time}s for $SWIPE_SAMPLES swipes... <<<"
    sleep $total_time

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
        for scenario in "single_tap" "scroll" "fast_swipe"; do
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
    log "ESM Latency Test (Perfetto) - Build: $BUILD_TYPE"
    log "=========================================="

    if [[ "$BUILD_TYPE" == "unknown" ]]; then
        echo "Usage: $0 <baseline|esm>"
        echo "  baseline - Test stock AOSP with epoll"
        echo "  esm      - Test ESM-modified AOSP"
        exit 1
    fi

    check_device
    detect_touch_device
    setup_ftrace

    test_single_tap
    test_scroll
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
