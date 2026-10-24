import SwiftUI

/// Live remote-control agents — the default tab. Non-expandable leaf rows with a
/// status dot, exactly like MyMu's Agents view. (NavigationStack + path live in
/// MainTabView so tab switches keep your place.)
struct AgentsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: ProjectsStore
    @ObservedObject private var recents = RecentlyViewedStore.shared
    @State private var query = ""
    /// Shared token-count cache: persisted values render instantly, probes
    /// revalidate concurrently in the background. Refreshed per roster change
    /// and on pull-to-refresh, NOT on the 5s status poll.
    @ObservedObject private var tokenCounts = TokenCountStore.shared

    private var filtered: [Project] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.agents }
        return store.agents.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search agents")
        .navigationTitle("Agents")
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        // Usage refresh lives in the NAV BAR, on the profile button — the iOS
        // spot for quiet background activity. It started as a bar+text capsule
        // over the list, then a bottom hairline, then a plain spinner beside
        // the icon; Manar wanted it out of the content area (2026-09-20) and
        // then distinct from the everyday spinners (2026-09-29) — a long batch
        // now wears a determinate ring AROUND the account icon (App Store
        // download idiom). Counts still animate into the rows as they land.
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                ProfileMenu()
                    .overlay {
                        if let p = tokenCounts.progress, p.total > 0 {
                            BatchProgressRing(fraction: Double(p.done) / Double(p.total))
                                .transition(.opacity)
                                .accessibilityLabel("Updating usage \(p.done) of \(p.total)")
                        }
                    }
                    .animation(.easeOut(duration: 0.25), value: tokenCounts.progress == nil)
            }
        }
        // Live running/connected dots: the projects fetch is a one-shot snapshot,
        // so the list's spinner lagged reality (or never appeared). Poll the cheap
        // agent-status endpoint every 5s while this tab is visible; the store only
        // publishes on real changes. .task cancels on tab switch automatically.
        .task {
            guard !store.isDemo else { return }
            // Agent→host pinning map: loaded alongside the roster so opening a
            // pinned agent routes its conversation to the right host.
            await appState.refreshAgentHosts()
            while !Task.isCancelled {
                if let st = try? await appState.api.agentStatus() {
                    store.applyAgentStatus(st)
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        // Consumption counts follow the roster, not the status poll.
        .task(id: store.agents.map(\.projectId).joined(separator: "|")) {
            guard !store.isDemo else { return }
            // Chat snapshots decode into RAM while the user is still browsing
            // the list, so opening any agent seeds its transcript at init.
            ChatCacheStore.shared.warm(sessionIds: store.agents.compactMap(\.remoteSessionId))
            await tokenCounts.refresh(sessionIds: store.agents.compactMap(\.remoteSessionId),
                                      api: appState.api)
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.loading && store.projects.isEmpty {
            MyMuLoader().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.agents.isEmpty {
            EmptyStateView(text: store.error ?? "No agents found.") { Task { await store.load(appState.api) } }
        } else if filtered.isEmpty {
            EmptyStateView(text: "No agents match “\(query)”.")
        } else {
            List {
                if query.isEmpty && !recents.items.isEmpty {
                    Section {
                        lastSeenChips
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }
                }
                ForEach(filtered) { agent in
                    NavigationLink(value: Route.chat(ChatTarget(
                        sessionId: agent.remoteSessionId ?? agent.projectId.replacingOccurrences(of: "remote:", with: ""),
                        projectId: agent.projectId, isRemote: true, title: agent.displayName))) {
                        row(agent)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Theme.border)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .refreshable {
                // The gesture ends when the ROSTER lands (fast). Counts re-pull
                // in the background and narrate their own progress below — a
                // pull pinned to the slowest probe read as "never finishes".
                await store.load(appState.api)
                guard !store.isDemo else { return }
                let ids = store.agents.compactMap(\.remoteSessionId)
                let api = appState.api
                Task { await TokenCountStore.shared.refresh(sessionIds: ids, api: api, force: true) }
            }
        }
    }

    /// "Last seen" — the conversations the user most recently OPENED, as a small
    /// horizontal history strip. Remote entries re-resolve to the agent's CURRENT
    /// session (ids rotate on agent restarts).
    private var lastSeenChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(recents.items) { r in
                    NavigationLink(value: Route.chat(chipTarget(r))) {
                        HStack(spacing: 6) {
                            Image(systemName: r.isRemote ? "terminal" : "bubble.left")
                                .font(.caption2).foregroundColor(Theme.primary)
                            Text(r.title).font(.caption).foregroundColor(Theme.text)
                                .lineLimit(1).frame(maxWidth: 140)
                        }
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(Theme.surface)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }

    private func chipTarget(_ r: RecentlyViewed) -> ChatTarget {
        if r.isRemote, let agent = store.agents.first(where: { $0.projectId == r.projectId }),
           let sid = agent.remoteSessionId {
            return ChatTarget(sessionId: sid, projectId: agent.projectId, isRemote: true, title: agent.displayName)
        }
        return ChatTarget(sessionId: r.sessionId, projectId: r.projectId, isRemote: r.isRemote,
                          title: r.title, projectPath: r.projectPath)
    }

    private static func tokensCompact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(Int((Double(n) / 1_000).rounded()))k" }
        return "\(n)"
    }

    private func row(_ p: Project) -> some View {
        HStack(spacing: 12) {
            // Harness rides UNDER the icon (Manar's layout call): the tile
            // column carries "what kind of thing this is", the text column
            // stays purely name + status.
            VStack(spacing: 3) {
                IconTile(symbol: "terminal")
                if let sid = p.remoteSessionId, let h = Harness(sessionId: sid) {
                    HarnessBadge(harness: h)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(p.displayName).foregroundColor(Theme.text).font(.body).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(AgentStatus.color(p)).frame(width: 7, height: 7)
                    Text(AgentStatus.text(p)).font(.caption2).foregroundColor(Theme.mutedText)
                }
            }
            Spacer()
            // Context consumed by this agent's conversation, same number the
            // chat's status strip shows — absent (not zero) when unknown.
            if let sid = p.remoteSessionId, let used = tokenCounts.counts[sid] {
                Text(Self.tokensCompact(used))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.mutedText.opacity(0.85))
                    .contentTransition(.numericText())
                    .animation(.default, value: used)
            }
            if p.remoteRunning == true { ProgressView().scaleEffect(0.7).tint(Theme.primary) }
        }
        .padding(.vertical, 4)
        .opacity(AgentStatus.dimmed(p) ? 0.6 : 1)
    }
}
