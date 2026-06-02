import Foundation
import AVFoundation

/// Captures the mic continuously (including while backgrounded / screen locked,
/// thanks to the `audio` background mode + an active record session) and streams
/// 16 kHz mono PCM16 to the server. Also plays back any audio the server pushes
/// down (e.g. the assistant's spoken reply / TTS).
final class AudioStreamer: NSObject, ObservableObject {
    @Published private(set) var isStreaming = false
    @Published private(set) var connected = false
    @Published private(set) var sentKB: Double = 0

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var ws: WebSocketClient?

    /// What the server wants: 16 kHz, mono, signed 16-bit, interleaved.
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    // MARK: - Lifecycle

    func start() {
        guard !isStreaming else { return }
        requestMicThen { [weak self] granted in
            guard let self, granted else { return }
            self.configureSession()
            self.connect()
            do {
                try self.startEngine()
                DispatchQueue.main.async { self.isStreaming = true }
            } catch {
                NSLog("AudioStreamer engine error: \(error)")
            }
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        ws?.close()
        ws = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        DispatchQueue.main.async {
            self.isStreaming = false
            self.connected = false
        }
    }

    // MARK: - Setup

    private func requestMicThen(_ done: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in done(granted) }
    }

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            // playAndRecord keeps the mic hot while we also play TTS back.
            try s.setCategory(.playAndRecord,
                              mode: .voiceChat,
                              options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers])
            try s.setActive(true)
        } catch {
            NSLog("AudioStreamer session error: \(error)")
        }
    }

    private func connect() {
        let cfg = SharedConfig.load()
        let client = WebSocketClient(url: cfg.audioURL, token: cfg.token)
        client.onState = { [weak self] up in DispatchQueue.main.async { self?.connected = up } }
        client.onData = { [weak self] data in self?.playback(pcm16: data) }
        client.onText = { text in NSLog("server: \(text)") }
        client.connect()
        ws = client
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        // Player node lets the server stream a spoken reply back to the user.
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        engine.prepare()
        try engine.start()
        playerNode.play()
    }

    // MARK: - Uplink (mic -> server)

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var convErr: NSError?
        converter.convert(to: out, error: &convErr) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if convErr != nil { return }

        guard let chData = out.int16ChannelData else { return }
        let bytes = Int(out.frameLength) * MemoryLayout<Int16>.size
        guard bytes > 0 else { return }
        let data = Data(bytes: chData[0], count: bytes)
        ws?.sendBinary(data)
        DispatchQueue.main.async { self.sentKB += Double(bytes) / 1024 }
    }

    // MARK: - Downlink (server TTS -> speaker)

    /// Server pushes raw 16 kHz mono PCM16; schedule it on the player node.
    private func playback(pcm16 data: Data) {
        let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frames),
              let dst = buf.int16ChannelData else { return }
        buf.frameLength = frames
        data.withUnsafeBytes { raw in
            if let src = raw.bindMemory(to: Int16.self).baseAddress {
                dst[0].update(from: src, count: Int(frames))
            }
        }
        playerNode.scheduleBuffer(buf, completionHandler: nil)
        if !playerNode.isPlaying { playerNode.play() }
    }
}
