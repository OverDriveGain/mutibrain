import SwiftUI

struct LoginView: View {
    @EnvironmentObject var appState: AppState
    /// Set when presented as a SHEET ("Add account") — called after a successful
    /// login so the presenter can dismiss. Root-level usage leaves it nil.
    var onSuccess: (() -> Void)? = nil
    /// Escape hatch out of a PINNED sign-in (expired session): without it the
    /// user is trapped on one account's login with no route to the others.
    var onCancel: (() -> Void)? = nil
    /// Explanatory line shown above the fields (e.g. "session expired").
    var notice: String? = nil
    @State private var serverOrigin: String
    @State private var username: String
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showScanner = false
    /// Past successful logins (host + user, never passwords) — the "I signed
    /// out and now I'm retyping everything" fix. Loaded on appear.
    @State private var history: [LoginMemory] = []

    /// `initialOrigin` is deliberately NOT defaulted to the active host. Adding a
    /// second account pre-filled with the CURRENT server is a trap: you type the
    /// new account's credentials, they're checked against the old host, and the
    /// 401 reads as a wrong password. "Add account" passes nil (empty field, an
    /// explicit choice); the root login and re-auth pass the host they mean.
    init(onSuccess: (() -> Void)? = nil,
         initialOrigin: String? = nil,
         initialUsername: String? = nil,
         notice: String? = nil,
         onCancel: (() -> Void)? = nil) {
        self.onSuccess = onSuccess
        self.onCancel = onCancel
        self.notice = notice
        _serverOrigin = State(initialValue: initialOrigin ?? "")
        _username = State(initialValue: initialUsername ?? "")
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    brandHeader
                        .padding(.top, 60)
                    VStack(spacing: 12) {
                        HStack(spacing: 10) {
                            field("Server", text: $serverOrigin, icon: "server.rack",
                                  keyboard: .URL, content: .URL)
                            // Camera hand-off: scan an access QR from another
                            // MyMu and land signed in (or at least pre-filled).
                            Button {
                                showScanner = true
                            } label: {
                                Image(systemName: "qrcode.viewfinder")
                                    .font(.system(size: 20))
                                    .foregroundColor(Theme.primary)
                                    .frame(width: 50, height: 50)
                                    .background(Theme.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
                            }
                            .accessibilityLabel("Scan access QR")
                        }
                        if !suggestions.isEmpty { historyChips }
                        field("Username", text: $username, icon: "person", content: .username)
                        secureField("Password", text: $password, icon: "lock")
                    }
                    if let notice {
                        Text(notice)
                            .font(.footnote).foregroundColor(Theme.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Point MyMu at your own Claude Code UI server, or explore the demo.")
                        .font(.caption).foregroundColor(Theme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let error {
                        Text(error).foregroundColor(Theme.danger).font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    signInButton
                    if onSuccess == nil { demoButton }
                    Spacer(minLength: 40)
                }
                .padding(24)
            }
        }
        .onAppear {
            history = LoginHistory.all()
            consumePendingAccess()
        }
        // Covers the already-on-screen case (root login when signed out): the
        // link arrives after onAppear, so watch for it too.
        .onChange(of: appState.pendingAccess) { _ in consumePendingAccess() }
        .sheet(isPresented: $showScanner) {
            QRScanSheet { payload in
                serverOrigin = Config.normalize(payload.origin)
                if let u = payload.username { username = u }
                if let p = payload.password { password = p }
                // A full payload signs straight in — that's the hand-off.
                if !username.isEmpty && !password.isEmpty {
                    Task { await doLogin() }
                }
            }
        }
        // Pinned re-login must never be a trap: a REAL back button (not a
        // footnote link nobody finds) returns to the accounts that still work.
        .overlay(alignment: .topLeading) {
            if let onCancel {
                Button(action: onCancel) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Back")
                    }
                    .foregroundColor(Theme.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("login-back")
            }
        }
    }

    private var brandHeader: some View {
        VStack(spacing: 8) {
            Text("MyMu")
                .font(.system(size: 44, weight: .semibold))
                .foregroundColor(Theme.primary)
            Text("Drive your agents")
                .font(.subheadline)
                .foregroundColor(Theme.mutedText)
            Text("v\(Bundle.main.appVersionLabel)")
                .font(.caption2)
                .foregroundColor(Theme.mutedText.opacity(0.7))
        }
    }

    /// Matching hosts from past logins, shown as one-tap chips. Filtered by
    /// what's typed so far; everything when the field is empty. Hidden once
    /// the field exactly holds a remembered origin (job done).
    private var suggestions: [LoginMemory] {
        let typed = serverOrigin.trimmingCharacters(in: .whitespaces).lowercased()
        if typed.isEmpty { return Array(history.prefix(4)) }
        let matches = history.filter {
            $0.hostLabel.lowercased().contains(typed) || $0.origin.lowercased().contains(typed)
        }
        if matches.count == 1, let only = matches.first,
           only.origin.lowercased() == Config.normalize(typed).lowercased(),
           only.username == username { return [] }
        return Array(matches.prefix(4))
    }

    private var historyChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions) { m in
                    Button {
                        serverOrigin = m.origin
                        username = m.username
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.caption2).foregroundColor(Theme.primary)
                            Text("\(m.username) · \(m.hostLabel)")
                                .font(.caption).foregroundColor(Theme.text)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(Theme.surface)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, icon: String,
                       keyboard: UIKeyboardType = .default, content: UITextContentType? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(Theme.mutedText).frame(width: 20)
            TextField("", text: text, prompt: Text(placeholder).foregroundColor(Theme.mutedText))
                .foregroundColor(Theme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .textContentType(content)
                // Stable handle for XCUITest: prompt-based textFields["Username"]
                // matching broke when the fields gained prompts + content types.
                .accessibilityIdentifier("login-\(placeholder.lowercased())")
        }
        .padding(14)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
    }

    private func secureField(_ placeholder: String, text: Binding<String>, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(Theme.mutedText).frame(width: 20)
            SecureField("", text: text, prompt: Text(placeholder).foregroundColor(Theme.mutedText))
                .foregroundColor(Theme.text)
                .textContentType(.password)
                .accessibilityIdentifier("login-\(placeholder.lowercased())")
        }
        .padding(14)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
    }

