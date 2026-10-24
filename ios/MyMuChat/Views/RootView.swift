import SwiftUI

struct RootView: View {
    @EnvironmentObject var appState: AppState
    /// An access link arrived while SIGNED IN — present the add-account login
    /// as a sheet (the root login isn't on screen to consume it).
    @State private var showAccessLogin = false

    var body: some View {
        content
            // Session death is handled HERE, at the root, so the sign-in can
            // always be shown — a rejected token can surface from any screen,
            // and a sheet owned by a toolbar item only presents if that toolbar
            // happens to be on screen.
            .onReceive(NotificationCenter.default.publisher(for: .mymuUnauthorized)) { note in
                guard let origin = note.userInfo?["origin"] as? String else { return }
                appState.handleUnauthorized(origin: origin)
            }
            .onChange(of: appState.pendingAccess) { p in
                guard p != nil else { return }
                // Signed out: the root LoginView is on screen and consumes the
                // payload itself. Signed in: raise a login sheet to hold it.
                if appState.isAuthenticated || appState.isDemo { showAccessLogin = true }
            }
            .sheet(isPresented: $showAccessLogin) {
                LoginView(onSuccess: { showAccessLogin = false })
            }
    }

    @ViewBuilder
    private var content: some View {
        if appState.isAuthenticated {
            // Re-id on account switch: the whole tab tree (stores, relay
            // sockets) rebuilds against the newly-active server + token.
            MainTabView().id(appState.accountEpoch)
        } else if appState.isDemo {
            MainTabView(store: .demo())
        } else if let expired = appState.reauthNeeded {
            // Session expired: sign back in to THAT account — host and username
            // fixed, so the credentials can't be checked against another server.
            LoginView(onSuccess: { appState.reauthNeeded = nil },
                      initialOrigin: expired.serverOrigin,
                      initialUsername: expired.username,
                      notice: "Your session on \(expired.hostLabel) expired. Sign in again to continue.",
                      onCancel: { appState.cancelReauth() })
        } else {
            // Signed out entirely: pre-fill the host last used — there's only one
            // context here, so it's a help rather than the "Add account" trap.
            LoginView(initialOrigin: Config.serverOrigin)
        }
    }
}
