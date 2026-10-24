import Foundation
import SwiftUI

/// The per-conversation STORE: the transcript, the turn state, and the live
/// socket for one session on one host. Owned by `ConversationRegistry` (not
/// by the chat view), so it outlives the screen that shows it — the chat is
/// local-first: what the user sees is the truth the app already holds, the
/// server only ever CONTINUES it (Manar, 2026-10-24).
///
/// Three rules keep it honest:
///  1. Every mutation is persisted (debounced) — a re-open renders the exact
///     state that was left, sent message, half-streamed reply, pulsing ball.
///  2. Inbound frames are idempotent. The server re-flushes the current
///     turn's frame buffer on every (re)subscribe — id'd frames dedupe by id,
///     id-less stream deltas are ABSORBED as a running prefix of the newest
///     assistant row, and the final `text` frame finalizes the streaming
///     bubble in place rather than sitting beside it.
///  3. A history fetch is a MERGE, never a replace: `mergingLiveTail` keeps
///     what the server hasn't caught up to; the swap is fingerprint-gated and
///     animated, so a quiet reconcile paints nothing.
@MainActor
final class RelayClient: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isLoading = false {
        didSet {
            // Date() is only a provisional anchor — the real turn start (the user
            // prompt's transcript timestamp) replaces it via applyServerTurnStart,
            // so reopening a mid-turn conversation shows true elapsed, not zero.
            if isLoading && !oldValue {
                turnStartedAt = Date(); turnAnchored = false
                // Baseline for the token counter: the last known context position.
                turnStartContext = context?.usedTokens
                turnTokens = nil
            }
            if !isLoading { turnStartedAt = nil; turnAnchored = false; turnStartContext = nil; turnTokens = nil }
            if isLoading != oldValue { persistSoon() }
        }
    }
    /// When the current turn started — drives the elapsed timer on the loader.
    @Published var turnStartedAt: Date?
    /// Tokens the context grew since the turn started ("tokens this turn"),
    /// ticking live off assistant frames' absolute contextTokens field.
    @Published var turnTokens: Int?
    private var turnStartContext: Int?
    /// True once turnStartedAt holds the REAL turn start (local send or server
    /// transcript timestamp) rather than the provisional "when I noticed" stamp.
    private var turnAnchored = false
    /// Armed by send(); the first response frame fires the reply haptic.
    private var awaitingFirstResponse = false

    private func noteResponseActivity() {
        if awaitingFirstResponse { awaitingFirstResponse = false; Haptics.firstResponse() }
    }
    @Published var statusText: String?
    @Published var connected = false
    @Published var pendingPermission: ChatMessage?
    /// Bumped on EVERY content mutation (new message, stream chunk, history swap).
    /// The view follows this — messages.count misses stream growth inside one message.
    @Published var revision = 0
    /// Context-window fullness from the last history fetch (nil until known).
    @Published var context: ContextUsage?
    /// A history reconcile is in flight. Surfaced as a small honest signal in
    /// the status strip — never as a loader over content the user can read.
    @Published var syncing = false
    /// The user message that opened the turn FROM THIS DEVICE. The chat keeps
    /// that row at the top of the viewport for the whole turn (the ChatGPT
    /// "message goes to the top, reply streams under it" geometry). Survives
    /// Back/re-open because the client does; restored from the snapshot when
    /// the turn is still running after a cold start.
    @Published var activeTurnUserId: String?
    /// Older messages exist beyond the loaded page (from the last fetch).
    @Published var hasMore: Bool?
    /// Off for the offline demo: canned transcripts must not be written into
    /// the real cache.
    var persistenceEnabled = true
    /// A transcript has been established — seeded from a snapshot or fetched
    /// once. The view skips the blocking open path when this is already true.
    private(set) var hasLoadedOnce = false

    private(set) var token: String
    /// Host this conversation talks to (agent→host pinning); nil = active host.
    /// The pinned host lands file attachments on the agent's own disk — the
    /// relay mirrors the turn to every attached host, so viewing works anywhere
    /// but SENDING must hit the agent's machine.
    let origin: String?
    private(set) var sessionId: String
    /// Fired when a NEW local conversation is assigned its real id mid-turn
    /// (`session_created`). The view uses it to propagate the id outward —
    /// into Recents and the reopen target — so closing and reopening the
    /// conversation resolves to the real session instead of the empty draft id
    /// (which would fetch no history and render blank).
    var onSessionIdRebound: ((String) -> Void)?
    let isRemote: Bool
    /// Remote agent sessions accept messages MID-TURN (the relay routes them
    /// through the agent's native queue) — the composer uses this to allow
    /// queueing while the agent is working.
    var supportsMidTurnSend: Bool { isRemote }
    private let projectPath: String?
    private var task: URLSessionWebSocketTask?
    private var keepAlive: Task<Void, Never>?
    private var streamingId: String?
    private var seq = 0
    private var reconnectAttempts = 0
    private var intentionalClose = false
    /// Highest `seq` seen from the server — chat.subscribe replays everything
    /// after this, closing gaps from drops/backgrounding.
    private var lastSeq = 0

    // MARK: visibility / lifecycle owned by the registry

    /// A chat screen is showing this conversation right now.
    private(set) var isVisible = false
    private var graceDisconnect: Task<Void, Never>?
    /// Idle and unwatched: the socket goes after this (a quick tab-out-and-
    /// back never reconnects).
    private let idleGrace: TimeInterval = 15
    /// Unwatched but mid-turn: the socket stays so the reply keeps landing in
    /// the store — bounded, so a hung agent can't pin a socket forever.
    private let busyGrace: TimeInterval = 20 * 60

    init(token: String, sessionId: String, isRemote: Bool, projectPath: String? = nil, origin: String? = nil,
         seed: ChatCacheStore.Snapshot? = nil) {
        self.token = token
        self.sessionId = sessionId
        self.isRemote = isRemote
        self.projectPath = projectPath
        self.origin = origin
        if let seed { adoptSnapshot(seed) }
    }

    /// Warm start: the FIRST rendered frame carries the transcript — and the
    /// turn exactly as it was left, if the snapshot says it was still running
    /// recently. Used by init (RAM hit) and by the view's disk fallback.
    func adoptSnapshot(_ seed: ChatCacheStore.Snapshot) {
        guard !seed.messages.isEmpty else { return }
        messages = seed.messages
        context = seed.context
        hasMore = seed.hasMore
        hasLoadedOnce = true
        if let turn = seed.turn {
            lastSeq = max(lastSeq, turn.lastSeq)
            if turn.isLoadingFresh, !isLoading {
                isLoading = true
                if let iso = turn.startedAt, let d = Self.parseISO(iso) {
                    turnStartedAt = d; turnAnchored = true
                }
                activeTurnUserId = turn.activeTurnUserId
            }
        }
        revision += 1
    }

    /// Account re-login can rotate the token under a long-lived client.
    func updateToken(_ new: String) {
        guard new != token else { return }
        token = new
        if task != nil { disconnect(); connect() }
    }

    func viewAppeared() {
        isVisible = true
        graceDisconnect?.cancel(); graceDisconnect = nil
    }

    /// The screen left. Keep the transcript (and the socket while a turn is
    /// running) — see ConversationRegistry. Presence is released at once so a
    /// reply finishing while unwatched pushes a notification.
    func viewDisappeared() {
        isVisible = false
        persistNow()
        releasePresence()
        scheduleGraceDisconnect()
    }

    private func scheduleGraceDisconnect() {
        graceDisconnect?.cancel()
        guard task != nil else { return }
        let delay = isLoading ? busyGrace : idleGrace
        graceDisconnect = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isVisible else { return }
            self.persistNow()
            self.disconnect()
        }
    }

    // MARK: persistence

    private var persistTask: Task<Void, Never>?

    private var turnState: ChatCacheStore.TurnState {
        ChatCacheStore.TurnState(isLoading: isLoading,
                                 startedAt: turnStartedAt.map { ISO8601DateFormatter().string(from: $0) },
                                 activeTurnUserId: activeTurnUserId,
                                 lastSeq: lastSeq,
                                 savedAt: ISO8601DateFormatter().string(from: Date()))
    }

    /// Debounced snapshot write — stream chunks coalesce into one write per
    /// ~third of a second; the store skips the write when nothing changed.
    func persistSoon() {
        guard isRemote, persistenceEnabled, !sessionId.isEmpty else { return }
        guard persistTask == nil else { return }
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self else { return }
            self.persistTask = nil
            self.persistNow()
        }
    }

    func persistNow() {
        persistTask?.cancel(); persistTask = nil
        guard isRemote, persistenceEnabled, !sessionId.isEmpty else { return }
        ChatCacheStore.shared.save(sessionId: sessionId, messages: messages, hasMore: hasMore,
                                   context: context, turn: turnState)
    }

    // MARK: Lifecycle

    func connect() {
        intentionalClose = false
        openSocket()
    }

    private func openSocket() {
        guard task == nil else { return }
        let ws = URLSession.shared.webSocketTask(with: Config.webSocketURL(token: token, origin: origin))
        task = ws
        ws.resume()
        connected = true
        receiveLoop()
        subscribe()
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45 * 1_000_000_000)
                self?.subscribe()
            }
        }
    }

    func disconnect() {
        intentionalClose = true
        keepAlive?.cancel(); keepAlive = nil
        graceDisconnect?.cancel(); graceDisconnect = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
    }

    private func subscribe(retryOnce: Bool = false) {
        // A brand-new conversation has no id to attach yet — the first send
        // allocates one and subscribes.
        guard !sessionId.isEmpty else { return }
        // Every (re)subscribe makes the server re-flush the current turn's
        // frames — arm the absorber so the replay lands on what's already here.
        armReplayAbsorption()
        sendJSON(["type": "chat.subscribe", "sessions": [["sessionId": sessionId, "lastSeq": lastSeq]]],
                 retryOnce: retryOnce)
        // Subscribing marks presence server-side ("user is looking") which
        // suppresses push for this session — only true while a screen shows it.
        if !isVisible { releasePresence() }
    }

    /// Foreground kick: iOS kills sockets in the background but they look alive
    /// until the next I/O fails, so returning to the app could sit stale for the
    /// full backoff. Re-subscribe (or reopen) and reconcile immediately instead.
    /// `retryOnce` matters here specifically: this resubscribe is the ONLY thing
    /// that fires the instant you foreground, straight onto a socket that may
    /// already be dead (backgrounding kills them silently) — without it, that
    /// send just vanishes and recovery waits on the passive receive-loop error +
    /// exponential backoff instead, which reads as "the reply took forever, then
    /// the whole thing dumped in at once" (Manar, field report).
    func ensureConnected() {
        intentionalClose = false
        if task == nil { openSocket() } else { subscribe(retryOnce: true) }
        reconcile()
    }

    private func scheduleReconnect() {
        guard !intentionalClose else { return }
        task = nil
        reconnectAttempts += 1
        // Fast first retries (0.5s, 1s, 2s…) — the old 2s/4s/…/15s curve left
        // visible dead air after every network blip.
        let delay = min(0.5 * pow(2.0, Double(reconnectAttempts - 1)), 8.0)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.intentionalClose else { return }
            self.openSocket()
            self.reconcile()   // catch up on anything missed while disconnected
        }
    }

    // MARK: Outbound

    /// Send a prompt, optionally with attachments in the web client's
    /// `options.images` shape: `[{name, data: "data:<mime>;base64,…"}]` — the
    /// server converts them to image/PDF/text content blocks (toUserContent).
    /// `permissionMode` rides in the same options bag; the server spreads client
    /// options through to the provider runtime, which maps the mode onto its own
    /// controls. nil leaves it out entirely (server default).
    func send(_ text: String, attachments: [[String: String]] = [],
              permissionMode: PermissionMode? = nil, model: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        // Images render inline in the bubble; only non-image files fall back to a
        // "📎 name" chip line.
        let imageURLs = attachments.compactMap { $0["data"] }.filter { $0.hasPrefix("data:image/") }
        let otherFiles = attachments.filter { !($0["data"]?.hasPrefix("data:image/") ?? false) }
        var shown = trimmed
        if !otherFiles.isEmpty {
            let names = otherFiles.compactMap { $0["name"] }.map { "📎 \($0)" }.joined(separator: "\n")
            shown = shown.isEmpty ? names : shown + "\n" + names
        }
        var localMsg = ChatMessage(id: "local-\(nextSeq())", kind: "text", role: "user", content: shown)
        if !imageURLs.isEmpty { localMsg.images = imageURLs }
        // Mid-turn send: the relay queues it behind the current run. Say so on
        // the bubble — an optimistic bubble with no marker read as "sent and
        // ignored" while the agent was simply busy.
        let queued = isLoading
        if queued { localMsg.queued = true }
        // The optimistic bubble is the SEND moment of the choreography: it
        // transitions in (flies up out of the composer) and, for a fresh turn,
        // becomes the row the viewport keeps at the top. A queued message joins
        // the turn already in progress instead of re-anchoring it.
        withAnimation(ChatScroll.insertAnimation) {
            appendOrReplace(localMsg)
            if !queued { activeTurnUserId = localMsg.id }
            // Same transaction: the pending ball fades in with the bubble.
            isLoading = true
        }
        // A turn started HERE is anchored exactly by the send moment; a mid-turn
        // queued message must NOT restart the timer (isLoading was already true).
        turnAnchored = true
        awaitingFirstResponse = true
        persistNow()
        // iOS kills sockets in the background; a send into a dead one would
        // silently vanish behind the optimistic bubble. Reopen before sending.
        intentionalClose = false
        if task == nil { openSocket() }
        Task { [weak self] in
            guard let self else { return }
            // 1. Sessions exist BEFORE the first message (allocated over REST —
            //    the standard claudecodeui contract).
            if self.sessionId.isEmpty {
                guard let projectPath = self.projectPath,
                      let newId = try? await APIClient(token: self.token, origin: self.origin)
                          .createProviderSession(projectPath: projectPath) else {
                    self.appendOrReplace(ChatMessage(id: "err-\(self.nextSeq())", kind: "error", role: "assistant",
                                                     content: "Could not create a session on this server.", isError: true))
                    self.isLoading = false
                    return
                }
                self.rebind(to: newId)
                self.subscribe()   // attach the live stream so replay covers the whole run
            }
            // 2. Attachments go to the server's asset store first and are
            //    referenced by path (standard flow); a failed upload keeps the
            //    text going and reports the loss instead of vanishing silently.
            var options: [String: Any] = [:]
            if let permissionMode { options["permissionMode"] = permissionMode.rawValue }
            // The server records this against the session, so a later reopen
            // resumes on the same model.
            if let model, !model.isEmpty { options["model"] = model }
            if !attachments.isEmpty {
                do {
                    let records = try await self.uploadAttachments(attachments)
                    if !records.isEmpty { options["images"] = records }
                } catch {
                    self.appendOrReplace(ChatMessage(id: "err-\(self.nextSeq())", kind: "error", role: "assistant",
                                                     content: "Attachment upload failed — sending without files. (\(error.localizedDescription))",
                                                     isError: true))
                }
            }
            self.sendJSON(["type": "chat.send", "sessionId": self.sessionId, "content": trimmed, "options": options], retryOnce: true)
        }
    }

    /// A conversation acquired (or changed) its real session id: re-key in the
    /// registry and tell the view so Recents/reopen targets follow.
    private func rebind(to newId: String) {
        guard !newId.isEmpty else { return }
        let changed = sessionId != newId
        sessionId = newId
        ConversationRegistry.shared.register(self)
        if changed { onSessionIdRebound?(newId) }
    }

    /// Uploads composer attachments (held as data-URLs) to the asset store and
    /// returns the `{name, path, mimeType}` records chat.send references.
    /// Images and other files go to their respective store routes.
    private func uploadAttachments(_ attachments: [[String: String]]) async throws -> [[String: Any]] {
        var images: [(name: String, mime: String, bytes: Data)] = []
        var files: [(name: String, mime: String, bytes: Data)] = []
        for attachment in attachments {
            guard let dataURL = attachment["data"], let parsed = Self.parseDataURL(dataURL) else { continue }
            let entry = (name: attachment["name"] ?? "attachment", mime: parsed.mime, bytes: parsed.bytes)
            if parsed.mime.hasPrefix("image/") { images.append(entry) } else { files.append(entry) }
        }
        let api = APIClient(token: token, origin: origin)
        var records: [APIClient.AssetRecord] = []
        if !images.isEmpty { records += try await api.uploadAssets(images, field: "images") }
        if !files.isEmpty { records += try await api.uploadAssets(files, field: "files") }
        return records.map { record in
            var entry: [String: Any] = ["path": record.path]
            if let name = record.name { entry["name"] = name }
            if let mimeType = record.mimeType { entry["mimeType"] = mimeType }
            return entry
        }
    }

    /// "data:<mime>;base64,<payload>" → (mime, bytes). Returns nil for
    /// malformed or non-base64 data URLs.
    static func parseDataURL(_ dataURL: String) -> (mime: String, bytes: Data)? {
        guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ",") else { return nil }
        let header = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma])
        let mime = header.split(separator: ";").first.map(String.init) ?? ""
        guard let bytes = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return (mime.isEmpty ? "application/octet-stream" : mime, bytes)
    }

    func answerPermission(requestId: String, allow: Bool) {
        sendJSON(["type": "chat.permission-response", "requestId": requestId, "allow": allow])
        pendingPermission = nil
    }

    /// Drop the server-side "user is watching this session" presence WITHOUT
    /// closing the socket, so a reply finishing a moment later pushes a
    /// notification instead of being suppressed. Sent on background, on
    /// leaving the screen, and after every re-subscribe while unwatched.
    /// (Server ≥1.37.22 honors presence.release; older servers ignore it.)
    func releasePresence() {
        guard task != nil else { return }
        sendJSON(["type": "presence.release"])
    }

    func abort() {
        sendJSON(["type": "chat.abort", "sessionId": sessionId])
        isLoading = false
    }

    /// Reconcile the working indicator with the server's live agent status — the
    /// stream only flips isLoading when a frame ARRIVES, so opening a chat whose
    /// agent is already mid-turn (quiet inside a long tool call) showed no loader
    /// at all. Poll-safe: only ever turns the indicator ON; the stream's complete
    /// (or the server watchdog) turns it off.
    func syncRunningState(_ api: APIClient) async {
        guard isRemote else { return }
        if let st = try? await api.agentStatus(),
           let mine = st.first(where: { $0.id == sessionId }) {
            if mine.running == true {
                if !isLoading { isLoading = true }
                // Turn started elsewhere (web, another device, a scheduled run) or
                // was already running on open: fetch the real start from the
                // transcript so the timer doesn't restart from zero. Retries on the
                // next poll until anchored (limit=1 keeps the fetch tiny).
                if !turnAnchored { await refreshTurnStart(api) }
            } else if isLoading, !awaitingFirstResponse,
                      Date().timeIntervalSince(turnStartedAt ?? .distantPast) > 20 {
                // Restored "working" from a snapshot (or a missed `complete`)
                // while the agent is demonstrably idle: the status endpoint is
                // authoritative — clear the ball and fetch what we missed.
                isLoading = false
                statusText = nil
                reconcile()
            }
        }
    }

    /// Anchor the elapsed timer to the transcript's turn-start timestamp and
    /// seed the token counter's baseline when the server provides one.
    /// Ignored when idle (a stale anchor from a finished turn must not revive).
    func applyServerTurnStart(_ iso: String?, startContext: Int? = nil) {
        guard isLoading, let iso, let date = Self.parseISO(iso) else { return }
        turnStartedAt = date
        turnAnchored = true
        if let startContext {
            turnStartContext = startContext
            if let current = context?.usedTokens {
                turnTokens = max(0, current - startContext)
            }
        }
    }

    /// Assistant frames carry the absolute context position; diff against the
    /// turn baseline for the live counter. Absolute values are replay-safe —
    /// duplicated frames can never double-count.
    private func noteContextTokens(_ tokens: Int) {
        guard tokens > 0 else { return }

        // Per-TURN counter only means anything inside a turn.
        if isLoading {
            // Re-baseline when the anchor sits ABOVE the live reading. The
            // baseline can come from history (which adds output_tokens) while
            // frames carry prompt only, so the difference goes negative and the
            // counter used to clamp to a permanent "0 tokens". Trusting the
            // lower, same-formula reading keeps the delta meaningful.
            if turnStartContext == nil || tokens < (turnStartContext ?? tokens) {
                turnStartContext = tokens
            }
            turnTokens = max(0, tokens - (turnStartContext ?? tokens))
        }

        // Context genuinely goes DOWN (compaction), so the meter follows in
        // both directions. Window is preserved when known and left at 0
        // otherwise — ContextMeter then prints a bare count rather than
        // inventing a denominator. Live frames (prompt only) and the history
        // payload (adds output_tokens) disagree slightly by design; left as-is.
        context = ContextUsage(usedTokens: tokens, windowTokens: context?.windowTokens ?? 0)
    }

    /// Fetch just the turn anchor — history with limit=1 still carries
    /// turnStartedAt (derived server-side from the full event log).
    private func refreshTurnStart(_ api: APIClient) async {
        guard let h = try? await api.history(sessionId: sessionId, limit: 1) else { return }
        if let ctx = h.context { context = ctx }
        applyServerTurnStart(h.turnStartedAt, startContext: h.turnStartContextTokens)
    }

    /// Relay timestamps carry microsecond fractions ("…T00:03:53.981039Z") that
    /// ISO8601DateFormatter rejects — drop the fraction (second precision is
    /// plenty for an elapsed timer).
    nonisolated static func parseISO(_ s: String) -> Date? {
        let cleaned = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: cleaned)
    }

    // MARK: History

    func setHistory(_ history: [ChatMessage]) {
        let previousAnchor = activeTurnUserId.flatMap { id in messages.first { $0.id == id } }
        messages = history
        hasLoadedOnce = hasLoadedOnce || !history.isEmpty
        reanchorActiveTurn(previous: previousAnchor)
        revision += 1
        persistSoon()
    }

    /// Adopt the history the server already has for THIS conversation on
    /// open — merged, so the live tail (a message sent moments ago that the
    /// server's cache hasn't caught up to) is never erased. Returns true when
    /// anything visibly changed.
    @discardableResult
    func adoptHistory(_ h: HistoryResponse) -> Bool {
        let merged = Self.mergingLiveTail(live: messages, fetched: h.messages)
        let changed = ChatCacheStore.fingerprint(merged) != ChatCacheStore.fingerprint(messages)
        if changed {
            withAnimation(ChatScroll.reconcileAnimation) { setHistory(merged) }
        }
        hasMore = h.hasMore ?? hasMore
        hasLoadedOnce = true
        if let ctx = h.context { context = ctx }
        // If a stream frame already flipped the loader on, anchor the timer to
        // the real turn start carried by this history fetch.
        applyServerTurnStart(h.turnStartedAt, startContext: h.turnStartContextTokens)
        persistNow()
        return changed
    }

    /// The active-turn anchor must survive id rebinds: the echo and the
    /// history merge both replace the optimistic "local-…" row by its server
    /// copy. Re-point at the server copy (same typed text), else at the newest
    /// user message, else drop the anchor.
    private func reanchorActiveTurn(previous: ChatMessage?) {
        guard let id = activeTurnUserId else { return }
        if messages.contains(where: { $0.id == id }) { return }
        if let prev = previous {
            let typed = Self.typedText(prev)
            if let twin = messages.last(where: { m in
                m.role == "user" && m.kind == "text" && (Self.typedText(m) == typed
                    || (m.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(typed + "\n"))
            }) {
                activeTurnUserId = twin.id
                return
            }
        }
        activeTurnUserId = messages.last(where: { $0.role == "user" && $0.kind == "text" })?.id
    }

    /// Replace the transcript with a fetched history WITHOUT letting a stale
    /// fetch erase messages already on screen. The server pages agent
    /// transcripts from a relay-events cache whose top-up fails SILENTLY
    /// (throttling, token refresh) — history then comes back missing the
    /// newest turn, and a blind replace wiped a message the user had just
    /// sent (seen in the field 2026-09-27: sent bubble vanished while the
    /// agent demonstrably received it). Keep any live tail the fetch doesn't
    /// know about; the next fresh fetch converges naturally.
    static func mergingLiveTail(live: [ChatMessage], fetched: [ChatMessage]) -> [ChatMessage] {
        guard !live.isEmpty else { return fetched }
        let fetchedIds = Set(fetched.map(\.id))
        // Anchor: the LAST live message the fetch also has. No overlap at all
        // means the transcript legitimately restarted (/clear, compaction) —
        // trust the fetch wholesale rather than resurrecting an old view.
        guard let anchor = live.lastIndex(where: { fetchedIds.contains($0.id) }) else { return fetched }
        let tail = live[(anchor + 1)...]
        guard !tail.isEmpty else { return fetched }
        // Content-level dedupe: a locally-streamed bubble ("stream-N") and the
        // fetch's final text are the same message under different ids.
        let fetchedBodies = Set(fetched.map(bodyKey))
        // User bubbles need a FUZZY pass on top: the optimistic bubble renders
        // attachments as trailing "📎 name" lines and the server stores its own
        // normalization, so exact-body dedupe can miss — and the stale bubble
        // then re-appended BELOW the agent's response (field bug 2026-10-18:
        // "my message appears below the response"). Compare the typed text
        // against the fetch's post-anchor USER messages instead; a decorated
        // server copy still matches by prefix.
        let anchorIdx = fetched.firstIndex { $0.id == live[anchor].id } ?? (fetched.count - 1)
        let fetchedUserTexts = fetched[anchorIdx...].filter { $0.role == "user" }
            .map { ($0.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let missing = tail.filter { m in
            if fetchedBodies.contains(bodyKey(m)) { return false }
            if m.role == "user", m.kind == "text", m.queued != true {
                let typed = typedText(m)
                if typed.isEmpty {
                    // Attachment-only send: any post-anchor user message in the
                    // fetch means the server recorded it in its own format.
                    return fetchedUserTexts.isEmpty
                }
                if fetchedUserTexts.contains(where: { $0 == typed || $0.hasPrefix(typed + "\n") }) {
                    return false
                }
            }
            return true
        }
        return missing.isEmpty ? fetched : fetched + missing
    }

    /// A final `text` frame belongs to the bubble we streamed when one is a
    /// prefix of the other (the stream may have been cut short, or the final
    /// may carry a trimmed body). A replayed EARLIER block's final must not
    /// hijack the bubble of the block currently streaming.
    private static func sameBlock(bubble: String, final: String) -> Bool {
        let b = bubble.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = final.trimmingCharacters(in: .whitespacesAndNewlines)
        if b.isEmpty || f.isEmpty { return false }
        return f.hasPrefix(b) || b.hasPrefix(f)
    }

    /// The text the user actually TYPED: the optimistic bubble appends non-image
    /// attachments as "📎 name" lines that exist nowhere server-side.
    static func typedText(_ m: ChatMessage) -> String {
        (m.content ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("📎 ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bodyKey(_ m: ChatMessage) -> String {
        "\(m.role)|\(m.kind)|\((m.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Prepend an older page. Deliberately does NOT bump `revision`: that drives
    /// the follow-to-bottom scroll, and content added ABOVE the viewport must
    /// leave the reading position where it is.
    func prependHistory(_ older: [ChatMessage]) {
        guard !older.isEmpty else { return }
        messages.insert(contentsOf: older, at: 0)
    }

    /// Re-fetch the authoritative transcript and MERGE it in. Only when idle,
    /// so an in-progress streaming turn is never wiped mid-flight. Visually
    /// idempotent: nothing is swapped unless the server really has something
    /// new, and then the new rows animate in like live ones.
    private var reconcileInFlight = false
    private func reconcile() {
        guard !isLoading, !sessionId.isEmpty, !reconcileInFlight else { return }
        reconcileInFlight = true
        syncing = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.reconcileInFlight = false; self.syncing = false }
            if let h = try? await APIClient(token: self.token, origin: self.origin).history(sessionId: self.sessionId) {
                // A turn may have started meanwhile — never disturb it.
                if !self.isLoading { self.adoptHistory(h) }
            }
        }
    }

    /// Unconditional history refetch — unlike `reconcile()` this ignores
    /// `isLoading`. Used by the view's `/clear` recovery poll, which must keep
    /// refreshing even while `isLoading` is stuck true (a local `/clear` may
    /// never emit the "complete" frame the normal reconcile waits for). Safe
    /// to call anytime: `mergingLiveTail` already protects any live tail the
    /// fetch doesn't know about yet, and trusts the fetch wholesale when the
    /// transcript legitimately restarted (this is exactly that case).
    func forceReconcile() async {
        guard let h = try? await APIClient(token: token, origin: origin).history(sessionId: sessionId) else { return }
        adoptHistory(h)
    }

    private func scheduleReconcile() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self?.reconcile()
        }
    }

    // MARK: Inbound

    private func receiveLoop() {
        let ws = task
        ws?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                // A socket we already replaced (token rotation, explicit
                // reconnect) reports its own death late — never let that
                // tear down the live one.
                guard self.task === ws else { return }
                switch result {
                case .failure:
                    self.connected = false
                    self.scheduleReconnect()
                case .success(let message):
                    self.reconnectAttempts = 0
                    if case let .string(text) = message { self.handle(text) }
                    self.receiveLoop()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let type = obj["type"] as? String
        let kind = obj["kind"] as? String

        // Any non-delta frame must observe the fully-applied stream so ordering
        // holds (e.g. stream_end / tool_use arriving between coalesced flushes).
        if kind != "stream_delta" {
            chunkFlushTask?.cancel()
            chunkFlushTask = nil
            flushStreamChunk()
        }

        if type == "session-status" {
            if let processing = obj["isProcessing"] as? Bool { isLoading = processing }
            if let status = obj["status"] as? [String: Any], let t = status["text"] as? String { statusText = t }
            return
        }

        // Live token counter: assistant frames carry the absolute context position.
        if let ctx = obj["contextTokens"] as? Int { noteContextTokens(ctx) }

        // Upstream frames carry a per-run seq — remember the high-water mark so
        // the next chat.subscribe replays only what we actually missed.
        if let s = obj["seq"] as? Int { lastSeq = max(lastSeq, s) }

        switch kind {
        case "chat_subscribed":
            // Upstream's subscribe ack: authoritative running/pending snapshot.
            if let processing = obj["isProcessing"] as? Bool {
                if processing { isLoading = true }
                // A just-sent turn can't have finished before its first frame —
                // don't let a pre-run snapshot kill the fresh loader.
                else if !awaitingFirstResponse { isLoading = false }
            }
            if let pending = obj["pendingPermissions"] as? [[String: Any]],
               let first = pending.first, let requestId = first["requestId"] as? String {
                var m = ChatMessage(id: (first["id"] as? String) ?? "perm-\(nextSeq())",
                                    kind: "permission_request", role: "assistant",
                                    toolName: first["toolName"] as? String)
                m.requestId = requestId
                pendingPermission = m
            }
            return
        case "session_upserted", "loading_progress":
            return
        case "protocol_error":
            streamingId = nil
            Haptics.error()
            appendOrReplace(ChatMessage(id: messageId(obj), kind: "error", role: "assistant",
                                        content: (obj["message"] as? String) ?? "Server rejected the request.",
                                        isError: true))
            isLoading = false
            return
        default:
            break
        }

        switch kind {
        case "stream_delta":
            // Replayed deltas (every re-subscribe re-flushes the turn) are
            // absorbed against what's already here; only new text streams.
            guard let fresh = absorb(obj["content"] as? String ?? ""), !fresh.isEmpty else { break }
            noteResponseActivity()
            appendStream(fresh)
            isLoading = true
        case "stream_end":
            // The block's final `text` frame follows and finalizes the bubble
            // in place — keep the bubble addressable until then.
            break
        case "text":
            let role = obj["role"] as? String ?? "assistant"
            if role == "assistant" { noteResponseActivity() }
            let body = (obj["displayText"] as? String) ?? (obj["content"] as? String) ?? ""
            if !body.isEmpty {
                // The relay echoes the user's own message back as a text frame. If we
                // already showed it optimistically (id "local-…"), reconcile that bubble
                // to the server id instead of appending a duplicate. Matching must be
                // FUZZY in both directions: the local bubble may carry "📎 name" chip
                // lines the echo lacks, and the echo may carry server-side attachment
                // decoration the bubble lacks — a missed match here appended the echo
                // BELOW the already-streaming response (2026-10-18 ordering bug).
                if role == "user",
                   let idx = messages.firstIndex(where: { m in
                       guard m.id.hasPrefix("local-"), m.role == "user" else { return false }
                       let c = m.content ?? ""
                       let typed = Self.typedText(m)
                       let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
                       if c == body || typed == b { return true }
                       if !typed.isEmpty && b.hasPrefix(typed + "\n") { return true }
                       if b.isEmpty && c.hasPrefix("📎") { return true }
                       // Attachment-only send: the echo is all decoration.
                       if typed.isEmpty && !b.isEmpty { return true }
                       return false
                   }) {
                    let serverId = messageId(obj)
                    if activeTurnUserId == messages[idx].id { activeTurnUserId = serverId }
                    messages[idx].id = serverId
                    // The relay echoed it back — it left the queue.
                    messages[idx].queued = nil
                    revision += 1
                    persistSoon()
                } else if role != "user", let sid = streamingId,
                          let idx = messages.firstIndex(where: { $0.id == sid }),
                          Self.sameBlock(bubble: messages[idx].content ?? "", final: body) {
                    // The final text for the bubble that just streamed: FINALIZE
                    // it in place (same row, server id, authoritative body) —
                    // a separate final row beside the stream bubble was the
                    // duplicate the end-of-turn reconcile used to mop up, and
                    // on a replay it was the duplicate nothing mopped up.
                    let serverId = messageId(obj)
                    streamingId = nil
                    if messages.contains(where: { $0.id == serverId }) {
                        // Already have the final (replayed stream) — the
                        // temporary bubble is the duplicate.
                        messages.remove(at: idx)
                    } else {
                        messages[idx].id = serverId
                        messages[idx].content = body
                        if messages[idx].timestamp == nil, let ts = obj["timestamp"] as? String {
                            messages[idx].timestamp = ts
                        }
                    }
                    revision += 1
                    persistSoon()
                } else {
                    streamingId = nil
                    appendOrReplace(ChatMessage(id: messageId(obj), kind: "text", role: role, content: body))
                }
            } else {
                streamingId = nil
            }
        case "tool_use":
            noteResponseActivity()
            var m = ChatMessage(id: messageId(obj), kind: "tool_use", role: "assistant",
                                toolName: obj["toolName"] as? String)
            if let ti = obj["toolInput"] { m.toolInput = AnyCodable(ti) }
            appendOrReplace(m)
        case "tool_result":
            appendOrReplace(ChatMessage(id: messageId(obj), kind: "tool_result", role: "assistant",
                                        content: obj["content"] as? String, isError: obj["isError"] as? Bool))
        case "thinking":
            // Was dropped on the floor. For a REASONING model (DeepSeek through
            // the opencode provider) this is the bulk of a turn, so discarding it
            // left the transcript empty while the model worked — the app looked
            // frozen. Keep it; ChatView renders it muted.
            noteResponseActivity()
            appendOrReplace(ChatMessage(id: messageId(obj), kind: "thinking", role: "assistant",
                                        content: (obj["content"] as? String) ?? (obj["text"] as? String)))
        case "status":
            // A `token_budget` status frame carries a token-usage payload, NOT a
            // human status label — the web client routes it to its usage meter.
            // iOS has no usage meter yet, so swallow it; rendering its literal
            // "token_budget" text in the progress line was the bug.
            if (obj["text"] as? String) == "token_budget" { break }
            statusText = obj["text"] as? String
            isLoading = true
        case "permission_request":
            Haptics.attention()
            var m = ChatMessage(id: messageId(obj), kind: "permission_request", role: "assistant",
                                toolName: obj["toolName"] as? String)
            m.requestId = obj["requestId"] as? String
            pendingPermission = m
        case "session_created":
            // A new local conversation gets its real id at turn start — rebind so
            // resumes and history reads target the actual session.
            if !isRemote, let newId = (obj["newSessionId"] as? String) ?? (obj["sessionId"] as? String), !newId.isEmpty {
                rebind(to: newId)
            }
        case "permission_cancelled":
            pendingPermission = nil
        case "error":
            streamingId = nil
            Haptics.error()
            appendOrReplace(ChatMessage(id: messageId(obj), kind: "error", role: "assistant",
                                        content: obj["content"] as? String, isError: true))
            isLoading = false
        case "complete":
            streamingId = nil
            if isLoading { Haptics.complete() }
            isLoading = false
            statusText = nil
            // Turn over — anything still marked queued has been consumed (or
            // will be re-sent by the user); the marker must not outlive the run.
            for i in messages.indices where messages[i].queued == true {
                messages[i].queued = nil
            }
            persistNow()
            scheduleReconcile()
            // Nobody is watching: the socket has done its job for this turn.
            if !isVisible { scheduleGraceDisconnect() }
        default:
            break
        }
    }

    // MARK: replay absorption

    /// The server re-flushes the current turn's frame buffer on every
    /// (re)subscribe — the 45s keepalive and the foreground kick (a send's
    /// own attach replays nothing: the buffer is emptied at turn end). Id'd
    /// frames collapse by id; stream deltas carry NO id, so they are matched,
    /// in order, as a running PREFIX of the turn's assistant text rows. Only
    /// text past what's already on screen is new.
    ///
    /// Divergence is NOT assumed to be a replay: a live reply that merely
    /// starts with the same words as the row it is compared to is swallowed
    /// only until it differs, and the swallowed prefix is restored then. A
    /// reply identical to an entire earlier row is repaired by its final
    /// `text` frame (appended by id). The worst case is a missed streaming
    /// animation, never lost or duplicated text.
    private var absorbQueue: [String] = []
    private var absorbCursor = 0
    private var absorbed = ""

    private func armReplayAbsorption() {
        flushStreamChunk()
        absorbCursor = 0
        absorbed = ""
        // The current turn's assistant text rows: everything after the last
        // user message, in order.
        let turnStart = messages.lastIndex(where: { $0.role == "user" && $0.kind == "text" })
            .map { $0 + 1 } ?? 0
        absorbQueue = messages[turnStart...]
            .filter { $0.kind == "text" && $0.role != "user" }
            .map(\.id)
    }

    /// nil = fully replayed (drop); otherwise the part of `chunk` that is new.
    private func absorb(_ chunk: String) -> String? {
        guard !chunk.isEmpty else { return nil }
        while let tid = absorbQueue.first {
            guard let idx = messages.firstIndex(where: { $0.id == tid }) else {
                absorbQueue.removeFirst(); absorbCursor = 0; absorbed = ""
                continue
            }
            let content = messages[idx].content ?? ""
            let remaining = content.dropFirst(absorbCursor)
            if remaining.isEmpty {
                // This row fully re-covered — on to the next one. A row we were
                // streaming ourselves (necessarily the last) continues in place.
                absorbQueue.removeFirst(); absorbCursor = 0; absorbed = ""
                if absorbQueue.isEmpty, tid.hasPrefix("stream-") { streamingId = tid }
                continue
            }
            if remaining.hasPrefix(chunk) {
                absorbCursor += chunk.count
                absorbed += chunk
                return nil
            }
            if chunk.hasPrefix(remaining) {
                // Runs past this row: the excess continues our own stream
                // bubble, or starts a new row after a finalized one.
                let excess = String(chunk.dropFirst(remaining.count))
                absorbQueue.removeFirst(); absorbCursor = 0; absorbed = ""
                if absorbQueue.isEmpty, tid.hasPrefix("stream-") { streamingId = tid }
                return absorb(excess) ?? nil
            }
            // Divergent: not a replay of this row — it's live text. Give back
            // whatever was provisionally swallowed against this row.
            let restored = absorbed + chunk
            absorbQueue = []; absorbCursor = 0; absorbed = ""
            return restored
        }
        return chunk
    }

    // MARK: helpers

    // Stream chunks arrive per-token; publishing `messages` on each one forced a
    // full SwiftUI re-render per token — long replies made the whole chat crawl
    // (O(n²): every token re-rendered the entire growing message). Coalesce to
    // ~12 UI updates/second; `handle` flushes synchronously before any non-delta
    // frame so ordering is preserved.
    private var pendingChunk = ""
    private var chunkFlushTask: Task<Void, Never>?

    private func appendStream(_ chunk: String) {
        pendingChunk += chunk
        guard chunkFlushTask == nil else { return }
        chunkFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self, !Task.isCancelled else { return }
            self.chunkFlushTask = nil
            self.flushStreamChunk()
        }
    }

    private func flushStreamChunk() {
        guard !pendingChunk.isEmpty else { return }
        let chunk = pendingChunk
        pendingChunk = ""
        if let sid = streamingId, let idx = messages.firstIndex(where: { $0.id == sid }) {
            messages[idx].content = (messages[idx].content ?? "") + chunk
        } else {
            let id = "stream-\(nextSeq())"
            streamingId = id
            // The first text of a reply takes the pending ball's place — one
            // transaction, so the ball dissolves into the text (ChatGPT feel).
            withAnimation(ChatScroll.insertAnimation) {
                messages.append(ChatMessage(id: id, kind: "text", role: "assistant", content: chunk,
                                            timestamp: ISO8601DateFormatter().string(from: Date())))
            }
        }
        revision += 1
        persistSoon()
    }

    private func appendOrReplace(_ m: ChatMessage) {
        var m = m
        if let idx = messages.firstIndex(where: { $0.id == m.id }) {
            // A replacement frame without its own stamp keeps the original's —
            // an echo must not erase when the message was actually sent.
            if m.timestamp == nil { m.timestamp = messages[idx].timestamp }
            messages[idx] = m
        } else {
            // Live frames don't always carry a transcript timestamp; they DO
            // arrive in real time, so "now" is the truth for display.
            if m.timestamp == nil {
                m.timestamp = ISO8601DateFormatter().string(from: Date())
            }
            withAnimation(ChatScroll.insertAnimation) { messages.append(m) }
        }
        revision += 1
        persistSoon()
    }

    private func messageId(_ obj: [String: Any]) -> String {
        (obj["id"] as? String) ?? "srv-\(nextSeq())"
    }

    private func nextSeq() -> Int { seq += 1; return seq }

    private func sendJSON(_ dict: [String: Any], retryOnce: Bool = false) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return }
        let ws = task
        ws?.send(.string(str)) { [weak self] error in
            guard error != nil, retryOnce else { return }
            // Dead socket (backgrounding kills them): reopen and resend once so
            // the message the user already sees as sent actually goes out.
            Task { @MainActor in
                guard let self else { return }
                if self.task === ws { self.task = nil }
                self.openSocket()
                try? await Task.sleep(nanoseconds: 700_000_000)
                self.task?.send(.string(str)) { _ in }
            }
        }
    }
}
