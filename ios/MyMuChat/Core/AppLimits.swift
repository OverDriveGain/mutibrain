import Foundation

/// Server-authoritative file-size limits, fetched at runtime from `GET /api/limits`.
///
/// The app deliberately holds NO hardcoded cap as the source of truth: the value
/// below is only a cold-start fallback until the server answers. This is what
/// lets the limit change server-side (a `CCUI_MAX_ATTACHMENT_MB` env + restart)
/// and take effect on already-shipped app builds — no App Store resubmission.
///
/// Plain lock-guarded value (not an actor / not @Published): it's read at
/// attach-time from the composer and written once per refresh, so it needs to be
/// readable from any context without isolation friction, not reactive.
final class AppLimits: @unchecked Sendable {
    static let shared = AppLimits()

    private let lock = NSLock()
    private var _attachmentBytes = 64 * 1024 * 1024  // fallback only; server overrides

    var attachmentBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return _attachmentBytes
    }

    /// Human label for the current cap, e.g. "64 MB", for error copy.
    var attachmentLabel: String { "\(attachmentBytes / (1024 * 1024)) MB" }

    private func set(_ bytes: Int) {
        lock.lock(); _attachmentBytes = bytes; lock.unlock()
    }

    /// Refresh from the active account's server. Best-effort: on any failure the
    /// last-known (or fallback) value stands, so composing never breaks offline.
    func refresh(token: String?, origin: String?) async {
        if let bytes = try? await APIClient(token: token, origin: origin).attachmentLimitBytes(), bytes > 0 {
            set(bytes)
        }
    }
}
