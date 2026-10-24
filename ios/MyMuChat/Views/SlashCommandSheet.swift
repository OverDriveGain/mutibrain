import SwiftUI

/// Pick a slash command and drop it into the composer.
///
/// A searchable SHEET rather than a Menu: the useful set here is the user-level
/// `~/.claude/commands` directory, which on a fleet machine holds dozens of
/// entries — a menu that long is unusable on a phone and can't be filtered.
///
/// Selecting inserts `/name ` into the composer instead of executing anything.
/// That's deliberate: the agent interprets its own slash commands, so insertion
/// works identically for a live agent and a local session, and it leaves you a
/// chance to add arguments before sending. `POST /api/commands/execute` exists
/// but only prepares text, so calling it would buy nothing and would fail for
/// live agents, whose commands live on the agent's own machine.
struct SlashCommandSheet: View {
    let api: APIClient
    let projectPath: String?
    let onPick: (APIClient.SlashCommand) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var commands: [APIClient.SlashCommand] = []
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?

    private var filtered: [APIClient.SlashCommand] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return commands }
        return commands.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || ($0.description ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .searchable(text: $query, prompt: "Search commands")
        .task {
            do {
                commands = try await api.slashCommands(projectPath: projectPath)
            } catch let APIError.http(code, _, host) where code >= 500 {
                // The raw body was being shown verbatim — users were reading a
                // JSON blob about `MYMU_SHOW_BUILTIN_COMMANDS`. A 5xx here is
                // the server's fault and nothing the user can act on, so say
                // that plainly and name the host so it's clear WHICH server.
                error = "\(host ?? "The server") couldn't list its commands (HTTP \(code)). "
                      + "This is a server-side fault, not something to fix on the phone."
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            MyMuLoader().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            EmptyStateView(text: error)
        } else if commands.isEmpty {
            EmptyStateView(text: "No commands on this server.")
        } else if filtered.isEmpty {
            EmptyStateView(text: "No command matches “\(query)”.")
        } else {
            List {
                ForEach(filtered) { cmd in
                    Button {
                        onPick(cmd)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(cmd.invocation)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(Theme.primary)
                                    .lineLimit(1)
                                if let ns = cmd.namespace, !ns.isEmpty, ns != "user" {
                                    Text(ns)
                                        .font(.caption2)
                                        .foregroundColor(Theme.mutedText)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Theme.surface)
                                        .clipShape(Capsule())
                                }
                            }
                            if let d = cmd.description, !d.isEmpty {
                                Text(d)
                                    .font(.caption)
                                    .foregroundColor(Theme.mutedText)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Theme.border)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
        }
    }
}
