import Foundation

/// Config shared between the main app and the broadcast extension.
///
/// This file is compiled into BOTH targets, so the `static let` defaults below
/// are available in both processes at compile time — which matters because free
/// (personal-team) signing can't provision an App Group, so the broadcast
/// extension can NOT read values the app writes to UserDefaults at runtime. The
/// extension therefore relies on these compile-time defaults; the in-app fields
/// are a convenience that only affects the app process.
struct SharedConfig {
    let base: String        // screenpipe central base URL, e.g. http://192.168.0.229:8090
    let token: String       // screenpipe agent bearer token (spk_...)
    let agentId: String     // screenpipe agent_id
    let gadk: String        // gadk voice URL (the pet's brain)

    static let appGroup = "group.com.manarz.aiassistant"
    static let extensionBundleID = "com.manarz.aiassistant.ScreenBroadcast"

    // ---- Compile-time defaults (source of truth for the broadcast extension) ----
    static let defaultBase = "http://192.168.0.229:8090"   // berlin LAN; use http://10.10.0.2:8090 on WireGuard
    static let defaultAgentId = "iphone-manar"
    // Since the single-env cutover the voice backend needs ?app= + ?token= (the
    // same tokenized URL the /voice QR encodes). Paste the full URL in Settings,
    // or replace the placeholder at build time (same pattern as the token below).
    static let defaultGadk = "https://agent.kaxtus.com/voice?app=manar&token=__GADK_TOKEN__"
    // Injected at build time (see build pipeline); committed value is empty so no
    // secret lives in git. Set this on the build host before compiling for device.
    static let defaultToken = "__SCREENPIPE_TOKEN__"

    /// Shared store when the App Group is provisioned (paid team); otherwise the
    /// process-local standard defaults (free team — does NOT cross app↔extension).
    private static var store: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    var baseURL: URL { URL(string: base) ?? URL(string: Self.defaultBase)! }
    var ingestURL: URL { baseURL.appendingPathComponent("ingest") }
    var ingestAudioURL: URL { baseURL.appendingPathComponent("ingest-audio") }
    var gadkURL: URL { URL(string: gadk) ?? URL(string: Self.defaultGadk)! }

    // Legacy WebSocket URLs (pre-screenpipe transport). Still referenced by the
    // mic path (AudioStreamer), which is phase 2 — not yet wired to /ingest-audio.
    var audioURL: URL { URL(string: base.replacingOccurrences(of: "http", with: "ws") + "/v1/audio")! }
    var screenURL: URL { URL(string: base.replacingOccurrences(of: "http", with: "ws") + "/v1/screen")! }

    static func load() -> SharedConfig {
        let d = store
        let base = nonEmpty(d.string(forKey: "serverBase")) ?? defaultBase
        let token = nonEmpty(d.string(forKey: "token")) ?? defaultToken
        let agentId = nonEmpty(d.string(forKey: "agentId")) ?? defaultAgentId
        let gadk = nonEmpty(d.string(forKey: "gadkURL")) ?? defaultGadk
        return SharedConfig(base: base, token: token, agentId: agentId, gadk: gadk)
    }

    static func save(base: String, token: String, agentId: String, gadk: String) {
        let d = store
        d.set(base, forKey: "serverBase")
        d.set(token, forKey: "token")
        d.set(agentId, forKey: "agentId")
        d.set(gadk, forKey: "gadkURL")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
