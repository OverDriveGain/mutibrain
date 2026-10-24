import Foundation

extension Notification.Name {
    /// An authenticated request came back 401: the active session's token is no
    /// longer accepted by its server. Posted with `userInfo["origin"]`.
    static let mymuUnauthorized = Notification.Name("mymu.unauthorized")
}

enum APIError: LocalizedError {
    case badURL
    /// (status, body, host) — the host is carried so a 401 can name the server
    /// that actually rejected the request. Without it, signing in against the
    /// wrong origin (a stale "Server" field) is indistinguishable from a real
    /// bad password: both render as "invalid username or password".
    case http(Int, String, String?)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Bad URL."
        case .http(let code, let msg, let host):
            let onHost = host.map { " on \($0)" } ?? ""
            // 401 is only ever a credentials problem on the LOGIN call; anywhere
            // else it means the saved session expired. Say which.
            if code == 401 { return "Rejected\(onHost) — check the server, username and password, or sign in again if the session expired." }
            return "Server error (HTTP \(code))\(onHost). \(msg)"
        case .network(let m): return m
        }
    }
}

/// Thin REST client over the same endpoints the web app uses.
struct APIClient {
    var token: String?
    /// Per-conversation host override (agent→host pinning): requests go to this
    /// origin instead of the active account's server. nil = active host.
    var origin: String? = nil

