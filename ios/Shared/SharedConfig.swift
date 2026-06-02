import Foundation

/// Config shared between the main app and the broadcast extension via an
/// App Group. The app writes the server address + token; the extension reads
/// them when a broadcast starts (the two run in separate processes).
struct SharedConfig {
    let base: String
    let token: String

    /// Must match the App Group in both targets' entitlements.
    static let appGroup = "group.com.example.aiassistant"
    static let extensionBundleID = "com.example.aiassistant.ScreenBroadcast"

    var audioURL: URL { URL(string: base.replacingOccurrences(of: "http", with: "ws") + "/v1/audio")! }
    var screenURL: URL { URL(string: base.replacingOccurrences(of: "http", with: "ws") + "/v1/screen")! }

    static func load() -> SharedConfig {
        let d = UserDefaults(suiteName: appGroup)
        // Default to a LAN address; change it in the app UI before first run.
        let base = d?.string(forKey: "serverBase") ?? "ws://192.168.1.10:8000"
        let token = d?.string(forKey: "token") ?? "dev-secret-token"
        return SharedConfig(base: base, token: token)
    }

    static func save(base: String, token: String) {
        let d = UserDefaults(suiteName: appGroup)
        d?.set(base, forKey: "serverBase")
        d?.set(token, forKey: "token")
    }
}
