package com.mymu.app.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import com.mymu.app.ui.AccessPayload
import org.json.JSONArray
import org.json.JSONObject

/**
 * A saved login: one server + one user on it. Gmail-style — the app keeps a
 * list of these and exactly ONE is active at a time; switching swaps the whole
 * environment. (1:1 port of iOS Core/AppState.swift, persistence keys included.)
 */
data class SavedAccount(val serverOrigin: String, val username: String) {
    val id: String get() = "$serverOrigin|$username"

    /** Short display host, e.g. "code.kaxtus.com". */
    val hostLabel: String
        get() = serverOrigin.replace("https://", "").replace("http://", "")

    fun toJson(): JSONObject = JSONObject().put("serverOrigin", serverOrigin).put("username", username)

    companion object {
        fun fromJson(o: JSONObject) = SavedAccount(o.optString("serverOrigin", ""), o.optString("username", ""))
    }
}

object AppState {
    val token = MutableStateFlow<String?>(null)
    val user = MutableStateFlow<User?>(null)
    val accounts = MutableStateFlow<List<SavedAccount>>(emptyList())
    val activeAccountId = MutableStateFlow<String?>(null)
    /** Bumped on every account switch — the root re-keys the tab tree on it. */
    val accountEpoch = MutableStateFlow(0)
    /** Set when switching to a saved account whose token is gone: the account is
     * KEPT and the UI presents a pre-filled sign-in for exactly that host+user. */
    val reauthNeeded = MutableStateFlow<SavedAccount?>(null)
    /** Where "Back" from that pinned sign-in returns: the account that was
     * active before the switch (its token still works). Without it, leaving
     * the sign-in dead-ended at an empty login while working sessions existed. */
    private var reauthReturn: SavedAccount? = null
    /** Agent → host assignments from the server (agent title → host origin). */
    val agentHostAssignments = MutableStateFlow<Map<String, String>>(emptyMap())
    /** A scanned/tapped mymu://login access link waiting to be consumed by a
     * login screen (RootView routes it; LoginScreen fills itself and clears it).
     * Set by MainActivity's VIEW-intent handling — the iOS onOpenURL. */
    val pendingAccess = MutableStateFlow<AccessPayload?>(null)
    /** Local, network-free preview (canned DemoData) — the "Try the demo"
     * button on the login screen; the app is explorable with no server. */
    val isDemo = MutableStateFlow(false)

    private const val TOKEN_ACCOUNT = "auth-token" // legacy + always-the-ACTIVE-account token
    private const val USER_KEY = "mymu.user"
    private const val ACCOUNTS_KEY = "mymu.accounts"
    private const val ACTIVE_KEY = "mymu.activeAccount"
    private const val AGENT_HOSTS_KEY = "mymu.agentHosts"

    private fun accountTokenKey(id: String) = "auth-token|$id"
    private fun accountUserKey(id: String) = "mymu.user|$id"

    /** Call once after Prefs.init — the iOS init block. */
    fun load() {
        token.value = Prefs.getString(TOKEN_ACCOUNT)
        Prefs.getString(USER_KEY)?.let { raw ->
            try { user.value = User.fromJson(JSONObject(raw)) } catch (_: Exception) {}
        }
        Prefs.getString(ACCOUNTS_KEY)?.let { raw ->
            try {
                val arr = JSONArray(raw)
                accounts.value = (0 until arr.length()).mapNotNull {
                    (arr.opt(it) as? JSONObject)?.let(SavedAccount::fromJson)
                }
            } catch (_: Exception) {}
        }
        activeAccountId.value = Prefs.getString(ACTIVE_KEY)
        // Last-known agent→host routing map — a chat opened before the first
        // refresh lands must still route to the agent's pinned host.
        Prefs.getString(AGENT_HOSTS_KEY)?.let { raw ->
            try {
                val o = JSONObject(raw)
                agentHostAssignments.value = buildMap { for (k in o.keys()) put(k, o.getString(k)) }
            } catch (_: Exception) {}
        }
        // Migration: a pre-accounts install has a lone token+user — adopt it.
        val t = token.value; val u = user.value
        if (accounts.value.isEmpty() && t != null && u != null) {
            val acct = SavedAccount(Config.serverOrigin, u.username)
            accounts.value = listOf(acct)
            activeAccountId.value = acct.id
            Prefs.putString(accountTokenKey(acct.id), t)
            persistAccounts()
        }
    }

    val isAuthenticated: Boolean get() = token.value != null
    val api: ApiClient get() = ApiClient(token.value)
    val activeAccount: SavedAccount? get() = accounts.value.firstOrNull { it.id == activeAccountId.value }

    /** The saved token for ANY account (the share sheet sends as a picked
     * account without switching the app to it). null = needs re-login. */
    fun tokenFor(account: SavedAccount): String? = Prefs.getString(accountTokenKey(account.id))

    // MARK: Agent → host routing

