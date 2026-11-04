package com.manarz.myagent.music

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.ListenableFuture
import com.manarz.myagent.core.Beacon
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * The native music player — Android port of iOS SubsonicPlayer. One app-wide
 * ExoPlayer owns the queue; [PlaybackService] wraps it in a MediaSession, which
 * gives the lock screen, the media notification, Bluetooth/headset buttons and
 * background playback for free. ExoPlayer handles audio focus and "becoming
 * noisy" (headphones unplugged → pause) — standard platform behavior.
 *
 * Main thread only (ExoPlayer's application looper).
 */
object MusicPlayer {
    lateinit var exo: ExoPlayer
        private set
    private lateinit var app: Context
    private val main = Handler(Looper.getMainLooper())
    private var controller: ListenableFuture<MediaController>? = null

    private val _queue = MutableStateFlow<List<Song>>(emptyList())
    val queue: StateFlow<List<Song>> get() = _queue
    private val _index = MutableStateFlow(0)
    val index: StateFlow<Int> get() = _index
    private val _isPlaying = MutableStateFlow(false)
    val isPlaying: StateFlow<Boolean> get() = _isPlaying
    /** Seconds into the track / its length (0 = unknown yet). Ticks every 500 ms. */
    private val _position = MutableStateFlow(0.0)
    val position: StateFlow<Double> get() = _position
    private val _duration = MutableStateFlow(0.0)
    val duration: StateFlow<Double> get() = _duration

    val current: Song? get() = _queue.value.getOrNull(_index.value)
    val isActive: Boolean get() = _queue.value.isNotEmpty()

    /** A live conversation is on: the music sits under it (iOS ducking), restored after. */
    private var ducked = false

    fun init(ctx: Context) {
        app = ctx.applicationContext
        exo = ExoPlayer.Builder(app)
            .setAudioAttributes(AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(), /* handleAudioFocus = */ true)
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build()
        exo.addListener(object : Player.Listener {
            override fun onIsPlayingChanged(playing: Boolean) { _isPlaying.value = playing }
            override fun onMediaItemTransition(item: MediaItem?, reason: Int) {
                _index.value = exo.currentMediaItemIndex
                _position.value = 0.0
                _duration.value = current?.duration?.toDouble() ?: 0.0
            }
            override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                Beacon.send("music-err-${error.errorCodeName}")
            }
        })
        tick()
    }

    private fun tick() {
        if (exo.isPlaying || exo.playbackState == Player.STATE_READY) {
            _position.value = (exo.currentPosition / 1000.0).coerceAtLeast(0.0)
            val d = exo.duration
            _duration.value = if (d != C.TIME_UNSET && d > 0) d / 1000.0 else (current?.duration?.toDouble() ?: 0.0)
        }
        main.postDelayed(::tick, 500)
    }

    /** Connecting a controller starts PlaybackService, which then runs foreground while playing. */
    private fun ensureService() {
        if (controller != null) return
        controller = MediaController.Builder(app, SessionToken(app, ComponentName(app, PlaybackService::class.java))).buildAsync()
    }

    private fun item(s: Song): MediaItem = MediaItem.Builder()
        .setMediaId(s.id)
        .setUri(DownloadStore.localUri(s.id) ?: Uri.parse(s.streamUrl))
        .setMediaMetadata(MediaMetadata.Builder()
            .setTitle(s.displayTitle).setArtist(s.displayArtist).setAlbumTitle(s.album)
            .setArtworkUri(s.coverUrl?.let(Uri::parse))
            .setIsPlayable(true).setIsBrowsable(false)
            .build())
        .build()

    // The STANDARD platform duck does the work: the conversation takes transient
    // may-duck focus and ExoPlayer (handleAudioFocus) lowers itself. A second manual
    // duck on top stacked to ~6% — near silence (measured 2026-11-03). `ducked` only
    // feeds the beacons now.
    private fun applyVolume() { exo.volume = 1f }

    // ---------------------------------------------------------------- transport

    fun play(songs: List<Song>, startAt: Int = 0) {
        if (songs.isEmpty()) return
        ensureService()
        val start = startAt.coerceIn(0, songs.size - 1)
        _queue.value = songs
        _index.value = start
        _position.value = 0.0
        _duration.value = songs[start].duration?.toDouble() ?: 0.0
        exo.setMediaItems(songs.map(::item), start, 0L)
        applyVolume()
        exo.prepare()
        exo.play()
    }

    fun addToQueue(songs: List<Song>) {
        if (_queue.value.isEmpty()) return play(songs)
        _queue.value = _queue.value + songs
        exo.addMediaItems(songs.map(::item))
    }

    fun playAt(i: Int) {
        if (i !in _queue.value.indices) return
        ensureService()
        exo.seekTo(i, 0L)
        exo.prepare()
        exo.play()
    }

    fun move(from: Int, to: Int) {
        val q = _queue.value.toMutableList()
        if (from !in q.indices || to !in q.indices || from == to) return
        q.add(to, q.removeAt(from))
        _queue.value = q
        exo.moveMediaItem(from, to)
        _index.value = exo.currentMediaItemIndex
    }

    fun removeAt(i: Int) {
        val q = _queue.value.toMutableList()
        if (i !in q.indices) return
        q.removeAt(i)
        _queue.value = q
        exo.removeMediaItem(i)
        if (q.isEmpty()) { exo.stop(); _index.value = 0 } else _index.value = exo.currentMediaItemIndex
    }

    fun toggle() {
        if (exo.isPlaying) exo.pause()
        else if (current != null) {
            ensureService()
            if (exo.playbackState == Player.STATE_IDLE) exo.prepare()
            if (exo.playbackState == Player.STATE_ENDED) exo.seekTo(exo.currentMediaItemIndex, 0L)
            exo.play()
        }
    }

    fun next() { if (exo.hasNextMediaItem()) exo.seekToNextMediaItem() else exo.pause() }

    /** iOS semantics: >3 s in (or the first track) restarts the track, else the previous one. */
    fun prev() {
        if (exo.currentPosition > 3000 || !exo.hasPreviousMediaItem()) exo.seekTo(0L) else exo.seekToPreviousMediaItem()
    }

    fun seek(seconds: Double) = exo.seekTo((seconds * 1000).toLong())

    fun pauseFromVoice() = exo.pause()
    fun resumeFromVoice() { if (current != null && !exo.isPlaying) toggle() }

    fun stop() {
        exo.stop()
        exo.clearMediaItems()
        _queue.value = emptyList()
        _index.value = 0
        _position.value = 0.0; _duration.value = 0.0
    }

    fun duck(on: Boolean) {
        if (ducked == on) return
        ducked = on
        applyVolume()
        if (!on) Beacon.send("unduck")
    }

    /** "download this song" from voice: save the current track. */
    fun downloadCurrent() { current?.let { DownloadStore.download(it) } }
}
