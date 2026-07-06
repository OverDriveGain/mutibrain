import SwiftUI

@main
struct AIAssistantApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                PetView()
                    .tabItem { Label("Buddy", systemImage: "mic.fill") }
                ChatView()
                    .ignoresSafeArea(.container, edges: .top)
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
            }
        }
    }
}
