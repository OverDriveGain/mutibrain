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
    var moveDuration: Double?           // optional hold time (s) for the pending moveRequest
    @Published var brainDispatched = 0  // bumps when ask_the_brain fires (cue: refresh /pending now)
    /// Connection/progress feedback line ("✓ Server up — connecting to Google…").
    /// Native milestones + server ?stages=1 messages feed it; empty = steady
    /// state (PetView falls back to Listening…/Talking…). A line starting with
    /// ✗ survives stop() so failures stay visible until the next attempt.
    @Published var stageText = ""
    /// Connect progress for the avatar ("loaded25"/"loaded50"/"loaded75"),
    /// "" once truly ready — the swarm gathers with it and only forms the
    /// rigid ball when Google is actually connected.
    @Published var connectStage = ""
    /// Smoothed mic loudness 0…1 for the on-screen equalizer — the LIVE proof
    /// the mic hears you while the status stays a simple "Listening…".
    @Published var micLevel: Float = 0
    /// The assistant's playback loudness 0…1 (mainMixer output tap) — feeds
    /// the avatar's talking pulse.
    @Published var outLevel: Float = 0

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

    /// Bumped by every start() and stop(). An async connect, a socket callback
    /// or a playback-drained callback belonging to an OLDER conversation must
    /// never touch the current one — a quick stop→start (or an app close/reopen
    /// mid-connect) otherwise let the old socket's late failure stop the NEW
    /// session, or let an abandoned connect start the engine + socket with the
    /// button showing idle (agent talking, UI "not talking"). Main thread only.
    private var epoch = 0
    /// The server said turnComplete; `answering` drops only once the player has
    /// also played out what's queued (the reply streams faster than real time,
    /// so turnComplete arrives seconds before the voice actually stops).
    private var turnDone = true
    /// Buffers scheduled on the player and not yet played back (AudioGraph.q only).
    private var queuedBuffers = 0

    /// TEMP diagnostics: report milestones to the server's public /healthz as a
    /// query string, so they land in the server's access log — readable without
    /// any device tooling. Remove once the voice path is stable.
    static func beacon(_ msg: String) {
        Breadcrumbs.add(msg)   // every beacon is also crash/bug-report context
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
        endRequested = false
        guard !active else { return }
        epoch += 1
        let myEpoch = epoch
        active = true; caption = ""; answering = false; newAgentTurn = true; turnDone = true
        stageText = "Connecting to server…"
        connectStage = "loaded25"
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
            Task { await self.connectAndRun(epoch: myEpoch) }
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
        epoch += 1
        turnDone = true
        active = false; answering = false; caption = ""; stageText = ""; connectStage = ""; micLevel = 0; outLevel = 0
        UIApplication.shared.isIdleTimerDisabled = false
        ws?.send(.string("{\"close\":true}")) { _ in }
        ws?.cancel(with: .goingAway, reason: nil); ws = nil
        teardownAudio()
        sendQueue.async { [weak self] in self?.pendingSend.removeAll() }
        tapFired = false
        micConverter = nil
        playDiagSent = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        // Session restore/release happens in teardownAudio's q-block, strictly
        // AFTER the engine teardown — never from here (racing the graph
        // queue on session state is what got the app watchdog-killed).
    }

    /// Engine down, voice processing off, session back to .media (or released).
    private func teardownAudio() {
        AudioGraph.q.async { [self] in
            AudioGraph.guarded("gadk-stop") {
                if engine.isRunning {
                    engine.inputNode.removeTap(onBus: 0)
                    engine.mainMixerNode.removeTap(onBus: 0)
                    engine.stop()
                }
                player.stop()
                queuedBuffers = 0   // a stopped player holds nothing
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
            // Music keeps playing at the DUCKED level after call mode ends
            // unless the player itself completes the transition (see
            // unduckAfterConversation) — restore full volume explicitly.
            if SubsonicPlayer.isActive {
                DispatchQueue.main.async { SubsonicPlayer.shared.unduckAfterConversation() }
            }
        }
    }

    // MARK: - Connect

    private func isCurrent(_ e: Int) async -> Bool {
        await MainActor.run { self.epoch == e && self.active }
    }

    /// The user stopped (or restarted) while this connect was in flight: undo
    /// what it started — unless a NEWER conversation is live and owns the engine.
    private func abandon(_ what: String, engineStarted: Bool) async {
        beacon("start-abandoned-\(what)")
        if engineStarted { await MainActor.run { if !self.active { self.teardownAudio() } } }
    }

    private func connectAndRun(epoch e: Int) async {
        do {
            let target = Target.from(SharedConfig.load().gadkURL)
            let sid = try await createSession(target: target)
            beacon("session-ok")
            guard await isCurrent(e) else { return await abandon("session", engineStarted: false) }
            await MainActor.run { stageText = "✓ Server up — starting audio…"; connectStage = "loaded50" }
            try startEngine()   // asserts the .conversation session state on q
            beacon("engine-ok")
            // check + open atomically on main, so a stop() can't slip between them
            let opened = await MainActor.run { () -> Bool in
                guard self.epoch == e && self.active else { return false }
                self.openSocket(target: target, sessionId: sid)
                self.stageText = "✓ Server up — connecting to Google…"; self.connectStage = "loaded75"
                return true
            }
            guard opened else { return await abandon("engine", engineStarted: true) }
            beacon("ws-opening")
        } catch {
            beacon("start-FAILED-\(error.localizedDescription)")
            NSLog("GadkVoice start failed: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.epoch == e else { return }
                self.stop()
                self.stageText = "✗ Couldn't reach the server — check connection, tap to retry"
            }
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
            .init(name: "stages", value: "1"),   // server sends {"mymuStage": ...} feedback
        ]
        if let token = target.token { comps.queryItems?.append(.init(name: "token", value: token)) }
        let task = URLSession.shared.webSocketTask(with: comps.url!)
        ws = task
        task.resume()
        receiveLoop(task)
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
        // Output tap: the assistant's REAL playback loudness (post-mix), so the
        // avatar can pulse with the voice as it is actually heard — not with
        // the (queued-ahead) network buffers.
        AudioGraph.guarded("gadk-outtap") {
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buf, _ in
                guard let self, let ch = buf.floatChannelData?.pointee else { return }
                let n = Int(buf.frameLength)
                guard n > 0 else { return }
                var peak: Float = 0
                var i = 0
                while i < n { peak = max(peak, abs(ch[i])); i += 16 }  // stride: cheap peak
                let lvl = min(peak * 2.2, 1)
                DispatchQueue.main.async { self.outLevel = max(lvl, self.outLevel * 0.75) }
            }
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
            queuedBuffers = 0   // a stopped player holds nothing
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
        // abs() on Int16 TRAPS for a full-scale negative sample (-32768 has
        // no positive counterpart) — ONE clipped mic sample crashed the app
        // mid-conversation (Zohreh's iPhone 16, crash thread = this tap).
        // Widen to Int32 before abs.
        var peak: Int32 = 0
        for i in 0..<Int(out.frameLength) { peak = max(peak, abs(Int32(ch[0][i]))) }
        micLogPeak = max(micLogPeak, Int16(clamping: peak))
        // Equalizer feed: fast rise, gentle decay (~12 updates/s from the tap).
        let lvl = min(Float(1), Float(peak) / 9000)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.micLevel = max(lvl, self.micLevel * 0.72)
        }
        if micLogFrames >= 16000 {
            NSLog("GadkVoice mic: peak=%d (%@)", micLogPeak, micLogPeak < 200 ? "SILENT?" : "ok")
            Self.beacon("mic-peak-\(micLogPeak)")
            micLogFrames = 0; micLogPeak = 0
        }
        let data = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
        sendQueue.async { [weak self] in self?.accumulate(data) }
    }

    /// The assistant called end_conversation: the socket close that follows
    /// is the goodbye, not a failure.
    private var endRequested = false

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

    /// Bound to ITS socket: once stop() drops `task` (or a new conversation
    /// opened another), its late callbacks are ignored instead of acting on
    /// whatever session is current.
    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                Self.beacon("ws-FAIL-\(err.localizedDescription)")
                NSLog("GadkVoice ws receive failed: %@", err.localizedDescription)
                // The server ends a goodbye by CLOSING the socket (normal
                // closure) — that's the conversation finishing as asked, not
                // a lost connection: end quietly, no error line.
                let normal = task.closeCode == .normalClosure || task.closeCode == .goingAway
                DispatchQueue.main.async {
                    if self.active && self.ws === task {
                        let asked = self.endRequested || normal
                        self.stop()
                        if asked { Self.beacon("ended-by-agent") }
                        else { self.stageText = "✗ Connection lost — tap to reconnect" }
                    }
                }
            case .success(let msg):
                if case .string(let text) = msg {
                    DispatchQueue.main.async {
                        guard self.ws === task else { return }
                        self.handleEvent(text)
                    }
                }
                self.receiveLoop(task)
            }
        }
    }

    /// Main thread: drive playback + the pet's caption/answering state off gadk events.
    private func handleEvent(_ json: String) {
        guard let data = json.data(using: .utf8),
              let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Server connection-stage feedback (?stages=1) — progress you can SEE
        // on a slow connection instead of a silent wait.
        if let st = ev["mymuStage"] as? String {
            Self.beacon("stage-\(st)")
            switch st {
            case "server_connected":  stageText = "✓ Server up — connecting to Google…"
            case "gemini_connecting": stageText = "✓ Server up · Google connecting…"; connectStage = "loaded99"
            case "gemini_connected":
                // Straight to "Listening…" — the ball forms at the SAME
                // moment the label says you can talk (no lingering banner).
                stageText = ""
                connectStage = ""
            default: break
            }
            return
        }

        if ev["interrupted"] as? Bool == true {   // barge-in: her turn is over
            turnDone = true
            flushPlayback()
        }

        if let content = ev["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            for part in parts {
                // Any tool call = the assistant is WORKING — show what, so a
                // long tool run doesn't read as a hang.
                if let fc = part["functionCall"] as? [String: Any],
                   let toolName = fc["name"] as? String {
                    stageText = "⚙️ \(toolName.replacingOccurrences(of: "_", with: " "))…"
                    if toolName == "end_conversation" { endRequested = true }
                }
                // The agent's perform_move tool call is OUR cue: the client is
                // the effector — forward the move to the critter webview.
                if let fc = part["functionCall"] as? [String: Any],
                   (fc["name"] as? String) == "perform_move",
                   let args = fc["args"] as? [String: Any], let mv = args["move"] as? String {
                    // duration_s (agent-controlled hold time) may arrive as a
                    // number or a numeric string — capture BEFORE moveRequest so
                    // PetView's onChange sees both.
                    if let d = args["duration_s"] as? Double { moveDuration = d }
                    else if let n = args["duration_s"] as? NSNumber { moveDuration = n.doubleValue }
                    else if let s = args["duration_s"] as? String { moveDuration = Double(s) }
                    else { moveDuration = nil }
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
                    // keep_listening=true (the user asked to keep talking, or the
                    // request implies a continuing conversation) -> DON'T hand off:
                    // start the music UNDER the live conversation (iOS ducks it in
                    // .conversation, like control_music) and leave the mic open.
                    // Absent/false -> standard Siri handoff: tear the voice engine
                    // down in order, then play at full media volume.
                    let keepListening = (resp["keep_listening"] as? Bool) ?? false
                    if let data = try? JSONSerialization.data(withJSONObject: raw),
                       let songs = try? JSONDecoder().decode([Song].self, from: data), !songs.isEmpty {
                        if keepListening {
                            Self.beacon("play-music-\(songs.count)-keeplistening")
                            DispatchQueue.main.async {
                                SubsonicPlayer.shared.play(songs)  // ducks under the live convo
                            }
                        } else {
                            Self.beacon("play-music-\(songs.count)-handoff")
                            stop()   // queues the ordered teardown on AudioGraph.q
                            SubsonicPlayer.shared.play(songs)  // queues AFTER it
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                Self.beacon("music-t2-\(AudioSessionManager.describe())-alive")
                            }
                        }
                    }
                }
                // The agent's control_music tool: transport for music that is
                // ALREADY playing. The conversation continues (music stays
                // ducked under it); only the player changes state.
                if let fr = part["functionResponse"] as? [String: Any],
                   let resp = fr["response"] as? [String: Any],
                   (resp["status"] as? String) == "music_control",
                   let action = resp["action"] as? String {
                    Self.beacon("music-ctl-\(action)")
                    DispatchQueue.main.async {
                        switch action {
                        case "stop": SubsonicPlayer.shared.stopFromVoice()
                        case "pause": SubsonicPlayer.shared.pauseFromVoice()
                        case "resume": SubsonicPlayer.shared.resumeFromVoice()
                        case "next": SubsonicPlayer.shared.next()
                        case "previous": SubsonicPlayer.shared.prev()
                        case "download":  // "download this song" — save the current track
                            if let cur = SubsonicPlayer.shared.current {
                                DownloadStore.shared.download(cur)
                            }
                        default: break
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
                    turnDone = false
                    settleTicks = 0
                    stageText = ""   // the voice itself is the feedback now
                    connectStage = ""
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
            turnDone = true
            newAgentTurn = true
            settleAnswering()
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
                self.queuedBuffers += 1
                self.player.scheduleBuffer(out, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    AudioGraph.q.async {
                        guard let self else { return }
                        self.queuedBuffers = max(0, self.queuedBuffers - 1)
                        if self.queuedBuffers == 0 { DispatchQueue.main.async { self.settleAnswering() } }
                    }
                }
            }
        }
    }

    /// Main thread: the assistant stops "answering" only when the server's turn
    /// is done AND the speaker has played everything queued.
    private func settleAnswering() {
        guard answering, turnDone else { return }
        AudioGraph.q.async { [weak self] in
            guard let self else { return }
            if self.queuedBuffers == 0 {
                DispatchQueue.main.async { if self.turnDone { self.answering = false } }
                return
            }
            // Buffers still queued: a completion handler normally brings us
            // back — but a player stopped by an interruption / rebuild while
            // the app was in the background may never fire them, and the
            // button would blink "talking" forever. Re-check until drained.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.answering, self.turnDone else { return }
                self.settleTicks += 1
                if self.settleTicks > 12 {   // 12 s past the turn: nothing is playing
                    AudioGraph.q.async { self.queuedBuffers = 0 }
                    self.answering = false
                    Self.beacon("answering-forced-off")
                    return
                }
                self.settleAnswering()
            }
        }
    }
    private var settleTicks = 0

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
                self.queuedBuffers = 0   // a stopped player holds nothing
                if self.engine.isRunning { self.player.play() }
            }
            DispatchQueue.main.async { self.settleAnswering() }
        }
    }

}
