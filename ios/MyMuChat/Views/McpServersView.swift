import SwiftUI

/// The MCP servers configured on the active host, grouped by scope.
///
/// READ + REMOVE only. Creating a server means composing a transport, command,
/// argv, env vars and headers — a form that belongs on a keyboard, not a phone,
/// and one where a typo produces a broken server rather than an obvious error.
/// Seeing what's configured and removing a bad entry are the two things worth
/// doing from a phone, so those are what this does.
struct McpServersView: View {
    let api: APIClient

    @State private var servers: [APIClient.McpServer] = []
    @State private var loading = true
    @State private var error: String?
    @State private var pendingDelete: APIClient.McpServer?

    /// user / local / project, in that order — user scope is the machine-wide
    /// set and the one most likely to be what you came to check.
    private var scopes: [String] {
        let present = Set(servers.map { $0.scope ?? "other" })
        return ["user", "local", "project", "other"].filter { present.contains($0) }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle("MCP servers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            pendingDelete.map { "Remove “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let s = pendingDelete { Task { await remove(s) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The agent will lose this server's tools on its next run.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading && servers.isEmpty {
            MyMuLoader().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            EmptyStateView(text: error) { Task { await load() } }
        } else if servers.isEmpty {
            EmptyStateView(text: "No MCP servers configured on this host.") { Task { await load() } }
        } else {
            List {
                ForEach(scopes, id: \.self) { scope in
                    Section {
                        ForEach(servers.filter { ($0.scope ?? "other") == scope }) { server in
                            row(server)
                                .listRowBackground(Color.clear)
                                .listRowSeparatorTint(Theme.border)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { pendingDelete = server } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        Text(scope.uppercased())
                            .font(.caption2).foregroundColor(Theme.mutedText)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
        }
    }

    private func row(_ s: APIClient.McpServer) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: s.transport == "stdio" ? "terminal" : "network")
            VStack(alignment: .leading, spacing: 3) {
                Text(s.name).foregroundColor(Theme.text).font(.body).lineLimit(1)
                Text(s.target)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(Theme.mutedText)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let t = s.transport {
                Text(t).font(.caption2).foregroundColor(Theme.mutedText)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.surface).clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        error = nil
        do {
            servers = try await api.mcpServers()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func remove(_ s: APIClient.McpServer) async {
        do {
            try await api.deleteMcpServer(name: s.name, scope: s.scope)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
