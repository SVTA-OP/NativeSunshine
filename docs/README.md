# NativeSunshine — Documentation Index

NativeSunshine turns an Android phone into a **wired USB-C secondary monitor** for a Linux GNOME desktop — no Wi-Fi, no network, no Moonlight/Sunshine dependency. Everything runs over the ADB USB tunnel.

## How it works (one-liner)

```
GNOME virtual display → Mutter ScreenCast → PipeWire → GStreamer H.264 encode
  → socat → ADB USB forward → Android ServerSocket → MediaCodec decode → SurfaceView
```

## Docs in this folder

| File | What it covers |
|------|----------------|
| [architecture.md](architecture.md) | End-to-end data-flow diagram, port map, process tree |
| [host-side.md](host-side.md) | Every file in `lib/` and the root scripts explained in full |
| [android-side.md](android-side.md) | Every Kotlin file in the Android app explained in full |
| [config-reference.md](config-reference.md) | All config variables, what they do, and sane values |
| [troubleshooting.md](troubleshooting.md) | Known bugs, failure modes, and how to fix them |
| [how-to.md](how-to.md) | Step-by-step recipes for common operations |

## Quick orientation

```
NativeSunshine/
├── native-sunshine.sh       # Entry point — orchestrates the whole thing
├── config.sh                # All user-facing config knobs
├── lib/
│   ├── utils.sh             # Logging, dependency check, signal traps
│   ├── adb.sh               # ADB device validation + port forwarding
│   ├── display.sh           # Virtual display verification + PW node discovery
│   ├── pipeline.sh          # GStreamer pipeline builders + process management
│   ├── control_server.py    # TCP control channel (port 7879): bitrate/fps from Android
│   ├── mutter_record_virtual.py  # Starts Mutter ScreenCast session, emits PW node ID
│   ├── portal_screencast.py      # (Alt) XDG Desktop Portal screencast path
│   ├── placement_manager.py      # Positions virtual monitor in GNOME layout
│   ├── check_monitors.py         # Debug: dumps Mutter DisplayConfig state
│   └── get_displays.py           # Lists connectors via gdbus (used by GUI)
└── android/NativeSunshine/app/src/main/java/dev/nativesunshine/
    ├── MainActivity.kt      # Fullscreen SurfaceView + service lifecycle
    ├── ReceiverService.kt   # Foreground service owning SocketReader + StreamDecoder
    ├── SocketReader.kt      # TCP ServerSocket on port 7878
    └── StreamDecoder.kt     # MediaCodec async H.264 decoder → SurfaceView
```
