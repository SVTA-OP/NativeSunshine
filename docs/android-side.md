# Android-Side Files

All Kotlin files live in `android/NativeSunshine/app/src/main/java/dev/nativesunshine/`.

---

## Component map

```
MainActivity  ──bind──►  ReceiverService
     │                        │
     │ SurfaceHolder.Callback  │ owns
     │ (Surface lifecycle)     ├── SocketReader   (TCP ServerSocket 7878)
     │                         └── StreamDecoder  (MediaCodec async H.264)
     │
     └── SettingsActivity (SharedPreferences UI)
```

---

## `MainActivity.kt`

**Role:** The only Activity. Owns the fullscreen `SurfaceView`. Starts and binds `ReceiverService`. Passes the `Surface` to the service whenever it becomes available/invalid. Shows a status text overlay.

### Key design decisions

**Why a bound + started service?**
- *Started* (`startForegroundService`) → survives Activity backgrounding
- *Bound* → direct reference for `setSurface()` / listener registration without IPC overhead

**Dynamic display sync:**
Android respects the native refresh rate, running smoothly up to 120Hz depending on the hardware capabilities.

**Surface frame rate hint:**
```kotlin
// In surfaceCreated:
holder.surface.setFrameRate(120.0f, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
```
Tells SurfaceFlinger what rate this surface produces, so it can mode-switch appropriately.

### `SurfaceHolder.Callback` implementation

| Callback | Action |
|----------|--------|
| `surfaceCreated` | Calls `receiverService?.setSurface(holder.surface)` — decoder can start rendering |
| `surfaceChanged` | No-op — SurfaceView handles resize |
| `surfaceDestroyed` | Calls `receiverService?.setSurface(null)` — decoder must not render to a dead surface |

### `StreamStatus` sealed class

```kotlin
sealed class StreamStatus {
    object WAITING    : StreamStatus()   // waiting for TCP connection
    object CONNECTING : StreamStatus()   // connection accepted, decoder starting
    object STREAMING  : StreamStatus()   // first frame rendered
    data class ERROR(val message: String) : StreamStatus()
}
```

Status → UI mapping:
- `WAITING`: statusText visible, settingsButton visible, statsText gone
- `CONNECTING`: statusText visible, statsText gone
- `STREAMING`: statusText gone, settingsButton gone, statsText visible (FPS/Mbps/latency)
- `ERROR`: statusText with message, settingsButton visible

### Stats overlay format
```
FPS: 60 | 8.1 Mbps | Latency: 12 ms
```
Updated every second from `StreamDecoder.checkStats()` via `ReceiverService.statsListener`.

---

## `ReceiverService.kt`

**Role:** The long-running foreground service. Owns `SocketReader` and `StreamDecoder`. Coordinates their lifecycle. Sends control messages to the host.

### Service lifecycle

```
onCreate()  → startForeground() with "Waiting for stream…" notification
onStartCommand() → startPipeline()   (START_STICKY = restart if killed)
onBind()    → return LocalBinder
onDestroy() → stopPipeline()
```

`FOREGROUND_SERVICE_TYPE_DATA_SYNC` is used (API 34+) because the streaming is analogous to a data sync operation.

### `startPipeline()`

1. `stopPipeline()` — clean slate
2. `sendControlMessage()` — send `{fps, bitrate}` JSON to host port 7879 (in a background thread)
3. Create `StreamDecoder` (initial instance — will be replaced on actual connection)
4. Create `SocketReader` with callbacks:
   - `onConnected` → stop old decoder, create **new** `StreamDecoder`, call `decoder.start(currentSurface)`
   - `onData` → `decoder.feedData(buf, offset, length)`
   - `onDisconnected` → `decoder.stop()`, emit `WAITING` status
   - `onError` → emit `ERROR` status

**Why a new decoder on each connect?** To guarantee completely clean MediaCodec state. Reusing a stopped codec instance was found to cause subtle SPS-parse-order issues.

