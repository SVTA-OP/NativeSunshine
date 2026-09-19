# Host-Side Files — `lib/` and root scripts

All files are on the Linux host. They capture the virtual display, encode it as H.264, and push it over the ADB USB tunnel.

---

## `config.sh`

**Role:** Single source of truth for all tunable values. Sourced by `native-sunshine.sh` before anything else. Also reads overrides from `~/.config/native-sunshine/config.json` (written by `control_server.py` when Android sends settings).

**Variables:**

| Variable | Default | Meaning |
|----------|---------|---------|
| `TARGET_WIDTH` | 800 | Horizontal resolution of virtual monitor (also encoder output width) |
| `TARGET_HEIGHT` | 1340 | Vertical resolution. Gets overridden at runtime by `adb.sh` after querying device |
| `TARGET_REFRESH` | 120 | FPS limit (dynamic up to 120). |
| `ENCODER` | vulkan | Which GStreamer encoder to use: `vulkan`, `vaapi`, `nvenc`, `software` |
| `STREAM_BITRATE` | 8000 | H.264 target bitrate in kbps |
| `KEYFRAME_INTERVAL` | 60 | IDR period in frames. Low = fast recovery after frame drops but slightly bigger stream |
| `RESOLUTION_SCALE` | 100 | Scale factor (50–100). 80 means encode at 80% of native resolution |
| `PLACEMENT` | right | Where to put virtual monitor relative to primary: `left`, `right`, `above`, `below` |
| `ADB_STREAM_PORT` | 7878 | TCP port for video. Must match Android's `ServerSocket` port |
| `ADB_WAIT_TIMEOUT` | 30 | Seconds to wait for ADB device before aborting |
| `VAAPI_DEVICE` | /dev/dri/renderD128 | GPU render node (VAAPI encoder only) |
| `GST_LAUNCH_BIN` | gst-launch-1.0 | Path to gst-launch binary |
| `TARGET_DISPLAY` | virtual | `virtual` = auto-detect virtual monitor; otherwise a connector name like `HDMI-A-1` |

**How GUI overrides work:** config.sh reads `~/.config/native-sunshine/config.json` with inline Python one-liners. If the file does not exist, defaults apply. The file is written by `control_server.py`.

---

## `native-sunshine.sh`

**Role:** Master orchestrator. Sources config + all lib modules. Runs 5 setup steps sequentially, then waits for the pipeline to die or a signal.

**Execution flow:**
```
1. Parse --dry-run / --check / --help flags
2. source config.sh, lib/utils.sh, lib/display.sh, lib/adb.sh, lib/pipeline.sh
3. setup_logging()       — rotate log file if >5 MB
4. setup_traps()         — register INT/TERM/EXIT → teardown()
5. check_deps()          — verify all binaries and GStreamer elements exist
6. wait_for_adb_device() — poll until authorized USB device appears
7. check_adb_usb()       — warn if device serial looks like a TCP address
8. get_device_info()     — log brand/model/SDK, abort if SDK < 23
9. get_client_display_metrics() — query wm size + orientation → set TARGET_WIDTH/HEIGHT
10. check_app_installed() — warn if APK not found (non-fatal)
11. setup_adb_forward()  — adb forward tcp:7878 tcp:7878 + adb reverse tcp:7879 tcp:7879
12. verify_virtual_display() — set VIRT_DISPLAY_NAME
13. placement_manager.py PLACEMENT — reposition virtual monitor
14. get_pipewire_node_id() → VIRT_PW_NODE_ID
15. build_pipeline_string(VIRT_PW_NODE_ID, PORT) → PIPELINE_STR
16. launch_app_on_device()  — adb shell am start MainActivity (non-fatal)
17. launch_pipeline(PIPELINE_STR)  — gst-launch + socat via named pipe
18. print_stream_info()
19. Start control_server.py in background
20. Start watch_client_orientation in background
21. wait $PIPELINE_PID
```

**SIGUSR1 handling (`restart_pipeline`):**
- Triggered by `control_server.py` (settings change) or `watch_client_orientation` (rotation change)
- Disables all traps, stops pipeline, does `exec "$0" "$@"` — replaces self entirely so config.sh re-reads the JSON

