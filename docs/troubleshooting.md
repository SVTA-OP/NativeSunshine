# Troubleshooting

Known bugs, failure modes, and how to diagnose them.

---

## 120Hz panel freeze (CRITICAL — known bug)

**Symptom:** Stream plays for a few seconds then freezes. Android logs show `MediaCodec` output buffers being dropped. May also manifest as the app becoming unresponsive.

**Root cause:** On 120Hz panels (e.g. Samsung Galaxy Tab A7 Lite's MTK decoder), running `SurfaceFlinger` at 120Hz exhausts the `MediaCodec` buffer pool. The decoder keeps dequeuing output buffers but SurfaceFlinger doesn't consume them fast enough, causing a backlog that starves the codec.

**Fix (already applied):**
**GSI Decoder Problem:** On some GSI ROMs or devices (e.g. MediaTek Helio P22T), the hardware decoder physically cannot sustain decoding 120fps video at high resolutions (throwing QMU_ERR inside the MediaCodec loop). If you experience freezes or crashes during stream playback:
1. Try capping the FPS to 60 in the Android app settings.
2. Check `adb logcat` for MediaCodec buffer exhaustion or firmware crashes.

---

## vulkanh264enc green / corrupted frames

**Symptom:** Half the frame or the entire frame is green, or there are corrupt macroblocks.

**Root cause:** RADV `vulkanh264enc` has a bug with heights that are not 32-aligned. `1340 % 32 = 28`, so 1340 is not 32-aligned and triggers the bug.

**Fix:** Switch encoder to `vaapi` or `software` in `config.sh`:
```bash
ENCODER=vaapi
```

**Do NOT** re-add height alignment math (`h = (h / 32) * 32 * 2`) because aligning the encoder height creates a mismatch between what the SPS signals (true display size) and what the Android decoder expects, causing Android to configure `MediaCodec` with wrong dimensions.

---

## "No virtual monitor found" / empty PipeWire node

**Symptom:** `display.sh` → `get_pipewire_node_id()` exits with "Could not find Virtual Monitor in PipeWire."

**Diagnosis:**
```bash
python3 lib/check_monitors.py
```
Look for a connector with "Virtual", "HEADLESS", or "Meta" in the name.

**Causes and fixes:**

1. **Virtual monitor not created:** The GNOME Shell systemd override with `--virtual-monitor 800x1340` isn't active.
   ```bash
   systemctl --user status org.gnome.Shell@wayland.service
   # Look for --virtual-monitor in ExecStart
   ```

2. **Wrong connector name:** `TARGET_DISPLAY=virtual` will search for "Virtual", "HEADLESS", or "Meta". If Mutter names it something else, set `TARGET_DISPLAY` to the exact connector name shown in `check_monitors.py`.

3. **Mutter ScreenCast not responding:** Try restarting GNOME Shell:
   ```bash
   busctl --user call org.gnome.Shell /org/gnome/Shell org.gnome.Shell Eval s "global.reexec_self()"
   ```

---

## ADB forward fails after reconnect

**Symptom:** "Failed to set up ADB forward on port 7878" even though device is connected.

**Fix:**
```bash
adb kill-server
adb start-server
adb devices  # confirm device appears as "device" not "unauthorized"
```

**If still failing:**
```bash
adb forward --remove-all
adb reverse --remove-all
# Then re-run native-sunshine.sh
```

---

## Pipeline exits immediately

**Symptom:** `launch_pipeline()` reports "GStreamer pipeline exited immediately."

**Check the pipeline log:**
```bash
tail -100 ~/.local/log/native-sunshine-pipeline.log
```

**Common causes:**

| Log message | Fix |
|-------------|-----|
| `Could not open device` | VAAPI_DEVICE wrong. Check `ls /dev/dri/render*` |
| `No such element: vulkanh264enc` | Install `gst-plugins-bad` with Vulkan support |
| `Failed to link elements` | Caps negotiation failure — try a different encoder |
| `Could not open source node` | Wrong PipeWire node ID. Run `pw-dump \| jq '.[] \| select(.type == "PipeWire:Interface:Node") \| select(.info.props["media.class"] // "" \| test("Video/Source"; "i"))'` |
| `connection refused` / socat error | Android `ServerSocket` not listening on 7878. Ensure app is open and ADB forward is active |

---

## "Cannot bind port 7878" on Android

**Symptom:** Android logcat shows `SocketReader: Failed to bind port 7878`.

**Cause:** Another process on the device is already bound to 7878, OR the app didn't clean up after a crash.

**Fix:** Force-stop the app via Android settings, then reopen. Or:
```bash
adb shell am force-stop dev.nativesunshine
adb shell am start -n dev.nativesunshine/.MainActivity
```

---

## Codec setup failed / "No valid display surface"

**Symptom:** Android shows "Codec setup failed" error overlay.

**Diagnosis:**
```bash
adb logcat -s NS:StreamDecoder
```

**Common causes:**

| Log | Cause |
|-----|-------|
| `SPS parse failed` | SPS NAL is corrupted or incomplete chunk. Usually transient — retry |
| `Could not parse SPS dimensions` | High-profile SPS received (unexpected). Ensure host encoder uses `profile=constrained-baseline` |
| `Codec setup failed: null` | MediaCodec returned null decoder. Check if `findH264Decoder()` fell back to software |
| `surface is null or invalid` | Race between `surfaceDestroyed` and `onConnected`. Should self-heal on next connection |

---

## High latency (>100ms)

**Expected latency:** 10–30ms over USB.

**Diagnose:** Watch the stats overlay on Android (FPS / Mbps / Latency).

**Causes:**

1. **Congested dataQueue:** If `droppedPacing` count climbs in logcat, the decoder is behind. The USB bandwidth may be saturated — lower `STREAM_BITRATE`.

2. **Nagle algorithm:** Ensure `tcpNoDelay = true` is set in `SocketReader`. It is by default.

3. **Keyframe interval too long:** If a reconnect happened, the decoder must wait for an IDR. Lower `KEYFRAME_INTERVAL` in `config.sh` (e.g. to 60).

4. **socat buffer:** The `sndbuf=32768,rcvbuf=32768` in `pipeline.sh` already limits TCP socket buffers. Do not increase these.

---

## Orientation change doesn't restart

**Symptom:** Device is rotated but stream stays in wrong orientation.

**Check:**
```bash
adb shell dumpsys input | grep SurfaceOrientation
```

The `watch_client_orientation` loop in `adb.sh` polls this every 2 seconds. If the PID for this background loop was killed, it won't restart automatically. Check `$ORIENTATION_WATCHER_PID` is alive.

---

## control_server.py "Address already in use"

**Symptom:** Python traceback "OSError: [Errno 98] Address already in use" for port 7879.

**Fix:** `control_server.py` calls `kill_port(7879)` (via `fuser -k`) on startup, but this may fail if `fuser` is not installed.

```bash
fuser -k 7879/tcp
# or
lsof -i :7879
kill <PID>
```

---

## Virtual monitor not appearing in GNOME display settings after teardown

**Symptom:** After stopping native-sunshine.sh, the virtual monitor is still shown in GNOME display settings as active.

**Cause:** `placement_manager.py disable` failed during teardown.

**Fix:**
```bash
python3 lib/placement_manager.py disable
```

---

## "Applied virtual monitor placement" but monitor is in wrong position

**Cause:** The serial returned by `GetCurrentState()` may have changed if another display config call happened between our read and our `ApplyMonitorsConfig`. GNOME will reject stale serials.

**Fix:** Simply re-run:
```bash
python3 lib/placement_manager.py right
```

---

## Logcat tags reference

| Tag | Component |
|-----|-----------|
| `NS:SocketReader` | TCP accept/read loop |
| `NS:StreamDecoder` | NAL parsing, SPS detection, MediaCodec, stats |
| `NS:ReceiverService` | Service lifecycle, control messages |
