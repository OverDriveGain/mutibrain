import Foundation
import UIKit
import UserNotifications

/// APNs push for agent text shares (2026-09-25).
///
/// The web-push path in the voice shell only reaches a home-screen PWA; this
/// native app never got share notifications while it was closed, so the only
/// way to copy a shared text was to open the app. APNs fixes that on the native
/// surface — and better: the "Copy" notification action runs in the BACKGROUND
/// (`options: []`, not `.foreground`), so the user copies the shared text
/// straight from the banner / lock screen WITHOUT opening the app.
///
/// Flow:
///   1. request notification auth + registerForRemoteNotifications()
///   2. didRegister… → POST the device token to {origin}/push/apns/register
///      (subscriber-token authed, same target GadkVoice talks to)
///   3. server sends an alert (category MYMU_SHARE) carrying `text`
///   4. tap "Copy" → write UIPasteboard in the background handler; tap the body
///      → open the app (the embed's Files box / copy banner shows the share).
final class PushNotifications: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let shared = PushNotifications()

    private let categoryId = "MYMU_SHARE"
    private let copyActionId = "COPY"
    private let tokenKey = "apnsDeviceToken"   // hex, remembered so we can
                                               // re-register when the subscriber changes

    // MARK: - App lifecycle

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // The MYMU_SHARE category with a background Copy action. The action has
        // NO .foreground option, so iOS launches us in the background to run the
        // handler and never brings the app forward — a true copy-from-notification.
        let copy = UNNotificationAction(identifier: copyActionId, title: "Copy", options: [])
        let category = UNNotificationCategory(identifier: categoryId,
                                              actions: [copy],
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])

        requestAuthorizationAndRegister()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: tokenKey)
        GadkVoice.beacon("apns-token")
        postToken(hex)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        GadkVoice.beacon("apns-fail-\(error.localizedDescription.prefix(40))")
    }

    // MARK: - Registration

    /// Ask for permission (once granted, iOS remembers) and register for remote
    /// notifications. Safe to call repeatedly — e.g. on every foreground.
    func requestAuthorizationAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// Re-POST the remembered device token to the CURRENT subscriber's endpoint.
    /// Call after a QR login / subscriber switch so shares for the new
    /// subscriber reach this device (the APNs token itself is unchanged).
    func reregisterCurrentSubscriber() {
        if let hex = UserDefaults.standard.string(forKey: tokenKey), !hex.isEmpty {
            postToken(hex)
        } else {
            // no token yet (permission not granted / first run) — try again
            requestAuthorizationAndRegister()
        }
    }

    private func postToken(_ hex: String) {
        let t = GadkVoice.feedTarget()
        guard !t.token.isEmpty, !t.token.contains("__") else { return }  // pre-login / placeholder
        var comps = URLComponents(url: t.origin.appendingPathComponent("push/apns/register"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "app", value: t.app),
                            .init(name: "token", value: t.token)]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let env = apnsEnvironment()
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": hex, "env": env])
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            GadkVoice.beacon("apns-reg-\(code)")
        }.resume()
    }

    /// TestFlight / App Store builds use the production APNs environment; a debug
    /// build installed straight from Xcode uses sandbox. The embedded provisioning
    /// profile's `aps-environment` tells us which.
    private func apnsEnvironment() -> String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Foreground arrival: still show the banner + sound so an in-app share is
    /// never silent (the webview's own banner also handles it — harmless overlap).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// The user acted on a notification. "Copy" writes the clipboard in the
    /// background (app never opens); the default tap opens the app and the
    /// embed's copy banner / Files box surfaces the share.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        guard response.actionIdentifier == copyActionId else {
            completionHandler()   // default/other → app opens; nothing else to do
            return
        }
        let text = info["text"] as? String ?? ""
        let truncated = (info["text_truncated"] as? Bool) ?? false
        if !truncated {
            UIPasteboard.general.string = text
            GadkVoice.beacon("apns-copy")
            completionHandler()
            return
        }
        // truncated in the payload — fetch the full text from the server, then copy
        fetchFullShareText(id: info["id"] as? String ?? "", fallback: text) { full in
            UIPasteboard.general.string = full
            GadkVoice.beacon("apns-copy-full")
            completionHandler()
        }
    }

    private func fetchFullShareText(id: String, fallback: String,
                                    done: @escaping (String) -> Void) {
        let t = GadkVoice.feedTarget()
        guard !id.isEmpty, !t.token.isEmpty else { done(fallback); return }
        var comps = URLComponents(url: t.origin.appendingPathComponent("shares/list"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "app", value: t.app),
                            .init(name: "token", value: t.token)]
        guard let url = comps.url else { done(fallback); return }
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let shares = obj["shares"] as? [[String: Any]],
                  let hit = shares.first(where: { ($0["id"] as? String) == id }),
                  let full = hit["text"] as? String else {
                done(fallback); return
            }
            done(full)
        }
        task.resume()
        // safety: don't hold the background handler open forever
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak task] in
            if task?.state == .running { task?.cancel(); done(fallback) }
        }
    }
}
