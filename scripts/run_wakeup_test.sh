#!/bin/bash
#
# run_wakeup_test.sh - Measure CPU wakeups during input interaction
#
# Tracks wakeup count from /proc/interrupts during physical touch input.
#
# NOTE: Requires PHYSICAL touch input - automated input bypasses the ESM path.
#
# Output: CSV file with wakeup measurements
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
LOGS_DIR="$SCRIPT_DIR/../logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Test configuration - can be overridden via environment
NUM_TAPS=${NUM_TAPS:-50}          # Number of taps per test run
NUM_RUNS=${NUM_RUNS:-5}           # Number of test runs

# Determine output directory
BUILD_TYPE="${1:-unknown}"
OUTPUT_DIR="$RESULTS_DIR/$BUILD_TYPE"
mkdir -p "$OUTPUT_DIR" "$LOGS_DIR"

OUTPUT_CSV="$OUTPUT_DIR/wakeups.csv"
LOG_FILE="$LOGS_DIR/wakeup_test_$TIMESTAMP.log"

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

# Setup ftrace for input event counting
setup_ftrace() {
    log "Setting up ftrace for touch counting..."

    if ! adb shell "test -d /sys/kernel/debug/tracing/events/input/input_event" 2>/dev/null; then
        error "input_event tracepoint not found. Kernel must include input ftrace tracepoint."
    fi

    adb shell "
        echo 0 > /sys/kernel/debug/tracing/tracing_on
        echo > /sys/kernel/debug/tracing/trace
        echo 8192 > /sys/kernel/debug/tracing/buffer_size_kb
        echo 1 > /sys/kernel/debug/tracing/events/input/input_event/enable
    " || error "Failed to setup ftrace"

    log "ftrace ready"
}

# Start ftrace
start_ftrace() {
    adb shell "
        echo > /sys/kernel/debug/tracing/trace
        echo 1 > /sys/kernel/debug/tracing/tracing_on
    "
}

# Stop ftrace
stop_ftrace() {
    adb shell "echo 0 > /sys/kernel/debug/tracing/tracing_on"
}

# Count touches from live trace (BTN_TOUCH down events)
count_live_touches() {
    local count=$(adb shell "cat /sys/kernel/debug/tracing/trace | grep -c 'input_event:.*type=1.*code=330.*value=1'" 2>/dev/null || echo "0")
    echo "${count//[^0-9]/}"
}

# Get touchscreen IRQ number
find_touch_irq() {
    log "Finding touchscreen IRQ..."

    local irq_line=$(adb shell "cat /proc/interrupts" | \
        grep -iE "touch|fts|sec_ts|synaptics|goodix|atmel" | head -1)

    if [[ -n "$irq_line" ]]; then
        TOUCH_IRQ=$(echo "$irq_line" | awk '{print $1}' | tr -d ':')
        TOUCH_NAME=$(echo "$irq_line" | awk '{print $NF}')
        log "  Found touchscreen IRQ: $TOUCH_IRQ ($TOUCH_NAME)"
    else
        log "  WARNING: Could not identify touchscreen IRQ"
        log "  Will use total interrupt count instead"
        TOUCH_IRQ=""
    fi
}

# Capture interrupt counts
capture_interrupts() {
    local output_file="$1"
    adb shell "cat /proc/interrupts" > "$output_file"
}

# Parse interrupt delta
parse_interrupt_delta() {
    local before_file="$1"
    local after_file="$2"

    if [[ -n "$TOUCH_IRQ" ]]; then
        local before=$(grep "^ *$TOUCH_IRQ:" "$before_file" | awk '{sum=0; for(i=2;i<=NF-2;i++) sum+=$i; print sum}')
        local after=$(grep "^ *$TOUCH_IRQ:" "$after_file" | awk '{sum=0; for(i=2;i<=NF-2;i++) sum+=$i; print sum}')
    else
        local before=$(tail -1 "$before_file" | awk '{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}')
        local after=$(tail -1 "$after_file" | awk '{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}')
    fi

    before=${before:-0}
    after=${after:-0}

    echo $((after - before))
}

