package com.manarz.myagent.chat

import android.content.Context
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.PersonOff
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.manarz.myagent.R
import com.manarz.myagent.core.Beacon
import com.manarz.myagent.core.Config as HostConfig
import com.mymu.app.core.AppState
import com.mymu.app.core.ChatCacheStore
import com.mymu.app.core.Config as MyMuConfig
import com.mymu.app.core.Haptics
import com.mymu.app.core.Harness
import com.mymu.app.core.Prefs
import com.mymu.app.core.Project
import com.mymu.app.core.ProjectsStore
import com.mymu.app.core.RecentlyViewedStore
import com.mymu.app.core.TokenCountStore
import com.mymu.app.core.UnauthorizedBus
import com.mymu.app.ui.AgentStatus
import com.mymu.app.ui.AgentsScreen
import com.mymu.app.ui.ChatScreen
import com.mymu.app.ui.ChatSwitcher
import com.mymu.app.ui.ChatTarget
import com.mymu.app.ui.FilePreviewScreen
import com.mymu.app.ui.FilesScreen
import com.mymu.app.ui.McpServersScreen
import com.mymu.app.ui.MyMuColors
import com.mymu.app.ui.MyMuLoader
import com.mymu.app.ui.MyMuTheme
import com.mymu.app.ui.ProjectDetailScreen
import com.mymu.app.ui.Route
import com.mymu.app.ui.TrackTextSelection
import com.mymu.app.ui.routed
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/**
 * The brain's chat = the vendored MyMu client (com.mymu.app, see
 * android/VENDORING.md), hosted as the drawer under the swarm. Port of iOS
 * App/BrainChat.swift: which host to sign in to, which agent the drawer opens,
 * the curated swipe roster + its dots, the closed drawer's peek row.
 */
object ChatModule {
    /** ONE roster for the peek and the drawer (iOS keeps it in PetView). */
    val store = ProjectsStore()

    /** The agent the drawer is on when it is not the brain. Survives a
     * close/reopen of the drawer; a cold launch starts at the brain (null). */
    val currentAgent = MutableStateFlow<ChatTarget?>(null)

    private var loadedEpoch = -1
    private var loadedKey = ""

    /** MyMu's own Application.onCreate block (MyMuApplication), run by the host. */
    fun init(ctx: Context) {
        Prefs.init(ctx)
        Haptics.init(ctx)
        ChatCacheStore.init(ctx)
        AppState.load()
        TokenCountStore.load()
        RecentlyViewedStore.load()
        // Signed out: MyMu's server defaults to the host the voice /config names.
        if (!AppState.isAuthenticated) MyMuConfig.serverOrigin = HostConfig.mymuHost
    }

    /** Signed-in MyMu username (Settings shows it), null = signed out. */
    val user: String? get() = if (AppState.token.value != null) AppState.user.value?.username else null

    fun signOut() {
        AppState.logout()
        store.projects.value = emptyList()
        currentAgent.value = null
        loadedEpoch = -1
    }

    /** The drawer's roster: the curated list from /config, else the brain alone. */
    fun rosterNames(): List<String> =
        HostConfig.mymuAgentsCSV.split(",").map { it.trim() }.filter { it.isNotEmpty() }
            .ifEmpty { listOf(HostConfig.mymuAgent) }

    /** Legacy agent-view token from the /config chat URL (fallback path only). */
    fun legacyToken(chatURL: String = HostConfig.chatURL): String? {
        if (chatURL.isBlank()) return null
        val t = runCatching { Uri.parse(chatURL).getQueryParameter("token") }.getOrNull()
        return t?.takeIf { it.isNotEmpty() && !it.contains("__") }
    }

    val signedIn: Boolean get() = AppState.isAuthenticated || legacyToken() != null

