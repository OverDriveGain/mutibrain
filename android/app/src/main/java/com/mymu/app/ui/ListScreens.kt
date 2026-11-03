package com.mymu.app.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.EditNote
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Inventory2
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.PullToRefreshDefaults
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.manarz.myagent.R // HOST PATCH: host resources
import com.mymu.app.core.AppState
import com.mymu.app.core.Harness
import com.mymu.app.core.Project
import com.mymu.app.core.ProjectsStore
import com.mymu.app.core.RecentItem
import com.mymu.app.core.RecentlyViewedStore
import com.mymu.app.core.RelayClient
import com.mymu.app.core.Session
import com.mymu.app.core.TokenCountStore
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

// Shared bits ---------------------------------------------------------------

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MyMuTopBar(title: String, onBack: (() -> Unit)? = null, actions: @Composable () -> Unit = {}) {
    TopAppBar(
        title = {
            Text(title, color = MyMuColors.text, fontWeight = FontWeight.SemiBold,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
        },
        navigationIcon = {
            if (onBack != null) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back",
                        tint = MyMuColors.text)
                }
            }
        },
        actions = { actions() },
        colors = TopAppBarDefaults.topAppBarColors(
            containerColor = MyMuColors.background,
            titleContentColor = MyMuColors.text,
        ),
    )
}

/** The harness logo, sized to sit under a row's leading icon tile. */
@Composable
fun HarnessBadge(harness: Harness) {
    val res = when (harness) {
        Harness.CLAUDE -> R.drawable.harness_claude
        Harness.OPENCODE -> R.drawable.harness_opencode
        Harness.CODEX -> R.drawable.harness_codex
        Harness.CURSOR -> R.drawable.harness_cursor
    }
    Image(painterResource(res), contentDescription = harness.label, modifier = Modifier.size(15.dp))
}

/** Rounded square icon tile used across list rows, harness logo underneath. */
@Composable
fun IconTile(icon: ImageVector, harness: Harness? = null, statusDot: Color? = null, size: Int = 38) {
    Column(horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Box(
            Modifier.size(size.dp).background(MyMuColors.surface, RoundedCornerShape(10.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = MyMuColors.primary,
                modifier = Modifier.size((size * 0.5).dp))
            if (statusDot != null) {
                Box(Modifier.align(Alignment.TopEnd).padding(3.dp).size(8.dp)
                    .background(statusDot, CircleShape))
            }
        }
        harness?.let { HarnessBadge(it) }
    }
}

@Composable
fun CenteredNote(text: String, danger: Boolean = false, retry: (() -> Unit)? = null) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(text, color = if (danger) MyMuColors.danger else MyMuColors.mutedText,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(24.dp))
            if (retry != null) {
                TextButton(onClick = retry) { Text("Retry", color = MyMuColors.primary) }
            }
        }
    }
}

@Composable
fun LoadingBox() {
    // Branded loader, not a generic spinner — every list/chat loading state on
    // iOS shows the MyMu wordmark wave (MyMuLoader.swift).
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        MyMuLoader()
    }
}

/**
 * Material pull-to-refresh around a populated list — the counterpart of iOS
 * `.refreshable` on Projects/Chats/Agents/Archive/MCP lists. Brand-tinted
 * indicator; the caller owns the refreshing flag so the gesture can end when
 * the fast part lands (the Agents list narrates its probes separately).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RefreshableList(
    refreshing: Boolean,
    onRefresh: () -> Unit,
    content: @Composable () -> Unit,
) {
    val state = rememberPullToRefreshState()
    PullToRefreshBox(
        isRefreshing = refreshing,
        onRefresh = onRefresh,
        state = state,
        modifier = Modifier.fillMaxSize(),
        indicator = {
            PullToRefreshDefaults.Indicator(
                state = state,
                isRefreshing = refreshing,
                modifier = Modifier.align(Alignment.TopCenter),
                containerColor = MyMuColors.surface,
                color = MyMuColors.primary,
            )
        },
    ) {
        content()
    }
}

/** Inline search field used at the top of list screens. */
@Composable
fun SearchField(query: String, onQuery: (String) -> Unit, placeholder: String) {
    TextField(
        value = query, onValueChange = onQuery, singleLine = true,
        placeholder = { Text(placeholder, color = MyMuColors.mutedText) },
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 2.dp),
        shape = RoundedCornerShape(12.dp),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = MyMuColors.surface,
            unfocusedContainerColor = MyMuColors.surface,
            focusedTextColor = MyMuColors.text,
            unfocusedTextColor = MyMuColors.text,
            cursorColor = MyMuColors.primary,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
        ),
    )
}

