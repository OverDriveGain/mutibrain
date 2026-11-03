package com.mymu.app.core

/**
 * One live [RelayClient] per conversation, owned HERE rather than by the chat
 * screen — the structural fix for "I send, go out, come back, and the message
 * is gone until the server spits the whole turn in" (Manar, 2026-10-24; port
 * of iOS Core/ConversationRegistry.swift).
 *
 * The chat screen used to own its relay in a `remember {}`: Back disposed it,
 * the socket with it, and the next open started from a snapshot written
 * before the send. Now the screen only BORROWS the client for this
 * conversation (keyed by host + session) and the registry keeps it alive:
 *
 * - while a turn is running the socket stays open after the screen is gone, so
 *   the stream keeps landing in the store (and in the snapshot) exactly as if
 *   the user had stayed — re-entry shows the reply where it got to, no fetch
 *   needed. Presence is released on every re-subscribe while unwatched, so
 *   push notifications still fire for an unwatched reply.
 * - an idle client disconnects after a short grace (quick tab-out-and-back
 *   never reconnects) but keeps its transcript in RAM; the snapshot on disk
 *   backs it if the registry evicts it (bounded LRU).
 *
 * The registry is also the one place that reacts to app lifecycle for
 * clients the visible screen does not own (background → release presence;
 * foreground → reconnect anything mid-turn). All calls happen on Main.
 */
object ConversationRegistry {
    private val clients = mutableMapOf<String, RelayClient>()
    /** Most-recently-used LAST. */
    private val recency = mutableListOf<String>()
    /** Instances kept alive beyond what is on screen. Each holds one page of
     * transcript (≤200 rows) — cheap — and at most one socket. */
    private const val KEEP_ALIVE = 6

    fun key(origin: String?, sessionId: String): String =
        "${Config.normalize(origin ?: "")}|$sessionId"

    /**
     * The client for this conversation — existing (live transcript, maybe a
     * live socket) or freshly built from the RAM snapshot. A conversation
     * with no id yet (brand-new local chat) is handed an unregistered client;
     * [register] adopts it once `session_created` assigns the real id.
     */
    fun client(token: String, sessionId: String, isRemote: Boolean, projectPath: String?,
               origin: String?): RelayClient {
        if (sessionId.isEmpty()) {
            return RelayClient(token = token, sessionId = sessionId, isRemote = isRemote,
                projectPath = projectPath, origin = origin)
        }
        val k = key(origin, sessionId)
        clients[k]?.let { existing ->
            existing.updateToken(token)
            touch(k)
            return existing
        }
        val snap = ChatCacheStore.cached(sessionId)
        val c = RelayClient(token = token, sessionId = sessionId, isRemote = isRemote,
            projectPath = projectPath, origin = origin, seed = snap)
        clients[k] = c
        touch(k)
        evictIfNeeded()
        return c
    }

    /** A client that already exists for this session on ANY host — previews
     * read the live transcript from here before falling back to the disk
     * snapshot. */
    fun peek(sessionId: String): RelayClient? {
        if (sessionId.isEmpty()) return null
        return clients.values.firstOrNull { it.sessionId == sessionId }
    }

    /** Adopt a client under its (new) key — called after a session-id rebind. */
    fun register(client: RelayClient) {
        if (client.sessionId.isEmpty()) return
        val k = key(client.origin, client.sessionId)
        clients[k] = client
        touch(k)
        evictIfNeeded()
    }

    private fun touch(k: String) {
        recency.remove(k)
        recency.add(k)
    }

    /** Drop the oldest IDLE, UNWATCHED clients beyond the cap. A client mid-turn
     * is never evicted — its socket is the thing keeping the reply flowing. */
    private fun evictIfNeeded() {
        var excess = recency.size - KEEP_ALIVE
        if (excess <= 0) return
        for (k in recency.toList()) {
            if (excess <= 0) break
            val c = clients[k] ?: continue
            if (c.isVisible || c.isLoading.value) continue
            c.persistNow()
            c.dispose()
            clients.remove(k)
            recency.remove(k)
            excess -= 1
        }
    }

    /** App went to the background: nobody is watching any of these. */
    fun appBackgrounded() {
        for (c in clients.values) {
            c.persistNow()
            c.releasePresence()
        }
    }

    /** App is back: only the unwatched mid-turn ones — the visible chat kicks
     * its own. */
    fun appForegrounded() {
        for (c in clients.values) {
            if (!c.isVisible && c.isLoading.value) c.ensureConnected()
        }
    }

    /** Account removal: nothing may outlive the login that fetched it. */
    fun clearAll() {
        for (c in clients.values) c.dispose()
        clients.clear()
        recency.clear()
    }
}
