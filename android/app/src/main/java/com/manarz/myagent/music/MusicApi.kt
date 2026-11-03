package com.manarz.myagent.music

import com.manarz.myagent.core.Net
import com.manarz.myagent.core.Target
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

/**
 * The voice server's /music routes (Navidrome behind it), subscriber-authed
 * with ?app=&token= — same contract as iOS MusicView:
 *   GET  /music/search[?q]          → {songs, albums, artists}   (no q = the album wall)
 *   GET  /music/album?id            → {songs}
 *   GET  /music/artist?name         → {songs}
 *   GET  /music/playlist?id         → {songs}
 *   GET  /music/playlists           → {playlists}
 *   POST /music/playlists           {name, songIds, comment?}      (save the queue)
 *   POST /music/playlist?id         {comment} | {songIds}           (describe / append)
 *   DELETE /music/playlist?id
 */
object MusicApi {
    class Results(val songs: List<Song>, val albums: List<Album>, val artists: List<Artist>)

    private fun url(path: String, vararg q: Pair<String, String>) = Target.current().url(path, *q)

    private suspend fun get(path: String, vararg q: Pair<String, String>): JSONObject = withContext(Dispatchers.IO) {
        if (!Target.current().hasToken) error("Not configured")
        Net.http.newCall(Request.Builder().url(url(path, *q)).build()).execute().use { r ->
            val o = runCatching { JSONObject(r.body!!.string()) }.getOrElse { error("HTTP ${r.code}") }
            if (!r.isSuccessful || o.has("error")) error(o.optString("error").ifEmpty { "HTTP ${r.code}" })
            o
        }
    }

    private suspend fun send(method: String, path: String, body: JSONObject?, vararg q: Pair<String, String>) =
        withContext(Dispatchers.IO) {
            val rb = body?.toString()?.toRequestBody(Net.JSON)
            runCatching {
                Net.http.newCall(Request.Builder().url(url(path, *q)).method(method, rb).build()).execute().close()
            }
            Unit
        }

    suspend fun albumWall(): List<Album> = albums(get("/music/search").optJSONArray("albums"))

    suspend fun search(q: String): Results = get("/music/search", "q" to q).let {
        Results(Song.list(it.optJSONArray("songs")), albums(it.optJSONArray("albums")), artists(it.optJSONArray("artists")))
    }

    suspend fun album(id: String) = Song.list(get("/music/album", "id" to id).optJSONArray("songs"))
    suspend fun artist(name: String) = Song.list(get("/music/artist", "name" to name).optJSONArray("songs"))
    suspend fun playlist(id: String) = Song.list(get("/music/playlist", "id" to id).optJSONArray("songs"))
    suspend fun playlists(): List<Playlist> = playlists(get("/music/playlists").optJSONArray("playlists"))

    suspend fun savePlaylist(name: String, songIds: List<String>, comment: String?) =
        send("POST", "/music/playlists", JSONObject().put("name", name).put("songIds", JSONArray(songIds))
            .apply { if (!comment.isNullOrBlank()) put("comment", comment) })

    suspend fun describe(id: String, comment: String) =
        send("POST", "/music/playlist", JSONObject().put("comment", comment), "id" to id)

    suspend fun addToPlaylist(id: String, songId: String) =
        send("POST", "/music/playlist", JSONObject().put("songIds", JSONArray(listOf(songId))), "id" to id)

    suspend fun delete(id: String) = send("DELETE", "/music/playlist", null, "id" to id)
}
