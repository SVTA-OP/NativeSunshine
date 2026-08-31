#!/usr/bin/env bash
# =============================================================================
# native-sunshine.sh — Master orchestrator
#
# Usage:
#   ./native-sunshine.sh              # Normal run
#   ./native-sunshine.sh --dry-run   # Print config, make no system changes
#   ./native-sunshine.sh --check     # Dependency check only, then exit
#
# Lifecycle:
#   1. Load config + libraries
#   2. Check dependencies
#   3. Verify ADB device (USB)
#   4. Set up ADB port forward
#   5. Verify virtual display exists (from systemd override)
#   6. Discover PipeWire node ID
#   7. Build + launch GStreamer pipeline
#   8. Wait for pipeline (or Ctrl+C)
#
# Teardown (SIGINT / SIGTERM / EXIT):
#   → Stop GStreamer pipeline
#   → Remove ADB forwards
# =============================================================================

set -euo pipefail

# Resolve script directory so we can source siblings regardless of CWD
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Parse flags
# -----------------------------------------------------------------------------
DRY_RUN=false
CHECK_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)   DRY_RUN=true ;;
        --check)     CHECK_ONLY=true ;;
        --help|-h)
            cat <<'HELP'
NativeSunshine — Android USB-C secondary monitor (no network, no WiFi)

Usage:
  native-sunshine.sh [OPTIONS]

Options:
  --dry-run     Print all computed settings without making system changes
  --check       Run dependency check only and exit
  --help        Show this help

Prerequisites:
  - Android device connected via USB-C with USB Debugging enabled
  - NativeSunshine APK installed on the Android device
  - GNOME Shell running with --virtual-monitor 800x1340
    (set via your systemd override in ~/.config/systemd/user/org.gnome.Shell@user.service.d/)

See README.md for full setup instructions.
HELP
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg. Use --help for usage." >&2
            exit 1
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Source configuration and libraries
# -----------------------------------------------------------------------------
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=lib/utils.sh
source "${SCRIPT_DIR}/lib/utils.sh"
# shellcheck source=lib/display.sh
source "${SCRIPT_DIR}/lib/display.sh"
# shellcheck source=lib/adb.sh
source "${SCRIPT_DIR}/lib/adb.sh"
# shellcheck source=lib/pipeline.sh
source "${SCRIPT_DIR}/lib/pipeline.sh"

# Initialize pipeline PID to empty (set later by launch_pipeline)
PIPELINE_PID=""

# -----------------------------------------------------------------------------
# Logging setup
# -----------------------------------------------------------------------------
setup_logging

log_info "NativeSunshine starting (encoder=${ENCODER}, ${TARGET_WIDTH}x${TARGET_HEIGHT}@${TARGET_REFRESH}Hz)"

# -----------------------------------------------------------------------------
# Teardown function — called by signal traps in utils.sh
# -----------------------------------------------------------------------------
teardown() {
    echo ""  # Newline after ^C
    log_step "Teardown"

    # 1. Stop GStreamer pipeline
    stop_pipeline "${PIPELINE_PID:-}"

    # 2. Kill the headless Mutter screencast script if it's running
    if [[ -n "${MUTTER_SCREENCAST_PID:-}" ]]; then
        kill "$MUTTER_SCREENCAST_PID" 2>/dev/null || true
    fi

    # 3. Remove ADB port forwards
    teardown_adb_forward

    log_success "Teardown complete. Goodbye."
}

# Register signal traps (defined in lib/utils.sh, calls teardown above)
setup_traps

# -----------------------------------------------------------------------------
# --check mode: dependency validation only
# -----------------------------------------------------------------------------
if [[ "${CHECK_ONLY}" == "true" ]]; then
    check_deps
    exit $?
fi

# -----------------------------------------------------------------------------
# Dependency check
# -----------------------------------------------------------------------------
check_deps || exit 1

