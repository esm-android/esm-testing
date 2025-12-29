#!/bin/bash
#
# run_wakeup_test.sh - Measure CPU wakeups during input interaction
#
# Tracks wakeup count from /proc/interrupts and batterystats
# during extended interaction sessions.
#
# Output: CSV file with wakeup measurements
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
LOGS_DIR="$SCRIPT_DIR/../logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Test configuration - can be overridden via environment
TEST_DURATION=${TEST_DURATION:-120}   # 2 minutes per test (sufficient for interrupt counting)
NUM_RUNS=${NUM_RUNS:-10}              # Number of test runs (increased for statistical significance)

# Determine output directory
BUILD_TYPE="${1:-unknown}"
OUTPUT_DIR="$RESULTS_DIR/$BUILD_TYPE"
mkdir -p "$OUTPUT_DIR" "$LOGS_DIR"

OUTPUT_CSV="$OUTPUT_DIR/wakeups.csv"
LOG_FILE="$LOGS_DIR/wakeup_test_$TIMESTAMP.log"

log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Get touchscreen IRQ number
find_touch_irq() {
    log "Finding touchscreen IRQ..."

    # Common touchscreen controller names
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
        # Get specific touchscreen IRQ count
        local before=$(grep "^ *$TOUCH_IRQ:" "$before_file" | awk '{sum=0; for(i=2;i<=NF-2;i++) sum+=$i; print sum}')
        local after=$(grep "^ *$TOUCH_IRQ:" "$after_file" | awk '{sum=0; for(i=2;i<=NF-2;i++) sum+=$i; print sum}')
    else
        # Fall back to total interrupts (less accurate)
        local before=$(tail -1 "$before_file" | awk '{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}')
        local after=$(tail -1 "$after_file" | awk '{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}')
    fi

    before=${before:-0}
    after=${after:-0}

    echo $((after - before))
}

# Reset batterystats
reset_batterystats() {
    log "Resetting batterystats..."
    adb shell "dumpsys batterystats --reset" >/dev/null 2>&1
}

# Capture batterystats wakeups
capture_batterystats() {
    local output_file="$1"
    adb shell "dumpsys batterystats" > "$output_file"
}

# Parse wakeups from batterystats
parse_wakeups() {
    local stats_file="$1"

    # Look for wakeup count in batterystats output
    # Format varies by Android version
    local wakeups=$(grep -oP 'Wakeup reason.*?(\d+)' "$stats_file" | \
        grep -oP '\d+' | awk '{sum+=$1} END {print sum}' || echo "0")

    # Alternative: look for "Total wakeups"
    if [[ "$wakeups" == "0" ]]; then
        wakeups=$(grep -i "total.*wakeup" "$stats_file" | grep -oP '\d+' | head -1 || echo "0")
    fi

    echo "${wakeups:-0}"
}

# Run a single wakeup test
run_wakeup_test() {
    local run_num=$1

    log "Starting wakeup test run $run_num ($TEST_DURATION seconds)..."

    # Capture initial state
    local irq_before="$LOGS_DIR/irq_before_${run_num}.txt"
    local irq_after="$LOGS_DIR/irq_after_${run_num}.txt"
    local stats_before="$LOGS_DIR/stats_before_${run_num}.txt"
    local stats_after="$LOGS_DIR/stats_after_${run_num}.txt"

    reset_batterystats
    capture_interrupts "$irq_before"
    capture_batterystats "$stats_before"

    local start_time=$(date +%s)

    # Start interaction in background (seeded random for reproducibility)
    log "  Generating mixed input events..."
    python3 "$SCRIPT_DIR/generate_input.py" mixed $TEST_DURATION &
    INPUT_PID=$!

    # Wait for test duration
    wait $INPUT_PID 2>/dev/null || true

    local end_time=$(date +%s)
    local actual_duration=$((end_time - start_time))

    # Capture final state
    capture_interrupts "$irq_after"
    capture_batterystats "$stats_after"

    # Calculate metrics
    local irq_delta=$(parse_interrupt_delta "$irq_before" "$irq_after")
    local wakeups=$(parse_wakeups "$stats_after")

    # Calculate wakeups per second
    local wakeups_per_sec=0
    if [[ $actual_duration -gt 0 ]]; then
        wakeups_per_sec=$(echo "scale=2; $irq_delta / $actual_duration" | bc)
    fi

    log "  Run $run_num: interrupts=$irq_delta, wakeups/sec=$wakeups_per_sec, duration=${actual_duration}s"

    # Append to results
    echo "$run_num,$irq_delta,$wakeups_per_sec,$actual_duration" >> "$LOGS_DIR/wakeup_results.tmp"
}

# Generate final CSV
generate_csv() {
    log "Generating CSV output..."

    echo "run,total_interrupts,wakeups_per_sec,duration_sec" > "$OUTPUT_CSV"

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
        local avg_wakeups=$(tail -n +2 "$OUTPUT_CSV" | cut -d, -f3 | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count; else print "0"}')

        local avg_interrupts=$(tail -n +2 "$OUTPUT_CSV" | cut -d, -f2 | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.0f", sum/count; else print "0"}')

        log "  Test duration: ${TEST_DURATION}s per run"
        log "  Number of runs: $NUM_RUNS"
        log "  Average total interrupts: $avg_interrupts"
        log "  Average wakeups/sec: $avg_wakeups"
    fi
}

# Main execution
main() {
    log "=========================================="
    log "ESM Wakeup Test - Build: $BUILD_TYPE"
    log "=========================================="

    if [[ "$BUILD_TYPE" == "unknown" ]]; then
        echo "Usage: $0 <baseline|esm>"
        exit 1
    fi

    # Initialize
    rm -f "$LOGS_DIR/wakeup_results.tmp"

    find_touch_irq

    for run in $(seq 1 $NUM_RUNS); do
        run_wakeup_test $run

        # Cool-down between runs
        if [[ $run -lt $NUM_RUNS ]]; then
            log "Cooling down (60 seconds)..."
            sleep 60
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
