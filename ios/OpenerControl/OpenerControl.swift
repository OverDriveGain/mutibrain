import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center button (iOS 18+). Add it via Control Center → Edit → ＋ →
/// "ProAgent — Opener". Tapping it runs WriteOpenerIntent in the background —
/// which writes an opener for what's on screen and copies it — WITHOUT leaving
/// the app you're in (e.g. Hinge). Control Center floats over every app, so it
/// works on top of Hinge.
///
/// The whole extension targets iOS 18 (see project.yml deploymentTarget), so no
/// per-symbol @available guards are needed here.
struct OpenerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.manarz.myagent.opener") {
            ControlWidgetButton(action: WriteOpenerIntent()) {
                Label("Opener", systemImage: "sparkles")
            }
        }
        .displayName("ProAgent — Opener")
        .description("Write an opener for what's on your screen.")
    }
}

@main
struct OpenerControlBundle: WidgetBundle {
    var body: some Widget {
        OpenerControl()
    }
}
