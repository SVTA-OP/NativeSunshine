package dev.nativesunshine

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "NS:StreamDecoder"

// H.264 NAL unit start codes
private val START_CODE_4 = byteArrayOf(0x00, 0x00, 0x00, 0x01)
private val START_CODE_3 = byteArrayOf(0x00, 0x00, 0x01)

/**
 * StreamDecoder — Hardware H.264 decoder using Android MediaCodec.
 *
 * Receives raw H.264 byte-stream data from SocketReader and decodes it
 * directly to a Surface (zero-copy GPU path). MediaCodec is configured with:
 *   - KEY_LOW_LATENCY = 1 (API 30+): disables B-frame buffering
 *   - KEY_PRIORITY = 0: real-time priority
 *   - KEY_MAX_INPUT_SIZE: generous buffer for large NAL units
 *
 * Input format: byte-stream (Annex B, start-code prefixed NAL units)
 * as produced by GStreamer's h264parse element with stream-format=byte-stream.
 *
 * Threading:
 *   - feedData() is called from SocketReader's read thread
 *   - Internally queues data into MediaCodec input buffers via queueThread
 *   - MediaCodec output is configured for surface rendering (async-to-surface)
 *
 * @param onFirstFrame  Callback fired on the first successfully rendered frame
 * @param onError       Callback fired on a non-recoverable codec error
 * @param onStatsUpdate Callback fired every second with (fps, mbps, latencyMs)
 */