    /**
     * Refresh the admin-set agent→host map from the active server. Cheap; call
     * when the agents list loads and after account switches. Persisted so a
     * cold launch routes correctly BEFORE the first fetch lands — the map used
     * to start empty every launch, and a chat opened in that window silently
     * bound to the wrong host (iOS field bug 2026-09-27: sends reached the
     * agent through the relay, but the transcript came from a host that lagged).
     */
    suspend fun refreshAgentHosts() {
        if (token.value == null || isDemo.value) return
        try {
            val map = api.agentHosts()
            agentHostAssignments.value = map
            Prefs.putString(AGENT_HOSTS_KEY, JSONObject(map as Map<*, *>).toString())
        } catch (_: Exception) {}
    }

    /**
     * Where a pinned agent's conversation should connect: the assigned host +
     * the saved account's token for it. null = the active host.
     */
    fun routeForAgent(title: String): Pair<String, String>? {
        val assigned = agentHostAssignments.value[title] ?: return null
        val origin = Config.normalize(assigned)
        if (origin == Config.normalize(Config.serverOrigin)) return null
        val acct = accounts.value.firstOrNull { Config.normalize(it.serverOrigin) == origin } ?: return null
        val tok = Prefs.getString(accountTokenKey(acct.id)) ?: return null
        return origin to tok
    }

    /** Host label when the agent is pinned to a host the app has NO saved login
     * for — the composer warns and points at "Add account". */
    fun pinnedHostNeedingLogin(title: String): String? {
        val assigned = agentHostAssignments.value[title] ?: return null
        val origin = Config.normalize(assigned)
        if (origin == Config.normalize(Config.serverOrigin)) return null
        val hasLogin = accounts.value.any { acct ->
            Config.normalize(acct.serverOrigin) == origin && Prefs.getString(accountTokenKey(acct.id)) != null
        }
        return if (hasLogin) null else origin.replace("https://", "").replace("http://", "")
    }

    private fun persistAccounts() {
        val arr = JSONArray()
        for (a in accounts.value) arr.put(a.toJson())
        Prefs.putString(ACCOUNTS_KEY, arr.toString())
        Prefs.putString(ACTIVE_KEY, activeAccountId.value)
    }

