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

    local w="${TARGET_WIDTH:-800}"
    local h="${TARGET_HEIGHT:-1340}"
    local fps="${TARGET_REFRESH:-60}"
    # NOTE: encoding at the exact target resolution (no manual alignment).
    # H.264 always pads internally to 16px macroblocks and signals the true
    # display size via SPS frame-cropping, so the decoder should see 800x1340
    # regardless of internal padding.
    # KNOWN ISSUE: vulkanh264enc (RADV) has a history of corrupting/half-green
    # frames on heights that aren't 32-aligned (1340 is not). If that
    # resurfaces here, it's a RADV-specific SPS-cropping bug — fall back to
    # the vaapi or software encoder rather than re-adding alignment math,
    # since re-aligning here just reintroduces the host/decoder size mismatch.
    #
    # Explicit framerate: without this, vulkanh264enc has been observed
    # signaling framerate=120 in the SPS VUI (see h264parse "exceeds allowed
    # maximum" warnings) regardless of what's actually delivered, which
    # desyncs its own rate-control/GOP timing model from reality. Pin it to
    # the real detected refresh so the encoder isn't guessing.

    cat <<EOF
pipewiresrc
    path=${node_id}
    do-timestamp=true
    keepalive-time=16
  !
  videoconvert n-threads=0
  !
  videoscale method=0
  !
  videorate
  !
  video/x-raw, format=NV12, width=${w}, height=${h}, framerate=${fps}/1
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
    profile=constrained-baseline
  !
  h264parse
    config-interval=-1
  !
  fdsink fd=1 sync=false
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
    local w="${TARGET_WIDTH:-800}"
    local h="${TARGET_HEIGHT:-1340}"

    cat <<EOF
pipewiresrc
    path=${node_id}
    do-timestamp=true
  !
  videoconvert n-threads=0
  !
  videoscale method=0
  !
  videorate
  !
  video/x-raw, width=${w}, height=${h}, framerate=${TARGET_REFRESH:-60}/1
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
    profile=constrained-baseline
  !
  h264parse
    config-interval=-1
  !
  fdsink fd=1 sync=false
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
    local w="${TARGET_WIDTH:-800}"
    local h="${TARGET_HEIGHT:-1340}"

    # x264enc bitrate is in kbit/s
    cat <<EOF
pipewiresrc
    path=${node_id}
    do-timestamp=true
  !
  videoconvert n-threads=0
  !
  videoscale method=0
  !
  videorate
  !
  video/x-raw, format=I420, width=${w}, height=${h}, framerate=${TARGET_REFRESH:-60}/1
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
    profile=constrained-baseline
  !
  h264parse
    config-interval=-1
  !
  fdsink fd=1 sync=false
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
    local w="${TARGET_WIDTH:-800}"
    local h="${TARGET_HEIGHT:-1340}"

    cat <<EOF
pipewiresrc
    path=${node_id}
    do-timestamp=true
  !
  vapostproc
  !
  videorate
  !
  video/x-raw, width=${w}, height=${h}, framerate=${TARGET_REFRESH:-60}/1
  !
  queue max-size-buffers=5
  !
  vah264enc
    bitrate=${bitrate}
    key-int-max=${keyint}
    rate-control=cbr
  !
  video/x-h264,
    stream-format=byte-stream,
    alignment=au,
    profile=constrained-baseline
  !
  h264parse
    config-interval=-1
  !
  fdsink fd=1 sync=false
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

    local port="${ADB_STREAM_PORT:-7878}"

    # Kill any stale gst-launch or socat processes from previous sessions
    pkill -f "gst-launch.*fdsink" 2>/dev/null || true
    pkill -f "socat.*TCP.*${port}" 2>/dev/null || true
    sleep 0.2

    # Use a named pipe to decouple gst-launch and socat so we can track both PIDs.
    local fifo
    fifo=$(mktemp -u /tmp/nativesunshine-pipe-XXXX)
    mkfifo "$fifo"

    # Start gst-launch writing into the named pipe
    "${gst_bin}" -e ${PIPELINE_LOG:+--gst-debug-level=2} \
        ${pipeline_oneline} \
        2>>"$log" >"$fifo" &
    export GST_PID=$!

    # Start socat reading from the pipe and forwarding to Android
    socat - "TCP:127.0.0.1:${port},nodelay" <"$fifo" &
    export PIPELINE_PID=$!

    # Clean up the fifo path (the pipe stays open via FDs)
    rm -f "$fifo"

    # Give it a moment to fail fast (bad plugin, wrong node ID, etc.)
    sleep 1

    if ! kill -0 "${PIPELINE_PID}" 2>/dev/null && ! kill -0 "${GST_PID}" 2>/dev/null; then
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
    local gst_pid="${GST_PID:-}"

    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        # Also check gst_pid
        if [[ -z "$gst_pid" ]] || ! kill -0 "$gst_pid" 2>/dev/null; then
            log_info "Pipeline not running, nothing to stop."
            return 0
        fi
    fi

    log_step "Stopping GStreamer pipeline (PID: ${pid})"

    # SIGINT → gst-launch-1.0 sends EOS and flushes
    kill -SIGINT "$pid" 2>/dev/null || true
    [[ -n "$gst_pid" ]] && kill -SIGINT "$gst_pid" 2>/dev/null || true

    # Also kill any remaining gst-launch or socat by name (belt-and-suspenders)
    pkill -f "gst-launch.*fdsink" 2>/dev/null || true

    # Wait up to 5 seconds for clean exit
    local i=0
    while { kill -0 "$pid" 2>/dev/null || { [[ -n "$gst_pid" ]] && kill -0 "$gst_pid" 2>/dev/null; }; } && [[ $i -lt 5 ]]; do
        sleep 1
        (( ++i )) || true
    done

    # Force kill if still alive
    kill -SIGKILL "$pid" 2>/dev/null || true
    [[ -n "$gst_pid" ]] && kill -SIGKILL "$gst_pid" 2>/dev/null || true

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