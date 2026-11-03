package com.mymu.app.core

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Persistent snapshot of every agent conversation — what makes the chat
 * LOCAL-FIRST (port of iOS Core/ChatCacheStore.swift, wave 6; Manar,
 * 2026-10-24: "we already know we sent the message and it succeeded, why
 * reload it from the server").
 *
 * History: this began (2026-09-19) as a warm-start cache written at exactly
 * two moments — the open fetch and the end-of-turn reconcile. That left a hole
 * that read as a bug: a message sent, then Back, then re-open rendered the
 * OLD snapshot (no sent bubble, no reply) and the server's refresh then
 * dumped the whole turn in at once. The store is now written on every
 * transcript mutation (debounced by the relay) and carries the turn state —
 * is the agent working, since when, which user message opened the turn, the
 * replay cursor — so a conversation re-opens EXACTLY as it was left, ball
 * still pulsing, and the live stream merely continues it.
 *
 * Snapshots live in cacheDir (the OS may evict them; they rebuild on the
 * next open) and are wiped when an account is removed.
 */
object ChatCacheStore {
    private lateinit var dir: File
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Newest page only — mirrors what a fresh open fetches, so cache and
     * network agree on shape ("Load earlier messages" covers the rest). */
    private const val MAX_MESSAGES = 200
    private const val MAX_SESSIONS = 40
    /** A "loading" flag older than this is not trusted on restore — the turn
     * ended while the app was dead and the agent-status poll will say so. */
    const val STALE_LOADING_AFTER_MS = 3L * 60 * 60 * 1000

    /**
     * Turn-level state saved beside the messages. Optional in the snapshot so
     * pre-existing files (no `turn` key) still decode.
     */
    data class TurnState(
        val isLoading: Boolean,
        /** ISO timestamp the running turn started (anchors the elapsed timer). */
        val startedAt: String?,
        /** Id of the user message that opened the turn FROM THIS DEVICE — the
         * geometry anchor the chat keeps at the top of the viewport. */
        val activeTurnUserId: String?,
        /** Highest server `seq` seen (the replay cursor). */
        val lastSeq: Int,
        /** When this state was written. */
        val savedAt: String,
    ) {
        val isLoadingFresh: Boolean
            get() {
                if (!isLoading) return false
                val saved = RelayClient.parseIso(savedAt) ?: return false
                return System.currentTimeMillis() - saved < STALE_LOADING_AFTER_MS
            }

        fun toJson(): JSONObject = JSONObject().apply {
            put("isLoading", isLoading)
            startedAt?.let { put("startedAt", it) }
            activeTurnUserId?.let { put("activeTurnUserId", it) }
            put("lastSeq", lastSeq)
            put("savedAt", savedAt)
        }

        companion object {
            fun fromJson(o: JSONObject?): TurnState? {
                o ?: return null
                return TurnState(
                    isLoading = o.boolOrNull("isLoading") ?: false,
                    startedAt = o.stringOrNull("startedAt"),
                    activeTurnUserId = o.stringOrNull("activeTurnUserId"),
                    lastSeq = o.intOrNull("lastSeq") ?: 0,
                    savedAt = o.stringOrNull("savedAt") ?: "",
                )
            }
        }
    }

    data class Snapshot(
        val messages: List<ChatMessage>,
        val hasMore: Boolean?,
        val context: ContextUsage?,
        val turn: TurnState? = null,
    )

    private val lock = Any()
    /** Fingerprint of what's on disk per session, so an unchanged transcript
     * is never re-encoded or rewritten. */
    private val savedFingerprints = mutableMapOf<String, Int>()
    /** Turn state last written per session (savedAt excluded from the compare —
     * a bare clock tick must not cost a disk write). */
    private val savedTurns = mutableMapOf<String, TurnState?>()
    /** Decoded snapshots held in RAM. This is what makes opening a chat
     * INSTANT: the registry reads it synchronously when it builds a client,
     * so the first rendered frame already contains the transcript — no
     * loader, no disk hop on the open path. Populated by warm() (roster
     * load), load() and save(). */
    private val memory = mutableMapOf<String, Snapshot>()

    fun init(context: Context) {
        dir = File(context.cacheDir, "chat-cache")
    }

    /** Synchronous RAM hit — null means "not warmed yet", NOT "no cache";
     * callers fall back to the suspend load() for the disk answer. */
    fun cached(sessionId: String): Snapshot? = synchronized(lock) { memory[sessionId] }

    /** Decode disk snapshots into RAM ahead of need (called when the agent
     * roster lands), so first opens hit memory too. Skips already-warm ids;
     * decodes off-main, one pass. */
    fun warm(sessionIds: List<String>) {
        if (!::dir.isInitialized) return
        val cold = synchronized(lock) { sessionIds.filter { it.isNotEmpty() && memory[it] == null } }
        if (cold.isEmpty()) return
        scope.launch {
            for (sid in cold) {
                val snap = decode(sid) ?: continue
                synchronized(lock) { if (memory[sid] == null) adopt(sid, snap) }
            }
        }
    }

    /** Must be called holding `lock`. */
    private fun adopt(sid: String, snap: Snapshot) {
        memory[sid] = snap
        savedFingerprints[sid] = fingerprint(snap.messages)
        savedTurns[sid] = snap.turn
    }

    /** The transcript identity that matters for "did anything change": row
     * ids, visible text length, and tool progress. Deliberately NOT the full
     * content bytes — one pass over lengths catches every real mutation the
     * server can make. */
    fun fingerprint(messages: List<ChatMessage>): Int {
        var h = messages.size
        for (m in messages) {
            h = 31 * h + m.id.hashCode()
            h = 31 * h + m.bodyText.length
            h = 31 * h + (m.status?.hashCode() ?: 0)
            h = 31 * h + if (m.toolResult != null) 1 else 0
        }
        return h
    }

    suspend fun load(sessionId: String): Snapshot? {
        if (sessionId.isEmpty() || !::dir.isInitialized) return null
        synchronized(lock) { memory[sessionId] }?.let { return it }
        val snap = withContext(Dispatchers.IO) { decode(sessionId) } ?: return null
        synchronized(lock) { adopt(sessionId, snap) }
        return snap
    }

    private fun decode(sessionId: String): Snapshot? {
        val body = try { fileFor(sessionId).readText() } catch (_: Exception) { return null }
        return try {
            val o = JSONObject(body)
            val arr = o.optJSONArray("messages") ?: JSONArray()
            Snapshot(
                messages = (0 until arr.length()).mapNotNull {
                    (arr.opt(it) as? JSONObject)?.let(ChatMessage::fromJson)
                },
                hasMore = o.boolOrNull("hasMore"),
                context = ContextUsage.fromJson(o.opt("context") as? JSONObject),
                turn = TurnState.fromJson(o.opt("turn") as? JSONObject),
            )
        } catch (_: Exception) { null }
    }

    /** Write a snapshot. Change-gated on the transcript fingerprint AND the
     * turn state (minus its clock), encoded and written off-main. */
    fun save(sessionId: String, messages: List<ChatMessage>, hasMore: Boolean?, context: ContextUsage?,
             turn: TurnState? = null) {
        if (sessionId.isEmpty() || messages.isEmpty() || !::dir.isInitialized) return
        // `queued` is local mid-turn state; a reopened chat must not resurrect
        // ghost "queued" chips from a turn that finished long ago.
        val page = messages.takeLast(MAX_MESSAGES).map { if (it.queued == true) it.copy(queued = null) else it }
        val fp = fingerprint(page)
        val snap = Snapshot(page, hasMore, context, turn)
        synchronized(lock) {
            val turnChanged = !sameTurn(savedTurns[sessionId], turn)
            if (savedFingerprints[sessionId] == fp && !turnChanged) return
            savedFingerprints[sessionId] = fp
            savedTurns[sessionId] = turn
            memory[sessionId] = snap
        }
        scope.launch {
            try {
                val o = JSONObject()
                o.put("messages", JSONArray(page.map { it.toJson() }))
                hasMore?.let { o.put("hasMore", it) }
                context?.let {
                    o.put("context", JSONObject()
                        .put("usedTokens", it.usedTokens)
                        .put("windowTokens", it.windowTokens))
                }
                turn?.let { o.put("turn", it.toJson()) }
                dir.mkdirs()
                fileFor(sessionId).writeText(o.toString())
                prune()
            } catch (_: Exception) {}
        }
    }

    private fun sameTurn(a: TurnState?, b: TurnState?): Boolean {
        if (a == null && b == null) return true
        if (a == null || b == null) return false
        return a.isLoading == b.isLoading && a.startedAt == b.startedAt
            && a.activeTurnUserId == b.activeTurnUserId && a.lastSeq == b.lastSeq
    }

    /** Account removal wipes everything — snapshots are cheap to rebuild and
     * must not outlive the login that fetched them. */
    fun clearAll() {
        synchronized(lock) {
            savedFingerprints.clear()
            savedTurns.clear()
            memory.clear()
        }
        if (!::dir.isInitialized) return
        scope.launch { try { dir.deleteRecursively() } catch (_: Exception) {} }
    }

    private fun fileFor(sessionId: String): File {
        val safe = sessionId.map { if (it.isLetterOrDigit() || it == '-' || it == '_') it else '_' }
            .joinToString("")
        return File(dir, "$safe.json")
    }

    /** Oldest snapshots beyond the cap go; runs on the write queue, best-effort. */
    private fun prune() {
        val files = dir.listFiles() ?: return
        if (files.size <= MAX_SESSIONS) return
        files.sortedBy { it.lastModified() }
            .take(files.size - MAX_SESSIONS)
            .forEach { try { it.delete() } catch (_: Exception) {} }
    }
}
