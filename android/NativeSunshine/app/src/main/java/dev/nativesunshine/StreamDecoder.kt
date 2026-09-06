package dev.nativesunshine

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentLinkedQueue
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
 *   - MediaCodec operates in asynchronous event-driven mode (MediaCodec.Callback)
 *   - Hardware input buffers are fed on-demand with zero thread polling
 *   - Decoded output is released immediately to Surface on hardware callback
 *
 * @param onFirstFrame  Callback fired on the first successfully rendered frame
 * @param onError       Callback fired on a non-recoverable codec error
 * @param onStatsUpdate Callback fired every second with (fps, mbps, latencyMs)
 */
class StreamDecoder(
    private val refreshRate: Float = 60f,
    private val onFirstFrame: () -> Unit,
    private val onError: (message: String) -> Unit,
    private val onStatsUpdate: ((Int, Float, Long) -> Unit)? = null
) {
    private var codec: MediaCodec? = null
    private val isRunning = AtomicBoolean(false)
    private val firstFrameFired = AtomicBoolean(false)
    private var pendingSurface: Surface? = null
    private var codecConfigured = false

    private val bufferLock = Any()

    // Queue of byte arrays from SocketReader when codec input buffers are busy
    // Capped to 2 frames to strictly prevent buffer bloat (Scrcpy / Moonlight pattern)
    private val dataQueue = ArrayBlockingQueue<ByteArray>(2)
    private val availableInputBuffers = ConcurrentLinkedQueue<Int>()

    // Performance tracking
    private var framesDequeued = 0
    private var framesRendered = 0
    private var framesDroppedPacing = 0
    private var framesDroppedCongested = 0
    private var bytesReceived = 0L
    private var lastStatsTime = System.currentTimeMillis()
    private val latencyMap = java.util.concurrent.ConcurrentHashMap<Long, Long>()
    private var totalLatencyNs = 0L
    private var latencyCount = 0

    private val targetFps = refreshRate.coerceAtMost(60f)
    private var presentationUs = 0L
    private val frameDurationUs = 1_000L

    // NAL unit framing buffers
    private val frameBuf = ByteArray(2 * 1024 * 1024) // 2MB max frame
    private var frameBufLen = 0

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
        synchronized(bufferLock) {
            dataQueue.clear()
            availableInputBuffers.clear()
        }
        latencyMap.clear()
        frameBufLen = 0
        presentationUs = 0L
        pendingSurface = surface
        codecConfigured = false

        Log.i(TAG, "Decoder waiting for SPS to configure async codec (capped to ${targetFps.toInt()} FPS)")
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
        
        var lastStartIdx = -1
        var lastAdvance = 0
        var searchIdx = 0
        while (searchIdx <= frameBufLen - 3) {
            if (frameBuf[searchIdx] == 0.toByte() && frameBuf[searchIdx+1] == 0.toByte() && frameBuf[searchIdx+2] == 1.toByte()) {
                lastStartIdx = searchIdx
                lastAdvance = 3
                if (searchIdx > 0 && frameBuf[searchIdx - 1] == 0.toByte()) {
                    lastStartIdx = searchIdx - 1
                    lastAdvance = 4
                }
            }
            searchIdx++
        }
        
        if (lastStartIdx > 0) {
            // Extract all NAL units up to the last start code as a single chunk
            val frame = frameBuf.copyOfRange(0, lastStartIdx)

            if (!codecConfigured) {
                // Scan the chunk to find the SPS start code
                var spsStart = -1
                var i = 0
                while (i <= frame.size - 4) {
                    if (frame[i] == 0.toByte() && frame[i+1] == 0.toByte() && frame[i+2] == 1.toByte()) {
                        val nalType = frame[i+3].toInt() and 0x1F
                        if (nalType == 7) {
                            spsStart = if (i > 0 && frame[i-1] == 0.toByte()) i - 1 else i
                            break
                        }
                    }
                    i++
                }
                
                if (spsStart >= 0) {
                    val sclen = getStartCodeLen(frame, spsStart, frame.size)
                    if (sclen > 0) {
                        val dims = parseSpsDimensions(frame, spsStart + sclen)
                        val surface = pendingSurface
                        if (dims != null && surface != null) {
                            try {
                                setupCodec(surface, dims.first, dims.second)
                                codecConfigured = true
                                Log.i(TAG, "Async decoder started")
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
            }

            if (codecConfigured) {
                val c = codec
                var handled = false
                if (c != null && isRunning.get()) {
                    var idx: Int? = null
                    synchronized(bufferLock) {
                        idx = availableInputBuffers.poll()
                        if (idx == null) {
                            while (!dataQueue.offer(frame)) {
                                dataQueue.poll()
                                framesDroppedCongested++
                            }
                            handled = true
                        }
                    }
                    if (idx != null) {
                        writeChunkToInputBuffer(c, idx!!, frame)
                        handled = true
                    }
                }
                if (!handled) {
                    synchronized(bufferLock) {
                        while (!dataQueue.offer(frame)) {
                            dataQueue.poll()
                            framesDroppedCongested++
                        }
                    }
                }
            }
            
            // Shift the remaining data (including the last start code) to the beginning
            val remaining = frameBufLen - lastStartIdx
            System.arraycopy(frameBuf, lastStartIdx, frameBuf, 0, remaining)
            frameBufLen = remaining
        }
        
        bytesReceived += length
        checkStats()
    }

    private fun checkStats() {
        val now = System.currentTimeMillis()
        if (now - lastStatsTime >= 1000) {
            val mbps = (bytesReceived * 8f) / 1_000_000f
            val avgLatencyMs = if (latencyCount > 0) (totalLatencyNs / latencyCount) / 1_000_000L else 0L
            Log.i(TAG, "Stats: rendered=$framesRendered, dequeued=$framesDequeued, droppedPacing=$framesDroppedPacing, droppedCongested=$framesDroppedCongested, dataQ=${dataQueue.size}, ${"%.2f".format(mbps)} Mbps, ${avgLatencyMs}ms latency")
            onStatsUpdate?.invoke(framesRendered, mbps, avgLatencyMs)
            framesDequeued = 0
            framesRendered = 0
            framesDroppedPacing = 0
            framesDroppedCongested = 0
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
        synchronized(bufferLock) {
            dataQueue.clear()
            availableInputBuffers.clear()
        }
        latencyMap.clear()
        codecConfigured = false
        pendingSurface = null
        releaseCodec()
    }

    /** Update the render surface (called when SurfaceView changes). */
    fun updateSurface(surface: Surface?) {
        pendingSurface = surface
        if (surface == null || !surface.isValid) {
            Log.d(TAG, "Output surface cleared or invalid")
            return
        }
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

        // Find a hardware H.264 decoder first to inspect capabilities/quirks
        val decoderName = findH264Decoder()
        Log.i(TAG, "Using decoder: $decoderName")
        val isMtk = decoderName.contains("mtk", ignoreCase = true)

        val format = MediaFormat.createVideoFormat(
            MediaFormat.MIMETYPE_VIDEO_AVC,
            streamWidth,
            streamHeight
        ).apply {
            // Real-time priority — reduces decode latency
            setInteger(MediaFormat.KEY_PRIORITY, 0)

            // Request high operating rate so the VPU clocks up for real-time 60fps decoding
            try {
                setInteger(MediaFormat.KEY_OPERATING_RATE, 120)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to set KEY_OPERATING_RATE: ${e.message}")
            }

            // Zero-reorder hints (no B-frames in stream, output immediately)
            try {
                setInteger("max-num-reorder-frames", 0)
                setInteger("output-reorder-depth", 0)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to set reorder depth: ${e.message}")
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                try {
                    setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                    Log.i(TAG, "Low latency mode enabled natively for $decoderName")
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to set KEY_LOW_LATENCY: ${e.message}")
                }
            }

            // Input buffer: large enough for SPS/PPS + IDR NAL units
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 512 * 1024)

            // Frame rate hint for the decoder
            setInteger(MediaFormat.KEY_FRAME_RATE, targetFps.toInt())

            // COLOR_FormatSurface = decode directly to Surface (zero-copy)
            setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        }

        codec = MediaCodec.createByCodecName(decoderName).also { c ->
            c.setCallback(object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(mc: MediaCodec, inputIndex: Int) {
                    if (!isRunning.get()) return
                    onInputBufferReady(mc, inputIndex)
                }

                override fun onOutputBufferAvailable(mc: MediaCodec, outputIndex: Int, info: MediaCodec.BufferInfo) {
                    if (!isRunning.get()) return
                    handleDecodedOutput(mc, outputIndex, info)
                }

                override fun onError(mc: MediaCodec, e: MediaCodec.CodecException) {
                    Log.e(TAG, "MediaCodec callback error: ${e.message}", e)
                    if (isRunning.get()) {
                        onError("Decoder callback error: ${e.message}")
                    }
                }

                override fun onOutputFormatChanged(mc: MediaCodec, format: MediaFormat) {
                    Log.d(TAG, "Output format changed: $format")
                }
            })
            c.configure(format, surface, null, 0 /* decode */)
            c.start()
        }
    }

    private fun findH264Decoder(): String {
        val codecList = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        for (info in codecList.codecInfos) {
            if (!info.isEncoder) {
                val types = info.supportedTypes
                if (types.contains(MediaFormat.MIMETYPE_VIDEO_AVC)) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        if (info.isHardwareAccelerated) {
                            return info.name
                        }
                    } else {
                        // Fallback check for older devices
                        if (!info.name.contains("google", ignoreCase = true) && !info.name.contains("sw", ignoreCase = true)) {
                            return info.name
                        }
                    }
                }
            }
        }
        
        // Fallback to default if no hardware decoder explicitly found
        val defaultInfo = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        val defaultName = defaultInfo.name
        defaultInfo.release()
        Log.w(TAG, "Hardware decoder not explicitly found, falling back to default: $defaultName")
        return defaultName
    }

    private fun getStartCodeLen(buf: ByteArray, offset: Int, limit: Int): Int {
        if (offset + 2 >= limit) return 0
        if (buf[offset] == 0.toByte() && buf[offset+1] == 0.toByte()) {
            if (buf[offset+2] == 1.toByte()) return 3
            if (offset + 3 < limit && buf[offset+2] == 0.toByte() && buf[offset+3] == 1.toByte()) return 4
        }
        return 0
    }

    private fun onInputBufferReady(mc: MediaCodec, inputIndex: Int) {
        val chunk = synchronized(bufferLock) {
            dataQueue.poll()
        } ?: run {
            availableInputBuffers.offer(inputIndex)
            return
        }
        writeChunkToInputBuffer(mc, inputIndex, chunk)
    }

    private fun writeChunkToInputBuffer(c: MediaCodec, idx: Int, chunk: ByteArray) {
        try {
            val inputBuf = c.getInputBuffer(idx) ?: return
            inputBuf.clear()
            inputBuf.put(chunk)

            // Determine if this NAL unit is SPS (7) or PPS (8)
            var flags = 0
            var i = 0
            while (i <= chunk.size - 4) {
                if (chunk[i] == 0.toByte() && chunk[i+1] == 0.toByte() && chunk[i+2] == 1.toByte()) {
                    val nalType = chunk[i+3].toInt() and 0x1F
                    if (nalType == 7 || nalType == 8) {
                        flags = MediaCodec.BUFFER_FLAG_CODEC_CONFIG
                        break
                    }
                }
                i++
            }

            val pts = presentationUs
            if (flags == 0) {
                if (latencyMap.size > 120) {
                    latencyMap.clear()
                }
                latencyMap[pts] = System.nanoTime()
                presentationUs += frameDurationUs
            }

            c.queueInputBuffer(idx, 0, chunk.size, pts, flags)
        } catch (e: Exception) {
            Log.w(TAG, "writeChunkToInputBuffer error: ${e.message}")
        }
    }

    private fun handleDecodedOutput(c: MediaCodec, outIdx: Int, info: MediaCodec.BufferInfo) {
        val queuedTime = latencyMap.remove(info.presentationTimeUs)
        if (queuedTime != null) {
            val decodeLatencyNs = System.nanoTime() - queuedTime
            totalLatencyNs += decodeLatencyNs
            latencyCount++
        }

        framesDequeued++
        val isSurfaceValid = pendingSurface?.isValid == true
        val shouldRender = isSurfaceValid && isRunning.get()

        try {
            c.releaseOutputBuffer(outIdx, shouldRender)
            if (shouldRender) {
                framesRendered++
                if (!firstFrameFired.getAndSet(true)) {
                    onFirstFrame()
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "releaseOutputBuffer error: ${e.message}")
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