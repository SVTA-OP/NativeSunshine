#!/usr/bin/env bash
# =============================================================================
# lib/pipeline.sh — GStreamer pipeline construction and process lifecycle
#
# Captures the virtual Wayland display via PipeWire and encodes it as H.264
# (AMD VAAPI by default), then pushes the byte-stream to localhost:<port>
# where the ADB forward tunnel delivers it to the Android receiver app.
#
# Pipeline data flow:
#   pipewiresrc (PW node)
#     → videoconvert / vaapipostproc
#     → vaapih264enc (CBR, zero-latency profile)
#     → h264parse (byte-stream, AU alignment)
#     → tcpclientsink (localhost:ADB_STREAM_PORT)
#     ─────────────────────────────── USB cable ─────
#     → Android NativeSunshine app (ServerSocket)
#     → MediaCodec H.264 decoder
#     → SurfaceView fullscreen render
# =============================================================================

# Globals set by this module:
#   PIPELINE_PID   — PID of the gst-launch-1.0 process

# -----------------------------------------------------------------------------
# _build_vulkan_pipeline — AMD hardware H.264 via Vulkan Video (RADV)
# Requires: gst-plugins-bad with Vulkan support (gst-plugin-vulkan on Arch)
# The vulkanh264enc element uses the GPU's fixed-function encode hardware
# via the Vulkan Video extension, identical in quality to VAAPI but using
# the modern Vulkan API instead of the legacy VA-API.
# -----------------------------------------------------------------------------
_build_vulkan_pipeline() {
    local node_id="$1"
    local port="$2"
    local bitrate="${STREAM_BITRATE:-8000}"
    local keyint="${KEYFRAME_INTERVAL:-60}"

    # vulkanh264enc properties:
    #   rate-control=cbr (2)  → constant bitrate
    #   bitrate=N             → target kbps
    #   idr-period=N          → IDR every N frames
    #   quality=1             → fastest (0-10, lower=faster)
    #
    # vulkanupload: copies frames from CPU/PipeWire memory into Vulkan GPU memory
    # (required before vulkanh264enc which only accepts VulkanImage memory)

    cat <<EOF
pipewiresrc
    path=${node_id}
    do-timestamp=true
    keepalive-time=16
  !
  videoconvert
  !
  video/x-raw, width=${TARGET_WIDTH}, height=${TARGET_HEIGHT}, max-framerate=${TARGET_REFRESH}/1, format=NV12
  !
  queue max-size-buffers=5
  !
  vulkanupload
  !
  vulkanh264enc
    rate-control=cbr
    bitrate=${bitrate}
    idr-period=${keyint}
    quality=1
  !
  video/x-h264,
    stream-format=byte-stream,
    alignment=au,
    profile=main
  !
  h264parse
    config-interval=-1
  !
  tcpclientsink
    host=127.0.0.1
    port=${port}
    sync=false
    max-lateness=-1
EOF
}

# -----------------------------------------------------------------------------
# _build_nvenc_pipeline — NVIDIA NVENC H.264 encoder pipeline
# -----------------------------------------------------------------------------
_build_nvenc_pipeline() {
    local node_id="$1"
    local port="$2"
    local bitrate="${STREAM_BITRATE:-8000}"
    local keyint="${KEYFRAME_INTERVAL:-60}"

    cat <<EOF
pipewiresrc
    path=${node_id}
    do-timestamp=true
  !
  videoconvert
  !
  video/x-raw, width=${TARGET_WIDTH}, height=${TARGET_HEIGHT}, max-framerate=${TARGET_REFRESH}/1
  !
  queue max-size-buffers=5
  !
  nvh264enc
    bitrate=${bitrate}
    gop-size=${keyint}
    rc-mode=cbr
    preset=low-latency-hq
    zerolatency=true
    aud=false
  !
  video/x-h264,
    stream-format=byte-stream,
    alignment=au,
    profile=main
  !
  h264parse
    config-interval=-1
  !
  tcpclientsink
    host=127.0.0.1
    port=${port}
    sync=false
EOF
}

