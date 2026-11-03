package com.manarz.myagent.music

import android.app.PendingIntent
import android.content.Intent
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.manarz.myagent.MainActivity
import com.manarz.myagent.R
import com.manarz.myagent.core.Notify

/**
 * The Media3 session around the app-wide [MusicPlayer.exo] — lock-screen and
 * notification controls, Bluetooth/headset buttons, Android Auto-style
 * controllers. Media3 runs it in the foreground (type mediaPlayback) while
 * playing and lets it drop out of the foreground when paused.
 * The player is NOT owned here: the UI and the voice tools drive the same one.
 */
@UnstableApi
class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        setMediaNotificationProvider(DefaultMediaNotificationProvider.Builder(this)
            .setChannelId(Notify.CH_MUSIC).setChannelName(R.string.app_name).build()
            .apply { setSmallIcon(R.drawable.ic_notification) })
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        session = MediaSession.Builder(this, MusicPlayer.exo).setSessionActivity(open).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    /** Swiped away from recents while nothing plays: go. While playing, keep playing. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        val p = session?.player
        if (p == null || !p.playWhenReady || p.mediaItemCount == 0) stopSelf()
    }

    override fun onDestroy() {
        session?.release()      // releases the session only — the shared player lives on
        session = null
        super.onDestroy()
    }
}
