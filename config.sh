#!/usr/bin/env bash
# =============================================================================
# NativeSunshine — User Configuration
# Edit this file to match your system. All other scripts source this file.
# =============================================================================

# -----------------------------------------------------------------------------
# Virtual Display
# Must match the --virtual-monitor argument in your GNOME Shell systemd override:
# ~/.config/systemd/user/org.gnome.Shell@user.service.d/persistent-virtual-monitor.conf
# -----------------------------------------------------------------------------
TARGET_WIDTH=800
TARGET_HEIGHT=1340
TARGET_REFRESH=60

# -----------------------------------------------------------------------------
# Encoding
# Hardware encoder to use: vulkan | vaapi | nvenc | software
# vulkan: AMD GPU via Vulkan Video (RADV) — recommended for Arch Linux AMD
# vaapi:  AMD/Intel GPU via VA-API (install gstreamer-vaapi)
# nvenc:  NVIDIA GPU
# software: CPU-only libx264 (fallback, high CPU usage)
# -----------------------------------------------------------------------------
ENCODER=vulkan

# VAAPI render node — check with: ls /dev/dri/renderD*
VAAPI_DEVICE=/dev/dri/renderD128

# H.264 bitrate in kbps. 8000 = 8 Mbps (well within USB ADB throughput).
# Increase for higher quality; decrease if ADB throughput is saturated.
STREAM_BITRATE=8000

# H.264 keyframe interval in frames (1 second at 60fps = 60 frames).
# Lower = faster seek/recovery, slightly higher bandwidth.
KEYFRAME_INTERVAL=60

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
