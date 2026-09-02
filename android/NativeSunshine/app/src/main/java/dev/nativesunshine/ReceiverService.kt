package dev.nativesunshine

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.view.Surface
import androidx.core.app.NotificationCompat

private const val TAG = "NS:ReceiverService"
private const val CHANNEL_ID = "native_sunshine_stream"
private const val NOTIFICATION_ID = 1

/**
 * ReceiverService — foreground service that owns the streaming pipeline.
 *
 * Lifecycle:
 *  1. Started as a foreground service from MainActivity
 *  2. Bound by MainActivity to exchange the Surface reference
 *  3. Owns SocketReader (TCP server) and StreamDecoder (MediaCodec)
 *  4. Coordinates handoff: SocketReader feeds data → StreamDecoder renders to Surface
 *  5. Restarts the socket listener automatically on disconnect
 *
 * The service continues running even if the activity is backgrounded,
 * so the stream stays alive when the user switches apps.
 */
class ReceiverService : Service() {

    // ── Binder ────────────────────────────────────────────────────────────────
    inner class LocalBinder : Binder() {
        fun getService(): ReceiverService = this@ReceiverService
    }
    private val binder = LocalBinder()

    // ── Pipeline components ───────────────────────────────────────────────────
    private var socketReader: SocketReader? = null
    private var streamDecoder: StreamDecoder? = null

    // Volatile so MainActivity's UI thread sees updates from the service thread
    @Volatile private var currentSurface: Surface? = null
    private var statusListener: ((StreamStatus) -> Unit)? = null
    private var statsListener: ((Int, Float, Long) -> Unit)? = null

    // ── Service lifecycle ─────────────────────────────────────────────────────
    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, buildNotification("Waiting for stream…"), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, buildNotification("Waiting for stream…"))
        }
        Log.i(TAG, "Service created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startPipeline()
        return START_STICKY  // Restart if killed by system
    }

    override fun onBind(intent: Intent): IBinder = binder

    override fun onDestroy() {
        Log.i(TAG, "Service destroying — stopping pipeline")
        stopPipeline()
        super.onDestroy()
    }

    // ── Public API (called from MainActivity via bound connection) ────────────

    /** Called when the SurfaceView's Surface is created/destroyed. */
    fun setSurface(surface: Surface?) {
        Log.d(TAG, "setSurface: ${surface?.isValid}")
        currentSurface = surface
        streamDecoder?.updateSurface(surface)
    }

    /** Register a callback to receive StreamStatus updates on the calling thread. */
    fun setStatusListener(listener: (StreamStatus) -> Unit) {
        statusListener = listener
    }

    /** Register a callback to receive performance stats (fps, mbps, latencyMs). */
    fun setStatsListener(listener: (Int, Float, Long) -> Unit) {
        statsListener = listener
    }

    // ── Pipeline control ──────────────────────────────────────────────────────

    private fun getStreamPort(): Int {
        val prefs = androidx.preference.PreferenceManager.getDefaultSharedPreferences(this)
        return prefs.getString("stream_port", "7878")?.toIntOrNull() ?: 7878
    }

    private fun sendControlMessage() {
        Thread {
            try {
                val prefs = androidx.preference.PreferenceManager.getDefaultSharedPreferences(this)
                val fps = prefs.getString("host_fps", "60")?.toIntOrNull() ?: 60
                val bitrate = prefs.getString("host_bitrate", "8000")?.toIntOrNull() ?: 8000
                
                val json = """{"fps":$fps,"bitrate":$bitrate}"""
                val socket = java.net.Socket("127.0.0.1", 7879)
                socket.outputStream.write(json.toByteArray())
                socket.close()
                Log.i(TAG, "Sent control message to host")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to send control message: ${e.message}")
            }
        }.start()
    }

    private fun sendErrorToHost(errorMsg: String) {
        Thread {
            try {
                val escapedMsg = errorMsg.replace("\"", "\\\"").replace("\n", "\\n")
                val json = """{"error":"$escapedMsg"}"""
                val socket = java.net.Socket("127.0.0.1", 7879)
                socket.outputStream.write(json.toByteArray())
                socket.close()
                Log.i(TAG, "Sent error message to host")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to send error message: ${e.message}")
            }
        }.start()
    }

    private fun startPipeline() {
        stopPipeline()

        sendControlMessage()
        val streamPort = getStreamPort()

        Log.i(TAG, "Starting pipeline — port ${streamPort}")
        emitStatus(StreamStatus.WAITING)

        streamDecoder = StreamDecoder(
            onFirstFrame = {
                emitStatus(StreamStatus.STREAMING)
                updateNotification("Streaming")
            },
            onError = { msg ->
                Log.e(TAG, "Decoder error: $msg")
                emitStatus(StreamStatus.ERROR(msg))
                sendErrorToHost(msg)
                // Stop the decoder cleanly; SocketReader's accept() loop will
                // trigger a fresh decoder start on the next host connection.
                streamDecoder?.stop()
            },
            onStatsUpdate = { fps, mbps, latencyMs ->
                statsListener?.invoke(fps, mbps, latencyMs)
            }
        )

        socketReader = SocketReader(
            port = streamPort,
            onConnected = {
                Log.i(TAG, "Host connected")
                emitStatus(StreamStatus.CONNECTING)
                updateNotification("Connected — starting decode…")
                // Always create a fresh decoder on each new connection to guarantee clean state
                streamDecoder?.stop()
                streamDecoder = StreamDecoder(
                    onFirstFrame = {
                        emitStatus(StreamStatus.STREAMING)
                        updateNotification("Streaming")
                    },
                    onError = { msg ->
                        Log.e(TAG, "Decoder error: $msg")
                        emitStatus(StreamStatus.ERROR(msg))
                        sendErrorToHost(msg)
                        streamDecoder?.stop()
                    },
                    onStatsUpdate = { fps, mbps, latencyMs ->
                        statsListener?.invoke(fps, mbps, latencyMs)
                    }
                )
                streamDecoder?.start(currentSurface)
            },
            onData = { buf, offset, length ->
                streamDecoder?.feedData(buf, offset, length)
            },
            onDisconnected = {
                Log.i(TAG, "Host disconnected — waiting for reconnect")
                streamDecoder?.stop()
                emitStatus(StreamStatus.WAITING)
                updateNotification("Waiting for stream…")
                // SocketReader auto-loops back to accept() — no restart needed here
            },
            onError = { msg ->
                Log.e(TAG, "Socket error: $msg")
                emitStatus(StreamStatus.ERROR(msg))
            }
        )

        socketReader?.start()
    }

    private fun stopPipeline() {
        socketReader?.stop()
        socketReader = null
        streamDecoder?.stop()
        streamDecoder = null
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun emitStatus(status: StreamStatus) {
        statusListener?.invoke(status)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "NativeSunshine Stream",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "USB display stream receiver"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("NativeSunshine")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification(text))
    }

}