# -----------------------------------------------------------------------------
# --dry-run mode: print config and exit
# -----------------------------------------------------------------------------
if [[ "${DRY_RUN}" == "true" ]]; then
    log_step "DRY RUN — no system changes will be made"
    echo ""
    echo "  Configuration:"
    echo "    TARGET_WIDTH     = ${TARGET_WIDTH}"
    echo "    TARGET_HEIGHT    = ${TARGET_HEIGHT}"
    echo "    TARGET_REFRESH   = ${TARGET_REFRESH}"
    echo "    ENCODER          = ${ENCODER}"
    echo "    VAAPI_DEVICE     = ${VAAPI_DEVICE:-/dev/dri/renderD128}"
    echo "    STREAM_BITRATE   = ${STREAM_BITRATE} kbps"
    echo "    KEYFRAME_INTERVAL= ${KEYFRAME_INTERVAL} frames"
    echo "    ADB_BIN          = ${ADB_BIN}"
    echo "    ADB_STREAM_PORT  = ${ADB_STREAM_PORT}"
    echo "    ADB_WAIT_TIMEOUT = ${ADB_WAIT_TIMEOUT}s"
    echo "    LOG_FILE         = ${LOG_FILE}"
    echo "    PIPELINE_LOG     = ${PIPELINE_LOG}"
    echo ""

    log_info "Checking ADB devices (dry run):"
    "${ADB_BIN:-adb}" devices 2>&1 | sed 's/^/    /'

    log_info "Checking PipeWire nodes (dry run):"
    pw-dump 2>/dev/null | jq -r '
        .[] |
        select(.type == "PipeWire:Interface:Node") |
        select(.info.props["media.class"] // "" | test("Video/Source"; "i")) |
        "    id=\(.id)  desc=\(.info.props["node.description"] // "?")"
    ' 2>/dev/null || log_warn "pw-dump/jq not available or no video sources"

    echo ""
    log_success "Dry run complete. Review the above and run without --dry-run to stream."
    exit 0
fi

# -----------------------------------------------------------------------------
# STEP 1 — Verify ADB device is connected and authorized over USB
# -----------------------------------------------------------------------------
log_step "Step 1/5 — ADB device"
wait_for_adb_device || exit 1
check_adb_usb       || exit 1
get_device_info     || exit 1

# Non-fatal: warn if app not installed but continue so user can install + retry
check_app_installed || log_warn "Continuing without APK — install it before opening the app."

# -----------------------------------------------------------------------------
# STEP 2 — ADB port forwarding (USB tunnel for video stream)
# -----------------------------------------------------------------------------
log_step "Step 2/5 — ADB port forward"
setup_adb_forward || exit 1

# -----------------------------------------------------------------------------
# STEP 3 — Verify virtual display
# -----------------------------------------------------------------------------
log_step "Step 3/5 — Virtual display"
verify_virtual_display || exit 1

# -----------------------------------------------------------------------------
# STEP 4 — Discover PipeWire node ID for the virtual display
# -----------------------------------------------------------------------------
log_step "Step 4/5 — PipeWire node"
get_pipewire_node_id || exit 1
display_info

# -----------------------------------------------------------------------------
# STEP 5 — Build and launch GStreamer pipeline
# -----------------------------------------------------------------------------
log_step "Step 5/5 — Stream pipeline"

PIPELINE_STR=$(build_pipeline_string "${VIRT_PW_NODE_ID}" "${ADB_STREAM_PORT}") || exit 1

# Launch the Android app (non-fatal if it fails)
launch_app_on_device || true

launch_pipeline "${PIPELINE_STR}" || exit 1

# Print connection summary for the user
print_stream_info

# -----------------------------------------------------------------------------
# Wait — keep running until the pipeline exits or we get a signal
# -----------------------------------------------------------------------------
# The traps registered via setup_traps() handle SIGINT/SIGTERM → teardown().
# We wait on the pipeline PID so the script exits naturally if gst-launch dies.

wait "${PIPELINE_PID}" 2>/dev/null || true

# If we reach here without a signal (pipeline exited on its own):
if [[ "${_NS_TEARDOWN_CALLED:-0}" -eq 0 ]]; then
    log_warn "GStreamer pipeline exited unexpectedly."
    log_warn "Check pipeline log: ${PIPELINE_LOG}"
    teardown
fi
