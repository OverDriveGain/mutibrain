import SwiftUI
import UIKit

/// Visible copy affordance under a message (the web shows an explicit button, not
/// a long-press). Shows a brief "Copied" confirmation.
struct CopyButton: View {
    let text: String
    @State private var copied = false
    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .foregroundColor(Theme.mutedText)
        }
        .buttonStyle(.plain)
    }
}

/// Rounded square icon tile used across list rows.
struct IconTile: View {
    let symbol: String
    var size: CGFloat = 38
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Theme.surface).frame(width: size, height: size)
            Image(systemName: symbol).foregroundColor(Theme.primary).font(.system(size: size * 0.42))
        }
    }
}

/// Centered empty / hint state.
/// UIKit share sheet. ShareLink can't take an item that only exists after an
/// async download, and the image lightbox shares a UIImage (Save Image needs
/// the activity item itself, not a Transferable).
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct EmptyStateView: View {
    let text: String
    var retry: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 10) {
            Text(text).foregroundColor(Theme.mutedText).multilineTextAlignment(.center)
            if let retry {
                Button("Retry", action: retry).foregroundColor(Theme.primary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Determinate activity ring for LONG batch operations — the Agents tab's
/// usage-probe fan-out wears it around the account icon. Deliberately DISTINCT
/// from the app's ordinary indeterminate spinners (Manar, 2026-09-29: a long
/// fan-out must not use the same progress as quick everyday loads): the arc's
/// LENGTH is real batch completion (done/total), and the whole arc slowly
/// orbits so a stalled probe still reads as alive, not frozen.
struct BatchProgressRing: View {
    /// 0…1 batch completion.
    let fraction: Double

    @State private var orbiting = false

    var body: some View {
        ZStack {
            Circle().stroke(Theme.border.opacity(0.7), lineWidth: 2)
            Circle()
                // A hairline of arc is always shown so 0/N doesn't render bare.
                .trim(from: 0, to: max(0.06, min(1, fraction)))
                .stroke(Theme.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .animation(.easeOut(duration: 0.35), value: fraction)
                .rotationEffect(.degrees(orbiting ? 270 : -90))
                .animation(.linear(duration: 1.8).repeatForever(autoreverses: false), value: orbiting)
        }
        .frame(width: 29, height: 29)
        .allowsHitTesting(false)
        .onAppear { orbiting = true }
    }
}

/// Account switcher — Gmail-style multiple logins. Each saved account is a
/// (server, user) pair; tapping one switches the WHOLE environment to it.
///
/// A LIST in a sheet rather than a menu: with several logins a menu can't show
/// a monogram, can't mark the active row with anything but a checkmark, and —
/// decisively — can't offer a per-row destructive action, because menu items
/// support neither swipe nor long-press. The list gives one-tap switching,
/// swipe-to-sign-out, and a long-press context menu, which is how every
/// multi-account client does this.
struct ProfileMenu: View {
    @EnvironmentObject var appState: AppState
    @State private var showAccounts = false
    @State private var showAddAccount = false
    @State private var serverVersion: String?
    var body: some View {
        Button {
            showAccounts = true
        } label: {
            Image(systemName: "person.crop.circle").foregroundColor(Theme.primary)
        }
        .sheet(isPresented: $showAccounts) {
            AccountsSheet(
                serverVersion: serverVersion,
                onAddAccount: {
                    showAccounts = false
                    showAddAccount = true
                }
            )
            .environmentObject(appState)
        }
        // "Add account": no pre-filled host on purpose — see LoginView.init.
        .sheet(isPresented: $showAddAccount) {
            LoginView(onSuccess: { showAddAccount = false })
        }
        // NOTE: expired-session re-auth is presented by RootView, not here — a
        // sheet on a toolbar item only appears if that toolbar is on screen.
        .task(id: appState.accountEpoch) {
            // Active host's backend build (/api/version, unauthenticated).
            serverVersion = nil
            guard let url = URL(string: Config.serverOrigin + "/api/version") else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            var parts: [String] = []
            if let v = obj["version"] as? String { parts.append("v\(v)") }
            if let iso = obj["builtAt"] as? String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = f.date(from: iso) {
                    let out = DateFormatter()
                    out.dateFormat = "dd MMM HH:mm"
                    parts.append("built \(out.string(from: d))")
                }
            }
            serverVersion = parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }
}

/// The account list itself. Tap a row to switch; swipe it or long-press for
/// "Sign out" — including the last remaining account, which drops the app back
/// to the login screen.
struct AccountsSheet: View {
    let serverVersion: String?
    let onAddAccount: () -> Void
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    /// Signing out is destructive and unrecoverable without the password, so it
    /// asks first — the swipe/long-press only arms it.
    @State private var pendingSignOut: SavedAccount?
    @State private var showAccessQR = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(appState.accounts) { acct in
                        Button {
                            if acct.id != appState.activeAccountId { appState.switchTo(acct) }
                            dismiss()
                        } label: {
                            AccountRow(account: acct, isActive: acct.id == appState.activeAccountId)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingSignOut = acct
                            } label: {
                                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingSignOut = acct
                            } label: {
                                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        }
                    }
                }

                Section {
                    Button(action: onAddAccount) {
                        Label("Add account", systemImage: "plus")
                    }
                    // Hand this login to another device: show a QR the other
                    // MyMu scans on its login screen (server + user; password
                    // only if typed into the sheet).
                    if appState.activeAccount != nil {
                        Button { showAccessQR = true } label: {
                            Label("Share access QR", systemImage: "qrcode")
                        }
                    }
                }

                // Host-level configuration lives with the account it belongs to
                // — MCP servers are a property of the server you're signed in
                // to, not of any one conversation.
                Section {
                    NavigationLink {
                        McpServersView(api: appState.api)
                    } label: {
                        Label("MCP servers", systemImage: "puzzlepiece.extension")
                    }
                }

                Section {
                    Text("App v\(Bundle.main.appVersionLabel)")
                    if let serverVersion {
                        Text("Server \(serverVersion)")
                    }
                }
                .font(.footnote)
                .foregroundColor(Theme.mutedText)
            }
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showAccessQR) {
            if let acct = appState.activeAccount {
                AccessQRSheet(origin: Config.normalize(acct.serverOrigin), username: acct.username)
            }
        }
        .confirmationDialog(
            pendingSignOut.map { "Sign out \($0.username) · \($0.hostLabel)?" } ?? "",
            isPresented: Binding(get: { pendingSignOut != nil }, set: { if !$0 { pendingSignOut = nil } }),
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) {
                if let acct = pendingSignOut { appState.removeAccount(acct) }
                pendingSignOut = nil
            }
            Button("Cancel", role: .cancel) { pendingSignOut = nil }
        }
    }
}

