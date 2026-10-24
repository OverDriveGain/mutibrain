import Foundation

/// POSTs captured microphone audio to the screenpipe central server's
/// `/ingest-audio` endpoint in thin-client mode: the client ships an encoded
/// audio segment (AAC/m4a from the app recorder, or WAV from the broadcast
/// extension) and the central ASR-transcribes it on the GPU. This is the AUDIO
/// half of the screenpipe massam (see mymu-voice catalog/screenpipe@1.yaml);
/// `IngestClient` is the SCREEN half.
///
/// Replaces the old `/v1/audio` WebSocket uplink — that endpoint never existed
/// on the central server (every dial got HTTP 403). Screenpipe's real audio
/// ingest is this batch POST.
///
/// Applies the same backpressure as `IngestClient`: at most one request in
/// flight; a segment offered while a POST is outstanding is dropped, so the
/// memory-capped broadcast extension never piles up requests.
final class AudioIngestClient {
    private let cfg: SharedConfig
    private let session: URLSession

    /// connected/ok state for UI (true after a 2xx, false on failure).
    var onState: ((Bool) -> Void)?

    private let lock = NSLock()
    private var busy = false

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(cfg: SharedConfig) {
        self.cfg = cfg
        let c = URLSessionConfiguration.ephemeral
        c.shouldUseExtendedBackgroundIdleMode = true
        c.waitsForConnectivity = true
        c.timeoutIntervalForRequest = 30          // audio segments are larger than a JPEG
        c.urlCache = nil
        c.httpMaximumConnectionsPerHost = 1
        self.session = URLSession(configuration: c)
    }

    /// A collision-free, monotonic per-agent chunk id: epoch-milliseconds. Both
    /// the app recorder AND the broadcast-extension mic can run at once and they
    /// do NOT share UserDefaults under free provisioning — a shared counter would
    /// collide on (agent_id, source_chunk_id) and the central would dedup-drop
    /// one stream. Epoch-ms is unique across processes and is also a valid cursor
    /// (BigInteger on the server).
    static func nextChunkId() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    /// Send one encoded audio segment. No-op (drops it) if a POST is in flight.
    /// `mime` = "audio/mp4" (AAC/m4a) or "audio/wav"; the central's ASR sniffs
    /// the actual container, so either decodes.
    func sendSegment(_ audio: Data, mime: String = "audio/mp4",
                     chunkId: Int = AudioIngestClient.nextChunkId(),
                     timestamp: Date = Date()) {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()

        var req = URLRequest(url: cfg.ingestAudioURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(cfg.token)", forHTTPHeaderField: "Authorization")
        let built: Bool = autoreleasepool {
            let body: [String: Any] = [
                "agent_id": cfg.agentId,
                "chunks": [[
                    "chunk_id": chunkId,
                    "timestamp": Self.iso.string(from: timestamp),
                    "audio_b64": audio.base64EncodedString(),
                    "audio_mime": mime,
                ]],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
            req.httpBody = data
            return true
        }
        guard built else { finish(false); return }

        session.dataTask(with: req) { [weak self] _, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ok = err == nil && code == 200
            CaptureStats.recordAudio(ok: ok, code: code)    // debug panel (app group)
            self?.finish(ok)
        }.resume()
    }

    private func finish(_ ok: Bool) {
        lock.lock(); busy = false; lock.unlock()
        onState?(ok)
    }
}