    /**
     * BrainAccess.load: the roster for whoever is signed in; with nobody signed
     * in and a legacy token at hand, point the vendored client at the chat
     * URL's own server and hand it the token (no login screen, not persisted).
     */
    suspend fun load(force: Boolean = false) {
        store.agentFilter = rosterNames()
        val epoch = AppState.accountEpoch.value
        val key = HostConfig.chatURL + "|" + HostConfig.mymuAgentsCSV
        if (!force && epoch == loadedEpoch && key == loadedKey && store.projects.value.isNotEmpty()) return
        if (!AppState.isAuthenticated) {
            val tok = legacyToken() ?: return
            val u = Uri.parse(HostConfig.chatURL)
            u.host?.let { h ->
                val port = if (u.port > 0) ":${u.port}" else ""
                MyMuConfig.serverOrigin = "${u.scheme ?: "https"}://$h$port"
            }
            AppState.token.value = tok
        }
        loadedEpoch = epoch; loadedKey = key
        store.load(AppState.api)
        ChatCacheStore.warm(store.projects.value.mapNotNull { it.remoteSessionId })
    }

    /** The brain by name: a bridge-connected (remote) agent titled like the profile's brain. */
    fun brainAgent(name: String = HostConfig.mymuAgent): Project? {
        val want = name.lowercase()
        if (want.isEmpty()) return null
        return store.agents.firstOrNull {
            it.displayName.lowercase() == want || (it.sessions?.firstOrNull()?.summary ?: "").lowercase() == want
        }
    }

    val onlyAgent: Project? get() = store.agents.singleOrNull()

    fun targetFor(p: Project) = ChatTarget(
        sessionId = p.remoteSessionId ?: p.projectId.removePrefix("remote:"),
        projectId = p.projectId, title = p.displayName, isRemote = true)

    /** What the drawer opens: the brain agent, else the only agent, else the
     * newest conversation of the brain's LOCAL project (or the first project). */
    fun brainTarget(name: String = HostConfig.mymuAgent): ChatTarget? {
        (brainAgent(name) ?: onlyAgent)?.let { return targetFor(it) }
        val want = name.lowercase()
        val p = store.folders.firstOrNull {
            it.displayName.lowercase() == want || (it.path ?: "").lowercase().endsWith("/$want")
        } ?: store.folders.firstOrNull() ?: return null
        val s = p.sessions.orEmpty().maxByOrNull { it.sortKey } ?: return null
        return ChatTarget(sessionId = s.id, projectId = p.projectId, title = p.displayName,
            isRemote = false, projectPath = p.path)
    }
}

/** Keep the roster fresh + live agent status while a chat surface is on screen. */
@Composable
private fun RosterFeed() {
    val epoch by AppState.accountEpoch.collectAsState()
    LaunchedEffect(epoch) { ChatModule.load() }
    LaunchedEffect(Unit) {
        // a rejected token: MyMu probes once more before it ends the session
        UnauthorizedBus.events.collect { AppState.handleUnauthorized(it) }
    }
    LaunchedEffect(epoch) {
        while (true) {
            delay(10_000)
            if (AppState.isAuthenticated) runCatching { ChatModule.store.applyAgentStatus(AppState.api.agentStatus()) }
        }
    }
}

/** The open drawer's content: the brain's MyMu conversation. */
@Composable
fun DrawerChat(full: Boolean, onDictate: () -> Unit, modifier: Modifier = Modifier) {
    MyMuTheme {
        TrackTextSelection {
            Column(modifier.fillMaxSize().background(MyMuColors.background)) {
                RosterFeed()
                DrawerBody(full, onDictate)
            }
        }
    }
}

