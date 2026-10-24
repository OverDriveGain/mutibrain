import SwiftUI
import UIKit

/// The brain's conversation = the vendored MyMu client (ios/MyMuChat), used
/// EXACTLY as MyMu uses it (Manar 2026-10-24: "use the chat from MyMu, it is
/// hard to reimplement — whatever we have there we will use"). This file is
/// only the host side: WHICH MyMu host and WHICH agent (from the voice
/// server's /config), the sign-in gate, and the roster lookup that resolves
/// the brain to a conversation. The conversation itself is MyMu's `RouteView`
/// → `ChatView`, with its switcher, composer, permissions, files and all.
///
/// ACCESS (2026-10-23, Manar: "special-agent access = the MyMu host username
/// and password, that's it"): the user's own MyMu login (`AppState.login` →
/// POST /api/auth/login, JWT in the Keychain). A 401 later goes through the
/// client's own `handleUnauthorized` (one probe before believing it) and ends
/// in `reauthNeeded` → the sign-in again. The old agent-view share-token URL
/// (`chatURL` with ?token=…) is still honoured as a FALLBACK when nobody has
/// signed in — it is what prod serves today through /config.
@MainActor
struct BrainChatRoot: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: ProjectsStore
    let chatURL: String
    let host: String
    let agentName: String
    /// Drawer at full height: the nav bar carries the way back to voice.
    let showVoiceButton: Bool
    let onVoice: () -> Void

    @State private var path: [Route] = []
    /// The conversation on screen when it is NOT the brain: MyMu's swipe
    /// switcher (vendored, inside ChatView) hands over another agent here.
    @State private var switched: ChatTarget?
    /// Cross-dissolve for a switch, exactly as MyMu's MainTabView does it: the
    /// window snapshot taken at commit floats over the swapped-in chat and
    /// fades, so the switcher chrome melts away instead of cutting.
    @State private var switchDissolve: UIImage?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
                .toolbar {
                    if showVoiceButton {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: onVoice) {
                                Image(systemName: "waveform")
                                    .font(.body.weight(.semibold))
                            }
                            .accessibilityLabel("Back to voice")
                        }
                    }
                }
        }
        .tint(Theme.primary)
        .preferredColorScheme(.dark)
        .onReceive(ChatSwitcher.shared.$target) { target in
            guard let target else { return }
            ChatSwitcher.shared.target = nil
            let snap = ChatSwitcher.shared.takeDissolveSnapshot()
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                if let snap { switchDissolve = snap }
                switched = target
            }
            if snap != nil {
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.3)) { switchDissolve = nil }
                }
            }
        }
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

    @ViewBuilder
    private var content: some View {
        if let expired = appState.reauthNeeded {
            // The saved session died (second explicit 401): sign back in to
            // THAT host — same screen, host prefilled.
            MyMuSignIn(host: expired.serverOrigin, agentName: agentName)
        } else if !appState.isAuthenticated && BrainAccess.legacyToken(in: chatURL) == nil {
            MyMuSignIn(host: host, agentName: agentName)
        } else if store.loading && store.projects.isEmpty {
            ZStack { Theme.background.ignoresSafeArea(); MyMuLoader() }
        } else if let target = switched ?? store.brainTarget(named: agentName) {
            // THE conversation — MyMu's own route (host pinning, warm start,
            // identity keyed on session + resolved host, all as in MyMu).
            RouteView(route: .chat(target))
        } else if !store.agents.isEmpty {
            AgentsView()   // several agents, none named like the brain -> pick one
        } else {
            hint(store.error.map { "Couldn’t reach MyMu: \($0)" }
                 ?? "No agent is visible for this login right now.\nCheck that \(agentName) is running, then retry.")
        }
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
                Button("Retry") { Task { store.loading = true; await store.load(appState.api) } }
                    .buttonStyle(.bordered).tint(Theme.primary)
                if appState.isAuthenticated {
                    Button("Sign out") { appState.logout(); store.projects = [] }
                        .font(.footnote).foregroundColor(Theme.mutedText)
                }
            }
            .padding(24)
        }
    }
}

