package com.mymu.app.core

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

// 1:1 port of iOS Core/Models.swift. Parsing is hand-rolled over org.json to
// keep the same TOLERANT semantics: one message whose field arrives in an
// unexpected shape must never throw and blank the entire transcript.

fun JSONObject.stringOrNull(key: String): String? {
    if (!has(key) || isNull(key)) return null
    return opt(key) as? String
}

fun JSONObject.intOrNull(key: String): Int? {
    if (!has(key) || isNull(key)) return null
    return when (val v = opt(key)) {
        is Int -> v
        is Long -> v.toInt()
        is Number -> v.toInt()
        else -> null
    }
}

fun JSONObject.boolOrNull(key: String): Boolean? {
    if (!has(key) || isNull(key)) return null
    return opt(key) as? Boolean
}

fun JSONObject.anyOrNull(key: String): Any? {
    if (!has(key) || isNull(key)) return null
    return opt(key)
}

// MARK: - Auth

data class User(val id: Int, val username: String) {
    fun toJson(): JSONObject = JSONObject().put("id", id).put("username", username)

    companion object {
        fun fromJson(o: JSONObject) = User(o.optInt("id", 0), o.optString("username", ""))
    }
}

data class LoginResponse(val token: String, val user: User)

// MARK: - Projects & sessions (mirror of the web app's /api/projects shape)

data class Session(
    val id: String,
    /** Real for LOCAL sessions; remote agent rows hardcode "claude" server-side —
     * Harness prefers the session-id prefix for those. */
    val provider: String?,
    val title: String?,
    val summary: String?,
    val name: String?,
    val lastActivity: String?,
    val updatedAt: String?,     // updated_at
    val createdAtSnake: String?, // created_at
    val createdAt: String?,     // createdAt
    val messageCount: Int?,
) {
    val displayTitle: String
        get() = listOf(title, summary, name).firstOrNull { !it.isNullOrEmpty() } ?: id

    /** Recency key, matching the web app's sessionTime() precedence. */
    val sortKey: String
        get() = updatedAt ?: lastActivity ?: createdAt ?: createdAtSnake ?: ""

    companion object {
        fun fromJson(o: JSONObject) = Session(
            id = o.optString("id", ""),
            provider = o.stringOrNull("provider"),
            title = o.stringOrNull("title"),
            summary = o.stringOrNull("summary"),
            name = o.stringOrNull("name"),
            lastActivity = o.stringOrNull("lastActivity"),
            updatedAt = o.stringOrNull("updated_at"),
            createdAtSnake = o.stringOrNull("created_at"),
            createdAt = o.stringOrNull("createdAt"),
            messageCount = o.intOrNull("messageCount"),
        )
    }
}

data class Project(
    val projectId: String,
    val displayName: String,
    val fullPath: String?,
    val path: String?,
    val isStarred: Boolean?,
    val sessions: List<Session>?,
    // Set only for virtual `remote:<id>` projects — a live remote-control agent.
    val isRemoteAgent: Boolean?,
    val remoteSessionId: String?,
    val remoteConnected: Boolean?,
    val remoteRunning: Boolean?,
) {
    val id: String get() = projectId

    /** The one session this project's chat drives. */
    val primarySessionId: String?
        get() = if (isRemoteAgent == true) remoteSessionId else sessions?.firstOrNull()?.id

    companion object {
        fun fromJson(o: JSONObject): Project {
            val sessions = (o.opt("sessions") as? JSONArray)?.let { arr ->
                (0 until arr.length()).mapNotNull { (arr.opt(it) as? JSONObject)?.let(Session::fromJson) }
            }
            return Project(
                projectId = o.stringOrNull("projectId") ?: o.optString("id", ""),
                displayName = o.stringOrNull("displayName") ?: o.optString("projectId", ""),
                fullPath = o.stringOrNull("fullPath"),
                path = o.stringOrNull("path"),
                isStarred = o.boolOrNull("isStarred"),
                sessions = sessions,
                isRemoteAgent = o.boolOrNull("isRemoteAgent"),
                remoteSessionId = o.stringOrNull("remoteSessionId"),
                remoteConnected = o.boolOrNull("remoteConnected"),
                remoteRunning = o.boolOrNull("remoteRunning"),
            )
        }

        /** `/api/projects` may return a bare array or `{ projects: [...] }` — decode either. */
        fun listFrom(body: String): List<Project> {
            val trimmed = body.trim()
            val arr: JSONArray = when {
                trimmed.startsWith("[") -> try { JSONArray(trimmed) } catch (_: Exception) { JSONArray() }
                trimmed.startsWith("{") -> try { JSONObject(trimmed).optJSONArray("projects") ?: JSONArray() } catch (_: Exception) { JSONArray() }
                else -> JSONArray()
            }
            return (0 until arr.length()).mapNotNull { (arr.opt(it) as? JSONObject)?.let(::fromJson) }
        }
    }
}

