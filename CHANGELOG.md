# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [1.2.0] - 2026-11-06

### Added

- **Automatic Decoder Error Recovery**: When the Android client reports a `Decoder callback error` (MediaCodec `Error 0x80000000`), the host now automatically restarts the GStreamer pipeline and reconnects. Recovery is triggered via two independent mechanisms: the control channel (`control_server.py`) and a background `adb logcat` watcher (`watch_decoder_errors`), ensuring resilience even if the control socket drops during the crash.
- **Virtual Display Scale Setting**: The GUI now exposes a **Display Scale** preference under "Virtual Monitor Settings". Scale options are queried from GNOME Mutter's D-Bus interface (with common fallback choices if the query is unavailable), and the chosen scale is applied to the GNOME virtual monitor via `placement_manager.py`.

### Fixed

- **Launch/Stop Button State**: Fixed a regression where the **Stop Stream** button would block the GUI event loop indefinitely if the pipeline crashed before the GUI sent `SIGINT`. The stop handler now uses a bounded `wait(timeout=2)` with a `SIGKILL` fallback, ensuring the button always resets to **Launch Stream**.
- **Multi-monitor Placement Overlap**: Fixed `Logical monitors not adjacent` and `Logical monitors overlap` DBus errors from Mutter when placing the virtual monitor to the right of a multi-monitor layout (e.g., laptop + external). The placement now correctly computes the bounding box across all non-virtual monitors and applies a coordinate offset probe (`±2px`) to satisfy Mutter's adjacency constraint with fractional-scaled displays.
- **Device Refresh Rate Detection**: `TARGET_REFRESH` is now correctly set to the device's actual refresh rate (read from `adb shell dumpsys display`) instead of hardcoding `120`.
- **DBus Python Import Fallback**: Python helpers that import `dbus` (`check_monitors.py`, `get_pw_node.py`, `mutter_record_virtual.py`, and `placement_manager.py`) now re-exec under `/usr/bin/python3` if the module is missing from the current interpreter. `display.sh` invokes `/usr/bin/python3` directly for its D-Bus query.
- **Android Default FPS**: The Android app's default host FPS preference is now `60` (was `120`) to avoid overloading budget hardware by default. `KEY_OPERATING_RATE` is now set dynamically from the actual target FPS instead of a hardcoded `120`.

## [1.1.0] - 2026-09-20

### Added

- **Dynamic Orientation / Rotation Sync**: Restored device rotation tracking. The Android app's physical orientation changes are now instantly propagated to the Linux host, dynamically rotating the GNOME virtual monitor in real-time.

### Changed

- **120 FPS Uncapped Pipeline**: Removed all hardcoded 60 FPS limitations across both the Android receiver app (display refresh rate locks, codec buffer pacing) and the Linux host pipeline (GStreamer framerate constraints). The stream now natively operates up to 120 FPS depending on your device's refresh rate.

### Fixed

- **Config Overrides**: Fixed an issue where legacy `framerate: 60` settings in `~/.config/native-sunshine/config.json` would improperly throttle dynamic framerates.
- **Top-Level Bash Variable Fix**: Fixed a syntax error involving the `local` keyword being used in the main body of `native-sunshine.sh`.
- **Orientation and Alignment Issues**: Added fallback to `dumpsys window displays` for orientation detection, aligned dimensions to 32px boundaries to prevent hardware encoder failures, and updated Android manifest screen orientation to `fullUser`.

## [1.0.0] - 2026-09-02

### Added

- **GUI Desktop Shortcut**: `install.sh` now automatically creates and installs a Linux `.desktop` application menu shortcut for the NativeSunshine GUI.
- **Resolution Scale**: Added a "Resolution Scale (%)" knob to the GUI which dynamically scales the internal GStreamer capture/encode resolution without altering the GNOME virtual monitor geometry. This massively reduces decode latency on budget/older Android hardware (like Mediatek MT8768T).

### Changed

- **Pipeline Queues**: Configured GStreamer queues across all encoders (`vulkan`, `nvenc`, `vaapi`, `software`) to `max-size-buffers=1 leaky=downstream` for absolute zero-latency, dropping old frames immediately if the encoder or network falls behind.
- **Decoder Pacing**: Refined Android MediaCodec rendering. Soft-pacing restored with tighter backpressure and a slightly elevated `KEY_OPERATING_RATE` (120) to strike a balance between zero-latency and stutter-free VSYNC presentation on low-end hardware.

### Fixed

- Fixed GUI single-instance locking where running `./native-sunshine-gui.py` from the terminal would silently fail if an instance was already open.
