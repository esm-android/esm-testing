#!/bin/bash
#
# run_syscall_test.sh - Count syscalls during input event processing
#
# Uses kernel ftrace to count epoll_wait/read (baseline) or esm_wait (ESM)
# syscalls during PHYSICAL touch input.
#
# NOTE: Requires PHYSICAL touch input - automated input bypasses the measured path.
#
# Output: CSV file with syscall counts
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
LOGS_DIR="$SCRIPT_DIR/../logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Test configuration - can be overridden via environment
NUM_TAPS=${NUM_TAPS:-50}        # Number of taps to collect
NUM_RUNS=${NUM_RUNS:-3}         # Number of test runs

# Syscall numbers for ARM64
# These may vary by kernel version - verify with: ausyscall --dump | grep -E "epoll|read|esm"
SYSCALL_EPOLL_WAIT=22           # epoll_pwait on ARM64
SYSCALL_READ=63                 # read on ARM64
SYSCALL_EPOLL_CTL=21            # epoll_ctl on ARM64
# ESM syscalls (custom, defined in kernel patches)
SYSCALL_ESM_REGISTER=443
SYSCALL_ESM_WAIT=444
SYSCALL_ESM_CTL=445

# Determine output directory
BUILD_TYPE="${1:-unknown}"
OUTPUT_DIR="$RESULTS_DIR/$BUILD_TYPE"
TRACES_DIR="$OUTPUT_DIR/traces"
mkdir -p "$OUTPUT_DIR" "$TRACES_DIR" "$LOGS_DIR"

OUTPUT_CSV="$OUTPUT_DIR/syscalls.csv"
LOG_FILE="$LOGS_DIR/syscall_test_$TIMESTAMP.log"

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

# Get system_server PID
get_system_server_pid() {
    adb shell "pidof system_server" | tr -d '\r\n'
}

# Setup ftrace for syscall and input event tracing
setup_ftrace() {
    log "Setting up ftrace for syscall tracing..."

    local ss_pid=$(get_system_server_pid)
    log "system_server PID: $ss_pid"

    # Check if raw_syscalls tracepoint exists
    if ! adb shell "test -d /sys/kernel/debug/tracing/events/raw_syscalls" 2>/dev/null; then
        error "raw_syscalls tracepoint not found. Kernel may not support syscall tracing."
    fi

    # Check if input_event tracepoint exists (for counting touches)
    if ! adb shell "test -d /sys/kernel/debug/tracing/events/input/input_event" 2>/dev/null; then
        error "input_event tracepoint not found. Kernel must include input ftrace tracepoint."
    fi

    adb shell "
        # Reset tracing
        echo 0 > /sys/kernel/debug/tracing/tracing_on
        echo > /sys/kernel/debug/tracing/trace
        echo 65536 > /sys/kernel/debug/tracing/buffer_size_kb

        # Enable syscall entry tracing
        echo 1 > /sys/kernel/debug/tracing/events/raw_syscalls/sys_enter/enable

        # Enable input_event to count physical touches
        echo 1 > /sys/kernel/debug/tracing/events/input/input_event/enable

        # Filter by system_server PID if possible (reduces noise)
        # Note: This filters the syscall events, not input events
        echo $ss_pid > /sys/kernel/debug/tracing/set_event_pid 2>/dev/null || true
    " || error "Failed to setup ftrace"

    log "ftrace ready (raw_syscalls + input_event enabled)"
}

# Start ftrace
start_ftrace() {
    log "Starting ftrace..."
    adb shell "
        echo > /sys/kernel/debug/tracing/trace
        echo 1 > /sys/kernel/debug/tracing/tracing_on
    "
}

# Stop ftrace and pull trace
stop_ftrace() {
    local trace_file="$1"

    log "Stopping ftrace..."
    adb shell "echo 0 > /sys/kernel/debug/tracing/tracing_on"

    # Pull trace
    adb shell "cat /sys/kernel/debug/tracing/trace" > "$trace_file" || {
        log "Warning: Could not pull trace"
        return 1
    }

    log "Trace saved: $trace_file"
}

