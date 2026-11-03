package com.manarz.myagent.voice

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.manarz.myagent.MainActivity
import com.manarz.myagent.R
import com.manarz.myagent.core.Notify

/**
 * Keeps the process in the foreground while a conversation runs — Android's
 * counterpart of iOS UIBackgroundModes=audio + isIdleTimerDisabled: the talk
 * survives the screen turning off or switching apps. Type `microphone`, so
 * the mic keeps recording in the background (Android 14+ requires the type).
 * The audio itself lives in [GadkVoice]; this service only holds the process.
 */
class VoiceService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, VoiceService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE)
        if (intent?.action == ACTION_STOP) {
            GadkVoice.stop()
            stopSelf()
            return START_NOT_STICKY
        }
        val n: Notification = NotificationCompat.Builder(this, Notify.CH_VOICE)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Talking with MyMu")
            .setContentText("Tap to open · the conversation keeps going with the screen off")
            .setContentIntent(open)
            .addAction(0, "End", stop)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .build()
        ServiceCompat.startForeground(this, 41, n,
            if (Build.VERSION.SDK_INT >= 30) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0)
        return START_NOT_STICKY
    }

    companion object { const val ACTION_STOP = "com.manarz.myagent.voice.STOP" }
}
