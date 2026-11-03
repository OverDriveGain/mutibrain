package com.mymu.app.core

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * The per-conversation STORE: the transcript, the turn state, and the live
 * socket for one session on one host. Owned by [ConversationRegistry] (not by
 * the chat screen), so it outlives the screen that shows it — the chat is
 * local-first: what the user sees is the truth the app already holds, the
 * server only ever CONTINUES it (Manar, 2026-10-24; 1:1 port of iOS
 * Core/RelayClient.swift, wave 6).
 *
 * Three rules keep it honest:
 *  1. Every mutation is persisted (debounced) — a re-open renders the exact
 *     state that was left, sent message, half-streamed reply, pulsing ball.
 *  2. Inbound frames are idempotent. The server re-flushes the current
 *     turn's frame buffer on every (re)subscribe — id'd frames dedupe by id,
 *     id-less stream deltas are ABSORBED as a running prefix of the newest
 *     assistant row, and the final `text` frame finalizes the streaming
 *     bubble in place rather than sitting beside it.
 *  3. A history fetch is a MERGE, never a replace: [mergingLiveTail] keeps
 *     what the server hasn't caught up to; the swap is fingerprint-gated so
 *     a quiet reconcile paints nothing.
 */
class RelayClient(
    token: String,
    sessionId: String,
    val isRemote: Boolean,
    private val projectPath: String? = null,
    /** Host this conversation talks to (agent→host pinning); null = active host. */
    val origin: String? = null,
    seed: ChatCacheStore.Snapshot? = null,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    val messages = MutableStateFlow<List<ChatMessage>>(emptyList())
    val isLoading = MutableStateFlow(false)
    /** When the current turn started (epoch ms) — drives the elapsed timer. */
    val turnStartedAt = MutableStateFlow<Long?>(null)
    /** Tokens the context grew since the turn started ("tokens this turn"). */
    val turnTokens = MutableStateFlow<Int?>(null)
    val statusText = MutableStateFlow<String?>(null)
    val connected = MutableStateFlow(false)
    val pendingPermission = MutableStateFlow<ChatMessage?>(null)
    /** Bumped on EVERY content mutation — the view follows this. */
    val revision = MutableStateFlow(0)
    /** Context-window fullness from the last history fetch (null until known). */
    val context = MutableStateFlow<ContextUsage?>(null)
    /** A history reconcile is in flight. Surfaced as a small honest signal in
     * the status strip — never as a loader over content the user can read. */
    val syncing = MutableStateFlow(false)
    /** The user message that opened the turn FROM THIS DEVICE. The chat keeps
     * that row at the top of the viewport for the whole turn (the ChatGPT
     * "message goes to the top, reply streams under it" geometry). Survives
     * Back/re-open because the client does; restored from the snapshot when
     * the turn is still running after a cold start. */
    val activeTurnUserId = MutableStateFlow<String?>(null)
    /** Older messages exist beyond the loaded page (from the last fetch). */
    val hasMore = MutableStateFlow<Boolean?>(null)
    /** Off for the offline demo: canned transcripts must not be written into
     * the real cache. */
    var persistenceEnabled = true
    /** A canned conversation (the offline demo, the DEBUG stream simulation):
     * this store never opens the socket nor fetches history — nothing on it
     * may touch the network (iOS RelayClient.offline). Matters beyond
     * tidiness: a simulated turn's `complete` schedules a reconcile, and the
     * demo host bans an IP after a handful of 4xx. */
    var offline = false
    /** A transcript has been established — seeded from a snapshot or fetched
     * once. The screen skips the blocking open path when this is already true. */
    var hasLoadedOnce = false
        private set

    var token: String = token
        private set
    var sessionId: String = sessionId
        private set

    /** Fired when a NEW local conversation is assigned its real id mid-turn. */
    var onSessionIdRebound: ((String) -> Unit)? = null

    /** Remote agent sessions accept messages MID-TURN (agent-native queue). */
    val supportsMidTurnSend: Boolean get() = isRemote

    private var turnStartContext: Int? = null
    /** True once turnStartedAt holds the REAL turn start. */
    private var turnAnchored = false
    /** Armed by send(); the first response frame ends the wait. */
    private var awaitingFirstResponse = false

    private var ws: WebSocket? = null
    private var keepAlive: Job? = null
    private var streamingId: String? = null
    private var seq = 0
    private var reconnectAttempts = 0
    private var intentionalClose = false
    /** Highest `seq` seen — chat.subscribe replays everything after this. */
    private var lastSeq = 0

    // MARK: visibility / lifecycle owned by the registry

    /** A chat screen is showing this conversation right now. */
    var isVisible = false
        private set
    private var graceDisconnect: Job? = null
    /** Idle and unwatched: the socket goes after this (a quick tab-out-and-
     * back never reconnects). */
    private val idleGraceMs = 15_000L
    /** Unwatched but mid-turn: the socket stays so the reply keeps landing in
     * the store — bounded, so a hung agent can't pin a socket forever. */
    private val busyGraceMs = 20L * 60 * 1000

    // Mutable bookkeeping declared BEFORE the init block below: Kotlin runs
    // property initializers in textual order, and adoptSnapshot() (via
    // setLoading → persistSoon) touches these.
    private var persistJob: Job? = null
    private var reconcileInFlight = false
    private var absorbQueue = mutableListOf<String>()
    private var absorbCursor = 0
    private var absorbed = ""
    private var pendingChunk = ""
    private var chunkFlushJob: Job? = null

    init {
        if (seed != null) adoptSnapshot(seed)
    }

    // isLoading transitions carry state resets, like the iOS didSet.
    private fun setLoading(v: Boolean) {
        val old = isLoading.value
        if (v && !old) {
            // Provisional anchor — the real turn start replaces it via applyServerTurnStart.
            turnStartedAt.value = System.currentTimeMillis()
            turnAnchored = false
            turnStartContext = context.value?.usedTokens
            turnTokens.value = null
        }
        if (!v) {
            turnStartedAt.value = null; turnAnchored = false
            turnStartContext = null; turnTokens.value = null
        }
        isLoading.value = v
        if (v != old) persistSoon()
    }

    private fun noteResponseActivity() {
        if (awaitingFirstResponse) { awaitingFirstResponse = false; Haptics.firstResponse() }
    }

    /** Warm start: the FIRST rendered frame carries the transcript — and the
     * turn exactly as it was left, if the snapshot says it was still running
     * recently. Used by init (RAM hit) and by the screen's disk fallback. */
    fun adoptSnapshot(seed: ChatCacheStore.Snapshot) {
        if (seed.messages.isEmpty()) return
        messages.value = seed.messages
        context.value = seed.context
        hasMore.value = seed.hasMore
        hasLoadedOnce = true
        seed.turn?.let { turn ->
            lastSeq = max(lastSeq, turn.lastSeq)
            if (turn.isLoadingFresh && !isLoading.value) {
                setLoading(true)
                turn.startedAt?.let { parseIso(it) }?.let { turnStartedAt.value = it; turnAnchored = true }
                activeTurnUserId.value = turn.activeTurnUserId
            }
        }
        revision.value += 1
    }

    /** Account re-login can rotate the token under a long-lived client. */
    fun updateToken(new: String) {
        if (new == token) return
        token = new
        if (ws != null) { disconnect(); connect() }
    }

    fun viewAppeared() {
        isVisible = true
        graceDisconnect?.cancel(); graceDisconnect = null
    }

    /** The screen left. Keep the transcript (and the socket while a turn is
     * running) — see ConversationRegistry. Presence is released at once so a
     * reply finishing while unwatched pushes a notification. */
    fun viewDisappeared() {
        isVisible = false
        finishRevealNow()
        persistNow()
        releasePresence()
        scheduleGraceDisconnect()
    }

    private fun scheduleGraceDisconnect() {
        graceDisconnect?.cancel()
        if (ws == null) return
        val delayMs = if (isLoading.value) busyGraceMs else idleGraceMs
        graceDisconnect = scope.launch {
            delay(delayMs)
            if (isVisible) return@launch
            persistNow()
            disconnect()
        }
    }

    // MARK: persistence

    private fun turnState(): ChatCacheStore.TurnState = ChatCacheStore.TurnState(
        isLoading = isLoading.value,
        startedAt = turnStartedAt.value?.let { Instant.ofEpochMilli(it).toString() },
        activeTurnUserId = activeTurnUserId.value,
        lastSeq = lastSeq,
        savedAt = Instant.now().toString(),
    )

    /** Debounced snapshot write — stream chunks coalesce into one write per
     * ~third of a second; the store skips the write when nothing changed. */
    fun persistSoon() {
        if (!isRemote || !persistenceEnabled || sessionId.isEmpty()) return
        if (persistJob != null) return
        persistJob = scope.launch {
            delay(350)
            persistJob = null
            persistNow()
        }
    }

    fun persistNow() {
        persistJob?.cancel(); persistJob = null
        if (!isRemote || !persistenceEnabled || sessionId.isEmpty()) return
        ChatCacheStore.save(sessionId, persistableMessages(), hasMore.value, context.value, turnState())
    }

    // MARK: Lifecycle

    fun connect() {
        intentionalClose = false
        openSocket()
    }

    private fun openSocket() {
        if (offline || ws != null) return
        val req = Request.Builder().url(Config.webSocketUrl(token, origin)).build()
        ws = ApiClient.http.newWebSocket(req, object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                scope.launch {
                    // A socket we already replaced (token rotation, explicit
                    // reconnect) must not feed the live store.
                    if (ws !== webSocket) return@launch
                    reconnectAttempts = 0
                    // Frame trace for emulator passes (`adb logcat -s MyMuRelay`).
                    Log.d("MyMuRelay", "← " + text.take(400))
                    handle(text)
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                scope.launch {
                    if (ws === webSocket) {
                        connected.value = false
                        scheduleReconnect()
                    }
                }
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                scope.launch {
                    if (ws === webSocket) {
                        connected.value = false
                        scheduleReconnect()
                    }
                }
            }
        })
        connected.value = true
        subscribe()
        keepAlive?.cancel()
        keepAlive = scope.launch {
            while (isActive) {
                delay(45_000)
                subscribe()
            }
        }
    }

    fun disconnect() {
        intentionalClose = true
        keepAlive?.cancel(); keepAlive = null
        graceDisconnect?.cancel(); graceDisconnect = null
        ws?.close(1001, null)
        ws = null
        connected.value = false
    }

    /** Tear down coroutines — the registry calls this when it evicts or
     * clears a client; the screen never does (it only borrows the client). */
    fun dispose() {
        disconnect()
        scope.cancel()
    }

    private fun subscribe(retryOnce: Boolean = false) {
        // A brand-new conversation has no id to attach yet — the first send
        // allocates one and subscribes.
        if (sessionId.isEmpty()) return
        // Every (re)subscribe makes the server re-flush the current turn's
        // frames — arm the absorber so the replay lands on what's already here.
        armReplayAbsorption()
        sendJson(JSONObject()
            .put("type", "chat.subscribe")
            .put("sessions", JSONArray().put(JSONObject().put("sessionId", sessionId).put("lastSeq", lastSeq))),
            retryOnce = retryOnce)
        // Subscribing marks presence server-side ("user is looking") which
        // suppresses push for this session — only true while a screen shows it.
        if (!isVisible) releasePresence()
    }

    /**
     * Foreground kick: Android kills sockets in the background too — they look
     * alive until the next I/O fails. Re-subscribe (or reopen) and reconcile.
     * `retryOnce` matters here: this resubscribe is the ONLY thing that fires
     * the instant the app foregrounds, straight onto a socket that may already
     * be dead — without it, that send just vanishes and recovery waits on the
     * passive failure + exponential backoff.
     */
    fun ensureConnected() {
        if (offline) return
        intentionalClose = false
        if (ws == null) openSocket() else subscribe(retryOnce = true)
        reconcile()
    }

    private fun scheduleReconnect() {
        if (intentionalClose) return
        ws = null
        reconnectAttempts += 1
        // Fast first retries (0.5s, 1s, 2s…) — no visible dead air after blips.
        val delayS = min(0.5 * 2.0.pow((reconnectAttempts - 1).toDouble()), 8.0)
        scope.launch {
            delay((delayS * 1000).toLong())
            if (intentionalClose) return@launch
            openSocket()
            reconcile()   // catch up on anything missed while disconnected
        }
    }

    // MARK: Outbound

    /**
     * Send a prompt, optionally with attachments as
     * `[{name, data: "data:<mime>;base64,…"}]` — uploaded to the asset store
     * first and referenced by path (standard claudecodeui flow).
     */
    fun send(text: String, attachments: List<Map<String, String>> = emptyList(),
             permissionMode: PermissionMode? = null, model: String? = null) {
        val trimmed = text.trim()
        if (trimmed.isEmpty() && attachments.isEmpty()) return
        // Images render inline in the bubble; only non-image files fall back to
        // a "📎 name" chip line.
        val imageUrls = attachments.mapNotNull { it["data"] }.filter { it.startsWith("data:image/") }
        val otherFiles = attachments.filter { !(it["data"]?.startsWith("data:image/") ?: false) }
        var shown = trimmed
        if (otherFiles.isNotEmpty()) {
            val names = otherFiles.mapNotNull { it["name"] }.joinToString("\n") { "📎 $it" }
            shown = if (shown.isEmpty()) names else "$shown\n$names"
        }
        stageOutgoing(shown, imageUrls)
        // A send into a dead socket would silently vanish behind the optimistic
        // bubble. Reopen before sending.
        intentionalClose = false
        if (ws == null) openSocket()
        scope.launch {
            // 1. Sessions exist BEFORE the first message (allocated over REST —
            //    the standard claudecodeui contract).
            if (sessionId.isEmpty()) {
                val newId = try {
                    projectPath?.let { ApiClient(token, origin).createProviderSession(projectPath = it) }
                } catch (_: Exception) { null }
                if (newId == null) {
                    appendOrReplace(ChatMessage(id = "err-${nextSeq()}", kind = "error", role = "assistant",
                        content = "Could not create a session on this server.", isError = true))
                    setLoading(false)
                    return@launch
                }
                rebind(newId)
                subscribe()   // attach the live stream so replay covers the whole run
            }
            // 2. Attachments go to the asset store first; a failed upload keeps
            //    the text going and reports the loss instead of vanishing.
            val options = JSONObject()
            if (permissionMode != null) options.put("permissionMode", permissionMode.raw)
            // The server records this against the session, so a later reopen
            // resumes on the same model.
            if (!model.isNullOrEmpty()) options.put("model", model)
            if (attachments.isNotEmpty()) {
                try {
                    val records = uploadAttachments(attachments)
                    if (records.isNotEmpty()) {
                        val arr = JSONArray()
                        for (r in records) arr.put(r)
                        options.put("images", arr)
                    }
                } catch (e: Exception) {
                    appendOrReplace(ChatMessage(id = "err-${nextSeq()}", kind = "error", role = "assistant",
                        content = "Attachment upload failed — sending without files. (${e.message})",
                        isError = true))
                }
            }
            sendJson(JSONObject()
                .put("type", "chat.send")
                .put("sessionId", sessionId)
                .put("content", trimmed)
                .put("options", options), retryOnce = true)
        }
    }

    /** The optimistic bubble + the turn state a send opens (iOS stageOutgoing). */
    private fun stageOutgoing(shown: String, imageUrls: List<String>) {
        finishRevealNow()
        val localId = "local-${nextSeq()}"
        var localMsg = ChatMessage(id = localId, clientId = localId, kind = "text", role = "user", content = shown)
        if (imageUrls.isNotEmpty()) localMsg = localMsg.copy(images = imageUrls)
        // Mid-turn send: the relay queues it behind the current run. Say so on
        // the bubble — an optimistic bubble with no marker read as "sent and
        // ignored" while the agent was simply busy.
        val queued = isLoading.value
        if (queued) localMsg = localMsg.copy(queued = true)
        // The optimistic bubble is the SEND moment of the choreography: it
        // transitions in (flies up out of the composer) and, for a fresh turn,
        // becomes the row the viewport keeps at the top. A queued message joins
        // the turn already in progress instead of re-anchoring it.
        // A new turn starts here: nothing streamed for it can be a replay, so
        // the absorber armed at the last (re)subscribe — still queued on the
        // PREVIOUS turn's reply — must stand down (emulator pass 2026-10-24:
        // the demo backend's canned reply is byte-identical to the last one,
        // and the whole stream was swallowed as a "replay" of that row).
        if (!queued) disarmReplayAbsorption()
        appendOrReplace(localMsg)
        if (!queued) activeTurnUserId.value = localMsg.id
        setLoading(true)
        // A turn started HERE is anchored exactly by the send moment; a mid-turn
        // queued message must NOT restart the timer (isLoading was already true).
        turnAnchored = true
        awaitingFirstResponse = true
        persistNow()
    }

    /**
     * UI-test hook (`mymu.demo.stream` launch extra, DEBUG): one whole fake
     * turn pushed through the SAME inbound path real frames take — a tool
     * step, a reply streamed word by word, its final text, `complete` — so the
     * send choreography and the overflow follow can be exercised offline,
     * deterministically. Same frames and timings as iOS
     * RelayClient.simulateTurn. Only ever called on an `offline` store.
     */
    fun simulateTurn(prompt: String, reply: String, wholeBlock: Boolean = false) {
        stageOutgoing(prompt, emptyList())
        scope.launch {
            delay(900)
            injectFrame(JSONObject().put("kind", "tool_use").put("id", "sim-tu").put("toolName", "Read")
                .put("toolInput", JSONObject().put("file_path", "module/part_24.swift")))
            delay(700)
            injectFrame(JSONObject().put("kind", "tool_result").put("id", "sim-tr")
                .put("content", "Read module/part_24.swift (64 lines)"))
            delay(500)
            if (wholeBlock) {
                // The relay's shape (`mymu.demo.stream=block`): ONE text frame,
                // the next tool step right behind it — the paced-reveal stage.
                injectFrame(JSONObject().put("kind", "text").put("id", "sim-block").put("role", "assistant")
                    .put("content", reply))
                injectFrame(JSONObject().put("kind", "tool_use").put("id", "sim-tu2").put("toolName", "Bash")
                    .put("toolInput", JSONObject().put("command", "swift test --filter Part24")))
                injectFrame(JSONObject().put("kind", "complete"))
                return@launch
            }
            reply.split(" ").forEachIndexed { i, word ->
                injectFrame(JSONObject().put("kind", "stream_delta").put("content", (if (i == 0) "" else " ") + word))
                delay(45)
            }
            injectFrame(JSONObject().put("kind", "stream_end"))
            injectFrame(JSONObject().put("kind", "text").put("id", "sim-final").put("role", "assistant")
                .put("content", reply))
            injectFrame(JSONObject().put("kind", "complete"))
        }
    }

    /** One fake server frame through the real inbound handler. */
    private fun injectFrame(obj: JSONObject) = handle(obj.toString())

    /** A conversation acquired (or changed) its real session id: re-key in the
     * registry and tell the screen so Recents/reopen targets follow. */
    private fun rebind(newId: String) {
        if (newId.isEmpty()) return
        val changed = sessionId != newId
        sessionId = newId
        ConversationRegistry.register(this)
        if (changed) onSessionIdRebound?.invoke(newId)
    }

    private suspend fun uploadAttachments(attachments: List<Map<String, String>>): List<JSONObject> {
        val images = mutableListOf<ApiClient.Attachment>()
        val files = mutableListOf<ApiClient.Attachment>()
        for (a in attachments) {
            val dataUrl = a["data"] ?: continue
            val parsed = parseDataUrl(dataUrl) ?: continue
            val entry = ApiClient.Attachment(a["name"] ?: "attachment", parsed.first, parsed.second)
            if (parsed.first.startsWith("image/")) images += entry else files += entry
        }
        val api = ApiClient(token, origin)
        val records = mutableListOf<ApiClient.AssetRecord>()
        if (images.isNotEmpty()) records += api.uploadAssets(images, "images")
        if (files.isNotEmpty()) records += api.uploadAssets(files, "files")
        return records.map { r ->
            JSONObject().apply {
                put("path", r.path)
                r.name?.let { put("name", it) }
                r.mimeType?.let { put("mimeType", it) }
            }
        }
    }

    fun answerPermission(requestId: String, allow: Boolean) {
        sendJson(JSONObject().put("type", "chat.permission-response")
            .put("requestId", requestId).put("allow", allow))
        pendingPermission.value = null
    }

    fun abort() {
        finishRevealNow()
        sendJson(JSONObject().put("type", "chat.abort").put("sessionId", sessionId))
        setLoading(false)
    }

    /** Drop the server-side "user is watching this session" presence WITHOUT
     * closing the socket, so a reply finishing a moment later pushes a
     * notification instead of being suppressed. Sent on background, on
     * leaving the screen, and after every re-subscribe while unwatched.
     * (Server ≥1.37.22 honors presence.release; older servers ignore it.) */
    fun releasePresence() {
        if (ws == null) return
        sendJson(JSONObject().put("type", "presence.release"))
    }

    /**
     * Reconcile the working indicator with the server's live agent status —
     * the stream only flips isLoading when a frame ARRIVES, so opening a chat
     * whose agent is already mid-turn (quiet inside a long tool call) showed
     * no loader at all. Also the authority that CLEARS a "working" restored
     * from a snapshot when the agent is demonstrably idle.
     */
    suspend fun syncRunningState(api: ApiClient) {
        if (!isRemote || offline) return
        val status = try { api.agentStatus() } catch (_: Exception) { return }
        val mine = status.firstOrNull { it.id == sessionId } ?: return
        if (mine.running == true) {
            if (!isLoading.value) setLoading(true)
            // Turn started elsewhere (web, another device, a scheduled run) or
            // was already running on open: fetch the real start from the
            // transcript so the timer doesn't restart from zero.
            if (!turnAnchored) refreshTurnStart(api)
        } else if (isLoading.value && !awaitingFirstResponse &&
            System.currentTimeMillis() - (turnStartedAt.value ?: 0L) > 20_000) {
            // Restored "working" from a snapshot (or a missed `complete`)
            // while the agent is demonstrably idle: the status endpoint is
            // authoritative — clear the ball and fetch what we missed.
            setLoading(false)
            statusText.value = null
            reconcile()
        }
    }

    /**
     * Anchor the elapsed timer to the transcript's turn-start timestamp and
     * seed the token counter's baseline. Ignored when idle.
     */
    fun applyServerTurnStart(iso: String?, startContext: Int? = null) {
        if (!isLoading.value) return
        val date = iso?.let { parseIso(it) } ?: return
        turnStartedAt.value = date
        turnAnchored = true
        if (startContext != null) {
            turnStartContext = startContext
            context.value?.usedTokens?.let { current ->
                turnTokens.value = max(0, current - startContext)
            }
        }
    }

    /** Assistant frames carry the absolute context position; diff against the
     * turn baseline. Absolute values are replay-safe. */
    private fun noteContextTokens(tokens: Int) {
        if (tokens <= 0) return

        if (isLoading.value) {
            // Re-baseline when the anchor sits ABOVE the live reading (history
            // adds output_tokens; frames carry prompt only).
            if (turnStartContext == null || tokens < (turnStartContext ?: tokens)) {
                turnStartContext = tokens
            }
            turnTokens.value = max(0, tokens - (turnStartContext ?: tokens))
        }

        // Context genuinely goes DOWN (compaction) — the meter must follow in
        // both directions. Window preserved when known, 0 otherwise.
        context.value = ContextUsage(tokens, context.value?.windowTokens ?: 0)
    }

    /** Fetch just the turn anchor — history with limit=1 still carries turnStartedAt. */
    private suspend fun refreshTurnStart(api: ApiClient) {
        val h = try { api.history(sessionId, limit = 1) } catch (_: Exception) { return }
        h.context?.let { context.value = it }
        applyServerTurnStart(h.turnStartedAt, h.turnStartContextTokens)
    }

    // MARK: History

    fun setHistory(history: List<ChatMessage>) {
        finishRevealNow()
        val previousAnchor = activeTurnUserId.value?.let { id -> messages.value.firstOrNull { it.id == id } }
        messages.value = history
        hasLoadedOnce = hasLoadedOnce || history.isNotEmpty()
        reanchorActiveTurn(previousAnchor)
        revision.value += 1
        persistSoon()
    }

    /**
     * Adopt the history the server already has for THIS conversation on
     * open — merged, so the live tail (a message sent moments ago that the
     * server's cache hasn't caught up to) is never erased. Returns true when
     * anything visibly changed.
     */
    fun adoptHistory(h: HistoryResponse): Boolean {
        finishRevealNow()
        val merged = mergingLiveTail(messages.value, h.messages)
        val changed = ChatCacheStore.fingerprint(merged) != ChatCacheStore.fingerprint(messages.value)
        if (changed) setHistory(merged)
        hasMore.value = h.hasMore ?: hasMore.value
        hasLoadedOnce = true
        h.context?.let { context.value = it }
        // If a stream frame already flipped the loader on, anchor the timer to
        // the real turn start carried by this history fetch.
        applyServerTurnStart(h.turnStartedAt, h.turnStartContextTokens)
        persistNow()
        return changed
    }

    /** The active-turn anchor must survive id rebinds: the echo and the
     * history merge both replace the optimistic "local-…" row by its server
     * copy. Re-point at the server copy (same typed text), else at the newest
     * user message, else drop the anchor. */
    private fun reanchorActiveTurn(previous: ChatMessage?) {
        val id = activeTurnUserId.value ?: return
        val list = messages.value
        if (list.any { it.id == id }) return
        if (previous != null) {
            val typed = typedText(previous)
            val twin = list.lastOrNull { m ->
                m.role == "user" && m.kind == "text" && (typedText(m) == typed
                    || (m.content ?: "").trim().startsWith(typed + "\n"))
            }
            if (twin != null) {
                activeTurnUserId.value = twin.id
                return
            }
        }
        activeTurnUserId.value = list.lastOrNull { it.role == "user" && it.kind == "text" }?.id
    }

    /** Prepend an older page. UNLIKE iOS this must bump `revision`: the
     * Android chat renders from revision-gated snapshots, so without a bump
     * the older page never appears at all. The reading position still holds —
     * load-earlier is only reachable after an upward drag (follow-mode off,
     * so the bump cannot scroll to bottom) and the LazyColumn re-anchors by
     * item key across the insertion. */
    fun prependHistory(older: List<ChatMessage>) {
        if (older.isEmpty()) return
        messages.value = older + messages.value
        revision.value += 1
    }

    /** Re-fetch the authoritative transcript and MERGE it in. Only when idle,
     * so an in-progress streaming turn is never wiped mid-flight. Visually
     * idempotent: nothing is swapped unless the server really has something
     * new. */
    private fun reconcile() {
        if (offline || isLoading.value || sessionId.isEmpty() || reconcileInFlight) return
        reconcileInFlight = true
        syncing.value = true
        scope.launch {
            try {
                val h = try { ApiClient(token, origin).history(sessionId) } catch (_: Exception) { null }
                // A turn may have started meanwhile — never disturb it.
                if (h != null && !isLoading.value) adoptHistory(h)
            } finally {
                reconcileInFlight = false
                syncing.value = false
            }
        }
    }

    /** Unconditional history refetch — unlike `reconcile()` this ignores
     * `isLoading`. Safe to call anytime: `mergingLiveTail` already protects
     * any live tail the fetch doesn't know about yet, and trusts the fetch
     * wholesale when the transcript legitimately restarted. */
    suspend fun forceReconcile() {
        if (offline) return
        val h = try { ApiClient(token, origin).history(sessionId) } catch (_: Exception) { return }
        adoptHistory(h)
    }

    private fun scheduleReconcile() {
        scope.launch {
            delay(700)
            reconcile()
        }
    }

    // MARK: Inbound

    private fun handle(text: String) {
        val obj = try { JSONObject(text) } catch (_: Exception) { return }

        val type = obj.stringOrNull("type")
        val kind = obj.stringOrNull("kind")

        // A paced reveal is running: everything after it waits its turn, so
        // a tool row or the turn's end never lands above half-shown text.
        if (reveal != null) {
            held.add(HeldFrame(text, kind == "text" && obj.stringOrNull("role") != "user"))
            return
        }

        // Any non-delta frame must observe the fully-applied stream so ordering
        // holds (e.g. stream_end / tool_use arriving between coalesced flushes).
        if (kind != "stream_delta") {
            chunkFlushJob?.cancel()
            chunkFlushJob = null
            flushStreamChunk()
        }

        if (type == "session-status") {
            obj.boolOrNull("isProcessing")?.let { setLoading(it) }
            (obj.optJSONObject("status"))?.stringOrNull("text")?.let { statusText.value = it }
            return
        }

        // Live token counter: assistant frames carry the absolute context position.
        obj.intOrNull("contextTokens")?.let { noteContextTokens(it) }

        // Remember the high-water seq so the next chat.subscribe replays only
        // what we actually missed.
        obj.intOrNull("seq")?.let { lastSeq = max(lastSeq, it) }

        when (kind) {
            "chat_subscribed" -> {
                // Upstream's subscribe ack: authoritative running/pending snapshot.
                obj.boolOrNull("isProcessing")?.let { processing ->
                    if (processing) setLoading(true)
                    // A just-sent turn can't have finished before its first frame.
                    else if (!awaitingFirstResponse) setLoading(false)
                }
                val pending = obj.optJSONArray("pendingPermissions")
                val first = pending?.optJSONObject(0)
                val requestId = first?.stringOrNull("requestId")
                if (first != null && requestId != null) {
                    pendingPermission.value = ChatMessage(
                        id = first.stringOrNull("id") ?: "perm-${nextSeq()}",
                        kind = "permission_request", role = "assistant",
                        toolName = first.stringOrNull("toolName"),
                        requestId = requestId)
                }
                return
            }
            "session_upserted", "loading_progress" -> return
            "protocol_error" -> {
                streamingId = null
                Haptics.error()
                appendOrReplace(ChatMessage(id = messageId(obj), kind = "error", role = "assistant",
                    content = obj.stringOrNull("message") ?: "Server rejected the request.",
                    isError = true))
                setLoading(false)
                return
            }
        }

        // A prompt answered from ANOTHER client (web tab, terminal, second phone)
        // has no server event of its own — the harness blocks the turn on an
        // unanswered prompt, so any assistant content past it, or the turn
        // ending, proves it was answered. Retire the banner. (A replayed
        // permission_request is the newest frame in the buffer and re-arms it.)
        if (pendingPermission.value != null && resolvesPendingPermission(kind, obj.stringOrNull("role"))) {
            pendingPermission.value = null
        }

        when (kind) {
            "stream_delta" -> {
                // Replayed deltas (every re-subscribe re-flushes the turn) are
                // absorbed against what's already here; only new text streams.
                val fresh = absorb(obj.stringOrNull("content") ?: "")
                if (fresh.isNullOrEmpty()) return
                pendingPermission.value = null  // new text past the prompt
                noteResponseActivity()
                appendStream(fresh)
                setLoading(true)
            }
            "stream_end" -> {
                // The block's final `text` frame follows and finalizes the bubble
                // in place — keep the bubble addressable until then.
            }
            "text" -> handleTextFrame(obj)
            "tool_use" -> {
                noteResponseActivity()
                appendOrReplace(ChatMessage(id = messageId(obj), kind = "tool_use", role = "assistant",
                    toolName = obj.stringOrNull("toolName"), toolInput = obj.anyOrNull("toolInput")))
            }
            "tool_result" -> {
                appendOrReplace(ChatMessage(id = messageId(obj), kind = "tool_result", role = "assistant",
                    content = obj.stringOrNull("content"), isError = obj.boolOrNull("isError")))
            }
            "thinking" -> {
                // For a REASONING model this is the bulk of a turn — keep it;
                // the chat renders it muted.
                noteResponseActivity()
                appendOrReplace(ChatMessage(id = messageId(obj), kind = "thinking", role = "assistant",
                    content = obj.stringOrNull("content") ?: obj.stringOrNull("text")))
            }
            "status" -> {
                // A `token_budget` status frame carries a usage payload, NOT a
                // human status label — swallow it.
                if (obj.stringOrNull("text") == "token_budget") return
                statusText.value = obj.stringOrNull("text")
                setLoading(true)
            }
            "permission_request" -> {
                Haptics.attention()
                pendingPermission.value = ChatMessage(id = messageId(obj), kind = "permission_request",
                    role = "assistant", toolName = obj.stringOrNull("toolName"),
                    requestId = obj.stringOrNull("requestId"))
            }
            "session_created" -> {
                // A new local conversation gets its real id at turn start —
                // rebind so resumes and history reads target the actual session.
                if (!isRemote) {
                    val newId = obj.stringOrNull("newSessionId") ?: obj.stringOrNull("sessionId")
                    if (!newId.isNullOrEmpty()) rebind(newId)
                }
            }
            "permission_cancelled" -> pendingPermission.value = null
            "error" -> {
                streamingId = null
                Haptics.error()
                appendOrReplace(ChatMessage(id = messageId(obj), kind = "error", role = "assistant",
                    content = obj.stringOrNull("content"), isError = true))
                setLoading(false)
            }
            "complete" -> {
                streamingId = null
                if (isLoading.value) Haptics.complete()
                setLoading(false)
                statusText.value = null
                // Turn over — the queued marker must not outlive the run.
                if (messages.value.any { it.queued == true }) {
                    messages.value = messages.value.map { if (it.queued == true) it.copy(queued = null) else it }
                }
                persistNow()
                scheduleReconcile()
                // Nobody is watching: the socket has done its job for this turn.
                if (!isVisible) scheduleGraceDisconnect()
            }
        }
    }

    /** Frames that can only arrive once a pending permission prompt has been
     * answered (the harness blocks the turn on it): assistant content and the
     * turn's end. `stream_delta` is judged at its fresh-text branch so an
     * absorbed replay doesn't count. Status/snapshot frames never qualify. */
    private fun resolvesPendingPermission(kind: String?, role: String?): Boolean = when (kind) {
        "tool_use", "tool_result", "thinking", "complete", "error" -> true
        "text" -> role != "user"
        else -> false
    }

    /** The `text` frame: a user echo rebinds the optimistic bubble; an
     * assistant final FINALIZES the streaming bubble in place; anything else
     * appends by id. */
    private fun handleTextFrame(obj: JSONObject) {
        val role = obj.stringOrNull("role") ?: "assistant"
        if (role == "assistant") noteResponseActivity()
        val body = obj.stringOrNull("displayText") ?: obj.stringOrNull("content") ?: ""
        if (body.isEmpty()) { streamingId = null; return }
        val list = messages.value
        // The relay echoes the user's own message back. If we already showed
        // it optimistically (id "local-…"), reconcile that bubble to the
        // server id instead of appending a duplicate. Matching must be FUZZY
        // in both directions: the local bubble may carry "📎 name" chip lines
        // the echo lacks, and the echo may carry server-side attachment
        // decoration the bubble lacks — a missed match here appended the echo
        // BELOW the already-streaming response (2026-10-18 ordering bug).
        val echoIdx = if (role == "user") list.indexOfFirst { m ->
            if (!m.id.startsWith("local-") || m.role != "user") return@indexOfFirst false
            val c = m.content ?: ""
            val typed = typedText(m)
            val b = body.trim()
            if (c == body || typed == b) return@indexOfFirst true
            if (typed.isNotEmpty() && b.startsWith(typed + "\n")) return@indexOfFirst true
            if (b.isEmpty() && c.startsWith("📎")) return@indexOfFirst true
            // Attachment-only send: the echo is all decoration.
            typed.isEmpty() && b.isNotEmpty()
        } else -1
        if (echoIdx >= 0) {
            val serverId = messageId(obj)
            if (activeTurnUserId.value == list[echoIdx].id) activeTurnUserId.value = serverId
            val next = list.toMutableList()
            // The relay echoed it back — it left the queue.
            next[echoIdx] = next[echoIdx].copy(id = serverId, queued = null)
            messages.value = next
            revision.value += 1
            persistSoon()
            return
        }
        val sid = streamingId
        val streamIdx = if (role != "user" && sid != null) list.indexOfFirst { it.id == sid } else -1
        if (streamIdx >= 0 && sameBlock(list[streamIdx].content ?: "", body)) {
            // The final text for the bubble that just streamed: FINALIZE it in
            // place (same row, server id, authoritative body) — a separate
            // final row beside the stream bubble was the duplicate the
            // end-of-turn reconcile used to mop up, and on a replay it was the
            // duplicate nothing mopped up.
            val serverId = messageId(obj)
            streamingId = null
            val next = list.toMutableList()
            if (list.any { it.id == serverId }) {
                // Already have the final (replayed stream) — the temporary
                // bubble is the duplicate.
                next.removeAt(streamIdx)
            } else {
                val row = next[streamIdx]
                next[streamIdx] = row.copy(id = serverId, content = body,
                    timestamp = row.timestamp ?: obj.stringOrNull("timestamp"))
            }
            messages.value = next
            revision.value += 1
            persistSoon()
            return
        }
        streamingId = null
        // A user message we did not send (turn started on another client) is
        // a new turn too — the rows queued for absorption belong to the one
        // before it.
        val id = messageId(obj)
        if (role == "user" && list.none { it.id == id }) disarmReplayAbsorption()
        if (role != "user" && shouldPace(id, body)) {
            startReveal(id, body, obj.stringOrNull("timestamp"))
        } else {
            appendOrReplace(ChatMessage(id = id, kind = "text", role = role, content = body))
        }
    }

    // MARK: replay absorption

    /**
     * The server re-flushes the current turn's frame buffer on every
     * (re)subscribe — the 45s keepalive and the foreground kick (a send's
     * own attach replays nothing: the buffer is emptied at turn end). Id'd
     * frames collapse by id; stream deltas carry NO id, so they are matched,
     * in order, as a running PREFIX of the turn's assistant text rows. Only
     * text past what's already on screen is new.
     *
     * Divergence is NOT assumed to be a replay: a live reply that merely
     * starts with the same words as the row it is compared to is swallowed
     * only until it differs, and the swallowed prefix is restored then. A
     * reply identical to an entire earlier row is repaired by its final
     * `text` frame (appended by id). The worst case is a missed streaming
     * animation, never lost or duplicated text.
     */
    private fun armReplayAbsorption() {
        finishRevealNow()
        flushStreamChunk()
        absorbCursor = 0
        absorbed = ""
        // The current turn's assistant text rows: everything after the last
        // user message, in order.
        val list = messages.value
        val turnStart = list.indexOfLast { it.role == "user" && it.kind == "text" } + 1
        absorbQueue = list.drop(turnStart)
            .filter { it.kind == "text" && it.role != "user" }
            .map { it.id }
            .toMutableList()
    }

    /** A new turn began (our send, or another client's user message landed):
     * whatever was queued for absorption is the previous turn's reply and
     * must not eat the live stream. The next (re)subscribe re-arms. */
    private fun disarmReplayAbsorption() {
        absorbQueue = mutableListOf(); absorbCursor = 0; absorbed = ""
    }

    /** null = fully replayed (drop); otherwise the part of `chunk` that is new. */
    private fun absorb(chunk: String): String? {
        if (chunk.isEmpty()) return null
        while (absorbQueue.isNotEmpty()) {
            val tid = absorbQueue.first()
            val row = messages.value.firstOrNull { it.id == tid }
            if (row == null) {
                absorbQueue.removeAt(0); absorbCursor = 0; absorbed = ""
                continue
            }
            val content = row.content ?: ""
            val remaining = if (absorbCursor < content.length) content.substring(absorbCursor) else ""
            if (remaining.isEmpty()) {
                // This row fully re-covered — on to the next one. A row we were
                // streaming ourselves (necessarily the last) continues in place.
                absorbQueue.removeAt(0); absorbCursor = 0; absorbed = ""
                if (absorbQueue.isEmpty() && tid.startsWith("stream-")) streamingId = tid
                continue
            }
            if (remaining.startsWith(chunk)) {
                absorbCursor += chunk.length
                absorbed += chunk
                return null
            }
            if (chunk.startsWith(remaining)) {
                // Runs past this row: the excess continues our own stream
                // bubble, or starts a new row after a finalized one.
                val excess = chunk.substring(remaining.length)
                absorbQueue.removeAt(0); absorbCursor = 0; absorbed = ""
                if (absorbQueue.isEmpty() && tid.startsWith("stream-")) streamingId = tid
                return absorb(excess)
            }
            // Divergent: not a replay of this row — it's live text. Give back
            // whatever was provisionally swallowed against this row.
            val restored = absorbed + chunk
            absorbQueue = mutableListOf(); absorbCursor = 0; absorbed = ""
            return restored
        }
        return chunk
    }

    // MARK: paced reveal

    /*
     * Fleet agents reach the phone through the remote-control relay, which
     * sends a finished text block as ONE frame — no token deltas exist for
     * them (measured 2026-10-30: 0 deltas in 4649 events; blocks up to ~3k
     * chars). Dropped in whole, a reply "spits out at once" (Manar). So a NEW
     * assistant prose block that arrives LIVE while the chat is on screen is
     * revealed at reading pace, word by word: a growing bubble (born
     * "reveal-N"), finalized in place under the server id with the
     * authoritative body. Frames that arrive meanwhile are held and replayed
     * in order afterwards. History, replays and anything already on screen
     * render instantly as before. Same rules and numbers as iOS
     * RelayClient (paced reveal).
     */
    private class Reveal(val rowId: String, val serverId: String, val body: String,
                         val timestamp: String?, var shown: Int)
    private class HeldFrame(val raw: String, val prose: Boolean)
    private var reveal: Reveal? = null
    private var revealJob: Job? = null
    /** Raw frames that arrived during a reveal, in arrival order. */
    private val held = ArrayDeque<HeldFrame>()
    /** Draining the backlog after a forced finish: show it all instantly. */
    private var pacingSuspended = false

    private fun shouldPace(id: String, body: String): Boolean =
        !pacingSuspended && isVisible && body.length >= REVEAL_MIN_CHARS &&
            messages.value.none { it.id == id }

    private fun startReveal(id: String, body: String, timestamp: String?) {
        val rowId = "reveal-${nextSeq()}"
        val first = wordBoundary(body, 1)
        val r = Reveal(rowId, id, body, timestamp, first)
        reveal = r
        // The first words take the pending ball's place, same as a streamed
        // reply's first chunk.
        messages.value = messages.value + ChatMessage(id = rowId, clientId = rowId, kind = "text",
            role = "assistant", content = body.take(first), timestamp = timestamp ?: Instant.now().toString())
        revision.value += 1
        UiTestHooks.trace("reveal:$first")
        val duration = (body.length / REVEAL_CHARS_PER_SECOND).coerceIn(REVEAL_MIN_S, REVEAL_MAX_S)
        val start = System.nanoTime()
        revealJob = scope.launch {
            while (true) {
                delay(REVEAL_TICK_MS)
                if (reveal !== r) return@launch
                // Another prose block is already waiting: catch up fast.
                val budget = if (held.any { it.prose }) minOf(duration, 0.15) else duration
                val progress = minOf(1.0, (System.nanoTime() - start) / 1e9 / budget)
                val target = wordBoundary(body, (body.length * progress).toInt())
                if (target >= body.length) { completeReveal(); return@launch }
                if (target <= r.shown) continue
                val list = messages.value
                val idx = list.indexOfFirst { it.id == rowId }
                if (idx < 0) continue
                r.shown = target
                messages.value = list.toMutableList().also { it[idx] = it[idx].copy(content = body.take(target)) }
                revision.value += 1
                UiTestHooks.trace("reveal:$target")
            }
        }
    }

    /** The bubble becomes the real message (server id, full body), then the
     * held frames run in order — one of them may start the next reveal. */
    private fun completeReveal() {
        val r = reveal ?: return
        reveal = null
        val job = revealJob
        revealJob = null
        val list = messages.value
        val idx = list.indexOfFirst { it.id == r.rowId }
        if (idx >= 0) {
            messages.value = list.toMutableList().also {
                it[idx] = it[idx].copy(id = r.serverId, content = r.body,
                    timestamp = r.timestamp ?: it[idx].timestamp)
            }
        }
        revision.value += 1
        UiTestHooks.trace("reveal:${r.body.length}")
        persistSoon()
        while (reveal == null && held.isNotEmpty()) handle(held.removeFirst().raw)
        // Last: cancelling the job we may be running inside must not cut the
        // drain short.
        job?.cancel()
    }

    /** Show everything now: the screen left, the user sent, history is about
     * to be merged, or the server is re-flushing the turn. */
    fun finishRevealNow() {
        if (reveal == null) return
        pacingSuspended = true
        try { while (reveal != null) completeReveal() } finally { pacingSuspended = false }
    }

    /** The transcript as it should be stored: a reveal in flight is saved
     * whole under its server id, never half-shown under a temporary one. */
    private fun persistableMessages(): List<ChatMessage> {
        val r = reveal ?: return messages.value
        val list = messages.value
        val idx = list.indexOfFirst { it.id == r.rowId }
        if (idx < 0) return list
        return list.toMutableList().also { it[idx] = it[idx].copy(id = r.serverId, content = r.body) }
    }

    // MARK: helpers

    // Stream chunks arrive per-token; publishing on each one forces a full
    // recompose per token. Coalesce to ~12 UI updates/second; `handle` flushes
    // synchronously before any non-delta frame so ordering is preserved.
    private fun appendStream(chunk: String) {
        pendingChunk += chunk
        if (chunkFlushJob != null) return
        chunkFlushJob = scope.launch {
            delay(80)
            chunkFlushJob = null
            flushStreamChunk()
        }
    }

    private fun flushStreamChunk() {
        if (pendingChunk.isEmpty()) return
        val chunk = pendingChunk
        pendingChunk = ""
        val list = messages.value
        val sid = streamingId
        val idx = if (sid != null) list.indexOfFirst { it.id == sid } else -1
        if (idx >= 0) {
            val next = list.toMutableList()
            next[idx] = next[idx].copy(content = (next[idx].content ?: "") + chunk)
            messages.value = next
        } else {
            val id = "stream-${nextSeq()}"
            streamingId = id
            // The first text of a reply takes the pending ball's place — the
            // ball dissolves into the text (ChatGPT feel).
            messages.value = list + ChatMessage(id = id, clientId = id, kind = "text", role = "assistant",
                content = chunk, timestamp = Instant.now().toString())
        }
        revision.value += 1
        persistSoon()
    }

    private fun appendOrReplace(m: ChatMessage) {
        var msg = m
        val list = messages.value
        val idx = list.indexOfFirst { it.id == msg.id }
        messages.value = if (idx >= 0) {
            // A replacement frame without its own stamp keeps the original's —
            // an echo must not erase when the message was actually sent.
            if (msg.timestamp == null) msg = msg.copy(timestamp = list[idx].timestamp)
            list.toMutableList().also { it[idx] = msg }
        } else {
            // Live frames don't always carry a transcript timestamp; they DO
            // arrive in real time, so "now" is the truth for display.
            if (msg.timestamp == null) msg = msg.copy(timestamp = Instant.now().toString())
            UiTestHooks.trace("row:${msg.kind}:${msg.toolName ?: ""}")
            list + msg
        }
        revision.value += 1
        persistSoon()
    }

    private fun messageId(obj: JSONObject): String =
        obj.stringOrNull("id") ?: "srv-${nextSeq()}"

    private fun nextSeq(): Int { seq += 1; return seq }

    private fun sendJson(dict: JSONObject, retryOnce: Boolean = false) {
        val str = dict.toString()
        val socket = ws
        val ok = socket?.send(str) ?: false
        if (!ok && retryOnce) {
            // Dead socket (backgrounding kills them): reopen and resend once so
            // the message the user already sees as sent actually goes out.
            scope.launch {
                if (ws === socket) ws = null
                openSocket()
                delay(700)
                ws?.send(str)
            }
        }
    }

    companion object {
        /** Reading pace and its bounds (iOS RelayClient.reveal*): ~600 chars/s
         * reads as fast typing; the cap keeps a 3k-char block from holding
         * the turn back for long. Shorter than REVEAL_MIN_CHARS shows whole. */
        const val REVEAL_CHARS_PER_SECOND = 600.0
        const val REVEAL_MIN_S = 0.35
        const val REVEAL_MAX_S = 1.8
        const val REVEAL_TICK_MS = 40L
        const val REVEAL_MIN_CHARS = 40

        /** The first word end at or after [n] characters (whole words only,
         * so a half word never flashes). */
        fun wordBoundary(s: String, n: Int): Int {
            if (n >= s.length) return s.length
            var i = maxOf(n, 0)
            while (i < s.length && !s[i].isWhitespace()) i++
            return i
        }

        /** "data:<mime>;base64,<payload>" → (mime, bytes). */
        fun parseDataUrl(dataUrl: String): Pair<String, ByteArray>? {
            if (!dataUrl.startsWith("data:")) return null
            val comma = dataUrl.indexOf(',')
            if (comma < 0) return null
            val header = dataUrl.substring(5, comma)
            val mime = header.split(";").firstOrNull() ?: ""
            val bytes = try {
                android.util.Base64.decode(dataUrl.substring(comma + 1), android.util.Base64.DEFAULT)
            } catch (_: Exception) { return null }
            return (mime.ifEmpty { "application/octet-stream" }) to bytes
        }

        /** Relay timestamps carry microsecond fractions ISO parsers may reject —
         * drop the fraction (second precision is plenty). Returns epoch ms. */
        fun parseIso(s: String): Long? {
            val cleaned = s.replace(Regex("\\.\\d+"), "")
            return try { Instant.parse(cleaned).toEpochMilli() } catch (_: Exception) { null }
        }

        /** The text the user actually TYPED: the optimistic bubble appends
         * non-image attachments as "📎 name" lines that exist nowhere server-side. */
        fun typedText(m: ChatMessage): String =
            (m.content ?: "").split("\n").filter { !it.startsWith("📎 ") }.joinToString("\n").trim()

        private fun bodyKey(m: ChatMessage): String = "${m.role}|${m.kind}|${(m.content ?: "").trim()}"

        /** A final `text` frame belongs to the bubble we streamed when one is a
         * prefix of the other (the stream may have been cut short, or the final
         * may carry a trimmed body). A replayed EARLIER block's final must not
         * hijack the bubble of the block currently streaming. */
        fun sameBlock(bubble: String, final: String): Boolean {
            val b = bubble.trim()
            val f = final.trim()
            if (b.isEmpty() || f.isEmpty()) return false
            return f.startsWith(b) || b.startsWith(f)
        }

        /**
         * Replace the transcript with a fetched history WITHOUT letting a stale
         * fetch erase messages already on screen. The server pages agent
         * transcripts from a relay-events cache whose top-up fails SILENTLY —
         * history then comes back missing the newest turn, and a blind replace
         * wiped a message the user had just sent (field bug 2026-09-27). Keep
         * any live tail the fetch doesn't know about; the next fresh fetch
         * converges naturally.
         */
        fun mergingLiveTail(live: List<ChatMessage>, fetched: List<ChatMessage>): List<ChatMessage> {
            if (live.isEmpty()) return fetched
            val fetchedIds = fetched.map { it.id }.toSet()
            // Anchor: the LAST live message the fetch also has. No overlap at all
            // means the transcript legitimately restarted (/clear, compaction) —
            // trust the fetch wholesale rather than resurrecting an old view.
            val anchor = live.indexOfLast { it.id in fetchedIds }
            if (anchor < 0) return fetched
            // Rows the fetch shares BY ID keep the identity they were born
            // with: the echo rebinds the optimistic bubble to its server id
            // (clientId kept), so the fetch's copy is the same row — without
            // this carry the active-turn box (keyed by clientId) was rebuilt
            // whenever the sent bubble sat at or before the anchor.
            val cidById = live.mapNotNull { m -> m.clientId?.let { m.id to it } }.toMap()
            val tail = live.drop(anchor + 1)
            if (tail.isEmpty()) return carryById(fetched, cidById)
            // Content-level dedupe: a locally-streamed bubble ("stream-N") and the
            // fetch's final text are the same message under different ids.
            val fetchedBodies = fetched.map(::bodyKey).toSet()
            // User bubbles need a FUZZY pass on top: the optimistic bubble renders
            // attachments as trailing "📎 name" lines and the server stores its own
            // normalization, so exact-body dedupe can miss — and the stale bubble
            // then re-appended BELOW the agent's response (field bug 2026-10-18).
            // Compare the typed text against the fetch's post-anchor USER
            // messages instead; a decorated server copy still matches by prefix.
            val anchorIdx = fetched.indexOfFirst { it.id == live[anchor].id }.let { if (it < 0) fetched.size - 1 else it }
            val fetchedUserTexts = fetched.drop(anchorIdx).filter { it.role == "user" }
                .map { (it.content ?: "").trim() }
            val missing = tail.filter { m ->
                if (bodyKey(m) in fetchedBodies) return@filter false
                if (m.role == "user" && m.kind == "text" && m.queued != true) {
                    val typed = typedText(m)
                    if (typed.isEmpty()) {
                        // Attachment-only send: any post-anchor user message in the
                        // fetch means the server recorded it in its own format.
                        return@filter fetchedUserTexts.isEmpty()
                    }
                    if (fetchedUserTexts.any { it == typed || it.startsWith(typed + "\n") }) {
                        return@filter false
                    }
                }
                true
            }
            // The fetch's post-anchor rows that REPLACE a live row (the user
            // bubble by its typed text, the streamed bubble by its body) keep
            // that row's clientId: to the screen this is an id rebind — the row
            // must not replay its insertion transition, and the active-turn
            // box (keyed by the bubble's birth id) must not be rebuilt. Without
            // it the sent bubble and the reply flew in a second time when the
            // end-of-turn reconcile landed (emulator pass 2026-10-24).
            // Each identity goes to ONE row (iOS e0528a4). Bodies repeat — a Stop
            // hook posts the identical "Stop says: …" every turn, users type
            // "yes" twice — and handing one clientId to every match gave many
            // rows the same birth id. Id matches first; fuzzy matches
            // newest-first, since the rows born here are the recent ones.
            val tailByBody = tail.filter { it.clientId != null }.associateBy(::bodyKey)
            val tailUsers = tail.filter { it.clientId != null && it.role == "user" && it.kind == "text" }
            val adopted = carryById(fetched, cidById).toMutableList()
            val used = (adopted.mapNotNull { it.clientId } + missing.mapNotNull { it.clientId }).toMutableSet()
            for (i in adopted.indices.reversed()) {
                val f = adopted[i]
                if (i <= anchorIdx || f.clientId != null) continue
                val twin = tailByBody[bodyKey(f)] ?: if (f.role == "user" && f.kind == "text") {
                    val body = (f.content ?: "").trim()
                    tailUsers.firstOrNull { l ->
                        val typed = typedText(l)
                        typed.isNotEmpty() && (body == typed || body.startsWith(typed + "\n"))
                    }
                } else null
                val cid = twin?.clientId ?: continue
                if (used.add(cid)) adopted[i] = f.copy(clientId = cid)
            }
            return if (missing.isEmpty()) adopted else adopted + missing
        }

        private fun carryById(fetched: List<ChatMessage>, cidById: Map<String, String>): List<ChatMessage> =
            if (cidById.isEmpty()) fetched
            else {
                val used = fetched.mapNotNull { it.clientId }.toMutableSet()
                fetched.map { f ->
                    if (f.clientId != null) f
                    else cidById[f.id]?.takeIf { used.add(it) }?.let { f.copy(clientId = it) } ?: f
                }
            }
    }
}
