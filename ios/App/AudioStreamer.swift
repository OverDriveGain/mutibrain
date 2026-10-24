import Foundation
import AVFoundation
import UIKit

/// Captures the mic continuously (including while backgrounded / screen locked,
/// thanks to the `audio` background mode + an active record session) and ships
/// it to a screenpipe central server as rotated AAC/m4a segments via
/// `POST /ingest-audio` (the screenpipe massam, audio half — see mymu-voice
/// catalog/screenpipe@1.yaml).
///
/// HISTORY: this used to stream 16 kHz PCM16 over a `/v1/audio` WebSocket. That
/// endpoint never existed on the central server (every dial got HTTP 403), so no
/// audio was ever ingested. Screenpipe's real audio ingest is a batch POST of
/// encoded chunks, which the central ASR-transcribes on the GPU. We now record
/// short AAC segments with `AVAudioRecorder` (native, background-capable, real
/// mp4 container the ASR decodes) and POST each finished segment.
final class AudioStreamer: NSObject, ObservableObject, AVAudioRecorderDelegate {
    /// ONE app-wide recorder. It must outlive the Settings sheet that toggles
    /// it — a sheet-owned @StateObject deallocates on dismiss and takes the
    /// running capture with it ("mic goes off when I close the menu").
    static let shared = AudioStreamer()

    /// STRICTLY OPT-IN (Manar, 2026-07-15): the always-on recorder never
    /// starts unless the user explicitly enabled it in Settings; that choice
    /// persists.
    private static let enabledKey = "micAlwaysOn"

    static var alwaysOn: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Called once at app launch: start capture unless the user turned it off.
    func autoStartIfEnabled() {
        guard Self.alwaysOn, !isStreaming else { return }
        GadkVoice.beacon("sp-mic-autostart")
        start()
    }

    /// User-intent wrappers (Settings button): remember the choice.
    func userStart() {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        start()
    }

