package com.manarz.myagent.core

import android.content.Context
import android.os.Build
import com.manarz.myagent.BuildConfig
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** One OkHttp for the whole app (connection pool + dispatcher shared). */
object Net {
    val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()
    val JSON = "application/json".toMediaType()

    /** Fire-and-forget GET (beacons). */
    fun ping(url: String) {
        http.newCall(Request.Builder().url(url).build()).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {}
            override fun onResponse(call: Call, response: Response) { response.close() }
        })
    }
}

/** Single source for the build tag carried by beacons and reports (iOS AppBuild). */
object AppBuild {
    /** Platform-tagged so the server log tells the two apps apart. */
    val tag: String get() = "android-b${BuildConfig.VERSION_CODE}"
    val header: String get() = "build ${BuildConfig.VERSION_CODE}"
}

/**
 * Milestones to the server's public /healthz as `?dbg=` — they land in the
 * server's access log, readable without device tooling (same channel as iOS).
 */
object Beacon {
    fun send(msg: String) {
        Breadcrumbs.add(msg)
        val t = Target.current()
        val u = android.net.Uri.parse(t.origin + "/healthz").buildUpon()
            .appendQueryParameter("dbg", "a-$msg").build().toString()
        Net.ping(u)
    }
}

/** Rolling event trail attached to crash + bug reports (iOS Breadcrumbs). */
object Breadcrumbs {
    private val q = Executors.newSingleThreadExecutor()
    private lateinit var file: File
    private const val MAX_BYTES = 96 * 1024

    fun init(ctx: Context) { file = File(ctx.filesDir, "breadcrumbs.log") }

    fun add(msg: String) {
        if (!::file.isInitialized) return
        val line = SimpleDateFormat("HH:mm:ss.SSS", Locale.US).format(Date()) + " " + msg + "\n"
        q.execute {
            runCatching {
                file.appendText(line)
                if (file.length() > MAX_BYTES) file.writeText(file.readLines().takeLast(400).joinToString("\n") + "\n")
            }
        }
    }

    fun tail(n: Int = 80): List<String> =
        if (!::file.isInitialized) emptyList() else runCatching { file.readLines().takeLast(n) }.getOrDefault(emptyList())
}

/** Queued POST /report — survives offline runs, flushed on launch/foreground. */
object ReportClient {
    private lateinit var dir: File

    fun init(ctx: Context) { dir = File(ctx.filesDir, "pending-reports").apply { mkdirs() } }

    fun submit(kind: String, text: String? = null, reason: String? = null, breadcrumbs: List<String>? = null,
               done: ((Boolean) -> Unit)? = null) {
        val p = JSONObject()
            .put("kind", kind)
            .put("build", AppBuild.tag)
            .put("device", "${Build.MANUFACTURER} ${Build.MODEL}")
            .put("os", "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
            .put("at", System.currentTimeMillis() / 1000.0)
            .put("breadcrumbs", JSONArray(breadcrumbs ?: Breadcrumbs.tail()))
        text?.let { p.put("text", it) }
        reason?.let { p.put("reason", it) }
        File(dir, UUID.randomUUID().toString() + ".json").writeText(p.toString())
        flush(done)
    }

    fun flush(done: ((Boolean) -> Unit)? = null) {
        val t = Target.current()
        if (!t.hasToken) { done?.invoke(false); return }
        val files = dir.listFiles()?.toList().orEmpty()
        if (files.isEmpty()) { done?.invoke(true); return }
        var remaining = files.size
        var allOk = true
        for (f in files) {
            val req = Request.Builder().url(t.url("/report"))
                .post(f.readText().toRequestBody(Net.JSON)).build()
            Net.http.newCall(req).enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) { allOk = false; finish() }
                override fun onResponse(call: Call, response: Response) {
                    if (response.code == 200) f.delete() else allOk = false
                    response.close(); finish()
                }
                private fun finish() { if (--remaining <= 0) done?.invoke(allOk) }
            })
        }
    }
}

/**
 * Uncaught exceptions → a crash report on the NEXT launch (iOS CrashReporter).
 * The trace is written synchronously in the handler; the network send happens
 * when the app comes back, so a crash during an outage still reaches us.
 */
object CrashReporter {
    private lateinit var marker: File
    private lateinit var alive: File

    fun install(ctx: Context) {
        marker = File(ctx.filesDir, "last-crash.txt")
        alive = File(ctx.filesDir, "alive.txt")
        val prev = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { th, e ->
            runCatching {
                marker.writeText("crash-${e.javaClass.simpleName}: ${e.message}\n" + e.stackTraceToString().take(6000))
                Breadcrumbs.add("CRASH ${e.javaClass.simpleName} on ${th.name}")
            }
            prev?.uncaughtException(th, e)
        }
    }

    /** Heartbeat so a SIGKILL (low-memory killer / swipe) can be told apart on relaunch. */
    fun heartbeat() { runCatching { alive.writeText(System.currentTimeMillis().toString()) } }

    fun reportIfCrashed() {
        if (marker.exists()) {
            val body = marker.readText()
            marker.delete()
            Beacon.send(body.lineSequence().first().take(120))
            ReportClient.submit(kind = "crash", reason = body)
        }
    }
}
