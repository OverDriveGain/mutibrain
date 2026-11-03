package com.manarz.myagent.capture

import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.manarz.myagent.R
import com.manarz.myagent.core.Beacon
import com.manarz.myagent.core.Config
import com.manarz.myagent.core.Notify
import com.manarz.myagent.voice.GadkVoice
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.io.File
import java.util.Date

/**
 * Always-on microphone into screenpipe memory — the Android port of iOS
 * AudioStreamer: opt-in (the choice persists), records continuously in 20 s
 * AAC segments (16 kHz mono, audio/mp4) and POSTs each to /ingest-audio.
 *
 * Android gives the mic to ONE recorder at a time, so while a voice
 * conversation runs (GadkVoice) this pauses and resumes right after — the
 * conversation always wins the microphone.
 */
class MicCaptureService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var recorder: MediaRecorder? = null
    private var file: File? = null
    private var segStart = Date()
    private var paused = false
    private var hb = 0
    private val ingest = AudioIngest { ok, code ->
        CaptureState.micConnected.value = ok
        if (!ok) CaptureState.lastError.value = "mic HTTP $code"
    }
    private val rotate = Runnable { rotateSegment() }
    private val heartbeat = object : Runnable {
        override fun run() {
            hb++
            if (hb % 6 == 0) Beacon.send("sp-mic-hb-$hb-kb${CaptureState.micSentKB.value.toInt()}-rec${recorder != null}-paused$paused")
            main.postDelayed(this, 10_000)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) { Config.setBool(KEY, false); stopSelf(); return START_NOT_STICKY }
        if (ContextCompat.checkSelfPermission(this, android.Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            Beacon.send("sp-mic-DENIED"); stopSelf(); return START_NOT_STICKY
        }
        ServiceCompat.startForeground(this, 44, notification(),
            if (Build.VERSION.SDK_INT >= 30) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0)
        if (CaptureState.micRunning.value) return START_NOT_STICKY
        CaptureState.micRunning.value = true
        scope.launch {
            GadkVoice.active.collect { talking ->
                if (talking && !paused) { paused = true; finishSegment(); Beacon.send("sp-mic-paused-for-voice") }
                else if (!talking && paused) { paused = false; startSegment(); Beacon.send("sp-mic-resumed") }
            }
        }
        paused = GadkVoice.active.value
        if (!paused) startSegment()
        main.postDelayed(heartbeat, 10_000)
        Beacon.send("sp-mic-streaming-android")
        // sticky restarts would be background mic-FGS starts (refused on Android 14):
        // the app resumes the mic itself on its next open (CaptureModule.autoStart)
        return START_NOT_STICKY
    }

    private fun startSegment() {
        val f = File(cacheDir, "mic-${System.currentTimeMillis()}.m4a")
        val r = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(this) else @Suppress("DEPRECATION") MediaRecorder()
        try {
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioSamplingRate(16000)
            r.setAudioChannels(1)
            r.setAudioEncodingBitRate(32000)
            r.setOutputFile(f.absolutePath)
            r.prepare()
            r.start()
        } catch (e: Exception) {
            Beacon.send("sp-mic-record-FAILED-${e.javaClass.simpleName}")
            runCatching { r.release() }; f.delete()
            main.postDelayed({ if (!paused && recorder == null && CaptureState.micRunning.value) startSegment() }, 5000)
            return
        }
        recorder = r; file = f; segStart = Date()
        main.postDelayed(rotate, SEGMENT_MS)
    }

    /** Stop the current segment and ship it. */
    private fun finishSegment() {
        main.removeCallbacks(rotate)
        val r = recorder ?: return
        val f = file
        recorder = null; file = null
        val ok = runCatching { r.stop() }.isSuccess    // throws when nothing was recorded yet
        runCatching { r.release() }
        if (f == null) return
        if (ok && f.length() > 0) {
            val bytes = f.readBytes()
            CaptureState.micSentKB.value += bytes.size / 1024.0
            ingest.sendSegment(bytes, "audio/mp4", segStart)
        }
        f.delete()
    }

    private fun rotateSegment() {
        finishSegment()
        if (!paused && CaptureState.micRunning.value) startSegment()
    }

    override fun onDestroy() {
        CaptureState.micRunning.value = false
        main.removeCallbacks(heartbeat)
        finishSegment()
        scope.cancel()
        CaptureState.micConnected.value = false
        Beacon.send("sp-mic-stopped")
        super.onDestroy()
    }

    private fun notification() = NotificationCompat.Builder(this, Notify.CH_CAPTURE)
        .setSmallIcon(R.drawable.ic_notification)
        .setContentTitle("Recording your microphone into memory")
        .setContentText("Screenpipe · tap to open")
        .setContentIntent(ScreenCaptureService.openScreenpipe(this))
        .addAction(0, "Stop", PendingIntent.getService(this, 5,
            Intent(this, MicCaptureService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE))
        .setOngoing(true)
        .build()

    companion object {
        private const val ACTION_STOP = "com.manarz.myagent.capture.MIC_STOP"
        const val KEY = "micAlwaysOn"
        private const val SEGMENT_MS = 20_000L

        val enabled: Boolean get() = Config.bool(KEY)

        /** The user turned the mic on (persists). */
        fun userStart(ctx: Context) { Config.setBool(KEY, true); start(ctx) }

        /** The user turned it off (persists). */
        fun userStop(ctx: Context) { Config.setBool(KEY, false); ctx.stopService(Intent(ctx, MicCaptureService::class.java)) }

        fun start(ctx: Context) {
            runCatching { ContextCompat.startForegroundService(ctx, Intent(ctx, MicCaptureService::class.java)) }
                .onFailure { Beacon.send("sp-mic-fgs-FAIL-${it.javaClass.simpleName}") }
        }
    }
}