    private func request(_ path: String, method: String = "GET", body: Data? = nil, auth: Bool = true,
                         timeout: TimeInterval? = nil) async throws -> Data {
        let base = origin ?? Config.serverOrigin
        guard let url = URL(string: base + path) else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout ?? 30
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if auth, let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError.network("No response from server.") }
        guard (200..<300).contains(http.statusCode) else {
            // A 401 on a call we SENT A TOKEN WITH means that token is dead —
            // not that a password was mistyped. Announce it so AppState can drop
            // the session and put a sign-in in front of the user. Without this
            // the app sat on an "expired" error behind a Retry button that could
            // only ever fail again, with no route back to a login screen.
            if http.statusCode == 401, auth, token != nil {
                NotificationCenter.default.post(
                    name: .mymuUnauthorized, object: nil,
                    userInfo: ["origin": base])
            }
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "",
                                URL(string: base)?.host)
        }
        return Self.unwrapEnvelope(data)
    }

    /// Stock (upstream) claudecodeui servers wrap REST payloads in a
    /// `{success: true, data: …}` envelope; this app's original server returns
    /// most payloads bare. Unwrap the envelope when it is the entire response
    /// so both server dialects decode identically downstream. Responses that
    /// merely contain a `success` flag among other fields (e.g. login) pass
    /// through untouched.
    private static func unwrapEnvelope(_ data: Data) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj.count == 2,
              obj["success"] as? Bool == true,
              let inner = obj["data"],
              let unwrapped = try? JSONSerialization.data(withJSONObject: inner, options: [.fragmentsAllowed])
        else { return data }
        return unwrapped
    }

    // MARK: Endpoints

    static func login(username: String, password: String) async throws -> LoginResponse {
        let body = try JSONEncoder().encode(["username": username, "password": password])
        let data = try await APIClient(token: nil).request("/api/auth/login", method: "POST", body: body, auth: false)
        return try JSONDecoder().decode(LoginResponse.self, from: data)
    }

    struct AgentStatusEntry: Codable { let id: String; let running: Bool?; let connected: Bool? }
    private struct AgentStatusResponse: Codable { let agents: [AgentStatusEntry] }

    /// Lightweight live status for remote agents ({id, running, connected}) —
    /// served from a short server cache, safe to poll every few seconds.
    func agentStatus() async throws -> [AgentStatusEntry] {
        let data = try await request("/api/projects/agent-status")
        return try JSONDecoder().decode(AgentStatusResponse.self, from: data).agents
    }

    func projects() async throws -> [Project] {
        let data = try await request("/api/projects")
        return try JSONDecoder().decode(ProjectsEnvelope.self, from: data).projects
    }

    func archivedProjects() async throws -> [Project] {
        let data = try await request("/api/projects/archived")
        return try JSONDecoder().decode(ProjectsEnvelope.self, from: data).projects
    }

    /// Lazy tree loading: `depth` bounds the server-side walk (cut-off dirs come
    /// back `truncated`), `path` re-roots it at a subdirectory for on-demand
    /// expansion — the whole-tree eager walk was multi-MB and crawled on
    /// network-mounted folders.
    func files(projectId: String, path: String? = nil, depth: Int = 2) async throws -> [FileNode] {
        let pid = projectId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? projectId
        var endpoint = "/api/file-tree/projects/\(pid)/files?depth=\(depth)"
        if let path, !path.isEmpty {
            let p = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
            endpoint += "&path=\(p)"
        }
        let data = try await request(endpoint)
        return try JSONDecoder().decode([FileNode].self, from: data)
    }

    /// Raw bytes of any tree file — the download path behind the file-preview
    /// share button. Binary/media files can't ride fileText's JSON envelope,
    /// and big files need more than the default 30s.
    func fileData(projectId: String, path: String) async throws -> Data {
        let pid = projectId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? projectId
        let p = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        return try await request("/api/file-tree/projects/\(pid)/files/content?path=\(p)", timeout: 120)
    }

    func fileText(projectId: String, filePath: String) async throws -> String {
        struct R: Codable { let content: String }
        let pid = projectId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? projectId
        let fp = filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filePath
        let data = try await request("/api/file-tree/projects/\(pid)/file?filePath=\(fp)")
        return try JSONDecoder().decode(R.self, from: data).content
    }

    // MARK: File-tree management (same routes the web file browser drives)

    /// Creates an empty file or directory under `parentPath` ("" = tree root).
    func createFileEntry(projectId: String, parentPath: String, name: String, isDirectory: Bool) async throws {
        let pid = projectId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? projectId
        let body = try JSONSerialization.data(withJSONObject: [
            "name": name, "type": isDirectory ? "directory" : "file", "path": parentPath])
        _ = try await request("/api/file-tree/projects/\(pid)/files/create", method: "POST", body: body)
    }

    func renameFileEntry(projectId: String, oldPath: String, newName: String) async throws {
        let pid = projectId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? projectId
        let body = try JSONSerialization.data(withJSONObject: ["oldPath": oldPath, "newName": newName])
        _ = try await request("/api/file-tree/projects/\(pid)/files/rename", method: "PUT", body: body)
    }

    /// Deletes a file or directory. The path rides in the DELETE body — that is
    /// this route's contract server-side, not a query parameter.
    func deleteFileEntry(projectId: String, path: String) async throws {
        let pid = projectId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? projectId
        let body = try JSONSerialization.data(withJSONObject: ["path": path])
        _ = try await request("/api/file-tree/projects/\(pid)/files", method: "DELETE", body: body)
    }

    /// Uploads files INTO the project tree at `targetPath` ("" = root) — the
    /// web file browser's upload route (multipart field `files`), distinct from
    /// the chat-attachment asset store.
    func uploadProjectFiles(projectId: String, targetPath: String,
                            files: [(name: String, mime: String, bytes: Data)]) async throws {
        guard !files.isEmpty else { return }
        let pid = projectId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? projectId
        guard let url = URL(string: (origin ?? Config.serverOrigin) + "/api/file-tree/projects/\(pid)/files/upload") else {
            throw APIError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let boundary = "mymu-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func textField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        textField("targetPath", targetPath)
        textField("requestedFileCount", String(files.count))
        for file in files {
            let safeName = file.name.replacingOccurrences(of: "\"", with: "_")
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"files\"; filename=\"\(safeName)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(file.mime)\r\n\r\n".data(using: .utf8)!)
            body.append(file.bytes)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "", url.host)
        }
    }

    /// `timeout` override exists for token-count PROBES: a list fanning out
    /// dozens of these must not let a dead host hold a slot for the full 30s.
    func history(sessionId: String, limit: Int = 200, offset: Int = 0,
                 timeout: TimeInterval? = nil) async throws -> HistoryResponse {
        let sid = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        let data = try await request("/api/providers/sessions/\(sid)/messages?limit=\(limit)&offset=\(offset)",
                                     timeout: timeout)
        return try JSONDecoder().decode(HistoryResponse.self, from: data)
    }

    private struct LimitsResponse: Codable { let attachmentBytes: Int? }

    /// The server-authoritative chat-attachment cap in bytes (`GET /api/limits`),
    /// so the composer never hardcodes it. Unauthenticated; returns 0 if the
    /// server predates the endpoint (caller keeps its fallback).
    func attachmentLimitBytes() async throws -> Int {
        let data = try await request("/api/limits", auth: false)
        return (try? JSONDecoder().decode(LimitsResponse.self, from: data))?.attachmentBytes ?? 0
    }

    // MARK: slash commands

    /// A `.claude/commands/*.md` command — project-level or user-level. Manar's
    /// whole fleet is user-level commands (`/environment`, `/mymu`, …), so the
    /// user scope matters more here than the project one.
    struct SlashCommand: Codable, Identifiable, Equatable {
        let name: String
        let description: String?
        let namespace: String?
        let path: String?
        var id: String { path ?? name }
        /// Server names are stored with or without the leading slash depending
        /// on scope; normalise so the composer always inserts exactly one.
        var invocation: String { name.hasPrefix("/") ? name : "/" + name }
    }

    private struct CommandsResponse: Codable {
        let builtIn: [SlashCommand]?
        let custom: [SlashCommand]?
    }

    /// `POST /api/commands/list`. `projectPath` is optional — omitting it still
    /// returns the user-level commands, which is the useful set for a live agent
    /// (it has no project path we can know from here).
    func slashCommands(projectPath: String?) async throws -> [SlashCommand] {
        let body = try JSONSerialization.data(
            withJSONObject: projectPath.map { ["projectPath": $0] } ?? [:])
        let data = try await request("/api/commands/list", method: "POST", body: body)
        let decoded = try JSONDecoder().decode(CommandsResponse.self, from: data)
        return (decoded.custom ?? []) + (decoded.builtIn ?? [])
    }

    // MARK: models

    struct ModelOption: Codable, Identifiable, Equatable {
        let value: String
        let label: String
        let description: String?
        var id: String { value }
    }

    private struct ModelsEnvelope: Codable {
        struct Models: Codable {
            let OPTIONS: [ModelOption]
            let DEFAULT: String
        }
        let models: Models
    }

    /// The provider's model catalogue (`GET /api/providers/:provider/models`).
    func models(provider: String = "claude") async throws -> (options: [ModelOption], defaultValue: String) {
        let data = try await request("/api/providers/\(provider)/models")
        let decoded = try JSONDecoder().decode(ModelsEnvelope.self, from: data)
        return (decoded.models.OPTIONS, decoded.models.DEFAULT)
    }

    private struct ActiveModelResponse: Codable { let model: String? }

    /// Which model a session resolves to right now
    /// (`GET /api/providers/:provider/sessions/:id/active-model`).
    func activeModel(provider: String = "claude", sessionId: String) async throws -> String? {
        let sid = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        let data = try await request("/api/providers/\(provider)/sessions/\(sid)/active-model")
        return (try? JSONDecoder().decode(ActiveModelResponse.self, from: data))?.model
    }

    // MARK: MCP servers

    /// A configured MCP server, as normalised by the server's provider adapters.
    /// `scope` is user / local / project; `transport` is stdio / http / sse.
    struct McpServer: Codable, Identifiable, Equatable {
        let name: String
        let scope: String?
        let transport: String?
        let command: String?
        let args: [String]?
        let url: String?
        var id: String { "\(scope ?? "")|\(name)" }

        /// One line describing where it points — the command for stdio, the URL
        /// for http/sse. This is what you check when a server misbehaves.
        var target: String {
            if let url, !url.isEmpty { return url }
            let joined = ([command] + (args ?? [])).compactMap { $0 }.joined(separator: " ")
            return joined.isEmpty ? "—" : joined
        }
    }

    /// Scope-grouped listing: `GET /api/providers/:provider/mcp/servers`
    /// answers `{provider, scopes: {user: [...], local: [...], project: [...]}}`.
    private struct McpScopesResponse: Codable { let scopes: [String: [McpServer]]? }

    func mcpServers(provider: String = "claude") async throws -> [McpServer] {
        let data = try await request("/api/providers/\(provider)/mcp/servers")
        let decoded = try JSONDecoder().decode(McpScopesResponse.self, from: data)
        // Flatten, stamping the scope from its group key when the row omits it.
        return (decoded.scopes ?? [:]).flatMap { scope, servers in
            servers.map {
                McpServer(name: $0.name, scope: $0.scope ?? scope, transport: $0.transport,
                          command: $0.command, args: $0.args, url: $0.url)
            }
        }
        .sorted { ($0.scope ?? "", $0.name) < ($1.scope ?? "", $1.name) }
    }

    /// `DELETE /api/providers/:provider/mcp/servers/:name?scope=`
    func deleteMcpServer(provider: String = "claude", name: String, scope: String?) async throws {
        let n = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        var path = "/api/providers/\(provider)/mcp/servers/\(n)"
        if let scope { path += "?scope=\(scope)" }
        _ = try await request(path, method: "DELETE")
    }

    struct AssetRecord: Codable {
        let name: String?
        let path: String
        let size: Int?
        let mimeType: String?
    }

    /// Uploads chat attachments to the server's asset store (the standard
    /// claudecodeui flow: store first, then reference by path in chat.send).
    /// `field` is "images" for image files or "files" for anything else — it
    /// names both the route and the multipart field.
    func uploadAssets(_ attachments: [(name: String, mime: String, bytes: Data)], field: String) async throws -> [AssetRecord] {
        guard !attachments.isEmpty else { return [] }
        guard let url = URL(string: (origin ?? Config.serverOrigin) + "/api/assets/\(field)") else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let boundary = "mymu-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        for attachment in attachments {
            let safeName = attachment.name.replacingOccurrences(of: "\"", with: "_")
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(safeName)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(attachment.mime)\r\n\r\n".data(using: .utf8)!)
            body.append(attachment.bytes)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "", url.host)
        }
        struct R: Codable { let images: [AssetRecord]?; let attachments: [AssetRecord]? }
        let decoded = try JSONDecoder().decode(R.self, from: Self.unwrapEnvelope(data))
        return decoded.images ?? decoded.attachments ?? []
    }

    /// Stock upstream servers allocate chat sessions over REST before the first
    /// `chat.send` (the fork allocates implicitly on first message instead).
    /// Returns the new app session id.
    func createProviderSession(provider: String = "claude", projectPath: String) async throws -> String {
        struct R: Codable { let sessionId: String }
        let body = try JSONEncoder().encode(["provider": provider, "projectPath": projectPath])
        let data = try await request("/api/providers/sessions", method: "POST", body: body)
        return try JSONDecoder().decode(R.self, from: data).sessionId
    }

    /// Agent → host assignments (admin-set on the server): agentKey → host
    /// origin. Used to route a pinned agent's conversation through the saved
    /// account matching its host, so file sends land on the agent's machine.
    func agentHosts() async throws -> [String: String] {
        struct R: Codable { let assignments: [String: String]? }
        let data = try await request("/api/agent-hosts")
        return (try JSONDecoder().decode(R.self, from: data)).assignments ?? [:]
    }

    // MARK: Push notifications (locked contract with the server, 2026-09-13)

    /// Register this device's APNs token so the server can push agent-reply
    /// notifications. Idempotent upsert server-side.
    func pushRegister(deviceToken: String) async throws {
        struct Body: Encodable {
            let deviceToken: String
            let platform = "ios"
            let bundleId = "com.mymu.app"
            let appVersion: String?
        }
        let body = Body(deviceToken: deviceToken,
                        appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        _ = try await request("/api/push/register", method: "POST",
                              body: try JSONEncoder().encode(body))
    }

    /// Forget this device's token (sign-out / account removal).
    func pushUnregister(deviceToken: String) async throws {
        struct Body: Encodable { let deviceToken: String }
        _ = try await request("/api/push/register", method: "DELETE",
                              body: try JSONEncoder().encode(Body(deviceToken: deviceToken)))
    }
}
