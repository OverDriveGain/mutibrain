import Foundation

/// Tiny WebSocket wrapper used by both the app (audio) and the broadcast
/// extension (screen). Auto-reconnects with backoff. Sends binary + text.
final class WebSocketClient: NSObject {
    private let url: URL
    private let token: String
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var shouldRun = false
    private var backoff: TimeInterval = 1

    /// Called when the server pushes data/text back (e.g. assistant TTS audio).
    var onData: ((Data) -> Void)?
    var onText: ((String) -> Void)?
    var onState: ((Bool) -> Void)?   // connected / disconnected

    init(url: URL, token: String) {
        self.url = url
        self.token = token
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.shouldUseExtendedBackgroundIdleMode = true
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg)
    }

    func connect() {
        shouldRun = true
        openSocket()
    }

    private func openSocket() {
        guard shouldRun else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let t = session.webSocketTask(with: req)
        task = t
        t.resume()
        onState?(true)
        backoff = 1
        receive()
    }

    func sendBinary(_ data: Data) {
        task?.send(.data(data)) { [weak self] err in
            if err != nil { self?.dropAndReconnect() }
        }
    }

    func sendText(_ string: String) {
        task?.send(.string(string)) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let d): self.onData?(d)
                case .string(let s): self.onText?(s)
                @unknown default: break
                }
                self.receive()
            case .failure:
                self.dropAndReconnect()
            }
        }
    }

    private func dropAndReconnect() {
        guard shouldRun else { return }
        onState?(false)
        task?.cancel()
        task = nil
        let delay = backoff
        backoff = min(backoff * 2, 15)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.openSocket()
        }
    }

    func close() {
        shouldRun = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onState?(false)
    }
}
