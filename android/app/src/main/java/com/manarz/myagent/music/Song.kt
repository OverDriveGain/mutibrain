package com.manarz.myagent.music

import org.json.JSONArray
import org.json.JSONObject

/**
 * A playable track as the voice server hands it out (iOS Song): the stream /
 * download / cover URLs are absolute and already carry Navidrome's auth, so
 * the player needs nothing else to play them.
 */
data class Song(
    val id: String,
    val title: String?,
    val artist: String?,
    val album: String?,
    val duration: Int?,
    val streamUrl: String,
    val downloadUrl: String?,   // original file (offline saves); older payloads omit it
    val coverUrl: String?,
) {
    val displayTitle get() = title ?: "Unknown"
    val displayArtist get() = artist ?: ""

    fun toJson(): JSONObject = JSONObject()
        .put("id", id).put("title", title).put("artist", artist).put("album", album)
        .put("duration", duration).put("streamUrl", streamUrl).put("downloadUrl", downloadUrl).put("coverUrl", coverUrl)

    companion object {
        fun from(o: JSONObject): Song? {
            val id = o.optString("id").takeIf { it.isNotEmpty() } ?: return null
            val stream = o.optString("streamUrl").takeIf { it.isNotEmpty() } ?: return null
            fun s(k: String) = o.optString(k).takeIf { !o.isNull(k) && it.isNotEmpty() }
            return Song(id, s("title"), s("artist"), s("album"),
                if (o.has("duration") && !o.isNull("duration")) o.optInt("duration") else null,
                stream, s("downloadUrl"), s("coverUrl"))
        }

        fun list(a: JSONArray?): List<Song> =
            if (a == null) emptyList() else (0 until a.length()).mapNotNull { a.optJSONObject(it)?.let(::from) }
    }
}

data class Album(val id: String, val name: String?, val artist: String?, val songCount: Int?, val coverUrl: String?)
data class Artist(val id: String, val name: String?, val albumCount: Int?, val coverUrl: String?)
data class Playlist(val id: String, val name: String?, val comment: String?, val songCount: Int?, val coverUrl: String?)

internal fun JSONObject.str(k: String): String? = optString(k).takeIf { !isNull(k) && it.isNotEmpty() }
internal fun JSONObject.int(k: String): Int? = if (has(k) && !isNull(k)) optInt(k) else null

internal fun albums(a: JSONArray?) = objs(a).map { Album(it.optString("id"), it.str("name"), it.str("artist"), it.int("songCount"), it.str("coverUrl")) }
internal fun artists(a: JSONArray?) = objs(a).map { Artist(it.optString("id"), it.str("name"), it.int("albumCount"), it.str("coverUrl")) }
internal fun playlists(a: JSONArray?) = objs(a).map { Playlist(it.optString("id"), it.str("name"), it.str("comment"), it.int("songCount"), it.str("coverUrl")) }
private fun objs(a: JSONArray?) = if (a == null) emptyList() else (0 until a.length()).mapNotNull { a.optJSONObject(it) }
