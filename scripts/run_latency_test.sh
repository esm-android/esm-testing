#!/bin/bash
#
# run_latency_test.sh - Measure input event latency using ftrace
#
# Measures time from hardware IRQ to input event delivery.
# Tests three scenarios: single tap, scroll (50 events), fast swipe (100 events).
#
# Output: CSV file with latency measurements
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
LOGS_DIR="$SCRIPT_DIR/../logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Test configuration
TAP_SAMPLES=50
SCROLL_SAMPLES=20
SWIPE_SAMPLES=20
TAP_DELAY=2        # seconds between taps
SCROLL_DELAY=5     # seconds between scrolls
SWIPE_DELAY=5      # seconds between swipes

# Determine output directory based on build type
BUILD_TYPE="${1:-unknown}"
OUTPUT_DIR="$RESULTS_DIR/$BUILD_TYPE"
mkdir -p "$OUTPUT_DIR" "$LOGS_DIR"

OUTPUT_CSV="$OUTPUT_DIR/latency.csv"
LOG_FILE="$LOGS_DIR/latency_test_$TIMESTAMP.log"

log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    log "ERROR: $1"
    exit 1
}

# Check root access (required for ftrace)
check_root() {
    log "Checking root access..."
    ROOT_CHECK=$(adb shell "id" | grep -c "uid=0" || echo "0")
    if [[ "$ROOT_CHECK" -eq 0 ]]; then
        log "Attempting to get root..."
        adb root
        sleep 2
    fi
}

# Setup ftrace for input event tracing
setup_ftrace() {
    log "Setting up ftrace..."

    # Clear trace buffer
    adb shell "echo > /sys/kernel/debug/tracing/trace"

    # Set buffer size (8MB per CPU)
    adb shell "echo 8192 > /sys/kernel/debug/tracing/buffer_size_kb"

    # Enable input event tracepoint
    adb shell "echo 1 > /sys/kernel/debug/tracing/events/input/input_event/enable" 2>/dev/null || \
        log "Warning: Could not enable input/input_event tracepoint"

    # Enable IRQ tracepoints for touchscreen
    adb shell "echo 1 > /sys/kernel/debug/tracing/events/irq/irq_handler_entry/enable" 2>/dev/null || \
        log "Warning: Could not enable irq/irq_handler_entry tracepoint"

    adb shell "echo 1 > /sys/kernel/debug/tracing/events/irq/irq_handler_exit/enable" 2>/dev/null || \
        log "Warning: Could not enable irq/irq_handler_exit tracepoint"

    # Enable function tracing for ESM (if available)
    adb shell "echo 1 > /sys/kernel/debug/tracing/events/syscalls/sys_enter_esm_wait/enable" 2>/dev/null || true
    adb shell "echo 1 > /sys/kernel/debug/tracing/events/syscalls/sys_exit_esm_wait/enable" 2>/dev/null || true

    log "ftrace setup complete"
}

# Start tracing
start_trace() {
    adb shell "echo > /sys/kernel/debug/tracing/trace"
    adb shell "echo 1 > /sys/kernel/debug/tracing/tracing_on"
}

# Stop tracing and capture
stop_trace() {
    local output_file="$1"
    adb shell "echo 0 > /sys/kernel/debug/tracing/tracing_on"
    adb shell "cat /sys/kernel/debug/tracing/trace" > "$output_file"
}

# Disable ftrace
cleanup_ftrace() {
    log "Cleaning up ftrace..."
    adb shell "echo 0 > /sys/kernel/debug/tracing/events/input/input_event/enable" 2>/dev/null || true
    adb shell "echo 0 > /sys/kernel/debug/tracing/events/irq/irq_handler_entry/enable" 2>/dev/null || true
    adb shell "echo 0 > /sys/kernel/debug/tracing/events/irq/irq_handler_exit/enable" 2>/dev/null || true
    adb shell "echo 0 > /sys/kernel/debug/tracing/tracing_on" 2>/dev/null || true
}

# Run single tap test
test_single_tap() {
    log "Running single tap test ($TAP_SAMPLES samples)..."

    local results=()

    for i in $(seq 1 $TAP_SAMPLES); do
        # Start trace
        start_trace

        # Generate single tap
        adb shell "input tap 540 1200"

        # Small delay for event processing
        sleep 0.1

        # Stop trace and capture
        local trace_file="$LOGS_DIR/tap_trace_${i}.txt"
        stop_trace "$trace_file"

        # Parse latency from trace
        local latency=$(python3 "$SCRIPT_DIR/parse_ftrace.py" "$trace_file" 2>/dev/null || echo "")

        if [[ -n "$latency" ]]; then
            results+=("$latency")
            log "  Tap $i: ${latency}ms"
        else
            log "  Tap $i: Could not parse latency"
        fi

        # Delay between samples
        sleep $TAP_DELAY
    done

    # Output results
    echo "single_tap" > "$LOGS_DIR/tap_results.tmp"
    printf '%s\n' "${results[@]}" >> "$LOGS_DIR/tap_results.tmp"

    log "Single tap test complete: ${#results[@]} valid samples"
}

