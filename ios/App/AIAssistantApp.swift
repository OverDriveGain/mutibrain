import SwiftUI

@main
struct AIAssistantApp: App {
    init() {
        CrashReporter.install()
        // If the previous run died, tell the server journal what killed it.
        CrashReporter.reportIfCrashed()
        // Build tag: proves in the journal WHICH build is on the phone (we
        // once spent a session debugging an old build believed new).
        GadkVoice.beacon("build-v10-standard-audio")
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
        }
    }
}
