#!/bin/bash
#
# run_power_test.sh - Measure power consumption in idle and active states
#
# Tests two scenarios:
#   1. Idle: Screen on, no interaction
#   2. Active: Continuous random tapping
#
# Measures:
#   - Battery drain percentage
#   - Current draw (mA) if available
#   - Wakeups per second
#
# Output: CSV file with power measurements
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
LOGS_DIR="$SCRIPT_DIR/../logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Test configuration
IDLE_DURATION=${IDLE_DURATION:-300}      # 5 minutes idle test
ACTIVE_DURATION=${ACTIVE_DURATION:-300}  # 5 minutes active test
TAP_INTERVAL=${TAP_INTERVAL:-0.1}        # 100ms between taps (10 taps/sec)
NUM_RUNS=${NUM_RUNS:-3}                  # Number of test runs per scenario

# Screen dimensions (will be auto-detected)
SCREEN_WIDTH=1080
SCREEN_HEIGHT=2340

# Determine output directory based on build type
BUILD_TYPE="${1:-unknown}"
OUTPUT_DIR="$RESULTS_DIR/$BUILD_TYPE"
mkdir -p "$OUTPUT_DIR" "$LOGS_DIR"

OUTPUT_CSV="$OUTPUT_DIR/power.csv"
LOG_FILE="$LOGS_DIR/power_test_$TIMESTAMP.log"

log() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    log "ERROR: $1"
    exit 1
}

# Check root access
check_root() {
    log "Checking root access..."
    ROOT_CHECK=$(adb shell "id" | grep -c "uid=0" || echo "0")
    if [[ "$ROOT_CHECK" -eq 0 ]]; then
        log "Attempting to get root..."
        adb root
        sleep 2
    fi
}

# Get screen dimensions
detect_screen_size() {
    log "Detecting screen size..."
    local size=$(adb shell wm size | grep -oE '[0-9]+x[0-9]+' | tail -1)
    if [[ -n "$size" ]]; then
        SCREEN_WIDTH=$(echo "$size" | cut -dx -f1)
        SCREEN_HEIGHT=$(echo "$size" | cut -dx -f2)
        log "Screen size: ${SCREEN_WIDTH}x${SCREEN_HEIGHT}"
    else
        log "Could not detect screen size, using defaults: ${SCREEN_WIDTH}x${SCREEN_HEIGHT}"
    fi
}

# Ensure screen stays on during tests
setup_screen() {
    log "Configuring screen settings..."
    # Disable screen timeout
    adb shell settings put system screen_off_timeout 1800000  # 30 minutes
    # Set brightness to 50%
    adb shell settings put system screen_brightness 128
    # Disable adaptive brightness
    adb shell settings put system screen_brightness_mode 0
    # Wake up and unlock screen
    adb shell input keyevent KEYCODE_WAKEUP
    sleep 1
    adb shell input keyevent KEYCODE_MENU
    sleep 1
}

# Reset battery stats
reset_battery_stats() {
    log "Resetting battery statistics..."
    adb shell dumpsys batterystats --reset > /dev/null 2>&1
    sleep 2
}

# Get current battery level
get_battery_level() {
    adb shell dumpsys battery | grep "level:" | awk '{print $2}'
}

# Get battery current (mA) if available
get_battery_current() {
    # Try different paths for current measurement
    local current=""

    # Method 1: battery service
    current=$(adb shell "cat /sys/class/power_supply/battery/current_now 2>/dev/null" | tr -d '\r\n')
    if [[ -n "$current" && "$current" != "0" ]]; then
        # Convert from uA to mA if needed (values > 10000 are likely in uA)
        if [[ "$current" -gt 10000 || "$current" -lt -10000 ]]; then
            current=$((current / 1000))
        fi
        echo "$current"
        return
    fi

    # Method 2: dumpsys battery
    current=$(adb shell dumpsys battery | grep "current" | head -1 | awk '{print $2}' | tr -d '\r\n')
    if [[ -n "$current" ]]; then
        echo "$current"
        return
    fi

    echo "N/A"
}

# Get wakeup count from /proc/interrupts
get_wakeup_count() {
    # Sum all interrupt counts
    adb shell "cat /proc/interrupts" | awk 'NR>1 {sum=0; for(i=2;i<=NF-2;i++) sum+=$i; total+=sum} END {print total}'
}

# Generate random tap position
random_tap() {
    # Generate random x,y within screen bounds (with margin)
    local margin=50
    local x=$((RANDOM % (SCREEN_WIDTH - 2*margin) + margin))
    local y=$((RANDOM % (SCREEN_HEIGHT - 2*margin) + margin))
    adb shell "input tap $x $y" &
}

# Run idle power test
test_idle_power() {
    local run_num="$1"
    log "Running idle power test (run $run_num, ${IDLE_DURATION}s)..."

    # Reset stats
    reset_battery_stats

    # Record initial state
    local start_level=$(get_battery_level)
    local start_current=$(get_battery_current)
    local start_wakeups=$(get_wakeup_count)
    local start_time=$(date +%s)

    log "  Initial: battery=${start_level}%, current=${start_current}mA"

    # Wait for idle duration (screen on, no interaction)
    log "  Waiting ${IDLE_DURATION} seconds (idle)..."
    sleep "$IDLE_DURATION"

    # Record final state
    local end_level=$(get_battery_level)
    local end_current=$(get_battery_current)
    local end_wakeups=$(get_wakeup_count)
    local end_time=$(date +%s)

    # Calculate metrics
    local duration=$((end_time - start_time))
    local battery_drain=$((start_level - end_level))
    local wakeup_delta=$((end_wakeups - start_wakeups))
    local wakeups_per_sec=$(echo "scale=2; $wakeup_delta / $duration" | bc)

    log "  Final: battery=${end_level}%, drain=${battery_drain}%"
    log "  Wakeups: ${wakeup_delta} total, ${wakeups_per_sec}/sec"

    # Output result
    echo "idle,$run_num,$duration,$battery_drain,$start_current,$end_current,$wakeups_per_sec"
}

