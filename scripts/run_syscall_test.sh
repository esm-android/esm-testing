#!/bin/bash
#
# run_syscall_test.sh - Count syscalls during input event processing
#
# Uses strace to count epoll_wait/read (baseline) or esm_wait (ESM)
# syscalls while processing exactly 100 input events.
#
# Output: CSV file with syscall counts
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
LOGS_DIR="$SCRIPT_DIR/../logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Test configuration
NUM_EVENTS=100      # Events per test
NUM_RUNS=10         # Number of test runs
EVENT_DELAY=50      # ms between events

# Determine output directory
BUILD_TYPE="${1:-unknown}"
OUTPUT_DIR="$RESULTS_DIR/$BUILD_TYPE"
mkdir -p "$OUTPUT_DIR" "$LOGS_DIR"

OUTPUT_CSV="$OUTPUT_DIR/syscalls.csv"
LOG_FILE="$LOGS_DIR/syscall_test_$TIMESTAMP.log"

log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Find system_server PID
get_system_server_pid() {
    adb shell "pidof system_server"
}

# Check if strace is available
check_strace() {
    log "Checking for strace..."

    if ! adb shell "which strace" >/dev/null 2>&1; then
        log "WARNING: strace not found on device"
        log "For userdebug builds, strace should be available"
        log "Attempting to use /system/bin/strace..."
    fi
}

# Run strace on system_server
run_strace_test() {
    local run_num=$1
    local strace_output="$LOGS_DIR/strace_run_${run_num}.txt"

    log "Starting syscall test run $run_num..."

    # Get system_server PID
    local ss_pid=$(get_system_server_pid)
    if [[ -z "$ss_pid" ]]; then
        log "ERROR: Could not find system_server PID"
        return 1
    fi
    log "  system_server PID: $ss_pid"

    # Start strace in background
    # -c: count syscalls
    # -f: follow forks/threads
    # -e: filter specific syscalls
    adb shell "strace -c -f -p $ss_pid \
        -e epoll_wait,epoll_ctl,read,write,esm_register,esm_wait,esm_ctl \
        2>&1" > "$strace_output" &
    STRACE_PID=$!

    # Give strace time to attach
    sleep 2

    log "  Generating $NUM_EVENTS input events..."

    # Generate exactly 100 taps
    for i in $(seq 1 $NUM_EVENTS); do
        adb shell "input tap 540 1200"
        # Small delay to ensure events are processed
        sleep 0.$(printf "%03d" $EVENT_DELAY)

        # Progress indicator
        if [[ $((i % 25)) -eq 0 ]]; then
            log "    Generated $i/$NUM_EVENTS events"
        fi
    done

    # Wait for event processing to complete
    sleep 2

    # Stop strace (send interrupt to device strace)
    # This is tricky - we need to interrupt strace on the device
    adb shell "pkill -INT strace" 2>/dev/null || true

    # Wait for local adb shell to finish
    sleep 2
    kill $STRACE_PID 2>/dev/null || true
    wait $STRACE_PID 2>/dev/null || true

    log "  Syscall test run $run_num complete"

    # Parse strace output
    parse_strace_output "$strace_output" "$run_num"
}

# Alternative: Use /proc/[pid]/syscall counting
run_proc_test() {
    local run_num=$1

    log "Starting syscall test run $run_num (proc method)..."

    # Get system_server PID
    local ss_pid=$(get_system_server_pid)

    # Capture syscall stats before
    local before_file="$LOGS_DIR/proc_before_${run_num}.txt"
    adb shell "cat /proc/$ss_pid/io" > "$before_file" 2>/dev/null || true

    # Generate events
    log "  Generating $NUM_EVENTS input events..."
    for i in $(seq 1 $NUM_EVENTS); do
        adb shell "input tap 540 1200"
        sleep 0.05
    done

    # Wait for processing
    sleep 2

    # Capture syscall stats after
    local after_file="$LOGS_DIR/proc_after_${run_num}.txt"
    adb shell "cat /proc/$ss_pid/io" > "$after_file" 2>/dev/null || true

    # Calculate delta (rough estimate based on read/write syscalls)
    local before_syscalls=$(grep "syscr:" "$before_file" 2>/dev/null | awk '{print $2}' || echo "0")
    local after_syscalls=$(grep "syscr:" "$after_file" 2>/dev/null | awk '{print $2}' || echo "0")

    local delta=$((after_syscalls - before_syscalls))
    log "  Run $run_num: ~$delta syscalls (read syscalls only)"

    echo "$run_num,$delta,0,0,0" >> "$LOGS_DIR/syscall_results.tmp"
}