# Run a single wakeup test with physical touch
run_wakeup_test() {
    local run_num=$1

    log "Starting wakeup test run $run_num ($NUM_TAPS taps)..."
    log "NOTE: This test requires PHYSICAL touch input on the device screen"

    local irq_before="$LOGS_DIR/irq_before_${run_num}.txt"
    local irq_after="$LOGS_DIR/irq_after_${run_num}.txt"

    # Capture initial state
    capture_interrupts "$irq_before"
    local start_time=$(date +%s)

    # Start ftrace for touch counting
    start_ftrace

    # Wait for user to perform taps
    log ">>> TAP THE SCREEN $NUM_TAPS TIMES <<<"
    log ">>> Starting in 3 seconds... <<<"
    sleep 3

    local current_count=0
    local last_count=0

    while [[ $current_count -lt $NUM_TAPS ]]; do
        sleep 1

        current_count=$(count_live_touches)

        if [[ $current_count -gt $last_count ]]; then
            log ">>> $current_count / $NUM_TAPS taps detected <<<"
            last_count=$current_count
        fi
    done

    log ">>> All $NUM_TAPS taps received! <<<"

    # Capture final state
    stop_ftrace
    local end_time=$(date +%s)
    capture_interrupts "$irq_after"

    # Calculate metrics
    local actual_duration=$((end_time - start_time))
    local irq_delta=$(parse_interrupt_delta "$irq_before" "$irq_after")

    local wakeups_per_sec=0
    if [[ $actual_duration -gt 0 ]]; then
        wakeups_per_sec=$(echo "scale=2; $irq_delta / $actual_duration" | bc)
    fi

    local irqs_per_tap=0
    if [[ $NUM_TAPS -gt 0 ]]; then
        irqs_per_tap=$(echo "scale=2; $irq_delta / $NUM_TAPS" | bc)
    fi

    log "  Run $run_num: interrupts=$irq_delta, wakeups/sec=$wakeups_per_sec, irqs/tap=$irqs_per_tap, duration=${actual_duration}s"

    # Append to results
    echo "$run_num,$NUM_TAPS,$irq_delta,$wakeups_per_sec,$irqs_per_tap,$actual_duration" >> "$LOGS_DIR/wakeup_results.tmp"
}

# Generate final CSV
generate_csv() {
    log "Generating CSV output..."

    echo "run,taps,total_interrupts,wakeups_per_sec,irqs_per_tap,duration_sec" > "$OUTPUT_CSV"

    if [[ -f "$LOGS_DIR/wakeup_results.tmp" ]]; then
        cat "$LOGS_DIR/wakeup_results.tmp" >> "$OUTPUT_CSV"
        rm "$LOGS_DIR/wakeup_results.tmp"
    fi

    log "Results saved to: $OUTPUT_CSV"
}

# Print summary
print_summary() {
    log "=== Wakeup Test Summary ==="

    if [[ -f "$OUTPUT_CSV" ]]; then
        local avg_wakeups=$(tail -n +2 "$OUTPUT_CSV" | cut -d, -f4 | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count; else print "0"}')

        local avg_interrupts=$(tail -n +2 "$OUTPUT_CSV" | cut -d, -f3 | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.0f", sum/count; else print "0"}')

        local avg_irqs_per_tap=$(tail -n +2 "$OUTPUT_CSV" | cut -d, -f5 | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count; else print "0"}')

        log "  Taps per run: $NUM_TAPS"
        log "  Number of runs: $NUM_RUNS"
        log "  Average total interrupts: $avg_interrupts"
        log "  Average wakeups/sec: $avg_wakeups"
        log "  Average IRQs per tap: $avg_irqs_per_tap"
    fi
}

# Main execution
main() {
    log "=========================================="
    log "ESM Wakeup Test - Build: $BUILD_TYPE"
    log "=========================================="

    if [[ "$BUILD_TYPE" == "unknown" ]]; then
        echo "Usage: $0 <baseline|esm>"
        echo "  baseline - Test stock AOSP with epoll"
        echo "  esm      - Test ESM-modified AOSP"
        echo ""
        echo "NOTE: This test requires PHYSICAL touch input on the device screen."
        echo ""
        echo "Environment variables:"
        echo "  NUM_TAPS - Number of taps per run (default: 50)"
        echo "  NUM_RUNS - Number of test runs (default: 5)"
        exit 1
    fi

    # Initialize
    rm -f "$LOGS_DIR/wakeup_results.tmp"

    check_device
    setup_ftrace
    find_touch_irq

    for run in $(seq 1 $NUM_RUNS); do
        run_wakeup_test $run

        # Cool-down between runs
        if [[ $run -lt $NUM_RUNS ]]; then
            log "Cooling down (30 seconds)..."
            sleep 30
        fi
    done

    generate_csv
    print_summary

    log "=========================================="
    log "Wakeup test complete!"
    log "Results: $OUTPUT_CSV"
    log "=========================================="
}

main "$@"
