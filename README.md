# NativeSunshine

**Use your Android device as a secondary monitor over USB-C — no Wi-Fi, no network, no third-party streaming protocol.**

All pixel data travels through the physical USB-C cable via the ADB daemon. Features low-latency hardware encoding, dynamic device rotation sync, streaming up to 120 FPS, automatic decoder error recovery, and virtual display scaling. Streaming defaults to 60 FPS; you can request a higher rate in Android settings when supported by both devices.

```
Linux Host (Wayland/GNOME)          Android Device
─────────────────────────           ──────────────
Virtual display (800×1340)
  │
PipeWire capture
  │
H.264 encode (8Mbps CBR)
  │
GStreamer tcpclientsink
  │
adb forward tcp:7878 ──USB-C──►  ServerSocket:7878
                                    │
                               MediaCodec H.264 decode
                                    │
                               SurfaceView fullscreen
```

---

## Prerequisites

### Linux Host
| Requirement | Notes |
|---|---|
| GNOME Shell with Wayland | Tested on GNOME Shell 50+ |
| `--virtual-monitor 800x1340` in gnome-shell args | See [Virtual Display Setup](#virtual-display-setup) |
| `adb` (Android Debug Bridge) | `sudo apt install android-tools` |
| GStreamer with VAAPI | `sudo apt install gstreamer1.0-vaapi gstreamer1.0-pipewire gstreamer1.0-plugins-good gstreamer1.0-plugins-bad` |
| `jq`, `pipewire`, `gdbus` | Usually pre-installed on GNOME systems |

### Android Device
| Requirement | Notes |
|---|---|
| Android 6.0+ (API 23+) | API 30+ recommended for low-latency mode |
| USB Debugging enabled | Settings → Developer Options → USB Debugging |
| NativeSunshine APK installed | See [Building the APK](#building-the-apk) |
| USB-C data cable | Must support data transfer (not charge-only) |

---

## Quick Start

### 1. Check dependencies
```bash
./install.sh --check
```

### 2. Build and install the Android APK
```bash
cd android/NativeSunshine
# AGP 8.5 requires JDK 17–21. If your default Java is newer, set JAVA_HOME:
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk   # Arch: jdk21-openjdk
export ANDROID_HOME=~/Android/Sdk
./gradlew assembleDebug
adb install app/build/outputs/apk/debug/app-debug.apk
cd ../..
```

Or use the installer:
```bash
./install.sh --apk
```

### 3. Connect and stream
1. Connect your Android device via USB-C
2. Accept the USB Debugging RSA fingerprint on your device
3. Open **NativeSunshine** on your Android device
4. Launch the NativeSunshine GUI:
   ```bash
   ./native-sunshine-gui.py
   ```
5. In the GUI, configure your Encoder, Bitrate, Display Scale, and where you want the virtual monitor placed (Left, Right, Above, Below).
6. Click **Launch Stream**. 
7. The virtual monitor will use the connected Android device's detected resolution and refresh rate (up to 120 FPS).

*Tip: A desktop shortcut for NativeSunshine is automatically installed by `install.sh`, so you can launch it from your application menu in the future!*

### 4. Stop
Click **Stop Stream** in the GUI, or close the window. All virtual monitors will be automatically and cleanly destroyed.

---

## Configuration

Settings are easily managed through the GTK4 GUI (`./native-sunshine-gui.py`) which saves to `~/.config/native-sunshine/config.json`.

The GUI exposes the following settings:

| Setting | Description |
|---|---|
| **Encoder** | GStreamer encoder: `vulkan`, `vaapi`, `nvenc`, or `software` (the GUI initially selects `vulkan`; `config.sh` defaults to `software`) |
| **Bitrate** | H.264 target bitrate in kbps |
| **Keyframe Interval** | IDR frame period in frames |
| **Resolution Scale (%)** | Encode at 10–100% of native resolution (reduces decode load on budget hardware) |
| **Display Scale** | GNOME UI scaling for the virtual monitor. Options are queried from Mutter when available; the GUI offers common fallback scales if that query is unavailable. |
| **Placement** | Where to place the virtual monitor relative to your primary display: Left, Right, Above, or Below |

Alternatively, advanced users can edit [`config.sh`](config.sh) to adjust low-level paths or ADB ports:

| Variable | Default | Description |
|---|---|---|
| `ADB_STREAM_PORT` | `7878` | TCP port for ADB tunnel (must match APK's `STREAM_PORT`) |

> **Important**: If you change `ADB_STREAM_PORT` in `config.sh`, update `STREAM_PORT` in [`ReceiverService.kt`](android/NativeSunshine/app/src/main/java/dev/nativesunshine/ReceiverService.kt) and rebuild the APK.

---

## Troubleshooting

### Cannot find PipeWire node ID for virtual monitor
If you encounter this error, ensure your GNOME session supports DBus Screencasting.

### `Pipeline exited immediately`
Check the pipeline log:
```bash
cat ~/.local/log/native-sunshine-pipeline.log
```
Common causes:
- Wrong PipeWire node ID — run `pw-dump | jq '.[] | select(.type=="PipeWire:Interface:Node") | {id, desc: .info.props["node.description"]}'`
- VAAPI device permission — add yourself to the `render` group: `sudo usermod -aG render $USER` (re-login required)
- VAAPI device path wrong — check `config.sh` → `VAAPI_DEVICE`

### Android app shows "Waiting for host" indefinitely
- Confirm ADB forward is set: `adb forward --list`
- Confirm the pipeline is running on the host
- Confirm both use the same port (default: 7878)

### High latency / choppy video
- Lower the **Resolution Scale (%)** in the GUI to reduce decode latency on budget Android devices.
- Increase the **Keyframe Interval** in the GUI to 240 or 300 to prevent micro-stutters.
- Reduce `STREAM_BITRATE` in the GUI (try `4000` or `5000`).
- Ensure you are using a USB 3.0+ cable and port.
- Check VAAPI is actually using hardware: `vainfo | grep VAEntrypointEncSliceLP`.
- **LineageOS/Custom ROMs**: If latency persists, go to Developer Options and turn ON **Disable HW Overlays** to bypass the hardware composer's buffer frame.

### Decoder callback error / stream drops unexpectedly
NativeSunshine automatically detects Android MediaCodec `Decoder callback error` events and restarts the GStreamer pipeline. If the stream drops and immediately recovers, this is normal self-healing behavior. If restarts recur frequently:
- Lower the **Bitrate** or **Resolution Scale (%)** to reduce decoder pressure.
- In Android settings, cap the **Host FPS** to 60 if your device struggles at higher rates.
- Check `adb logcat -s NS:StreamDecoder` for the exact error code.

The Android **Host FPS** setting defaults to 60. NativeSunshine detects the device's display refresh rate when no explicit FPS is requested and caps the stream at 120 FPS.

### Virtual monitor appears wrong size / GNOME scaling looks off
Use the **Display Scale** dropdown in the GUI ("Virtual Monitor Settings" section). It shows the scales Mutter reports (e.g. 75%, 100%, 125%), or common fallback options if Mutter cannot be queried. The selected scale is applied when you next launch a stream.

### `adb: device unauthorized`
Accept the RSA fingerprint prompt on your Android device's screen.

---

## Project Structure

```
NativeSunshine/
├── native-sunshine.sh       # Master orchestrator (run this)
├── config.sh                # User configuration
├── install.sh               # Dependency checker + APK builder
├── lib/
│   ├── utils.sh             # Logging, dependency checks, traps
│   ├── display.sh           # Virtual display verification + PipeWire node discovery
│   ├── adb.sh               # ADB device management + port forwarding
│   └── pipeline.sh          # GStreamer pipeline builder + process manager
└── android/
    └── NativeSunshine/      # Android Studio project
        └── app/src/main/
            └── java/dev/nativesunshine/
                ├── MainActivity.kt     # Fullscreen SurfaceView host
                ├── ReceiverService.kt  # Foreground service + pipeline owner
                ├── SocketReader.kt     # TCP server (ADB tunnel receiver)
                └── StreamDecoder.kt   # MediaCodec H.264 → Surface decoder
```

---

## How It Works

1. **Virtual display**: GNOME Shell creates a headless virtual monitor (`Virtual-1`) at startup via `--virtual-monitor 800x1340`. This appears as a real display in GNOME settings.

2. **PipeWire capture**: GStreamer's `pipewiresrc` captures frames directly from the virtual display's PipeWire node (no XDG portal dialog needed for compositor-owned nodes).

3. **VAAPI encode**: Frames are hardware-encoded to H.264 on the AMD GPU using VAAPI — CBR at 8Mbps, keyframe every 60 frames, low-power fixed-function path.

4. **ADB tunnel**: `adb forward tcp:7878 tcp:7878` creates a bidirectional socket tunnel through the USB cable. GStreamer's `tcpclientsink` connects to `localhost:7878`; data flows through ADB to `localhost:7878` on the Android device.

5. **Android decode**: The NativeSunshine app runs a `ServerSocket(7878)`, accepts the connection, feeds the H.264 byte-stream to Android's `MediaCodec` hardware decoder, and renders decoded frames directly to a fullscreen `SurfaceView` — zero network, zero copies.