@Composable
private fun DrawerBody(full: Boolean, onDictate: () -> Unit) {
    val store = ChatModule.store
    val token by AppState.token.collectAsState()
    val reauth by AppState.reauthNeeded.collectAsState()
    val projects by store.projects.collectAsState()
    val loading by store.loading.collectAsState()
    val error by store.error.collectAsState()
    val current by ChatModule.currentAgent.collectAsState()
    val agentHosts by AppState.agentHostAssignments.collectAsState()
    val accounts by AppState.accounts.collectAsState()
    val scope = rememberCoroutineScope()
    // in-drawer navigation (files, previews, MCP) above the conversation
    var stack by remember { mutableStateOf<List<Route>>(emptyList()) }

    val roster = remember(projects, HostConfig.mymuAgentsCSV) { store.rosterOf(projects) }
    val active: ChatTarget? = remember(projects, current) {
        current?.takeIf { t -> store.agents.any { it.projectId == t.projectId } } ?: ChatModule.brainTarget()
    }

    // a swipe settles → the drawer swaps conversations in place
    LaunchedEffect(Unit) {
        ChatSwitcher.target.collect { t ->
            if (t == null) return@collect
            ChatModule.currentAgent.value = t
            stack = emptyList()
            ChatSwitcher.target.value = null
        }
    }
    BackHandler(stack.isNotEmpty()) { stack = stack.dropLast(1) }

    // ---- the strip above the chat: dictate (full only) + the agent dots
    if (full || roster.size > 1) {
        Box(Modifier.fillMaxWidth().height(34.dp)) {
            if (full) DictateButton(Modifier.align(Alignment.CenterStart).padding(start = 6.dp), onDictate)
            AgentDots(roster, active?.projectId, Modifier.align(Alignment.Center)) { p ->
                ChatModule.currentAgent.value = ChatModule.targetFor(p)
                stack = emptyList()
            }
        }
    }
    if (full) DictationBar()

    Box(Modifier.fillMaxSize()) {
        val top = stack.lastOrNull()
        val expired = reauth
        when {
            top != null -> when (top) {
                is Route.Chat -> {
                    val t = remember(top.target, agentHosts, accounts) { top.target.routed() }
                    key("${t.sessionId}|${t.origin ?: ""}") {
                        ChatScreen(t, onBack = { stack = stack.dropLast(1) }, onOpen = { stack = stack + it }, store = store)
                    }
                }
                is Route.ProjectDetail -> key(top.project.projectId) {
                    ProjectDetailScreen(top.project, onOpen = { stack = stack + it }, onBack = { stack = stack.dropLast(1) })
                }
                is Route.Files -> key(top) { FilesScreen(top, onOpen = { stack = stack + it }, onBack = { stack = stack.dropLast(1) }) }
                is Route.FilePreview -> key(top) { FilePreviewScreen(top, onBack = { stack = stack.dropLast(1) }) }
                Route.McpServers -> McpServersScreen(onBack = { stack = stack.dropLast(1) })
            }
            expired != null -> MyMuSignIn(expired.serverOrigin, HostConfig.mymuAgent, expired.username)
            token == null && ChatModule.legacyToken() == null -> MyMuSignIn(HostConfig.mymuHost, HostConfig.mymuAgent)
            loading && projects.isEmpty() -> MyMuLoader(modifier = Modifier.fillMaxSize())
            active != null -> {
                val t = remember(active, agentHosts, accounts) { active.routed() }
                key("${t.sessionId}|${t.origin ?: ""}") {
                    // the drawer is the conversation's root: Back closes nothing here
                    ChatScreen(t, onBack = {}, onOpen = { stack = stack + it }, store = store)
                }
            }
            store.agents.isNotEmpty() -> AgentsScreen(store,
                onOpen = { r -> if (r is Route.Chat) ChatModule.currentAgent.value = r.target else stack = stack + r },
                onAddAccount = {}, onOpenMcp = { stack = stack + Route.McpServers })
            else -> Hint(
                error?.let { "Couldn’t reach MyMu: $it" }
                    ?: "No agent is visible for this login right now.\nCheck that ${HostConfig.mymuAgent} is running, then retry.",
                onRetry = { scope.launch { store.loading.value = true; ChatModule.load(force = true) } },
                onSignOut = if (token != null) ({ ChatModule.signOut() }) else null,
            )
        }
    }
}

@Composable
private fun Hint(text: String, onRetry: () -> Unit, onSignOut: (() -> Unit)?) {
    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally) {
        Text(text, color = MyMuColors.mutedText, textAlign = TextAlign.Center, fontSize = 14.sp)
        Spacer(Modifier.height(12.dp))
        OutlinedButton(onClick = onRetry) { Text("Retry", color = MyMuColors.primary) }
        onSignOut?.let { TextButton(onClick = it) { Text("Sign out", color = MyMuColors.mutedText, fontSize = 13.sp) } }
    }
}

