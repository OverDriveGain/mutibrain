package com.mymu.app.core

/**
 * How much the agent may do without asking — the web client's composer
 * "permission menu", sent as `options.permissionMode` on `chat.send`.
 * (1:1 port of iOS Core/PermissionMode.swift; `auto` deliberately omitted for
 * the same reason it is on iOS.)
 */
enum class PermissionMode(val raw: String) {
    DEFAULT("default"),
    ACCEPT_EDITS("acceptEdits"),
    PLAN("plan"),
    BYPASS_PERMISSIONS("bypassPermissions");

    val label: String
        get() = when (this) {
            DEFAULT -> "Ask each time"
            ACCEPT_EDITS -> "Accept edits"
            PLAN -> "Plan only"
            BYPASS_PERMISSIONS -> "Bypass permissions"
        }

    /** Shown under the label in the picker — the consequence, not a restatement. */
    val detail: String
        get() = when (this) {
            DEFAULT -> "Prompt before tools that change anything"
            ACCEPT_EDITS -> "File edits go through without asking"
            PLAN -> "Plan a change; make none"
            BYPASS_PERMISSIONS -> "Never ask. Use with care"
        }

    companion object {
        fun fromRaw(raw: String?): PermissionMode? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * Per-session persistence, mirroring the web client's
 * `permissionMode-<sessionId>` / `permissionMode-last` pair.
 */
object PermissionModeStore {
    private const val LAST_KEY = "mymu.permissionMode.last"
    private fun key(sessionId: String) = "mymu.permissionMode.$sessionId"

    fun load(sessionId: String): PermissionMode =
        PermissionMode.fromRaw(Prefs.getString(key(sessionId)))
            ?: PermissionMode.fromRaw(Prefs.getString(LAST_KEY))
            ?: PermissionMode.DEFAULT

    fun save(mode: PermissionMode, sessionId: String) {
        Prefs.putString(key(sessionId), mode.raw)
        Prefs.putString(LAST_KEY, mode.raw)
    }
}