**teardown():**
- Calls `stop_pipeline`
- Runs `placement_manager.py disable` to hide virtual monitor from GNOME
- Kills `control_server.py`, `mutter_record_virtual.py`, orientation watcher
- Calls `teardown_adb_forward`

---

## `lib/utils.sh`

**Role:** Logging helpers, dependency checker, signal trap setup. Sourced first.

**Key functions:**

### `log_info / log_warn / log_error / log_success / log_step`
- All output to stdout (stderr for errors) AND append to `$LOG_FILE`
- Color-coded when stdout is a terminal; plain text otherwise
- Format: `[LEVEL]  YYYY-MM-DD HH:MM:SS  message`

### `check_deps()`
- Checks binaries: `adb`, `gst-launch-1.0`, `gst-inspect-1.0`, `pw-dump`, `jq`, `gdbus`
- Checks GStreamer elements based on `$ENCODER`:
  - `vulkan`: `pipewiresrc`, `vulkanh264enc`, `vulkanupload`, `videoconvert`, `tcpclientsink`, `h264parse`, `queue`, `videorate`
  - `vaapi`: `pipewiresrc`, `vah264enc`, `vapostproc`, etc.
  - `nvenc`: `pipewiresrc`, `nvh264enc`
  - `software`: `pipewiresrc`, `x264enc`
- Populates `MISSING_DEPS` array

### `setup_traps()`
- Registers `_ns_trap_handler` for INT, TERM, EXIT
- `_ns_trap_handler` checks `_NS_TEARDOWN_CALLED` flag (prevents double-teardown)
- Calls main script's `teardown()` function

### `setup_logging()`
- Creates `$LOG_DIR`, rotates `$LOG_FILE` if >5 MB to `.old`

---

## `lib/adb.sh`

**Role:** Everything ADB: device detection, USB vs TCP check, device info, metrics, port forwarding, app launch.

### `wait_for_adb_device()`
- Polls `adb devices` every 1 second up to `$ADB_WAIT_TIMEOUT` seconds
- Sets `ADB_SERIAL` to first authorized device serial
- Handles UNAUTHORIZED state: prints "accept the prompt" message every 5s

### `check_adb_usb()`
- Warns if `ADB_SERIAL` looks like `IP:PORT` (TCP/IP ADB instead of USB)
- Not fatal — WiFi ADB works but has higher latency

### `get_device_info()`
- Queries `ro.product.model`, `ro.product.brand`, `ro.build.version.sdk`
- Fatal if SDK < 23 (API level 23 = Android 6.0 is the minimum)

### `get_client_display_metrics()`
- Runs `adb shell wm size` → parses `Physical size: WxH`
- Runs `adb shell dumpsys input | grep SurfaceOrientation` → if orientation is 1 or 3 (landscape), swaps W and H
- Sets `TARGET_WIDTH` and `TARGET_HEIGHT` (exports)
- Gets refresh rate from `adb shell dumpsys display | grep -iE 'refresh|fps'`
- **Caps `TARGET_REFRESH` at 120 Hz**

### `watch_client_orientation()`
- Background loop, polls orientation every 2 seconds
- On change: sends `SIGUSR1` to main PID → triggers pipeline restart with new dimensions

### `setup_adb_forward()`
- `adb forward tcp:7878 tcp:7878` — video stream (host→device)
- `adb reverse tcp:7879 tcp:7879` — control channel (device→host)
- Verifies with `adb forward --list`

### `teardown_adb_forward()`
- `adb forward --remove-all` + `adb reverse --remove-all`
- Safe to call even if no forwards exist

### `check_app_installed()`
- `adb shell pm list packages | grep dev.nativesunshine`
- Non-fatal: logs how to install if missing

### `launch_app_on_device()`
- `adb shell am start -n dev.nativesunshine/.MainActivity --activity-clear-top`
- Non-fatal

---

## `lib/display.sh`

**Role:** Finds the virtual monitor's connector name and starts the Mutter ScreenCast session to get the PipeWire node ID.

### `verify_virtual_display()`
- Currently just sets `VIRT_DISPLAY_NAME` based on `TARGET_DISPLAY`
- Marked deprecated (was once the main function, now just sets a name)

### `get_pipewire_node_id()`
- If `TARGET_DISPLAY == virtual`: uses inline Python to call `org.gnome.Mutter.DisplayConfig.GetCurrentState()` and find a connector containing "Virtual", "HEADLESS", or "Meta"
- Calls `_get_pw_node_headless(connector)` with the found connector

