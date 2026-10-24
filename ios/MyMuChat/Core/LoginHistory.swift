import Foundation

/// One remembered (host, username) pair from a past successful login.
struct LoginMemory: Codable, Identifiable, Equatable {
    let origin: String
    let username: String
    var id: String { origin + "|" + username }
    /// Chip label: host without the scheme noise (a distinct port stays).
    var hostLabel: String {
        origin.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }
}

/// Hosts + usernames from past SUCCESSFUL logins, surviving sign-out (Manar,
/// 2026-09-19: "I logout from a host, then I log again, no rememberance").
/// Signing out rightly deletes the account and its token — but it must not
/// erase the MEMORY that the host exists; retyping full origins was the pain.
/// Passwords are never stored here; this is autocomplete, not credentials.
@MainActor
enum LoginHistory {
    private static let key = "mymu.loginHistory"
    private static let cap = 12

    static func all() -> [LoginMemory] {
        guard let data = AppGroup.defaults.data(forKey: key),
              let items = try? JSONDecoder().decode([LoginMemory].self, from: data) else { return [] }
        return items
    }

    /// Most-recent-first upsert, called on every successful login.
    static func record(origin: String, username: String) {
        let entry = LoginMemory(origin: Config.normalize(origin), username: username)
        var items = all().filter { $0.id != entry.id }
        items.insert(entry, at: 0)
        if items.count > cap { items = Array(items.prefix(cap)) }
        if let data = try? JSONEncoder().encode(items) {
            AppGroup.defaults.set(data, forKey: key)
        }
    }
}
