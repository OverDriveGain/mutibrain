import SwiftUI

/// How much the agent may do without asking — the web client's composer
/// "permission menu", sent as `options.permissionMode` on `chat.send`.
///
/// The server spreads client options straight through to the provider runtime
/// (`chat-websocket.service.ts`), where each runtime maps the mode onto its own
/// controls: the Claude SDK takes it verbatim, OpenCode turns it into
/// `--agent plan` / `--auto` / `OPENCODE_PERMISSION`, Codex into a sandbox +
/// approval policy. So the phone only has to name the mode correctly.
///
/// `auto` exists in the server's matrix for Claude only and is deliberately
/// omitted here: it has no distinct meaning to a phone user next to
/// `acceptEdits`, and offering a mode that silently does nothing on three of
/// four providers is worse than not offering it.
enum PermissionMode: String, CaseIterable, Identifiable {
    case `default`
    case acceptEdits
    case plan
    case bypassPermissions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .default: return "Ask each time"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan only"
        case .bypassPermissions: return "Bypass permissions"
        }
    }

    /// Shown under the label in the picker — the consequence, not a restatement.
    var detail: String {
        switch self {
        case .default: return "Prompt before tools that change anything"
        case .acceptEdits: return "File edits go through without asking"
        case .plan: return "Plan a change; make none"
        case .bypassPermissions: return "Never ask. Use with care"
        }
    }

    var symbol: String {
        switch self {
        case .default: return "hand.raised"
        case .acceptEdits: return "pencil"
        case .plan: return "list.bullet.clipboard"
        case .bypassPermissions: return "bolt"
        }
    }

    /// Tint for the composer control — `bypassPermissions` earns a warning
    /// colour because it is the one mode that can act destructively unattended.
    var tint: Color {
        switch self {
        case .default: return Theme.mutedText
        case .acceptEdits: return Theme.primary
        case .plan: return Theme.primary
        case .bypassPermissions: return Theme.danger
        }
    }
}

/// Per-session persistence, mirroring the web client's
/// `permissionMode-<sessionId>` / `permissionMode-last` pair: a conversation
/// remembers the mode it was last run with, and a NEW conversation inherits the
/// last mode you chose rather than silently resetting to "ask".
enum PermissionModeStore {
    private static let lastKey = "mymu.permissionMode.last"
    private static func key(_ sessionId: String) -> String { "mymu.permissionMode.\(sessionId)" }

    static func load(sessionId: String) -> PermissionMode {
        if let raw = UserDefaults.standard.string(forKey: key(sessionId)),
           let mode = PermissionMode(rawValue: raw) { return mode }
        if let raw = UserDefaults.standard.string(forKey: lastKey),
           let mode = PermissionMode(rawValue: raw) { return mode }
        return .default
    }

    static func save(_ mode: PermissionMode, sessionId: String) {
        UserDefaults.standard.set(mode.rawValue, forKey: key(sessionId))
        UserDefaults.standard.set(mode.rawValue, forKey: lastKey)
    }
}
