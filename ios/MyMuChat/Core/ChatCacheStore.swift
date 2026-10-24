import Foundation

/// Persistent snapshot of every agent conversation — what makes the chat
/// LOCAL-FIRST (Manar, 2026-10-24: "we already know we sent the message and it
/// succeeded, why reload it from the server").
///
/// History: this began (2026-09-19) as a warm-start cache written at exactly
/// two moments — the open fetch and the end-of-turn reconcile. That left a hole
/// that read as a bug: a message sent, then Back, then re-open rendered the
/// OLD snapshot (no sent bubble, no reply) and the server's refresh then
/// dumped the whole turn in at once. The store is now written on every
/// transcript mutation (debounced by the relay) and carries the turn state —
/// is the agent working, since when, which user message opened the turn, the
/// replay cursor — so a conversation re-opens EXACTLY as it was left, ball
/// still pulsing, and the live stream merely continues it.
///
/// Snapshots live in Caches (the system may evict them; they rebuild on the
/// next open) and are wiped when an account is removed.
@MainActor
final class ChatCacheStore {
    static let shared = ChatCacheStore()

    /// Turn-level state saved beside the messages. Optional in the snapshot so
    /// pre-existing files (no `turn` key) still decode.
    struct TurnState: Codable, Equatable {
        var isLoading: Bool
        /// ISO timestamp the running turn started (anchors the elapsed timer).
        var startedAt: String?
        /// Id of the user message that opened the turn FROM THIS DEVICE — the
        /// geometry anchor the chat keeps at the top of the viewport.
        var activeTurnUserId: String?
        /// Highest server `seq` seen (local sessions' replay cursor).
        var lastSeq: Int
        /// When this state was written. A "loading" flag older than
        /// `staleLoadingAfter` is not trusted on restore — the turn ended while
        /// the app was dead and the agent-status poll will say so anyway.
        var savedAt: String

        var isLoadingFresh: Bool {
            guard isLoading, let d = RelayClient.parseISO(savedAt) else { return false }
            return Date().timeIntervalSince(d) < ChatCacheStore.staleLoadingAfter
        }
    }

    struct Snapshot: Codable {
        var messages: [ChatMessage]
        var hasMore: Bool?
        var context: ContextUsage?
        var turn: TurnState?
    }

    /// Newest page only — mirrors what a fresh open fetches, so cache and
    /// network agree on shape ("Load earlier messages" covers the rest).
    nonisolated private static let maxMessages = 200
    nonisolated private static let maxSessions = 40
    nonisolated static let staleLoadingAfter: TimeInterval = 3 * 60 * 60

    /// Fingerprint of what's on disk per session (this process's Hasher seed),
    /// so an unchanged transcript is never re-encoded or rewritten.
    private var savedFingerprints: [String: Int] = [:]
    /// Turn state last written per session (savedAt excluded from the compare —
    /// a bare clock tick must not cost a disk write).
    private var savedTurns: [String: TurnState] = [:]

    /// Decoded snapshots held in RAM. This is what makes opening a chat
    /// INSTANT: the registry reads it synchronously when it builds a client,
    /// so the first rendered frame already contains the transcript — no
    /// loader, no disk hop on the open path. Populated by warm() (roster
    /// load), load() and save().
    private var memory: [String: Snapshot] = [:]

    /// Synchronous RAM hit — nil means "not warmed yet", NOT "no cache";
    /// callers fall back to the async load() for the disk answer.
    func cached(sessionId: String) -> Snapshot? { memory[sessionId] }

    /// Decode disk snapshots into RAM ahead of need (called when the agent
    /// roster lands), so first opens hit memory too. Skips already-warm ids;
    /// decodes off-main, one pass.
    func warm(sessionIds: [String]) {
        let cold = sessionIds.filter { !$0.isEmpty && memory[$0] == nil }
        guard !cold.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            var found: [(String, Snapshot)] = []
            for sid in cold {
                guard let data = try? Data(contentsOf: Self.fileURL(sid)),
                      let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { continue }
                found.append((sid, snap))
            }
            guard !found.isEmpty else { return }
            await MainActor.run {
                for (sid, snap) in found where ChatCacheStore.shared.memory[sid] == nil {
                    ChatCacheStore.shared.adopt(sid, snap)
                }
            }
        }
    }

    private func adopt(_ sid: String, _ snap: Snapshot) {
        memory[sid] = snap
        savedFingerprints[sid] = Self.fingerprint(snap.messages)
        savedTurns[sid] = snap.turn
    }

    /// The transcript identity that matters for "did anything change":
    /// row ids, visible text length, and tool progress. Deliberately NOT the
    /// full content bytes — a single pass over stored lengths is enough to
    /// catch every real mutation the server can make.
    static func fingerprint(_ messages: [ChatMessage]) -> Int {
        var h = Hasher()
        h.combine(messages.count)
        for m in messages {
            h.combine(m.id)
            h.combine(m.bodyText.utf8.count)
            h.combine(m.status)
            h.combine(m.toolResult != nil)
        }
        return h.finalize()
    }

    func load(sessionId: String) async -> Snapshot? {
        guard !sessionId.isEmpty else { return nil }
        if let hit = memory[sessionId] { return hit }
        let url = Self.fileURL(sessionId)
        let snap = await Task.detached(priority: .userInitiated) { () -> Snapshot? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Snapshot.self, from: data)
        }.value
        if let snap { adopt(sessionId, snap) }
        return snap
    }

    /// Write a snapshot. Change-gated on the transcript fingerprint AND the
    /// turn state (minus its clock), encoded and written off-main.
    func save(sessionId: String, messages: [ChatMessage], hasMore: Bool?, context: ContextUsage?,
              turn: TurnState? = nil) {
        guard !sessionId.isEmpty, !messages.isEmpty else { return }
        var page = Array(messages.suffix(Self.maxMessages))
        let fp = Self.fingerprint(page)
        let turnChanged = !Self.sameTurn(savedTurns[sessionId], turn)
        guard savedFingerprints[sessionId] != fp || turnChanged else { return }
        savedFingerprints[sessionId] = fp
        savedTurns[sessionId] = turn
        // `queued` is local mid-turn state; a reopened chat must not resurrect
        // ghost "queued" chips from a turn that finished long ago.
        for i in page.indices { page[i].queued = nil }
        let snap = Snapshot(messages: page, hasMore: hasMore, context: context, turn: turn)
        memory[sessionId] = snap
        let url = Self.fileURL(sessionId)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snap) else { return }
            try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            Self.prune()
        }
    }

    private static func sameTurn(_ a: TurnState?, _ b: TurnState?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?):
            return x.isLoading == y.isLoading && x.startedAt == y.startedAt
                && x.activeTurnUserId == y.activeTurnUserId && x.lastSeq == y.lastSeq
        default: return false
        }
    }

    /// Account removal wipes everything — snapshots are cheap to rebuild and
    /// must not outlive the login that fetched them.
    func clearAll() {
        savedFingerprints = [:]
        savedTurns = [:]
        memory = [:]
        let dir = Self.dir
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: disk

    nonisolated private static var dir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-cache", isDirectory: true)
    }

    nonisolated private static func fileURL(_ sessionId: String) -> URL {
        let safe = String(sessionId.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        return dir.appendingPathComponent("\(safe).json")
    }

    /// Oldest snapshots beyond the cap go; runs on the write queue, best-effort.
    nonisolated private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        guard files.count > maxSessions else { return }
        let dated = files.map { url -> (URL, Date) in
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (url, d)
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - maxSessions) {
            try? fm.removeItem(at: url)
        }
    }
}