# -----------------------------------------------------------------------------
# _build_software_pipeline — CPU x264 encoder pipeline (fallback)
# -----------------------------------------------------------------------------
_build_software_pipeline() {
    local node_id="$1"
    local port="$2"
    local bitrate="${STREAM_BITRATE:-8000}"
    local keyint="${KEYFRAME_INTERVAL:-60}"

    # x264enc bitrate is in kbit/s
    cat <<EOF
pipewiresrc
    path=${node_id}
    do-timestamp=true
  !
  videoconvert
  !
  video/x-raw, width=${TARGET_WIDTH}, height=${TARGET_HEIGHT}, max-framerate=${TARGET_REFRESH}/1, format=I420
  !
  queue max-size-buffers=5
  !
  x264enc
    bitrate=${bitrate}
    key-int-max=${keyint}
    tune=zerolatency
    speed-preset=ultrafast
    pass=cbr
    aud=false
    threads=4
  !
  video/x-h264,
    stream-format=byte-stream,
    alignment=au,
    profile=main
  !
  h264parse
    config-interval=-1
  !
  tcpclientsink
    host=127.0.0.1
    port=${port}
    sync=false
EOF
}

# -----------------------------------------------------------------------------
# _build_vaapi_pipeline — Intel/AMD VAAPI H.264 encoder pipeline
# -----------------------------------------------------------------------------
_build_vaapi_pipeline() {
    local node_id="$1"
    local port="$2"
    local bitrate="${STREAM_BITRATE:-8000}"
    local keyint="${KEYFRAME_INTERVAL:-60}"

    cat <<EOF
pipewiresrc
    path=${node_id}
    do-timestamp=true
  !
  video/x-raw, width=${TARGET_WIDTH}, height=${TARGET_HEIGHT}, max-framerate=${TARGET_REFRESH}/1
  !
  vaapipostproc
  !
  queue max-size-buffers=5
  !
  vaapih264enc
    bitrate=${bitrate}
    keyframe-period=${keyint}
    rate-control=cbr
    tune=low-power
  !
  video/x-h264,
    stream-format=byte-stream,
    alignment=au,
    profile=main
  !
  h264parse
    config-interval=-1
  !
  tcpclientsink
    host=127.0.0.1
    port=${port}
    sync=false
EOF
}

# -----------------------------------------------------------------------------
# build_pipeline_string — select encoder and return the pipeline string.
# Args: $1=pw_node_id, $2=port
# Prints the pipeline string to stdout.
# -----------------------------------------------------------------------------
build_pipeline_string() {
    local node_id="$1"
    local port="$2"
    local encoder="${ENCODER:-vulkan}"

    case "$encoder" in
        vulkan)    _build_vulkan_pipeline    "$node_id" "$port" ;;
        vaapi)     _build_vaapi_pipeline     "$node_id" "$port" ;;
        nvenc)     _build_nvenc_pipeline     "$node_id" "$port" ;;
        software)  _build_software_pipeline  "$node_id" "$port" ;;
        *)
            log_error "Unknown encoder: '${encoder}'. Valid options: vulkan, vaapi, nvenc, software"
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# launch_pipeline — start the GStreamer pipeline as a background process.
# Args: $1=pipeline_string
# Sets global PIPELINE_PID on success.
# -----------------------------------------------------------------------------
launch_pipeline() {
    local pipeline="$1"
    local gst_bin="${GST_LAUNCH_BIN:-gst-launch-1.0}"
    local log="${PIPELINE_LOG:-${HOME}/.local/log/native-sunshine-pipeline.log}"

    log_step "Launching GStreamer pipeline (encoder: ${ENCODER:-vaapi})"

    # Log the pipeline for debugging
    log_info "Pipeline:"
    echo "$pipeline" | while IFS= read -r line; do
        log_info "  ${line}"
    done

    # Launch — redirect pipeline stderr to a dedicated log file
    # We use `eval` here carefully to handle the multi-line pipeline string
    # that contains GStreamer property assignments.
    mkdir -p "$(dirname "$log")"

    # Collapse the pipeline to a single line (gst-launch-1.0 expects one line)
    local pipeline_oneline
    pipeline_oneline=$(echo "$pipeline" | tr -s ' \n\t' ' ' | sed 's/^ //;s/ $//')

    "${gst_bin}" -e ${PIPELINE_LOG:+--gst-debug-level=2} \
        ${pipeline_oneline} \
        >> "$log" 2>&1 &

    export PIPELINE_PID=$!

    # Give it a moment to fail fast (bad plugin, wrong node ID, etc.)
    sleep 1

    if ! kill -0 "${PIPELINE_PID}" 2>/dev/null; then
        log_error "GStreamer pipeline exited immediately."
        log_error "Check pipeline log: ${log}"
        log_error "Common causes:"
        log_error "  - Wrong PipeWire node ID (VIRT_PW_NODE_ID=${VIRT_PW_NODE_ID})"
        log_error "  - VAAPI device not accessible (${VAAPI_DEVICE:-/dev/dri/renderD128})"
        log_error "  - NativeSunshine app not running on Android (nothing to connect to)"
        return 1
    fi

    log_success "Pipeline running (PID: ${PIPELINE_PID})"
    log_info "Pipeline log: ${log}"
    return 0
}