    private var signInButton: some View {
        Button {
            Task { await doLogin() }
        } label: {
            HStack {
                if busy { ProgressView().tint(Theme.background) }
                Text(busy ? "Signing in…" : "Sign in").fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.primary)
            .foregroundColor(Theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(canSubmit ? 1 : 0.5)
        }
        .disabled(!canSubmit)
    }

    private var demoButton: some View {
        Button {
            appState.enterDemo()
        } label: {
            Text("Try the demo")
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .foregroundColor(Theme.primary)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
        }
        .disabled(busy)
    }

    /// The server is required. An empty field would fall through
    /// `Config.normalize("")` to the DEMO origin and silently check the
    /// credentials against the wrong host.
    private var canSubmit: Bool {
        !busy && !username.isEmpty && !password.isEmpty
            && !serverOrigin.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Take the waiting access link (camera-scanned QR): fill the fields, and
    /// when it carries the full credentials, sign straight in.
    private func consumePendingAccess() {
        guard let p = appState.pendingAccess else { return }
        appState.pendingAccess = nil
        serverOrigin = Config.normalize(p.origin)
        if let u = p.username { username = u }
        if let pw = p.password { password = pw }
        if !username.isEmpty && !password.isEmpty {
            Task { await doLogin() }
        }
    }

    private func doLogin() async {
        error = nil
        busy = true
        // Point the global origin at the target server for the login call, but
        // restore it on failure — an "Add account" attempt must not hijack the
        // still-active environment when the password was wrong.
        let previousOrigin = Config.serverOrigin
        Config.serverOrigin = serverOrigin
        do {
            try await appState.login(username: username, password: password)
            onSuccess?()
        } catch {
            Config.serverOrigin = previousOrigin
            self.error = error.localizedDescription
        }
        busy = false
    }
}
