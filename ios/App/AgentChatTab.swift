import SwiftUI

/// The Chat tab — NATIVE MyMu chat (claude-code-cli-ui's client code, vendored
/// under ios/MyMuChat/), replacing the old WKWebView embed.
///
/// Auth is unchanged: `chatURL` (Settings / build-time default) carries the
/// agent-view JWT as `?token=…`. Its `agentView` claim makes the CCUI server
/// scope everything (REST, /ws, files) to exactly one agent, so /api/projects
/// returns just that agent and we drop straight into its conversation. If the
/// token ever allows several agents, a picker list appears instead.
struct AgentChatTab: View {
    @AppStorage("chatURL", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var chatURL: String = SharedConfig.defaultChat

    var body: some View {
        // Re-created whenever the URL changes in Settings (id: swaps the tree).
        AgentChatRoot(chatURL: chatURL).id(chatURL)
    }
}

private struct AgentChatRoot: View {
    let chatURL: String

    @StateObject private var appState = AppState()
    @StateObject private var store = ProjectsStore()
    @State private var path: [Route] = []

    private var token: String? {
        guard let url = URL(string: chatURL),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "token" })?.value
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
        .environmentObject(appState)
        .environmentObject(store)
        .task { await configure() }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        if token == nil {
            hint("No chat token configured.\nSet the MyMu URL (with ?token=…) in Settings.")
        } else if store.loading && store.projects.isEmpty {
            ZStack { Theme.background.ignoresSafeArea(); MyMuLoader() }
        } else if let agent = onlyAgent {
            // Single-agent token (the normal case): straight into the chat.
            ChatView(sessionId: agent.remoteSessionId
                        ?? agent.projectId.replacingOccurrences(of: "remote:", with: ""),
                     projectId: agent.projectId,
                     isRemote: true,
                     title: agent.displayName,
                     token: appState.token ?? "")
        } else if !store.agents.isEmpty {
            AgentsView()   // several agents allowed -> pick one
        } else {
            hint(store.error.map { "Couldn’t reach MyMu: \($0)" }
                 ?? "No agent is live for this token right now.\nPull to retry from the Agents list, or check the server.")
        }
    }

    private var onlyAgent: Project? {
        store.agents.count == 1 ? store.agents.first : nil
    }

    private func hint(_ text: String) -> some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                    .font(.system(size: 34)).foregroundColor(Theme.mutedText)
                Text(text)
                    .multilineTextAlignment(.center)
                    .font(.callout).foregroundColor(Theme.mutedText)
                Button("Retry") { Task { await reload() } }
                    .buttonStyle(.bordered).tint(Theme.primary)
            }
            .padding(24)
        }
    }

    private func configure() async {
        guard let token else { return }
        // Point the vendored MyMu client at the chat URL's own server and hand
        // it the agent-view JWT directly — no login screen, no Keychain write.
        if let url = URL(string: chatURL), let host = url.host {
            let scheme = url.scheme ?? "https"
            Config.serverOrigin = url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
        }
        appState.token = token
        await store.load(appState.api)
    }

    private func reload() async {
        store.loading = true
        await configure()
    }
}
