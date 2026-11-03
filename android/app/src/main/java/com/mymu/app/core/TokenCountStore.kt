package com.mymu.app.core

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * Last-known context consumption per session — shared by every list row that
 * shows a token count. (1:1 port of iOS TokenCountStore: counts persist and
 * render instantly, probes revalidate concurrently with a small cap and a
 * short timeout so one dead host can't block the rest.)
 */
object TokenCountStore {
    val counts = MutableStateFlow<Map<String, Int>>(emptyMap())
    /** Live progress of the current batch refresh — (done, total) while probes
     * are in flight, null when idle. Lists narrate THIS ("Updating usage 4/9")
     * instead of holding a refresh spinner hostage until the slowest probe. */
    val progress = MutableStateFlow<Pair<Int, Int>?>(null)
    private val inFlight = mutableSetOf<String>()

    private const val PREFS_KEY = "mymu.tokenCounts"
    private const val PROBE_TIMEOUT_S = 8L
    private const val MAX_CONCURRENT = 5

    fun load() {
        Prefs.getString(PREFS_KEY)?.let { raw ->
            try {
                val o = JSONObject(raw)
                counts.value = buildMap { for (k in o.keys()) o.intOrNull(k)?.let { put(k, it) } }
            } catch (_: Exception) {}
        }
    }

    private fun persist() {
        // Bound the persisted set so it can't grow with every session ever seen.
        val snapshot = counts.value.entries.take(400)
        val o = JSONObject()
        for ((k, v) in snapshot) o.put(k, v)
        Prefs.putString(PREFS_KEY, o.toString())
    }

    private suspend fun fetch(sessionId: String, api: ApiClient): Int? {
        val used = try {
            api.history(sessionId, limit = 1, timeoutSeconds = PROBE_TIMEOUT_S).context?.usedTokens
        } catch (_: Exception) { null }
        return if ((used ?: 0) > 0) used else null
    }

    /** Batch refresh (the Agents roster). Missing-only unless `force`; rows
     * fill in one by one, sliding-window concurrency. */
    suspend fun refresh(sessionIds: List<String>, api: ApiClient, force: Boolean = false) {
        val wanted = synchronized(inFlight) {
            sessionIds.filter { (force || counts.value[it] == null) && it !in inFlight }
                .also { inFlight.addAll(it) }
        }
        if (wanted.isEmpty()) return
        // Accumulate into any batch already narrating (parallel refreshes sum).
        val running = progress.value ?: (0 to 0)
        progress.value = running.first to (running.second + wanted.size)
        try {
            coroutineScope {
                val queue = Channel<String>(Channel.UNLIMITED)
                wanted.forEach { queue.trySend(it) }
                queue.close()
                repeat(MAX_CONCURRENT) {
                    launch {
                        for (sid in queue) {
                            fetch(sid, api)?.let { used -> counts.value = counts.value + (sid to used) }
                            progress.value?.let { p -> progress.value = (p.first + 1) to p.second }
                        }
                    }
                }
            }
        } finally {
            synchronized(inFlight) {
                inFlight.removeAll(wanted.toSet())
                if (inFlight.isEmpty()) progress.value = null
            }
            persist()
        }
    }

    /** One lazy probe — Conversations rows fire these as they scroll into view. */
    suspend fun probe(sessionId: String, api: ApiClient) {
        synchronized(inFlight) {
            if (counts.value[sessionId] != null || sessionId in inFlight) return
            inFlight.add(sessionId)
        }
        try {
            fetch(sessionId, api)?.let { used ->
                counts.value = counts.value + (sessionId to used)
                persist()
            }
        } finally {
            synchronized(inFlight) { inFlight.remove(sessionId) }
        }
    }

    /** "412" / "4.2k" / "1.3M" — compact count for trailing edges. */
    fun compactLabel(n: Int): String = when {
        n >= 1_000_000 -> "%.1fM".format(n / 1_000_000.0)
        n >= 1_000 -> "${Math.round(n / 1_000.0)}k"
        else -> "$n"
    }
}
