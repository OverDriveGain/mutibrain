import SwiftUI

@main
struct AIAssistantApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CrashReporter.install()
        // If the previous run died, report what killed it (journal beacon +
        // a structured POST /report with the death-context breadcrumbs).
        CrashReporter.reportIfCrashed()
        // Build tag: proves in the journal WHICH build is on the phone (we
        // once spent a session debugging an old build believed new).
        GadkVoice.beacon(AppBuild.tag)
        ReportClient.flush()   // deliver anything still queued from offline runs
        ChatURLSync.run()      // server-driven Chat tab token (voice /config)
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                PetView()
                    .tabItem { Label("Buddy", systemImage: "mic.fill") }
                    .onAppear { AudioStreamer.shared.autoStartIfEnabled() }
                AgentChatTab()   // native MyMu chat (ios/MyMuChat) — was a WKWebView
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
                MusicView()
                    .tabItem { Label("Music", systemImage: "music.note") }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    ReportClient.flush()  // retry queued reports
                    ChatURLSync.run()     // pick up server-side chat-token rotations
                }
            }
        }
    }
}