# -----------------------------------------------------------------------------
# stop_pipeline — gracefully terminate the GStreamer pipeline.
# Sends SIGINT (triggers EOS flush) then waits; SIGKILL after 5s if needed.
# -----------------------------------------------------------------------------
stop_pipeline() {
    local pid="${1:-${PIPELINE_PID}}"

    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        log_info "Pipeline not running, nothing to stop."
        return 0
    fi

    log_step "Stopping GStreamer pipeline (PID: ${pid})"

    # SIGINT → gst-launch-1.0 sends EOS and flushes
    kill -SIGINT "$pid" 2>/dev/null || true

    # Wait up to 5 seconds for clean exit
    local i=0
    while kill -0 "$pid" 2>/dev/null && [[ $i -lt 5 ]]; do
        sleep 1
        (( i++ ))
    done

    # Force kill if still alive
    if kill -0 "$pid" 2>/dev/null; then
        log_warn "Pipeline did not exit cleanly; sending SIGKILL..."
        kill -SIGKILL "$pid" 2>/dev/null || true
    fi

    wait "$pid" 2>/dev/null || true
    log_success "Pipeline stopped."
}

# -----------------------------------------------------------------------------
# print_stream_info — print connection status/URL for the user.
# -----------------------------------------------------------------------------
print_stream_info() {
    local port="${ADB_STREAM_PORT:-7878}"
    echo ""
    echo -e "${_C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_C_RESET}"
    echo -e "${_C_SUCCESS}  NativeSunshine stream is LIVE${_C_RESET}"
    echo -e "${_C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_C_RESET}"
    echo ""
    echo -e "  Virtual display : ${_C_INFO}${VIRT_DISPLAY_NAME}${_C_RESET} (${TARGET_WIDTH}×${TARGET_HEIGHT}@${TARGET_REFRESH}Hz)"
    echo -e "  PipeWire node   : ${_C_INFO}${VIRT_PW_NODE_ID}${_C_RESET}"
    echo -e "  ADB tunnel      : ${_C_INFO}tcp:${port} → USB → tcp:${port}${_C_RESET}"
    echo -e "  Encoder         : ${_C_INFO}${ENCODER:-vaapi} H.264 @ ${STREAM_BITRATE}kbps${_C_RESET}"
    echo -e "  Device          : ${_C_INFO}${ADB_SERIAL}${_C_RESET}"
    echo ""
    echo -e "  ${_C_WARN}Open NativeSunshine on your Android device.${_C_RESET}"
    echo -e "  Move windows to '${VIRT_DISPLAY_NAME}' in GNOME display settings."
    echo ""
    echo -e "  Press ${_C_BOLD}Ctrl+C${_C_RESET} to stop the stream and clean up."
    echo ""
}
