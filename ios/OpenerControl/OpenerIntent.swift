import AppIntents
import Foundation
import UIKit
import UserNotifications

/// The action behind the Control Center button. Runs in the background (does NOT
/// open the app): it asks the agent server to write an opener for whatever is on
/// the phone's screen RIGHT NOW (read from the live screen broadcast) and copies
/// it to the clipboard so the user can paste it straight into Hinge.
///
/// The server also pushes the opener as a share (APNs Copy action) — that's the
/// fallback if this background call runs out of time before it can copy.
struct WriteOpenerIntent: AppIntent {
    static var title: LocalizedStringResource = "Write an opener"
    static var description = IntentDescription(
        "Ask ProAgent to write an opener for what's on your screen and copy it to the clipboard.")
    // Background: never leave the app the user is in (that's the whole point).
    static var openAppWhenRun: Bool = false

    // Transient "Reading…" placeholder id — reused so a slow load shows ONE
    // updating banner. The RESULT, by contrast, gets a UNIQUE id every tap
    // (see finalNotify) — iOS updates a same-id notification SILENTLY (no banner,
    // no sound), so reusing one id made only the first tap ever alert.
    private let feedID = "proagent-opener"

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await progress(body: "Reading your screen…")
        let t = SharedConfig.agentTarget()
        guard t.loggedIn else {
            await finalNotify(title: "ProAgent", subtitle: "", body: "Open MyAgent and log in first.")
            return .result(dialog: "Open MyAgent and log in first.")
        }
        guard let url = t.url(path: "screen/opener",
                              extra: [.init(name: "which", value: "Hinge")]) else {
            await finalNotify(title: "ProAgent", subtitle: "", body: "Couldn't build the request.")
            return .result(dialog: "Couldn't build the request.")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let opener = (obj?["opener"] as? String) ?? ""
            // what screen did it actually read? (so it's obvious when it's the
            // desktop, not Hinge — i.e. the phone broadcast isn't feeding us)
            let agent = (obj?["agent"] as? String) ?? ""
            let ctx = obj?["context"] as? [String: Any]
            let app = (ctx?["app"] as? String) ?? ""
            let from = [app, agent].filter { !$0.isEmpty }.joined(separator: " · ")
            // The phone's screen isn't being broadcast (server: needs_broadcast /
            // not connected) → send the user to the broadcast control. A Control
            // Center intent that runs in the background cannot open the app
            // conditionally, so the PROMPT is the notification: tapping it opens
            // MyAgent straight onto the screen-capture sheet (PushNotifications
            // sees userInfo.mymu == "broadcast" → mymuShowScreenpipe). Manar
            // 2026-10-23: "when the screen is not recording, take me there".
            let needsBroadcast = (obj?["needs_broadcast"] as? Bool) ?? false
            if needsBroadcast || (obj?["connected"] as? Bool) == false {
                await finalNotify(title: "ProAgent — your screen isn't being recorded",
                                  subtitle: "Tap to start the screen broadcast",
                                  body: (obj?["reason"] as? String)
                                      ?? "Open MyAgent, start the broadcast, then press the button again.",
                                  userInfo: ["mymu": "broadcast"])
                return .result(dialog: "Your screen isn't being recorded — tap the notification to start the broadcast.")
            }
            if code == 200, !opener.isEmpty {
                UIPasteboard.general.string = opener
                await finalNotify(title: "✨ Opener copied — paste into Hinge",
                                  subtitle: from.isEmpty ? "" : "read: \(from)", body: opener)
                return .result(dialog: "Opener copied ✓ — paste into Hinge.")
            }
            let reason = (obj?["reason"] as? String)
                ?? "Nothing to write — is the MyAgent broadcast running on this screen?"
            let tail = from.isEmpty ? "" : "  (read: \(from))"
            await finalNotify(title: "ProAgent — nothing to copy", subtitle: "", body: reason + tail)
            return .result(dialog: "\(reason)")
        } catch {
            await finalNotify(title: "ProAgent — couldn't reach the server", subtitle: "",
                              body: "Check your connection + that the MyAgent broadcast is running.")
            return .result(dialog: "Couldn't reach ProAgent. Check the screen broadcast is running.")
        }
    }

    /// The transient in-progress banner — SAME id each time so a slow "Reading…"
    /// updates in place rather than stacking. It is removed by finalNotify before
    /// the result is posted.
    private func progress(body: String) async {
        let content = UNMutableNotificationContent()
        content.title = "🔎 ProAgent"
        content.body = String(body.prefix(300))
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let req = UNNotificationRequest(identifier: feedID, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    /// The RESULT notification. Clears the "Reading…" placeholder, then posts with
    /// a UNIQUE identifier so EVERY tap pops a fresh banner + sound (a same-id
    /// update would be silent). Marked time-sensitive so it can break through a
    /// Focus WHEN the entitlement is present; without it, a Focus still silences
    /// it — turn Focus off to see it (the opener is on the clipboard regardless).
    private func finalNotify(title: String, subtitle: String, body: String,
                             userInfo: [String: Any] = [:]) async {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [feedID])
        center.removePendingNotificationRequests(withIdentifiers: [feedID])
        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty { content.subtitle = subtitle }
        if !userInfo.isEmpty { content.userInfo = userInfo }
        content.body = String(body.prefix(300))
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let uid = "proagent-opener-\(UUID().uuidString)"
        let req = UNNotificationRequest(identifier: uid, content: content, trigger: nil)
        try? await center.add(req)
    }
}
