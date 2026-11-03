package com.mymu.app.ui

import com.mymu.app.core.AppState
import com.mymu.app.core.FileNode
import com.mymu.app.core.Project

/**
 * Everything a ChatScreen needs to attach: the session, where it lives, and —
 * for pinned agents — the routed host + its token (agent→host pinning, same
 * contract as the iOS RelayClient origin override).
 */
data class ChatTarget(
    val sessionId: String,
    val projectId: String,
    val title: String,
    val isRemote: Boolean,
    val projectPath: String? = null,
    /** Session provider when the origin list knew it (local sessions carry a
     * real one). Live agents resolve their harness from the id prefix. */
    val provider: String? = null,
    val origin: String? = null,
    val tokenOverride: String? = null,
    /** Pinned to a host with NO saved login — the composer's file warning. */
    val pinnedHostNeedingLogin: String? = null,
    /** Network-free demo conversation (canned DemoData transcript). */
    val isDemo: Boolean = false,
)

/**
 * The target with agent→host pinning resolved NOW, from the current routing
 * map — iOS RouteView resolves `routeForAgent` at render time the same way.
 * The map loads async; a target built before it landed carries the active
 * host, and re-resolving on every render lets a late-arriving map rebind the
 * open chat to the agent's pinned host. Same rules as the Agents-list row
 * construction, so an already-routed target resolves to itself.
 */
fun ChatTarget.routed(): ChatTarget {
    if (!isRemote || isDemo) return this
    val route = AppState.routeForAgent(title)
    return copy(origin = route?.first, tokenOverride = route?.second,
        pinnedHostNeedingLogin = AppState.pinnedHostNeedingLogin(title))
}

/** In-tab navigation destinations (hand-rolled per-tab back stacks). */
sealed interface Route {
    data class ProjectDetail(val project: Project) : Route
    data class Chat(val target: ChatTarget) : Route
    /** One level of a project's file tree; null path = the root. A level
     * whose contents are already in hand travels with them (`preloaded`) —
     * the server's file-tree route returns the WHOLE nested tree and ignores
     * `path`, so refetching per level would show the root everywhere (iOS
     * FileBrowser's preloaded/fetchPath split). */
    data class Files(val projectId: String, val title: String, val path: String? = null,
                     val origin: String? = null, val tokenOverride: String? = null,
                     val preloaded: List<FileNode>? = null) : Route
    data class FilePreview(val projectId: String, val name: String, val path: String,
                           val origin: String? = null, val tokenOverride: String? = null) : Route
    data object McpServers : Route
}