# Run scroll test
test_scroll() {
    log "Running scroll test ($SCROLL_SAMPLES samples)..."

    local results=()

    for i in $(seq 1 $SCROLL_SAMPLES); do
        start_trace

        # Generate scroll (50 events)
        adb shell "input swipe 540 1500 540 500 500"

        sleep 0.5
        local trace_file="$LOGS_DIR/scroll_trace_${i}.txt"
        stop_trace "$trace_file"

        local latency=$(python3 "$SCRIPT_DIR/parse_ftrace.py" "$trace_file" --aggregate 2>/dev/null || echo "")

        if [[ -n "$latency" ]]; then
            results+=("$latency")
            log "  Scroll $i: ${latency}ms (aggregate)"
        fi

        sleep $SCROLL_DELAY
    done

    echo "scroll" > "$LOGS_DIR/scroll_results.tmp"
    printf '%s\n' "${results[@]}" >> "$LOGS_DIR/scroll_results.tmp"

    log "Scroll test complete: ${#results[@]} valid samples"
}

# Run fast swipe test
test_fast_swipe() {
    log "Running fast swipe test ($SWIPE_SAMPLES samples)..."

    local results=()

    for i in $(seq 1 $SWIPE_SAMPLES); do
        start_trace

        # Generate fast swipe (100 events)
        adb shell "input swipe 540 1800 540 200 200"

        sleep 0.3
        local trace_file="$LOGS_DIR/swipe_trace_${i}.txt"
        stop_trace "$trace_file"

        local latency=$(python3 "$SCRIPT_DIR/parse_ftrace.py" "$trace_file" --aggregate 2>/dev/null || echo "")

        if [[ -n "$latency" ]]; then
            results+=("$latency")
            log "  Swipe $i: ${latency}ms (aggregate)"
        fi

        sleep $SWIPE_DELAY
    done

    echo "fast_swipe" > "$LOGS_DIR/swipe_results.tmp"
    printf '%s\n' "${results[@]}" >> "$LOGS_DIR/swipe_results.tmp"

    log "Fast swipe test complete: ${#results[@]} valid samples"
}

# Combine results into CSV
generate_csv() {
    log "Generating CSV output..."

    echo "scenario,sample,latency_ms" > "$OUTPUT_CSV"

    # Process tap results
    if [[ -f "$LOGS_DIR/tap_results.tmp" ]]; then
        tail -n +2 "$LOGS_DIR/tap_results.tmp" | nl -n ln | while read n val; do
            echo "single_tap,$n,$val" >> "$OUTPUT_CSV"
        done
    fi

    # Process scroll results
    if [[ -f "$LOGS_DIR/scroll_results.tmp" ]]; then
        tail -n +2 "$LOGS_DIR/scroll_results.tmp" | nl -n ln | while read n val; do
            echo "scroll,$n,$val" >> "$OUTPUT_CSV"
        done
    fi

    # Process swipe results
    if [[ -f "$LOGS_DIR/swipe_results.tmp" ]]; then
        tail -n +2 "$LOGS_DIR/swipe_results.tmp" | nl -n ln | while read n val; do
            echo "fast_swipe,$n,$val" >> "$OUTPUT_CSV"
        done
    fi

    # Cleanup temp files
    rm -f "$LOGS_DIR"/*.tmp

    log "Results saved to: $OUTPUT_CSV"
}

# Print summary statistics
print_summary() {
    log "=== Latency Test Summary ==="

    if [[ -f "$OUTPUT_CSV" ]]; then
        for scenario in "single_tap" "scroll" "fast_swipe"; do
            values=$(grep "^$scenario," "$OUTPUT_CSV" | cut -d, -f3)
            if [[ -n "$values" ]]; then
                count=$(echo "$values" | wc -l)
                mean=$(echo "$values" | awk '{sum+=$1} END {printf "%.2f", sum/NR}')
                log "  $scenario: n=$count, mean=${mean}ms"
            fi
        done
    fi
}

# Main execution
main() {
    log "=========================================="
    log "ESM Latency Test - Build: $BUILD_TYPE"
    log "=========================================="

    if [[ "$BUILD_TYPE" == "unknown" ]]; then
        echo "Usage: $0 <baseline|esm>"
        echo "  baseline - Test stock AOSP with epoll"
        echo "  esm      - Test ESM-modified AOSP"
        exit 1
    fi

    check_root
    setup_ftrace

    trap cleanup_ftrace EXIT

    test_single_tap
    test_scroll
    test_fast_swipe

    generate_csv
    print_summary

    log "=========================================="
    log "Latency test complete!"
    log "Results: $OUTPUT_CSV"
    log "=========================================="
}

main "$@"
