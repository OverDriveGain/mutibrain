package com.manarz.myagent.music

import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/** STUB — the Media3 session service (filled by the music module). */
class PlaybackService : MediaSessionService() {
    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = null
}
