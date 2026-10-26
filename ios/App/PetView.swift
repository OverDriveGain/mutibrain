import SwiftUI
import UIKit

/// Home screen — the mymu-voice swarm/critter (rendered by the server's embed
/// page in a webview) with the native gadk voice underneath, and since
/// 2026-10-24 the brain's MyMu conversation as a DRAWER under it (see
/// ChatDrawer.swift for the three states and why). "Talk to me" runs gadk
/// (GadkVoice, native audio); the swarm reacts to both voices; the hand-off
/// chips inside the embed keep showing what the brain is doing.
/// The old pixel-art pet room this replaces lives on in PixelKit/PetEngine.
@MainActor
struct PetView: View {
    @StateObject private var voice = GadkVoice()
    @StateObject private var critter = CritterController()
    // The brain's chat = the vendored MyMu client. Its account and roster
    // live HERE (not in the drawer) so the closed drawer's peek row knows the
    // agent's name and state, and a drag-open shows a conversation at once.
    @StateObject private var mymu = AppState()
    @StateObject private var roster = ProjectsStore()
    @AppStorage("chatURL", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var chatURL: String = SharedConfig.defaultChat
    @AppStorage("mymuHost", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var mymuHost: String = "https://code.kaxtus.com"
    @AppStorage("mymuAgent", store: UserDefaults(suiteName: SharedConfig.appGroup))
    private var mymuAgent: String = "special-agent"

    @State private var showSettings = false
    /// Opened by the web "Screen" massam via the mymuBroadcast bridge — shows the
    /// native screen-capture sheet (standard broadcast picker + mic) right there.
    @State private var showScreenpipe = false
    /// Swap the full-bleed background between the critter and the shared Spot
    /// garden. Voice stays live in both, so you can say "walk to Zohreh" from
    /// the garden and watch it happen.
    @State private var showSpot = false

    // ---- the drawer ----
    @State private var detent: DrawerDetent = .closed
    /// Live drag delta (points, + = up) on top of the resting height.
    @State private var dragDelta: CGFloat = 0
    @State private var dragging = false
    /// Height of the tab's safe area — the drawer's world (shrinks with the keyboard).
    @State private var container: CGFloat = 0
    @State private var hintFetched = false

    private var metrics: DrawerMetrics { DrawerMetrics(container: container) }

    init() {
        #if DEBUG
        // Screenshot/QA hook: launch with MYAGENT_DRAWER=closed|half|full
        // (simulator: SIMCTL_CHILD_MYAGENT_DRAWER=half xcrun simctl launch …)
        // to open on a given drawer state without a touch driver.
        if let d = ProcessInfo.processInfo.environment["MYAGENT_DRAWER"] {
            _detent = State(initialValue: d == "full" ? .full : (d == "half" ? .half : .closed))
        }
        #endif
    }

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

    private var gadkOrigin: URL {
        let url = SharedConfig.load().gadkURL
        var c = URLComponents()
        c.scheme = url.scheme ?? "https"
        c.host = url.host
        c.port = url.port
        return c.url ?? url
    }

    var body: some View {
        scene
            .toolbar(detent == .closed ? .visible : .hidden, for: .tabBar)
            .environmentObject(mymu)
            .environmentObject(roster)
            .modifier(VoiceWiring(voice: voice, critter: critter, critterState: critterState))
            .modifier(MassamWiring(showScreenpipe: $showScreenpipe))
            .onAppear {
                GadkVoice.beacon("app-launched")
                let t = GadkVoice.feedTarget()
                critter.startFeeds(origin: t.origin, app: t.app, token: t.token)
                critter.setStage(shift: 0, scale: 1, inset: DrawerMetrics.peek, dragging: false)
            }
            .onDisappear { critter.stopFeeds() }
            .animation(.easeInOut(duration: 0.2), value: voice.caption)
            // ---- MyMu access: which host/agent (from /config), then the roster ----
            .task(id: chatURL + "|" + mymuHost + "|" + mymuAgent) {
                if !hintFetched {
                    hintFetched = true
                    await MyMuHint.fetch { h, a in mymuHost = h; mymuAgent = a }
                }
                await BrainAccess.load(mymu, roster, chatURL: chatURL)
            }
            .onChange(of: mymu.accountEpoch) { _ in
                Task { await BrainAccess.load(mymu, roster, chatURL: chatURL) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .mymuUnauthorized)) { note in
                // A rejected MyMu token: the client probes once more before it
                // ends the session (reauthNeeded) — the drawer then shows the sign-in.
                guard let origin = note.userInfo?["origin"] as? String else { return }
                mymu.handleUnauthorized(origin: origin)
            }
            // Writing needs the room: the keyboard lifts a half drawer to full.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                if detent == .half { snap(.full, metrics) }
            }
            .sheet(isPresented: $showSettings) {
                ContentView(mymuUser: mymu.user?.username,
                            onMyMuSignOut: { mymu.logout(); roster.projects = [] })
            }
    }

    /// The stage (swarm), the seam (mic), and the drawer, laid out in the
    /// tab's safe area — the drawer's world.
    private var scene: some View {
        GeometryReader { geo in
            let m = DrawerMetrics(container: geo.size.height)
            let h = m.clamp(m.height(detent) + dragDelta)
            ZStack(alignment: .bottom) {
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
                }
                .padding(.horizontal, 18)

                drawer(h: h, m: m)
                seam(h: h, m: m, width: geo.size.width)
            }
            .coordinateSpace(name: drawerWorld)
            .onChange(of: h) { stage(height: $0, m, dragging: dragging) }
            .onAppear {
                container = geo.size.height
                stage(height: m.height(detent), m, dragging: false)
            }
            .onChange(of: geo.size.height) { container = $0 }
        }
    }

