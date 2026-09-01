#!/usr/bin/env bash
# =============================================================================
# lib/adb.sh — ADB device validation and port forwarding over USB-C
#
# All video data is transported through the ADB daemon over the physical
# USB-C cable. No network interface, no WiFi, no IP routing.
#
# ADB socket forwarding:
#   adb forward tcp:<HOST_PORT> tcp:<DEVICE_PORT>
#   → Connections to localhost:<HOST_PORT> on the Linux host are tunneled
#     through the USB ADB daemon to localhost:<DEVICE_PORT> on Android.
# =============================================================================

# Exported after wait_for_adb_device():
#   ADB_SERIAL      — serial number of the connected device
#   ADB_STREAM_PORT — port used for the video stream socket (from config.sh)

# Initialize to empty so teardown is safe even if setup was never reached
ADB_SERIAL="${ADB_SERIAL:-}"

# -----------------------------------------------------------------------------
# wait_for_adb_device — poll until exactly one authorized device is connected.
# Aborts if the timeout (ADB_WAIT_TIMEOUT seconds) is exceeded.
# -----------------------------------------------------------------------------
wait_for_adb_device() {
    local timeout="${ADB_WAIT_TIMEOUT:-30}"
    log_step "Waiting for ADB device (timeout: ${timeout}s)"

    local elapsed=0
    while true; do
        local raw
        raw=$("${ADB_BIN:-adb}" devices 2>/dev/null)

        # Extract lines after the header, filter out empty lines
        local devices
        devices=$(echo "$raw" | tail -n +2 | grep -v '^\s*$')

        # Count authorized devices (state = "device")
        local authorized_count
        authorized_count=$(echo "$devices" | awk '$2 == "device"' | wc -l)

        local unauthorized_count
        unauthorized_count=$(echo "$devices" | awk '$2 == "unauthorized"' | wc -l)

        if [[ "$authorized_count" -ge 1 ]]; then
            # Pick the first authorized device serial
            export ADB_SERIAL
            ADB_SERIAL=$(echo "$devices" | awk '$2 == "device" {print $1}' | head -1)
            log_success "ADB device connected: ${ADB_SERIAL}"
            return 0
        fi

        if [[ "$unauthorized_count" -ge 1 ]]; then
            if [[ "$elapsed" -eq 0 ]] || (( elapsed % 5 == 0 )); then
                log_warn "Device found but UNAUTHORIZED. Please accept the ADB debugging prompt on your Android device."
            fi
        else
            if [[ "$elapsed" -eq 0 ]]; then
                log_info "No ADB device detected. Connect your Android device via USB-C."
                log_info "Ensure USB Debugging is enabled in Developer Options."
            fi
        fi

        sleep 1
        (( elapsed++ ))

        if [[ "$elapsed" -ge "$timeout" ]]; then
            log_error "Timed out after ${timeout}s waiting for an authorized ADB device."
            log_error "Troubleshooting:"
            log_error "  1. Ensure USB Debugging is ON: Settings → Developer Options → USB Debugging"
            log_error "  2. Accept the RSA fingerprint prompt on the device"
            log_error "  3. Try: adb kill-server && adb start-server"
            return 1
        fi
    done
}

