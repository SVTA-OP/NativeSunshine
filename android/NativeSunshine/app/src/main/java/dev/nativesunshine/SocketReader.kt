package dev.nativesunshine

import android.util.Log
import java.io.InputStream
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "NS:SocketReader"

/**
 * SocketReader — TCP server that accepts a single connection from the host.
 *
 * The ADB port forward maps:
 *   Linux  localhost:7878  ──USB──►  Android localhost:7878
 *
 * So we bind a ServerSocket on 7878 and wait for the GStreamer tcpclientsink
 * to connect. When the host stops streaming, the socket closes and we loop
 * back to accept() automatically, ready for reconnection.
 *
 * Threading model:
 *   - accept() loop runs on a dedicated IO thread (acceptThread)
 *   - read() loop runs on a second dedicated IO thread (readThread)
 *   - Callbacks are invoked on those threads; callers must marshal to UI
 *     thread if needed (MainActivity uses runOnUiThread for statusListener)
 *
 * @param port          Port to bind on (must match ADB_STREAM_PORT in config.sh)
 * @param onConnected   Called when a client connects — starts the decoder
 * @param onData        Called for each received chunk; buf is a reusable byte array
 * @param onDisconnected Called when the client disconnects (EOF / RST)
 * @param onError       Called on non-recoverable errors
 */
class SocketReader(
    private val port: Int,
    private val onConnected: () -> Unit,
    private val onData: (buf: ByteArray, offset: Int, length: Int) -> Unit,
    private val onDisconnected: () -> Unit,
    private val onError: (message: String) -> Unit
) {
    private val running = AtomicBoolean(false)
    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null

    // Read buffer — 64 KB is a good balance between memory and syscall overhead
    // for H.264 NAL units over a USB-ADB pipe.
    private val readBuffer = ByteArray(65536)

    fun start() {
        if (running.getAndSet(true)) return

        acceptThread = Thread({
            runAcceptLoop()
        }, "NS-accept").apply {
            isDaemon = true
            start()
        }
    }

    fun stop() {
        running.set(false)
        try {
            serverSocket?.close()
        } catch (_: Exception) {}
        acceptThread?.interrupt()
        acceptThread = null
    }

    // ── Accept loop ────────────────────────────────────────────────────────────
    private fun runAcceptLoop() {
        try {
            serverSocket = ServerSocket(port).also {
                it.reuseAddress = true
                it.soTimeout = 0   // Block indefinitely on accept()
            }
            Log.i(TAG, "Listening on port $port")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to bind port $port: ${e.message}")
            onError("Cannot bind port $port: ${e.message}")
            return
        }

        while (running.get()) {
            try {
                Log.d(TAG, "Waiting for connection...")
                val client: Socket = serverSocket!!.accept()
                Log.i(TAG, "Client connected: ${client.remoteSocketAddress}")

                // Optimize socket for low-latency streaming:
                client.tcpNoDelay = true           // Disable Nagle (send immediately)
                client.setPerformancePreferences(0, 1, 0)  // prioritize latency

                onConnected()
                readFromSocket(client)
                onDisconnected()

            } catch (e: SocketException) {
                if (!running.get()) break  // Normal shutdown
                Log.w(TAG, "Socket exception (will retry): ${e.message}")
            } catch (e: Exception) {
                if (!running.get()) break
                Log.e(TAG, "Accept error: ${e.message}")
            }
        }

        Log.i(TAG, "Accept loop exiting")
    }

    // ── Read loop ─────────────────────────────────────────────────────────────
    private fun readFromSocket(socket: Socket) {
        val stream: InputStream = socket.getInputStream()
        try {
            while (running.get()) {
                val bytesRead = stream.read(readBuffer)
                if (bytesRead == -1) {
                    Log.i(TAG, "Stream EOF — host disconnected")
                    break
                }
                if (bytesRead > 0) {
                    onData(readBuffer, 0, bytesRead)
                }
            }
        } catch (e: SocketException) {
            if (running.get()) {
                Log.w(TAG, "Read socket exception: ${e.message}")
            }
        } catch (e: Exception) {
            if (running.get()) {
                Log.e(TAG, "Read error: ${e.message}")
            }
        } finally {
            try { socket.close() } catch (_: Exception) {}
        }
    }
}
