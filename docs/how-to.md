# How-To Recipes

Common operations, step by step.

---

## Start streaming

```bash
cd ~/Repos/NativeSunshine
./native-sunshine.sh
```

Prerequisites:
- Android device connected via USB-C
- USB Debugging enabled (Settings → Developer Options)
- NativeSunshine APK installed and open on the device
- GNOME Shell started with `--virtual-monitor 800x1340` (systemd override)

---

## Dry-run (check config without streaming)

```bash
./native-sunshine.sh --dry-run
```

Prints all computed config values, ADB device list, and PipeWire video sources. Makes no system changes.

---

## Check dependencies only

```bash
./native-sunshine.sh --check
```

---

## Change encoder

Edit `config.sh`:
```bash
ENCODER=vaapi   # vulkan | vaapi | nvenc | software
```

Or change via the GUI / Android settings (writes `~/.config/native-sunshine/config.json`).

---

## Change bitrate or FPS from Android

1. Open NativeSunshine app → ⚙ Settings
2. Set "Host FPS" and "Host Bitrate"
3. Close Settings — settings are sent automatically on next connection

Or manually send JSON to port 7879 from host:
```bash
echo '{"fps":30,"bitrate":4000}' | nc 127.0.0.1 7879
```
This will trigger `SIGUSR1` → pipeline restart with new values.

---

## Move virtual monitor position

```bash
python3 lib/placement_manager.py right   # right of primary
python3 lib/placement_manager.py left
python3 lib/placement_manager.py above
python3 lib/placement_manager.py below
python3 lib/placement_manager.py disable  # hide from GNOME layout
```

Also configurable via `PLACEMENT=right` in `config.sh` (applied at stream start).

---

## Inspect current monitor layout (debug)

```bash
python3 lib/check_monitors.py
```

Shows all physical connectors and logical monitor positions from Mutter DisplayConfig.

---

## List PipeWire video sources (debug)

```bash
pw-dump | jq '.[] | select(.type == "PipeWire:Interface:Node") | select(.info.props["media.class"] // "" | test("Video/Source"; "i")) | {id: .id, desc: .info.props["node.description"]}'
```

---

## Manually get PipeWire node ID for a connector

```bash
python3 lib/mutter_record_virtual.py Virtual-1
# prints node_id to stdout, then runs GLib main loop
# Ctrl+C to stop
```

---

## Build and install Android APK

```bash
cd android/NativeSunshine
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

`-r` reinstalls over existing app, preserving data.

---

## Read Android logs for the streaming pipeline

```bash
adb logcat -s NS:SocketReader NS:StreamDecoder NS:ReceiverService
```

Add `-v time` for timestamps:
```bash
adb logcat -v time -s NS:SocketReader NS:StreamDecoder NS:ReceiverService
```

---

## Diagnose a frozen stream

1. Check Android stats overlay (FPS/Mbps/Latency)
2. Check logcat for dropped frames:
   ```bash
   adb logcat -s NS:StreamDecoder | grep -E "Stats:|dropped|error"
   ```
3. Check GStreamer pipeline log:
   ```bash
   tail -f ~/.local/log/native-sunshine-pipeline.log
   ```
4. Check if pipeline processes are alive:
   ```bash
   ps aux | grep -E "gst-launch|socat"
   ```

---

## Force restart the pipeline without disconnecting

Send SIGUSR1 to the main script:
```bash
kill -SIGUSR1 $(pgrep -f native-sunshine.sh)
```

This triggers `restart_pipeline()` — stops and re-launches gst-launch + socat, re-reads config.

---

## Reduce latency

1. Lower bitrate (less USB bandwidth contention): `STREAM_BITRATE=4000`
2. Lower keyframe interval (faster decoder init on reconnect): `KEYFRAME_INTERVAL=60`
3. Use hardware encoder: `ENCODER=vulkan` or `ENCODER=vaapi` instead of `software`
4. Confirm `tcpNoDelay = true` in `SocketReader.kt` (it is by default)
5. Ensure USB 3.x cable — USB 2.0 throughput limit is ~480 Mbps but with ADB overhead, effective is lower

---

## Add resolution scale (reduce CPU/GPU load)

```bash
RESOLUTION_SCALE=80   # encode at 80% of native resolution
```

This sets `TARGET_WIDTH` and `TARGET_HEIGHT` to 80% of device-detected values inside `build_pipeline_string()`. Dimensions are rounded up to even numbers (H.264 requirement).

---

## Run on a non-virtual (real) display

Set `TARGET_DISPLAY` to the connector name of a real monitor:
```bash
TARGET_DISPLAY=HDMI-A-1
```

Then in `display.sh`, `get_pipewire_node_id()` will call `RecordMonitor("HDMI-A-1", ...)` instead of searching for a virtual connector.

---

## Use the XDG Portal path instead of Mutter ScreenCast

For sandboxed GNOME environments where `org.gnome.Mutter.ScreenCast` is not directly accessible:

```bash
python3 lib/portal_screencast.py
# A system dialog will appear asking you to select a screen to share
# On selection: prints NODE_ID:N to stdout
```

Then use the printed node ID manually in the pipeline. Integration with `native-sunshine.sh` for the portal path is not currently implemented.

---

## Wipe and reset config

```bash
rm ~/.config/native-sunshine/config.json
# Defaults from config.sh will be used on next run
```

---

## Check what ADB forwards are active

```bash
adb forward --list
adb reverse --list
```

Expected output when streaming:
```
SERIAL tcp:7878 tcp:7878
SERIAL tcp:7879 tcp:7879
```

---

## Clear all ADB forwards

```bash
adb forward --remove-all
adb reverse --remove-all
```
