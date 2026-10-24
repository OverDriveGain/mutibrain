import SwiftUI

/// Sign in to the MyMu host with the user's OWN MyMu username + password
/// (Manar 2026-10-23: "special-agent access should be the host username and
/// password of MyMu — that's it"). Replaces the agent-view share-token URL
/// the Chat tab used to need. The host is prefilled from the voice server's
/// /config (`mymu.host`), so normally only the two credentials are typed.
///
/// The vendored MyMu client does the actual login (`AppState.login` →
/// POST /api/auth/login) and keeps the JWT in the Keychain, exactly like the
/// standalone MyMu app — so a 401 later drops back to this screen.
struct MyMuSignIn: View {
    @EnvironmentObject var appState: AppState
    let host: String
    /// The agent the Chat tab will open after signing in (for the caption).
    let agentName: String

    @State private var serverOrigin: String
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Field?
    private enum Field { case host, user, pass }

    init(host: String, agentName: String) {
        self.host = host
        self.agentName = agentName
        _serverOrigin = State(initialValue: host)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 40)).foregroundColor(Theme.primary)
                        Text("Sign in to MyMu")
                            .font(.title2.weight(.semibold)).foregroundColor(Theme.text)
                        Text("Your MyMu username and password open \(agentName)'s conversation.")
                            .font(.footnote).foregroundColor(Theme.mutedText)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 48)

                    VStack(spacing: 10) {
                        row("server.rack") {
                            TextField("MyMu host", text: $serverOrigin)
                                .keyboardType(.URL).textContentType(.URL)
                                .focused($focused, equals: .host)
                        }
                        row("person") {
                            TextField("Username", text: $username)
                                .textContentType(.username)
                                .focused($focused, equals: .user)
                                .submitLabel(.next)
                                .onSubmit { focused = .pass }
                        }
                        row("lock") {
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                                .focused($focused, equals: .pass)
                                .submitLabel(.go)
                                .onSubmit { Task { await signIn() } }
                        }
                    }

                    if let error {
                        Text(error).font(.footnote).foregroundColor(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            if busy { ProgressView().tint(.white) }
                            Text(busy ? "Signing in…" : "Sign in").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.primary)
                    .disabled(busy || username.isEmpty || password.isEmpty)

                    Spacer(minLength: 30)
                }
                .padding(22)
            }
        }
        .onAppear { if username.isEmpty { focused = .user } }
    }

    @ViewBuilder
    private func row<Content: View>(_ icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(Theme.mutedText).frame(width: 20)
            content()
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundColor(Theme.text)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
    }

    private func signIn() async {
        guard !busy, !username.isEmpty, !password.isEmpty else { return }
        busy = true; error = nil
        Config.serverOrigin = Config.normalize(serverOrigin)
        do {
            try await appState.login(username: username.trimmingCharacters(in: .whitespaces),
                                     password: password)
            GadkVoice.beacon("mymu-login-ok")
            appState.reauthNeeded = nil   // a pinned re-sign-in is satisfied too
            password = ""
        } catch {
            self.error = error.localizedDescription
            GadkVoice.beacon("mymu-login-failed")
        }
        busy = false
    }
}
