package com.mymu.app.core

import org.json.JSONArray
import org.json.JSONObject

/** One remembered (host, username) pair from a past successful login. */
data class LoginMemory(val origin: String, val username: String) {
    val id: String get() = "$origin|$username"

    /** Chip label: host without the scheme noise (a distinct port stays). */
    val hostLabel: String
        get() = origin.replace("https://", "").replace("http://", "")
}

/**
 * Hosts + usernames from past SUCCESSFUL logins, surviving sign-out (Manar,
 * 2026-09-19: "I logout from a host, then I log again, no rememberance").
 * Signing out rightly deletes the account and its token — but it must not
 * erase the MEMORY that the host exists; retyping full origins was the pain.
 * Passwords are never stored here; this is autocomplete, not credentials.
 * Its Prefs key is deliberately none of the ones `AppState.removeAccount`
 * touches. (1:1 port of iOS Core/LoginHistory.swift, same key + cap.)
 */
object LoginHistory {
    private const val KEY = "mymu.loginHistory"
    private const val CAP = 12

    fun all(): List<LoginMemory> = decode(Prefs.getString(KEY))

    /** Most-recent-first upsert, called on every successful login. */
    fun record(origin: String, username: String) {
        val entry = LoginMemory(Config.normalize(origin), username)
        Prefs.putString(KEY, encode(recording(all(), entry)))
    }

    /** The upsert rule itself, kept pure for the JVM test: the same id moves
     * to the front rather than duplicating, and the list trims to the cap. */
    internal fun recording(items: List<LoginMemory>, entry: LoginMemory): List<LoginMemory> =
        (listOf(entry) + items.filter { it.id != entry.id }).take(CAP)

    /** JSON array of {origin, username} — the iOS Codable shape, so the two
     * stores stay diffable side by side. */
    internal fun encode(items: List<LoginMemory>): String {
        val arr = JSONArray()
        for (m in items) arr.put(JSONObject().put("origin", m.origin).put("username", m.username))
        return arr.toString()
    }

    internal fun decode(raw: String?): List<LoginMemory> {
        if (raw == null) return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { i ->
                val o = arr.opt(i) as? JSONObject ?: return@mapNotNull null
                val origin = o.optString("origin", "")
                if (origin.isEmpty()) null else LoginMemory(origin, o.optString("username", ""))
            }
        } catch (_: Exception) {
            emptyList()
        }
    }
}
