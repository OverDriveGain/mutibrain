package com.manarz.myagent.capture

import android.util.Base64
import com.manarz.myagent.core.Config
import com.manarz.myagent.core.Net
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Live capture state for the Screenpipe page — one process holds both the
 * capture and the UI here, so these are real (iOS could only show the mic;
 * its screen counters lived in the broadcast extension's process).
 */
object CaptureState {
    val screenRunning = MutableStateFlow(false)
    val screenSent = MutableStateFlow(0)
    val screenFailed = MutableStateFlow(0)
    val lastError = MutableStateFlow<String?>(null)
    val micRunning = MutableStateFlow(false)
    /** The last mic segment upload succeeded ("Uploading" vs "Recording"). */
    val micConnected = MutableStateFlow(false)
    val micSentKB = MutableStateFlow(0.0)
}

private fun iso(d: Date): String = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
    .apply { timeZone = TimeZone.getTimeZone("UTC") }.format(d)

/** Shared POST: Bearer token, JSON body, at most one request in flight (a busy client drops). */
private class OneInFlight {
    val busy = AtomicBoolean(false)
    fun post(path: String, body: JSONObject, done: (Boolean, Int) -> Unit) {
        if (!busy.compareAndSet(false, true)) return
        val req = Request.Builder()
            .url(Config.screenpipeBase.trimEnd('/') + path)
            .header("Authorization", "Bearer ${Config.screenpipeToken}")
            .post(body.toString().toRequestBody(Net.JSON))
            .build()
        Net.http.newCall(req).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) { busy.set(false); done(false, 0) }
            override fun onResponse(call: Call, response: Response) {
                val code = response.code; response.close()
                busy.set(false); done(code == 200, code)
            }
        })
    }
}

/** POST /ingest — one JPEG frame (iOS IngestClient). Drops a frame while one is still in flight. */
object ScreenIngest {
    private val client = OneInFlight()

    /** Strictly increasing, also across reinstalls: central dedupes on max_source_frame_id. */
    private fun nextFrameId(): Long {
        val prev = Config.string("ingest.frameId")?.toLongOrNull() ?: 0L
        val n = maxOf(prev + 1, System.currentTimeMillis())
        Config.setString("ingest.frameId", n.toString())
        return n
    }

    fun sendFrame(jpeg: ByteArray, at: Date = Date()) {
        if (client.busy.get()) return
        val frame = JSONObject()
            .put("frame_id", nextFrameId())
            .put("timestamp", iso(at))
            .put("app_name", "Android")
            .put("capture_trigger", "periodic")
            .put("text_source", "ocr")
            .put("image_b64", Base64.encodeToString(jpeg, Base64.NO_WRAP))
            .put("image_mime", "image/jpeg")
        val body = JSONObject().put("agent_id", Config.screenpipeAgentId).put("frames", JSONArray().put(frame))
        client.post("/ingest", body) { ok, code ->
            if (ok) { CaptureState.screenSent.value++; CaptureState.lastError.value = null }
            else { CaptureState.screenFailed.value++; CaptureState.lastError.value = "screen HTTP $code" }
        }
    }
}

/** POST /ingest-audio — one audio segment (iOS AudioIngestClient). */
class AudioIngest(private val onResult: (Boolean, Int) -> Unit = { _, _ -> }) {
    private val client = OneInFlight()

    fun sendSegment(audio: ByteArray, mime: String, at: Date) {
        val chunk = JSONObject()
            .put("chunk_id", System.currentTimeMillis())
            .put("timestamp", iso(at))
            .put("audio_b64", Base64.encodeToString(audio, Base64.NO_WRAP))
            .put("audio_mime", mime)
        val body = JSONObject().put("agent_id", Config.screenpipeAgentId).put("chunks", JSONArray().put(chunk))
        client.post("/ingest-audio", body, onResult)
    }
}

/** 16-bit PCM → a WAV file (the shape central's ASR takes, same as the iOS broadcast's app audio). */
fun wavOf(pcm: ByteArray, sampleRate: Int = 16000, channels: Int = 1): ByteArray {
    val out = ByteArrayOutputStream(44 + pcm.size)
    fun le32(v: Int) { out.write(v and 0xff); out.write(v shr 8 and 0xff); out.write(v shr 16 and 0xff); out.write(v shr 24 and 0xff) }
    fun le16(v: Int) { out.write(v and 0xff); out.write(v shr 8 and 0xff) }
    out.write("RIFF".toByteArray()); le32(36 + pcm.size)
    out.write("WAVE".toByteArray())
    out.write("fmt ".toByteArray()); le32(16); le16(1); le16(channels)
    le32(sampleRate); le32(sampleRate * channels * 2); le16(channels * 2); le16(16)
    out.write("data".toByteArray()); le32(pcm.size)
    out.write(pcm)
    return out.toByteArray()
}

/** Accumulates PCM16 and ships a WAV segment every [seconds]. */
class SegmentBuffer(private val ingest: AudioIngest, private val seconds: Int = 20, private val sampleRate: Int = 16000) {
    private val buf = ByteArrayOutputStream()
    private var start = Date()
    private val full = sampleRate * 2 * seconds

    @Synchronized fun add(pcm: ByteArray, len: Int) {
        buf.write(pcm, 0, len)
        if (buf.size() >= full || Date().time - start.time >= seconds * 1000L) flush()
    }

    @Synchronized fun flush() {
        if (buf.size() == 0) { start = Date(); return }
        val pcm = buf.toByteArray(); val at = start
        buf.reset(); start = Date()
        ingest.sendSegment(wavOf(pcm, sampleRate), "audio/wav", at)
    }
}
