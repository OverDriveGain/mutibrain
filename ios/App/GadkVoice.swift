import Foundation
import AVFoundation
import Combine
import UIKit

/// Native realtime voice client for the gadk calendar agent (the pet's brain).
///
/// Replaces the old WKWebView (VoiceBridge) that hosted gadk's `/voice` web page.
/// A WebRTC voice call inside WKWebView fought iOS's shared audio session, which
/// caused the chronic earpiece / faint-output / "agent hears silence (mic reset)"
/// bugs — every speaker override knocked the webview's mic offline. Here the audio
/// session is OURS: AVAudioEngine + the voice-processing I/O unit (hardware echo
/// cancellation + AGC + noise suppression), output forced to the loudspeaker. The
/// agent never hears itself, and nothing fights us for the route.
///
/// Talks gadk's ADK `/run_live` WebSocket directly — identical protocol to the web
/// client (calendar-agent/static/voice.js):
///   1. POST {origin}/apps/calendar_agent/users/{uid}/sessions            -> { id }
///   2. WS   {origin}/run_live?app_name=…&user_id=…&session_id=…&modalities=AUDIO
///   3. send: {"blob":{"mimeType":"audio/pcm;rate=16000","data":<b64 Int16LE>}}  (mic 16 kHz)
///   4. recv: content.parts[].inlineData(audio/pcm @24k) -> play
///            outputTranscription.text -> assistant caption ; turnComplete ; interrupted (barge-in)
///   5. end:  {"close":true}
final class GadkVoice: ObservableObject {
    @Published var active = false       // session running (mic live)
    @Published var answering = false    // assistant currently speaking
    @Published var caption = ""         // latest assistant words (this turn)
    @Published var moveRequest: String? // critter move ordered by the agent (perform_move tool)
    @Published var brainDispatched = 0  // bumps when ask_the_brain fires (cue: refresh /pending now)

    /// (origin, app, token) for sibling fetches (/pending, /capabilities) —
    /// same parse the voice session itself uses.
    static func feedTarget() -> (origin: URL, app: String, token: String) {
        let t = Target.from(SharedConfig.load().gadkURL)
        return (t.origin, t.app, t.token ?? "")
    }

    /// Where + who to talk to, parsed from the configured gadk URL. Since the
    /// single-env cutover the backend serves one app per subscriber behind
    /// MANDATORY token auth: the URL in Settings is the full tokenized one
    /// (https://agent.kaxtus.com/voice?app=manar&token=...), same as the QR link.
    private struct Target {
        let origin: URL
        let app: String
        let token: String?

        static func from(_ url: URL) -> Target {
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let app = q.first { $0.name == "app" }?.value ?? "manar"
            let token = q.first { $0.name == "token" }?.value
            var o = URLComponents()
            o.scheme = url.scheme ?? "https"
            o.host = url.host
            o.port = url.port
            return Target(origin: o.url ?? url, app: app, token: token)
        }
    }

    private var ws: URLSessionWebSocketTask?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var micConverter: AVAudioConverter?

