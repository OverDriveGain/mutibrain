package com.mymu.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Message
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Inventory2
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.mymu.app.core.AppState
import com.mymu.app.core.ChatCacheStore
import com.mymu.app.core.ConversationRegistry
import com.mymu.app.core.ProjectsStore
import com.mymu.app.core.PushManager

/**
 * Port of iOS MainTabView: Projects (default), Chats, Agents, Archive. Each
 * tab keeps its own back stack, so switching tabs preserves exactly where you
 * were in each one. One shared ProjectsStore backs all tabs (the demo variant
 * when exploring without a server).
 */
@Composable
fun MainTabs(demo: Boolean = false) {
    val store = remember { if (demo) ProjectsStore.demo() else ProjectsStore() }
    var selection by remember { mutableIntStateOf(0) }
    // Per-tab navigation stacks (hand-rolled; small and predictable).
    var projectsStack by remember { mutableStateOf<List<Route>>(emptyList()) }
    var chatsStack by remember { mutableStateOf<List<Route>>(emptyList()) }
    var agentsStack by remember { mutableStateOf<List<Route>>(emptyList()) }
    var archiveStack by remember { mutableStateOf<List<Route>>(emptyList()) }
    // "Add account" presented over everything, like the iOS sheet.
    var showAddAccount by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { store.loadIfNeeded(AppState.api) }

    // Warm chat snapshots into RAM as soon as the roster is known — not just
    // when a chat opens — so a notification-opened or Chats-tab conversation
    // warm-starts too (iOS MainTabView.task parity).
    LaunchedEffect(Unit) {
        store.projects.collect { projects ->
            ChatCacheStore.warm(projects.mapNotNull { it.remoteSessionId })
        }
    }

    // Conversations the chat screen no longer owns (left mid-turn, kept live
    // by the registry) still need the app-lifecycle kicks the visible chat
    // gives its own: release presence on background, reconnect on foreground
    // (iOS MainTabView.onChange(scenePhase) → ConversationRegistry). The
    // activity's lifecycle stands in for the scene phase — single-activity app.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> ConversationRegistry.appBackgrounded()
                Lifecycle.Event.ON_START -> ConversationRegistry.appForegrounded()
                else -> {}
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // Notification tap → land IN that conversation: switch to Agents and
    // REPLACE the stack with the chat (repeated taps must not stack copies) —
    // iOS MainTabView.onReceive(pendingTarget) parity.
    LaunchedEffect(Unit) {
        PushManager.pendingTarget.collect { target ->
            if (target == null) return@collect
            selection = 2
            agentsStack = listOf(Route.Chat(ChatTarget(
                sessionId = target.sessionId, projectId = target.projectId,
                title = target.title, isRemote = true)))
            PushManager.pendingTarget.value = null
        }
    }

    fun currentStack(): List<Route> = when (selection) {
        0 -> projectsStack; 1 -> chatsStack; 2 -> agentsStack; else -> archiveStack
    }

    fun setStack(next: List<Route>) {
        when (selection) {
            0 -> projectsStack = next
            1 -> chatsStack = next
            2 -> agentsStack = next
            else -> archiveStack = next
        }
    }

    fun push(route: Route) = setStack(currentStack() + route)
    fun pop() = setStack(currentStack().dropLast(1))

    // Swipe-switcher settle → swap the visible chat IN PLACE. Same ChatTarget
    // contract as the notification path above, but no tab jump and no stack
    // reset: the new chat replaces the old at the same depth, so Back still
    // returns to the list the user came from (iOS MainTabView.replaceTop).
    LaunchedEffect(Unit) {
        ChatSwitcher.target.collect { t ->
            if (t == null) return@collect
            setStack(currentStack().dropLast(1) + Route.Chat(t))
            ChatSwitcher.target.value = null
        }
    }

    BackHandler(enabled = currentStack().isNotEmpty() || showAddAccount) {
        if (showAddAccount) showAddAccount = false else pop()
    }

    if (showAddAccount) {
        // Add-account: empty server field is an explicit choice (the iOS
        // "wrong-host trap" note) — initialOrigin stays null.
        LoginScreen(
            onSuccess = { showAddAccount = false },
            onCancel = { showAddAccount = false },
        )
        return
    }

    // A conversation owns the full screen: the tab bar would just steal
    // vertical space from the transcript (iOS parity: ChatView's
    // `.toolbar(.hidden, for: .tabBar)`). `top` is re-derived from the stack
    // every recomposition, so popping back to a list auto-restores the bar —
    // no manual show-again logic — and an in-place agent-switcher swap stays
    // hidden throughout, since it only replaces the top Route.Chat with
    // another Route.Chat.
    val top = currentStack().lastOrNull()
    // Chat routes re-resolve their host whenever the routing map (or the
    // saved logins it routes through) changes.
    val agentHosts by AppState.agentHostAssignments.collectAsStateWithLifecycle()
    val accounts by AppState.accounts.collectAsStateWithLifecycle()
    Scaffold(
        containerColor = MyMuColors.background,
        // Each screen's TopAppBar consumes the status-bar inset itself; letting
        // the Scaffold ALSO pad the top double-counted it (a dead black band
        // above every title, seen on the first emulator run).
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        bottomBar = {
            if (top !is Route.Chat) {
                NavigationBar(containerColor = MyMuColors.surface) {
                    TabItem(0, selection, "Projects", Icons.Outlined.Folder) { selection = 0 }
                    TabItem(1, selection, "Chats", Icons.AutoMirrored.Outlined.Message) { selection = 1 }
                    TabItem(2, selection, "Agents", Icons.Outlined.Terminal) { selection = 2 }
                    TabItem(3, selection, "Archive", Icons.Outlined.Inventory2) { selection = 3 }
                }
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            // Destinations are keyed by their route: the top of the stack can
            // swap IN PLACE (a notification tap replaces the open chat; files
            // levels replace each other on push/pop), and same-typed routes
            // share one call site — without an explicit identity the previous
            // screen's remember{} state (composer draft, a stale load error)
            // survived into the new destination. Chat keys by session id
            // (iOS 63db4ac parity).
            when (top) {
                is Route.Chat -> {
                    // Keyed by session AND the resolved host: the routing map
                    // loads async, and a chat opened before it landed stayed
                    // bound to the wrong host for its whole life (the relay
                    // lives in remember{} state). A route change rebuilds the
                    // chat against the agent's real host — the registry's
                    // per-host store + snapshot make the swap invisible (iOS
                    // d69341c parity).
                    val target = remember(top.target, agentHosts, accounts) { top.target.routed() }
                    key("${target.sessionId}|${target.origin ?: ""}") {
                        ChatScreen(target = target, onBack = { pop() }, onOpen = { push(it) },
                            store = store)
                    }
                }
                is Route.ProjectDetail -> key(top.project.projectId) {
                    ProjectDetailScreen(project = top.project, onOpen = { push(it) }, onBack = { pop() })
                }
                is Route.Files -> key(top) { FilesScreen(top, onOpen = { push(it) }, onBack = { pop() }) }
                is Route.FilePreview -> key(top) { FilePreviewScreen(top, onBack = { pop() }) }
                Route.McpServers -> McpServersScreen(onBack = { pop() })
                null -> when (selection) {
                    0 -> ProjectsScreen(store, onOpen = { push(it) },
                        onAddAccount = { showAddAccount = true },
                        onOpenMcp = { push(Route.McpServers) })
                    1 -> RecentsScreen(store, onOpen = { push(it) },
                        onAddAccount = { showAddAccount = true },
                        onOpenMcp = { push(Route.McpServers) })
                    2 -> AgentsScreen(store, onOpen = { push(it) },
                        onAddAccount = { showAddAccount = true },
                        onOpenMcp = { push(Route.McpServers) })
                    else -> ArchiveScreen(store, onOpen = { push(it) })
                }
            }
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.TabItem(
    index: Int, selection: Int, label: String, icon: ImageVector, onClick: () -> Unit,
) {
    NavigationBarItem(
        selected = selection == index,
        onClick = onClick,
        icon = { Icon(icon, contentDescription = label) },
        label = { Text(label) },
        colors = NavigationBarItemDefaults.colors(
            selectedIconColor = MyMuColors.primary,
            selectedTextColor = MyMuColors.primary,
            unselectedIconColor = MyMuColors.mutedText,
            unselectedTextColor = MyMuColors.mutedText,
            indicatorColor = MyMuColors.elevated,
        ),
    )
}
