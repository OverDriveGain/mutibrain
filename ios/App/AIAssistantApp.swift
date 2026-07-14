import SwiftUI

@main
struct AIAssistantApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                PetView()
                    .tabItem { Label("Buddy", systemImage: "mic.fill") }
                    .onAppear { AudioStreamer.shared.autoStartIfEnabled() }
                ChatView()
                    .background(Color.black.ignoresSafeArea())   // blend the status-bar strip
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
                MusicView()
                    .tabItem { Label("Music", systemImage: "music.note") }
            }
        }
    }
}