# Disable ftrace
cleanup_ftrace() {
    log "Cleaning up ftrace..."
    adb shell "
        echo 0 > /sys/kernel/debug/tracing/events/raw_syscalls/sys_enter/enable
        echo 0 > /sys/kernel/debug/tracing/events/input/input_event/enable
        echo > /sys/kernel/debug/tracing/set_event_pid 2>/dev/null || true
    " 2>/dev/null || true
}

# Count touches in trace (EV_KEY with BTN_TOUCH or EV_ABS events)
count_touches_in_trace() {
    local trace_file="$1"

    # Count EV_SYN events (type=0, code=0) which mark end of each touch event batch
    # Each physical touch generates one SYN_REPORT
    local syn_count=$(grep -c "input_event:.*type=0.*code=0.*value=0" "$trace_file" 2>/dev/null || echo "0")

    echo "$syn_count"
}

# Wait for N touches, monitoring the trace
wait_for_touches() {
    local target_touches="$1"
    local trace_file="$2"
    local check_interval=2

    log ">>> TAP THE SCREEN $target_touches TIMES <<<"
    log ">>> Starting in 3 seconds... <<<"
    sleep 3

    local current_touches=0
    local last_count=0

    while [[ $current_touches -lt $target_touches ]]; do
        sleep $check_interval

        # Check current touch count from live trace
        current_touches=$(adb shell "cat /sys/kernel/debug/tracing/trace | grep -c 'input_event:.*type=0.*code=0.*value=0'" 2>/dev/null || echo "0")
        current_touches=${current_touches//[^0-9]/}  # Clean non-numeric chars

        if [[ $current_touches -gt $last_count ]]; then
            log ">>> $current_touches / $target_touches touches detected <<<"
            last_count=$current_touches
        fi
    done

    log ">>> All $target_touches touches received! <<<"
}

# Parse syscalls from trace
parse_syscalls() {
    local trace_file="$1"
    local run_num="$2"

    log "Parsing syscalls from trace..."

    # Count syscalls by number
    # Format: sys_enter: NR 63 (...)  for read
    local epoll_wait_count=$(grep -cE "sys_enter: NR $SYSCALL_EPOLL_WAIT " "$trace_file" 2>/dev/null || echo "0")
    local read_count=$(grep -cE "sys_enter: NR $SYSCALL_READ " "$trace_file" 2>/dev/null || echo "0")
    local epoll_ctl_count=$(grep -cE "sys_enter: NR $SYSCALL_EPOLL_CTL " "$trace_file" 2>/dev/null || echo "0")
    local esm_register_count=$(grep -cE "sys_enter: NR $SYSCALL_ESM_REGISTER " "$trace_file" 2>/dev/null || echo "0")
    local esm_wait_count=$(grep -cE "sys_enter: NR $SYSCALL_ESM_WAIT " "$trace_file" 2>/dev/null || echo "0")
    local esm_ctl_count=$(grep -cE "sys_enter: NR $SYSCALL_ESM_CTL " "$trace_file" 2>/dev/null || echo "0")

    # Count actual touches
    local touch_count=$(count_touches_in_trace "$trace_file")

    # Calculate totals
    local epoll_total=$((epoll_wait_count + read_count))
    local esm_total=$((esm_wait_count))

    log "  Touches detected: $touch_count"
    log "  epoll_wait: $epoll_wait_count"
    log "  read: $read_count"
    log "  epoll_ctl: $epoll_ctl_count"
    log "  esm_register: $esm_register_count"
    log "  esm_wait: $esm_wait_count"
    log "  esm_ctl: $esm_ctl_count"

    # Append to results
    echo "$run_num,$touch_count,$epoll_wait_count,$read_count,$epoll_ctl_count,$esm_register_count,$esm_wait_count,$esm_ctl_count" >> "$LOGS_DIR/syscall_results.tmp"
}

# Run a single syscall test
run_syscall_test() {
    local run_num="$1"

    log "Starting syscall test run $run_num ($NUM_TAPS taps)..."
    log "NOTE: This test requires PHYSICAL touch input on the device screen"

    local trace_file="$TRACES_DIR/syscall_trace_run${run_num}.txt"

    start_ftrace

    # Wait for user to perform taps
    wait_for_touches "$NUM_TAPS" "$trace_file"

    stop_ftrace "$trace_file"

    # Parse the trace
    parse_syscalls "$trace_file" "$run_num"

    log "Syscall test run $run_num complete"
}

# Generate final CSV
generate_csv() {
    log "Generating CSV output..."

    echo "run,touches,epoll_wait,read,epoll_ctl,esm_register,esm_wait,esm_ctl" > "$OUTPUT_CSV"

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
        local avg_touches=$(tail -n +2 "$OUTPUT_CSV" | cut -d, -f2 | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.0f", sum/count; else print "0"}')
        local avg_epoll=$(tail -n +2 "$OUTPUT_CSV" | cut -d, -f3 | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.0f", sum/count; else print "0"}')
        local avg_read=$(tail -n +2 "$OUTPUT_CSV" | cut -d, -f4 | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.0f", sum/count; else print "0"}')
        local avg_esm_wait=$(tail -n +2 "$OUTPUT_CSV" | cut -d, -f7 | \
            awk '{sum+=$1; count++} END {if(count>0) printf "%.0f", sum/count; else print "0"}')

        log "  Taps per run: $NUM_TAPS"
        log "  Number of runs: $NUM_RUNS"
        log "  Average touches detected: $avg_touches"
        log "  Average epoll_wait calls: $avg_epoll"
        log "  Average read calls: $avg_read"
        log "  Average esm_wait calls: $avg_esm_wait"

        # Calculate per-touch ratio
        if [[ $avg_touches -gt 0 ]]; then
            if [[ $avg_esm_wait -gt 0 ]]; then
                local ratio=$(echo "scale=2; $avg_esm_wait / $avg_touches" | bc)
                log "  ESM syscalls per touch: $ratio"
            elif [[ $avg_epoll -gt 0 ]]; then
                local epoll_ratio=$(echo "scale=2; ($avg_epoll + $avg_read) / $avg_touches" | bc)
                log "  epoll+read syscalls per touch: $epoll_ratio"
            fi
        fi
    fi
}

# Main execution
main() {
    log "=========================================="
    log "ESM Syscall Test (ftrace) - Build: $BUILD_TYPE"
    log "=========================================="

    if [[ "$BUILD_TYPE" == "unknown" ]]; then
        echo "Usage: $0 <baseline|esm>"
        echo "  baseline - Test stock AOSP with epoll"
        echo "  esm      - Test ESM-modified AOSP"
        echo ""
        echo "NOTE: This test requires PHYSICAL touch input on the device screen."
        echo ""
        echo "Environment variables:"
        echo "  NUM_TAPS  - Number of taps per run (default: 50)"
        echo "  NUM_RUNS  - Number of test runs (default: 3)"
        exit 1
    fi

    # Initialize
    rm -f "$LOGS_DIR/syscall_results.tmp"

    check_device
    setup_ftrace

    for run in $(seq 1 $NUM_RUNS); do
        run_syscall_test $run

        # Brief pause between runs
        if [[ $run -lt $NUM_RUNS ]]; then
            log "Pausing before next run (10 seconds)..."
            sleep 10
        fi
    done

    cleanup_ftrace
    generate_csv
    print_summary

    log "=========================================="
    log "Syscall test complete!"
    log "Traces: $TRACES_DIR"
    log "Results: $OUTPUT_CSV"
    log "=========================================="
}

main "$@"
