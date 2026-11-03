package com.mymu.app.core

import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.util.concurrent.TimeUnit

/**
 * An authenticated request came back 401: the active session's token is no
 * longer accepted by its server. (iOS: Notification .mymuUnauthorized.)
 */
object UnauthorizedBus {
    val events = MutableSharedFlow<String>(extraBufferCapacity = 8)
    fun post(origin: String) { events.tryEmit(origin) }
}

/** (status, body-derived message, host) — mirrors iOS APIError.http. */
class ApiException(val code: Int, message: String, val host: String?) : Exception(message)

private fun hostOf(origin: String): String? = try { URI(origin).host } catch (_: Exception) { null }

private fun httpErrorMessage(code: Int, host: String?): String {
    val onHost = host?.let { " on $it" } ?: ""
    // 401 is only ever a credentials problem on the LOGIN call; anywhere else
    // it means the saved session expired. Say which.
    return if (code == 401)
        "Rejected$onHost — check the server, username and password, or sign in again if the session expired."
    else
        "Server error (HTTP $code)$onHost."
}

/**
 * Thin REST client over the same endpoints the web app uses.
 * 1:1 port of iOS Core/APIClient.swift.
 */
class ApiClient(private val token: String?, private val origin: String? = null) {

    companion object {
        private val JSON = "application/json; charset=utf-8".toMediaType()

        val http: OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .callTimeout(30, TimeUnit.SECONDS)
            .build()

        /**
         * Stock (upstream) claudecodeui servers wrap REST payloads in a
         * `{success: true, data: …}` envelope; the fork returns most payloads
         * bare. Unwrap the envelope when it is the entire response.
         */
        fun unwrapEnvelope(body: String): String {
            val trimmed = body.trim()
            if (!trimmed.startsWith("{")) return body
            return try {
                val o = JSONObject(trimmed)
                if (o.length() == 2 && o.optBoolean("success", false) && o.has("data"))
                    o.get("data").toString()
                else body
            } catch (_: Exception) { body }
        }

        suspend fun login(username: String, password: String): LoginResponse {
            val body = JSONObject().put("username", username).put("password", password).toString()
            val data = ApiClient(null).request("/api/auth/login", "POST", body, auth = false)
            val o = JSONObject(data)
            return LoginResponse(o.getString("token"), User.fromJson(o.getJSONObject("user")))
        }
    }

    private suspend fun request(
        path: String,
        method: String = "GET",
        body: String? = null,
        auth: Boolean = true,
        timeoutSeconds: Long? = null,
    ): String = withContext(Dispatchers.IO) {
        val base = origin ?: Config.serverOrigin
        val builder = Request.Builder().url(base + path)
        when (method) {
            "GET" -> builder.get()
            // A DELETE carries a body only where the route's contract says so
            // (file-tree DELETE files takes its path in the body).
            "DELETE" -> if (body != null) builder.delete(body.toRequestBody(JSON)) else builder.delete()
            else -> builder.method(method, (body ?: "{}").toRequestBody(JSON))
        }
        if (auth && token != null) builder.header("Authorization", "Bearer $token")
        val client = if (timeoutSeconds != null)
            http.newBuilder().callTimeout(timeoutSeconds, TimeUnit.SECONDS).build()
        else http
        client.newCall(builder.build()).execute().use { resp ->
            val text = resp.body?.string() ?: ""
            if (resp.code !in 200..299) {
                // A 401 on a call we SENT A TOKEN WITH means that token is dead —
                // announce it so AppState can drop the session and show sign-in.
                if (resp.code == 401 && auth && token != null) UnauthorizedBus.post(base)
                throw ApiException(resp.code, httpErrorMessage(resp.code, hostOf(base)), hostOf(base))
            }
            unwrapEnvelope(text)
        }
    }

    // MARK: Endpoints

    data class AgentStatusEntry(val id: String, val running: Boolean?, val connected: Boolean?)

    /** Lightweight live status for remote agents — safe to poll every few seconds. */
    suspend fun agentStatus(): List<AgentStatusEntry> {
        val data = request("/api/projects/agent-status")
        val arr = try { JSONObject(data).optJSONArray("agents") ?: JSONArray() } catch (_: Exception) { JSONArray() }
        return (0 until arr.length()).mapNotNull { i ->
            (arr.opt(i) as? JSONObject)?.let {
                AgentStatusEntry(it.optString("id", ""), it.boolOrNull("running"), it.boolOrNull("connected"))
            }
        }
    }

    suspend fun projects(): List<Project> = Project.listFrom(request("/api/projects"))