    func userStop() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        stop()
    }

    @Published private(set) var isStreaming = false
    @Published private(set) var connected = false
    @Published private(set) var sentKB: Double = 0

    /// Visible to GadkVoice: while the screenpipe mic records, nobody may
    /// deactivate the shared AVAudioSession (it would kill this capture).
    static private(set) var anyStreaming = false

    private var recorder: AVAudioRecorder?
    private var ingest: AudioIngestClient?
    private var observers: [NSObjectProtocol] = []
    private var heartbeat: Timer?
    private var hbCount = 0

    /// Segment length. Each finished segment is uploaded and a new one starts.
    private let segmentSeconds: TimeInterval = 20

    /// AAC / m4a, 16 kHz mono — matches the ASR target and keeps segments small.
    private let recordSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

    // MARK: - Lifecycle

    func start() {
        guard !isStreaming else { return }
        requestMicThen { [weak self] granted in
            guard let self, granted else { return }
            GadkVoice.beacon("sp-mic-start-granted-\(granted)")
            self.ingest = AudioIngestClient(cfg: SharedConfig.load())
            self.ingest?.onState = { [weak self] up in
                DispatchQueue.main.async { self?.connected = up }
            }
            // Async onto the graph queue: the permission callback can arrive ON
            // MAIN, and session/recorder setup can stall for seconds during a
            // route flap — a synchronous hop would block the main thread
            // (watchdog kill, no crash marker). The session assert lives inside
            // the ordered block and never yanks an active conversation.
            AudioGraph.q.async { [weak self] in
                guard let self else { return }
                if AudioSessionManager.state != .conversation { AudioSessionManager.media() }
                guard self.startSegmentLocked() else {
                    GadkVoice.beacon("sp-mic-record-FAILED")
                    return
                }
                Self.anyStreaming = true
                self.installResilience()
                DispatchQueue.main.async {
                    self.isStreaming = true
                    // Ground-truth heartbeat: if these stop the moment the app
                    // backgrounds, iOS suspended us; if they continue, capture
                    // is alive and any "not recording" is downstream.
                    self.hbCount = 0
                    self.heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                        guard let self else { return }
                        self.hbCount += 1
                        GadkVoice.beacon("sp-mic-hb-\(self.hbCount)-kb\(Int(self.sentKB))-rec\(self.recorder?.isRecording == true)")
                    }
                }
                GadkVoice.beacon("sp-mic-streaming-v10-ingestaudio")
            }
        }
    }

    func stop() {
        Self.anyStreaming = false
        heartbeat?.invalidate()
        heartbeat = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        AudioGraph.q.async { [self] in
            AudioGraph.guarded("sp-stop") {
                // Discard the in-flight partial segment (do NOT upload it — the
                // delegate's success path only fires on a natural forDuration end).
                recorder?.delegate = nil
                if recorder?.isRecording == true { recorder?.stop() }
                if let url = recorder?.url { try? FileManager.default.removeItem(at: url) }
                recorder = nil
            }
            if !SubsonicPlayer.isActive && AudioSessionManager.state != .conversation {
                AudioSessionManager.deactivate()
            }
        }
        ingest = nil
        DispatchQueue.main.async {
            self.isStreaming = false
            self.connected = false
        }
        GadkVoice.beacon("sp-mic-stopped")
    }

    /// Everything iOS does to background audio, answered: interruptions
    /// (Siri/calls/alarms) resume when allowed; a mediaserverd crash rebuilds
    /// from the session up; a foreground return revives a stalled recorder.
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
                self.restartCapture("interruption-end")
            }
        })
        observers.append(nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, Self.anyStreaming else { return }
            GadkVoice.beacon("sp-mic-mediaservices-reset")
            self.restartCapture("media-reset")
        })
        observers.append(nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            GadkVoice.beacon("sp-mic-went-background-rec-\(self.recorder?.isRecording == true)")
        })
        observers.append(nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            GadkVoice.beacon("sp-mic-foreground-again-rec-\(self.recorder?.isRecording == true)")
            if Self.anyStreaming && self.recorder?.isRecording != true {
                self.restartCapture("foreground-revive")
            }
        })
    }

    private func restartCapture(_ why: String) {
        AudioGraph.q.async { [self] in
            guard Self.anyStreaming else { return }
            if AudioSessionManager.state != .conversation { AudioSessionManager.media() }
            AudioGraph.guarded("sp-restart-teardown") {
                recorder?.delegate = nil
                if recorder?.isRecording == true { recorder?.stop() }
                if let url = recorder?.url { try? FileManager.default.removeItem(at: url) }
                recorder = nil
            }
            if startSegmentLocked() {
                GadkVoice.beacon("sp-mic-recovered-\(why)")
            } else {
                GadkVoice.beacon("sp-mic-recover-FAILED-\(why)")
            }
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

    /// MUST run on AudioGraph.q. Start ONE fixed-length AAC segment; the delegate
    /// uploads it and starts the next when `record(forDuration:)` finishes.
    @discardableResult
    private func startSegmentLocked() -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spmic-\(UUID().uuidString).m4a")
        do {
            let rec = try AVAudioRecorder(url: url, settings: recordSettings)
            rec.delegate = self
            guard rec.record(forDuration: segmentSeconds) else {
                try? FileManager.default.removeItem(at: url)
                return false
            }
            recorder = rec
            return true
        } catch {
            GadkVoice.beacon("sp-mic-recorder-init-FAILED-\(error.localizedDescription)")
            NSLog("AudioStreamer recorder error: \(error)")
            return false
        }
    }

    // MARK: - AVAudioRecorderDelegate — segment finished -> upload + rotate

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        // Read + upload the finished segment (off the delegate thread is fine;
        // AudioIngestClient does its own backpressure).
        if flag, let data = try? Data(contentsOf: url), !data.isEmpty {
            ingest?.sendSegment(data, mime: "audio/mp4")
            let kb = Double(data.count) / 1024
            DispatchQueue.main.async { self.sentKB += kb }
        }
        try? FileManager.default.removeItem(at: url)
        // Rotate: start the next segment if we're still meant to be capturing.
        AudioGraph.q.async { [weak self] in
            guard let self, Self.anyStreaming else { return }
            self.startSegmentLocked()
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        GadkVoice.beacon("sp-mic-encode-error-\(error?.localizedDescription ?? "nil")")
        try? FileManager.default.removeItem(at: recorder.url)
        restartCapture("encode-error")
    }
}
