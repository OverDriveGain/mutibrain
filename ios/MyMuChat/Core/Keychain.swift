import Foundation
import Security

/// Minimal Keychain wrapper for the auth token (a credential — belongs in the
/// Keychain, not UserDefaults).
enum Keychain {
    private static let service = "com.mymu.app"

    /// `shared: true` stores the item in the app-group access group, readable
    /// by the share extension too. Account tokens live there; the legacy
    /// app-private items stay where they are.
    private static func baseQuery(_ account: String, shared: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if shared, AppGroup.keychainSharing { query[kSecAttrAccessGroup as String] = AppGroup.id }  // HOST PATCH, see AppGroup
        return query
    }

    static func set(_ value: String?, for account: String, shared: Bool = false) {
        guard let value, let data = value.data(using: .utf8) else {
            delete(account, shared: shared)
            return
        }
        let query = baseQuery(account, shared: shared)
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func get(_ account: String, shared: Bool = false) -> String? {
        var query = baseQuery(account, shared: shared)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String, shared: Bool = false) {
        SecItemDelete(baseQuery(account, shared: shared) as CFDictionary)
    }
}
