import Foundation

/// Per-conversation composer drafts (Manar, 2026-09-19): text typed but not
/// sent survives leaving the chat — switching agents and coming back finds
/// the draft where it was left, the Mail/Telegram convention. Remote chats
/// key by AGENT (projectId): session ids rotate on agent restarts and the
/// draft belongs to the agent, not the socket. Local chats key by session.
/// UserDefaults is plenty — drafts are in-flight typing, not documents — and
/// empty text removes its entry so the store never accumulates.
enum DraftStore {
    private static func key(_ id: String) -> String { "mymu.draft.\(id)" }

    static func load(_ id: String) -> String? {
        guard !id.isEmpty else { return nil }
        let s = UserDefaults.standard.string(forKey: key(id))
        return (s?.isEmpty == false) ? s : nil
    }

    static func save(_ text: String, for id: String) {
        guard !id.isEmpty else { return }
        if text.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(id))
        } else {
            UserDefaults.standard.set(text, forKey: key(id))
        }
    }

    /// A type-to-switch hands the draft to another agent — the origin's copy
    /// must not linger and greet the user as a stale duplicate later.
    static func clear(_ id: String) { save("", for: id) }
}
