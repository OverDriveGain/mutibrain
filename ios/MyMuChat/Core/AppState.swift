import SwiftUI

/// App-wide auth + session. The active account's token is persisted in the
/// Keychain (legacy key kept so every existing consumer stays unchanged); the
/// app reuses the same login the web client does (`POST /api/auth/login`).
@MainActor
final class AppState: ObservableObject {
    @Published var token: String?
    @Published var user: User?
    @Published var accounts: [SavedAccount] = []
    @Published var activeAccountId: String?
    /// A scanned/tapped mymu://login access link waiting to be consumed by a
    /// login screen (RootView routes it; LoginView fills itself and clears it).
    @Published var pendingAccess: AccessPayload?
    /// Bumped on every account switch — RootView re-ids the tab tree on it so
    /// stores/sockets rebuild against the new environment.
    @Published var accountEpoch = 0
    /// Local, network-free preview (canned DemoData) — used by the "Try the demo"
    /// button on the login screen so the app is reviewable/explorable with no server.
    @Published var isDemo = false
    /// Set when switching to a saved account whose token is gone: the account is
    /// KEPT and the UI presents a pre-filled sign-in for exactly that host and
    /// username, instead of silently deleting the row.
    @Published var reauthNeeded: SavedAccount?
    /// Where "Back" from that pinned sign-in returns: the account that was
    /// active before the switch (its token still works). Without it, leaving
    /// the sign-in dead-ended at an empty login while working sessions existed.
    var reauthReturn: SavedAccount?
    /// Agent → host assignments from the server (agent title → host origin).
    /// Admin-set pinning: which CCUI host an agent runs on. Drives per-chat
    /// routing so file sends land on the agent's machine.
    @Published var agentHostAssignments: [String: String] = [:]

    private let tokenAccount = "auth-token" // legacy + always-the-ACTIVE-account token
    private let userKey = "mymu.user"
    private let accountsKey = "mymu.accounts"
    private let activeKey = "mymu.activeAccount"
    private let agentHostsKey = "mymu.agentHosts"

    private func accountTokenKey(_ id: String) -> String { "auth-token|\(id)" }
    private func accountUserKey(_ id: String) -> String { "mymu.user|\(id)" }

    init() {
        token = Keychain.get(tokenAccount)
        if let data = UserDefaults.standard.data(forKey: userKey),
           let u = try? JSONDecoder().decode(User.self, from: data) {
            user = u
        }
        // Accounts live in the APP GROUP store — the share extension offers
        // the same accounts from the same data. A pre-group install carries
        // them in the private store; migrate everything across once, per-
        // account tokens included.
        if let data = AppGroup.defaults.data(forKey: accountsKey),
           let list = try? JSONDecoder().decode([SavedAccount].self, from: data) {
            accounts = list
        } else if let data = UserDefaults.standard.data(forKey: accountsKey),
                  let list = try? JSONDecoder().decode([SavedAccount].self, from: data) {
            accounts = list
            AppGroup.defaults.set(data, forKey: accountsKey)
        }
        activeAccountId = AppGroup.defaults.string(forKey: activeKey)
            ?? UserDefaults.standard.string(forKey: activeKey)
        // Last-known agent→host routing map — a chat opened before the first
        // refresh lands must still route to the agent's pinned host.
        if let stored = AppGroup.defaults.dictionary(forKey: agentHostsKey) as? [String: String] {
            agentHostAssignments = stored
        }
        for acct in accounts {
            if Keychain.get(accountTokenKey(acct.id), shared: true) == nil,
               let legacy = Keychain.get(accountTokenKey(acct.id)) {
                Keychain.set(legacy, for: accountTokenKey(acct.id), shared: true)
            }
            if AppGroup.defaults.data(forKey: accountUserKey(acct.id)) == nil,
               let blob = UserDefaults.standard.data(forKey: accountUserKey(acct.id)) {
                AppGroup.defaults.set(blob, forKey: accountUserKey(acct.id))
            }
        }
        // Migration: a pre-accounts install has a lone token+user — adopt it as
        // the first saved account so the switcher starts populated.
        if accounts.isEmpty, let token, let user {
            let acct = SavedAccount(serverOrigin: Config.serverOrigin, username: user.username)
            accounts = [acct]
            activeAccountId = acct.id
            Keychain.set(token, for: accountTokenKey(acct.id), shared: true)
            persistAccounts()
        }
    }

