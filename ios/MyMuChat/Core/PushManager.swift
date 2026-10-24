import UIKit
import UserNotifications
import os

/// The client half of agent-reply push notifications (server contract locked
/// 2026-09-13: POST/DELETE /api/push/register, APNs payload carrying
/// `sessionId` + `projectId`, alert title = agent name).
///
/// Everything here is safe while the server has no APNs key yet: registration
/// rows sit dormant server-side and no pushes arrive.
@MainActor
final class PushManager: NSObject, ObservableObject {
    static let shared = PushManager()

    /// Set when the user taps a notification; MainTabView navigates to it and
    /// clears it. Published so the observation is a plain onReceive.
    @Published var pendingTarget: ChatTarget?

    /// Hex APNs token once the system hands it over; re-registered against
    /// every saved account's server (each host pushes for its own agents).
    private var deviceToken: String?

    func bootstrap() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Ask for permission (first time) and register with APNs. Called when the
    /// signed-in UI appears — a permission prompt at cold launch has no context.
    func enable() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                if granted { UIApplication.shared.registerForRemoteNotifications() }
            case .authorized, .provisional, .ephemeral:
                UIApplication.shared.registerForRemoteNotifications()
            default:
                break  // denied — respect it; Settings is the way back
            }
        }
    }

    /// APNs delivered the device token (via the app delegate). Register it on
    /// every saved account's server; best-effort per host, a dead host skips.
    func tokenReceived(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        registerEverywhere()
    }

    /// Idempotent: safe to call again after adding an account or re-login.
    func registerEverywhere() {
        guard let hex = deviceToken else { return }
        guard let data = AppGroup.defaults.data(forKey: "mymu.accounts"),
              let accounts = try? JSONDecoder().decode([SavedAccount].self, from: data) else { return }
        for acct in accounts {
            guard let tok = Keychain.get("auth-token|\(acct.id)", shared: true) else { continue }
            Task {
                try? await APIClient(token: tok, origin: acct.serverOrigin)
                    .pushRegister(deviceToken: hex)
            }
        }
    }

    /// Sign-out of one account: stop that server pushing to this device.
    func unregister(account: SavedAccount, token: String) {
        guard let hex = deviceToken else { return }
        Task {
            try? await APIClient(token: token, origin: account.serverOrigin)
                .pushUnregister(deviceToken: hex)
        }
    }
}


/// Breadcrumbs for the push path, readable from a Mac via Console/log stream —
/// "tapped and nothing happened" must never be undiagnosable again.
enum PushLog {
    static let logger = Logger(subsystem: "com.mymu.app", category: "push")
}

extension PushManager: UNUserNotificationCenterDelegate {
    /// Tap on a notification → open that conversation. The payload carries the
    /// session/project ids top-level; the alert title IS the agent name.
    /// Classic completion-handler signature on purpose: the async variant is
    /// the newer path and a cold-launch tap silently failed with it in the
    /// field (2026-09-13).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let sessionId = (content.userInfo["sessionId"] as? String) ?? ""
        let projectId = (content.userInfo["projectId"] as? String)
            ?? (sessionId.isEmpty ? "" : "remote:\(sessionId)")
        let title = content.title.isEmpty ? "Agent" : content.title
        PushLog.logger.info("tap received session=\(sessionId, privacy: .public) project=\(projectId, privacy: .public)")
        if !sessionId.isEmpty {
            let target = ChatTarget(sessionId: sessionId, projectId: projectId,
                                    isRemote: true, title: title)
            Task { @MainActor in PushManager.shared.pendingTarget = target }
        }
        completionHandler()
    }

    /// Foreground arrivals for OTHER sessions still show as a banner (the
    /// server already suppresses the session being watched live).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
