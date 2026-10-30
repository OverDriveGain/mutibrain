import AVFoundation
import Combine
import UIKit

/// Dictation for the full-screen agent view (2026-10-30, Manar: "when the
/// agent view is filling the screen, the talk button only transcribes — a
/// very smart transcribe"). The mic records 16 kHz mono PCM16, the server's
/// POST /transcribe turns it into a clean written message (ElevenLabs Scribe,
/// Gemini fallback — see mymu-voice shell/transcribe.py), and the text lands
/// in MyMu's composer (ChatView host patch) for the user to read, edit, send.
///
/// Tap to start, tap to finish (WhatsApp-style, no hold). Never runs at the
/// same time as the voice conversation: the host stops GadkVoice first — one
/// mic, one owner. Audio rules as everywhere in the app: every engine
/// mutation on AudioGraph.q, the session in the standard `.media` state
/// (recorder input), released when nothing else uses audio.
@MainActor
final class Dictation: ObservableObject {
    static let shared = Dictation()

    enum Phase: Equatable { case idle, recording, transcribing, failed(String) }
    @Published var phase: Phase = .idle
    @Published var level: Float = 0
    @Published var seconds = 0
    /// The finished transcript — the composer consumes it and sets it back to nil.
    @Published var result: String?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                       channels: 1, interleaved: true)!
    private var pcm = Data()
    private let lock = NSLock()
    private var timer: Timer?
    private let maxSeconds = 300
    private var failTask: Task<Void, Never>?

    func toggle() {
        switch phase {
        case .recording: stop()
        case .transcribing: break
        default: start()
        }
    }

    func start() {
        guard phase != .recording, phase != .transcribing else { return }
        GadkVoice.beacon("dictate-start")
        failTask?.cancel()
        phase = .recording
        seconds = 0; level = 0
        lock.lock(); pcm = Data(); lock.unlock()
        UIApplication.shared.isIdleTimerDisabled = true
        let ask: (@escaping (Bool) -> Void) -> Void = { done in
            if #available(iOS 17.0, *) { AVAudioApplication.requestRecordPermission { done($0) } }
            else { AVAudioSession.sharedInstance().requestRecordPermission { done($0) } }
        }
        ask { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.phase == .recording else { return }
                guard granted else { self.fail("Microphone access is off — enable it in Settings"); return }
                self.startEngine()
            }
        }
    }

    /// Finish and transcribe.
    func stop() {
        guard phase == .recording else { return }
        teardown()
        let data: Data
        lock.lock(); data = pcm; pcm = Data(); lock.unlock()
        guard data.count > 16000 * 2 / 2 else {   // < 0.5 s: nothing was said
            fail("Nothing heard")
            return
        }
        phase = .transcribing
        GadkVoice.beacon("dictate-stop-\(data.count / 32000)s")
        Task { await self.transcribe(Self.wav(data)) }
    }

    /// Abandon the recording (the drawer left the full-screen view).
    func cancel() {
        guard phase == .recording else { return }
        teardown()
        lock.lock(); pcm = Data(); lock.unlock()
        phase = .idle
        GadkVoice.beacon("dictate-cancel")
    }

    // MARK: - engine

    private func startEngine() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                self.seconds += 1
                if self.seconds >= self.maxSeconds { self.stop() }
            }
        }
        AudioGraph.q.async { [self] in
            AudioSessionManager.media()
            let input = engine.inputNode
            guard input.inputFormat(forBus: 0).sampleRate > 0 else {
                DispatchQueue.main.async { self.fail("No audio input available") }
                return
            }
            let tapped = AudioGraph.guarded("dictate-tap") {
                input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in
                    self?.handle(buf)
                }
            }
            guard tapped else {
                DispatchQueue.main.async { self.fail("Microphone unavailable") }
                return
            }
            engine.prepare()
            do { try engine.start() } catch {
                AudioGraph.guarded("dictate-untap") { input.removeTap(onBus: 0) }
                DispatchQueue.main.async { self.fail("Couldn't start the microphone") }
            }
        }
    }

    private func teardown() {
        timer?.invalidate(); timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        AudioGraph.q.async { [self] in
            AudioGraph.guarded("dictate-stop") {
                if engine.isRunning {
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                }
            }
            converter = nil
            // the recorder/music keep the session; otherwise release it
            if !(AudioStreamer.anyStreaming || SubsonicPlayer.isActive) {
                AudioSessionManager.deactivate()
            }
        }
    }

    /// Audio-thread: resample to 16 kHz mono PCM16 (the format Scribe and
    /// Gemini take natively) and accumulate; a cheap peak drives the meter.
    nonisolated private func handle(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.sampleRate > 0 else { return }
        let conv: AVAudioConverter
        if let c = converterFor(buffer.format) { conv = c } else { return }
        let ratio = 16000.0 / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: conv.outputFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let n = Int(out.frameLength)
        var peak: Int32 = 0
        var i = 0
        while i < n { peak = max(peak, abs(Int32(ch[0][i]))); i += 8 }
        let lvl = min(Float(1), Float(peak) / 9000)
        lock.lock()
        pcm.append(Data(bytes: ch[0], count: n * 2))
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.level = max(lvl, self.level * 0.72)
        }
    }

    nonisolated private func converterFor(_ format: AVAudioFormat) -> AVAudioConverter? {
        lock.lock(); defer { lock.unlock() }
        if let c = converter, c.inputFormat == format { return c }
        converter = AVAudioConverter(from: format, to: target)
        return converter
    }

    // MARK: - transcription

    private func transcribe(_ wav: Data) async {
        let t = GadkVoice.feedTarget()
        var comps = URLComponents(url: t.origin.appendingPathComponent("transcribe"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "app", value: t.app), .init(name: "token", value: t.token)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.httpBody = wav
        req.timeoutInterval = 90
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            guard code == 200, let text = obj["text"] as? String else {
                let msg = (obj["message"] as? String) ?? (obj["error"] as? String) ?? "HTTP \(code)"
                GadkVoice.beacon("dictate-FAIL-\(code)")
                fail("Transcription failed — \(msg)")
                return
            }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { fail("Nothing heard"); return }
            GadkVoice.beacon("dictate-ok-\(clean.count)ch-\((obj["engine"] as? String) ?? "?")")
            Haptics.send()
            result = clean
            phase = .idle
        } catch {
            GadkVoice.beacon("dictate-FAIL-net")
            fail("Transcription failed — check the connection")
        }
    }

    private func fail(_ msg: String) {
        phase = .failed(msg)
        failTask?.cancel()
        failTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if case .failed = self.phase { self.phase = .idle }
        }
    }

    /// 44-byte RIFF/WAVE header + the PCM16 payload (16 kHz mono).
    private static func wav(_ pcm: Data) -> Data {
        var h = Data()
        func le32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        func le16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        h.append(contentsOf: Array("RIFF".utf8)); le32(36 + pcm.count)
        h.append(contentsOf: Array("WAVE".utf8))
        h.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1)
        le32(16000); le32(32000); le16(2); le16(16)
        h.append(contentsOf: Array("data".utf8)); le32(pcm.count)
        h.append(pcm)
        return h
    }
}
