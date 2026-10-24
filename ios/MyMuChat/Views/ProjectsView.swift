import SwiftUI

/// Projects = folders. Each opens to its conversations. (NavigationStack lives
/// in MainTabView.)
struct ProjectsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: ProjectsStore
    @State private var query = ""

    private var filtered: [Project] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.folders }
        return store.folders.filter {
            $0.displayName.localizedCaseInsensitiveContains(q)
                || ($0.fullPath ?? $0.path ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search projects")
        .navigationTitle("Projects")
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { ProfileMenu() } }
    }

    @ViewBuilder
    private var content: some View {
        if store.loading && store.projects.isEmpty {
            MyMuLoader().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.folders.isEmpty {
            EmptyStateView(text: store.error ?? "No projects yet.") { Task { await store.load(appState.api) } }
        } else if filtered.isEmpty {
            EmptyStateView(text: "No projects match “\(query)”.")
        } else {
            List(filtered) { p in
                NavigationLink(value: Route.projectDetail(p)) { row(p) }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Theme.border)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .refreshable { await store.load(appState.api) }
        }
    }

    private func row(_ p: Project) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 3) {
                IconTile(symbol: "folder")
                // A folder can hold mixed-harness sessions; badge only when
                // every session agrees, so the label can't lie about a project.
                if let h = uniformHarness(p) { HarnessBadge(harness: h) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(p.displayName).foregroundColor(Theme.text).font(.body).lineLimit(1)
                let count = p.sessions?.count ?? 0
                Text("\(count) conversation\(count == 1 ? "" : "s")")
                    .font(.caption2).foregroundColor(Theme.mutedText)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// The project's harness IF unambiguous: all sessions resolve to the same
    /// one. Mixed or unknown → nil, no badge — never a majority guess.
    private func uniformHarness(_ p: Project) -> Harness? {
        let resolved = (p.sessions ?? []).compactMap {
            Harness(sessionId: $0.id, provider: $0.provider)
        }
        guard let first = resolved.first, resolved.count == (p.sessions?.count ?? 0),
              resolved.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}
