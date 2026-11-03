package com.manarz.myagent.chat

import android.Manifest
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import com.manarz.myagent.core.AppContext
import com.manarz.myagent.core.AppEvent
import com.manarz.myagent.core.Beacon
import com.manarz.myagent.core.Events
import com.manarz.myagent.core.Net
import com.manarz.myagent.core.Target
import com.manarz.myagent.voice.GadkVoice
import com.mymu.app.ui.ComposerInsertBus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.min

/**
 * Full-screen dictation (iOS Dictation.swift): record the user, POST the audio
 * to the voice server's /transcribe (ElevenLabs Scribe / Gemini), drop the text
 * into the MyMu composer (MyMu's own ComposerInsertBus — no vendored patch).
 * One mic: a live voice conversation ends before recording starts.
 */
object Dictation {
    enum class Phase { IDLE, RECORDING, TRANSCRIBING, FAILED }

    private val _phase = MutableStateFlow(Phase.IDLE)
    val phase: StateFlow<Phase> get() = _phase
    private val _seconds = MutableStateFlow(0)
    val seconds: StateFlow<Int> get() = _seconds
    private val _level = MutableStateFlow(0f)
    val level: StateFlow<Float> get() = _level
    private val _error = MutableStateFlow("")
    val error: StateFlow<String> get() = _error

    private const val MAX_SECONDS = 300
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var recorder: MediaRecorder? = null
    private var file: File? = null
    private var ticker: Runnable? = null
    private var meter: Runnable? = null
    private val http: OkHttpClient by lazy { Net.http.newBuilder().readTimeout(90, TimeUnit.SECONDS).build() }

    fun toggle() = when (_phase.value) {
        Phase.RECORDING -> stop()
        Phase.TRANSCRIBING -> Unit
        else -> start()
    }

    /** Drop a recording (the drawer left full height) — nothing is sent. */
    fun cancel() {
        if (_phase.value != Phase.RECORDING) { if (_phase.value == Phase.FAILED) _phase.value = Phase.IDLE; return }
        release()
        file?.delete()
        _phase.value = Phase.IDLE
        Beacon.send("dictate-cancel")
    }

    private fun start() {
        val ctx = AppContext.get()
        if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            return fail("Microphone permission needed")
        }
        if (GadkVoice.active.value) GadkVoice.stop()      // one mic
        val f = File(ctx.cacheDir, "dictation.m4a").also { it.delete() }
        val r = (if (Build.VERSION.SDK_INT >= 31) MediaRecorder(ctx) else @Suppress("DEPRECATION") MediaRecorder())
        try {
            r.setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioChannels(1)
            r.setAudioSamplingRate(16000)
            r.setAudioEncodingBitRate(48000)
            r.setOutputFile(f.absolutePath)
            r.prepare()
            r.start()
        } catch (e: Exception) {
            runCatching { r.release() }
            Beacon.send("dictate-start-FAIL-${e.javaClass.simpleName}")
            return fail("Couldn't start the microphone")
        }
        recorder = r; file = f
        _seconds.value = 0; _level.value = 0f; _error.value = ""
        _phase.value = Phase.RECORDING
        Beacon.send("dictate-start")
        val tick = object : Runnable {
            override fun run() {
                if (_phase.value != Phase.RECORDING) return
                _seconds.value += 1
                if (_seconds.value >= MAX_SECONDS) stop() else main.postDelayed(this, 1000)
            }
        }
        ticker = tick; main.postDelayed(tick, 1000)
        val m = object : Runnable {
            override fun run() {
                val rec = recorder ?: return
                val amp = runCatching { rec.maxAmplitude }.getOrDefault(0)
                _level.value = max(min(1f, amp / 9000f), _level.value * 0.72f)
                main.postDelayed(this, 80)
            }
        }
        meter = m; main.post(m)
    }

    private fun stop() {
        val f = file
        val ok = runCatching { recorder?.stop() }.isSuccess
        release()
        if (!ok || f == null || !f.exists() || f.length() < 1000) {
            Beacon.send("dictate-empty")
            return fail("Nothing recorded — try again")
        }
        _phase.value = Phase.TRANSCRIBING
        scope.launch { transcribe(f) }
    }

    private fun release() {
        ticker?.let { main.removeCallbacks(it) }; meter?.let { main.removeCallbacks(it) }
        ticker = null; meter = null
        runCatching { recorder?.release() }
        recorder = null
        _level.value = 0f
    }

    private suspend fun transcribe(f: File) {
        val t = Target.current()
        val result = kotlinx.coroutines.withContext(Dispatchers.IO) {
            runCatching {
                val req = Request.Builder().url(t.url("/transcribe"))
                    .post(f.asRequestBody("audio/mp4".toMediaType())).build()
                http.newCall(req).execute().use { r ->
                    val body = r.body?.string().orEmpty()
                    val obj = runCatching { JSONObject(body) }.getOrDefault(JSONObject())
                    if (r.code != 200 || !obj.has("text")) {
                        Beacon.send("dictate-FAIL-${r.code}")
                        throw IllegalStateException(obj.optString("message").ifEmpty { obj.optString("error").ifEmpty { "HTTP ${r.code}" } })
                    }
                    obj.optString("text")
                }
            }
        }
        f.delete()
        result.fold(
            onSuccess = { text ->
                _phase.value = Phase.IDLE
                if (text.isNotBlank()) {
                    Beacon.send("dictate-ok-${text.length}")
                    ComposerInsertBus.insert(text.trim())
                    Events.post(AppEvent.Dictated(text.trim()))
                } else Beacon.send("dictate-blank")
            },
            onFailure = { fail("Couldn't transcribe: ${it.message ?: "network error"}") },
        )
    }

    private fun fail(msg: String) {
        _error.value = msg
        _phase.value = Phase.FAILED
        scope.launch {
            delay(3500)
            if (_phase.value == Phase.FAILED) _phase.value = Phase.IDLE
        }
    }
}