    // gadk speaks 16 kHz mono PCM16 up, 24 kHz mono PCM16 down.
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private let sendFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                           channels: 1, interleaved: true)!

    private let sendQueue = DispatchQueue(label: "gadk.voice.send")
    private var pendingSend = Data()          // accumulated Int16 LE bytes (sendQueue only)
    private let sendChunkBytes = 3200 * 2     // ~200 ms @ 16 kHz, matches the web client
    private var newAgentTurn = true

    /// TEMP diagnostics: report milestones to the server's public /healthz as a
    /// query string, so they land in the server's access log — readable without
    /// any device tooling. Remove once the voice path is stable.
    static func beacon(_ msg: String) {
        let origin = Target.from(SharedConfig.load().gadkURL).origin
        var c = URLComponents(url: origin.appendingPathComponent("healthz"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "dbg", value: msg)]
        if let u = c.url { URLSession.shared.dataTask(with: u).resume() }
    }
    private func beacon(_ msg: String) { Self.beacon(msg) }

    deinit { Self.beacon("gadk-deinit") }

    private var userId: String = {
        let d = UserDefaults.standard
        if let u = d.string(forKey: "gadkUserId") { return u }
        let u = "ios-" + UUID().uuidString.prefix(8)
        d.set(u, forKey: "gadkUserId")
        return u
    }()

    // MARK: - Control (call on main)

    func toggle() { active ? stop() : start() }

    func start() {
        guard !active else { return }
        active = true; caption = ""; answering = false; newAgentTurn = true
        // A conversation is hands-free — don't let the screen auto-lock and
        // suspend the app mid-talk (session + critter die with it).
        UIApplication.shared.isIdleTimerDisabled = true
        // Explicitly ask for the mic BEFORE the engine starts: without this a
        // fresh install records silence (the engine "works" but Gemini hears
        // nothing and never answers). AudioStreamer asks for screenpipe; this
        // path must ask for itself.
        beacon("start")
        requestMicPermission { [weak self] granted in
            guard let self else { return }
            self.beacon(granted ? "mic-granted" : "mic-DENIED")
            guard granted else {
                NSLog("GadkVoice: microphone permission denied — enable it in Settings > AI Assistant")
                DispatchQueue.main.async { self.stop() }
                return
            }
            Task { await self.connectAndRun() }
        }
    }

    private func requestMicPermission(_ done: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { done($0) }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { done($0) }
        }
    }

    func stop() {
        guard active else { return }
        beacon("stop-called")
        active = false; answering = false; caption = ""
        UIApplication.shared.isIdleTimerDisabled = false
        ws?.send(.string("{\"close\":true}")) { _ in }
        ws?.cancel(with: .goingAway, reason: nil); ws = nil
        AudioGraph.q.async { [self] in
            AudioGraph.guarded("gadk-stop") {
                if engine.isRunning {
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                }
                player.stop()
            }
            // Leave call mode IN ORDER: engine down first, THEN voice
            // processing off, THEN the session back to .media so music/
            // recorder return to the normal media-volume domain. If nothing
            // is using audio at all, release the session entirely.
            AudioGraph.guarded("gadk-vp-off") {
                try? engine.inputNode.setVoiceProcessingEnabled(false)
            }
            if AudioStreamer.anyStreaming || SubsonicPlayer.isActive {
                AudioSessionManager.media()
            } else {
                AudioSessionManager.deactivate()
            }
        }
        sendQueue.async { [weak self] in self?.pendingSend.removeAll() }
        tapFired = false
        micConverter = nil
        playDiagSent = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        // Session restore/release happens in the q-block above, strictly
        // AFTER the engine teardown — never from here (racing the graph
        // queue on session state is what got the app watchdog-killed).
    }

    // MARK: - Connect

    private func connectAndRun() async {
        do {
            let target = Target.from(SharedConfig.load().gadkURL)
            let sid = try await createSession(target: target)
            beacon("session-ok")
            try startEngine()   // asserts the .conversation session state on q
            beacon("engine-ok")
            openSocket(target: target, sessionId: sid)
            beacon("ws-opening")
        } catch {
            beacon("start-FAILED-\(error.localizedDescription)")
            NSLog("GadkVoice start failed: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in self?.stop() }
        }
    }

    private func createSession(target: Target) async throws -> String {
        var comps = URLComponents(
            url: target.origin.appendingPathComponent("apps/\(target.app)/users/\(userId)/sessions"),
            resolvingAgainstBaseURL: false)!
        if let token = target.token { comps.queryItems = [.init(name: "token", value: token)] }
        let url = comps.url!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "gadk", code: 1, userInfo: [NSLocalizedDescriptionKey: "session create failed"])
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = obj?["id"] as? String else {
            throw NSError(domain: "gadk", code: 2, userInfo: [NSLocalizedDescriptionKey: "no session id"])
        }
        return id
    }

    private func openSocket(target: Target, sessionId: String) {
        var comps = URLComponents(url: target.origin.appendingPathComponent("run_live"),
                                  resolvingAgainstBaseURL: false)!
        comps.scheme = (target.origin.scheme == "http") ? "ws" : "wss"
        comps.queryItems = [
            .init(name: "app_name", value: target.app),
            .init(name: "user_id", value: userId),
            .init(name: "session_id", value: sessionId),
            .init(name: "modalities", value: "AUDIO"),
        ]
        if let token = target.token { comps.queryItems?.append(.init(name: "token", value: token)) }
        let task = URLSession.shared.webSocketTask(with: comps.url!)
        ws = task
        task.resume()
        receiveLoop()
    }

    // MARK: - Audio engine

    private func startEngine() throws {
        // Serialize with every other graph mutation (AudioStreamer restarts,
        // rebuilds, buffer scheduling) — racing them is what crashed the app.
        try AudioGraph.q.sync { try startEngineLocked() }
    }

    private func startEngineLocked() throws {
        // Call mode. iOS ducks other audio (music) under the conversation —
        // that's the STANDARD behavior we now embrace; .media restores full
        // music volume when the conversation ends (see stop()).
        AudioSessionManager.conversation()

        let input = engine.inputNode

        // CRASH GUARD: installing a tap when the input node has no valid format
        // (0 Hz / 0 ch — happens transiently right after a session change, e.g.
        // starting a call while music is playing) crashes hard. Re-assert the
        // session and bail gracefully instead of trapping.
        if input.inputFormat(forBus: 0).sampleRate == 0 || input.inputFormat(forBus: 0).channelCount == 0 {
            AudioSessionManager.conversation()
            if input.inputFormat(forBus: 0).sampleRate == 0 {
                Self.beacon("no-input-format-abort")
                throw NSError(domain: "gadk", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "no audio input available"])
            }
        }
        try? input.setVoiceProcessingEnabled(true)   // engine-level AEC (call mode)

        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(.speaker)
        Self.beacon("route-\(session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","))")

        // With voice processing enabled the output element silently drops audio
        // that isn't at the HARDWARE sample rate (the simulator tolerates it,
        // real devices don't): the player "plays", the mixer "resamples", the
        // speaker stays mute. Connect at the hardware rate and resample our
        // 24 kHz stream ourselves.
        let hwRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        playOutFormat = AVAudioFormat(standardFormatWithSampleRate: hwRate > 0 ? hwRate : 48000,
                                      channels: 1)!
        playConverter = AVAudioConverter(from: playFormat, to: playOutFormat)
        let wired = AudioGraph.guarded("gadk-wire") {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playOutFormat)
        }
        guard wired else {
            throw NSError(domain: "gadk", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "audio graph wire failed"])
        }
        Self.beacon("play-fmt-\(Int(playOutFormat.sampleRate))Hz")

        // Tap in the node's NATIVE format (format: nil). On real hardware the
        // reported format at install time can be transient/invalid (0 Hz), and a
        // converter built from it silently produces nothing forever — the
        // simulator never showed this. The converter is created lazily from the
        // first real buffer instead (see handleMic).
        let tapFormat = input.outputFormat(forBus: 0)
        Self.beacon("tap-format-\(Int(tapFormat.sampleRate))Hz-\(tapFormat.channelCount)ch")
        let tapped = AudioGraph.guarded("gadk-tap") {
            input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in
                self?.handleMic(buf)
            }
        }
        guard tapped else {
            throw NSError(domain: "gadk", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "mic tap install failed"])
        }
        engine.prepare()
        try engine.start()
        AudioGraph.guarded("gadk-play") { player.play() }
        Self.beacon("route-after-start-\(Self.currentRoute())-\(AudioSessionManager.describe())")

        // If iOS halts the engine (route/config change mid-call), restart it —
        // otherwise the mic silently dies and the call looks frozen.
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.active else { return }
            Self.beacon("engine-config-change")
            self.rebuildPlayback()
        })

        // Starting the voice-processing IO flips the route back to the earpiece
        // (Receiver) no matter what was set before. Chase it: whenever the route
        // lands on the receiver while we're live, force the speaker again. The
        // override triggers a config change; the handler above restarts the
        // engine; this observer stops firing once the output is Speaker.
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.active else { return }
            let route = Self.currentRoute()
            Self.beacon("route-change-\(route)")
            if route.contains("Receiver") {
                try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
            }
        })
        if Self.currentRoute().contains("Receiver") {
            try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
        }

        // Background persistence: UIBackgroundModes=audio keeps us alive while
        // the session records, but an INTERRUPTION (Siri, phone call, alarm)
        // silently stops the engine — without this observer the mic dies until
        // the user taps stop/start. Resume when iOS says we may.
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.active,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                Self.beacon("audio-interrupted")
            } else if type == .ended {
                let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                Self.beacon("audio-interruption-ended-resume-\(opts.contains(.shouldResume))")
                try? AVAudioSession.sharedInstance().setActive(true)
                self.rebuildPlayback()
            }
        })
    }

    private static func currentRoute() -> String {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .map { $0.portType.rawValue }.joined(separator: ",")
    }

    /// After an engine configuration change the player→mixer connection can be
    /// silently invalidated: the engine runs, the mic tap works, buffers get
    /// scheduled — into a dead node. Rebuild the whole playback leg.
    private func rebuildPlayback() {
        AudioGraph.q.async { [weak self] in self?.rebuildPlaybackLocked() }
    }

    /// MUST run on AudioGraph.q.
    private func rebuildPlaybackLocked() {
        AudioGraph.guarded("gadk-rebuild-teardown") {
            player.stop()
            engine.stop()
            engine.disconnectNodeOutput(player)
        }
        // The hardware rate can CHANGE mid-session (bluetooth/route flap — the
        // crash session started at 44.1k while everything assumes 48k), and
        // reconnecting with a stale format throws an uncatchable NSException.
        // Re-derive the output format + converter from the CURRENT hardware.
        let hwRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if hwRate > 0, playOutFormat == nil || hwRate != playOutFormat.sampleRate {
            playOutFormat = AVAudioFormat(standardFormatWithSampleRate: hwRate, channels: 1)!
            playConverter = AVAudioConverter(from: playFormat, to: playOutFormat)
            Self.beacon("play-fmt-rederived-\(Int(hwRate))Hz")
        }
        var connected = AudioGraph.guarded("gadk-rebuild-connect") {
            engine.connect(player, to: engine.mainMixerNode, format: playOutFormat ?? playFormat)
        }
        if !connected {
            // Degrade: let the engine pick the format rather than staying dead.
            connected = AudioGraph.guarded("gadk-rebuild-connect-nilfmt") {
                engine.connect(player, to: engine.mainMixerNode, format: nil)
            }
        }
        guard connected else { return }
        engine.mainMixerNode.outputVolume = 1.0
        engine.prepare()
        do {
            try engine.start()
            AudioGraph.guarded("gadk-rebuild-play") { player.play() }
            Self.beacon("playback-rebuilt-running")
        } catch {
            Self.beacon("playback-rebuild-FAILED-\(error.localizedDescription)")
        }
    }

    private var tapFired = false
    private var observers: [NSObjectProtocol] = []
    private var playOutFormat: AVAudioFormat!
    private var playConverter: AVAudioConverter?

    /// Render-thread: convert the mic buffer to 16 kHz PCM16 and hand bytes to the send queue.
    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        if !tapFired {
            tapFired = true
            Self.beacon("tap-first-fire-\(Int(buffer.format.sampleRate))Hz-\(buffer.format.channelCount)ch")
        }
        // (Re)build the converter from the actual buffer format, not a snapshot.
        if micConverter == nil || micConverter!.inputFormat != buffer.format {
            micConverter = AVAudioConverter(from: buffer.format, to: sendFormat)
            Self.beacon(micConverter == nil ? "converter-NIL" : "converter-ok")
        }
        guard let conv = micConverter, buffer.format.sampleRate > 0 else { return }
        let ratio = sendFormat.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: sendFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        if let err {
            Self.beacon("convert-ERR-\(err.code)")
            return
        }
        guard out.frameLength > 0, let ch = out.int16ChannelData else { return }
        // Once-a-second mic level log — silence here = permission/route problem.
        micLogFrames += Int(out.frameLength)
        var peak: Int16 = 0
        for i in 0..<Int(out.frameLength) { peak = max(peak, abs(ch[0][i])) }
        micLogPeak = max(micLogPeak, peak)
        if micLogFrames >= 16000 {
            NSLog("GadkVoice mic: peak=%d (%@)", micLogPeak, micLogPeak < 200 ? "SILENT?" : "ok")
            Self.beacon("mic-peak-\(micLogPeak)")
            micLogFrames = 0; micLogPeak = 0
        }
        let data = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
        sendQueue.async { [weak self] in self?.accumulate(data) }
    }

    private var micLogFrames = 0
    private var micLogPeak: Int16 = 0

    /// sendQueue: buffer ~200 ms then flush as base64 blobs.
    private func accumulate(_ data: Data) {
        pendingSend.append(data)
        while pendingSend.count >= sendChunkBytes {
            let slice = Data(pendingSend.prefix(sendChunkBytes))
            pendingSend.removeFirst(sendChunkBytes)
            let b64 = slice.base64EncodedString()
            let msg = ["blob": ["mimeType": "audio/pcm;rate=16000", "data": b64]]
            guard let json = try? JSONSerialization.data(withJSONObject: msg),
                  let str = String(data: json, encoding: .utf8) else { continue }
            ws?.send(.string(str)) { _ in }
        }
    }

    // MARK: - Receive

    private func receiveLoop() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                Self.beacon("ws-FAIL-\(err.localizedDescription)")
                NSLog("GadkVoice ws receive failed: %@", err.localizedDescription)
                DispatchQueue.main.async { if self.active { self.stop() } }
            case .success(let msg):
                if case .string(let text) = msg {
                    DispatchQueue.main.async { self.handleEvent(text) }
                }
                self.receiveLoop()
            }
        }
    }

    /// Main thread: drive playback + the pet's caption/answering state off gadk events.
    private func handleEvent(_ json: String) {
        guard let data = json.data(using: .utf8),
              let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if ev["interrupted"] as? Bool == true { flushPlayback() }   // barge-in

        if let content = ev["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            for part in parts {
                // The agent's perform_move tool call is OUR cue: the client is
                // the effector — forward the move to the critter webview.
                if let fc = part["functionCall"] as? [String: Any],
                   (fc["name"] as? String) == "perform_move",
                   let args = fc["args"] as? [String: Any], let mv = args["move"] as? String {
                    moveRequest = mv.lowercased().filter { $0.isLetter }  // sanitized for JS
                }
                // Any tool that returns {status:"playing", songs:[...]} ->
                // STANDARD HANDOFF (the Siri pattern): the music IS the
                // answer, so the conversation ENDS — stop() tears the voice
                // engine down in order on the graph queue (VP off, session
                // back to .media) and only THEN does the player start, at
                // full media volume. No mixing, no mid-flight route fight.
                if let fr = part["functionResponse"] as? [String: Any],
                   let resp = fr["response"] as? [String: Any],
                   (resp["status"] as? String) == "playing",
                   let raw = resp["songs"] {
                    if let data = try? JSONSerialization.data(withJSONObject: raw),
                       let songs = try? JSONDecoder().decode([Song].self, from: data), !songs.isEmpty {
                        Self.beacon("play-music-\(songs.count)-handoff")
                        stop()   // queues the ordered teardown on AudioGraph.q
                        SubsonicPlayer.shared.play(songs)  // queues AFTER it
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            Self.beacon("music-t2-\(AudioSessionManager.describe())-alive")
                        }
                    }
                }
                // ask_the_brain going out means the pending ledger just grew —
                // cue an immediate /pending refresh so the chip appears at once.
                if let fc = part["functionCall"] as? [String: Any],
                   (fc["name"] as? String) == "ask_the_brain" {
                    brainDispatched += 1
                }
                if let inline = part["inlineData"] as? [String: Any],
                   let mime = inline["mimeType"] as? String, mime.hasPrefix("audio/pcm"),
                   let b64 = inline["data"] as? String {
                    if !answering { Self.beacon("got-audio") }
                    answering = true
                    playPcm(b64)
                }
            }
        }
        if let ot = ev["outputTranscription"] as? [String: Any],
           let t = ot["text"] as? String, !t.isEmpty {
            if newAgentTurn { caption = ""; newAgentTurn = false }
            // finished:true REPEATS the whole turn's text as one aggregate —
            // appending it doubles the caption; replace with it (authoritative).
            if ot["finished"] as? Bool == true { caption = t } else { caption += t }
            answering = true
        }
        if ev["turnComplete"] as? Bool == true {
            answering = false
            newAgentTurn = true
        }
    }

    private var playDiagSent = false
    private var b64Drops = 0

    /// gadk sends inlineData as URL-SAFE, often unpadded base64. Swift's strict
    /// Data(base64Encoded:) rejects those outright, silently dropping almost
    /// every audio chunk — the web client normalizes (voice.js b64ToBytes);
    /// this port originally didn't. THE historical "app plays silence" bug.
    private func decodeB64(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    private func playPcm(_ b64: String) {
        guard let data = decodeB64(b64) else {
            b64Drops += 1
            if b64Drops == 1 || b64Drops % 50 == 0 { Self.beacon("b64-drop-\(b64Drops)") }
            return
        }
        let frames = AVAudioFrameCount(data.count / 2)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: frames) else { return }
        buf.frameLength = frames
        let dst = buf.floatChannelData![0]
        var peak: Float = 0
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(frames) {
                let v = Float(Int16(littleEndian: s[i])) / 32768.0
                dst[i] = v
                peak = max(peak, abs(v))
            }
        }
        if !playDiagSent {
            playDiagSent = true
            Self.beacon("play-state-engine-\(engine.isRunning)-player-\(player.isPlaying)"
                + "-vol-\(Int(engine.mainMixerNode.outputVolume * 100))-rxpeak-\(Int(peak * 1000))")
        }

        // Convert AND schedule on the graph queue. The 2026-07-15 SIGTRAP:
        // conversion ran on the main thread with the pre-music converter
        // (48 kHz) while music's AVPlayer flipped the hardware to 44.1 kHz and
        // the rebuild (on q) rewired the connection — scheduling that stale
        // 48 kHz buffer trapped with EXC_BREAKPOINT, which is NOT an
        // NSException and sails straight past ExcCatch. On q, the converter is
        // always the one matching the live graph, and the format guard below
        // makes a mismatch a dropped chunk + beacon instead of a dead app.
        AudioGraph.q.async { [weak self] in
            guard let self, self.active else { return }
            if !self.engine.isRunning { self.rebuildPlaybackLocked() }
            guard self.engine.isRunning else { return }  // rebuild failed — drop, don't crash

            var out = buf
            if let conv = self.playConverter, let fmt = self.playOutFormat,
               fmt.sampleRate != self.playFormat.sampleRate {
                let cap = AVAudioFrameCount(
                    Double(frames) * fmt.sampleRate / self.playFormat.sampleRate + 32)
                guard let ob = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return }
                var fed = false
                var err: NSError?
                conv.convert(to: ob, error: &err) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true; status.pointee = .haveData; return buf
                }
                if err != nil || ob.frameLength == 0 { return }
                out = ob
            }

            // The player's connection format is ground truth; a mismatched
            // scheduleBuffer is an uncatchable trap, so verify — never assume.
            let want = self.player.outputFormat(forBus: 0)
            guard out.format.sampleRate == want.sampleRate,
                  out.format.channelCount == want.channelCount else {
                Self.beacon("fmt-mismatch-drop-\(Int(out.format.sampleRate))"
                    + "vs\(Int(want.sampleRate))")
                return
            }
            AudioGraph.guarded("gadk-schedule") {
                if !self.player.isPlaying { self.player.play() }
                self.player.scheduleBuffer(out, completionHandler: nil)
            }
        }
    }

    private func flushPlayback() {
        // Barge-in. player.play() throws an uncatchable NSException if the
        // engine is stopped — and loud user speech can trigger an engine
        // config change that stops it right before the `interrupted` event
        // lands (this crashed the app). Guard; the config-change observer /
        // playPcm's rebuild path restart playback for the next reply.
        AudioGraph.q.async { [weak self] in
            guard let self else { return }
            AudioGraph.guarded("gadk-flush") {
                self.player.stop()
                if self.engine.isRunning { self.player.play() }
            }
        }
    }

}