# -----------------------------------------------------------------------------
# check_adb_usb — verify the connected device is over USB, not TCP/IP.
# Warns if the device serial looks like an IP address (tcp connection).
# -----------------------------------------------------------------------------
check_adb_usb() {
    if [[ "${ADB_SERIAL}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
        log_warn "ADB device serial '${ADB_SERIAL}' looks like a TCP/IP connection."
        log_warn "NativeSunshine was designed for USB-C, so using Wireless Debugging (Wi-Fi) may have higher latency."
        return 0
    fi
    log_info "ADB device is connected via USB ✓"
    return 0
}

# -----------------------------------------------------------------------------
# get_device_info — log basic info about the connected Android device.
# -----------------------------------------------------------------------------
get_device_info() {
    local serial="${ADB_SERIAL}"
    local model brand sdk
    model=$("${ADB_BIN:-adb}" -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
    brand=$("${ADB_BIN:-adb}" -s "$serial" shell getprop ro.product.brand 2>/dev/null | tr -d '\r')
    sdk=$("${ADB_BIN:-adb}" -s "$serial" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')

    log_info "Device: ${brand} ${model} (Android SDK ${sdk})"

    if [[ -n "$sdk" ]] && [[ "$sdk" -lt 23 ]]; then
        log_error "Android SDK ${sdk} is too old. NativeSunshine requires API level 23+ (Android 6.0+)."
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# get_client_display_metrics — query device for native resolution and refresh rate
# -----------------------------------------------------------------------------
get_client_display_metrics() {
    log_step "Fetching device display metrics"
    local serial="${ADB_SERIAL}"
    
    # Get Physical Size
    local wm_size
    wm_size=$("${ADB_BIN:-adb}" -s "$serial" shell wm size 2>/dev/null | grep "Physical size:" | awk '{print $3}')
    if [[ -n "$wm_size" && "$wm_size" == *"x"* ]]; then
        local w="${wm_size%x*}"
        local h="${wm_size#*x}"
        
        # Get Orientation
        local orientation
        orientation=$("${ADB_BIN:-adb}" -s "$serial" shell dumpsys input 2>/dev/null | grep SurfaceOrientation | head -1 | awk '{print $2}')
        
        if [[ "$orientation" == "1" || "$orientation" == "3" ]]; then
            export TARGET_WIDTH="$h"
            export TARGET_HEIGHT="$w"
        else
            export TARGET_WIDTH="$w"
            export TARGET_HEIGHT="$h"
        fi
        
        log_info "Device native resolution: ${TARGET_WIDTH}x${TARGET_HEIGHT} (Orientation: ${orientation:-0})"
    else
        log_warn "Could not fetch device resolution, falling back to ${TARGET_WIDTH}x${TARGET_HEIGHT}"
    fi

    # Get Refresh Rate
    local refresh_rate
    
    if [[ -n "${GUI_FRAMERATE:-}" ]] && [[ "${GUI_FRAMERATE}" -gt 0 ]]; then
        TARGET_REFRESH="${GUI_FRAMERATE}"
        log_info "Device native resolution: ${TARGET_WIDTH}x${TARGET_HEIGHT} (Orientation: ${orientation}, forced ${TARGET_REFRESH}Hz)"
    else
        refresh_rate=$("${ADB_BIN:-adb}" -s "$ADB_SERIAL" shell dumpsys display | grep -iE 'refresh|fps' | grep -oE '[0-9]+\.[0-9]+' | head -n 1)

        if [[ -n "$refresh_rate" ]]; then
            # Round to integer
            TARGET_REFRESH=$(printf "%.0f" "$refresh_rate")
            log_info "Device native resolution: ${TARGET_WIDTH}x${TARGET_HEIGHT} (Orientation: ${orientation}, ${TARGET_REFRESH}Hz)"
        else
            log_info "Device native resolution: ${TARGET_WIDTH}x${TARGET_HEIGHT} (Orientation: ${orientation})"
            log_warn "Could not fetch device refresh rate, falling back to 120Hz"
            TARGET_REFRESH=120
        fi
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# watch_client_orientation — background loop to poll orientation
# -----------------------------------------------------------------------------
watch_client_orientation() {
    local serial="${ADB_SERIAL}"
    local main_pid="$1"
    
    # Get initial orientation
    local current_orientation
    current_orientation=$("${ADB_BIN:-adb}" -s "$serial" shell dumpsys input 2>/dev/null | grep SurfaceOrientation | head -1 | awk '{print $2}')
    
    while true; do
        sleep 2
        local new_orientation
        new_orientation=$("${ADB_BIN:-adb}" -s "$serial" shell dumpsys input 2>/dev/null | grep SurfaceOrientation | head -1 | awk '{print $2}')
        if [[ -n "$new_orientation" && "$new_orientation" != "$current_orientation" ]]; then
            log_info "Orientation changed ($current_orientation -> $new_orientation). Restarting pipeline..."
            kill -SIGUSR1 "$main_pid"
            exit 0
        fi
    done
}

# -----------------------------------------------------------------------------
# setup_adb_forward — create the ADB forward tunnel for the video stream port.
#
# adb forward tcp:HOST_PORT tcp:DEVICE_PORT
#
# This makes connections to localhost:HOST_PORT on Linux route through the
# USB cable to localhost:DEVICE_PORT on Android — pure USB, no network.
# -----------------------------------------------------------------------------
setup_adb_forward() {
    local port="${ADB_STREAM_PORT:-7878}"
    log_step "Setting up ADB port forward: localhost:${port} → device:${port}"

    if ! "${ADB_BIN:-adb}" -s "${ADB_SERIAL}" forward "tcp:${port}" "tcp:${port}" 2>/dev/null; then
        log_error "Failed to set up ADB forward on port ${port}."
        log_error "Check that the device is still connected and authorized."
        return 1
    fi

    # Verify the forward is in place
    local fwd_check
    fwd_check=$("${ADB_BIN:-adb}" -s "${ADB_SERIAL}" forward --list 2>/dev/null)
    if echo "$fwd_check" | grep -q "tcp:${port}"; then
        log_success "ADB forward established: tcp:${port} → tcp:${port}"
    else
        log_warn "Forward may not have been applied. Current forwards:"
        log_warn "$fwd_check"
    fi
    
    local control_port="7879"
    log_step "Setting up ADB reverse forward: device:${control_port} → localhost:${control_port}"
    "${ADB_BIN:-adb}" -s "${ADB_SERIAL}" reverse "tcp:${control_port}" "tcp:${control_port}" 2>/dev/null || true

    return 0
}

# -----------------------------------------------------------------------------
# teardown_adb_forward — remove all ADB forward rules for this device.
# Safe to call even if no forwards are active.
# -----------------------------------------------------------------------------
teardown_adb_forward() {
    log_step "Removing ADB port forwards"

    if [[ -z "${ADB_SERIAL}" ]]; then
        # No serial means we can't target a specific device; remove all
        "${ADB_BIN:-adb}" forward --remove-all 2>/dev/null || true
        "${ADB_BIN:-adb}" reverse --remove-all 2>/dev/null || true
    else
        "${ADB_BIN:-adb}" -s "${ADB_SERIAL}" forward --remove-all 2>/dev/null || true
        "${ADB_BIN:-adb}" -s "${ADB_SERIAL}" reverse --remove-all 2>/dev/null || true
    fi

    log_success "ADB port forwards cleared."
}

# -----------------------------------------------------------------------------
# check_app_installed — verify the NativeSunshine APK is installed on device.
# -----------------------------------------------------------------------------
check_app_installed() {
    local pkg="dev.nativesunshine"
    log_step "Checking NativeSunshine APK on device"

    local installed
    installed=$("${ADB_BIN:-adb}" -s "${ADB_SERIAL}" shell pm list packages 2>/dev/null | grep "package:${pkg}")

    if [[ -z "$installed" ]]; then
        log_warn "NativeSunshine APK (${pkg}) is not installed on the device."
        log_warn "Build and install it with:"
        log_warn "  cd android/NativeSunshine && ./gradlew assembleDebug"
        log_warn "  adb install app/build/outputs/apk/debug/app-debug.apk"
        return 1
    fi

    log_success "NativeSunshine APK found on device."
    return 0
}

# -----------------------------------------------------------------------------
# launch_app_on_device — start the NativeSunshine receiver activity via ADB.
# -----------------------------------------------------------------------------
launch_app_on_device() {
    log_step "Launching NativeSunshine on Android device"
    "${ADB_BIN:-adb}" -s "${ADB_SERIAL}" shell \
        am start -n "dev.nativesunshine/.MainActivity" \
        --activity-clear-top \
        2>/dev/null || {
        log_warn "Could not auto-launch NativeSunshine app. Please open it manually on your device."
        return 0  # Non-fatal; user can launch manually
    }
    log_success "NativeSunshine launched on device."
}
