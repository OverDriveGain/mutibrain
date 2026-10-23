import SwiftUI

/// Home screen — the mymu-voice critter (SDF blend-shell character, rendered by
/// the server's embed page in a webview) with the native gadk voice underneath.
/// "Talk to me" runs gadk (GadkVoice, native audio); the critter turns to face
/// you and lip-bobs while the agent speaks; a bubble shows the words.
/// The old pixel-art pet room this replaces lives on in PixelKit/PetEngine.
struct PetView: View {
    @StateObject private var voice = GadkVoice()
    @StateObject private var critter = CritterController()
    @State private var showSettings = false
    /// Opened by the web "Screen" massam via the mymuBroadcast bridge — shows the
    /// native screen-capture sheet (standard broadcast picker + mic) right there.
    @State private var showScreenpipe = false
    /// Swap the full-bleed background between the critter and the shared Spot
    /// garden. Voice stays live in both, so you can say "walk to Zohreh" from
    /// the garden and watch it happen.
    @State private var showSpot = false
    /// The embed's keyboard composer is open (mymuCompose bridge): the big
    /// native mic gets out of the way of the conversation (Manar 2026-10-23:
    /// "when I chat with the agent there is a big microphone on the screen").
    @State private var composing = false

    private var critterState: String {
        guard voice.active else { return "idle" }
        if voice.answering { return "talking" }
        // while connecting the avatar shows loading progress (the swarm
        // gathers in stages); "" = truly ready -> listening
        return voice.connectStage.isEmpty ? "listening" : voice.connectStage
    }

    /// Routine status chatter ("Listening…", "Talking…", "Tap to talk", the
    /// connect stages and ⚙️ tool lines) was REMOVED by request (2026-07-28):
    /// the equalizer + avatar ARE the feedback now, so the text on top just
    /// felt like noise. ONLY genuine failures (✗ …) still surface, so sudden
    /// dead air is always explained.
    private var statusLine: String {
        voice.stageText.hasPrefix("✗") ? voice.stageText : ""
    }

    private var statusColor: Color {
        if voice.stageText.hasPrefix("✗") { return .red.opacity(0.85) }
        if !voice.stageText.isEmpty { return .white.opacity(0.85) }
        return .white.opacity(0.6)
    }

    private var gadkOrigin: URL {
        let url = SharedConfig.load().gadkURL
        var c = URLComponents()
        c.scheme = url.scheme ?? "https"
        c.host = url.host
        c.port = url.port
        return c.url ?? url
    }

