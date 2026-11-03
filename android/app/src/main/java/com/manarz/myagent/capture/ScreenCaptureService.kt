package com.manarz.myagent.capture

import android.annotation.SuppressLint
import android.app.Activity
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.manarz.myagent.MainActivity
import com.manarz.myagent.R
import com.manarz.myagent.core.Beacon
import com.manarz.myagent.core.Notify
import java.io.ByteArrayOutputStream
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Whole-screen capture into screenpipe memory — the Android counterpart of the
 * iOS ScreenBroadcast extension (SampleHandler). MediaProjection → VirtualDisplay
 * → ImageReader at ≤480 px wide, ~1 fps, JPEG q40 → POST /ingest. Also, like the
 * broadcast's .audioApp, the other apps' playback audio (AudioPlaybackCapture,
 * where the playing app allows it) → 20 s WAV segments → /ingest-audio.
 *
 * Android 14+: the consent result is single-use and the FGS (type
 * mediaProjection) must be foreground BEFORE getMediaProjection() is called.
 * The user can end it from the system status chip: MediaProjection.Callback
 * .onStop fires → we stop and nudge "tap to start again" (iOS BroadcastWatch).
 */
class ScreenCaptureService : Service() {
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var thread: HandlerThread? = null
    private var appAudio: AudioRecord? = null
    private var appAudioThread: Thread? = null
    @Volatile private var running = false
    private var stoppedByUser = false
    private var lastSent = 0L
    private var started = 0L
    private var lastAlive = 0L
    private var frames = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> { stoppedByUser = true; stopSelf(); return START_NOT_STICKY }
            ACTION_START -> {}
            else -> { stopSelf(); return START_NOT_STICKY }   // a sticky restart has no consent token
        }
        val code = intent.getIntExtra(EXTRA_CODE, Activity.RESULT_CANCELED)
        @Suppress("DEPRECATION")
        val data: Intent? = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(EXTRA_DATA, Intent::class.java)
            else intent.getParcelableExtra(EXTRA_DATA)
        if (code != Activity.RESULT_OK || data == null) { stopSelf(); return START_NOT_STICKY }

        // foreground FIRST (Android 14 rule), then the projection
        ServiceCompat.startForeground(this, 42, notification(),
            if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION else 0)
        if (running) teardown()   // a second consent replaces the first session
        val mpm = getSystemService(MediaProjectionManager::class.java)
        val p = runCatching { mpm.getMediaProjection(code, data) }.getOrNull()
        if (p == null) { Beacon.send("bcast-projection-NULL"); stopSelf(); return START_NOT_STICKY }
        projection = p
        p.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                Beacon.send("screen-capture-ended")
                Handler(Looper.getMainLooper()).post { stopSelf() }
            }
        }, Handler(Looper.getMainLooper()))
        startVideo(p)
        startAppAudio(p)
        running = true
        stoppedByUser = false
        started = SystemClock.elapsedRealtime(); lastAlive = started; frames = 0
        CaptureState.screenRunning.value = true
        Beacon.send("bcast-start")
        return START_NOT_STICKY
    }

    @SuppressLint("WrongConstant")
    private fun startVideo(p: MediaProjection) {
        val metrics = resources.displayMetrics
        val scale = min(1f, MAX_WIDTH.toFloat() / metrics.widthPixels)
        val w = (metrics.widthPixels * scale).roundToInt().coerceAtLeast(2)
        val h = (metrics.heightPixels * scale).roundToInt().coerceAtLeast(2)
        val dpi = (metrics.densityDpi * scale).roundToInt().coerceAtLeast(1)
        val t = HandlerThread("screen-capture").apply { start() }
        thread = t
        val handler = Handler(t.looper)
        val r = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        r.setOnImageAvailableListener({ ir -> onFrame(ir, w, h) }, handler)
        reader = r
        display = p.createVirtualDisplay("myagent-screenpipe", w, h, dpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, r.surface, null, handler)
    }

    private fun onFrame(ir: ImageReader, w: Int, h: Int) {
        val img = runCatching { ir.acquireLatestImage() }.getOrNull() ?: return
        try {
            val now = SystemClock.elapsedRealtime()
            heartbeat(now)
            if (now - lastSent < MIN_INTERVAL_MS) return
            val plane = img.planes[0]
            val pixelStride = plane.pixelStride
            val rowPad = plane.rowStride - pixelStride * w
            val bmp = Bitmap.createBitmap(w + rowPad / pixelStride, h, Bitmap.Config.ARGB_8888)
            bmp.copyPixelsFromBuffer(plane.buffer)
            val crop = if (rowPad > 0) Bitmap.createBitmap(bmp, 0, 0, w, h) else bmp
            val out = ByteArrayOutputStream()
            crop.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
            if (crop !== bmp) crop.recycle()
            bmp.recycle()
            lastSent = now
            frames++
            ScreenIngest.sendFrame(out.toByteArray())
        } catch (e: Exception) {
            Beacon.send("bcast-frame-ERR-${e.javaClass.simpleName}")
        } finally {
            img.close()
        }
    }

    private fun heartbeat(now: Long) {
        if (now - lastAlive < 60_000) return
        lastAlive = now
        Beacon.send("bcast-alive-${(now - started) / 60_000}min-frames$frames-sent${CaptureState.screenSent.value}")
    }

    /** Other apps' playback (media/game/unknown) → 16 kHz mono WAV segments. Optional: needs RECORD_AUDIO. */
    @SuppressLint("MissingPermission")
    private fun startAppAudio(p: MediaProjection) {
        if (Build.VERSION.SDK_INT < 29) return
        if (ContextCompat.checkSelfPermission(this, android.Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) return
        val cfg = AudioPlaybackCaptureConfiguration.Builder(p)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()
        val fmt = AudioFormat.Builder().setSampleRate(16000).setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO).build()
        val rec = runCatching {
            AudioRecord.Builder().setAudioPlaybackCaptureConfig(cfg).setAudioFormat(fmt)
                .setBufferSizeInBytes(16000 * 2).build()
        }.getOrNull() ?: return Beacon.send("bcast-appaudio-unavailable")
        if (rec.state != AudioRecord.STATE_INITIALIZED) { rec.release(); return }
        appAudio = rec
        val seg = SegmentBuffer(AudioIngest())
        rec.startRecording()
        appAudioThread = Thread({
            val buf = ByteArray(3200)
            var heard = false
            while (running || appAudio === rec) {
                val n = rec.read(buf, 0, buf.size)
                if (n <= 0) { if (appAudio !== rec) break; continue }
                // silence-only segments are worthless to ASR: only ship once something played
                if (!heard) heard = buf.anyLoud(n)
                if (heard) seg.add(buf, n)
            }
            seg.flush()
        }, "screen-appaudio").apply { start() }
    }

    private fun ByteArray.anyLoud(n: Int): Boolean {
        var i = 0
        while (i + 1 < n) {
            val v = (this[i].toInt() and 0xff) or (this[i + 1].toInt() shl 8)
            if (kotlin.math.abs(v.toShort().toInt()) > 300) return true
            i += 2
        }
        return false
    }

    private fun teardown() {
        running = false
        val rec = appAudio; appAudio = null
        runCatching { rec?.stop() }; runCatching { rec?.release() }
        runCatching { display?.release() }; display = null
        runCatching { reader?.close() }; reader = null
        thread?.quitSafely(); thread = null
        runCatching { projection?.stop() }; projection = null
    }

    override fun onDestroy() {
        val wasRunning = running || CaptureState.screenRunning.value
        teardown()
        CaptureState.screenRunning.value = false
        if (wasRunning) {
            Beacon.send("bcast-finished-after${(SystemClock.elapsedRealtime() - started) / 1000}s-frames$frames")
            if (!stoppedByUser) nudgeRestart(this)
        }
        super.onDestroy()
    }

    private fun notification() = NotificationCompat.Builder(this, Notify.CH_CAPTURE)
        .setSmallIcon(R.drawable.ic_notification)
        .setContentTitle("Recording your screen into memory")
        .setContentText("Screenpipe · tap to open")
        .setContentIntent(openScreenpipe(this))
        .addAction(0, "Stop", PendingIntent.getService(this, 2,
            Intent(this, ScreenCaptureService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE))
        .setOngoing(true)
        .build()

    companion object {
        const val ACTION_START = "com.manarz.myagent.capture.SCREEN_START"
        const val ACTION_STOP = "com.manarz.myagent.capture.SCREEN_STOP"
        private const val EXTRA_CODE = "code"
        private const val EXTRA_DATA = "data"
        private const val MAX_WIDTH = 480          // iOS maxWidth
        private const val JPEG_QUALITY = 40        // iOS jpegQuality 0.4
        private const val MIN_INTERVAL_MS = 1000L  // ~1 fps

        fun start(ctx: Context, resultCode: Int, data: Intent) {
            val i = Intent(ctx, ScreenCaptureService::class.java).setAction(ACTION_START)
                .putExtra(EXTRA_CODE, resultCode).putExtra(EXTRA_DATA, data)
            ContextCompat.startForegroundService(ctx, i)
        }

        fun stop(ctx: Context) {
            if (!CaptureState.screenRunning.value) return
            ctx.startService(Intent(ctx, ScreenCaptureService::class.java).setAction(ACTION_STOP))
        }

        /** Opens the app on the Screenpipe page (MainActivity handles EXTRA_SCREENPIPE). */
        fun openScreenpipe(ctx: Context): PendingIntent = PendingIntent.getActivity(ctx, 3,
            Intent(ctx, MainActivity::class.java).putExtra(MainActivity.EXTRA_SCREENPIPE, true)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

        /** "Screen broadcast stopped — tap to start again" (iOS BroadcastWatch.nudgeRestart). */
        fun nudgeRestart(ctx: Context, title: String = "Screen recording stopped",
                         body: String = "Your screen is no longer being recorded — tap to start it again.") {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            nm.notify(43, NotificationCompat.Builder(ctx, Notify.CH_AGENT)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(openScreenpipe(ctx))
                .setAutoCancel(true)
                .build())
        }
    }
}