    #if DEBUG
    /// UI-test hook (MYMU_RESET=1, applied in MyMuApp.init before AppState is
    /// built): wipe every persisted trace of a session so a test launch always
    /// starts at the login screen. Keychain items OUTLIVE an app uninstall on
    /// the simulator, so deleting the app between runs is not enough — a stale
    /// token kept RootView past login and broke every login-path UI test.
    static func wipeForUITests() {
        if let data = AppGroup.defaults.data(forKey: "mymu.accounts"),
           let list = try? JSONDecoder().decode([SavedAccount].self, from: data) {
            for acct in list {
                Keychain.delete("auth-token|\(acct.id)", shared: true)
                AppGroup.defaults.removeObject(forKey: "mymu.user|\(acct.id)")
            }
        }
        Keychain.delete("auth-token")
        for key in ["mymu.accounts", "mymu.activeAccount", "mymu.agentHosts", "mymu.loginHistory"] {
            AppGroup.defaults.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.removeObject(forKey: "mymu.user")
        // The remembered server origin too — a LiveServer run against a LAN
        // host otherwise pre-fills the login's Server field on the next smoke
        // run, which then signs into the wrong machine and times out.
        UserDefaults.standard.removeObject(forKey: "mymu.serverOrigin")
    }
    #endif

    var isAuthenticated: Bool { token != nil }
    var api: APIClient { APIClient(token: token) }
    var activeAccount: SavedAccount? { accounts.first { $0.id == activeAccountId } }

    // MARK: Agent → host routing

    /// Refresh the admin-set agent→host map from the active server. Cheap; call
    /// when the agents list loads and after account switches. Persisted so a
    /// cold launch routes correctly BEFORE the first fetch lands — the map used
    /// to start empty every launch, and a chat opened in that window silently
    /// bound to the wrong host (field bug 2026-09-27: sends reached the agent
    /// through the relay, but the transcript came from a host that lagged).
    func refreshAgentHosts() async {
        guard token != nil, !isDemo else { return }
        if let map = try? await api.agentHosts() {
            agentHostAssignments = map
            AppGroup.defaults.set(map, forKey: agentHostsKey)
        }
    }

    /// Where a pinned agent's conversation should connect: the assigned host +
    /// the saved account's token for it. nil = the active host (unpinned, pinned
    /// to the active host itself, or no saved login for the assigned host —
    /// callers pair this with `pinnedHostNeedingLogin` for the file warning).
    /// The key is the agent's title — same stable identity the web view uses
    /// (single claude.ai account per host, so no account-label prefix).
    func routeForAgent(title: String) -> (origin: String, token: String)? {
        guard let assigned = agentHostAssignments[title] else { return nil }
        let origin = Config.normalize(assigned)
        guard origin != Config.normalize(Config.serverOrigin) else { return nil }
        guard let acct = accounts.first(where: { Config.normalize($0.serverOrigin) == origin }),
              let tok = Keychain.get(accountTokenKey(acct.id), shared: true) else { return nil }
        return (origin, tok)
    }

    /// Host label when the agent is pinned to a host the app has NO saved login
    /// for — arbitrary files can't reach it; the composer warns and points the
    /// user at "Add account". nil when routing works (or nothing is pinned).
    func pinnedHostNeedingLogin(title: String) -> String? {
        guard let assigned = agentHostAssignments[title] else { return nil }
        let origin = Config.normalize(assigned)
        guard origin != Config.normalize(Config.serverOrigin) else { return nil }
        let hasLogin = accounts.contains { acct in
            Config.normalize(acct.serverOrigin) == origin && Keychain.get(accountTokenKey(acct.id), shared: true) != nil
        }
        return hasLogin ? nil : origin
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    func enterDemo() { isDemo = true }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            AppGroup.defaults.set(data, forKey: accountsKey)
        }
        AppGroup.defaults.set(activeAccountId, forKey: activeKey)
    }

    /// Sign in to (or add) an account on the CURRENT Config.serverOrigin and
    /// make it active. Same call for first login and Gmail-style "Add account".
    func login(username: String, password: String) async throws {
        let resp = try await APIClient.login(username: username, password: password)
        let acct = SavedAccount(serverOrigin: Config.serverOrigin, username: resp.user.username)
        // Remember host+user for login autocomplete — deliberately OUTSIDE the
        // account store, so signing out doesn't force retyping the origin.
        LoginHistory.record(origin: Config.serverOrigin, username: resp.user.username)
        accounts.removeAll { $0.id == acct.id }
        accounts.append(acct)
        Keychain.set(resp.token, for: accountTokenKey(acct.id), shared: true)
        if let data = try? JSONEncoder().encode(resp.user) {
            AppGroup.defaults.set(data, forKey: accountUserKey(acct.id))
        }
        activate(acct, token: resp.token, user: resp.user)
    }

    /// A server rejected our token (401 on an authenticated call). A single 401
    /// is NOT proof the session died: a restarting server or proxy race emits
    /// spurious ones while the token is still good, and ending the session on
    /// one showed a false "session expired, sign in again" that an app restart
    /// disproved (seen in the field 2026-09-13). Probe the server once more
    /// before believing it; only a second explicit 401 ends the session.
    /// Ignored when the origin isn't the account we're actually on, so a stray
    /// 401 from a pinned cross-host request can't sign you out.
    func handleUnauthorized(origin: String) {
        let host = Config.normalize(origin)
        guard let acct = activeAccount, Config.normalize(acct.serverOrigin) == host else { return }
        guard let current = token, !verifyingUnauthorized else { return }  // 401s arrive in bursts
        verifyingUnauthorized = true
        Task {
            defer { verifyingUnauthorized = false }
            do {
                _ = try await APIClient(token: current, origin: acct.serverOrigin).projects()
                // Token still accepted — the 401 was a hiccup; keep the session.
            } catch APIError.http(401, _, _) {
                guard token == current else { return }  // switched meanwhile
                Keychain.set(nil, for: accountTokenKey(acct.id), shared: true)
                Keychain.set(nil, for: tokenAccount)
                token = nil
                reauthReturn = nil
                reauthNeeded = acct
            } catch {
                // Network/other failure proves nothing about the token — never
                // sign the user out over a connectivity blip.
            }
        }
    }
    private var verifyingUnauthorized = false

