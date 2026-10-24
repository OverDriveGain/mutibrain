import SwiftUI

/// Which CLI harness drives a session.
///
/// Two truthful sources, tried in this order:
/// 1. The session-id routing prefix — the scheme the SERVER routes by
///    (oc-client.js `ocs_`, cx-client.js `cxs_`, the Claude relay's
///    `cse_`/`session_`). Covers live agents.
/// 2. The session row's `provider` field — real for LOCAL sessions (each is
///    read from its provider's own session store). NOT trusted for remote
///    agents, whose rows hardcode 'claude'; those are covered by (1) anyway.
///
/// Badges are the SAME vendor logos the web product's llm-provider-logo
/// component ships, ported as vector assets, so the app and web read
/// identically. (Mild App Review 5.2.1 exposure accepted knowingly — the marks
/// indicate interoperability, and the product family already displays them.)
enum Harness: String {
    case claude, opencode, codex, cursor

    init?(sessionId: String) {
        if sessionId.hasPrefix("ocs_") { self = .opencode }
        else if sessionId.hasPrefix("cxs_") { self = .codex }
        else if sessionId.hasPrefix("cse_") || sessionId.hasPrefix("session_") { self = .claude }
        else { return nil }
    }

    init?(provider: String?) {
        guard let provider, let h = Harness(rawValue: provider.lowercased()) else { return nil }
        self = h
    }

    /// Prefix first (authoritative), provider field second (local sessions).
    init?(sessionId: String, provider: String?) {
        if let h = Harness(sessionId: sessionId) { self = h }
        else if let h = Harness(provider: provider) { self = h }
        else { return nil }
    }

    var assetName: String { "harness-\(rawValue)" }

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .opencode: return "OpenCode"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }
}

/// The harness logo, sized to sit under a row's leading icon tile.
struct HarnessBadge: View {
    let harness: Harness

    var body: some View {
        Image(harness.assetName)
            .resizable()
            .scaledToFit()
            .frame(width: 15, height: 15)
            .accessibilityLabel(harness.label)
    }
}