### `_get_pw_node_headless(connector)`
- Launches `lib/mutter_record_virtual.py <connector>` in background, saves PID as `MUTTER_SCREENCAST_PID`
- The Python script starts a Mutter ScreenCast session — **this process must stay alive** for the ScreenCast to keep streaming
- Polls `/tmp/ns_mutter_out` for up to 5 seconds (50 × 100ms sleeps) for a numeric node ID
- Exports `VIRT_PW_NODE_ID`

**CRITICAL:** `mutter_record_virtual.py` is NOT killed after getting the node ID. It runs the GLib main loop indefinitely. Killing it would stop the PipeWire stream. It's explicitly killed in `teardown()`.

---

## `lib/mutter_record_virtual.py`

**Role:** Starts a `org.gnome.Mutter.ScreenCast` session for a specific monitor connector and emits the PipeWire node ID to stdout. Keeps the session alive by running the GLib main loop.

**Flow:**
```python
1. ConnectSession: bus.get_object('org.gnome.Mutter.ScreenCast', ...)
2. CreateSession({})  → session_path
3. session.RecordMonitor(connector, {'cursor-mode': 1})  → stream_path
4. stream.connect_to_signal("PipeWireStreamAdded", on_stream_added)
5. session.Start()
6. GLib.MainLoop().run()   ← NEVER exits normally
```

When `PipeWireStreamAdded` fires:
- Prints node_id to stdout
- `display.sh` reads this from `/tmp/ns_mutter_out`

**cursor-mode = 1** means cursor is included in the capture.

---

## `lib/portal_screencast.py`

**Role:** Alternative screencast path using the XDG Desktop Portal (for sandboxed environments). **Not currently used** in the main flow — `mutter_record_virtual.py` is used instead because it supports specifying an exact connector (headless virtual monitor), whereas the Portal shows a picker dialog.

**Flow:**
```
CreateSession → SelectSources(types=1=MONITOR, multiple=false)
→ user picks a monitor in the portal dialog
→ Start → PipeWireStreamAdded → print NODE_ID:n
```

Use this if you need to work in a sandboxed GNOME environment or if direct Mutter D-Bus access is unavailable.

---

## `lib/pipeline.sh`

**Role:** Builds GStreamer pipeline strings for each encoder, launches the pipeline as two processes (gst-launch + socat) via a named FIFO, and manages their lifecycle.

### Pipeline builders

All four builders share the same structure:
```
pipewiresrc path=NODE_ID do-timestamp=true
→ color conversion
→ videoscale + videorate  (resize to TARGET_WIDTH×TARGET_HEIGHT at TARGET_REFRESH fps)
→ queue (max 2 buffers, leaky=downstream — drop old frames, never block encoder)
→ [GPU/CPU H.264 encoder]
→ video/x-h264, stream-format=byte-stream, alignment=au, profile=constrained-baseline
→ h264parse config-interval=-1  (inline SPS/PPS in every IDR)
→ fdsink fd=1  (write to stdout = named FIFO)
```

**`config-interval=-1`** is critical: it means SPS/PPS are prepended to every IDR frame. This allows the Android decoder to initialize `MediaCodec` without needing out-of-band `BUFFER_FLAG_CODEC_CONFIG` data.

#### `_build_vulkan_pipeline` (default, AMD RADV)
- `vulkanupload` (CPU→GPU memory) → `vulkanh264enc` (Vulkan Video extension)
- Properties: `rate-control=cbr`, `idr-period=N`, `b-frames=0`, `quality=1` (fastest), `aud=false`
- **Known issue:** RADV `vulkanh264enc` can produce green/corrupted frames on heights that aren't 32-aligned. If this occurs, fall back to `vaapi` — do NOT re-add alignment math since it introduces a host/decoder size mismatch.

#### `_build_vaapi_pipeline` (Intel/AMD VA-API)
- `vapostproc` → `vah264enc`
- Properties: `target-usage=7` (fastest), `ref-frames=1`, `b-frames=0`

#### `_build_nvenc_pipeline` (NVIDIA)
- `nvh264enc` with `preset=low-latency-hq`, `zerolatency=true`, `rc-mode=cbr`

