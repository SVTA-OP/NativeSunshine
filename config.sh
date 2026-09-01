#!/usr/bin/env bash
# =============================================================================
# NativeSunshine — User Configuration
# Edit this file to match your system. All other scripts source this file.
# =============================================================================

# -----------------------------------------------------------------------------
# Virtual Display
# Target resolution and refresh rate for the virtual monitor.
# -----------------------------------------------------------------------------
TARGET_WIDTH=800
TARGET_HEIGHT=1340
TARGET_REFRESH=120

# -----------------------------------------------------------------------------
# Encoding
# Hardware encoder to use: vulkan | vaapi | nvenc | software
# vulkan: AMD GPU via Vulkan Video (RADV) — recommended for Arch Linux AMD
# vaapi:  AMD/Intel GPU via VA-API (install gstreamer-vaapi)
# nvenc:  NVIDIA GPU
# software: CPU-only libx264 (fallback, high CPU usage)
# -----------------------------------------------------------------------------
ENCODER=vulkan
STREAM_BITRATE=8000
KEYFRAME_INTERVAL=60
PLACEMENT="right"

# Try to load overrides from the GUI config
GUI_CONFIG="${HOME}/.config/native-sunshine/config.json"
if [[ -f "$GUI_CONFIG" ]]; then
    ENCODER=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('encoder', 'vulkan'))" "$GUI_CONFIG")
    STREAM_BITRATE=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('bitrate', 8000))" "$GUI_CONFIG")
    GUI_FRAMERATE=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('framerate', 0))" "$GUI_CONFIG")
    KEYFRAME_INTERVAL=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('keyframe_interval', 60))" "$GUI_CONFIG")
    PLACEMENT=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('placement', 'right'))" "$GUI_CONFIG")
fi

# VAAPI render node — check with: ls /dev/dri/renderD*
VAAPI_DEVICE=/dev/dri/renderD128

# -----------------------------------------------------------------------------
# ADB / Transport
# -----------------------------------------------------------------------------
ADB_BIN=adb

# TCP port used for the ADB socket tunnel.
# Must match the port the Android app listens on.
ADB_STREAM_PORT=7878

# Seconds to wait for an ADB device to appear before aborting.
ADB_WAIT_TIMEOUT=30

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
LOG_DIR="${HOME}/.local/log"
LOG_FILE="${LOG_DIR}/native-sunshine.log"
PIPELINE_LOG="${LOG_DIR}/native-sunshine-pipeline.log"

# Optional: explicit path to gst-launch-1.0 binary
GST_LAUNCH_BIN=gst-launch-1.0
TARGET_DISPLAY=virtual