// MARK: - Chat messages (mirror of NormalizedMessage; lenient decode)

data class ChatMessage(
    val id: String,
    val kind: String,
    val role: String? = null,
    val content: String? = null,
    val text: String? = null,
    val displayText: String? = null,
    val toolName: String? = null,
    val toolId: String? = null,
    val status: String? = null,
    val summary: String? = null,
    val requestId: String? = null,
    val isError: Boolean? = null,
    val timestamp: String? = null,
    /** Harness-injected content shipped as a user-role row — the person did NOT
     * type it; rendered as a collapsed context chip, never as a user bubble. */
    val isInjected: Boolean? = null,
    /** Local-only: sent mid-turn, waiting in the agent's queue. */
    val queued: Boolean? = null,
    /** Local-only: the id this row was BORN with ("local-N" for an optimistic
     * bubble, "stream-N" for a streaming reply) — kept when the server echo or
     * the final `text` frame rebinds `id`. The transcript uses it to know that
     * a re-keyed row is the SAME row, so the rebind swaps instantly instead of
     * replaying the insertion transition. Never serialized. */
    val clientId: String? = null,
    val toolInput: Any? = null,
    val input: Any? = null,
    val toolResult: Any? = null,
    /** Images attached to this message, as `data:` URLs. */
    val images: List<String>? = null,
) {
    /** The human-visible body for a simple text bubble. */
    val bodyText: String get() = displayText ?: content ?: text ?: ""

    /** Round-trip for the warm-start chat cache. `queued` is deliberately NOT
     * serialized — local mid-turn state must not resurrect ghost chips when a
     * cached transcript reopens (fromJson leaves it null). */
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("kind", kind)
        role?.let { put("role", it) }
        content?.let { put("content", it) }
        text?.let { put("text", it) }
        displayText?.let { put("displayText", it) }
        toolName?.let { put("toolName", it) }
        toolId?.let { put("toolId", it) }
        status?.let { put("status", it) }
        summary?.let { put("summary", it) }
        requestId?.let { put("requestId", it) }
        isError?.let { put("isError", it) }
        timestamp?.let { put("timestamp", it) }
        isInjected?.let { put("isInjected", it) }
        toolInput?.let { put("toolInput", it) }
        input?.let { put("input", it) }
        toolResult?.let { put("toolResult", it) }
        images?.let { put("images", JSONArray(it)) }
    }

    companion object {
        fun fromJson(o: JSONObject) = ChatMessage(
            id = o.stringOrNull("id") ?: UUID.randomUUID().toString(),
            kind = o.stringOrNull("kind") ?: "text",
            role = o.stringOrNull("role"),
            content = looseText(o.anyOrNull("content")),
            text = looseText(o.anyOrNull("text")),
            displayText = looseText(o.anyOrNull("displayText")),
            toolName = o.stringOrNull("toolName"),
            toolId = o.stringOrNull("toolId"),
            status = o.stringOrNull("status"),
            summary = looseText(o.anyOrNull("summary")),
            requestId = o.stringOrNull("requestId"),
            isError = o.boolOrNull("isError"),
            timestamp = o.stringOrNull("timestamp"),
            isInjected = o.boolOrNull("isInjected"),
            toolInput = o.anyOrNull("toolInput"),
            input = o.anyOrNull("input"),
            toolResult = o.anyOrNull("toolResult"),
            images = (o.opt("images") as? JSONArray)?.let { arr ->
                (0 until arr.length()).mapNotNull { arr.opt(it) as? String }
            },
        )

        /** A string field that may instead arrive as blocks
         * (`[{type:"text",text:…}]`) or an object — flatten to text. */
        fun looseText(v: Any?): String? = when (v) {
            null -> null
            is String -> v
            is JSONArray -> {
                val parts = (0 until v.length()).mapNotNull { looseText(v.opt(it)) }
                if (parts.isEmpty()) null else parts.joinToString("\n")
            }
            is JSONObject -> v.stringOrNull("text") ?: looseText(v.anyOrNull("content"))
            else -> null
        }
    }
}

