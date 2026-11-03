package com.mymu.app.core

/**
 * Per-conversation composer drafts (port of iOS Core/DraftStore.swift; Manar,
 * 2026-09-19): text typed but not sent survives leaving the chat — switching
 * agents and coming back finds the draft where it was left, the Mail/Telegram
 * convention. Remote chats key by AGENT (projectId): session ids rotate on
 * agent restarts and the draft belongs to the agent, not the socket. Local
 * chats key by session. Prefs (the UserDefaults counterpart) is plenty —
 * drafts are in-flight typing, not documents — and empty text removes its
 * entry so the store never accumulates. The key is the iOS name verbatim
 * (`mymu.draft.<id>`), like every other Prefs key.
 */
object DraftStore {
    private fun key(id: String) = "mymu.draft.$id"

    /** The backing store. Prefs needs a Context (SharedPreferences) that no
     * JVM unit test has, so the two accessors are swappable — the test points
     * them at a map; production never touches these. */
    internal var read: (String) -> String? = { Prefs.getString(it) }
    internal var write: (String, String?) -> Unit = { k, v -> Prefs.putString(k, v) }

    fun load(id: String): String? {
        if (id.isEmpty()) return null
        return read(key(id))?.takeIf { it.isNotEmpty() }
    }

    fun save(text: String, id: String) {
        if (id.isEmpty()) return
        // null removes (Prefs.putString contract) — same as the iOS
        // removeObject branch.
        write(key(id), text.ifEmpty { null })
    }

    /** A type-to-switch hands the draft to another agent — the origin's copy
     * must not linger and greet the user as a stale duplicate later. */
    fun clear(id: String) = save("", id)
}
