package com.manarz.myagent.push

import android.content.Context

/** STUB — FCM registration + notification handling + important reminders. */
object PushModule {
    fun init(ctx: Context) {}
    /** Re-register the device for the current subscriber (login change / foreground). */
    fun reregister() {}
    /** Confirm an important reminder (stops the server's repeats). */
    fun ackReminder(id: String) {}
}
