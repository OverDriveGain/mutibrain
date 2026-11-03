package com.mymu.app.core

/**
 * Which CLI harness drives a session. (1:1 port of iOS Core/Harness.swift.)
 *
 * Two truthful sources, tried in this order:
 * 1. The session-id routing prefix — the scheme the SERVER routes by
 *    (`ocs_`, `cxs_`, the Claude relay's `cse_`/`session_`). Covers live agents.
 * 2. The session row's `provider` field — real for LOCAL sessions only.
 */
enum class Harness(val raw: String) {
    CLAUDE("claude"), OPENCODE("opencode"), CODEX("codex"), CURSOR("cursor");

    val label: String
        get() = when (this) {
            CLAUDE -> "Claude Code"
            OPENCODE -> "OpenCode"
            CODEX -> "Codex"
            CURSOR -> "Cursor"
        }

    companion object {
        fun fromSessionId(sessionId: String): Harness? = when {
            sessionId.startsWith("ocs_") -> OPENCODE
            sessionId.startsWith("cxs_") -> CODEX
            sessionId.startsWith("cse_") || sessionId.startsWith("session_") -> CLAUDE
            else -> null
        }

        fun fromProvider(provider: String?): Harness? =
            provider?.let { p -> entries.firstOrNull { it.raw == p.lowercase() } }

        /** Prefix first (authoritative), provider field second (local sessions). */
        fun from(sessionId: String, provider: String?): Harness? =
            fromSessionId(sessionId) ?: fromProvider(provider)
    }
}