/** Compact relative age ("<1m", "5m", "3hr", "2d") — mirrors the web client. */
fun compactAge(iso: String?): String {
    val ms = iso?.let { RelayClient.parseIso(it) } ?: return ""
    val s = (System.currentTimeMillis() - ms) / 1000
    return when {
        s < 60 -> "<1m"
        s < 3600 -> "${s / 60}m"
        s < 86400 -> "${s / 3600}hr"
        else -> "${s / 86400}d"
    }
}

/** Agent status colors/labels (port of iOS AgentStatus). */
object AgentStatus {
    fun color(p: Project): Color = when {
        p.remoteRunning == true -> MyMuColors.primary
        p.remoteConnected != false -> Color(0xFF30D158)
        else -> MyMuColors.mutedText
    }
    fun text(p: Project): String = when {
        p.remoteRunning == true -> "working…"
        p.remoteConnected != false -> "agent"
        else -> "agent · offline"
    }
    fun dimmed(p: Project): Boolean = p.remoteConnected == false
}

/**
 * Profile button + accounts sheet + add-account hand-off. `batchProgress`
 * (done, total) wraps the icon in a [BatchProgressRing] while a long batch
 * runs — the Agents tab's usage-probe fan-out.
 */
@Composable
fun ProfileMenu(onAddAccount: () -> Unit, onOpenMcp: () -> Unit,
                batchProgress: Pair<Int, Int>? = null) {
    var showAccounts by remember { mutableStateOf(false) }
    // Keep the last value through the fade-out so the ring doesn't vanish
    // mid-transition when the batch ends (progress flips to null).
    var lastProgress by remember { mutableStateOf(0 to 0) }
    batchProgress?.let { lastProgress = it }
    IconButton(onClick = { showAccounts = true }) {
        Box(contentAlignment = Alignment.Center) {
            Icon(Icons.Outlined.AccountCircle, contentDescription = "Accounts", tint = MyMuColors.primary)
            AnimatedVisibility(
                visible = batchProgress != null && batchProgress.second > 0,
                enter = fadeIn(tween(250)), exit = fadeOut(tween(250)),
            ) {
                val (done, total) = lastProgress
                BatchProgressRing(
                    fraction = if (total > 0) done.toFloat() / total else 0f,
                    modifier = Modifier.semantics {
                        contentDescription = "Updating usage $done of $total"
                    },
                )
            }
        }
    }
    if (showAccounts) {
        AccountsSheet(
            onAddAccount = onAddAccount,
            onOpenMcp = onOpenMcp,
            onDismiss = { showAccounts = false },
        )
    }
}

// Projects ------------------------------------------------------------------

/** The project's harness IF unambiguous — never a majority guess. */
private fun uniformHarness(p: Project): Harness? {
    val sessions = p.sessions ?: emptyList()
    val resolved = sessions.mapNotNull { Harness.from(it.id, it.provider) }
    val first = resolved.firstOrNull() ?: return null
    if (resolved.size != sessions.size || !resolved.all { it == first }) return null
    return first
}

