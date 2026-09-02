# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- **GUI Desktop Shortcut**: `install.sh` now automatically creates and installs a Linux `.desktop` application menu shortcut for the NativeSunshine GUI.
- **Resolution Scale**: Added a "Resolution Scale (%)" knob to the GUI which dynamically scales the internal GStreamer capture/encode resolution without altering the GNOME virtual monitor geometry. This massively reduces decode latency on budget/older Android hardware (like Mediatek MT8768T).

### Changed
- **Pipeline Queues**: Configured GStreamer queues across all encoders (`vulkan`, `nvenc`, `vaapi`, `software`) to `max-size-buffers=1 leaky=downstream` for absolute zero-latency, dropping old frames immediately if the encoder or network falls behind.
- **Decoder Pacing**: Refined Android MediaCodec rendering. Soft-pacing restored with tighter backpressure and a slightly elevated `KEY_OPERATING_RATE` (120) to strike a balance between zero-latency and stutter-free VSYNC presentation on low-end hardware.

### Fixed
- Fixed GUI single-instance locking where running `./native-sunshine-gui.py` from the terminal would silently fail if an instance was already open.
