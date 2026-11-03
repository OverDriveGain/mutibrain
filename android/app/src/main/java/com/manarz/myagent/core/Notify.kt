package com.manarz.myagent.core

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.net.Uri

/** Notification channels — created once at startup, used by every module. */
object Notify {
    const val CH_VOICE = "voice"            // ongoing conversation (foreground service)
    const val CH_CAPTURE = "capture"        // screen / mic memory recording
    const val CH_MUSIC = "music"            // media playback
    const val CH_AGENT = "agent"            // hand-off results, shares, suggestions
    const val CH_REMINDER = "reminder"      // reminders
    const val CH_IMPORTANT = "important"    // important reminders: insistent, bypass-DND-capable

    fun init(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        fun ch(id: String, name: String, imp: Int, block: NotificationChannel.() -> Unit = {}) =
            nm.createNotificationChannel(NotificationChannel(id, name, imp).apply(block))
        ch(CH_VOICE, "Conversation", NotificationManager.IMPORTANCE_LOW)
        ch(CH_CAPTURE, "Screen & mic memory", NotificationManager.IMPORTANCE_LOW)
        ch(CH_MUSIC, "Music", NotificationManager.IMPORTANCE_LOW)
        ch(CH_AGENT, "From your assistant", NotificationManager.IMPORTANCE_DEFAULT)
        ch(CH_REMINDER, "Reminders", NotificationManager.IMPORTANCE_HIGH)
        ch(CH_IMPORTANT, "Important reminders", NotificationManager.IMPORTANCE_HIGH) {
            val res = ctx.resources.getIdentifier("important", "raw", ctx.packageName)
            if (res != 0) setSound(Uri.parse("android.resource://${ctx.packageName}/$res"),
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build())
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 600, 300, 600, 300, 600)
            setBypassDnd(true)
        }
    }
}