/// The closed drawer's one line: who the brain is and what it is doing right
/// now (MyMu's own status vocabulary: working… / agent / agent · offline).
/// It is the handle — tap or drag it up.
@MainActor
struct BrainPeek: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: ProjectsStore
    let agentName: String
    let chatURL: String

    private var agent: Project? { store.brainAgent(named: agentName) ?? store.onlyAgent }
    private var signedIn: Bool { appState.isAuthenticated || BrainAccess.legacyToken(in: chatURL) != nil }

    var body: some View {
        HStack(spacing: 8) {
            if let a = agent {
                if let sid = a.remoteSessionId, let h = Harness(sessionId: sid) {
                    Image(h.assetName).resizable().scaledToFit().frame(width: 16, height: 16)
                } else {
                    Image(systemName: "sparkle").font(.footnote).foregroundColor(Theme.primary)
                }
                Text(a.displayName)
                    .font(.subheadline.weight(.semibold)).foregroundColor(Theme.text)
                    .lineLimit(1)
                Circle().fill(AgentStatus.color(a)).frame(width: 6, height: 6)
                Text(AgentStatus.text(a))
                    .font(.caption).foregroundColor(Theme.mutedText)
                    .lineLimit(1)
            } else if !signedIn {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.footnote).foregroundColor(Theme.mutedText)
                Text("Sign in to write to \(agentName)")
                    .font(.subheadline).foregroundColor(Theme.mutedText)
                    .lineLimit(1)
            } else {
                Image(systemName: "sparkle").font(.footnote).foregroundColor(Theme.primary)
                Text(agentName)
                    .font(.subheadline.weight(.semibold)).foregroundColor(Theme.text)
                Text(store.error == nil ? "connecting…" : "unreachable")
                    .font(.caption).foregroundColor(Theme.mutedText)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.up")
                .font(.caption.weight(.bold)).foregroundColor(Theme.mutedText)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 30)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("brain-peek")
    }
}

/// Resolving "the brain" in MyMu's roster, and the access plumbing.
extension ProjectsStore {
    /// The brain by name: a bridge-connected (remote) agent titled like the
    /// profile's brain provider.
    func brainAgent(named name: String) -> Project? {
        let want = name.lowercased()
        guard !want.isEmpty else { return nil }
        return agents.first {
            $0.displayName.lowercased() == want
            || ($0.sessions?.first?.summary ?? "").lowercased() == want
        }
    }

    var onlyAgent: Project? { agents.count == 1 ? agents.first : nil }

    /// What the drawer opens: the brain agent, else the only agent, else the
    /// newest conversation of the brain's LOCAL project on the MyMu host (or
    /// the first project). nil = nothing visible for this login.
    func brainTarget(named name: String) -> ChatTarget? {
        if let a = brainAgent(named: name) ?? onlyAgent {
            return ChatTarget(sessionId: a.remoteSessionId
                                ?? a.projectId.replacingOccurrences(of: "remote:", with: ""),
                              projectId: a.projectId, isRemote: true, title: a.displayName)
        }
        let want = name.lowercased()
        let p = folders.first(where: { $0.displayName.lowercased() == want
                                       || ($0.path ?? "").lowercased().hasSuffix("/" + want) })
            ?? folders.first
        guard let p, let s = (p.sessions ?? []).max(by: { $0.sortKey < $1.sortKey }) else { return nil }
        return ChatTarget(sessionId: s.id, projectId: p.projectId, isRemote: false,
                          title: p.displayName, projectPath: p.path)
    }
}

enum BrainAccess {
    /// Legacy agent-view token from the chat URL (fallback path only).
    static func legacyToken(in chatURL: String) -> String? {
        guard let url = URL(string: chatURL),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let t = comps.queryItems?.first(where: { $0.name == "token" })?.value,
              !t.isEmpty, !t.contains("__") else { return nil }
        return t
    }

    /// Load the roster for whoever is signed in; with nobody signed in and a
    /// legacy token at hand, point the vendored client at the chat URL's own
    /// server and hand it the token directly (no login screen, no Keychain).
    @MainActor
    static func load(_ appState: AppState, _ store: ProjectsStore, chatURL: String) async {
        if appState.isAuthenticated {
            await store.load(appState.api)
            return
        }
        guard let token = legacyToken(in: chatURL) else { return }
        if let url = URL(string: chatURL), let host = url.host {
            let scheme = url.scheme ?? "https"
            Config.serverOrigin = url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
        }
        appState.token = token
        await store.load(appState.api)
    }
}

/// `/config` of the voice server (already gated by the subscriber's voice
/// token) carries `mymu: {host, agent}` — which MyMu host to sign in to and
/// which agent's conversation the drawer opens. One fetch per build of the
/// Buddy screen; the result is cached in @AppStorage by the caller.
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