@Composable
fun ProjectsScreen(store: ProjectsStore, onOpen: (Route) -> Unit,
                   onAddAccount: () -> Unit, onOpenMcp: () -> Unit) {
    val projects by store.projects.collectAsStateWithLifecycle()
    val loading by store.loading.collectAsStateWithLifecycle()
    val error by store.error.collectAsStateWithLifecycle()
    var query by remember { mutableStateOf("") }
    var refreshing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    Column(Modifier.fillMaxSize()) {
        MyMuTopBar("Projects") { ProfileMenu(onAddAccount, onOpenMcp) }
        val folders = projects.filter { it.isRemoteAgent != true }
        val filtered = if (query.isBlank()) folders else folders.filter {
            it.displayName.contains(query.trim(), true) ||
                (it.fullPath ?: it.path ?: "").contains(query.trim(), true)
        }
        when {
            loading && projects.isEmpty() -> LoadingBox()
            folders.isEmpty() -> CenteredNote(error ?: "No projects yet.")
            else -> {
                SearchField(query, { query = it }, "Search projects")
                if (filtered.isEmpty()) CenteredNote("No projects match \"$query\".")
                else RefreshableList(refreshing, onRefresh = {
                    scope.launch { refreshing = true; store.load(AppState.api); refreshing = false }
                }) { LazyColumn {
                    items(filtered, key = { it.projectId }) { p ->
                        Row(
                            Modifier.fillMaxWidth()
                                .clickable { onOpen(Route.ProjectDetail(p)) }
                                .padding(horizontal = 16.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            IconTile(Icons.Outlined.Folder, uniformHarness(p))
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(p.displayName, color = MyMuColors.text, maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    style = MaterialTheme.typography.bodyLarge)
                                val count = p.sessions?.size ?: 0
                                Text("$count conversation" + if (count == 1) "" else "s",
                                    color = MyMuColors.mutedText,
                                    style = MaterialTheme.typography.labelSmall)
                            }
                        }
                    }
                } }
            }
        }
    }
}

@Composable
fun ProjectDetailScreen(project: Project, onOpen: (Route) -> Unit, onBack: () -> Unit) {
    var query by remember { mutableStateOf("") }
    val sessions = remember(project) {
        (project.sessions ?: emptyList()).sortedByDescending { it.sortKey }
    }
    val newChatTarget = ChatTarget(sessionId = "", projectId = project.projectId,
        title = project.displayName, isRemote = false,
        projectPath = project.fullPath ?: project.path)

    Column(Modifier.fillMaxSize()) {
        MyMuTopBar(project.displayName, onBack = onBack) {
            IconButton(onClick = { onOpen(Route.Chat(newChatTarget)) }) {
                Icon(Icons.Outlined.EditNote, contentDescription = "New conversation",
                    tint = MyMuColors.primary)
            }
        }
        if (sessions.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("No conversations yet.", color = MyMuColors.mutedText)
                    TextButton(onClick = { onOpen(Route.Chat(newChatTarget)) }) {
                        Text("New conversation", color = MyMuColors.primary)
                    }
                }
            }
            return
        }
        SearchField(query, { query = it }, "Search conversations")
        val filtered = if (query.isBlank()) sessions
        else sessions.filter { it.displayTitle.contains(query.trim(), true) }
        if (filtered.isEmpty()) { CenteredNote("No conversations match \"$query\"."); return }
        LazyColumn {
            items(filtered, key = { it.id }) { s ->
                SessionRow(s, subtitleProject = null) {
                    onOpen(Route.Chat(ChatTarget(
                        sessionId = s.id, projectId = project.projectId,
                        title = s.displayTitle, isRemote = false,
                        projectPath = project.fullPath ?: project.path, provider = s.provider)))
                }
            }
        }
    }
}

