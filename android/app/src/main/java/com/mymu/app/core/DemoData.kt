package com.mymu.app.core

/**
 * Sample fleet + transcript for the network-free demo ("Try the demo" on the
 * login screen) — the app is reviewable/explorable with no server.
 * (1:1 port of iOS Core/DemoData.swift; same multi-harness story on purpose.)
 */
object DemoData {
    private fun agent(name: String, id: String, connected: Boolean, running: Boolean) = Project(
        projectId = "remote:$id", displayName = name, fullPath = null, path = null,
        isStarred = null, sessions = null, isRemoteAgent = true, remoteSessionId = id,
        remoteConnected = connected, remoteRunning = running)

    private fun session(id: String, title: String, msgs: Int, provider: String = "claude") = Session(
        id = id, provider = provider, title = title, summary = null, name = null,
        lastActivity = null, updatedAt = null, createdAtSnake = null, createdAt = null,
        messageCount = msgs)

    private fun folder(name: String, path: String, sessions: List<Session>) = Project(
        projectId = name, displayName = name, fullPath = path, path = path, isStarred = null,
        sessions = sessions, isRemoteAgent = false, remoteSessionId = null,
        remoteConnected = null, remoteRunning = null)

    // A MIXED fleet on purpose: the id prefixes route to different harnesses
    // (cse_ Claude Code, cxs_ Codex, ocs_ OpenCode) — the multi-brain story.
    val projects: List<Project> = listOf(
        agent("special-agent", "cse_a1", connected = true, running = true),
        agent("casabot-monitor", "cxs_b2", connected = true, running = false),
        agent("quotomate-dev", "ocs_c3", connected = false, running = false),
        folder("claudecodeui", "/home/manar/Projects/claudecodeui", listOf(
            session("s1", "Native iOS app — MyMu chat", 214),
            session("s2", "Fix delivered-file video streaming", 48, provider = "codex"),
        )),
        folder("mnemos", "/home/manar/Projects/mnemos", listOf(
            session("s3", "pgvector ingest pipeline", 132, provider = "opencode"),
        )),
    )

    /** Model catalogue for the offline demo chat — the shapes a real multi-
     * harness server returns, so the brain switcher renders without a login. */
    val modelOptions: List<ApiClient.ModelOption> = listOf(
        ApiClient.ModelOption("claude-opus-4-8", "Claude Opus 4.8", "Anthropic Claude, deep reasoning"),
        ApiClient.ModelOption("claude-sonnet-5-20260203", "Claude Sonnet 5", "Anthropic Claude, fast"),
        ApiClient.ModelOption("gpt-5.3-codex", "GPT-5.3 Codex", "OpenAI Codex agent"),
        ApiClient.ModelOption("deepseek-v4-pro", "DeepSeek V4 Pro", "DeepSeek V4 reasoning"),
    )
    const val defaultModel = "claude-opus-4-8"

    val messages: List<ChatMessage> = listOf(
        ChatMessage(id = "d1", kind = "text", role = "user",
            content = "Can you refactor the auth module and show me a quick example?"),
        ChatMessage(id = "d2", kind = "text", role = "assistant",
            content = """
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
            """.trimIndent()),
        ChatMessage(id = "d3", kind = "tool_use", role = "assistant", toolName = "Edit"),
        ChatMessage(id = "d4", kind = "tool_result", role = "assistant",
            content = "Applied 2 edits to auth.swift (+18 −6)"),
        ChatMessage(id = "d5", kind = "text", role = "assistant",
            content = "Done ✅ — the auth module now validates and refreshes tokens. Anything else?"),
    )

    /** A LONG, mixed transcript (tall enough to scroll) — the stage for the
     * scroll-framework UI tests (jump button, stream follow, composer anchor);
     * reached through the `mymu.demo=chatlong` launch extra (UiTestHooks).
     * 1:1 port of iOS DemoData.longMessages. */
    val longMessages: List<ChatMessage>
        get() = buildList {
            for (i in 0 until 24) {
                add(ChatMessage(id = "u$i", kind = "text", role = "user",
                    content = "Question number $i: can you look into part $i of the module and explain what it does in a couple of sentences?"))
                add(ChatMessage(id = "tu$i", kind = "tool_use", role = "assistant", toolName = "Read"))
                add(ChatMessage(id = "tr$i", kind = "tool_result", role = "assistant",
                    content = "Read module/part_$i.swift (${40 + i} lines)"))
                add(ChatMessage(id = "a$i", kind = "text", role = "assistant",
                    content = "Part $i handles the ${if (i % 2 == 0) "encoding" else "validation"} path. It takes the raw input, " +
                        "normalizes it, and returns a typed result. The tricky bit is the fallback branch that runs when " +
                        "the primary source is unavailable — it retries with a shorter timeout and then degrades gracefully."))
            }
        }
}
