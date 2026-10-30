import SwiftUI
import ReplayKit
import UserNotifications

/// Wraps the system broadcast picker. Tapping it lets the user start a
/// WHOLE-DEVICE screen broadcast that routes into our broadcast extension,
/// which keeps capturing even after the user leaves this app.
struct BroadcastPickerView: UIViewRepresentable {
    let extensionBundleID: String

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        v.preferredExtension = extensionBundleID
        v.showsMicrophoneButton = true    // system-level mic: survives other apps (YouTube), lock, everything
        // Make the embedded button fill the view and look tappable.
        for sub in v.subviews {
            if let button = sub as? UIButton {
                button.frame = v.bounds
                button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            }
        }
        return v
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

/// One tap → iOS's own "Start Broadcast" sheet, no screen in between
/// (2026-10-26, Manar: "the screenpipe needs two clicks; the massam goes
/// directly to where start screen broadcast goes"). ReplayKit has no API to
/// present that sheet, so a picker is parked invisibly in the key window and
/// its built-in button is fired — the standard, widely used pattern.
@MainActor
enum BroadcastLauncher {
    private static var picker: RPSystemBroadcastPickerView?

    static func present() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        let p = picker ?? RPSystemBroadcastPickerView(frame: CGRect(x: -100, y: -100, width: 44, height: 44))
        p.preferredExtension = SharedConfig.extensionBundleID
        p.showsMicrophoneButton = true
        p.alpha = 0.011
        if p.superview !== window { window.addSubview(p) }
        picker = p
        p.layoutIfNeeded()
        guard let button = p.subviews.compactMap({ $0 as? UIButton }).first else {
            GadkVoice.beacon("broadcast-sheet-nobutton"); return
        }
        button.sendActions(for: .touchUpInside)
        GadkVoice.beacon("broadcast-sheet")
    }
}


/// Watches the device's capture state (`UIScreen.isCaptured`: our broadcast,
/// any broadcast). When a capture that was running ENDS while the app is
/// alive, it reports it and posts a local "tap to restart" notification with
/// the same `mymu: broadcast` intent the Control widget and the server use,
/// so the user is one tap from the broadcast sheet. iOS gives no API to
/// restart a broadcast without that tap. The server's proactive loop covers
/// the case where the app itself is suspended (frames stop → push).
@MainActor
final class BroadcastWatch {
    static let shared = BroadcastWatch()
    private var observer: NSObjectProtocol?
    private var wasCaptured = UIScreen.main.isCaptured

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let now = UIScreen.main.isCaptured
            defer { self.wasCaptured = now }
            if now && !self.wasCaptured { GadkVoice.beacon("screen-capture-started") }
            if !now && self.wasCaptured {
                GadkVoice.beacon("screen-capture-ended")
                self.nudgeRestart()
            }
        }
    }

    private func nudgeRestart() {
        let content = UNMutableNotificationContent()
        content.title = "Screen broadcast stopped"
        content.body = "Your screen is no longer being recorded — tap to start the broadcast again."
        content.sound = .default
        content.categoryIdentifier = "MYMU_NUDGE"
        content.userInfo = ["mymu": "broadcast"]
        let req = UNNotificationRequest(identifier: "bcast-stopped-\(Int(Date().timeIntervalSince1970))",
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
