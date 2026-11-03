package com.manarz.myagent.push

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationManagerCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.manarz.myagent.core.AppEvent
import com.manarz.myagent.core.Beacon
import com.manarz.myagent.core.Config
import com.manarz.myagent.core.Events
import com.manarz.myagent.core.Net
import com.manarz.myagent.core.Target
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONObject
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Push (FCM) — the Android counterpart of iOS PushNotifications.swift.
 *
 * The server sends DATA-only messages carrying the same payload as its APNs
 * frame (shell/fcm.py); [PushService] renders them per category, the action
 * buttons run in [ActionReceiver] without opening the app.
 *
 * Inert without Firebase: if app/google-services.json wasn't built in, no
 * FirebaseApp exists — push stays off, nothing crashes, nothing is sent.
 */
object PushModule {
    const val EXTRA_ACK_ID = "push.ackReminder"
    private const val SNOOZE_MINUTES = 10

    @Volatile var enabled = false
        private set
    private lateinit var app: Context

    fun init(ctx: Context) {
        app = ctx.applicationContext
        enabled = runCatching { FirebaseApp.getApps(app).isNotEmpty() }.getOrDefault(false)
        if (!enabled) { Beacon.send("fcm-off-no-firebase"); return }
        reregister()
    }

    /** Post the current FCM token for the logged-in subscriber (login change / foreground). */
    fun reregister() {
        if (!enabled) return
        runCatching {
            FirebaseMessaging.getInstance().token
                .addOnSuccessListener { postToken(it) }
                .addOnFailureListener { Beacon.send("fcm-token-FAIL-${it.javaClass.simpleName}") }
        }
    }

    /** FCM handed us a (new) token, or we re-assert the known one. */
    internal fun postToken(token: String) {
        val t = Target.current()
        if (!t.hasToken || token.isEmpty()) return
        // a rotated token, or a different subscriber than last time: retire the old pairing
        val last = Config.string(KEY_TOKEN)
        val lastApp = Config.string(KEY_APP)
        if (last != null && last.isNotEmpty() && (last != token || lastApp != t.app + "|" + t.origin)) {
            lastTarget()?.let { post(it, "/push/fcm/unregister", JSONObject().put("token", last)) { } }
        }
        post(t, "/push/fcm/register",
            JSONObject().put("token", token).put("device", "${Build.MANUFACTURER} ${Build.MODEL}")) { code ->
            Beacon.send("fcm-reg-$code")
            if (code == 200) {
                Config.setString(KEY_TOKEN, token)
                Config.setString(KEY_APP, t.app + "|" + t.origin)
                Config.setString(KEY_TARGET, Config.gadkURL)
            }
        }
    }

    private const val KEY_TOKEN = "fcmToken"
    private const val KEY_APP = "fcmTokenApp"
    private const val KEY_TARGET = "fcmTokenTarget"
    private fun lastTarget(): Target? = Config.string(KEY_TARGET)?.let { Target.from(it) }?.takeIf { it.hasToken }

    /** Confirm an important reminder: the server stops its repeats, the card + notifications go. */
    fun ackReminder(id: String) {
        if (id.isEmpty()) return
        val t = Target.current()
        if (t.hasToken) {
            Net.http.newCall(Request.Builder().url(t.url("/reminders/ack", "id" to id))
                .post(ByteArray(0).toRequestBody()).build()).enqueue(cb { Beacon.send("rem-ack-$it") })
        }
        PushService.cancelReminder(app, id)
        Events.post(AppEvent.ImportantDone(id))
    }

    /** "Snooze 10 min": a fresh reminder at now+10 (the original's repeats are acked separately). */
    internal fun snooze(text: String, done: () -> Unit) {
        val t = Target.current()
        if (!t.hasToken || text.isEmpty()) { done(); return }
        val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US).apply { timeZone = TimeZone.getDefault() }
            .format(Date(System.currentTimeMillis() + SNOOZE_MINUTES * 60_000L))
        post(t, "/reminders", JSONObject().put("text", text).put("when", iso)) { code ->
            Beacon.send("rem-snooze-$code"); done()
        }
    }

    /** A share's full text when the push had to truncate it (Copy). */
    internal fun fullShareText(id: String, fallback: String, done: (String) -> Unit) {
        val t = Target.current()
        if (!t.hasToken || id.isEmpty()) { done(fallback); return }
        Net.http.newCall(Request.Builder().url(t.url("/shares/list")).build()).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) = done(fallback)
            override fun onResponse(call: Call, response: Response) {
                val body = response.use { it.body?.string() }
                val arr = runCatching { JSONObject(body ?: "").optJSONArray("shares") }.getOrNull()
                val hit = arr?.let { a -> (0 until a.length()).map { a.optJSONObject(it) }.firstOrNull { it?.optString("id") == id } }
                done(hit?.optString("text")?.takeIf { it.isNotEmpty() } ?: fallback)
            }
        })
    }

    /**
     * Call from MainActivity.onCreate (cold = true) and onNewIntent (cold = false):
     * a tap on an important reminder confirms it (iOS: a plain tap acks too), and a
     * cold launch from "screen broadcast stopped" lands on the capture page —
     * posted a beat late so the UI's event collector is listening by then.
     */
    fun handleLaunch(intent: Intent?, cold: Boolean) {
        intent ?: return
        intent.getStringExtra(EXTRA_ACK_ID)?.let { ackReminder(it); intent.removeExtra(EXTRA_ACK_ID) }
        if (cold && intent.getBooleanExtra(com.manarz.myagent.MainActivity.EXTRA_SCREENPIPE, false)) {
            Beacon.send("push-to-broadcast")
            Handler(Looper.getMainLooper()).postDelayed({ Events.post(AppEvent.ShowScreenpipe(present = false)) }, 700)
        }
    }

    internal fun appInForeground(): Boolean {
        val st = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(st)
        return st.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
    }

    internal fun notificationsAllowed(ctx: Context) = NotificationManagerCompat.from(ctx).areNotificationsEnabled()

    private fun post(t: Target, path: String, body: JSONObject, done: (Int) -> Unit) {
        Net.http.newCall(Request.Builder().url(t.url(path)).post(body.toString().toRequestBody(Net.JSON)).build())
            .enqueue(cb(done))
    }

    private fun cb(done: (Int) -> Unit) = object : Callback {
        override fun onFailure(call: Call, e: IOException) = done(0)
        override fun onResponse(call: Call, response: Response) { val c = response.code; response.close(); done(c) }
    }
}
