package dev.nativesunshine

import android.media.MediaCodec
import android.media.MediaCodecInfo
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

        try {
            setupCodec(surface)
        } catch (e: Exception) {
            Log.e(TAG, "Codec setup failed: ${e.message}", e)
            isRunning.set(false)
            onError("Codec setup failed: ${e.message}")
            return
        }

        startQueueThread()
        Log.i(TAG, "Decoder started")
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
                    try {
                        dataQueue.put(frame) // Blocks applying backpressure
                    } catch (e: InterruptedException) { 
                        return 
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

    // ── Codec setup ───────────────────────────────────────────────────────────

    private fun setupCodec(surface: Surface) {
        // Use the 16-aligned dimensions matching the host stream.
        // The host already computes (screenPx / 16) * 16 before streaming,
        // so we mirror that calculation here so decoder and stream agree exactly.
        val metrics = android.content.res.Resources.getSystem().displayMetrics
        val streamWidth  = (metrics.widthPixels  / 16) * 16
        val streamHeight = (metrics.heightPixels / 16) * 16

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
        val frameDurationUs = 1_000_000L / 60  // 60 fps

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
                    
                    // If forceDrop is true, return buffer to codec immediately without rendering.
                    // This prevents deadlocks when the Surface is consuming slower than the feed (e.g. 120Hz feed on 60Hz display).
                    c.releaseOutputBuffer(outIdx, !forceDrop)
                    if (!forceDrop && !firstFrameFired.getAndSet(true)) {
                        onFirstFrame()
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
