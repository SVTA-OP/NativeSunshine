# Config Reference

All variables live in `config.sh` and are overridden by `~/.config/native-sunshine/config.json` (written by `control_server.py` when Android sends settings).

## `config.sh` variables

### Display

| Variable | Default | Allowed | Notes |
|----------|---------|---------|-------|
| `TARGET_WIDTH` | `800` | any positive int | Initial guess; overridden at runtime by `get_client_display_metrics()` |
| `TARGET_HEIGHT` | `1340` | any positive int | Same — overridden after querying device `wm size` |
| `TARGET_REFRESH` | `120` | 1–120 | **Hard cap at 120**. Values above 120 are clamped in `build_pipeline_string()` and `get_client_display_metrics()` |
| `TARGET_DISPLAY` | `virtual` | `virtual` or connector name | `virtual` = auto-detect. Anything else is passed directly to `RecordMonitor()` |
| `PLACEMENT` | `right` | `left right above below` | Where the virtual monitor is placed relative to primary in GNOME layout |

### Encoding

| Variable | Default | Allowed | Notes |
|----------|---------|---------|-------|
| `ENCODER` | `vulkan` | `vulkan vaapi nvenc software` | See encoder notes below |
| `STREAM_BITRATE` | `8000` | kbps, e.g. 2000–20000 | CBR target. 8 Mbps is a good balance for 800×1340@60 |
| `KEYFRAME_INTERVAL` | `60` | frames | IDR every N frames. 60 @ 60fps = IDR every 1s. Low = fast recovery after frame drops but slightly bigger stream |
| `RESOLUTION_SCALE` | `100` | 50–100 | Scale down resolution before encoding. 80 = encode at 80% size |

### Encoder selection guide

| Encoder | GPU required | GStreamer package | Notes |
|---------|-------------|-----------------|-------|
| `vulkan` | AMD (RADV) | `gst-plugins-bad` with Vulkan | Recommended on Arch AMD. May produce green frames on heights not 32-aligned |
| `vaapi` | AMD or Intel | `gst-plugin-va` or `gstreamer-vaapi` | Stable, widely supported |
| `nvenc` | NVIDIA | `gstreamer1.0-plugins-bad` (nvcodec) | Lowest latency on NVIDIA |
| `software` | None | `gstreamer1.0-plugins-ugly` | CPU x264, high CPU use, last resort |

### ADB / Transport

| Variable | Default | Notes |
|----------|---------|-------|
| `ADB_BIN` | `adb` | Full path to adb binary if not in PATH |
| `ADB_STREAM_PORT` | `7878` | Video stream TCP port. Must match Android `SocketReader` port |
| `ADB_WAIT_TIMEOUT` | `30` | Seconds to wait for ADB device before aborting |

Control channel is always port `7879` — hardcoded in `adb.sh` and `control_server.py`.

### Paths

| Variable | Default |
|----------|---------|
| `LOG_DIR` | `~/.local/log` |
| `LOG_FILE` | `~/.local/log/native-sunshine.log` |
| `PIPELINE_LOG` | `~/.local/log/native-sunshine-pipeline.log` |
| `GST_LAUNCH_BIN` | `gst-launch-1.0` |
| `VAAPI_DEVICE` | `/dev/dri/renderD128` |

---

## `~/.config/native-sunshine/config.json`

Written by `control_server.py`. Read by `config.sh` at startup.

```json
{
    "encoder": "vulkan",
    "bitrate": 8000,
    "framerate": 120,
    "keyframe_interval": 300,
    "resolution_scale": 100,
    "placement": "right"
}
```

`framerate: 0` means "use device native refresh rate" (falls through to `TARGET_REFRESH` from `get_client_display_metrics`).

---

## Android SharedPreferences

Set via the in-app Settings screen. Read by `ReceiverService.sendControlMessage()` at connect time.

| Key | Default | Meaning |
|-----|---------|---------|
| `stream_port` | `"7878"` | TCP port to bind `ServerSocket` on |
| `host_fps` | `"120"` | FPS to request from host (sent over control channel) |
| `host_bitrate` | `"8000"` | Bitrate in kbps to request from host |

Values sent in `{"fps": N, "bitrate": M}` JSON to `control_server.py`.
