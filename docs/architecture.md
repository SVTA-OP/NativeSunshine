# Architecture — End-to-End Data Flow

## The full pipeline

```
┌─────────────────────────────── LINUX HOST ──────────────────────────────────┐
│                                                                              │
│  GNOME Shell with --virtual-monitor 800×1340                                 │
│       │                                                                      │
│       │ (connector: Virtual-1 / HEADLESS-1 / Meta-0)                        │
│       ▼                                                                      │
│  org.gnome.Mutter.ScreenCast  (D-Bus)                                        │
│       │ CreateSession → RecordMonitor(connector)                             │
│       │ emits: PipeWireStreamAdded(node_id)                                  │
│       ▼                                                                      │
│  PipeWire  (node_id = e.g. 42)                                               │
│       │                                                                      │
│       ▼                                                                      │
│  gst-launch-1.0                                                              │
│    pipewiresrc path=42                                                       │
│    → videoconvert / vulkanupload                                             │
│    → vulkanh264enc  (CBR, no B-frames, IDR every 300 frames)                │
│    → h264parse  (byte-stream, AU alignment, inline SPS/PPS)                 │
│    → fdsink fd=1  (stdout)                                                   │
│           │                                                                  │
│           ▼  (raw Annex-B H.264 byte stream on stdout)                       │
│  socat stdin → TCP:127.0.0.1:7878                                            │
│           │                                                                  │
│           ▼  (loopback TCP connection on host)                               │
│  ADB forward  tcp:7878 → tcp:7878  (USB-C cable)                            │
│                                                                              │
└──────────────────────────── USB CABLE ──────────────────────────────────────┘
                                   │
┌─────────────────────────── ANDROID DEVICE ──────────────────────────────────┐
│                                                                              │
│  ADB daemon on device  (port 7878 receives forwarded bytes)                  │
│       │                                                                      │
│       ▼                                                                      │
│  ReceiverService (foreground Android service)                                │
│    └── SocketReader (ServerSocket bound to 0.0.0.0:7878)                    │
│              │  accept() → one client at a time                              │
│              │  64 KB read buffer, TCP_NODELAY                               │
│              ▼                                                               │
│         StreamDecoder.feedData()                                             │
│              │  NAL unit scanner (Annex-B start-code parser)                │
│              │  waits for SPS → parses width/height → setupCodec()          │
│              ▼                                                               │
│         Android MediaCodec  (hardware H.264 decoder, async callback mode)   │
│              │  COLOR_FormatSurface → zero-copy GPU decode                  │
│              ▼                                                               │
│         SurfaceView  (fullscreen, immersive mode)                           │
│                                                                              │
│  ─── REVERSE CHANNEL (port 7879) ───────────────────────────────────────    │
│  ADB reverse  tcp:7879 → tcp:7879  (device→host)                           │
│  ReceiverService → sends JSON {fps, bitrate} on connect                     │
│  control_server.py (port 7879, host side) → updates config.json             │
│                               → SIGUSR1 → native-sunshine.sh restarts       │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Port map

| Port | Direction | What uses it |
|------|-----------|-------------|
| 7878 | host→device | Video stream. `adb forward tcp:7878 tcp:7878`. socat connects; Android `ServerSocket` accepts. |
| 7879 | device→host | Control channel. `adb reverse tcp:7879 tcp:7879`. Android connects; `control_server.py` accepts. |

Both ports are loopback-only — they never touch a network interface.

## Process tree (host side, during streaming)

```
native-sunshine.sh (main shell, PID = $$)
├── gst-launch-1.0  (GST_PID)  — captures PW node, encodes H.264, writes to named pipe
├── socat  (PIPELINE_PID)       — reads named pipe, writes to TCP 127.0.0.1:7878
├── python3 control_server.py   (CONTROL_SERVER_PID)  — listens TCP 7879
├── python3 mutter_record_virtual.py (MUTTER_SCREENCAST_PID) — keeps ScreenCast alive
└── watch_client_orientation subshell (ORIENTATION_WATCHER_PID)
```

## Signal protocol

| Signal | Who sends it | What happens |
|--------|-------------|--------------|
| SIGUSR1 | `control_server.py` or `watch_client_orientation` → `kill -SIGUSR1 $$` | `restart_pipeline()` in `native-sunshine.sh`: stops pipeline, re-execs self with same args |
| SIGINT / SIGTERM | User Ctrl+C or system | `_ns_trap_handler` → `teardown()`: stop pipeline, disable virtual monitor, clear ADB forwards |

## Named pipe trick

`launch_pipeline()` creates a `mktemp -u` named pipe (FIFO) so `gst-launch-1.0` and `socat` can each have their own PID (making them independently killable):

```
gst-launch-1.0 ... > /tmp/nativesunshine-pipe-XXXX &   GST_PID=$!
socat - TCP:... < /tmp/nativesunshine-pipe-XXXX &      PIPELINE_PID=$!
rm -f /tmp/nativesunshine-pipe-XXXX   # path gone but FDs remain open
```

## SIGUSR1 restart flow (settings change / orientation change)

```
1. Android changes fps or bitrate → sends JSON to 127.0.0.1:7879
2. control_server.py writes ~/.config/native-sunshine/config.json
3. os.kill(parent_pid, SIGUSR1)
4. native-sunshine.sh: restart_pipeline()
   a. Disable all traps (prevent double-teardown)
   b. stop_pipeline (SIGINT → wait → SIGKILL)
   c. exec "$0" "$@"   (replace self — config.sh re-reads the JSON on next start)
```

## Resolution auto-detection flow

```
adb shell wm size                    → TARGET_WIDTH × TARGET_HEIGHT
adb shell dumpsys input SurfaceOrientation → swap W/H if landscape
GStreamer encodes at TARGET_WIDTH × TARGET_HEIGHT
h264parse emits inline SPS with correct SPS frame-cropping info
Android: parseSpsDimensions(SPS NAL) → actual width × height
MediaCodec.configure(format, width, height)  ← always correct
```

This is why there is NO hardcoded resolution on the Android side. The SPS is the single source of truth.