    /** Sign in to (or add) an account on the CURRENT Config.serverOrigin and
     * make it active. Same call for first login and "Add account". */
    suspend fun login(username: String, password: String) {
        val resp = ApiClient.login(username, password)
        val acct = SavedAccount(Config.serverOrigin, resp.user.username)
        // Remember host+user for login autocomplete — deliberately OUTSIDE the
        // account store, so signing out doesn't force retyping the origin.
        LoginHistory.record(Config.serverOrigin, resp.user.username)
        accounts.value = accounts.value.filter { it.id != acct.id } + acct
        Prefs.putString(accountTokenKey(acct.id), resp.token)
        Prefs.putString(accountUserKey(acct.id), resp.user.toJson().toString())
        activate(acct, resp.token, resp.user)
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var verifyingUnauthorized = false

    /**
     * A server rejected our token (401 on an authenticated call). A single 401
     * is NOT proof the session died: a restarting server or proxy race emits
     * spurious ones while the token is still good, and ending the session on
     * one showed a false "session expired" that an app restart disproved
     * (iOS field find 2026-09-13, ported here). Probe the server once more
     * before believing it; only a second explicit 401 ends the session.
     */
    fun handleUnauthorized(origin: String) {
        val host = Config.normalize(origin)
        val acct = activeAccount ?: return
        if (Config.normalize(acct.serverOrigin) != host) return
        val current = token.value ?: return  // already handled; 401s arrive in bursts
        if (verifyingUnauthorized) return
        verifyingUnauthorized = true
        scope.launch {
            try {
                ApiClient(current, acct.serverOrigin).projects()
                // Token still accepted — the 401 was a hiccup; keep the session.
            } catch (e: ApiException) {
                if (e.code == 401 && token.value == current) {  // not switched meanwhile
                    Prefs.putString(accountTokenKey(acct.id), null)
                    Prefs.putString(TOKEN_ACCOUNT, null)
                    token.value = null
                    reauthReturn = null
                    reauthNeeded.value = acct
                }
                // Non-401 server errors prove nothing about the token.
            } catch (_: Exception) {
                // Network failure proves nothing about the token — never sign
                // the user out over a connectivity blip.
            } finally {
                verifyingUnauthorized = false
            }
        }
    }

    /** Leave a pinned re-login WITHOUT signing in: back to the account that was
     * active before the switch, or failing that any other saved account whose
     * token still works — never a dead-end empty login while live sessions
     * exist. Falls through to the plain sign-in only when nothing is left. */
    fun cancelReauth() {
        val dead = reauthNeeded.value?.id
        reauthNeeded.value = null
        val back = reauthReturn
        reauthReturn = null
        val candidates = (back?.let { listOf(it) } ?: emptyList()) +
            accounts.value.filter { it.id != dead }
        for (acct in candidates) {
            val tok = Prefs.getString(accountTokenKey(acct.id)) ?: continue
            val savedUser = Prefs.getString(accountUserKey(acct.id))?.let { raw ->
                try { User.fromJson(JSONObject(raw)) } catch (_: Exception) { null }
            }
            activate(acct, tok, savedUser ?: User(0, acct.username))
            return
        }
    }

    /** Switch the whole environment to a saved account (Gmail-style). */
    fun switchTo(account: SavedAccount) {
        if (account.id == activeAccountId.value) return
        val saved = Prefs.getString(accountTokenKey(account.id))
        if (saved == null) {
            // Token lost or expired away — keep the entry and ask for a
            // re-login. End the current session as we go; `reauthReturn`
            // remembers where "Back" should land.
            reauthReturn = activeAccount
            Prefs.putString(TOKEN_ACCOUNT, null)
            token.value = null
            activeAccountId.value = null
            reauthNeeded.value = account
            return
        }
        val savedUser = Prefs.getString(accountUserKey(account.id))?.let { raw ->
            try { User.fromJson(JSONObject(raw)) } catch (_: Exception) { null }
        }
        activate(account, saved, savedUser ?: User(0, account.username))
    }

    private fun activate(account: SavedAccount, newToken: String, newUser: User) {
        Config.serverOrigin = account.serverOrigin
        token.value = newToken
        user.value = newUser
        activeAccountId.value = account.id
        isDemo.value = false  // a real login ends the demo (iOS activate)
        reauthReturn = null
        // Legacy single-token key mirrors the ACTIVE account.
        Prefs.putString(TOKEN_ACCOUNT, newToken)
        Prefs.putString(USER_KEY, newUser.toJson().toString())
        persistAccounts()
        accountEpoch.value += 1
        // The routing map is per-host state — refetch it for the new active
        // server right away, not only when the Agents list next loads.
        scope.launch { refreshAgentHosts() }
    }

    /** Forget a saved account (its token included). If it was active, fall over
     * to the next saved account, or to the login screen when none remain. */
    fun removeAccount(account: SavedAccount) {
        accounts.value = accounts.value.filter { it.id != account.id }
        // Stop that server pushing to a device that no longer holds its login —
        // needs the token, so before it is wiped.
        tokenFor(account)?.let { PushManager.unregister(account, it) }
        Prefs.putString(accountTokenKey(account.id), null)
        Prefs.putString(accountUserKey(account.id), null)
        persistAccounts()
        // Conservative hygiene: cached transcripts must not outlive a login.
        // Wipes ALL accounts' snapshots — they rebuild on the next open —
        // and drops every live conversation store (sockets included).
        ConversationRegistry.clearAll()
        ChatCacheStore.clearAll()
        if (account.id == activeAccountId.value) {
            // Clear the stale active token FIRST so we can never end up
            // "authenticated" with no active account.
            activeAccountId.value = null
            token.value = null
            val next = accounts.value.firstOrNull { Prefs.getString(accountTokenKey(it.id)) != null }
            if (next != null) switchTo(next) else clearActive()
        }
    }

    fun enterDemo() { isDemo.value = true }

    /**
     * UI-test hook (`mymu.reset=1` launch extra, DEBUG — iOS MYMU_RESET /
     * wipeForUITests): forget every persisted trace of a session BEFORE the UI
     * composes, so a test launch always starts at the sign-in. The
     * instrumentation install keeps the app's data, so a login left by a
     * manual pass would otherwise skip the login screen and break every
     * demo-entry test. Live stores and cached transcripts go too — a demo chat
     * left mid-turn by one test must not be the next test's opening state.
     * Unlike iOS the remembered server origin is kept: it is the login
     * screen's prefill, and these tests never sign in.
     */
    fun wipeForUITests() {
        for (acct in accounts.value) {
            Prefs.putString(accountTokenKey(acct.id), null)
            Prefs.putString(accountUserKey(acct.id), null)
        }
        accounts.value = emptyList()
        agentHostAssignments.value = emptyMap()
        Prefs.putString(AGENT_HOSTS_KEY, null)
        reauthNeeded.value = null
        reauthReturn = null
        isDemo.value = false
        clearActive()
        ConversationRegistry.clearAll()
        ChatCacheStore.clearAll()
    }

    /** Sign out of the ACTIVE account only (Gmail semantics). */
    fun logout() {
        val acct = activeAccount
        if (acct != null) removeAccount(acct) else clearActive()
    }

    private fun clearActive() {
        token.value = null
        user.value = null
        // iOS clearActive: no account left means the login screen, never a
        // demo fleet that a "Try the demo" tap left armed underneath.
        isDemo.value = false
        activeAccountId.value = null
        Prefs.putString(TOKEN_ACCOUNT, null)
        Prefs.putString(USER_KEY, null)
        persistAccounts()
        accountEpoch.value += 1
    }
}
