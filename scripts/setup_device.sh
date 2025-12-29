#!/bin/bash
#
# setup_device.sh - Prepare Pixel 5 for ESM performance testing
#
# This script configures the device to a known baseline state for reproducible testing.
# Must be run before each test session.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/../logs"
mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_DIR/setup.log"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

# Check ADB connection
check_device() {
    log "Checking device connection..."
    if ! adb devices | grep -q "device$"; then
        error "No device connected. Please connect Pixel 5 via USB and enable USB debugging."
    fi

    DEVICE=$(adb shell getprop ro.product.device 2>/dev/null)
    log "Connected device: $DEVICE"

    if [[ "$DEVICE" != "redfin" ]]; then
        log "WARNING: Expected Pixel 5 (redfin), got $DEVICE"
    fi
}

# Enable root access (requires userdebug build)
enable_root() {
    log "Enabling ADB root access..."
    adb root 2>/dev/null || log "Note: Could not get root (may already be root or user build)"
    sleep 2
}

# Check if using ADB over WiFi
is_adb_wifi() {
    # Check if current ADB connection is over TCP (WiFi)
    # Traditional WiFi: IP:port (e.g., 192.168.1.100:5555)
    # Android 11+ wireless debugging: adb-*._adb-tls-connect._tcp
    # USB connections show as device serial (e.g., FA6A10302029)
    local serial=$(adb get-serialno 2>/dev/null)
    if [[ "$serial" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
        return 0  # Traditional WiFi ADB (IP:port format)
    fi
    if [[ "$serial" =~ _adb-tls-connect._tcp$ ]]; then
        return 0  # Android 11+ wireless debugging
    fi
    return 1
}

# Disable radios to reduce interference
disable_radios() {
    local serial=$(adb get-serialno 2>/dev/null)
    log "ADB connection: $serial"

    # Check if we're connected over WiFi
    if is_adb_wifi || [[ "${ADB_WIFI:-0}" == "1" ]]; then
        log "ADB over WiFi detected - keeping WiFi enabled"
        log "Disabling Bluetooth..."
        adb shell svc bluetooth disable 2>/dev/null || true
        log "Disabling mobile data..."
        adb shell svc data disable 2>/dev/null || true
        log "NOTE: Skipping airplane mode to maintain WiFi ADB connection"
    else
        log "Disabling WiFi..."
        adb shell svc wifi disable 2>/dev/null || true

        log "Disabling Bluetooth..."
        adb shell svc bluetooth disable 2>/dev/null || true

        log "Disabling mobile data..."
        adb shell svc data disable 2>/dev/null || true

        # Put device in airplane mode for good measure
        log "Enabling airplane mode..."
        adb shell settings put global airplane_mode_on 1 2>/dev/null || true
        adb shell am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true 2>/dev/null || true
    fi
}

# Set fixed screen brightness
set_brightness() {
    log "Setting screen brightness to 50%..."

    # Disable auto-brightness
    adb shell settings put system screen_brightness_mode 0

    # Set brightness to 128 (50% of 255)
    adb shell settings put system screen_brightness 128

    # Keep screen on during tests
    adb shell settings put system screen_off_timeout 1800000  # 30 minutes

    # Wake up screen
    adb shell input keyevent KEYCODE_WAKEUP
    sleep 1

    # Unlock if needed (swipe up)
    adb shell input swipe 540 1800 540 800 300
}

# Disable power-saving features that could affect measurements
disable_power_saving() {
    log "Disabling power-saving features..."

    # Disable adaptive battery
    adb shell settings put global adaptive_battery_management_enabled 0 2>/dev/null || true

    # Disable battery saver
    adb shell settings put global low_power 0 2>/dev/null || true

    # Disable doze mode
    adb shell dumpsys deviceidle disable 2>/dev/null || true

    # Set CPU governor to performance if available
    adb shell "echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor" 2>/dev/null || true
}

# Kill non-essential background apps
kill_background_apps() {
    log "Killing background apps..."

    # Get list of third-party packages
    PACKAGES=$(adb shell pm list packages -3 | cut -d: -f2)

    for pkg in $PACKAGES; do
        adb shell am force-stop "$pkg" 2>/dev/null || true
    done

    # Kill common battery-draining apps
    adb shell am force-stop com.google.android.gms 2>/dev/null || true
    adb shell am force-stop com.google.android.apps.photos 2>/dev/null || true
    adb shell am force-stop com.google.android.apps.maps 2>/dev/null || true

    log "Killed $(echo "$PACKAGES" | wc -w) third-party apps"
}

# Wait for system to stabilize
wait_for_idle() {
    log "Waiting for system to stabilize (120 seconds)..."
    sleep 120

    log "Checking system idle state..."

    # Check CPU usage
    CPU_USAGE=$(adb shell top -n 1 -b | head -5 | grep -oP '\d+(?=% cpu)' | head -1)
    log "Current CPU usage: ${CPU_USAGE:-unknown}%"

    # Check if system_server is stable
    SS_CPU=$(adb shell top -n 1 -b | grep system_server | awk '{print $9}')
    log "system_server CPU: ${SS_CPU:-unknown}%"
}

# Verify ESM is loaded (for ESM build only)
check_esm() {
    log "Checking for ESM kernel symbols..."

    # Use word boundary to avoid false positives like "resmask" matching "esm"
    ESM_SYMBOLS=$(adb shell "cat /proc/kallsyms 2>/dev/null | grep -cE ' esm_'" || echo "0")

    if [[ "$ESM_SYMBOLS" -gt 0 ]]; then
        log "ESM DETECTED: Found $ESM_SYMBOLS ESM symbols in kernel"
        adb shell "cat /proc/kallsyms | grep -E ' esm_' | head -10" | while read line; do
            log "  $line"
        done
    else
        log "ESM NOT DETECTED: This appears to be baseline (epoll) build"
    fi
}

# Record device state for reproducibility
record_state() {
    log "Recording device state..."

    STATE_FILE="$LOG_DIR/device_state_$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "=== Device State ==="
        echo "Date: $(date)"
        echo ""
        echo "=== Build Info ==="
        adb shell getprop ro.build.fingerprint
        adb shell getprop ro.build.version.release
        adb shell getprop ro.build.type
        echo ""
        echo "=== Kernel ==="
        adb shell uname -a
        echo ""
        echo "=== CPU Info ==="
        adb shell cat /proc/cpuinfo | head -20
        echo ""
        echo "=== Memory ==="
        adb shell cat /proc/meminfo | head -10
        echo ""
        echo "=== Battery ==="
        adb shell dumpsys battery
        echo ""
        echo "=== Temperature ==="
        adb shell cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null || echo "N/A"
    } > "$STATE_FILE"

    log "Device state saved to: $STATE_FILE"
}

# Main execution
main() {
    log "=========================================="
    log "ESM Performance Testing - Device Setup"
    log "=========================================="

    check_device
    enable_root
    disable_radios
    set_brightness
    disable_power_saving
    kill_background_apps
    wait_for_idle
    check_esm
    record_state

    log "=========================================="
    log "Device setup complete!"
    log "Ready for performance testing."
    log "=========================================="
}

main "$@"
