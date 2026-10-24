import Foundation
import SwiftUI

/// One live `RelayClient` per conversation, owned HERE rather than by the chat
/// view — the structural fix for "I send, go out, come back, and the message
/// is gone until the server spits the whole turn in" (Manar, 2026-10-24).
///
/// The chat view used to own its relay as a `@StateObject`: Back deallocated
/// it, the socket with it, and the next open started from a snapshot written
/// before the send. Now the view only BORROWS the client for this conversation
/// (keyed by host + session) and the registry keeps it alive:
///
/// - while a turn is running the socket stays open after the view is gone, so
///   the stream keeps landing in the store (and in the snapshot) exactly as if
///   the user had stayed — re-entry shows the reply where it got to, no fetch
///   needed. Presence is released on every re-subscribe while unwatched, so
///   push notifications still fire for an unwatched reply.
/// - an idle client disconnects after a short grace (quick tab-out-and-back
///   never reconnects) but keeps its transcript in RAM; the snapshot on disk
///   backs it if the registry evicts it (bounded LRU).
///
/// The registry is also the one place that reacts to app lifecycle for
/// clients the visible screen does not own (background → release presence;
/// foreground → reconnect anything mid-turn).
@MainActor
final class ConversationRegistry {
    static let shared = ConversationRegistry()

    private var clients: [String: RelayClient] = [:]
    /// Most-recently-used LAST.
    private var recency: [String] = []
    /// Instances kept alive beyond what is on screen. Each holds one page of
    /// transcript (≤200 rows) — cheap — and at most one socket.
    private let keepAlive = 6

    static func key(origin: String?, sessionId: String) -> String {
        "\(Config.normalize(origin ?? ""))|\(sessionId)"
    }

    /// The client for this conversation — existing (live transcript, maybe a
    /// live socket) or freshly built from the RAM snapshot. A conversation
    /// with no id yet (brand-new local chat) is handed an unregistered client;
    /// `register(_:)` adopts it once `session_created` assigns the real id.
    func client(token: String, sessionId: String, isRemote: Bool, projectPath: String?,
                origin: String?) -> RelayClient {
        guard !sessionId.isEmpty else {
            return RelayClient(token: token, sessionId: sessionId, isRemote: isRemote,
                               projectPath: projectPath, origin: origin)
        }
        let k = Self.key(origin: origin, sessionId: sessionId)
        if let existing = clients[k] {
            existing.updateToken(token)
            touch(k)
            return existing
        }
        let snap = ChatCacheStore.shared.cached(sessionId: sessionId)
        let c = RelayClient(token: token, sessionId: sessionId, isRemote: isRemote,
                            projectPath: projectPath, origin: origin, seed: snap)
        clients[k] = c
        touch(k)
        evictIfNeeded()
        return c
    }

    /// A client that already exists for this session on ANY host — the swipe
    /// switcher previews read the live transcript from here before falling
    /// back to the disk snapshot.
    func peek(sessionId: String) -> RelayClient? {
        guard !sessionId.isEmpty else { return nil }
        return clients.values.first { $0.sessionId == sessionId }
    }

    /// Adopt a client under its (new) key — called after a session-id rebind.
    func register(_ client: RelayClient) {
        guard !client.sessionId.isEmpty else { return }
        let k = Self.key(origin: client.origin, sessionId: client.sessionId)
        clients[k] = client
        touch(k)
        evictIfNeeded()
    }

    private func touch(_ k: String) {
        recency.removeAll { $0 == k }
        recency.append(k)
    }

    /// Drop the oldest IDLE, UNWATCHED clients beyond the cap. A client mid-turn
    /// is never evicted — its socket is the thing keeping the reply flowing.
    private func evictIfNeeded() {
        var excess = recency.count - keepAlive
        guard excess > 0 else { return }
        for k in recency {
            guard excess > 0, let c = clients[k], !c.isVisible, !c.isLoading else { continue }
            c.persistNow()
            c.disconnect()
            clients[k] = nil
            recency.removeAll { $0 == k }
            excess -= 1
        }
    }

    /// App lifecycle for the clients no screen owns right now.
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            for c in clients.values {
                c.persistNow()
                c.releasePresence()
            }
        case .active:
            // Only the unwatched ones — the visible chat kicks its own.
            for c in clients.values where !c.isVisible && c.isLoading {
                c.ensureConnected()
            }
        default:
            break
        }
    }

    /// Account removal: nothing may outlive the login that fetched it.
    func clearAll() {
        for c in clients.values { c.disconnect() }
        clients = [:]
        recency = []
    }
}