#### `_build_software_pipeline` (CPU fallback)
- `x264enc` with `tune=zerolatency`, `speed-preset=ultrafast`, `sliced-threads=true`
- High CPU usage; use only when no GPU encoder is available

### `build_pipeline_string(node_id, port)`
- Selects encoder based on `$ENCODER`
- Applies `RESOLUTION_SCALE` if < 100 (rounds new dimensions to even numbers)
- Caps fps to 120 before calling the encoder builder

### `launch_pipeline(pipeline_string)`
```bash
mkfifo /tmp/nativesunshine-pipe-XXXX
gst-launch-1.0 -e PIPELINE ... > fifo &   # GST_PID
socat - TCP:127.0.0.1:7878,nodelay < fifo &  # PIPELINE_PID
rm -f fifo   # path removed but FDs stay open
sleep 1  # fast-fail: if both PIDs already dead, something is wrong
```
- Kills stale `gst-launch.*fdsink` and `socat.*TCP.*7878` before starting
- Returns failure if both processes die within 1 second of start

### `stop_pipeline(pid)`
- SIGINT first (triggers EOS flush in gst-launch)
- Waits up to 5 seconds
- SIGKILL if still alive
- Also runs `pkill -f "gst-launch.*fdsink"` (belt-and-suspenders)

---

## `lib/control_server.py`

**Role:** TCP server on port 7879 (host side). Receives JSON messages from the Android app and updates the config + triggers pipeline restart.

**Config file:** `~/.config/native-sunshine/config.json`

**Accepted messages:**
```json
{"fps": 30, "bitrate": 4000}
{"error": "Codec setup failed: ..."}
```

**On settings change:**
1. Reads current `config.json`
2. Checks if value actually changed (avoids spurious restarts)
3. Writes updated `config.json`
4. `os.kill(parent_pid, signal.SIGUSR1)`

**On error from Android:**
- Just prints it. Does not restart.

**kill_port(7879):** On startup, kills any process holding 7879 with `fuser -k` to avoid "address already in use".

---

## `lib/placement_manager.py`

**Role:** Repositions the virtual monitor in the GNOME display layout by calling `org.gnome.Mutter.DisplayConfig.ApplyMonitorsConfig`.

**Arguments:** `left | right | above | below | disable`

**Logic for `right` (default):**
```
nx = primary_x + primary_logical_width
ny = primary_y
```

**Logic for `disable`:**
- Removes virtual monitor from logical monitors list
- Normalizes remaining monitors so bounding box starts at (0, 0) (GNOME requires this)

**Critical detail:** `ApplyMonitorsConfig` signature is `(serial, method, logical_monitors, properties)`. The `method=1` means "apply persistently". Each logical monitor entry is `(x, y, scale, transform, is_primary, linked_connectors)`. The linked connector is `(connector_string, mode_id_string, {})`. Mode ID must be the currently active or preferred mode — fetched via `get_active_mode_id_and_size()`.

**Common failure:** "Failed to apply monitor config" — usually means the serial is stale (another DisplayConfig call happened). Just retry.

---

## `lib/check_monitors.py`

**Role:** Debug tool. Dumps raw Mutter DisplayConfig state — physical monitors and logical monitors — to stdout.

**When to use:** When you're not sure what connectors are available, what mode IDs look like, or why `placement_manager.py` is failing.

```bash
python3 lib/check_monitors.py
```

---

## `lib/get_displays.py`

**Role:** Parses connector/vendor/product information from `gdbus call` to `org.gnome.Mutter.DisplayConfig.GetCurrentState`. Used by the GUI (`native-sunshine-gui.py`) to populate the display selector dropdown.

**Output format (stdout):**
```
Virtual-1|Unknown Unknown
HDMI-A-1|Samsung ODYSSEY
```

---

## `native-sunshine-gui.py`

**Role:** Graphical frontend (GTK). Allows selecting encoder, bitrate, FPS, resolution scale, placement, and display. Writes to `~/.config/native-sunshine/config.json` and launches `native-sunshine.sh` as a subprocess.

Not documented in depth here since the shell + library files are the core of the streaming engine.

---

## `tui.sh`

**Role:** Terminal-based interactive UI using `whiptail` or `dialog`. Presents the same settings as the GUI. Not part of the streaming engine itself.
