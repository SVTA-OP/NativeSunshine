package dev.nativesunshine

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

/**
 * MainActivity — fullscreen host for the video surface.
 *
 * Responsibilities:
 *  - Present a fullscreen SurfaceView that fills the entire screen
 *  - Start ReceiverService as a foreground service
 *  - Pass the Surface to the service once it is ready
 *  - Show status overlay (waiting / streaming / error)
 *  - Keep the screen on via KEEP_SCREEN_ON window flag
 */
class MainActivity : AppCompatActivity(), SurfaceHolder.Callback {

    private lateinit var surfaceView: SurfaceView
    private lateinit var statusText: TextView
    private lateinit var statsText: TextView
    private var receiverService: ReceiverService? = null
    private var isBound = false

    // ── Service connection ────────────────────────────────────────────────────
    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            val b = binder as ReceiverService.LocalBinder
            receiverService = b.getService()
            isBound = true

            // If the surface is already available (race condition), hand it over now
            val holder = surfaceView.holder
            if (holder.surface.isValid) {
                receiverService?.setSurface(holder.surface)
            }

            receiverService?.setStatusListener { status ->
                runOnUiThread { updateStatus(status) }
            }
            
            receiverService?.setStatsListener { fps, mbps, latencyMs ->
                runOnUiThread {
                    statsText.text = String.format("FPS: %d | %.1f Mbps | Latency: %d ms", fps, mbps, latencyMs)
                }
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            receiverService = null
            isBound = false
        }
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Keep screen on
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        setContentView(R.layout.activity_main)

        surfaceView = findViewById(R.id.surface_view)
        statusText  = findViewById(R.id.status_text)
        statsText   = findViewById(R.id.stats_text)

        surfaceView.holder.addCallback(this)

        // Go fully immersive
        hideSystemUI()

        // Start + bind the receiver service
        val intent = Intent(this, ReceiverService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)

        updateStatus(StreamStatus.WAITING)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemUI()
    }

    override fun onDestroy() {
        super.onDestroy()
        if (isBound) {
            unbindService(serviceConnection)
            isBound = false
        }
    }

    // ── SurfaceHolder.Callback ─────────────────────────────────────────────────
    override fun surfaceCreated(holder: SurfaceHolder) {
        // Hand the Surface to the service so the decoder can render into it
        receiverService?.setSurface(holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        // Nothing needed — SurfaceView handles resize automatically
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        receiverService?.setSurface(null)
    }

    // ── Status overlay ─────────────────────────────────────────────────────────
    private fun updateStatus(status: StreamStatus) {
        when (status) {
            StreamStatus.WAITING -> {
                statusText.visibility = View.VISIBLE
                statusText.text = getString(R.string.status_waiting)
                statsText.visibility = View.GONE
            }
            StreamStatus.CONNECTING -> {
                statusText.visibility = View.VISIBLE
                statusText.text = getString(R.string.status_connecting)
                statsText.visibility = View.GONE
            }
            StreamStatus.STREAMING -> {
                // Hide status text, show performance overlay
                statusText.visibility = View.GONE
                statsText.visibility = View.VISIBLE
            }
            is StreamStatus.ERROR -> {
                statusText.visibility = View.VISIBLE
                statusText.text = getString(R.string.status_error, status.message)
                statsText.visibility = View.GONE
            }
        }
    }

    // ── Immersive UI ───────────────────────────────────────────────────────────
    private fun hideSystemUI() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.let { controller ->
                controller.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                controller.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_FULLSCREEN
            )
        }
    }
}

/** Status values emitted by ReceiverService to the UI. */
sealed class StreamStatus {
    object WAITING    : StreamStatus()
    object CONNECTING : StreamStatus()
    object STREAMING  : StreamStatus()
    data class ERROR(val message: String) : StreamStatus()
}
