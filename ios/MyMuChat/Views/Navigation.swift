import SwiftUI

/// Value-based navigation targets. Each tab's path ([Route]) is OWNED BY
/// MainTabView, which never leaves the hierarchy — so switching tabs and coming
/// back restores exactly where you were (list, detail, or deep in a chat).
struct ChatTarget: Hashable {
    let sessionId: String
    let projectId: String
    let isRemote: Bool
    let title: String
    var projectPath: String? = nil
    /// Session provider when the ORIGIN list knew it (local sessions carry a
    /// real one). Live agents resolve their harness from the id prefix instead,
    /// so nil here never loses information.
    var provider: String? = nil
}

enum Route: Hashable {
    case chat(ChatTarget)
    case projectDetail(Project)
}

/// Resolves a Route to its screen. Registered once per tab's NavigationStack.
struct RouteView: View {
    let route: Route
    @EnvironmentObject var appState: AppState

    var body: some View {
        switch route {
        case .chat(let t):
            // Agent→host pinning: a remote agent assigned to another host — with a
            // saved login there — gets its WHOLE conversation (WS, history, files)
            // routed to that host, so file sends land on the agent's machine. The
            // relay mirrors turns to every attached host, so nothing else changes.
            let hostRoute = t.isRemote ? appState.routeForAgent(title: t.title) : nil
            ChatView(sessionId: t.sessionId, projectId: t.projectId, isRemote: t.isRemote,
                     title: t.title, token: hostRoute?.token ?? appState.token ?? "",
                     projectPath: t.projectPath, origin: hostRoute?.origin,
                     pinnedHostNeedingLogin: t.isRemote ? appState.pinnedHostNeedingLogin(title: t.title) : nil,
                     provider: t.provider)
                // Keyed by session: a notification tap can REPLACE the chat at
                // the same stack depth, and without an explicit identity the
                // old conversation's state (relay socket included) survived the
                // swap — screen kept showing the previous chat.
                // ALSO keyed by the resolved host: the routing map loads async,
                // and a chat opened before it landed stayed silently bound to
                // the wrong host for its whole life (the relay socket lives in
                // @StateObject state that param changes don't rebuild). A route
                // change now rebuilds the chat against the agent's real host —
                // the warm-start cache makes the swap invisible.
                .id("\(t.sessionId)|\(hostRoute?.origin ?? "")")
        case .projectDetail(let p):
            ProjectDetailView(project: p)
        }
    }
}