@Composable
private fun SessionRow(s: Session, subtitleProject: String?, tokenCount: Int? = null,
                       onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconTile(Icons.AutoMirrored.Outlined.Chat, Harness.from(s.id, s.provider), size = 34)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(s.displayTitle, color = MyMuColors.text, maxLines = 1,
                overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyLarge)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                subtitleProject?.let {
                    Text(it, color = MyMuColors.mutedText, maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.labelSmall)
                }
                // Hide zero counts: stock servers report 0 for CLI-synced rows.
                s.messageCount?.takeIf { it > 0 }?.let {
                    Text("$it messages", color = MyMuColors.mutedText,
                        style = MaterialTheme.typography.labelSmall)
                }
                Text(compactAge(s.sortKey), color = MyMuColors.mutedText,
                    style = MaterialTheme.typography.labelSmall)
            }
        }
        tokenCount?.let {
            Text(TokenCountStore.compactLabel(it), color = MyMuColors.mutedText.copy(alpha = 0.85f),
                style = MaterialTheme.typography.labelSmall)
        }
    }
}

// Chats (recents) -----------------------------------------------------------

@Composable
fun RecentsScreen(store: ProjectsStore, onOpen: (Route) -> Unit,
                  onAddAccount: () -> Unit, onOpenMcp: () -> Unit) {
    val loading by store.loading.collectAsStateWithLifecycle()
    @Suppress("UNUSED_VARIABLE") val projects by store.projects.collectAsStateWithLifecycle()
    val counts by TokenCountStore.counts.collectAsStateWithLifecycle()
    var query by remember { mutableStateOf("") }
    var refreshing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    Column(Modifier.fillMaxSize()) {
        MyMuTopBar("Conversations") { ProfileMenu(onAddAccount, onOpenMcp) }
        val recents = store.recents
        val filtered = if (query.isBlank()) recents else recents.filter {
            it.session.displayTitle.contains(query.trim(), true) ||
                it.project.displayName.contains(query.trim(), true)
        }
        when {
            loading && recents.isEmpty() -> LoadingBox()
            recents.isEmpty() -> CenteredNote("No conversations yet.")
            else -> {
                SearchField(query, { query = it }, "Search conversations")
                if (filtered.isEmpty()) { CenteredNote("No conversations match \"$query\".") }
                else RefreshableList(refreshing, onRefresh = {
                    scope.launch { refreshing = true; store.load(AppState.api); refreshing = false }
                }) { LazyColumn {
                    items(filtered, key = { it.id }) { r ->
                        // Lazy per-row token probe as rows scroll into view.
                        if (!store.isDemo) {
                            LaunchedEffect(r.session.id) {
                                TokenCountStore.probe(r.session.id, AppState.api)
                            }
                        }
                        SessionRow(r.session, subtitleProject = r.project.displayName,
                            tokenCount = counts[r.session.id]) {
                            onOpen(Route.Chat(ChatTarget(
                                sessionId = r.session.id, projectId = r.project.projectId,
                                title = r.session.displayTitle, isRemote = false,
                                projectPath = r.project.fullPath ?: r.project.path,
                                provider = r.session.provider)))
                        }
                    }
                } }
            }
        }
    }
}

// Agents --------------------------------------------------------------------

