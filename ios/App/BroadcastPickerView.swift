import SwiftUI
import ReplayKit

/// Wraps the system broadcast picker. Tapping it lets the user start a
/// WHOLE-DEVICE screen broadcast that routes into our broadcast extension,
/// which keeps capturing even after the user leaves this app.
struct BroadcastPickerView: UIViewRepresentable {
    let extensionBundleID: String

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        v.preferredExtension = extensionBundleID
        v.showsMicrophoneButton = false   // we stream the mic ourselves
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