    suspend fun archivedProjects(): List<Project> = Project.listFrom(request("/api/projects/archived"))

    /** Lazy tree loading: `depth` bounds the server-side walk, `path` re-roots it. */
    suspend fun files(projectId: String, path: String? = null, depth: Int = 2): List<FileNode> {
        val pid = Uri.encode(projectId)
        var endpoint = "/api/file-tree/projects/$pid/files?depth=$depth"
        if (!path.isNullOrEmpty()) endpoint += "&path=${Uri.encode(path)}"
        return FileNode.listFrom(request(endpoint))
    }

    suspend fun fileText(projectId: String, filePath: String): String {
        val pid = Uri.encode(projectId)
        val data = request("/api/file-tree/projects/$pid/file?filePath=${Uri.encode(filePath)}")
        return try { JSONObject(data).optString("content", "") } catch (_: Exception) { "" }
    }

    /** RAW bytes of a project file, for the preview's download/share button.
     * Binary/media can't ride fileText's JSON envelope; files/content streams
     * the file as-is (iOS APIClient.fileData). Long timeout: multi-MB renders
     * over a slow uplink must not abort mid-download. */
    suspend fun fileData(projectId: String, path: String): ByteArray = withContext(Dispatchers.IO) {
        val base = origin ?: Config.serverOrigin
        val pid = Uri.encode(projectId)
        val builder = Request.Builder()
            .url("$base/api/file-tree/projects/$pid/files/content?path=${Uri.encode(path)}")
            .get()
        if (token != null) builder.header("Authorization", "Bearer $token")
        val client = http.newBuilder().callTimeout(120, TimeUnit.SECONDS).build()
        client.newCall(builder.build()).execute().use { resp ->
            if (resp.code !in 200..299) {
                if (resp.code == 401 && token != null) UnauthorizedBus.post(base)
                throw ApiException(resp.code, httpErrorMessage(resp.code, hostOf(base)), hostOf(base))
            }
            resp.body?.bytes() ?: ByteArray(0)
        }
    }

    // MARK: File-tree management (same routes the web file browser drives;
    // request shapes 1:1 with iOS APIClient, ff6adcf)

    /** Creates an empty file or directory under `parentPath` ("" = tree root). */
    suspend fun createFileEntry(projectId: String, parentPath: String, name: String, isDirectory: Boolean) {
        val body = JSONObject()
            .put("name", name)
            .put("type", if (isDirectory) "directory" else "file")
            .put("path", parentPath)
            .toString()
        request("/api/file-tree/projects/${Uri.encode(projectId)}/files/create", "POST", body)
    }

    suspend fun renameFileEntry(projectId: String, oldPath: String, newName: String) {
        val body = JSONObject().put("oldPath", oldPath).put("newName", newName).toString()
        request("/api/file-tree/projects/${Uri.encode(projectId)}/files/rename", "PUT", body)
    }

    /** Deletes a file or directory. The path rides in the DELETE body — that is
     * this route's contract server-side, not a query parameter. */
    suspend fun deleteFileEntry(projectId: String, path: String) {
        val body = JSONObject().put("path", path).toString()
        request("/api/file-tree/projects/${Uri.encode(projectId)}/files", "DELETE", body)
    }

    /**
     * Uploads files INTO the project tree at `targetPath` ("" = root) — the web
     * file browser's upload route (multipart field `files`), distinct from the
     * chat-attachment asset store ([uploadAssets]).
     */
    suspend fun uploadProjectFiles(projectId: String, targetPath: String, files: List<Attachment>) {
        if (files.isEmpty()) return
        withContext(Dispatchers.IO) {
            val base = origin ?: Config.serverOrigin
            val bodyBuilder = MultipartBody.Builder().setType(MultipartBody.FORM)
                .addFormDataPart("targetPath", targetPath)
                .addFormDataPart("requestedFileCount", files.size.toString())
            for (f in files) {
                val safeName = f.name.replace("\"", "_")
                bodyBuilder.addFormDataPart("files", safeName, f.bytes.toRequestBody(f.mime.toMediaType()))
            }
            val builder = Request.Builder()
                .url("$base/api/file-tree/projects/${Uri.encode(projectId)}/files/upload")
                .post(bodyBuilder.build())
            if (token != null) builder.header("Authorization", "Bearer $token")
            val client = http.newBuilder().callTimeout(300, TimeUnit.SECONDS).build()
            client.newCall(builder.build()).execute().use { resp ->
                if (resp.code !in 200..299) {
                    if (resp.code == 401 && token != null) UnauthorizedBus.post(base)
                    throw ApiException(resp.code, httpErrorMessage(resp.code, hostOf(base)), hostOf(base))
                }
            }
        }
    }