@Composable
fun AgentsScreen(store: ProjectsStore, onOpen: (Route) -> Unit,
                 onAddAccount: () -> Unit, onOpenMcp: () -> Unit) {
    val loading by store.loading.collectAsStateWithLifecycle()
    @Suppress("UNUSED_VARIABLE") val projects by store.projects.collectAsStateWithLifecycle()
    val counts by TokenCountStore.counts.collectAsStateWithLifecycle()
    val lastSeen by RecentlyViewedStore.items.collectAsStateWithLifecycle()
    val probeProgress by TokenCountStore.progress.collectAsStateWithLifecycle()
    var query by remember { mutableStateOf("") }
    var refreshing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    // Live status poll while visible + agent→host pinning map; consumption
    // counts follow the roster, not the 5s status poll.
    LaunchedEffect(Unit) {
        if (store.isDemo) return@LaunchedEffect
        AppState.refreshAgentHosts()
        while (true) {
            try { store.applyAgentStatus(AppState.api.agentStatus()) } catch (_: Exception) {}
            delay(5_000)
        }
    }
    LaunchedEffect(store.agents.map { it.projectId }.joinToString("|")) {
        if (store.isDemo) return@LaunchedEffect
        TokenCountStore.refresh(store.agents.mapNotNull { it.remoteSessionId }, AppState.api)
    }

    fun chatTarget(agent: Project): ChatTarget {
        val sessionId = agent.remoteSessionId ?: agent.projectId.removePrefix("remote:")
        val route = AppState.routeForAgent(agent.displayName)
        return ChatTarget(
            sessionId = sessionId, projectId = agent.projectId, title = agent.displayName,
            isRemote = true, origin = route?.first, tokenOverride = route?.second,
            pinnedHostNeedingLogin = AppState.pinnedHostNeedingLogin(agent.displayName),
            isDemo = store.isDemo)
    }

    Column(Modifier.fillMaxSize()) {
        // Usage refresh lives on the profile button (iOS c376a47): a long
        // probe batch wears a determinate ring AROUND the account icon,
        // distinct from everyday spinners. It started as a bottom chip
        // ("Updating usage 4/9"); Manar wanted it out of the content area.
        // Counts still animate into the rows as they land.
        MyMuTopBar("Agents") { ProfileMenu(onAddAccount, onOpenMcp, batchProgress = probeProgress) }
        val agents = store.agents
        val filtered = if (query.isBlank()) agents
        else agents.filter { it.displayName.contains(query.trim(), true) }
        Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
        when {
            loading && agents.isEmpty() -> LoadingBox()
            agents.isEmpty() -> CenteredNote("No agents found.")
            else -> {
                SearchField(query, { query = it }, "Search agents")
                if (filtered.isEmpty()) { CenteredNote("No agents match \"$query\".") }
                else RefreshableList(refreshing, onRefresh = {
                    // The gesture ends when the ROSTER lands (fast). Counts
                    // re-pull in the background and narrate their own progress
                    // in the chip below — a pull pinned to the slowest probe
                    // read as "never finishes" (iOS 6cb7674).
                    scope.launch {
                        refreshing = true
                        store.load(AppState.api)
                        refreshing = false
                        if (!store.isDemo) {
                            val ids = store.agents.mapNotNull { it.remoteSessionId }
                            scope.launch { TokenCountStore.refresh(ids, AppState.api, force = true) }
                        }
                    }
                }) { LazyColumn {
                    // "Last seen" — conversations the user most recently OPENED.
                    if (query.isBlank() && lastSeen.isNotEmpty()) {
                        item(key = "last-seen") {
                            Row(
                                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                                    .padding(horizontal = 16.dp, vertical = 6.dp),
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                for (r in lastSeen) {
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        modifier = Modifier
                                            .border(1.dp, MyMuColors.border, CircleShape)
                                            .background(MyMuColors.surface, CircleShape)
                                            .clickable {
                                                // Remote entries re-resolve to the agent's
                                                // CURRENT session (ids rotate on restarts).
                                                val agent = if (r.isRemote)
                                                    agents.firstOrNull { it.projectId == r.projectId }
                                                else null
                                                val target = if (agent != null) chatTarget(agent)
                                                else ChatTarget(r.sessionId, r.projectId, r.title,
                                                    r.isRemote, r.projectPath)
                                                onOpen(Route.Chat(target))
                                            }
                                            .padding(horizontal = 11.dp, vertical = 7.dp),
                                    ) {
                                        Icon(
                                            if (r.isRemote) Icons.Outlined.Terminal
                                            else Icons.AutoMirrored.Outlined.Chat,
                                            contentDescription = null, tint = MyMuColors.primary,
                                            modifier = Modifier.size(12.dp))
                                        Spacer(Modifier.width(6.dp))
                                        Text(r.title, color = MyMuColors.text,
                                            style = MaterialTheme.typography.labelMedium,
                                            maxLines = 1, overflow = TextOverflow.Ellipsis,
                                            modifier = Modifier.widthIn(max = 140.dp))
                                    }
                                }
                            }
                        }
                    }
                    items(filtered, key = { it.projectId }) { a ->
                        Row(
                            Modifier.fillMaxWidth()
                                .clickable { onOpen(Route.Chat(chatTarget(a))) }
                                .padding(horizontal = 16.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            IconTile(Icons.Outlined.Terminal,
                                a.remoteSessionId?.let { Harness.fromSessionId(it) })
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(a.displayName, color = MyMuColors.text, maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    style = MaterialTheme.typography.bodyLarge)
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Box(Modifier.size(7.dp).background(AgentStatus.color(a), CircleShape))
                                    Spacer(Modifier.width(5.dp))
                                    Text(AgentStatus.text(a), color = MyMuColors.mutedText,
                                        style = MaterialTheme.typography.labelSmall)
                                }
                            }
                            // Context consumed — absent (not zero) when unknown.
                            a.remoteSessionId?.let { sid ->
                                counts[sid]?.let {
                                    Text(TokenCountStore.compactLabel(it),
                                        color = MyMuColors.mutedText.copy(alpha = 0.85f),
                                        style = MaterialTheme.typography.labelSmall)
                                }
                            }
                            if (a.remoteRunning == true) {
                                Spacer(Modifier.width(8.dp))
                                CircularProgressIndicator(Modifier.size(12.dp),
                                    color = MyMuColors.primary, strokeWidth = 2.dp)
                            }
                        }
                    }
                } }
            }
        }
        }
        }
    }
}