# Parse strace -c output
parse_strace_output() {
    local input_file="$1"
    local run_num="$2"

    # strace -c output format:
    # % time     seconds  usecs/call     calls    errors syscall
    # ------ ----------- ----------- --------- --------- ----------------
    #  45.00    0.123456          12     10000           epoll_wait

    local epoll_wait=0
    local read_calls=0
    local esm_wait=0
    local esm_register=0

    # Parse syscall counts from strace output
    if [[ -f "$input_file" ]]; then
        epoll_wait=$(grep -oP '\d+(?=\s+\d*\s+epoll_wait)' "$input_file" | head -1 || echo "0")
        read_calls=$(grep -oP '\d+(?=\s+\d*\s+read$)' "$input_file" | head -1 || echo "0")
        esm_wait=$(grep -oP '\d+(?=\s+\d*\s+esm_wait)' "$input_file" | head -1 || echo "0")
        esm_register=$(grep -oP '\d+(?=\s+\d*\s+esm_register)' "$input_file" | head -1 || echo "0")
    fi

    # Default to 0 if parsing failed
    epoll_wait=${epoll_wait:-0}
    read_calls=${read_calls:-0}
    esm_wait=${esm_wait:-0}
    esm_register=${esm_register:-0}

    local total=$((epoll_wait + read_calls + esm_wait))

    log "  Run $run_num: epoll_wait=$epoll_wait, read=$read_calls, esm_wait=$esm_wait, total=$total"

    # Append to results
    echo "$run_num,$epoll_wait,$read_calls,$esm_wait,$total" >> "$LOGS_DIR/syscall_results.tmp"
}

# Generate final CSV
generate_csv() {
    log "Generating CSV output..."

    echo "run,epoll_wait,read,esm_wait,total" > "$OUTPUT_CSV"

    if [[ -f "$LOGS_DIR/syscall_results.tmp" ]]; then
        cat "$LOGS_DIR/syscall_results.tmp" >> "$OUTPUT_CSV"
        rm "$LOGS_DIR/syscall_results.tmp"
    fi

    log "Results saved to: $OUTPUT_CSV"
}

# Print summary
print_summary() {
    log "=== Syscall Test Summary ==="

    if [[ -f "$OUTPUT_CSV" ]]; then
        # Calculate averages
        local avg_epoll=$(tail -n +2 "$OUTPUT_CSV" | cut -d, -f2 | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.0f", sum/count; else print "0"}')
        local avg_read=$(tail -n +2 "$OUTPUT_CSV" | cut -d, -f3 | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.0f", sum/count; else print "0"}')
        local avg_esm=$(tail -n +2 "$OUTPUT_CSV" | cut -d, -f4 | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.0f", sum/count; else print "0"}')
        local avg_total=$(tail -n +2 "$OUTPUT_CSV" | cut -d, -f5 | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.0f", sum/count; else print "0"}')

        log "  Events per test: $NUM_EVENTS"
        log "  Number of runs: $NUM_RUNS"
        log "  Average epoll_wait: $avg_epoll"
        log "  Average read: $avg_read"
        log "  Average esm_wait: $avg_esm"
        log "  Average total: $avg_total"

        # Calculate per-event ratio
        if [[ $avg_total -gt 0 ]]; then
            local ratio=$(echo "scale=2; $avg_total / $NUM_EVENTS" | bc)
            log "  Syscalls per event: $ratio"
        fi
    fi
}

# Main execution
main() {
    log "=========================================="
    log "ESM Syscall Test - Build: $BUILD_TYPE"
    log "=========================================="

    if [[ "$BUILD_TYPE" == "unknown" ]]; then
        echo "Usage: $0 <baseline|esm>"
        exit 1
    fi

    # Initialize results
    rm -f "$LOGS_DIR/syscall_results.tmp"

    check_strace

    for run in $(seq 1 $NUM_RUNS); do
        # Try strace method first, fall back to proc method
        run_strace_test $run || run_proc_test $run

        # Brief pause between runs
        sleep 5
    done

    generate_csv
    print_summary

    log "=========================================="
    log "Syscall test complete!"
    log "Results: $OUTPUT_CSV"
    log "=========================================="
}

main "$@"
