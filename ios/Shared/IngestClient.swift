import Foundation

/// POSTs captured screen frames to the screenpipe central server's `/ingest`
/// endpoint in thin-client mode: the phone ships a raw JPEG and the server does
/// the OCR + embedding. Used by the broadcast extension (one instance per
/// broadcast). Applies simple backpressure — at most one request in flight, new
/// frames are dropped while a POST is outstanding — so the memory-capped
/// extension never piles up requests.
final class IngestClient {
    private let cfg: SharedConfig
    private let session: URLSession

    /// connected/ok state for UI (true after a 2xx, false on failure).
    var onState: ((Bool) -> Void)?

    // Monotonic per-agent frame id: the dedup key + sync cursor on the server.
    // Persisted so it keeps climbing across broadcast restarts.
    private static let frameIdKey = "ingest.frameId"
    private let defaults = UserDefaults(suiteName: SharedConfig.appGroup) ?? .standard

    private let lock = NSLock()
    private var busy = false

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(cfg: SharedConfig) {
        self.cfg = cfg
        let c = URLSessionConfiguration.default
        c.shouldUseExtendedBackgroundIdleMode = true
        c.waitsForConnectivity = true
        c.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: c)
    }

    private func nextFrameId() -> Int {
        let n = defaults.integer(forKey: Self.frameIdKey) + 1
        defaults.set(n, forKey: Self.frameIdKey)
        return n
    }

    /// Send one frame. No-op (drops the frame) if a previous POST is still in flight.
    func sendFrame(jpeg: Data, timestamp: Date = Date()) {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()

        let body: [String: Any] = [
            "agent_id": cfg.agentId,
            "frames": [[
                "frame_id": nextFrameId(),
                "timestamp": Self.iso.string(from: timestamp),
                "app_name": "iOS",
                "capture_trigger": "periodic",
                "text_source": "ocr",
                "image_b64": jpeg.base64EncodedString(),
                "image_mime": "image/jpeg",
            ]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            finish(false); return
        }
        var req = URLRequest(url: cfg.ingestURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(cfg.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = data

        session.dataTask(with: req) { [weak self] _, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            self?.finish(err == nil && code == 200)
        }.resume()
    }

    private func finish(_ ok: Bool) {
        lock.lock(); busy = false; lock.unlock()
        onState?(ok)
    }
}