// Archive -------------------------------------------------------------------

@Composable
fun ArchiveScreen(store: ProjectsStore, onOpen: (Route) -> Unit) {
    var archived by remember { mutableStateOf<List<Project>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var query by remember { mutableStateOf("") }
    var refreshing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    suspend fun load() {
        if (store.isDemo) { archived = emptyList(); return }
        try { archived = AppState.api.archivedProjects(); error = null }
        catch (e: Exception) { error = e.message; archived = archived ?: emptyList() }
    }
    LaunchedEffect(Unit) { load() }

    Column(Modifier.fillMaxSize()) {
        MyMuTopBar("Archive")
        val list = archived
        val items = (list ?: emptyList()).flatMap { p ->
            (p.sessions ?: emptyList()).map { s -> RecentItem("${p.projectId}|${s.id}", p, s) }
        }.sortedByDescending { it.session.sortKey }
        val filtered = if (query.isBlank()) items else items.filter {
            it.session.displayTitle.contains(query.trim(), true) ||
                it.project.displayName.contains(query.trim(), true)
        }
        when {
            list == null -> LoadingBox()
            items.isEmpty() -> CenteredNote(error ?: "No archived conversations.")
            else -> {
                SearchField(query, { query = it }, "Search archive")
                if (filtered.isEmpty()) { CenteredNote("No conversations match \"$query\".") }
                else RefreshableList(refreshing, onRefresh = {
                    scope.launch { refreshing = true; load(); refreshing = false }
                }) { LazyColumn {
                    items(filtered, key = { it.id }) { r ->
                        Row(
                            Modifier.fillMaxWidth()
                                .clickable {
                                    onOpen(Route.Chat(ChatTarget(
                                        sessionId = r.session.id, projectId = r.project.projectId,
                                        title = r.session.displayTitle, isRemote = false,
                                        projectPath = r.project.fullPath ?: r.project.path,
                                        provider = r.session.provider)))
                                }
                                .padding(horizontal = 16.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            IconTile(Icons.Outlined.Inventory2, size = 34)
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f)) {
                                Text(r.session.displayTitle, color = MyMuColors.text, maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    style = MaterialTheme.typography.bodyLarge)
                                Text(r.project.displayName, color = MyMuColors.mutedText,
                                    maxLines = 1, style = MaterialTheme.typography.labelSmall)
                            }
                            Text(compactAge(r.session.sortKey), color = MyMuColors.mutedText,
                                style = MaterialTheme.typography.labelSmall)
                        }
                    }
                } }
            }
        }
    }
}
