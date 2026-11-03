package com.manarz.myagent.core

import okhttp3.Request
import org.json.JSONObject

/**
 * GET /config for the logged-in subscriber: the MyMu host + brain agent + the
 * drawer's curated roster, and the legacy chat share URL (iOS MyMuHint +
 * ChatURLSync). Also the login probe: a token the server rejects = not logged in.
 */
object ServerConfig {
    /** Blocking — call off the main thread. Returns the parsed body or null. */
    fun fetch(t: Target = Target.current()): JSONObject? {
        if (!t.hasToken) return null
        return runCatching {
            Net.http.newCall(Request.Builder().url(t.url("/config")).build()).execute().use { r ->
                if (r.isSuccessful) JSONObject(r.body!!.string()) else null
            }
        }.getOrNull()
    }

    /** Fetch + store what the app keeps from it. Returns true when the server accepted the token. */
    fun sync(): Boolean {
        val c = fetch() ?: return false
        c.optString("chatUrl").takeIf { it.isNotEmpty() }?.let { Config.chatURL = it }
        c.optJSONObject("mymu")?.let { m ->
            m.optString("host").takeIf { it.isNotEmpty() }?.let { Config.mymuHost = it }
            val agent = m.optString("agent").takeIf { it.isNotEmpty() }
            agent?.let { Config.mymuAgent = it }
            val list = m.optJSONArray("agents")?.let { a -> (0 until a.length()).map { a.optString(it) }.filter { it.isNotEmpty() } }
                .orEmpty()
            Config.mymuAgentsCSV = (list.ifEmpty { listOfNotNull(agent) }).joinToString(",")
        }
        return true
    }
}
