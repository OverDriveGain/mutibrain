package com.manarz.myagent.push

import android.annotation.SuppressLint
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.manarz.myagent.MainActivity
import com.manarz.myagent.R
import com.manarz.myagent.core.AppEvent
import com.manarz.myagent.core.Beacon
import com.manarz.myagent.core.Events
import com.manarz.myagent.core.Notify

/**
 * Renders the server's data messages (shell/fcm.py — the APNs payload,
 * flattened to strings). Categories, as on iOS:
 *   MYMU_SHARE     shares + hand-off results → "From your assistant", Copy action
 *   MYMU_REMINDER  reminders → Snooze 10 min + Done; an IMPORTANT one rides the
 *                  alarm channel, takes over the lock screen (full-screen intent),
 *                  rings insistently, and repeats from the server until confirmed
 *   MYMU_NUDGE     screen-suggest / broadcast-stopped → no Copy; `mymu=broadcast`
 *                  taps land on the screen-capture page
 */
class PushService : FirebaseMessagingService() {

    override fun onNewToken(token: String) {
        Beacon.send("fcm-token-new")
        PushModule.postToken(token)
    }

    override fun onMessageReceived(msg: RemoteMessage) {
        val d = msg.data
        if (d.isEmpty()) return
        val category = d["category"] ?: "MYMU_SHARE"
        val important = d["important"] == "1" || d["important"] == "true"
        Beacon.send("fcm-rx-${d["kind"] ?: "?"}${if (important) "-important" else ""}")
        if (important && PushModule.appInForeground()) {
            // the app is open: the card that stays until Done (the notification still rings)
            Events.post(AppEvent.Important(reminderId(d), d["text"]?.takeIf { it.isNotEmpty() } ?: d["body"].orEmpty()))
        }
        show(this, d, category, important)
    }

    companion object {
        private fun reminderId(d: Map<String, String>) = d["reminder_id"]?.takeIf { it.isNotEmpty() } ?: d["id"].orEmpty()

        /** One notification id per server id; every important repeat carries its own (nag) id. */
        private fun notifId(d: Map<String, String>) = (d["id"]?.takeIf { it.isNotEmpty() } ?: d.toString()).hashCode()

        /** Group key: all notifications of one reminder (its repeats) cancel together on Done. */
        private fun reminderTag(id: String) = "rem:$id"

        @SuppressLint("MissingPermission")   // guarded by areNotificationsEnabled
        fun show(ctx: Context, d: Map<String, String>, category: String, important: Boolean) {
            if (!PushModule.notificationsAllowed(ctx)) { Beacon.send("fcm-notif-blocked"); return }
            val id = notifId(d)
            val rid = reminderId(d)
            val title = d["title"].orEmpty().ifEmpty { "Your assistant" }
            val body = d["body"].orEmpty()

            val open = Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            if (d["mymu"] == "broadcast") open.putExtra(MainActivity.EXTRA_SCREENPIPE, true)
            if (important) open.putExtra(PushModule.EXTRA_ACK_ID, rid)
            val tap = PendingIntent.getActivity(ctx, id, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

            val channel = when {
                important -> Notify.CH_IMPORTANT
                category == "MYMU_REMINDER" -> Notify.CH_REMINDER
                else -> Notify.CH_AGENT
            }
            val b = NotificationCompat.Builder(ctx, channel)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(tap)
                .setAutoCancel(true)

            when (category) {
                "MYMU_REMINDER" -> {
                    b.setCategory(if (important) NotificationCompat.CATEGORY_ALARM else NotificationCompat.CATEGORY_REMINDER)
                        .setPriority(if (important) NotificationCompat.PRIORITY_MAX else NotificationCompat.PRIORITY_HIGH)
                        .addAction(0, "Snooze 10 min", ActionReceiver.intent(ctx, ActionReceiver.SNOOZE, id, d))
                        .addAction(0, "Done", ActionReceiver.intent(ctx, ActionReceiver.DONE, id, d))
                    if (important) {
                        b.setOngoing(true)       // no swipe-away: only Done / tap confirms
                            .setAutoCancel(false)
                            .setGroup(reminderTag(rid))
                        val nm = ctx.getSystemService(NotificationManager::class.java)
                        if (Build.VERSION.SDK_INT < 34 || nm.canUseFullScreenIntent()) b.setFullScreenIntent(tap, true)
                    }
                }
                "MYMU_NUDGE" -> b.setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
                else -> {
                    b.setCategory(NotificationCompat.CATEGORY_MESSAGE)
                    if (d["text"].orEmpty().isNotEmpty() || body.isNotEmpty())
                        b.addAction(0, "Copy", ActionReceiver.intent(ctx, ActionReceiver.COPY, id, d))
                }
            }
            val n = b.build()
            if (important) n.flags = n.flags or android.app.Notification.FLAG_INSISTENT   // ring until handled
            val tag = if (important) reminderTag(rid) else null
            NotificationManagerCompat.from(ctx).notify(tag, id, n)
            if (important) ActionReceiver.remember(ctx, rid, tag!!, id)
        }

        /** Drop every notification of one reminder (all its repeats). */
        fun cancelReminder(ctx: Context, rid: String) {
            val nm = NotificationManagerCompat.from(ctx)
            ActionReceiver.forget(ctx, rid).forEach { nm.cancel(reminderTag(rid), it) }
        }
    }
}
