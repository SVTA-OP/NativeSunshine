# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

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