/// One account row: monogram, user, host, and a tint/checkmark when it's the
/// active login.
struct AccountRow: View {
    let account: SavedAccount
    let isActive: Bool

    /// First letter of the username — the conventional stand-in for an avatar.
    private var monogram: String {
        account.username.first.map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(monogram)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(isActive ? .white : Theme.primary)
                .frame(width: 34, height: 34)
                .background(isActive ? Theme.primary : Theme.primary.opacity(0.15))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(account.username)
                    .font(.body)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)
                Text(account.hostLabel)
                    .font(.caption)
                    .foregroundColor(Theme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if isActive {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.primary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

extension Bundle {
    /// "1.0.0 (250725.2114)" — marketing version + build number.
    var appVersionLabel: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

enum AgentStatus {
    static func color(_ p: Project) -> Color {
        if p.remoteRunning == true { return Theme.primary }
        if p.remoteConnected != false { return .green }
        return Theme.mutedText
    }
    static func text(_ p: Project) -> String {
        if p.remoteRunning == true { return "working…" }
        if p.remoteConnected != false { return "agent" }
        return "agent · offline"
    }
    static func dimmed(_ p: Project) -> Bool { p.remoteConnected == false }
}

/// Compact relative age ("<1m", "5m", "3hr", "2d") — mirrors formatCompactSessionAge.
func compactAge(_ iso: String?) -> String {
    guard let iso, let date = parseISO(iso) else { return "" }
    let s = Date().timeIntervalSince(date)
    if s < 60 { return "<1m" }
    if s < 3600 { return "\(Int(s / 60))m" }
    if s < 86400 { return "\(Int(s / 3600))hr" }
    return "\(Int(s / 86400))d"
}

private func parseISO(_ s: String) -> Date? {
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: s) { return d }
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: s)
}