    /// The conversation drawer. Closed = the peek line (the brain's name +
    /// state), open = MyMu's chat. The tab bar leaves while it is open (a
    /// conversation is full-screen content).
    private func drawer(h: CGFloat, m: DrawerMetrics) -> some View {
        ChatDrawer(height: m.height(detent),
                   top: m.full - m.height(detent),
                   lift: h - m.height(detent),
                   handleZone: detent == .closed ? .infinity : 64,
                   onDrag: { d in drag(d, m) },
                   onRelease: { d, coast in release(d, coast, m) }) {
            if detent != .closed {
                // Equatable: a drag re-renders PetView ~120×/s; the conversation
                // must not re-evaluate with it.
                EquatableView(content: DrawerChat(chatURL: chatURL, host: mymuHost,
                                                  agentName: mymuAgent,
                                                  full: detent == .full,
                                                  onVoice: { backToVoice(m) }))
                    .transition(.opacity)
            } else {
                BrainPeek(agentName: mymuAgent, chatURL: chatURL)
                    .contentShape(Rectangle())
                    .onTapGesture { snap(.half, m) }
            }
        }
    }

    /// The mic (and any failure line) ride the SEAM: centred under the swarm
    /// while closed; as the drawer rises it glides to the LEFT corner of the
    /// seam (the drawer's grabber stays free in the middle) and at full height
    /// it hands over to the waveform button in the same corner of the nav bar.
    private func seam(h: CGFloat, m: DrawerMetrics, width: CGFloat) -> some View {
        let resting = detent == .closed && !dragging
        let p = min(1, max(0, (h - m.closed) / max(1, m.half - m.closed)))
        return VStack(spacing: 8) {
            if !statusLine.isEmpty {
                Text(statusLine)
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundStyle(.red.opacity(0.85))
                    .transition(.opacity)
            }
            TalkButton(active: voice.active, answering: voice.answering,
                       onSeam: !resting) { voice.toggle() }
        }
        // Positioned with an OFFSET, not padding: padding would grow the
        // ZStack past the container at full height and push the whole scene
        // (drawer included) 54pt off the bottom.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .offset(x: -p * (width / 2 - 58), y: -(resting ? m.closed + 12 : h - 42))
        .opacity(detent == .full && !dragging ? 0 : 1)
        .allowsHitTesting(!(detent == .full && !dragging))
    }

    // MARK: - drawer mechanics

    private func drag(_ delta: CGFloat, _ m: DrawerMetrics) {
        if !dragging { dragging = true }
        dragDelta = delta
    }

    private func release(_ delta: CGFloat, _ coast: CGFloat, _ m: DrawerMetrics) {
        let h = m.clamp(m.height(detent) + delta)
        snap(m.nearest(to: h + coast * 0.6), m)
    }

