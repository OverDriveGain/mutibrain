package com.manarz.myagent.voice

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
import androidx.core.content.ContextCompat
import com.manarz.myagent.core.Beacon
import com.manarz.myagent.core.Config
import com.manarz.myagent.core.Music
import com.manarz.myagent.core.Net
import com.manarz.myagent.core.Target
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Native realtime voice client — the Android port of iOS GadkVoice.swift.
 * Same ADK `/run_live` protocol as the web client and the iPhone app:
 *   1. POST {origin}/apps/{app}/users/{uid}/sessions?token=   -> { id }
 *   2. WS   {origin}/run_live?app_name&user_id&session_id&modalities=AUDIO&stages=1&token
 *   3. send {"blob":{"mimeType":"audio/pcm;rate=16000","data":<b64 Int16LE>}}  (~200 ms chunks)
 *   4. recv content.parts[].inlineData (audio/pcm @24k) -> play;
 *           outputTranscription -> caption; turnComplete; interrupted (barge-in);
 *           {"mymuStage": …} connect progress; functionCall/functionResponse -> moves, music
 *   5. end  {"close":true}
 *
 * Audio: the platform's VOICE_COMMUNICATION path (hardware AEC/NS/AGC where the
 * device has them) in MODE_IN_COMMUNICATION, output on the loudspeaker unless a
 * headset/Bluetooth device is connected — the standard call behavior, no hacks
 * (Manar's "standard audio model" ruling applies here too).
 */
object GadkVoice {
    private val _active = MutableStateFlow(false)
    val active: StateFlow<Boolean> get() = _active
    private val _answering = MutableStateFlow(false)
    val answering: StateFlow<Boolean> get() = _answering
    private val _caption = MutableStateFlow("")
    val caption: StateFlow<String> get() = _caption
    /** ✓/✗ progress line; a ✗ line survives stop() so failures stay visible. */
    private val _stageText = MutableStateFlow("")
    val stageText: StateFlow<String> get() = _stageText
    /** "loaded25/50/75/99" while connecting, "" once Google is connected. */
    private val _connectStage = MutableStateFlow("")
    val connectStage: StateFlow<String> get() = _connectStage
    private val _micLevel = MutableStateFlow(0f)
    val micLevel: StateFlow<Float> get() = _micLevel
    private val _outLevel = MutableStateFlow(0f)
    val outLevel: StateFlow<Float> get() = _outLevel

    data class Move(val name: String, val duration: Double?)
    private val _moves = MutableSharedFlow<Move>(extraBufferCapacity = 8, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    val moves: SharedFlow<Move> get() = _moves
    /** ask_the_brain fired — the home refreshes /pending a beat later. */
    private val _brainDispatched = MutableSharedFlow<Unit>(extraBufferCapacity = 4, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    val brainDispatched: SharedFlow<Unit> get() = _brainDispatched

    private lateinit var app: Context
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Bumped by every start()/stop(): late callbacks of an older conversation are ignored. */
    private val epoch = AtomicInteger(0)
    private var ws: WebSocket? = null
    private var record: AudioRecord? = null
    private var track: AudioTrack? = null
    private var effects = mutableListOf<android.media.audiofx.AudioEffect>()
    private var micThread: Thread? = null
    private var playThread: Thread? = null
    private val playQueue = LinkedBlockingQueue<ShortArray>()
    @Volatile private var queuedFrames = 0
    @Volatile private var turnDone = true
    private var newAgentTurn = true
    private var endRequested = false
    private var focusRequest: AudioFocusRequest? = null
    private var settleTicks = 0

    fun init(ctx: Context) { app = ctx.applicationContext }

    fun toggle() = if (_active.value) stop() else start()

    // ---------------------------------------------------------------- control

    fun start() {
        endRequested = false
        if (_active.value) return
        if (ContextCompat.checkSelfPermission(app, android.Manifest.permission.RECORD_AUDIO)
            != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            Beacon.send("mic-DENIED")
            _stageText.value = "✗ Microphone permission needed — allow it, then tap again"
            return
        }
        val my = epoch.incrementAndGet()
        _active.value = true; _caption.value = ""; _answering.value = false
        newAgentTurn = true; turnDone = true
        _stageText.value = "Connecting to server…"
        _connectStage.value = "loaded25"
        Beacon.send("start")
        // Keep the process foreground (screen off / backgrounded mid-talk).
        runCatching { ContextCompat.startForegroundService(app, Intent(app, VoiceService::class.java)) }
            .onFailure { Beacon.send("fgs-FAIL-${it.javaClass.simpleName}") }
        Music.host?.duck(true)
        scope.launch { connectAndRun(my) }
    }

    fun stop() {
        if (!_active.value) return
        Beacon.send("stop-called")
        epoch.incrementAndGet()
        turnDone = true
        _active.value = false; _answering.value = false; _caption.value = ""
        if (!_stageText.value.startsWith("✗")) _stageText.value = ""
        _connectStage.value = ""; _micLevel.value = 0f; _outLevel.value = 0f
        ws?.let { runCatching { it.send("{\"close\":true}"); it.close(1000, null) } }
        ws = null
        teardownAudio()
        Music.host?.duck(false)
        runCatching { app.stopService(Intent(app, VoiceService::class.java)) }
    }

    private fun current(e: Int) = epoch.get() == e && _active.value

    private fun fail(e: Int, msg: String) {
        main.post {
            if (epoch.get() != e) return@post
            stop()
            _stageText.value = msg
        }
    }

    // ---------------------------------------------------------------- connect

    private fun connectAndRun(e: Int) {
        val t = Target.current()
        val sid = try {
            createSession(t)
        } catch (ex: Exception) {
            Beacon.send("start-FAILED-${ex.message}")
            return fail(e, "✗ Couldn't reach the server — check connection, tap to retry")
        }
        Beacon.send("session-ok")
        if (!current(e)) return Beacon.send("start-abandoned-session")
        main.post { if (current(e)) { _stageText.value = "✓ Server up — starting audio…"; _connectStage.value = "loaded50" } }
        try {
            startAudio(e)
        } catch (ex: Exception) {
            Beacon.send("audio-FAILED-${ex.javaClass.simpleName}-${ex.message}")
            teardownAudio()
            return fail(e, "✗ Couldn't start the microphone — tap to retry")
        }
        Beacon.send("engine-ok")
        main.post {
            if (!current(e)) { teardownAudio(); return@post Beacon.send("start-abandoned-engine") }
            openSocket(t, sid, e)
            _stageText.value = "✓ Server up — connecting to Google…"; _connectStage.value = "loaded75"
            Beacon.send("ws-opening")
        }
    }

    private fun createSession(t: Target): String {
        val url = android.net.Uri.parse("${t.origin}/apps/${t.app}/users/${Config.userId}/sessions")
            .buildUpon().apply { if (t.token.isNotEmpty()) appendQueryParameter("token", t.token) }.build().toString()
        val req = Request.Builder().url(url).post("{}".toRequestBody(Net.JSON)).build()
        Net.http.newCall(req).execute().use { r ->
            if (!r.isSuccessful) throw IllegalStateException("session create failed ${r.code}")
            return JSONObject(r.body!!.string()).getString("id")
        }
    }

    private fun openSocket(t: Target, sid: String, e: Int) {
        val wsOrigin = t.origin.replaceFirst("https://", "wss://").replaceFirst("http://", "ws://")
        val url = android.net.Uri.parse("$wsOrigin/run_live").buildUpon()
            .appendQueryParameter("app_name", t.app)
            .appendQueryParameter("user_id", Config.userId)
            .appendQueryParameter("session_id", sid)
            .appendQueryParameter("modalities", "AUDIO")
            .appendQueryParameter("stages", "1")
            .apply { if (t.token.isNotEmpty()) appendQueryParameter("token", t.token) }
            .build().toString()
        // OkHttp wants http(s) for the upgrade request.
        val httpUrl = url.replaceFirst("wss://", "https://").replaceFirst("ws://", "http://")
        ws = Net.http.newWebSocket(Request.Builder().url(httpUrl).build(), object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                main.post { if (ws === webSocket && epoch.get() == e) handleEvent(text) }
            }
            override fun onFailure(webSocket: WebSocket, tt: Throwable, response: Response?) {
                Beacon.send("ws-FAIL-${tt.message}")
                main.post {
                    if (ws === webSocket && _active.value) {
                        val asked = endRequested
                        stop()
                        if (asked) Beacon.send("ended-by-agent") else _stageText.value = "✗ Connection lost — tap to reconnect"
                    }
                }
            }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                main.post {
                    if (ws === webSocket && _active.value) { stop(); Beacon.send("ended-by-agent-$code") }
                }
            }
        })
    }

    // ---------------------------------------------------------------- audio

    private val am get() = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    @SuppressLint("MissingPermission")  // checked in start()
    private fun startAudio(e: Int) {
        val am = am
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        routeOutput(am)
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
        focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(attrs).build().also { am.requestAudioFocus(it) }

        // ---- mic: 16 kHz mono PCM16 straight from the platform (it resamples)
        val inMin = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val rec = AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, 16000,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, max(inMin, 6400) * 2)
        if (rec.state != AudioRecord.STATE_INITIALIZED) { rec.release(); throw IllegalStateException("mic init") }
        val sid = rec.audioSessionId
        if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(sid)?.let { it.enabled = true; effects += it }
        if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(sid)?.let { it.enabled = true; effects += it }
        if (AutomaticGainControl.isAvailable()) AutomaticGainControl.create(sid)?.let { it.enabled = true; effects += it }
        Beacon.send("fx-aec${AcousticEchoCanceler.isAvailable()}-ns${NoiseSuppressor.isAvailable()}")
        record = rec

        // ---- playback: 24 kHz mono PCM16, same session id so AEC hears it
        val outMin = AudioTrack.getMinBufferSize(24000, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val tr = AudioTrack.Builder()
            .setAudioAttributes(attrs)
            .setAudioFormat(AudioFormat.Builder().setSampleRate(24000)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
            .setBufferSizeInBytes(max(outMin, 9600) * 2)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setSessionId(sid)
            .build()
        track = tr
        tr.play()
        rec.startRecording()

        micThread = Thread({ micLoop(rec, e) }, "gadk-mic").apply { start() }
        playThread = Thread({ playLoop(tr, e) }, "gadk-play").apply { start() }
        Beacon.send("route-${describeRoute(am)}")
    }

    /** Speaker unless the user has a headset / Bluetooth / USB audio connected. */
    private fun routeOutput(am: AudioManager) {
        if (Build.VERSION.SDK_INT >= 31) {
            val devs = am.availableCommunicationDevices
            val personal = devs.firstOrNull {
                it.type in setOf(AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_WIRED_HEADSET,
                    AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_BLE_HEADSET)
            }
            val pick = personal ?: devs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            pick?.let { am.setCommunicationDevice(it) }
        } else {
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = !(am.isWiredHeadsetOn || am.isBluetoothScoOn)
        }
    }

    private fun describeRoute(am: AudioManager): String =
        if (Build.VERSION.SDK_INT >= 31) "dev${am.communicationDevice?.type}" else "spk${@Suppress("DEPRECATION") am.isSpeakerphoneOn}"

    private fun micLoop(rec: AudioRecord, e: Int) {
        val chunk = ShortArray(3200)            // ~200 ms @ 16 kHz, matches the web client
        var firstFire = true
        var logFrames = 0; var logPeak = 0
        while (epoch.get() == e) {
            var got = 0
            while (got < chunk.size && epoch.get() == e) {
                val n = rec.read(chunk, got, chunk.size - got)
                if (n <= 0) { if (n < 0) Beacon.send("mic-read-ERR-$n"); break }
                got += n
            }
            if (got <= 0 || epoch.get() != e) continue
            if (firstFire) { firstFire = false; Beacon.send("tap-first-fire-16000Hz") }
            var peak = 0
            for (i in 0 until got) peak = max(peak, abs(chunk[i].toInt()))   // Int math: no -32768 overflow
            val lvl = min(1f, peak / 9000f)
            _micLevel.value = max(lvl, _micLevel.value * 0.72f)
            logFrames += got; logPeak = max(logPeak, peak)
            if (logFrames >= 16000 * 5) { Beacon.send("mic-peak-$logPeak"); logFrames = 0; logPeak = 0 }
            val bytes = ByteArray(got * 2)
            for (i in 0 until got) { val v = chunk[i].toInt(); bytes[2 * i] = v.toByte(); bytes[2 * i + 1] = (v shr 8).toByte() }
            val b64 = Base64.encodeToString(bytes, Base64.NO_WRAP)
            ws?.send("{\"blob\":{\"mimeType\":\"audio/pcm;rate=16000\",\"data\":\"$b64\"}}")
        }
    }

    private fun playLoop(tr: AudioTrack, e: Int) {
        while (epoch.get() == e) {
            val buf = try { playQueue.poll(200, java.util.concurrent.TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { null }
            if (buf == null) { if (_outLevel.value > 0.01f) _outLevel.value *= 0.6f else _outLevel.value = 0f; continue }
            var peak = 0
            var i = 0
            while (i < buf.size) { peak = max(peak, abs(buf[i].toInt())); i += 16 }
            _outLevel.value = max(min(peak / 32768f * 2.2f, 1f), _outLevel.value * 0.75f)
            tr.write(buf, 0, buf.size)        // blocking: paces playback in real time
            queuedFrames = max(0, queuedFrames - buf.size)
            if (queuedFrames == 0 && playQueue.isEmpty()) main.post { settleAnswering() }
        }
    }

    private fun teardownAudio() {
        val rec = record; val tr = track
        record = null; track = null
        playQueue.clear(); queuedFrames = 0
        micThread = null; playThread = null
        runCatching { rec?.stop() }; runCatching { rec?.release() }
        runCatching { tr?.pause(); tr?.flush() }; runCatching { tr?.release() }
        effects.forEach { runCatching { it.release() } }; effects.clear()
        val am = am
        focusRequest?.let { am.abandonAudioFocusRequest(it) }; focusRequest = null
        if (Build.VERSION.SDK_INT >= 31) runCatching { am.clearCommunicationDevice() }
        else @Suppress("DEPRECATION") { am.isSpeakerphoneOn = false }
        am.mode = AudioManager.MODE_NORMAL
    }

    private fun flushPlayback() {
        playQueue.clear(); queuedFrames = 0
        track?.let { runCatching { it.pause(); it.flush(); it.play() } }
        settleAnswering()
    }

    /** turnComplete arrives before the voice has played out: drop `answering` once the queue drains. */
    private fun settleAnswering() {
        if (!_answering.value || !turnDone) return
        if (queuedFrames == 0 && playQueue.isEmpty()) { _answering.value = false; return }
        main.postDelayed({
            if (!_answering.value || !turnDone) return@postDelayed
            if (++settleTicks > 12) { queuedFrames = 0; _answering.value = false; Beacon.send("answering-forced-off"); return@postDelayed }
            settleAnswering()
        }, 1000)
    }

    // ---------------------------------------------------------------- events

    private fun handleEvent(json: String) {
        val ev = runCatching { JSONObject(json) }.getOrNull() ?: return

        ev.optString("mymuStage").takeIf { it.isNotEmpty() }?.let { st ->
            Beacon.send("stage-$st")
            when (st) {
                "server_connected" -> _stageText.value = "✓ Server up — connecting to Google…"
                "gemini_connecting" -> { _stageText.value = "✓ Server up · Google connecting…"; _connectStage.value = "loaded99" }
                "gemini_connected" -> { _stageText.value = ""; _connectStage.value = "" }
            }
            return
        }

        if (ev.optBoolean("interrupted")) { turnDone = true; flushPlayback() }

        val parts = ev.optJSONObject("content")?.optJSONArray("parts")
        if (parts != null) for (i in 0 until parts.length()) {
            val part = parts.optJSONObject(i) ?: continue
            part.optJSONObject("functionCall")?.let { fc ->
                val name = fc.optString("name")
                _stageText.value = "⚙️ ${name.replace('_', ' ')}…"
                when (name) {
                    "end_conversation" -> endRequested = true
                    "ask_the_brain" -> _brainDispatched.tryEmit(Unit)
                    "perform_move" -> fc.optJSONObject("args")?.let { a ->
                        val mv = a.optString("move").lowercase().filter { it.isLetter() }
                        val d = a.opt("duration_s")?.toString()?.toDoubleOrNull()
                        if (mv.isNotEmpty()) _moves.tryEmit(Move(mv, d))
                    }
                }
            }
            part.optJSONObject("functionResponse")?.optJSONObject("response")?.let { resp -> handleToolResponse(resp) }
            part.optJSONObject("inlineData")?.let { inline ->
                if (inline.optString("mimeType").startsWith("audio/pcm")) {
                    if (!_answering.value) Beacon.send("got-audio")
                    _answering.value = true; turnDone = false; settleTicks = 0
                    _stageText.value = ""; _connectStage.value = ""
                    playPcm(inline.optString("data"))
                }
            }
        }
        ev.optJSONObject("outputTranscription")?.let { ot ->
            val t = ot.optString("text")
            if (t.isNotEmpty()) {
                if (newAgentTurn) { _caption.value = ""; newAgentTurn = false }
                _caption.value = if (ot.optBoolean("finished")) t else _caption.value + t
                _answering.value = true
            }
        }
        if (ev.optBoolean("turnComplete")) { turnDone = true; newAgentTurn = true; settleAnswering() }
    }

    /** Music tools: play (hand-off or keep_listening) and transport control. */
    private fun handleToolResponse(resp: JSONObject) {
        when (resp.optString("status")) {
            "playing" -> {
                val songs = resp.optJSONArray("songs") ?: return
                if (songs.length() == 0) return
                if (resp.optBoolean("keep_listening")) {
                    Beacon.send("play-music-${songs.length()}-keeplistening")
                    Music.host?.play(songs)
                } else {
                    Beacon.send("play-music-${songs.length()}-handoff")
                    stop()
                    main.postDelayed({ Music.host?.play(songs) }, 300)   // after the call-mode teardown
                }
            }
            "music_control" -> resp.optString("action").takeIf { it.isNotEmpty() }?.let {
                Beacon.send("music-ctl-$it"); Music.host?.control(it)
            }
        }
    }

    private var b64Drops = 0

    private fun playPcm(b64: String) {
        val bytes = runCatching { Base64.decode(b64.replace('-', '+').replace('_', '/'), Base64.DEFAULT) }.getOrNull()
        if (bytes == null) { if (++b64Drops == 1 || b64Drops % 50 == 0) Beacon.send("b64-drop-$b64Drops"); return }
        val n = bytes.size / 2
        if (n == 0) return
        val s = ShortArray(n)
        for (i in 0 until n) s[i] = ((bytes[2 * i].toInt() and 0xff) or (bytes[2 * i + 1].toInt() shl 8)).toShort()
        queuedFrames += n
        playQueue.offer(s)
    }

}
