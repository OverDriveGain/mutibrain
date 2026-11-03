package com.manarz.myagent.music

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.manarz.myagent.core.Music
import com.manarz.myagent.core.MusicHost
import com.manarz.myagent.voice.GadkVoice
import org.json.JSONArray

/**
 * Music wiring: the player, the offline store, and the [MusicHost] seam the
 * voice tools (play_music / music_control) and the web Music massam call.
 */
object MusicModule {
    private val main = Handler(Looper.getMainLooper())

    fun init(ctx: Context) {
        DownloadStore.init(ctx)
        MusicPlayer.init(ctx)
        Music.host = object : MusicHost {
            override fun play(songs: JSONArray, startAt: Int) = onMain {
                val list = Song.list(songs)
                if (list.isEmpty()) return@onMain
                // keep_listening: music starts while the conversation is live → under it
                MusicPlayer.duck(GadkVoice.active.value)
                MusicPlayer.play(list, startAt)
            }

            override fun control(action: String) = onMain {
                when (action) {
                    "stop" -> MusicPlayer.stop()
                    "pause" -> MusicPlayer.pauseFromVoice()
                    "resume" -> MusicPlayer.resumeFromVoice()
                    "next" -> MusicPlayer.next()
                    "previous" -> MusicPlayer.prev()
                    "download" -> MusicPlayer.downloadCurrent()
                }
            }

            override fun duck(on: Boolean) = onMain { MusicPlayer.duck(on) }

            override val isActive: Boolean get() = MusicPlayer.isActive
        }
    }

    private fun onMain(fn: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) fn() else main.post(fn)
    }
}
