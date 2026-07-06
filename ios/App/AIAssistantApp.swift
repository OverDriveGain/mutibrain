import SwiftUI

@main
struct AIAssistantApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                PetView()
                    .tabItem { Label("Buddy", systemImage: "mic.fill") }
                ChatView()
                    .background(Color.black.ignoresSafeArea())   // blend the status-bar strip
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
            }
        }
    }
}