### `sendControlMessage()`
Runs on a new Thread. Connects to `127.0.0.1:7879` (which the ADB reverse forward routes to the Linux host's `control_server.py`). Sends:
```json
{"fps": 60, "bitrate": 8000}
```
Values read from `SharedPreferences` (set in `SettingsActivity`). FPS is clamped to 120.

### `sendErrorToHost(errorMsg)`
Same mechanism — sends `{"error": "..."}` to port 7879 so the host can display it in the terminal.

### `setSurface(surface)`
Called by `MainActivity`. Updates `currentSurface` (volatile) and calls `streamDecoder?.updateSurface(surface)`.

---

## `SocketReader.kt`

**Role:** TCP server. Binds `ServerSocket` on port 7878. Accepts one connection at a time. Reads in 64 KB chunks and calls `onData`.

### Threading

```
Main thread → SocketReader.start()
    → launch Thread("NS-accept", daemon=true)
        → ServerSocket.accept() [blocks]
        → on connection: call onConnected()
        → launch inline read loop (same thread)
            → stream.read(readBuffer) [blocks]
            → on data: call onData()
        → on EOF: call onDisconnected()
        → loop back to accept()
```

There is no separate read thread — reading is synchronous within the accept thread. This is fine because we're dealing with a single-connection streaming scenario.

### Socket tuning
```kotlin
client.tcpNoDelay = true          // disable Nagle — critical for low latency
client.receiveBufferSize = 32768  // prevent kernel socket buffer bloat
client.setPerformancePreferences(0, 1, 0)  // prioritize latency over bandwidth
```

### Read buffer
64 KB (`ByteArray(65536)`). **Reused across reads** — `onData` must process or copy before returning. `StreamDecoder.feedData()` immediately copies into `frameBuf`, so this is safe.

### Reconnection
When the host stops streaming (EOF or RST), `readFromSocket` returns, `onDisconnected` is called, and the `while (running.get())` loop calls `serverSocket!!.accept()` again. No restart needed — the service auto-heals.

---

## `StreamDecoder.kt`

**Role:** The core of the Android side. Parses Annex-B H.264 NAL units from the raw byte stream, initializes `MediaCodec` from SPS parameters, and decodes frames directly to the `SurfaceView` with zero copy.

### Constructor parameters

| Parameter | Type | Use |
|-----------|------|-----|
| `refreshRate` | Float | FPS limit (default up to 120) |
| `onFirstFrame` | `() → Unit` | Fired once when the first frame is rendered |
| `onError` | `(String) → Unit` | Fired on non-recoverable codec error |
| `onStatsUpdate` | `((Int, Float, Long) → Unit)?` | Per-second stats: fps, Mbps, latency ms |

### Key state

| Field | Type | Meaning |
|-------|------|---------|
| `isRunning` | `AtomicBoolean` | Guards all entry points |
| `codecConfigured` | Boolean | True once `setupCodec()` has been called |
| `pendingSurface` | `Surface?` | Surface to render to; may change via `updateSurface()` |
| `frameBuf` | `ByteArray(2MB)` | Accumulation buffer for NAL framing |
| `frameBufLen` | Int | Current fill level of `frameBuf` |
| `hasVclInFrame` | Boolean | True once a VCL NAL (slice/IDR) seen in current AU |
| `dataQueue` | `ArrayBlockingQueue<ByteArray>(3)` | Overflow queue when codec input buffers busy. Capped to 3 frames to bound max queued latency |
| `availableInputBuffers` | `ConcurrentLinkedQueue<Int>` | Codec input buffer indices ready to be filled |

### NAL framing in `feedData()`

The GStreamer pipeline produces Annex-B byte-stream (start-code prefixed NAL units, AU-aligned). `feedData()` accumulates chunks in `frameBuf` and scans for start codes to find Access Unit boundaries:

```
Append incoming bytes to frameBuf
Scan for 00 00 01 start codes
For each start code found:
  Extract NAL type from the byte after start code
  If hasVclInFrame AND this NAL would start a new AU:
    → extract everything before this NAL → processExtractedFrame(frame)
    → shift remaining bytes to frameBuf[0]
    → reset searchIdx = 0
  If nalType == 1 (non-IDR slice) or 5 (IDR):
    hasVclInFrame = true
```

**"New AU" trigger NAL types:** `9` (AUD), `7` (SPS), `8` (PPS), `6` (SEI), `14` (prefix NAL), or a VCL NAL with the `first_mb_in_slice` bit set.

### SPS parsing → codec init in `processExtractedFrame()`

On the very first SPS-containing frame:
1. Scan for NAL type `7` (SPS)
2. Call `parseSpsDimensions(frame, startCodeLen)` → `Pair<width, height>`
3. Call `setupCodec(surface, width, height)` → creates `MediaCodec`

**Why parse SPS?** The host encoder may use dimensions that differ from any hardcoded value (alignment, insets, etc. have caused three different heights: 1312, 1328, 1340). The SPS is the single source of truth.

### `parseSpsDimensions()` — Exp-Golomb bit reader

Parses raw RBSP (after stripping emulation-prevention bytes `00 00 03 → 00 00`):
- `profile_idc` (8 bits)
- constraint flags + `level_idc` (16 bits)
- `seq_parameter_set_id` (UE)
- `log2_max_frame_num_minus4` (UE)
- `pic_order_cnt_type` (UE)
- `max_num_ref_frames` (UE), `gaps_in_frame_num_value_allowed_flag` (1 bit)
- `pic_width_in_mbs_minus1` (UE) → `width = (val+1)*16`
- `pic_height_in_map_units_minus1` (UE)
- `frame_mbs_only_flag` (1 bit) → `height = (2 - flag) * (val+1) * 16`
- Frame cropping → subtract `(cropLeft+cropRight)*2` from width, etc.

Only parses constrained-baseline (profile_idc not in the high-profile list). If high profile is detected, returns `null` → codec setup deferred to next SPS.

### `setupCodec(surface, width, height)`

```kotlin
MediaFormat.createVideoFormat(MIMETYPE_VIDEO_AVC, width, height).apply {
    KEY_PRIORITY = 0         // real-time
    KEY_OPERATING_RATE = 120 // clock up the VPU
    "max-num-reorder-frames" = 0   // no B-frame reorder buffer
    "output-reorder-depth" = 0
    KEY_LOW_LATENCY = 1      // API 30+
    KEY_MAX_INPUT_SIZE = 512 * 1024
    KEY_FRAME_RATE = targetFps.toInt()
    KEY_COLOR_FORMAT = COLOR_FormatSurface  // zero-copy GPU decode
}
```

Finds hardware H.264 decoder via `findH264Decoder()`:
- On API 29+: first `info.isHardwareAccelerated` decoder for AVC
- On older: first non-Google, non-sw decoder for AVC

**IMPORTANT:** `BUFFER_FLAG_CODEC_CONFIG` is **NOT** set on any input buffer. With `h264parse config-interval=-1`, inline SPS/PPS arrive in the byte stream as normal NAL units. Setting `CODEC_CONFIG` on a buffer containing inline Annex-B data causes MediaTek Codec2 to treat it as a stream reconfiguration, flushing in-flight frames. All buffers are queued with `flags = 0`.

### MediaCodec async callback mode

```kotlin
c.setCallback(object : MediaCodec.Callback() {
    override fun onInputBufferAvailable(mc, inputIndex) → onInputBufferReady()
    override fun onOutputBufferAvailable(mc, outputIndex, info) → handleDecodedOutput()
    override fun onError(mc, e) → onError(message)
    override fun onOutputFormatChanged(mc, format) → log only
})
c.configure(format, surface, null, 0 /*decode*/)
c.start()
```

### Input buffer feeding

When `onInputBufferAvailable` fires → `onInputBufferReady()`:
- Check `dataQueue` for pending frames first
- If found: write to the new input buffer immediately
- If not: put the index in `availableInputBuffers` (for `processExtractedFrame` to use)

When `processExtractedFrame` is called from the read thread:
- Lock `bufferLock`
- Poll `availableInputBuffers`
- If an index is available: call `writeChunkToInputBuffer`
- Otherwise: `dataQueue.offer(frame)` — if queue is full (3 frames), drop oldest and keep newest

### PTS assignment
```kotlin
var pts = (System.nanoTime() - baseTimeNs) / 1000  // nanoseconds → microseconds
if (pts <= lastPtsUs) pts = lastPtsUs + 1           // guarantee monotonic
```
`latencyMap[pts] = System.nanoTime()` records when each frame was submitted, for latency tracking.

### Output / rendering in `handleDecodedOutput()`

**Dynamic backpressure:**
```kotlin
val isCongested = dataQueue.size >= 3  // 3+ frames queued = genuinely behind
val shouldRender = isSurfaceValid && isRunning && !isCongested
c.releaseOutputBuffer(outIdx, shouldRender)
```
When congested (3+ frames backed up, ~50ms behind), the decoded frame is discarded from the SurfaceFlinger queue (but MediaCodec still decoded it internally — P-frame reference integrity is maintained). 1-2 frames in the queue is normal pipeline overlap between the socket-read thread and the codec callback thread — these do NOT trigger drops.

### Stats (`checkStats()`)
Every 1000ms:
- `mbps = (bytesReceived * 8) / 1_000_000`
- `avgLatencyMs = totalLatencyNs / latencyCount / 1_000_000`
- Resets all counters
- Calls `onStatsUpdate(framesRendered, mbps, avgLatencyMs)`

### `updateSurface(surface)`
Calls `codec?.setOutputSurface(surface)` — swaps the render target without stopping the codec. Available on API 23+. Used when `surfaceChanged` or `surfaceDestroyed` fires.

---

## `SettingsActivity.kt`

**Role:** Thin wrapper around `PreferenceFragmentCompat`. Shows a settings screen backed by `SharedPreferences`. Settings read by `ReceiverService.sendControlMessage()`:

- `stream_port` (String, default "7878") — TCP port for video stream
- `host_fps` (String, default "120") — FPS to request from host
- `host_bitrate` (String, default "8000") — bitrate in kbps to request from host

---

## `AndroidManifest.xml`

### Permissions

| Permission | Why |
|------------|-----|
| `FOREGROUND_SERVICE` | ReceiverService must be a foreground service |
| `FOREGROUND_SERVICE_DATA_SYNC` | API 34+ foreground service type |
| `WAKE_LOCK` | Keep CPU awake during streaming |
| `RECEIVE_BOOT_COMPLETED` | Optional auto-start (not yet implemented in code) |
| `INTERNET` | Required for loopback `ServerSocket` binding even though there's no actual internet use |

### Key activity attributes

| Attribute | Value | Why |
|-----------|-------|-----|
| `screenOrientation` | `userPortrait` | Phone stays portrait; the virtual monitor is portrait |
| `configChanges` | `orientation\|screenSize\|keyboardHidden` | Don't recreate Activity on rotation/keyboard |
| `launchMode` | `singleTop` | Prevent multiple instances from ADB am start |
| `keepScreenOn` | `true` | Belt-and-suspenders alongside the WAKE_LOCK |

### ReceiverService
- `exported="false"` — not accessible from other apps
- `foregroundServiceType="dataSync"` — API 34 requires explicit type
