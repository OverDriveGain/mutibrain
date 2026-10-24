import SwiftUI
import UIKit

/// MyMu's top-level IA as a native tab bar — Projects (default), Chats, Agents,
/// Archive. Each tab's NavigationStack PATH lives here: MainTabView never leaves
/// the hierarchy, so switching tabs preserves exactly where you were in each one.
struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var store: ProjectsStore
    @State private var selection: Int
    @State private var agentsPath: [Route] = []
    @State private var projectsPath: [Route] = []
    @State private var chatsPath: [Route] = []
    @State private var archivePath: [Route] = []
    /// Cross-dissolve for swipe switches: the window snapshot taken at commit,
    /// floated over the swapped-in chat and faded out. Lives HERE because this
    /// view survives the route swap that unmounts the switcher.
    @State private var switchDissolve: UIImage?
    @Environment(\.scenePhase) private var scenePhase

    @MainActor
    init(store: ProjectsStore? = nil) {
        _store = StateObject(wrappedValue: store ?? ProjectsStore())
        var initial = 0
        if let t = ProcessInfo.processInfo.environment["MYMU_DEMO_TAB"], let n = Int(t) { initial = n }
        _selection = State(initialValue: initial)
    }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack(path: $projectsPath) {
                ProjectsView().navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label("Projects", systemImage: "folder") }
            .tag(0)

            NavigationStack(path: $chatsPath) {
                RecentsView().navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label("Chats", systemImage: "message") }
            .tag(1)

            // Live agents — moved to second-to-last (immediately before Archive).
            NavigationStack(path: $agentsPath) {
                AgentsView().navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label("Agents", systemImage: "terminal") }
            .tag(2)

            NavigationStack(path: $archivePath) {
                ArchiveView().navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .tabItem { Label("Archive", systemImage: "archivebox") }
            .tag(3)
        }
        .environmentObject(store)
        .tint(Theme.primary)
        // Conversations the chat screen no longer owns (left mid-turn, kept
        // live by the registry) still need the app-lifecycle kicks the
        // visible chat gives its own: release presence on background,
        // reconnect on foreground.
        .onChange(of: scenePhase) { phase in
            ConversationRegistry.shared.scenePhaseChanged(phase)
        }
        .task {
            await store.loadIfNeeded(appState.api)
            // Warm chat snapshots into RAM as soon as the roster is known —
            // not just when the Agents tab shows — so a notification-opened or
            // Chats-tab conversation warm-starts too.
            ChatCacheStore.shared.warm(sessionIds: store.agents.compactMap(\.remoteSessionId))
        }
        // Notification tap → land IN that conversation: switch to Agents and
        // push the chat. The path lands on the NEXT runloop — a freshly
        // selected tab's NavigationStack drops a same-tick programmatic push —
        // and it goes through empty first so re-tapping the same conversation
        // still visibly navigates.
        .onReceive(PushManager.shared.$pendingTarget) { target in
            guard let target else { return }
            PushManager.shared.pendingTarget = nil
            PushLog.logger.info("navigating to \(target.sessionId, privacy: .public)")
            // Already reading that conversation — landing is a no-op.
            if selection == 2, let last = agentsPath.last,
               case .chat(let current) = last, current.sessionId == target.sessionId {
                return
            }
            selection = 2
            // ONE deferred, animation-free stack replacement. The previous
            // empty-then-push pair animated two transitions while the scene was
            // still activating and wedged between panes (Manar, 2026-09-13).
            DispatchQueue.main.async {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { agentsPath = [Route.chat(target)] }
            }
        }
        // Swipe-switcher settle → swap the visible chat IN PLACE. Same
        // ChatTarget contract as the notification path above, but no tab jump
        // and no path reset: the new chat replaces the old at the same stack
        // depth, so Back still returns to the list the user came from. The
        // switcher's window snapshot goes up in the SAME no-animation
        // transaction as the swap (no gap frame), then dissolves over the
        // incoming chat — the cross-fade Manar asked for; the transcripts on
        // both sides come from the same cache, so they visually merge.
        .onReceive(ChatSwitcher.shared.$target) { target in
            guard let target else { return }
            ChatSwitcher.shared.target = nil
            let snap = ChatSwitcher.shared.takeDissolveSnapshot()
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                if let snap { switchDissolve = snap }
                switch selection {
                case 0: Self.replaceTop(&projectsPath, with: target)
                case 1: Self.replaceTop(&chatsPath, with: target)
                case 2: Self.replaceTop(&agentsPath, with: target)
                default: Self.replaceTop(&archivePath, with: target)
                }
            }
            if snap != nil {
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.3)) { switchDissolve = nil }
                }
            }
        }
        // The dissolve layer itself — non-interactive, so the incoming chat is
        // usable from the first frame even while the fade runs.
        .overlay {
            if let img = switchDissolve {
                Image(uiImage: img)
                    .resizable()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    /// Replace the top route (the visible chat) with another chat. An empty
    /// path can't happen from inside a chat, but degrade to a push anyway.
    private static func replaceTop(_ path: inout [Route], with target: ChatTarget) {
        if path.isEmpty { path = [.chat(target)] } else { path[path.count - 1] = .chat(target) }
    }
}
