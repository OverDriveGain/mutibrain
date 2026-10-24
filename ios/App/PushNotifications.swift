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
    // Reminders (mymu-voice reminder system, 2026-10-23): the server pushes
    // category MYMU_REMINDER with the reminder `text` + `id`. Two background
    // actions — "Snooze 10 min" re-schedules it through POST /reminders without
    // opening the app; "Done" just dismisses. A plain tap opens the app.
    private let reminderCategoryId = "MYMU_REMINDER"
    private let snoozeActionId = "SNOOZE"
    /// Set when a notification tap must land on the screen-capture sheet; PetView
    /// consumes it on appear (cold launch from the opener's "start the broadcast").
    static let pendingBroadcastKey = "mymuPendingBroadcast"
    private let doneActionId = "DONE"
    private let snoozeMinutes = 10.0
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
        let snooze = UNNotificationAction(identifier: snoozeActionId, title: "Snooze 10 min", options: [])
        let done = UNNotificationAction(identifier: doneActionId, title: "Done", options: [.destructive])
        let reminder = UNNotificationCategory(identifier: reminderCategoryId,
                                              actions: [snooze, done],
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category, reminder])

        requestAuthorizationAndRegister()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        // A token from a PREVIOUS install/environment (e.g. TestFlight → dev
        // build) is dead for this binary: tell the server to drop it so pushes
        // stop going to a token APNs still accepts but no app receives.
        if let old = UserDefaults.standard.string(forKey: tokenKey), !old.isEmpty, old != hex {
            unregisterToken(old)
        }
        UserDefaults.standard.set(hex, forKey: tokenKey)
        GadkVoice.beacon("apns-token-\(apnsEnvironment())")
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
        #if DEBUG
        // Screenshot/QA runs on the simulator: no permission alert over the UI.
        if ProcessInfo.processInfo.environment["MYAGENT_QA"] == "1" { return }
        #endif
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

    private func unregisterToken(_ hex: String) {
        let t = GadkVoice.feedTarget()
        guard !t.token.isEmpty, !t.token.contains("__") else { return }
        var comps = URLComponents(url: t.origin.appendingPathComponent("push/apns/unregister"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "app", value: t.app),
                            .init(name: "token", value: t.token)]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": hex])
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            GadkVoice.beacon("apns-unreg-\((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }.resume()
    }

    /// Which APNs gateway this binary's tokens belong to. The TRUTH is the
    /// `aps-environment` in the embedded provisioning profile — "development"
    /// (sandbox gateway) for any dev-signed install, incl. a Release-configuration
    /// build installed over devicectl (build 16 reported "production" from the
    /// old #if DEBUG guess and the server pushed into the void). TestFlight /
    /// App Store carry "production". Falls back to the build-configuration guess.
    private func apnsEnvironment() -> String {
        if let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
           let data = FileManager.default.contents(atPath: path),
           let text = String(data: data, encoding: .isoLatin1),
           let range = text.range(of: "<key>aps-environment</key>") {
            let tail = text[range.upperBound...]
            if let open = tail.range(of: "<string>"), let close = tail.range(of: "</string>"),
               open.upperBound <= close.lowerBound {
                let value = tail[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                return value == "development" ? "sandbox" : "production"
            }
        }
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
        // Opener button pressed while the phone wasn't broadcasting: the widget's
        // notification sends the user HERE to start it (Manar 2026-10-23). Flag +
        // post — the flag covers a cold launch (PetView isn't listening yet), the
        // post covers the warm case.
        if (info["mymu"] as? String) == "broadcast" {
            UserDefaults.standard.set(true, forKey: PushNotifications.pendingBroadcastKey)
            NotificationCenter.default.post(name: .mymuShowScreenpipe, object: nil)
            GadkVoice.beacon("opener-to-broadcast")
            completionHandler()
            return
        }
        if response.actionIdentifier == snoozeActionId {
            snoozeReminder(text: info["text"] as? String ?? "",
                           body: response.notification.request.content.body,
                           done: completionHandler)
            return
        }
        if response.actionIdentifier == doneActionId {
            GadkVoice.beacon("rem-done")
            completionHandler()
            return
        }
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

    /// "Snooze 10 min" on a reminder: set the SAME reminder again, ten minutes
    /// from now, through the shell's reminder system (POST /reminders). Runs in
    /// the background handler — the app never comes forward.
    private func snoozeReminder(text: String, body: String, done: @escaping () -> Void) {
        let t = GadkVoice.feedTarget()
        let what = text.isEmpty ? body : text
        guard !what.isEmpty, !t.token.isEmpty, !t.token.contains("__") else { done(); return }
        var comps = URLComponents(url: t.origin.appendingPathComponent("reminders"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "app", value: t.app),
                            .init(name: "token", value: t.token)]
        guard let url = comps.url else { done(); return }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let when = fmt.string(from: Date().addingTimeInterval(snoozeMinutes * 60))
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": what, "when": when])
        let task = URLSession.shared.dataTask(with: req) { _, resp, _ in
            // fires exactly once — also on cancel (with an error) — so done()
            // is always called and never twice
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            GadkVoice.beacon("rem-snooze-\(code)")
            done()
        }
        task.resume()
        // safety: don't hold the background handler open forever
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if task.state == .running { task.cancel() }
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
