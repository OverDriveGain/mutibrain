package com.manarz.myagent.music

import android.content.Context
import android.net.Uri
import com.manarz.myagent.core.Beacon
import com.manarz.myagent.core.Net
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import okhttp3.Request
import org.json.JSONArray
import java.io.File

/**
 * Offline songs (iOS DownloadStore): the original file (downloadUrl, else the
 * stream) saved under the app's files dir as `<id>.<ext>`, plus an index of the
 * Song records so the Downloaded list survives restarts. The player prefers a
 * local file over the stream whenever one exists.
 */
object DownloadStore {
    private lateinit var dir: File
    private lateinit var index: File
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _songs = MutableStateFlow<List<Song>>(emptyList())
    /** Downloaded, newest first. */
    val songs: StateFlow<List<Song>> get() = _songs
    private val _inFlight = MutableStateFlow<Set<String>>(emptySet())
    val inFlight: StateFlow<Set<String>> get() = _inFlight

    fun init(ctx: Context) {
        dir = File(ctx.filesDir, "MusicDownloads").apply { mkdirs() }
        index = File(dir, "index.json")
        _songs.value = runCatching { Song.list(JSONArray(index.readText())) }.getOrDefault(emptyList())
            .filter { localFile(it.id) != null }
    }

    fun isDownloaded(id: String) = localFile(id) != null

    fun localFile(id: String): File? =
        dir.listFiles()?.firstOrNull { it.name.startsWith("$id.") && it.name != "index.json" && !it.name.endsWith(".part") }

    fun localUri(id: String): Uri? = localFile(id)?.let(Uri::fromFile)

    fun download(song: Song) {
        if (isDownloaded(song.id) || song.id in _inFlight.value) return
        _inFlight.update { it + song.id }
        scope.launch {
            val ok = runCatching {
                Net.http.newCall(Request.Builder().url(song.downloadUrl ?: song.streamUrl).build()).execute().use { r ->
                    if (!r.isSuccessful) error("HTTP ${r.code}")
                    val part = File(dir, "${song.id}.part")
                    r.body!!.byteStream().use { input -> part.outputStream().use { input.copyTo(it) } }
                    val dest = File(dir, "${song.id}.${ext(r.header("Content-Type"))}")
                    dest.delete()
                    if (!part.renameTo(dest)) error("rename")
                }
            }.isSuccess
            _inFlight.update { it - song.id }
            if (ok) {
                _songs.update { listOf(song) + it.filter { s -> s.id != song.id } }
                persist()
                Beacon.send("dl-ok-${song.id}")
            } else {
                File(dir, "${song.id}.part").delete()
                Beacon.send("dl-fail-${song.id}")
            }
        }
    }

    fun remove(id: String) {
        localFile(id)?.delete()
        _songs.update { it.filter { s -> s.id != id } }
        persist()
    }

    private fun persist() {
        val a = JSONArray(); _songs.value.forEach { a.put(it.toJson()) }
        runCatching { index.writeText(a.toString()) }
    }

    private fun ext(mime: String?): String = when (mime?.lowercase()?.substringBefore(';')?.trim()) {
        "audio/mpeg" -> "mp3"
        "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac" -> "m4a"
        "audio/flac", "audio/x-flac" -> "flac"
        "audio/ogg", "application/ogg" -> "ogg"
        "audio/wav", "audio/x-wav" -> "wav"
        else -> "mp3"
    }
}
