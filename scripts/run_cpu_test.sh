#!/bin/bash
#
# run_cpu_test.sh - Measure CPU usage during input interaction
#
# Monitors system_server and total CPU usage during 60-second
# continuous interaction sessions.
#
# Output: CSV file with CPU measurements
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
LOGS_DIR="$SCRIPT_DIR/../logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Test configuration
TEST_DURATION=60    # seconds per test
NUM_RUNS=5          # number of test runs
SAMPLE_INTERVAL=1   # CPU sampling interval

# Determine output directory
BUILD_TYPE="${1:-unknown}"
OUTPUT_DIR="$RESULTS_DIR/$BUILD_TYPE"
mkdir -p "$OUTPUT_DIR" "$LOGS_DIR"

OUTPUT_CSV="$OUTPUT_DIR/cpu.csv"
LOG_FILE="$LOGS_DIR/cpu_test_$TIMESTAMP.log"

log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Get CPU baseline (idle)
measure_baseline() {
    log "Measuring idle CPU baseline..."

    # Wait for system to be truly idle
    sleep 5

    # Take 10 samples of idle CPU
    local samples=()
    for i in $(seq 1 10); do
        # Get total CPU from top
        local cpu=$(adb shell "top -n 1 -b" | head -3 | grep -oP '\d+(?=% cpu)' | head -1)
        samples+=("${cpu:-0}")
        sleep 1
    done

    # Calculate average
    local sum=0
    for s in "${samples[@]}"; do
        sum=$((sum + s))
    done
    IDLE_CPU=$((sum / ${#samples[@]}))

    log "Idle CPU baseline: ${IDLE_CPU}%"
}

# Run a single CPU test
run_cpu_test() {
    local run_num=$1
    local output_file="$LOGS_DIR/cpu_run_${run_num}.txt"

    log "Starting CPU test run $run_num ($TEST_DURATION seconds)..."

    # Start top monitoring in background
    adb shell "top -d $SAMPLE_INTERVAL -n $((TEST_DURATION + 5)) -b" > "$output_file" &
    TOP_PID=$!

    # Give top time to start
    sleep 2

    # Start automated interaction
    log "  Generating input events..."
    python3 "$SCRIPT_DIR/generate_input.py" mixed $TEST_DURATION &
    INPUT_PID=$!

    # Wait for interaction to complete
    wait $INPUT_PID 2>/dev/null || true

    # Wait a bit more for final CPU readings
    sleep 3

    # Stop top
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

    # Extract system_server CPU samples
    local ss_samples=$(grep "system_server" "$input_file" | awk '{print $9}' | grep -oP '[\d.]+' || echo "")

    # Extract total CPU samples (from header lines)
    local total_samples=$(grep -oP '\d+(?=% cpu)' "$input_file" || echo "")

    # Calculate averages
    local ss_count=0
    local ss_sum=0
    for val in $ss_samples; do
        ss_sum=$(echo "$ss_sum + $val" | bc)
        ss_count=$((ss_count + 1))
    done

    local total_count=0
    local total_sum=0
    for val in $total_samples; do
        total_sum=$((total_sum + val))
        total_count=$((total_count + 1))
    done

    # Calculate averages
    if [[ $ss_count -gt 0 ]]; then
        SS_CPU=$(echo "scale=2; $ss_sum / $ss_count" | bc)
    else
        SS_CPU="0"
    fi

    if [[ $total_count -gt 0 ]]; then
        TOTAL_CPU=$((total_sum / total_count))
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
        # Calculate system_server average
        local ss_avg=$(tail -n +2 "$OUTPUT_CSV" | cut -d, -f2 | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count; else print "0"}')

        # Calculate total CPU average
        local total_avg=$(tail -n +2 "$OUTPUT_CSV" | cut -d, -f3 | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count; else print "0"}')

        log "  Idle baseline: ${IDLE_CPU}%"
        log "  system_server average: ${ss_avg}%"
        log "  Total CPU average: ${total_avg}%"
        log "  Number of runs: $NUM_RUNS"
    fi
}

# Main execution
main() {
    log "=========================================="
    log "ESM CPU Test - Build: $BUILD_TYPE"
    log "=========================================="

    if [[ "$BUILD_TYPE" == "unknown" ]]; then
        echo "Usage: $0 <baseline|esm>"
        exit 1
    fi

    # Initialize results file
    rm -f "$LOGS_DIR/cpu_results.tmp"

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
