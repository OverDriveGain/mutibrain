package com.mymu.app.core

import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONArray
import org.json.JSONObject

/**
 * One conversation the user actually OPENED — agents or project chats alike.
 * A local "last seen" history, distinct from the Chats tab which sorts by
 * server-side activity. (1:1 port of iOS RecentlyViewedStore, same prefs key.)
 */
data class RecentlyViewed(
    val sessionId: String,
    val projectId: String,
    val isRemote: Boolean,
    val title: String,
    val projectPath: String?,
    val at: Long,
) {
    val id: String get() = sessionId.ifEmpty { projectId }

    fun toJson(): JSONObject = JSONObject()
        .put("sessionId", sessionId).put("projectId", projectId)
        .put("isRemote", isRemote).put("title", title)
        .put("projectPath", projectPath ?: JSONObject.NULL).put("at", at)

    companion object {
        fun fromJson(o: JSONObject) = RecentlyViewed(
            sessionId = o.optString("sessionId", ""),
            projectId = o.optString("projectId", ""),
            isRemote = o.optBoolean("isRemote", false),
            title = o.optString("title", ""),
            projectPath = o.stringOrNull("projectPath"),
            at = o.optLong("at", 0),
        )
    }
}

object RecentlyViewedStore {
    val items = MutableStateFlow<List<RecentlyViewed>>(emptyList())
    private const val KEY = "recentlyViewedConversations"
    private const val CAP = 10

    fun load() {
        Prefs.getString(KEY)?.let { raw ->
            try {
                val arr = JSONArray(raw)
                items.value = (0 until arr.length()).mapNotNull {
                    (arr.opt(it) as? JSONObject)?.let(RecentlyViewed::fromJson)
                }
            } catch (_: Exception) {}
        }
    }

    /** Record an open. For remote agents, dedupe by PROJECT (the agent) — its
     * session id rotates on restarts. */
    fun record(sessionId: String, projectId: String, isRemote: Boolean, title: String, projectPath: String? = null) {
        if (sessionId.isEmpty() && projectId.isEmpty()) return
        var next = items.value.filter { existing ->
            if (isRemote) !(existing.isRemote && existing.projectId == projectId)
            else existing.sessionId != sessionId
        }
        next = listOf(RecentlyViewed(sessionId, projectId, isRemote, title, projectPath,
            System.currentTimeMillis())) + next
        if (next.size > CAP) next = next.take(CAP)
        items.value = next
        val arr = JSONArray()
        for (r in next) arr.put(r.toJson())
        Prefs.putString(KEY, arr.toString())
    }
}
