package com.manarz.myagent.push

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.core.app.NotificationManagerCompat
import com.manarz.myagent.core.Beacon

/**
 * Notification actions that run WITHOUT opening the app (iOS background actions):
 * Done (confirm a reminder — stops the server's repeats), Snooze 10 min (confirm
 * + a fresh reminder in 10), Copy (a share's text → clipboard, the full text
 * from /shares/list when the push had to truncate it).
 */
class ActionReceiver : BroadcastReceiver() {

    override fun onReceive(ctx: Context, intent: Intent) {
        val notifId = intent.getIntExtra(EXTRA_NOTIF, 0)
        val d = intent.getBundleExtra(EXTRA_DATA)?.let { b -> b.keySet().associateWith { b.getString(it).orEmpty() } }.orEmpty()
        val important = d["important"] == "1" || d["important"] == "true"
        val rid = d["reminder_id"]?.takeIf { it.isNotEmpty() } ?: d["id"].orEmpty()
        val pending = goAsync()
        fun finish() = runCatching { pending.finish() }
        when (intent.action) {
            DONE -> {
                Beacon.send("rem-done")
                if (important) PushModule.ackReminder(rid)
                NotificationManagerCompat.from(ctx).cancel(notifId)
                finish()
            }
            SNOOZE -> {
                if (important) PushModule.ackReminder(rid)   // the repeats stop; the snoozed copy rings later
                NotificationManagerCompat.from(ctx).cancel(notifId)
                PushModule.snooze(d["text"].orEmpty().ifEmpty { d["body"].orEmpty() }) { finish() }
            }
            COPY -> {
                val text = d["text"].orEmpty().ifEmpty { d["body"].orEmpty() }
                val done = { full: String ->
                    val cm = ctx.getSystemService(ClipboardManager::class.java)
                    android.os.Handler(android.os.Looper.getMainLooper()).post {
                        cm.setPrimaryClip(ClipData.newPlainText("MyMu", full))
                        // Android 13+ shows its own "copied" confirmation
                        if (android.os.Build.VERSION.SDK_INT < 33) Toast.makeText(ctx, "Copied", Toast.LENGTH_SHORT).show()
                        NotificationManagerCompat.from(ctx).cancel(notifId)
                        finish()
                    }
                    Unit
                }
                if (d["text_truncated"] == "1") {
                    PushModule.fullShareText(d["id"].orEmpty(), text) { done(it); Beacon.send("fcm-copy-full") }
                } else { done(text); Beacon.send("fcm-copy") }
            }
            else -> finish()
        }
    }

    companion object {
        const val DONE = "com.manarz.myagent.push.DONE"
        const val SNOOZE = "com.manarz.myagent.push.SNOOZE"
        const val COPY = "com.manarz.myagent.push.COPY"
        private const val EXTRA_NOTIF = "notif"
        private const val EXTRA_DATA = "data"
        private const val PREFS = "push-reminders"

        fun intent(ctx: Context, action: String, notifId: Int, d: Map<String, String>): PendingIntent {
            val b = Bundle().apply { d.forEach { (k, v) -> putString(k, v) } }
            val i = Intent(ctx, ActionReceiver::class.java).setAction(action)
                .putExtra(EXTRA_NOTIF, notifId).putExtra(EXTRA_DATA, b)
            return PendingIntent.getBroadcast(ctx, (action + notifId).hashCode(), i,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }

        /** Remember which notification ids one important reminder has on screen (its repeats). */
        internal fun remember(ctx: Context, rid: String, tag: String, id: Int) {
            val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val ids = (p.getStringSet(rid, emptySet()) ?: emptySet()) + id.toString()
            p.edit().putStringSet(rid, ids).apply()
        }

        internal fun forget(ctx: Context, rid: String): List<Int> {
            val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val ids = p.getStringSet(rid, emptySet()).orEmpty().mapNotNull { it.toIntOrNull() }
            p.edit().remove(rid).apply()
            return ids
        }
    }
}
