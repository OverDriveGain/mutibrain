package com.manarz.myagent.core

import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import org.json.JSONArray

/**
 * The seams between modules — the Android counterpart of the iOS
 * NotificationCenter names (.mymuPlaySongs, .mymuMusicControl,
 * .mymuShowScreenpipe, .mymuImportant …). Each module registers its own
 * implementation at startup; the voice client and the webview bridge only
 * talk to these, so the modules never import each other.
 */

/** The native music player (Media3). Registered by the music module. */
interface MusicHost {
    /** songs = the server's song objects ({id,title,artist,album,duration,streamUrl…}). */
    fun play(songs: JSONArray, startAt: Int = 0)
    /** stop | pause | resume | next | previous | download */
    fun control(action: String)
    /** A voice conversation started/ended: duck under it / restore. */
    fun duck(on: Boolean) {}
    val isActive: Boolean get() = false
}

object Music {
    @Volatile var host: MusicHost? = null
}

/** One-shot UI events the home screen reacts to. */
sealed class AppEvent {
    /** Web Screen massam: "present" = straight to the capture consent, else the full page. */
    data class ShowScreenpipe(val present: Boolean) : AppEvent()
    data class Composing(val open: Boolean) : AppEvent()
    /** An important reminder arrived while the app is open (card until Done). */
    data class Important(val id: String, val text: String) : AppEvent()
    data class ImportantDone(val id: String) : AppEvent()
    /** Dictation finished: text for the chat composer. */
    data class Dictated(val text: String) : AppEvent()
}

object Events {
    private val _flow = MutableSharedFlow<AppEvent>(extraBufferCapacity = 16, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    val flow: SharedFlow<AppEvent> get() = _flow
    fun post(e: AppEvent) { _flow.tryEmit(e) }
}
