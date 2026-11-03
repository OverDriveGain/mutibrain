package com.mymu.app.core

import kotlinx.coroutines.flow.MutableStateFlow

/**
 * One shared fetch of `/api/projects`, consumed by the Agents, Chats and
 * Projects tabs so they stay in sync and don't each hit the network.
 * (1:1 port of iOS Core/ProjectsStore.swift.)
 */
class ProjectsStore {
    val projects = MutableStateFlow<List<Project>>(emptyList())
    val loading = MutableStateFlow(true)
    val error = MutableStateFlow<String?>(null)
    var isDemo = false
        private set
    private var loaded = false

    companion object {
        /** Pre-seeded store for the network-free demo. */
        fun demo(): ProjectsStore = ProjectsStore().apply {
            isDemo = true
            loading.value = false
            projects.value = DemoData.projects
        }
    }

    suspend fun loadIfNeeded(api: ApiClient) {
        if (isDemo || loaded) return
        load(api)
    }

    suspend fun load(api: ApiClient) {
        if (isDemo) return
        error.value = null
        try {
            projects.value = api.projects()
            loaded = true
        } catch (e: Exception) {
            error.value = e.message ?: "Could not load projects."
        }
        loading.value = false
    }

    /** Merge live agent running/connected flags. Only publishes when something
     * actually changed, so the poll doesn't cause pointless re-renders. */
    fun applyAgentStatus(statuses: List<ApiClient.AgentStatusEntry>) {
        if (statuses.isEmpty()) return
        val byId = statuses.associateBy { it.id }
        var changed = false
        val next = projects.value.map { p ->
            if (p.isRemoteAgent != true) return@map p
            val st = p.remoteSessionId?.let { byId[it] } ?: return@map p
            if (p.remoteRunning != st.running || p.remoteConnected != st.connected) {
                changed = true
                p.copy(remoteRunning = st.running, remoteConnected = st.connected)
            } else p
        }
        if (changed) projects.value = next
    }

    // HOST PATCH (MyAgent): the drawer's curated roster — see VENDORING.md.
    var agentFilter: List<String>? = null
    fun rosterOf(list: List<Project>): List<Project> {
        val all = list.filter { it.isRemoteAgent == true }
        val names = agentFilter?.takeIf { it.isNotEmpty() } ?: return all
        val out = mutableListOf<Project>()
        for (n in names) {
            val w = n.lowercase()
            val p = all.firstOrNull { it.displayName.lowercase() == w }
                ?: all.firstOrNull { (it.sessions?.firstOrNull()?.summary ?: "").lowercase() == w }
            if (p != null && out.none { it.projectId == p.projectId }) out += p
        }
        return out
    }
    val agents: List<Project> get() = rosterOf(projects.value)
    val folders: List<Project> get() = projects.value.filter { it.isRemoteAgent != true }

    /** Flat, recency-sorted sessions across all local projects — the "Chats" tab. */
    val recents: List<RecentItem>
        get() {
            val items = mutableListOf<RecentItem>()
            for (p in folders) {
                for (s in (p.sessions ?: emptyList())) {
                    items += RecentItem("${p.projectId}|${s.id}", p, s)
                }
            }
            return items.sortedByDescending { it.session.sortKey }
        }
}

data class RecentItem(val id: String, val project: Project, val session: Session)
