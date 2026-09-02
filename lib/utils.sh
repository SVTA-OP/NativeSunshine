#!/usr/bin/env bash
# =============================================================================
# lib/utils.sh — Logging, dependency checking, and signal trap setup
# Sourced by native-sunshine.sh and other lib modules.
# =============================================================================

# -----------------------------------------------------------------------------
# Color codes (only emit if stdout is a terminal)
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    _C_RESET='\033[0m'
    _C_INFO='\033[0;36m'    # cyan
    _C_WARN='\033[0;33m'    # yellow
    _C_ERROR='\033[0;31m'   # red
    _C_SUCCESS='\033[0;32m' # green
    _C_BOLD='\033[1m'
else
    _C_RESET='' _C_INFO='' _C_WARN='' _C_ERROR='' _C_SUCCESS='' _C_BOLD=''
fi

_log_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()    { echo -e "${_C_INFO}[INFO ]${_C_RESET}  $(_log_ts)  $*" | tee -a "${LOG_FILE:-/dev/null}"; }
log_warn()    { echo -e "${_C_WARN}[WARN ]${_C_RESET}  $(_log_ts)  $*" | tee -a "${LOG_FILE:-/dev/null}"; }
log_error()   { echo -e "${_C_ERROR}[ERROR]${_C_RESET}  $(_log_ts)  $*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
log_success() { echo -e "${_C_SUCCESS}[  OK ]${_C_RESET}  $(_log_ts)  $*" | tee -a "${LOG_FILE:-/dev/null}"; }
log_step()    { echo -e "${_C_BOLD}[STEP ]${_C_RESET}  $(_log_ts)  ── $* ──" | tee -a "${LOG_FILE:-/dev/null}"; }

# Die with an error message and non-zero exit.
die() {
    log_error "$*"
    exit 1
}

# -----------------------------------------------------------------------------
# Dependency checking
# -----------------------------------------------------------------------------

# Check whether a single command exists.
_check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        return 1
    fi
    return 0
}

# Check a GStreamer plugin element exists.
_check_gst_element() {
    gst-inspect-1.0 --no-colors "$1" &>/dev/null
}

# check_deps — validate all required tools and GStreamer elements.
# Populates global MISSING_DEPS array. Returns 1 if anything is missing.
check_deps() {
    local ok=true
    declare -ga MISSING_DEPS=()

    log_step "Checking dependencies"

    local required_cmds=(
        "adb:Android Debug Bridge (install: android-tools / adb)"
        "${GST_LAUNCH_BIN:-gst-launch-1.0}:GStreamer launcher (install: gstreamer1.0-tools)"
        "gst-inspect-1.0:GStreamer inspector (install: gstreamer1.0-tools)"
        "pw-dump:PipeWire CLI (install: pipewire)"
        "jq:JSON processor (install: jq)"
        "gdbus:D-Bus CLI (install: dbus / libglib2.0-bin)"
    )

    for entry in "${required_cmds[@]}"; do
        local cmd="${entry%%:*}"
        local hint="${entry#*:}"
        if ! _check_cmd "$cmd"; then
            log_error "Missing command: ${_C_BOLD}${cmd}${_C_RESET} — ${hint}"
            MISSING_DEPS+=("$cmd")
            ok=false
        else
            log_info "  ✓ ${cmd}"
        fi
    done

    # GStreamer elements required
    local required_elements=()
    case "${ENCODER:-vaapi}" in
        vaapi)
            required_elements=(
                "pipewiresrc:gstreamer1.0-pipewire"
                "vah264enc:gst-plugin-va (or gstreamer-vaapi on older distros)"
                "tcpclientsink:gstreamer1.0-plugins-good (net)"
                "h264parse:gstreamer1.0-plugins-bad"
                "queue:gstreamer1.0-plugins-base"
                "videorate:gstreamer / gst-plugins-base"
            )
            ;;
        vulkan)
            required_elements=(
                "pipewiresrc:gst-plugin-pipewire"
                "vulkanh264enc:gst-plugins-bad (Vulkan support, Arch: gst-plugins-bad)"
                "vulkanupload:gst-plugins-bad (Vulkan support)"
                "videoconvert:gstreamer / gst-plugins-base"
                "tcpclientsink:gst-plugins-good"
                "h264parse:gst-plugins-bad"
                "queue:gst-plugins-base"
                "videorate:gstreamer / gst-plugins-base"
            )
            ;;
        nvenc)
            required_elements=(
                "pipewiresrc:gstreamer1.0-pipewire"
                "nvh264enc:gstreamer1.0-plugins-bad (nvcodec)"
                "tcpclientsink:gstreamer1.0-plugins-good (net)"
                "h264parse:gstreamer1.0-plugins-bad"
                "queue:gstreamer1.0-plugins-base"
                "videorate:gstreamer / gst-plugins-base"
            )
            ;;
        software)
            required_elements=(
                "pipewiresrc:gstreamer1.0-pipewire"
                "x264enc:gstreamer1.0-plugins-ugly"
                "tcpclientsink:gstreamer1.0-plugins-good (net)"
                "h264parse:gstreamer1.0-plugins-bad"
                "queue:gstreamer1.0-plugins-base"
                "videorate:gstreamer / gst-plugins-base"
            )
            ;;
    esac

    for entry in "${required_elements[@]}"; do
        local elem="${entry%%:*}"
        local pkg="${entry#*:}"
        if ! _check_gst_element "$elem"; then
            log_error "Missing GStreamer element: ${_C_BOLD}${elem}${_C_RESET} — install package: ${pkg}"
            MISSING_DEPS+=("gst:${elem}")
            ok=false
        else
            log_info "  ✓ gst:${elem}"
        fi
    done

    if [[ "$ok" == "false" ]]; then
        log_error "Dependency check FAILED. Run ./install.sh to install missing components."
        return 1
    fi

    log_success "All dependencies satisfied."
    return 0
}

# -----------------------------------------------------------------------------
# Log directory setup
# -----------------------------------------------------------------------------
setup_logging() {
    mkdir -p "${LOG_DIR:-${HOME}/.local/log}"
    # Rotate log if >5 MB
    if [[ -f "${LOG_FILE}" ]] && [[ $(stat -c%s "${LOG_FILE}" 2>/dev/null || echo 0) -gt 5242880 ]]; then
        mv "${LOG_FILE}" "${LOG_FILE}.old"
    fi
    log_info "=== NativeSunshine session start ==="
}

# -----------------------------------------------------------------------------
# Signal traps
# The teardown function must be defined in the main script (native-sunshine.sh)
# before setup_traps() is called.
# -----------------------------------------------------------------------------
setup_traps() {
    trap '_ns_trap_handler INT'  INT
    trap '_ns_trap_handler TERM' TERM
    trap '_ns_trap_handler EXIT' EXIT
}

_NS_TEARDOWN_CALLED=0
_ns_trap_handler() {
    local sig="$1"
    if [[ "${_NS_TEARDOWN_CALLED}" -eq 0 ]]; then
        _NS_TEARDOWN_CALLED=1
        log_warn "Caught signal ${sig} — initiating teardown..."
        # Call the main script's teardown function if it exists
        if declare -f teardown &>/dev/null; then
            teardown
        fi
    fi
    # Re-raise for EXIT so the exit code is correct
    [[ "$sig" != "EXIT" ]] && exit 1
}