class StreamDecoder(
    private val onFirstFrame: () -> Unit,
    private val onError: (message: String) -> Unit,
    private val onStatsUpdate: ((Int, Float, Long) -> Unit)? = null
) {
    private var codec: MediaCodec? = null
    private val isRunning = AtomicBoolean(false)
    private val firstFrameFired = AtomicBoolean(false)
    private var pendingSurface: Surface? = null
    private var codecConfigured = false

    // Render pacing: the A7 Lite panel is hardware-limited to 60Hz (confirmed
    // via dumpsys — no 120Hz mode exists on this device), but the host may
    // capture/encode at a higher rate for smoother motion sampling. We pace
    // *output* to wall-clock time rather than decimating by a fixed frame
    // count, so it self-adapts to whatever rate actually arrives instead of
    // assuming a specific capture fps. This is independent of the reactive
    // backpressure drop below, which remains purely a safety valve for input
    // buffer starvation, not a smoothing mechanism.
    private val renderIntervalNs = 1_000_000_000L / 60
    private var lastRenderNs = 0L

    // Queue of byte arrays from SocketReader → queueThread → MediaCodec
    private val dataQueue = LinkedBlockingQueue<ByteArray>(2048)

    // Performance tracking
    private var framesRendered = 0
    private var bytesReceived = 0L
    private var lastStatsTime = System.currentTimeMillis()
    private val latencyMap = java.util.concurrent.ConcurrentHashMap<Long, Long>()
    private var totalLatencyNs = 0L
    private var latencyCount = 0
    
    // NAL unit framing buffers
    private val frameBuf = ByteArray(2 * 1024 * 1024) // 2MB max frame
    private var frameBufLen = 0

    private var queueThread: Thread? = null
    private var outputThread: Thread? = null

    // ── Public API ─────────────────────────────────────────────────────────────

    /**
     * Start decoding. Should be called once the host connects and
     * a valid Surface is available.
     */
    fun start(surface: Surface?) {
        if (isRunning.getAndSet(true)) {
            Log.w(TAG, "Decoder already running — ignoring start()")
            return
        }
        if (surface == null || !surface.isValid) {
            Log.e(TAG, "Cannot start decoder: surface is null or invalid")
            isRunning.set(false)
            onError("No valid display surface")
            return
        }

        firstFrameFired.set(false)
        dataQueue.clear()
        frameBufLen = 0
        pendingSurface = surface
        codecConfigured = false

        Log.i(TAG, "Decoder waiting for SPS to configure codec")
    }

    /** Feed raw H.264 byte-stream data. Thread-safe; called from SocketReader. */
    fun feedData(buf: ByteArray, offset: Int, length: Int) {
        if (!isRunning.get()) return
        
        // Ensure we don't overflow the buffer (e.g., heavily corrupted stream)
        if (frameBufLen + length > frameBuf.size) {
            Log.e(TAG, "Frame buffer overflow! Dropping corrupted stream data.")
            frameBufLen = 0
        }
        
        System.arraycopy(buf, offset, frameBuf, frameBufLen, length)
        frameBufLen += length
        
        var searchIdx = 0
        while (searchIdx <= frameBufLen - 3) {
            // Find Annex B start codes (00 00 01)
            if (frameBuf[searchIdx] == 0.toByte() && frameBuf[searchIdx+1] == 0.toByte() && frameBuf[searchIdx+2] == 1.toByte()) {
                
                var actualStart = searchIdx
                var advance = 3
                // Check if it's a 4-byte start code (00 00 00 01)
                if (searchIdx > 0 && frameBuf[searchIdx - 1] == 0.toByte()) {
                    actualStart = searchIdx - 1
                    advance = 4
                }
                
                if (actualStart > 0) {
                    // Extract the complete NAL unit
                    val frame = frameBuf.copyOfRange(0, actualStart)

                    if (!codecConfigured) {
                        val sclen = getStartCodeLen(frame, 0, frame.size)
                        if (sclen > 0 && sclen < frame.size && (frame[sclen].toInt() and 0x1F) == 7) {
                            val dims = parseSpsDimensions(frame, sclen)
                            val surface = pendingSurface
                            if (dims != null && surface != null) {
                                try {
                                    setupCodec(surface, dims.first, dims.second)
                                    codecConfigured = true
                                    startQueueThread()
                                    Log.i(TAG, "Decoder started")
                                } catch (e: Exception) {
                                    Log.e(TAG, "Codec setup failed: ${e.message}", e)
                                    isRunning.set(false)
                                    onError("Codec setup failed: ${e.message}")
                                    return
                                }
                            } else {
                                Log.w(TAG, "Could not parse SPS dimensions — waiting for next SPS")
                            }
                        }
                    }

                    if (codecConfigured) {
                        try {
                            dataQueue.put(frame) // Blocks applying backpressure
                        } catch (e: InterruptedException) {
                            return
                        }
                    }
                    
                    // Shift the remaining data (including the start code) to the beginning
                    val remaining = frameBufLen - actualStart
                    System.arraycopy(frameBuf, actualStart, frameBuf, 0, remaining)
                    frameBufLen = remaining
                    searchIdx = advance
                } else {
                    // Start code is at the very beginning, skip past it to find the next one
                    searchIdx += advance
                }
            } else {
                searchIdx++
            }
        }
        
        bytesReceived += length
        checkStats()
    }

    private fun checkStats() {
        val now = System.currentTimeMillis()
        if (now - lastStatsTime >= 1000) {
            val mbps = (bytesReceived * 8f) / 1_000_000f
            val avgLatencyMs = if (latencyCount > 0) (totalLatencyNs / latencyCount) / 1_000_000L else 0L
            onStatsUpdate?.invoke(framesRendered, mbps, avgLatencyMs)
            framesRendered = 0
            bytesReceived = 0L
            totalLatencyNs = 0L
            latencyCount = 0
            lastStatsTime = now
        }
    }

    /** Stop decoding and release codec resources. */
    fun stop() {
        if (!isRunning.getAndSet(false)) return
        Log.i(TAG, "Stopping decoder")
        dataQueue.clear()
        queueThread?.interrupt()
        queueThread = null
        codecConfigured = false
        pendingSurface = null
        releaseCodec()
    }

    /** Update the render surface (called when SurfaceView changes). */
    fun updateSurface(surface: Surface?) {
        if (surface == null || !surface.isValid) return
        try {
            // MediaCodec.setOutputSurface() can swap the surface without
            // stopping the codec — available on API 23+.
            codec?.setOutputSurface(surface)
            Log.d(TAG, "Output surface updated")
        } catch (e: Exception) {
            Log.w(TAG, "setOutputSurface failed: ${e.message}")
        }
    }

    // ── SPS parsing (Exp-Golomb) ─────────────────────────────────────────────
    // The host's actual stream resolution is auto-detected at launch and can
    // differ from any value we might assume on the Android side (it has
    // drifted twice now: 800x1312 vs 800x1328 vs 800x1340 depending on
    // alignment/inset logic upstream). Rather than hardcode a guess, parse
    // the true width/height out of the SPS NAL itself — this is the single
    // source of truth the encoder actually used.
    private class BitReader(data: ByteArray) {
        private val rbsp: ByteArray
        private var bytePos = 0
        private var bitPos = 0
        init {
            // Strip emulation-prevention bytes (00 00 03 -> 00 00) before parsing
            val out = ByteArray(data.size)
            var len = 0
            var zeroRun = 0
            for (b in data) {
                if (zeroRun >= 2 && b == 0x03.toByte()) {
                    zeroRun = 0
                    continue
                }
                out[len++] = b
                zeroRun = if (b == 0.toByte()) zeroRun + 1 else 0
            }
            rbsp = out.copyOf(len)
        }
        fun readBit(): Int {
            val byte = rbsp[bytePos].toInt() and 0xFF
            val bit = (byte shr (7 - bitPos)) and 1
            bitPos++
            if (bitPos == 8) { bitPos = 0; bytePos++ }
            return bit
        }
        fun readBits(n: Int): Int {
            var v = 0
            repeat(n) { v = (v shl 1) or readBit() }
            return v
        }
        fun readUE(): Int {
            var zeros = 0
            while (readBit() == 0) zeros++
            if (zeros == 0) return 0
            var v = 1
            repeat(zeros) { v = (v shl 1) or readBit() }
            return v - 1
        }
    }

    /** Parses width/height out of a raw H.264 SPS NAL (start code + header included). */
    private fun parseSpsDimensions(nal: ByteArray, startCodeLen: Int): Pair<Int, Int>? {
        return try {
            val rbspBytes = nal.copyOfRange(startCodeLen + 1, nal.size) // skip start code + NAL header byte
            val br = BitReader(rbspBytes)
            val profileIdc = br.readBits(8)
            br.readBits(8) // constraint flags + reserved
            br.readBits(8) // level_idc
            br.readUE()    // seq_parameter_set_id
            if (profileIdc in intArrayOf(100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)) {
                // High-profile fields we don't expect from our constrained-baseline
                // encoders; bail rather than risk a wrong parse.
                return null
            }
            br.readUE() // log2_max_frame_num_minus4
            val picOrderCntType = br.readUE()
            if (picOrderCntType == 0) {
                br.readUE() // log2_max_pic_order_cnt_lsb_minus4
            } else if (picOrderCntType == 1) {
                return null // not expected from our encoders; bail rather than mis-parse
            }
            br.readUE()  // max_num_ref_frames
            br.readBit() // gaps_in_frame_num_value_allowed_flag
            val picWidthInMbsMinus1 = br.readUE()
            val picHeightInMapUnitsMinus1 = br.readUE()
            val frameMbsOnlyFlag = br.readBit()
            if (frameMbsOnlyFlag == 0) br.readBit() // mb_adaptive_frame_field_flag
            br.readBit() // direct_8x8_inference_flag
            var cropLeft = 0; var cropRight = 0; var cropTop = 0; var cropBottom = 0
            if (br.readBit() == 1) { // frame_cropping_flag
                cropLeft = br.readUE(); cropRight = br.readUE()
                cropTop = br.readUE(); cropBottom = br.readUE()
            }
            val width = (picWidthInMbsMinus1 + 1) * 16 - (cropLeft + cropRight) * 2
            val frameHeightInMbs = (2 - frameMbsOnlyFlag) * (picHeightInMapUnitsMinus1 + 1)
            val height = frameHeightInMbs * 16 - (cropTop + cropBottom) * (2 - frameMbsOnlyFlag) * 2
            Pair(width, height)
        } catch (e: Exception) {
            Log.w(TAG, "SPS parse failed: ${e.message}")
            null
        }
    }

    // ── Codec setup ───────────────────────────────────────────────────────────

    private fun setupCodec(surface: Surface, streamWidth: Int, streamHeight: Int) {
        Log.i(TAG, "Configuring codec for actual stream size: ${streamWidth}x${streamHeight}")

        // Diagnostic: log what the MTK decoder actually claims to support at
        // this resolution before we commit to a 120fps-capture plan. If the
        // reported max is well under 120, decode-side smoothing is moot —
        // the hardware itself can't keep up regardless of how we pace output.
        try {
            val caps = MediaCodecList(MediaCodecList.REGULAR_CODECS)
                .codecInfos.firstOrNull { it.name == findH264Decoder() }
                ?.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
                ?.videoCapabilities
            val range = caps?.getSupportedFrameRatesFor(streamWidth, streamHeight)
            Log.i(TAG, "Decoder-reported supported frame rate at ${streamWidth}x${streamHeight}: $range")
        } catch (e: Exception) {
            Log.w(TAG, "Could not query decoder frame rate capability: ${e.message}")
        }

        val format = MediaFormat.createVideoFormat(
            MediaFormat.MIMETYPE_VIDEO_AVC,
            streamWidth,
            streamHeight
        ).apply {
            // Real-time priority — reduces decode latency
            // NOTE: do NOT set KEY_LOW_LATENCY or KEY_OPERATING_RATE here.
            // The MediaTek c2.mtk.avc.decoder crashes immediately (C2_CORRUPTED,
            // err 0xe) if those hints are present in the format at configure time.
            setInteger(MediaFormat.KEY_PRIORITY, 0)

            // Input buffer: large enough for SPS/PPS + IDR NAL units
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 512 * 1024)

            // Frame rate hint for the decoder (matches encoder config)
            setInteger(MediaFormat.KEY_FRAME_RATE, 60)

            // COLOR_FormatSurface = decode directly to Surface (zero-copy)
            setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        }

        // Find a hardware H.264 decoder
        val decoderName = findH264Decoder()
        Log.i(TAG, "Using decoder: $decoderName")

        codec = MediaCodec.createByCodecName(decoderName).also { c ->
            c.configure(format, surface, null, 0 /* decode */)
            c.start()
        }
    }

    private fun findH264Decoder(): String {
        // Prefer hardware decoders; MediaCodec.createDecoderByType picks the
        // highest-priority one automatically, which is usually HW on modern devices.
        val info = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        val name = info.name
        info.release()

        // Validate it's a hardware decoder (name usually contains 'omx' or 'c2.android' is SW)
        if (name.contains("google") || name.contains("sw", ignoreCase = true)) {
            Log.w(TAG, "Decoder '$name' may be software — latency will be higher")
        }
        return name
    }

    // ── Input queue thread ─────────────────────────────────────────────────────

    private fun startQueueThread() {
        queueThread = Thread({
            runQueueLoop()
        }, "NS-codec-input").apply {
            isDaemon = true
            start()
        }
    }

    private fun getStartCodeLen(buf: ByteArray, offset: Int, limit: Int): Int {
        if (offset + 2 >= limit) return 0
        if (buf[offset] == 0.toByte() && buf[offset+1] == 0.toByte()) {
            if (buf[offset+2] == 1.toByte()) return 3
            if (offset + 3 < limit && buf[offset+2] == 0.toByte() && buf[offset+3] == 1.toByte()) return 4
        }
        return 0
    }

    private fun runQueueLoop() {
        val c = codec ?: return
        var presentationUs = 0L
        // This no longer drives render timing — actual pacing happens in
        // drainOutput() against wall-clock time, since the source frame rate
        // can vary (60Hz decode-only, or a higher capture rate decimated
        // down). This is just a monotonic key for latencyMap bookkeeping.
        val frameDurationUs = 1_000L

        try {
            while (isRunning.get()) {
                val chunk = dataQueue.poll(5, TimeUnit.MILLISECONDS)
                if (chunk == null) {
                    drainOutput(c, false)
                    continue
                }

                // Determine if this NAL unit is SPS (7) or PPS (8)
                var flags = 0
                val startCodeLen = getStartCodeLen(chunk, 0, chunk.size)
                if (startCodeLen > 0 && startCodeLen < chunk.size) {
                    val nalType = chunk[startCodeLen].toInt() and 0x1F
                    if (nalType == 7 || nalType == 8) {
                        flags = MediaCodec.BUFFER_FLAG_CODEC_CONFIG
                    }
                }

                var idx = -1
                var retries = 0
                while (isRunning.get()) {
                    idx = c.dequeueInputBuffer(10_000L)
                    if (idx >= 0) break
                    // If input buffer is full, drain output to free up buffers.
                    // If we retry, drop frames to relieve Surface backpressure.
                    retries++
                    drainOutput(c, forceDrop = (retries > 0))
                }

                if (idx >= 0) {
                    val inputBuf = c.getInputBuffer(idx)
                    if (inputBuf != null) {
                        inputBuf.clear()
                        inputBuf.put(chunk)
                        
                        if (flags == 0) latencyMap[presentationUs] = System.nanoTime()
                        c.queueInputBuffer(idx, 0, chunk.size, presentationUs, flags)
                        
                        // Only advance presentation time for actual payload frames
                        if (flags == 0) presentationUs += frameDurationUs
                    }
                }

                // Drain output — render any available decoded frames to the Surface
                drainOutput(c, false)
            }
        } catch (e: InterruptedException) {
            Log.d(TAG, "Queue thread interrupted (shutdown)")
        } catch (e: IllegalStateException) {
            // Thrown when codec is released while dequeueInputBuffer is blocking.
            // Only report as error if we weren't intentionally stopping.
            if (isRunning.get()) {
                Log.e(TAG, "Queue loop codec error: ${e.message}", e)
                onError("Queue thread error: ${e.message}")
            } else {
                Log.d(TAG, "Queue thread: codec stopped during shutdown (expected)")
            }
        } catch (e: Exception) {
            if (isRunning.get()) {
                Log.e(TAG, "Queue loop error: ${e.message}", e)
                onError("Queue thread error: ${e.message}")
            }
        }
    }

    // ── Output draining ───────────────────────────────────────────────────────

    private fun drainOutput(c: MediaCodec, forceDrop: Boolean) {
        val bufferInfo = MediaCodec.BufferInfo()
        while (true) {
            val outIdx = c.dequeueOutputBuffer(bufferInfo, 0L)  // non-blocking
            when {
                outIdx >= 0 -> {
                    val queuedTime = latencyMap.remove(bufferInfo.presentationTimeUs)
                    if (queuedTime != null) {
                        totalLatencyNs += (System.nanoTime() - queuedTime)
                        latencyCount++
                    }
                    framesRendered++

                    // Pace to a real 60Hz wall-clock interval regardless of
                    // how fast frames actually arrive. This gives even 2:1 (or
                    // N:1) decimation when the source runs faster than the
                    // panel, instead of dropping only under buffer pressure.
                    val now = System.nanoTime()
                    val duePaced = (now - lastRenderNs) >= renderIntervalNs
                    val shouldRender = !forceDrop && duePaced

                    c.releaseOutputBuffer(outIdx, shouldRender)
                    if (shouldRender) {
                        lastRenderNs = now
                        if (!firstFrameFired.getAndSet(true)) {
                            onFirstFrame()
                        }
                    }
                }
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    Log.d(TAG, "Output format changed: ${c.outputFormat}")
                }
                else -> break  // INFO_TRY_AGAIN_LATER or INFO_OUTPUT_BUFFERS_CHANGED
            }
        }
    }

    // ── Cleanup ───────────────────────────────────────────────────────────────

    private fun releaseCodec() {
        try {
            codec?.stop()
            codec?.release()
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing codec: ${e.message}")
        } finally {
            codec = null
        }
    }
}