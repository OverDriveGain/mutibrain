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
    // MUST equal the ScreenBroadcast.appex's real CFBundleIdentifier, else
    // RPSystemBroadcastPickerView.preferredExtension matches nothing and the
    // picker falls back to listing EVERY broadcast app (ChatGPT/Binance/…),
    // forcing the user to choose. The app is com.manarz.myagent, so the
    // extension is com.manarz.myagent.ScreenBroadcast (verified in the built
    // appex Info.plist 2026-09-20). The App Group id below is separate and
    // legitimately still uses the older "aiassistant" name.
    static let extensionBundleID = "com.manarz.myagent.ScreenBroadcast"

    // ---- Compile-time defaults (source of truth for the broadcast extension) ----
    static let defaultBase = "http://192.168.0.229:8090"   // berlin LAN; use http://10.10.0.2:8090 on WireGuard
    static let defaultAgentId = "iphone-manar"
    // Since the single-env cutover the voice backend needs ?app= + ?token= (the
    // same tokenized URL the /voice QR encodes). Paste the full URL in Settings,
    // or replace the placeholder at build time (same pattern as the token below).
    static let defaultGadk = "https://agent.kaxtus.com/voice?app=manar&token=__GADK_TOKEN__"
    // MyMu (CCUI) chat embedded in the Chat tab. The agent-view share token
    // (?token=…) logs the webview straight into the focused special-agent
    // conversation — no manual login. Injected at build time like the others.
    static let defaultChat = "https://code.kaxtus.com/?token=__MYMU_TOKEN__"
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

    // DEAD legacy WebSocket URLs (pre-screenpipe transport). The `/v1/audio` and
    // `/v1/screen` WS endpoints never existed on the central server (every dial
    // got HTTP 403). The mic now posts encoded segments to `ingestAudioURL`
    // (/ingest-audio) and the screen posts JPEGs to `ingestURL` (/ingest) — the
    // real screenpipe ingest API (the screenpipe massam). Kept only so any
    // straggler reference still compiles; no live code uses them.
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

/// Cross-process capture counters for the Screenpipe massam's debug panel. The
/// screen frames are POSTed from the BROADCAST EXTENSION (a separate process),
/// so the app can only see how capture is doing through the shared App Group
/// store. Written by IngestClient / AudioIngestClient, read by ScreenpipeView.
/// Falls back to process-local defaults if the group isn't provisioned (then
/// the extension's screen counters simply stay invisible to the app).
enum CaptureStats {
    private static var d: UserDefaults { UserDefaults(suiteName: SharedConfig.appGroup) ?? .standard }

    static func recordScreen(ok: Bool, code: Int) { record("screen", ok: ok, code: code) }
    static func recordAudio(ok: Bool, code: Int) { record("audio", ok: ok, code: code) }

    private static func record(_ kind: String, ok: Bool, code: Int) {
        let now = Date().timeIntervalSince1970
        if ok {
            d.set(d.integer(forKey: "sp.\(kind).sent") + 1, forKey: "sp.\(kind).sent")
            d.set(now, forKey: "sp.\(kind).lastOKAt")
            d.removeObject(forKey: "sp.\(kind).lastErr")
        } else {
            d.set(d.integer(forKey: "sp.\(kind).fail") + 1, forKey: "sp.\(kind).fail")
            d.set("HTTP \(code)", forKey: "sp.\(kind).lastErr")
            d.set(now, forKey: "sp.\(kind).lastErrAt")
        }
    }

    static func sent(_ kind: String) -> Int { d.integer(forKey: "sp.\(kind).sent") }
    static func failed(_ kind: String) -> Int { d.integer(forKey: "sp.\(kind).fail") }
    static func lastOK(_ kind: String) -> Date? {
        let t = d.double(forKey: "sp.\(kind).lastOKAt"); return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    static func lastErr(_ kind: String) -> String? { d.string(forKey: "sp.\(kind).lastErr") }
}