/** Pretty-printed JSON for a fallback tool-payload display (AnyCodable.prettyJSON). */
fun prettyJson(v: Any?): String = when (v) {
    null -> ""
    is String -> v
    is JSONObject -> try { v.toString(2) } catch (_: Exception) { v.toString() }
    is JSONArray -> try { v.toString(2) } catch (_: Exception) { v.toString() }
    else -> v.toString()
}

// MARK: - File tree

data class FileNode(
    val name: String,
    val path: String,
    val type: String, // "directory" | "file"
    val size: Long?,
    val children: List<FileNode>?,
    /** Directory exists but wasn't walked — fetch its contents on demand. */
    val truncated: Boolean?,
) {
    val id: String get() = path
    val isDir: Boolean get() = type == "directory"
    val needsFetch: Boolean get() = isDir && (truncated == true || children == null)
    val sortedChildren: List<FileNode>
        get() = (children ?: emptyList()).sortedWith(
            compareByDescending<FileNode> { it.isDir }.thenBy { it.name.lowercase() }
        )

    companion object {
        fun fromJson(o: JSONObject): FileNode = FileNode(
            name = o.optString("name", ""),
            path = o.optString("path", ""),
            type = o.optString("type", "file"),
            size = if (o.has("size") && !o.isNull("size")) o.optLong("size") else null,
            children = (o.opt("children") as? JSONArray)?.let { arr ->
                (0 until arr.length()).mapNotNull { (arr.opt(it) as? JSONObject)?.let(::fromJson) }
            },
            truncated = o.boolOrNull("truncated"),
        )

        fun listFrom(body: String): List<FileNode> {
            val arr = try { JSONArray(body.trim()) } catch (_: Exception) { JSONArray() }
            return (0 until arr.length()).mapNotNull { (arr.opt(it) as? JSONObject)?.let(::fromJson) }
        }
    }
}

data class ContextUsage(val usedTokens: Int, val windowTokens: Int) {
    /** 0…1 fullness of the agent's context window. */
    val fraction: Double
        get() = if (windowTokens > 0) minOf(1.0, usedTokens.toDouble() / windowTokens) else 0.0

    companion object {
        fun fromJson(o: JSONObject?): ContextUsage? {
            o ?: return null
            val used = o.intOrNull("usedTokens") ?: return null
            return ContextUsage(used, o.intOrNull("windowTokens") ?: 0)
        }
    }
}

data class HistoryResponse(
    val messages: List<ChatMessage>,
    val total: Int?,
    val hasMore: Boolean?,
    val offset: Int?,
    val limit: Int?,
    val context: ContextUsage?,
    /** ISO timestamp of the user prompt that opened a still-running turn. */
    val turnStartedAt: String?,
    /** Context position (tokens) just before the open turn started. */
    val turnStartContextTokens: Int?,
) {
    companion object {
        /** Tolerant: a wrong-typed meta field must not sink the whole transcript. */
        fun fromJson(body: String): HistoryResponse {
            val o = try { JSONObject(body.trim()) } catch (_: Exception) { JSONObject() }
            val msgs = (o.opt("messages") as? JSONArray)?.let { arr ->
                (0 until arr.length()).mapNotNull { (arr.opt(it) as? JSONObject)?.let(ChatMessage::fromJson) }
            } ?: emptyList()
            return HistoryResponse(
                messages = msgs,
                total = o.intOrNull("total"),
                hasMore = o.boolOrNull("hasMore"),
                offset = o.intOrNull("offset"),
                limit = o.intOrNull("limit"),
                context = ContextUsage.fromJson(o.opt("context") as? JSONObject),
                turnStartedAt = o.stringOrNull("turnStartedAt"),
                turnStartContextTokens = o.intOrNull("turnStartContextTokens"),
            )
        }
    }
}
