import SwiftUI

/// The Chat tab — NATIVE MyMu chat (claude-code-cli-ui's client code, vendored
/// under ios/MyMuChat/), replacing the old WKWebView embed.
///
/// ACCESS (2026-10-23, Manar: "special-agent access = the MyMu host username
/// and password, that's it"): the tab signs in to the MyMu host with the
/// user's own MyMu login (the vendored `AppState.login` → POST /api/auth/login,
/// JWT in the Keychain — exactly the standalone MyMu app) and then opens the
/// brain's conversation. WHICH host and WHICH agent come from the voice
/// server's /config (`mymu.host`, `mymu.agent`, derived from the subscriber's
/// profile), so nothing is typed but the two credentials. A 401 later (token
/// expired, password changed) drops straight back to the sign-in.
///
/// The old agent-view share-token URL (`chatURL` with ?token=…) still works as
/// a FALLBACK when nobody has signed in — older installs keep their chat.
struct AgentChatTab: View {
    @AppStorage("chatURL", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var chatURL: String = SharedConfig.defaultChat
    // The MyMu host / agent hint from /config, cached so the sign-in screen is
    // prefilled even before the first fetch (and offline).
    @AppStorage("mymuHost", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var mymuHost: String = "https://code.kaxtus.com"
    @AppStorage("mymuAgent", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var mymuAgent: String = "special-agent"

    var body: some View {
        // Re-created whenever the legacy URL or the hint changes (id: swaps the tree).
        AgentChatRoot(chatURL: chatURL, host: mymuHost, agentName: mymuAgent,
                      onHint: { h, a in mymuHost = h; mymuAgent = a })
            .id(chatURL + "|" + mymuHost + "|" + mymuAgent)
    }
}

private struct AgentChatRoot: View {
    let chatURL: String
    let host: String
    let agentName: String
    let onHint: (String, String) -> Void

    @StateObject private var appState = AppState()
    @StateObject private var store = ProjectsStore()
    @State private var path: [Route] = []
    @State private var hintFetched = false

    /// Legacy agent-view token from the chat URL (fallback path only).
    private var legacyToken: String? {
        guard let url = URL(string: chatURL),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let t = comps.queryItems?.first(where: { $0.name == "token" })?.value,
              !t.isEmpty, !t.contains("__") else { return nil }
        return t
    }

    private var signedIn: Bool { appState.isAuthenticated }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
                .toolbar {
                    if signedIn {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                if let u = appState.user?.username {
                                    Text("\(u) · \(hostLabel)")
                                }
                                Button("Refresh") { Task { await reload() } }
                                Button("Sign out", role: .destructive) { signOut() }
                            } label: {
                                Image(systemName: "person.crop.circle")
                            }
                        }
                    }
                }
        }
        .environmentObject(appState)
        .environmentObject(store)
        .task { await configure() }
        .onChange(of: appState.accountEpoch) { _ in Task { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: .mymuUnauthorized)) { _ in
            // The saved MyMu token is dead: back to the sign-in (keeps the
            // legacy fallback untouched).
            GadkVoice.beacon("mymu-token-rejected")
            appState.logout()
            store.projects = []
        }
        .preferredColorScheme(.dark)
    }

    private var hostLabel: String {
        Config.serverOrigin.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    @ViewBuilder
    private var content: some View {
        if !signedIn && legacyToken == nil {
            MyMuSignIn(host: host, agentName: agentName)
        } else if store.loading && store.projects.isEmpty {
            ZStack { Theme.background.ignoresSafeArea(); MyMuLoader() }
        } else if let agent = brainAgent {
            // THE agent (the subscriber's brain, e.g. special-agent): straight
            // into its streamed conversation.
            ChatView(sessionId: agent.remoteSessionId
                        ?? agent.projectId.replacingOccurrences(of: "remote:", with: ""),
                     projectId: agent.projectId,
                     isRemote: true,
                     title: agent.displayName,
                     token: appState.token ?? "")
        } else if let agent = onlyAgent {
            ChatView(sessionId: agent.remoteSessionId
                        ?? agent.projectId.replacingOccurrences(of: "remote:", with: ""),
                     projectId: agent.projectId,
                     isRemote: true,
                     title: agent.displayName,
                     token: appState.token ?? "")
        } else if !store.agents.isEmpty {
            AgentsView()   // several agents, none named like the brain -> pick one
        } else if let (project, session) = latestLocalSession {
            // The agent runs as a LOCAL Claude Code project on the MyMu host —
            // open its most recent conversation directly, resuming the same session.
            ChatView(sessionId: session.id,
                     projectId: project.projectId,
                     isRemote: false,
                     title: project.displayName,
                     token: appState.token ?? "",
                     projectPath: project.path)
        } else {
            hint(store.error.map { "Couldn’t reach MyMu: \($0)" }
                 ?? "No agent is visible for this login right now.\nCheck that \(agentName) is running, then retry.")
        }
    }

    /// The brain by name: a bridge-connected (remote) agent titled like the
    /// profile's brain provider, or a local project of that name.
    private var brainAgent: Project? {
        let want = agentName.lowercased()
        guard !want.isEmpty else { return nil }
        if let a = store.agents.first(where: {
            $0.displayName.lowercased() == want
            || ($0.sessions?.first?.summary ?? "").lowercased() == want }) {
            return a
        }
        return nil
    }

    private var onlyAgent: Project? {
        store.agents.count == 1 ? store.agents.first : nil
    }

    /// Newest session of the brain's local project (or the first project) — nil if none visible.
    private var latestLocalSession: (Project, Session)? {
        let want = agentName.lowercased()
        let p = store.folders.first(where: { $0.displayName.lowercased() == want
                                             || ($0.path ?? "").lowercased().hasSuffix("/" + want) })
            ?? store.folders.first
        guard let p else { return nil }
        guard let s = (p.sessions ?? []).max(by: { $0.sortKey < $1.sortKey }) else { return nil }
        return (p, s)
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
                if signedIn {
                    Button("Sign out") { signOut() }
                        .font(.footnote).foregroundColor(Theme.mutedText)
                }
            }
            .padding(24)
        }
    }

    private func configure() async {
        if !hintFetched {
            hintFetched = true
            await MyMuHint.fetch { h, a in onHint(h, a) }
        }
        await load()
    }

    private func load() async {
        if signedIn {
            // Config.serverOrigin was set at login (AppState.activate) and
            // persists; the Keychain token rides on appState.token.
            await store.load(appState.api)
            return
        }
        guard let token = legacyToken else { return }
        // LEGACY: point the vendored client at the chat URL's own server and
        // hand it the agent-view JWT directly — no login screen, no Keychain write.
        if let url = URL(string: chatURL), let host = url.host {
            let scheme = url.scheme ?? "https"
            Config.serverOrigin = url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
        }
        appState.token = token
        await store.load(appState.api)
    }

    private func reload() async {
        store.loading = true
        await load()
    }

    private func signOut() {
        appState.logout()
        store.projects = []
        path = []
    }
}

/// `/config` of the voice server (already gated by the subscriber's voice
/// token) carries `mymu: {host, agent}` — which MyMu host to sign in to and
/// which agent's conversation the Chat tab opens. One fetch per tab build;
/// the result is cached in @AppStorage by the caller.
enum MyMuHint {
    static func fetch(_ apply: @escaping (String, String) -> Void) async {
        let t = GadkVoice.feedTarget()
        guard !t.app.isEmpty, !t.token.isEmpty, !t.token.contains("__") else { return }
        var comps = URLComponents(url: t.origin, resolvingAgainstBaseURL: false)!
        comps.path = "/config"
        comps.queryItems = [URLQueryItem(name: "app", value: t.app),
                            URLQueryItem(name: "token", value: t.token)]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mymu = obj["mymu"] as? [String: Any],
              let host = mymu["host"] as? String, !host.isEmpty,
              let agent = mymu["agent"] as? String, !agent.isEmpty
        else { return }
        await MainActor.run { apply(host, agent) }
    }
}