# Run active power test (random tapping)
test_active_power() {
    local run_num="$1"
    log "Running active power test (run $run_num, ${ACTIVE_DURATION}s)..."

    # Reset stats
    reset_battery_stats

    # Record initial state
    local start_level=$(get_battery_level)
    local start_current=$(get_battery_current)
    local start_wakeups=$(get_wakeup_count)
    local start_time=$(date +%s)

    log "  Initial: battery=${start_level}%, current=${start_current}mA"

    # Generate continuous random taps for the duration
    log "  Generating random taps for ${ACTIVE_DURATION} seconds..."
    local tap_count=0
    local end_target=$((start_time + ACTIVE_DURATION))

    while [[ $(date +%s) -lt $end_target ]]; do
        random_tap
        tap_count=$((tap_count + 1))
        sleep "$TAP_INTERVAL"
    done

    # Wait for any pending taps to complete
    wait 2>/dev/null || true
    sleep 1

    # Record final state
    local end_level=$(get_battery_level)
    local end_current=$(get_battery_current)
    local end_wakeups=$(get_wakeup_count)
    local end_time=$(date +%s)

    # Calculate metrics
    local duration=$((end_time - start_time))
    local battery_drain=$((start_level - end_level))
    local wakeup_delta=$((end_wakeups - start_wakeups))
    local wakeups_per_sec=$(echo "scale=2; $wakeup_delta / $duration" | bc)
    local taps_per_sec=$(echo "scale=2; $tap_count / $duration" | bc)

    log "  Final: battery=${end_level}%, drain=${battery_drain}%"
    log "  Taps: ${tap_count} total, ${taps_per_sec}/sec"
    log "  Wakeups: ${wakeup_delta} total, ${wakeups_per_sec}/sec"

    # Output result
    echo "active,$run_num,$duration,$battery_drain,$start_current,$end_current,$wakeups_per_sec,$tap_count"
}

# Generate CSV output
generate_csv() {
    log "Generating CSV output..."

    # Create header
    echo "scenario,run,duration_sec,battery_drain_pct,start_current_ma,end_current_ma,wakeups_per_sec,tap_count" > "$OUTPUT_CSV"

    # Append results
    cat "$LOGS_DIR/power_results.tmp" >> "$OUTPUT_CSV" 2>/dev/null || true

    # Cleanup
    rm -f "$LOGS_DIR/power_results.tmp"

    log "Results saved to: $OUTPUT_CSV"
}

# Print summary
print_summary() {
    log "=== Power Test Summary ==="

    if [[ -f "$OUTPUT_CSV" ]]; then
        # Calculate averages for each scenario
        for scenario in "idle" "active"; do
            local drain_avg=$(grep "^$scenario," "$OUTPUT_CSV" | cut -d, -f4 | awk '{sum+=$1; n++} END {if(n>0) printf "%.2f", sum/n; else print "N/A"}')
            local wakeups_avg=$(grep "^$scenario," "$OUTPUT_CSV" | cut -d, -f7 | awk '{sum+=$1; n++} END {if(n>0) printf "%.2f", sum/n; else print "N/A"}')
            log "  $scenario: avg_drain=${drain_avg}%, avg_wakeups=${wakeups_avg}/sec"
        done
    fi
}

# Main execution
main() {
    log "=========================================="
    log "ESM Power Test - Build: $BUILD_TYPE"
    log "=========================================="

    if [[ "$BUILD_TYPE" == "unknown" ]]; then
        echo "Usage: $0 <baseline|esm>"
        echo "  baseline - Test stock AOSP with epoll"
        echo "  esm      - Test ESM-modified AOSP"
        echo ""
        echo "Environment variables:"
        echo "  IDLE_DURATION   - Idle test duration in seconds (default: 300)"
        echo "  ACTIVE_DURATION - Active test duration in seconds (default: 300)"
        echo "  TAP_INTERVAL    - Seconds between taps (default: 0.1)"
        echo "  NUM_RUNS        - Number of test runs per scenario (default: 3)"
        exit 1
    fi

    check_root
    detect_screen_size
    setup_screen

    # Clear previous results
    rm -f "$LOGS_DIR/power_results.tmp"

    # Run idle tests
    log "Starting idle power tests ($NUM_RUNS runs)..."
    for run in $(seq 1 $NUM_RUNS); do
        result=$(test_idle_power "$run")
        echo "$result" >> "$LOGS_DIR/power_results.tmp"

        # Cool down between runs
        if [[ $run -lt $NUM_RUNS ]]; then
            log "Cooling down (60s)..."
            sleep 60
        fi
    done

    # Cool down between test types
    log "Cooling down before active tests (120s)..."
    sleep 120

    # Run active tests
    log "Starting active power tests ($NUM_RUNS runs)..."
    for run in $(seq 1 $NUM_RUNS); do
        result=$(test_active_power "$run")
        echo "$result" >> "$LOGS_DIR/power_results.tmp"

        # Cool down between runs
        if [[ $run -lt $NUM_RUNS ]]; then
            log "Cooling down (60s)..."
            sleep 60
        fi
    done

    generate_csv
    print_summary

    log "=========================================="
    log "Power test complete!"
    log "Results: $OUTPUT_CSV"
    log "=========================================="
}

main "$@"