    private func snap(_ target: DrawerDetent, _ m: DrawerMetrics) {
        let changed = target != detent
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            detent = target
            dragDelta = 0
            dragging = false
        }
        // the embed animates its own CSS transition to the resting stage
        stage(height: m.height(target), m, dragging: false)
        if changed {
            Haptics.send()
            GadkVoice.beacon("drawer-\(target)")
        }
    }

    /// From the full conversation back to talking: the drawer drops to half
    /// (the swarm comes back above it) and the voice session starts if it
    /// isn't running — one tap from writing to speaking.
    private func backToVoice(_ m: DrawerMetrics) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        snap(.half, m)
        if !voice.active { voice.toggle() }
    }

    /// Re-compose the stage: the swarm shifts up by half the drawer's rise and
    /// shrinks towards 78% as the drawer reaches half height, so it re-centres
    /// in the space it has left.
    private func stage(height h: CGFloat, _ m: DrawerMetrics, dragging: Bool) {
        let rise = max(0, h - m.closed)
        let p = min(1, rise / max(1, m.half - m.closed))
        critter.setStage(shift: rise / 2, scale: 1 - 0.22 * p, inset: DrawerMetrics.peek, dragging: dragging)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text(showSpot ? "SPOT" : AppBuild.header)
                .font(.pixel(13)).foregroundStyle(.white.opacity(0.85))
            Spacer()
            // Spot (garden / TEAMWORK) toggle — HIDDEN 2026-07-28 (Manar: not
            // needed now, but KEEP for teams work). SpotView + showSpot stay
            // wired; un-comment this button to bring it back.
            // Button { withAnimation(.easeInOut(duration: 0.25)) { showSpot.toggle() } } label: {
            //     Image(systemName: showSpot ? "person.fill" : "tree.fill")
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

// MARK: - wiring

/// The drawer's MyMu conversation, compared by its inputs only (the closure is
/// rebuilt every render but always does the same thing).
private struct DrawerChat: View, Equatable {
    let chatURL: String
    let host: String
    let agentName: String
    let full: Bool
    let onVoice: () -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.chatURL == b.chatURL && a.host == b.host && a.agentName == b.agentName && a.full == b.full
    }

    var body: some View {
        BrainChatRoot(chatURL: chatURL, host: host, agentName: agentName,
                      showVoiceButton: full, onVoice: onVoice)
    }
}

/// Voice → avatar: state, levels, moves, hand-off chips. Split out of PetView's
/// body so the type-checker has a chain it can finish.
private struct VoiceWiring: ViewModifier {
    @ObservedObject var voice: GadkVoice
    let critter: CritterController
    let critterState: String

    func body(content: Content) -> some View {
        content
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
    }
}

/// Web massams → native: the screen-capture sheet, the music player.
private struct MassamWiring: ViewModifier {
    @Binding var showScreenpipe: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showScreenpipe) {
                NavigationView { ScreenpipeView() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .mymuShowScreenpipe)) { _ in
                showScreenpipe = true
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
}

// MARK: - Talk button

/// Circular mic button. Background-less under the swarm (Manar 2026-07-27:
/// just the symbol, a faint expanding ring is the only "live" cue); ON THE
/// SEAM (drawer open) it gets a dark glass disc so it reads over both the
/// swarm and the drawer's edge.
private struct TalkButton: View {
    let active: Bool
    let answering: Bool
    let onSeam: Bool
    let action: () -> Void
    @State private var pulsing = false

    private var glow: Color {
        active ? Color(red: 1.0, green: 0.3, blue: 0.4) : Color(red: 0.5, green: 0.35, blue: 1.0)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if onSeam {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
                        .frame(width: 60, height: 60)
                        .shadow(color: .black.opacity(0.5), radius: 10, y: 3)
                }
                if active {
                    Circle()
                        .stroke(glow.opacity(0.35), lineWidth: 2)
                        .frame(width: 64, height: 64)
                        .scaleEffect(pulsing ? 1.45 : 1.0)
                        .opacity(pulsing ? 0 : 0.7)
                }
                Image(systemName: active ? "stop.fill" : "mic.fill")
                    .font(.system(size: onSeam ? 26 : 34, weight: .semibold))
                    .foregroundStyle(active ? Color(red: 1.0, green: 0.45, blue: 0.45)
                                            : .white.opacity(0.85))
                    .shadow(color: .black.opacity(0.6), radius: 6)
                    .opacity(answering ? 0.75 : 1)
                    .animation(answering
                               ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
                               : .default, value: answering)
            }
            .frame(width: 96, height: 96)   // hit target
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("talk-button")
        .onChange(of: active) { isOn in
            pulsing = false
            guard isOn else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}

#Preview { PetView() }
