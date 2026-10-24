import SwiftUI

/// Conversations tab — a flat, most-recent-first list of every session across
/// projects (MyMu's "Recents"). NavigationStack lives in MainTabView.
struct RecentsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: ProjectsStore
    @State private var query = ""
    /// Shared token-count cache — persisted values render instantly; rows fire
    /// one short-timeout probe each as they scroll into view. Lazy-per-row on
    /// purpose: this list spans EVERY session of every project.
    @ObservedObject private var tokenCounts = TokenCountStore.shared

    private var filtered: [RecentItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.recents }
        return store.recents.filter {
            $0.session.displayTitle.localizedCaseInsensitiveContains(q)
                || $0.project.displayName.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search conversations")
        .navigationTitle("Conversations")
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { ProfileMenu() } }
    }

    @ViewBuilder
    private var content: some View {
        if store.loading && store.projects.isEmpty {
            MyMuLoader().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.recents.isEmpty {
            EmptyStateView(text: "No conversations yet.") { Task { await store.load(appState.api) } }
        } else if filtered.isEmpty {
            EmptyStateView(text: "No conversations match “\(query)”.")
        } else {
            List(filtered) { item in
                NavigationLink(value: Route.chat(ChatTarget(
                    sessionId: item.session.id, projectId: item.project.projectId, isRemote: false,
                    title: item.session.displayTitle,
                    projectPath: item.project.fullPath ?? item.project.path,
                    provider: item.session.provider))) {
                    row(item)
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Theme.border)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .refreshable { await store.load(appState.api) }
        }
    }

    private func row(_ item: RecentItem) -> some View {
        HStack(spacing: 12) {
            // Same info discipline as the Agents list, minus agent-only state
            // (online dots don't belong to a conversation): harness under the
            // icon, consumption on the trailing edge. Local claude sessions
            // have bare-UUID ids — no prefix, no badge, correctly nothing.
            VStack(spacing: 3) {
                IconTile(symbol: "bubble.left.and.bubble.right", size: 34)
                // Prefix for live agents, provider field for local sessions —
                // between them every conversation gets its harness logo.
                if let h = Harness(sessionId: item.session.id, provider: item.session.provider) {
                    HarnessBadge(harness: h)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.session.displayTitle).foregroundColor(Theme.text).font(.body).lineLimit(1)
                Text(item.project.displayName).font(.caption2).foregroundColor(Theme.mutedText).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(compactAge(item.session.sortKey)).font(.caption2).foregroundColor(Theme.mutedText)
                if let used = tokenCounts.counts[item.session.id] {
                    Text(Self.tokensCompact(used))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.mutedText.opacity(0.85))
                }
            }
        }
        .padding(.vertical, 4)
        .task {
            guard !store.isDemo else { return }
            await tokenCounts.probe(sessionId: item.session.id, api: appState.api)
        }
    }

    private static func tokensCompact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(Int((Double(n) / 1_000).rounded()))k" }
        return "\(n)"
    }
}
