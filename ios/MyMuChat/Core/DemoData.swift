import Foundation

/// Sample transcript used by the DEBUG demo screen (MYMU_DEMO=1) so the chat UI
/// can be screenshotted/iterated without a live login.
enum DemoData {
    private static func agent(_ name: String, id: String, connected: Bool, running: Bool) -> Project {
        Project(projectId: "remote:\(id)", displayName: name, fullPath: nil, path: nil, isStarred: nil, sessions: nil,
                isRemoteAgent: true, remoteSessionId: id, remoteConnected: connected, remoteRunning: running)
    }

    private static func session(_ id: String, title: String, msgs: Int, ageMin: Int,
                                provider: String = "claude") -> Session {
        Session(id: id, provider: provider, title: title, summary: nil, name: nil, lastActivity: nil,
                updated_at: nil, created_at: nil, createdAt: nil, messageCount: msgs)
    }

    private static func folder(_ name: String, path: String, sessions: [Session]) -> Project {
        Project(projectId: name, displayName: name, fullPath: path, path: path, isStarred: nil, sessions: sessions,
                isRemoteAgent: false, remoteSessionId: nil, remoteConnected: nil, remoteRunning: nil)
    }

    // A MIXED fleet on purpose: the id prefixes route to different harnesses
    // (cse_ Claude Code, cxs_ Codex, ocs_ OpenCode), so the demo — and every
    // screenshot taken from it — shows the multi-brain story, not one vendor.
    static let projects: [Project] = [
        agent("special-agent", id: "cse_a1", connected: true, running: true),
        agent("casabot-monitor", id: "cxs_b2", connected: true, running: false),
        agent("quotomate-dev", id: "ocs_c3", connected: false, running: false),
        folder("claudecodeui", path: "/home/manar/Projects/claudecodeui", sessions: [
            session("s1", title: "Native iOS app — MyMu chat", msgs: 214, ageMin: 3),
            session("s2", title: "Fix delivered-file video streaming", msgs: 48, ageMin: 90, provider: "codex"),
        ]),
        folder("mnemos", path: "/home/manar/Projects/mnemos", sessions: [
            session("s3", title: "pgvector ingest pipeline", msgs: 132, ageMin: 1440, provider: "opencode"),
        ]),
    ]

    /// Model catalogue for the offline demo chat — the shapes a real multi-
    /// harness server returns, so the brain switcher renders without a login.
    static let modelOptions: [APIClient.ModelOption] = [
        .init(value: "claude-opus-4-8", label: "Claude Opus 4.8", description: "Anthropic Claude, deep reasoning"),
        .init(value: "claude-sonnet-5-20260203", label: "Claude Sonnet 5", description: "Anthropic Claude, fast"),
        .init(value: "gpt-5.3-codex", label: "GPT-5.3 Codex", description: "OpenAI Codex agent"),
        .init(value: "deepseek-v4-pro", label: "DeepSeek V4 Pro", description: "DeepSeek V4 reasoning"),
    ]
    static let defaultModel = "claude-opus-4-8"

    static let messages: [ChatMessage] = [
        ChatMessage(id: "d1", kind: "text", role: "user",
                    content: "Can you refactor the auth module and show me a quick example?"),
        ChatMessage(id: "d2", kind: "text", role: "assistant",
                    content: """
                    Sure — here's the plan:

                    1. Extract **`validateToken`** into its own helper
                    2. Add refresh handling with a fallback

                    ```swift
                    func validateToken(_ token: String) -> Bool {
                        guard !token.isEmpty else { return false }
                        return token.hasPrefix("ey")
                    }
                    ```

                    That keeps the call sites clean. Want me to apply it?
                    """),
        ChatMessage(id: "d3", kind: "tool_use", role: "assistant", toolName: "Edit"),
        ChatMessage(id: "d4", kind: "tool_result", role: "assistant",
                    content: "Applied 2 edits to auth.swift (+18 −6)"),
        ChatMessage(id: "d5", kind: "text", role: "assistant",
                    content: "Done ✅ — the auth module now validates and refreshes tokens. Anything else?"),
    ]

