#!/bin/bash
#
# run_cpu_test.sh - Measure CPU usage during input interaction
#
# Monitors system_server and total CPU usage during physical touch
# interaction sessions.
#
# NOTE: Requires PHYSICAL touch input - automated input bypasses the ESM path.
#
# Output: CSV file with CPU measurements
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
LOGS_DIR="$SCRIPT_DIR/../logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Test configuration - can be overridden via environment
NUM_TAPS=${NUM_TAPS:-50}          # Number of taps per test run
NUM_RUNS=${NUM_RUNS:-5}           # Number of test runs
SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-1} # CPU sampling interval

# Determine output directory
BUILD_TYPE="${1:-unknown}"
OUTPUT_DIR="$RESULTS_DIR/$BUILD_TYPE"
mkdir -p "$OUTPUT_DIR" "$LOGS_DIR"

OUTPUT_CSV="$OUTPUT_DIR/cpu.csv"
LOG_FILE="$LOGS_DIR/cpu_test_$TIMESTAMP.log"

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

# Get CPU baseline (idle)
measure_baseline() {
    log "Measuring idle CPU baseline..."

    sleep 5

    local samples=()
    for i in $(seq 1 10); do
        local cpu=$(adb shell "top -n 1 -b" | head -3 | grep -oP '\d+(?=% cpu)' | head -1)
        samples+=("${cpu:-0}")
        sleep 1
    done

    local sum=0
    for s in "${samples[@]}"; do
        sum=$((sum + s))
    done
    IDLE_CPU=$((sum / ${#samples[@]}))

    log "Idle CPU baseline: ${IDLE_CPU}%"
}

# Run a single CPU test with physical touch
run_cpu_test() {
    local run_num=$1
    local output_file="$LOGS_DIR/cpu_run_${run_num}.txt"
    local cpu_samples_file="$LOGS_DIR/cpu_samples_${run_num}.txt"

    log "Starting CPU test run $run_num ($NUM_TAPS taps)..."
    log "NOTE: This test requires PHYSICAL touch input on the device screen"

    # Start ftrace for touch counting
    start_ftrace

    # Start top monitoring in background
    adb shell "top -d $SAMPLE_INTERVAL -n 300 -b" > "$output_file" &
    TOP_PID=$!

    sleep 2

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

    # Stop monitoring
    sleep 2
    stop_ftrace
    kill $TOP_PID 2>/dev/null || true
    wait $TOP_PID 2>/dev/null || true

    log "  CPU test run $run_num complete"

    # Parse results
    parse_cpu_results "$output_file" "$run_num"
}

# Parse top output and extract CPU values
parse_cpu_results() {
    local input_file="$1"
    local run_num="$2"

    # Extract system_server CPU samples (column 9 is %CPU)
    local ss_samples=$(grep "system_server" "$input_file" | awk '{print $9}' | grep -oE '[0-9.]+' || echo "")

    # Extract total CPU usage from header lines
    # Format: "800%cpu  71%user   7%nice  71%sys 643%idle ..."
    # Total CPU = (total_capacity - idle) / total_capacity * 100
    local total_cpu_samples=""
    while IFS= read -r line; do
        # Extract total capacity (e.g., 800 from "800%cpu") and idle (e.g., 643 from "643%idle")
        local capacity=$(echo "$line" | grep -oE '[0-9]+%cpu' | grep -oE '[0-9]+')
        local idle=$(echo "$line" | grep -oE '[0-9]+%idle' | grep -oE '[0-9]+')
        if [[ -n "$capacity" && -n "$idle" && "$capacity" -gt 0 ]]; then
            # Calculate usage percentage: (capacity - idle) / capacity * 100
            local usage=$(echo "scale=1; ($capacity - $idle) * 100 / $capacity" | bc)
            total_cpu_samples="$total_cpu_samples $usage"
        fi
    done < <(grep '%cpu.*%idle' "$input_file")

    # Calculate averages
    local ss_count=0
    local ss_sum=0
    for val in $ss_samples; do
        ss_sum=$(echo "$ss_sum + $val" | bc)
        ss_count=$((ss_count + 1))
    done

    local total_count=0
    local total_sum=0
    for val in $total_cpu_samples; do
        total_sum=$(echo "$total_sum + $val" | bc)
        total_count=$((total_count + 1))
    done

    # Calculate averages
    if [[ $ss_count -gt 0 ]]; then
        SS_CPU=$(echo "scale=2; $ss_sum / $ss_count" | bc)
    else
        SS_CPU="0"
    fi

    if [[ $total_count -gt 0 ]]; then
        TOTAL_CPU=$(echo "scale=1; $total_sum / $total_count" | bc)
    else
        TOTAL_CPU="0"
    fi

    log "  Run $run_num: system_server=${SS_CPU}%, total=${TOTAL_CPU}%"

    # Append to results
    echo "$run_num,$SS_CPU,$TOTAL_CPU" >> "$LOGS_DIR/cpu_results.tmp"
}

# Generate final CSV
generate_csv() {
    log "Generating CSV output..."

    echo "run,system_server_cpu,total_cpu" > "$OUTPUT_CSV"

    if [[ -f "$LOGS_DIR/cpu_results.tmp" ]]; then
        cat "$LOGS_DIR/cpu_results.tmp" >> "$OUTPUT_CSV"
        rm "$LOGS_DIR/cpu_results.tmp"
    fi

    log "Results saved to: $OUTPUT_CSV"
}

# Calculate and print statistics
print_summary() {
    log "=== CPU Test Summary ==="

    if [[ -f "$OUTPUT_CSV" ]]; then
        local ss_avg=$(tail -n +2 "$OUTPUT_CSV" | cut -d, -f2 | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count; else print "0"}')

        local total_avg=$(tail -n +2 "$OUTPUT_CSV" | cut -d, -f3 | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count; else print "0"}')

        log "  Idle baseline: ${IDLE_CPU}%"
        log "  system_server average: ${ss_avg}%"
        log "  Total CPU average: ${total_avg}%"
        log "  Number of runs: $NUM_RUNS"
        log "  Taps per run: $NUM_TAPS"
    fi
}

# Main execution
main() {
    log "=========================================="
    log "ESM CPU Test - Build: $BUILD_TYPE"
    log "=========================================="

    if [[ "$BUILD_TYPE" == "unknown" ]]; then
        echo "Usage: $0 <baseline|esm>"
        echo "  baseline - Test stock AOSP with epoll"
        echo "  esm      - Test ESM-modified AOSP"
        echo ""
        echo "NOTE: This test requires PHYSICAL touch input on the device screen."
        echo ""
        echo "Environment variables:"
        echo "  NUM_TAPS        - Number of taps per run (default: 50)"
        echo "  NUM_RUNS        - Number of test runs (default: 5)"
        echo "  SAMPLE_INTERVAL - CPU sampling interval in seconds (default: 1)"
        exit 1
    fi

    # Initialize results file
    rm -f "$LOGS_DIR/cpu_results.tmp"

    check_device
    setup_ftrace
    measure_baseline

    for run in $(seq 1 $NUM_RUNS); do
        run_cpu_test $run

        # Cool-down between runs
        if [[ $run -lt $NUM_RUNS ]]; then
            log "Cooling down (30 seconds)..."
            sleep 30
        fi
    done

    generate_csv
    print_summary

    log "=========================================="
    log "CPU test complete!"
    log "Results: $OUTPUT_CSV"
    log "=========================================="
}

main "$@"