/** One dot per agent of the curated roster, the current one stretched (page-control idiom). */
@Composable
private fun AgentDots(roster: List<Project>, currentId: String?, modifier: Modifier, onPick: (Project) -> Unit) {
    if (roster.size < 2) return
    Row(modifier.semantics { contentDescription = "agent-dots" }, horizontalArrangement = Arrangement.spacedBy(7.dp),
        verticalAlignment = Alignment.CenterVertically) {
        for (p in roster) {
            val on = p.projectId == currentId
            Box(Modifier.padding(vertical = 8.dp).width(if (on) 20.dp else 6.dp).height(6.dp).clip(CircleShape)
                .background(if (on) MyMuColors.primary else Color.White.copy(alpha = 0.26f))
                .clickable(enabled = !on) { Haptics.send(); onPick(p) }
                .semantics { contentDescription = if (on) "${p.displayName}, current" else "Switch to ${p.displayName}" })
        }
    }
}

/** The closed drawer's peek row: the brain's (or current agent's) name + state. */
@Composable
fun BrainPeek(modifier: Modifier = Modifier) {
    RosterFeed()
    val projects by ChatModule.store.projects.collectAsState()
    val error by ChatModule.store.error.collectAsState()
    val current by ChatModule.currentAgent.collectAsState()
    val token by AppState.token.collectAsState()
    val agentName = HostConfig.mymuAgent
    val agent: Project? = remember(projects, current) {
        current?.let { t -> ChatModule.store.agents.firstOrNull { it.projectId == t.projectId } }
            ?: ChatModule.brainAgent() ?: ChatModule.onlyAgent
    }
    Row(modifier.height(30.dp).semantics { contentDescription = "brain-peek" },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        when {
            agent != null -> {
                val h = agent.remoteSessionId?.let { Harness.fromSessionId(it) }
                if (h != null) Image(painterResource(harnessIcon(h)), h.label, Modifier.size(16.dp))
                else Icon(Icons.Filled.AutoAwesome, null, tint = MyMuColors.primary, modifier = Modifier.size(14.dp))
                Text(agent.displayName, color = MyMuColors.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                Box(Modifier.size(6.dp).clip(CircleShape).background(AgentStatus.color(agent)))
                Text(AgentStatus.text(agent), color = MyMuColors.mutedText, fontSize = 12.sp, maxLines = 1)
            }
            token == null && ChatModule.legacyToken() == null -> {
                Icon(Icons.Filled.PersonOff, null, tint = MyMuColors.mutedText, modifier = Modifier.size(15.dp))
                Text("Sign in to write to $agentName", color = MyMuColors.mutedText, fontSize = 15.sp, maxLines = 1)
            }
            else -> {
                Icon(Icons.Filled.AutoAwesome, null, tint = MyMuColors.primary, modifier = Modifier.size(14.dp))
                Text(agentName, color = MyMuColors.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                Text(if (error == null) "connecting…" else "unreachable", color = MyMuColors.mutedText, fontSize = 12.sp)
            }
        }
        Spacer(Modifier.weight(1f))
        Icon(Icons.Filled.KeyboardArrowUp, null, tint = MyMuColors.mutedText, modifier = Modifier.size(18.dp))
    }
}

private fun harnessIcon(h: Harness): Int = when (h) {
    Harness.CLAUDE -> R.drawable.harness_claude
    Harness.OPENCODE -> R.drawable.harness_opencode
    Harness.CODEX -> R.drawable.harness_codex
    Harness.CURSOR -> R.drawable.harness_cursor
}

/** "mymu-login" beacons, so the server log shows the chat sign-in outcome. */
internal fun loginBeacon(ok: Boolean) = Beacon.send(if (ok) "mymu-login-ok" else "mymu-login-failed")
