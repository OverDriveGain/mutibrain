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

    /// Visible to GadkVoice: while the screenpipe mic streams, nobody may
    /// deactivate the shared AVAudioSession (it would kill this stream).
    static private(set) var anyStreaming = false

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var ws: WebSocketClient?
    private var observers: [NSObjectProtocol] = []

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
            GadkVoice.beacon("sp-mic-start-granted-\(granted)")
            self.configureSession()
            self.connect()
            do {
                try self.startEngine()
                Self.anyStreaming = true
                self.installResilience()
                DispatchQueue.main.async { self.isStreaming = true }
                GadkVoice.beacon("sp-mic-streaming")
            } catch {
                GadkVoice.beacon("sp-mic-engine-FAILED-\(error.localizedDescription)")
                NSLog("AudioStreamer engine error: \(error)")
            }
        }
    }

    func stop() {
        Self.anyStreaming = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        ws?.close()
        ws = nil
        converter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        DispatchQueue.main.async {
            self.isStreaming = false
            self.connected = false
        }
        GadkVoice.beacon("sp-mic-stopped")
    }

    /// Everything iOS does to background audio, answered: interruptions
    /// (Siri/calls/alarms) resume when allowed; engine halts (route/config
    /// changes) rebuild; a mediaserverd crash rebuilds from the session up.
    private func installResilience() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, Self.anyStreaming,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                GadkVoice.beacon("sp-mic-interrupted")
            } else {
                GadkVoice.beacon("sp-mic-interruption-ended")
                self.configureSession()
                self.restartEngine("interruption-end")
            }
        })
        observers.append(nc.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, Self.anyStreaming, !self.engine.isRunning else { return }
            self.restartEngine("config-change")
        })
        observers.append(nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, Self.anyStreaming else { return }
            GadkVoice.beacon("sp-mic-mediaservices-reset")
            self.configureSession()
            self.restartEngine("media-reset")
        })
    }

    private func restartEngine(_ why: String) {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        engine.disconnectNodeOutput(playerNode)
        converter = nil                      // formats may have changed — rebuild lazily
        do {
            try startEngine()
            GadkVoice.beacon("sp-mic-recovered-\(why)")
        } catch {
            GadkVoice.beacon("sp-mic-recover-FAILED-\(why)-\(error.localizedDescription)")
        }
    }

    // MARK: - Setup

    private func requestMicThen(_ done: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in done(granted) }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in done(granted) }
        }
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

        // Player node lets the server stream a spoken reply back to the user.
        if playerNode.engine == nil { engine.attach(playerNode) }
        engine.connect(playerNode, to: engine.mainMixerNode, format: targetFormat)

        // Tap in the node's NATIVE format; the converter is built lazily from
        // the first real buffer (a snapshotted format goes silently dead on
        // real devices after route changes — same bug the voice path had).
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        engine.prepare()
        try engine.start()
        playerNode.play()
    }

    // MARK: - Uplink (mic -> server)

    private func handle(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || converter!.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter, buffer.format.sampleRate > 0 else { return }
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