    /** `timeoutSeconds` override exists for token-count probes. */
    suspend fun history(sessionId: String, limit: Int = 200, offset: Int = 0,
                        timeoutSeconds: Long? = null): HistoryResponse {
        val sid = Uri.encode(sessionId)
        val data = request("/api/providers/sessions/$sid/messages?limit=$limit&offset=$offset",
            timeoutSeconds = timeoutSeconds)
        return HistoryResponse.fromJson(data)
    }

    /**
     * The server-authoritative chat-attachment cap in bytes (`GET /api/limits`).
     * Returns 0 if the server predates the endpoint (stock servers SPA-fallback
     * to HTML here — hence the fully tolerant parse).
     */
    suspend fun attachmentLimitBytes(): Int = try {
        val data = request("/api/limits", auth = false)
        JSONObject(data.trim()).intOrNull("attachmentBytes") ?: 0
    } catch (_: Exception) { 0 }

    // MARK: slash commands

    /** A command from the `.claude` commands dir (`*.md`) — project- or user-level. */
    data class SlashCommand(val name: String, val description: String?, val namespace: String?, val path: String?) {
        val id: String get() = path ?: name
        val invocation: String get() = if (name.startsWith("/")) name else "/$name"
    }

    /** `POST /api/commands/list`. Omitting projectPath still returns user-level commands. */
    suspend fun slashCommands(projectPath: String?): List<SlashCommand> {
        val body = JSONObject().apply { if (projectPath != null) put("projectPath", projectPath) }.toString()
        val data = request("/api/commands/list", "POST", body)
        val o = try { JSONObject(data) } catch (_: Exception) { JSONObject() }
        fun parse(key: String): List<SlashCommand> {
            val arr = o.optJSONArray(key) ?: return emptyList()
            return (0 until arr.length()).mapNotNull { i ->
                (arr.opt(i) as? JSONObject)?.let {
                    SlashCommand(it.optString("name", ""), it.stringOrNull("description"),
                        it.stringOrNull("namespace"), it.stringOrNull("path"))
                }
            }
        }
        return parse("custom") + parse("builtIn")
    }

    // MARK: models

    data class ModelOption(val value: String, val label: String, val description: String?)

    /** The provider's model catalogue (`GET /api/providers/:provider/models`). */
    suspend fun models(provider: String = "claude"): Pair<List<ModelOption>, String> {
        val data = request("/api/providers/$provider/models")
        val models = JSONObject(data).getJSONObject("models")
        val arr = models.optJSONArray("OPTIONS") ?: JSONArray()
        val options = (0 until arr.length()).mapNotNull { i ->
            (arr.opt(i) as? JSONObject)?.let {
                ModelOption(it.optString("value", ""), it.optString("label", ""), it.stringOrNull("description"))
            }
        }
        return options to models.optString("DEFAULT", "")
    }

    /** Which model a session resolves to right now. */
    suspend fun activeModel(provider: String = "claude", sessionId: String): String? = try {
        val sid = Uri.encode(sessionId)
        val data = request("/api/providers/$provider/sessions/$sid/active-model")
        JSONObject(data).stringOrNull("model")
    } catch (_: Exception) { null }

    // MARK: MCP servers

    /** A configured MCP server, as normalised by the server's provider adapters. */
    data class McpServer(
        val name: String, val scope: String?, val transport: String?,
        val command: String?, val args: List<String>?, val url: String?,
    ) {
        val id: String get() = "${scope ?: ""}|$name"

        /** One line describing where it points. */
        val target: String
            get() {
                if (!url.isNullOrEmpty()) return url
                val joined = (listOf(command) + (args ?: emptyList())).filterNotNull().joinToString(" ")
                return joined.ifEmpty { "—" }
            }
    }

    suspend fun mcpServers(provider: String = "claude"): List<McpServer> {
        val data = request("/api/providers/$provider/mcp/servers")
        val scopes = try { JSONObject(data).optJSONObject("scopes") ?: JSONObject() } catch (_: Exception) { JSONObject() }
        val out = mutableListOf<McpServer>()
        for (scope in scopes.keys()) {
            val arr = scopes.optJSONArray(scope) ?: continue
            for (i in 0 until arr.length()) {
                val s = arr.opt(i) as? JSONObject ?: continue
                out += McpServer(
                    name = s.optString("name", ""),
                    scope = s.stringOrNull("scope") ?: scope,
                    transport = s.stringOrNull("transport"),
                    command = s.stringOrNull("command"),
                    args = (s.opt("args") as? JSONArray)?.let { a -> (0 until a.length()).mapNotNull { a.opt(it) as? String } },
                    url = s.stringOrNull("url"),
                )
            }
        }
        return out.sortedWith(compareBy({ it.scope ?: "" }, { it.name }))
    }

