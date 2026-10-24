import Foundation

/// The app group shared between the main app and the share extension. Saved
/// accounts (UserDefaults) and their tokens (Keychain, with the group as the
/// access group) live HERE so the extension can send as any signed-in account.
enum AppGroup {
    // HOST PATCH (MyAgent app, 2026-10-24): this client is vendored into the
    // MyAgent app, whose dev-signed builds carry NO app-group entitlement
    // (headless provisioning can't register one — see sp_deploy2.sh). The
    // MyMu group id would be a foreign group anyway. Use the host's own group
    // name for the defaults domain (works as a plain domain without the
    // entitlement) and keep Keychain items app-private, or every token write
    // fails with errSecMissingEntitlement and the sign-in never sticks.
    static let id = SharedConfig.appGroup
    static let keychainSharing = false
    /// Falls back to .standard only if the entitlement is missing entirely
    /// (never in a correctly signed build) — better a private store than a crash.
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
}