    /// Per-agent conversation tails for the swipe switcher's preview cards,
    /// keyed by demo session id. Plain text on purpose — the cards render
    /// bodies as raw Text, so markdown fences would show as syntax. Each
    /// reads like that agent's actual job, so zapping through the demo fleet
    /// tells three different stories, not one repeated one.
    static let agentTranscripts: [String: [ChatMessage]] = [
        "cse_a1": [
            ChatMessage(id: "sa0a", kind: "text", role: "assistant",
                        content: "Onboarding redesign is code-complete. Running the full test suite now."),
            ChatMessage(id: "sa0b", kind: "text", role: "user",
                        content: "How long?"),
            ChatMessage(id: "sa0c", kind: "text", role: "assistant",
                        content: "About four minutes — 42 UI tests on the slow simulator are the bulk of it."),
            ChatMessage(id: "sa1", kind: "text", role: "user",
                        content: "Ship the onboarding redesign to staging when the tests pass."),
            ChatMessage(id: "sa2", kind: "text", role: "assistant",
                        content: "All 42 tests green. Deploying to staging now — I'll post the preview link here."),
            ChatMessage(id: "sa3", kind: "text", role: "user",
                        content: "Nice. Anything risky in the diff?"),
            ChatMessage(id: "sa4", kind: "text", role: "assistant",
                        content: "One thing worth eyes: the welcome flow now skips the tour for returning users. Everything else is styling."),
        ],
        "cxs_b2": [
            ChatMessage(id: "cm00a", kind: "text", role: "user",
                        content: "Roll the scraper config out to the workers."),
            ChatMessage(id: "cm00b", kind: "text", role: "assistant",
                        content: "Rolling out now — one worker at a time so the queue never stalls."),
            ChatMessage(id: "cm0a", kind: "text", role: "assistant",
                        content: "Deployed the new scraper config to all three workers. First runs look clean."),
            ChatMessage(id: "cm0b", kind: "text", role: "user",
                        content: "Good. Ping me tomorrow with numbers."),
            ChatMessage(id: "cm1", kind: "text", role: "user",
                        content: "Morning report?"),
            ChatMessage(id: "cm2", kind: "text", role: "assistant",
                        content: "Overnight: 3,214 listings scraped, 0 failures. Two new price drops match your alert rules — sent both to the channel."),
            ChatMessage(id: "cm3", kind: "text", role: "user",
                        content: "Keep an eye on the login flow, it broke last week."),
            ChatMessage(id: "cm4", kind: "text", role: "assistant",
                        content: "Watching it. The session refresh has been stable for 6 days straight — I'll page you if it regresses."),
        ],
        "ocs_c3": [
            ChatMessage(id: "qd0a", kind: "text", role: "assistant",
                        content: "Nightly index rebuild finished: 1.2M parts, 9 suppliers, no gaps."),
            ChatMessage(id: "qd0b", kind: "text", role: "user",
                        content: "Great, thanks."),
            ChatMessage(id: "qd1", kind: "text", role: "user",
                        content: "Customers say part search feels slow since yesterday."),
            ChatMessage(id: "qd2", kind: "text", role: "assistant",
                        content: "Confirmed — p95 went from 180ms to 1.4s after the index rebuild. The new query skips the cache."),
            ChatMessage(id: "qd3", kind: "text", role: "assistant",
                        content: "Fix is ready: restored the cache path and added a regression test. Want me to deploy?"),
            ChatMessage(id: "qd4", kind: "text", role: "user",
                        content: "Deploy it and watch the latency for an hour."),
        ],
    ]

    /// A LONG, mixed transcript (tall enough to scroll) for reproducing the
    /// scroll-to-bottom overshoot / phantom-gap bug in the simulator.
    static var longMessages: [ChatMessage] {
        var out: [ChatMessage] = []
        for i in 0..<24 {
            out.append(ChatMessage(id: "u\(i)", kind: "text", role: "user",
                                   content: "Question number \(i): can you look into part \(i) of the module and explain what it does in a couple of sentences?"))
            out.append(ChatMessage(id: "tu\(i)", kind: "tool_use", role: "assistant", toolName: "Read"))
            out.append(ChatMessage(id: "tr\(i)", kind: "tool_result", role: "assistant",
                                   content: "Read module/part_\(i).swift (\(40 + i) lines)"))
            out.append(ChatMessage(id: "a\(i)", kind: "text", role: "assistant",
                                   content: """
                                   Part \(i) handles the \(i.isMultiple(of: 2) ? "encoding" : "validation") path. It takes the raw input, \
                                   normalizes it, and returns a typed result. The tricky bit is the fallback branch that runs when \
                                   the primary source is unavailable — it retries with a shorter timeout and then degrades gracefully.
                                   """))
        }
        return out
    }
}