    /// Switch the whole environment to a saved account (Gmail-style).
    func switchTo(_ account: SavedAccount) {
        guard account.id != activeAccountId else { return }
        guard let saved = Keychain.get(accountTokenKey(account.id), shared: true) else {
            // Token lost or expired away. This used to DELETE the account on the
            // spot: the row vanished with no explanation, and the user was left
            // re-adding it from scratch against a login form pre-filled with the
            // WRONG host — which then failed as "invalid username or password".
            // Keep the entry and ask for a re-login instead; the account still
            // exists on the server, only our token is gone. End the current
            // session as we go: you asked to be on THIS account, so leaving the
            // previous one active would both lie about where you are and leave
            // the sign-in with nothing to present it (RootView only shows it in
            // the unauthenticated state). The other accounts stay saved, and
            // `reauthReturn` remembers where "Back" should land.
            reauthReturn = activeAccount
            Keychain.set(nil, for: tokenAccount)
            token = nil
            activeAccountId = nil
            reauthNeeded = account
            return
        }
        var savedUser: User? = nil
        if let data = AppGroup.defaults.data(forKey: accountUserKey(account.id)) {
            savedUser = try? JSONDecoder().decode(User.self, from: data)
        }
        activate(account, token: saved, user: savedUser ?? User(id: 0, username: account.username))
    }

    /// Leave a pinned re-login WITHOUT signing in: back to the account that was
    /// active before the switch, or failing that any other saved account whose
    /// token still works — never a dead-end empty login while live sessions
    /// exist. Falls through to the plain sign-in only when nothing is left.
    func cancelReauth() {
        let dead = reauthNeeded?.id
        reauthNeeded = nil
        let back = reauthReturn
        reauthReturn = nil
        let candidates = (back.map { [$0] } ?? []) + accounts.filter { $0.id != dead }
        for acct in candidates {
            guard let tok = Keychain.get(accountTokenKey(acct.id), shared: true) else { continue }
            var savedUser: User? = nil
            if let data = AppGroup.defaults.data(forKey: accountUserKey(acct.id)) {
                savedUser = try? JSONDecoder().decode(User.self, from: data)
            }
            activate(acct, token: tok, user: savedUser ?? User(id: 0, username: acct.username))
            return
        }
    }

    private func activate(_ account: SavedAccount, token newToken: String, user newUser: User) {
        Config.serverOrigin = account.serverOrigin
        token = newToken
        user = newUser
        activeAccountId = account.id
        isDemo = false
        reauthReturn = nil
        // Legacy single-token key mirrors the ACTIVE account — every existing
        // consumer (stores, media URLs) keeps reading the same place.
        Keychain.set(newToken, for: tokenAccount)
        if let data = try? JSONEncoder().encode(newUser) {
            UserDefaults.standard.set(data, forKey: userKey)
        }
        persistAccounts()
        accountEpoch += 1
        // The routing map is per-host state — refetch it for the new active
        // server right away, not only when the Agents list next loads.
        Task { await refreshAgentHosts() }
    }

    /// Forget a saved account (its token included). If it was active, fall over
    /// to the next saved account, or to the login screen when none remain.
    func removeAccount(_ account: SavedAccount) {
        accounts.removeAll { $0.id == account.id }
        Keychain.set(nil, for: accountTokenKey(account.id), shared: true)
        AppGroup.defaults.removeObject(forKey: accountUserKey(account.id))
        persistAccounts()
        // Conservative hygiene: cached transcripts must not outlive a login.
        // Wipes ALL accounts' snapshots — they rebuild on the next open —
        // and drops every live conversation store (sockets included).
        ConversationRegistry.shared.clearAll()
        ChatCacheStore.shared.clearAll()
        if account.id == activeAccountId {
            // Fall over to the next account that still has a usable token. Clear the
            // stale active token FIRST so we can never end up "authenticated"
            // (token != nil) with no active account when no fallover token survives —
            // that stranded the app on a dead session instead of the login screen.
            activeAccountId = nil
            token = nil
            if let next = accounts.first(where: { Keychain.get(accountTokenKey($0.id), shared: true) != nil }) {
                switchTo(next)
            } else {
                clearActive()
            }
        }
    }

    /// Sign out of the ACTIVE account only (Gmail semantics).
    func logout() {
        if let acct = activeAccount {
            removeAccount(acct)
        } else {
            clearActive()
        }
    }

    private func clearActive() {
        token = nil
        user = nil
        isDemo = false
        activeAccountId = nil
        Keychain.set(nil, for: tokenAccount)
        UserDefaults.standard.removeObject(forKey: userKey)
        persistAccounts()
        accountEpoch += 1
    }
}