    var body: some View {
        ZStack {
            if showSpot {
                SpotView(origin: gadkOrigin)
                    .ignoresSafeArea()
            } else {
                CritterView(controller: critter, origin: gadkOrigin)
                    .ignoresSafeArea()
            }

            VStack(spacing: 14) {
                header

                // What she's saying — quiet words at the top, never covering
                // the avatar (was a big center-screen speech bubble).
                if voice.active && !voice.caption.isEmpty {
                    Text(voice.caption)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }

                Spacer()

                // Old dots equalizer (MicMeter) REMOVED 2026-07-28 (Manar): the
                // reacting swarm IS the equalizer now — no redundant native bars.

                if !statusLine.isEmpty {
                    Text(statusLine)
                        .font(.system(.footnote, design: .rounded).weight(.medium))
                        .foregroundStyle(statusColor)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.15), value: voice.stageText)
                }

                if !composing {
                    TalkButton(active: voice.active, answering: voice.answering) { voice.toggle() }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
        .onAppear {
            GadkVoice.beacon("app-launched")
            let t = GadkVoice.feedTarget()
            critter.startFeeds(origin: t.origin, app: t.app, token: t.token)
        }
        .onDisappear { critter.stopFeeds() }
        .onChange(of: voice.active) { on in
            critter.setState(critterState)
            if !on { critter.setLevel(0) }
        }
        .onChange(of: voice.answering) { _ in critter.setState(critterState) }
        .onChange(of: voice.connectStage) { _ in critter.setState(critterState) }
        .onChange(of: voice.micLevel) { lvl in
            if voice.active && !voice.answering { critter.setLevel(lvl) }
        }
        .onChange(of: voice.outLevel) { lvl in
            if voice.answering { critter.setLevel(lvl) }
        }
        .onChange(of: voice.brainDispatched) { _ in
            // give the tool a beat to register in the ledger, then show the chip
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { critter.refreshPending() }
        }
        .onChange(of: voice.moveRequest) { mv in
            guard let mv, !mv.isEmpty else { return }
            critter.perform(mv, duration: voice.moveDuration)
            voice.moveRequest = nil        // re-arm for repeated identical moves
            voice.moveDuration = nil
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: voice.active)
        .animation(.easeInOut(duration: 0.2), value: voice.caption)
        .sheet(isPresented: $showSettings) { ContentView() }
        .sheet(isPresented: $showScreenpipe) {
            NavigationView { ScreenpipeView() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mymuShowScreenpipe)) { _ in
            showScreenpipe = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .mymuComposing)) { n in
            let open = n.userInfo?["open"] as? Bool ?? false
            withAnimation(.easeInOut(duration: 0.2)) { composing = open }
            GadkVoice.beacon(open ? "compose-open" : "compose-close")
        }
        .onReceive(NotificationCenter.default.publisher(for: .mymuPlaySongs)) { n in
            // The Music massam tapped a song/album/playlist: the native player
            // takes the queue. During a live conversation the music ducks under
            // it (like keep_listening); otherwise it just plays.
            guard let raw = n.userInfo?["songs"] as? [[String: Any]],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let songs = try? JSONDecoder().decode([Song].self, from: data), !songs.isEmpty
            else { return }
            let startAt = n.userInfo?["startAt"] as? Int ?? 0
            GadkVoice.beacon("massam-play-\(songs.count)")
            SubsonicPlayer.shared.play(songs, startAt: startAt)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mymuMusicControl)) { n in
            switch n.userInfo?["action"] as? String {
            case "pause": SubsonicPlayer.shared.pauseFromVoice()
            case "resume": SubsonicPlayer.shared.resumeFromVoice()
            case "next": SubsonicPlayer.shared.next()
            case "previous": SubsonicPlayer.shared.prev()
            default: break
            }
        }
        .onAppear {
            // Cold launch from the opener's "your screen isn't being recorded"
            // notification: the tap was handled before this view listened, so
            // PushNotifications left a flag — land on the capture sheet now.
            if UserDefaults.standard.bool(forKey: PushNotifications.pendingBroadcastKey) {
                UserDefaults.standard.removeObject(forKey: PushNotifications.pendingBroadcastKey)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showScreenpipe = true }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text(showSpot ? "SPOT" : AppBuild.header)
                .font(.pixel(13)).foregroundStyle(.white.opacity(0.85))
            Spacer()
            // Spot (garden / TEAMWORK) toggle — HIDDEN 2026-07-28 (Manar: not
            // needed now, but KEEP for teams work). SpotView + showSpot stay
            // wired below; un-comment this button to bring it back.
            // Button { withAnimation(.easeInOut(duration: 0.25)) { showSpot.toggle() } } label: {
            //     Image(systemName: showSpot ? "person.fill" : "tree.fill")
            //         .font(.title3)
            //         .foregroundStyle(showSpot ? Color(red: 0.62, green: 0.94, blue: 0.75)
            //                                   : .white.opacity(0.7))
            //         .frame(width: 44, height: 44)
            //         .contentShape(Rectangle())
            // }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)      // generous tap target
                    .contentShape(Rectangle())
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - Mic meter

/// Simple symmetric equalizer showing live mic loudness — the visible proof
/// the app hears you while the status line stays a plain "Listening…".
private struct MicMeter: View {
    let level: Float
    private static let mult: [CGFloat] = [0.30, 0.55, 0.80, 1.00, 0.80, 0.55, 0.30]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<Self.mult.count, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: 4, height: 4 + 24 * Self.mult[i] * CGFloat(level))
            }
        }
        .frame(height: 30)
        .animation(.linear(duration: 0.09), value: level)
    }
}

// MARK: - Talk button

/// Modern circular mic button: soft gradient + glow, expanding pulse ring while
/// the session is live, red stop state.
private struct TalkButton: View {
    let active: Bool
    let answering: Bool
    let action: () -> Void
    @State private var pulsing = false

    private var glow: Color {
        active ? Color(red: 1.0, green: 0.3, blue: 0.4) : Color(red: 0.5, green: 0.35, blue: 1.0)
    }

    var body: some View {
        // Background-less (Manar 2026-07-27): just the symbol, no filled
        // circle, no glow — a faint expanding ring is the only "live" cue.
        Button(action: action) {
            ZStack {
                if active {
                    Circle()
                        .stroke(glow.opacity(0.35), lineWidth: 2)
                        .frame(width: 64, height: 64)
                        .scaleEffect(pulsing ? 1.45 : 1.0)
                        .opacity(pulsing ? 0 : 0.7)
                }
                Image(systemName: active ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(active ? Color(red: 1.0, green: 0.45, blue: 0.45)
                                            : .white.opacity(0.85))
                    .shadow(color: .black.opacity(0.6), radius: 6)
                    .opacity(answering ? 0.75 : 1)
                    .animation(answering
                               ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
                               : .default, value: answering)
            }
            .frame(width: 136, height: 136)   // hit target — a bit bigger (Manar 2026-07-28)
        }
        .buttonStyle(.plain)
        .onChange(of: active) { isOn in
            pulsing = false
            guard isOn else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}

// MARK: - Speech bubble

private struct SpeechBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(.callout, design: .rounded)).bold()
            .foregroundStyle(PX.ink)
            .multilineTextAlignment(.center).lineLimit(4)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(
                ZStack {
                    Rectangle().fill(PX.ink)
                    Rectangle().fill(PX.white).padding(3)
                }
            )
            .overlay(alignment: .bottom) {
                Rectangle().fill(PX.white).frame(width: 16, height: 12)
                    .overlay(Rectangle().fill(PX.ink).frame(width: 16, height: 3), alignment: .bottom)
                    .offset(y: 11)
            }
            .frame(maxWidth: 300)
    }
}

#Preview { PetView() }