    suspend fun deleteMcpServer(provider: String = "claude", name: String, scope: String?) {
        var path = "/api/providers/$provider/mcp/servers/${Uri.encode(name)}"
        if (scope != null) path += "?scope=$scope"
        request(path, "DELETE")
    }

    data class AssetRecord(val name: String?, val path: String, val size: Long?, val mimeType: String?)

    data class Attachment(val name: String, val mime: String, val bytes: ByteArray)

    /**
     * Uploads chat attachments to the server's asset store (store first, then
     * reference by path in chat.send). `field` is "images" or "files".
     */
    suspend fun uploadAssets(attachments: List<Attachment>, field: String): List<AssetRecord> {
        if (attachments.isEmpty()) return emptyList()
        return withContext(Dispatchers.IO) {
            val base = origin ?: Config.serverOrigin
            val bodyBuilder = MultipartBody.Builder().setType(MultipartBody.FORM)
            for (a in attachments) {
                val safeName = a.name.replace("\"", "_")
                bodyBuilder.addFormDataPart(field, safeName, a.bytes.toRequestBody(a.mime.toMediaType()))
            }
            val builder = Request.Builder()
                .url("$base/api/assets/$field")
                .post(bodyBuilder.build())
            if (token != null) builder.header("Authorization", "Bearer $token")
            val client = http.newBuilder().callTimeout(300, TimeUnit.SECONDS).build()
            client.newCall(builder.build()).execute().use { resp ->
                val text = resp.body?.string() ?: ""
                if (resp.code !in 200..299)
                    throw ApiException(resp.code, httpErrorMessage(resp.code, hostOf(base)), hostOf(base))
                val o = try { JSONObject(unwrapEnvelope(text)) } catch (_: Exception) { JSONObject() }
                val arr = o.optJSONArray("images") ?: o.optJSONArray("attachments") ?: JSONArray()
                (0 until arr.length()).mapNotNull { i ->
                    (arr.opt(i) as? JSONObject)?.let {
                        AssetRecord(it.stringOrNull("name"), it.optString("path", ""),
                            if (it.has("size") && !it.isNull("size")) it.optLong("size") else null,
                            it.stringOrNull("mimeType"))
                    }
                }
            }
        }
    }

    /**
     * Stock upstream servers allocate chat sessions over REST before the first
     * `chat.send`. Returns the new app session id.
     */
    suspend fun createProviderSession(provider: String = "claude", projectPath: String): String {
        val body = JSONObject().put("provider", provider).put("projectPath", projectPath).toString()
        val data = request("/api/providers/sessions", "POST", body)
        return JSONObject(data).getString("sessionId")
    }

    /** Agent → host assignments (admin-set on the server): agentKey → host origin. */
    suspend fun agentHosts(): Map<String, String> = try {
        val data = request("/api/agent-hosts")
        val o = JSONObject(data).optJSONObject("assignments") ?: JSONObject()
        buildMap { for (k in o.keys()) o.stringOrNull(k)?.let { put(k, it) } }
    } catch (e: ApiException) { throw e }

    // MARK: Push notifications (same endpoint contract as iOS, 2026-09-13)

    /**
     * Register this device's push token so the server can push agent-reply
     * notifications. Idempotent upsert server-side. `platform: "android"`
     * tells the server this is an FCM registration token, not an APNs one —
     * today's server stores every registration in its APNs channel, so this
     * stays dormant until the server grows an FCM sender (tracked).
     */
    suspend fun pushRegister(deviceToken: String) {
        val body = JSONObject()
            .put("deviceToken", deviceToken)
            .put("platform", "android")
            .put("bundleId", "com.mymu.app")
            .put("appVersion", com.manarz.myagent.BuildConfig.VERSION_NAME)
            .toString()
        request("/api/push/register", "POST", body)
    }

    /** Forget this device's token (sign-out / account removal). Uses the
     * path-param variant (this DELETE route takes no body). */
    suspend fun pushUnregister(deviceToken: String) {
        request("/api/push/register/${Uri.encode(deviceToken)}", "DELETE")
    }
}
