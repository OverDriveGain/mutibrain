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

    private var critterState: String {
        voice.active ? (voice.answering ? "talking" : "listening") : "idle"
    }

    /// Connection-stage feedback wins while present (server up → Google up →
    /// heard you → tool activity); otherwise the plain state line. A ✗ failure
    /// line stays visible after stop so the user knows WHY it went quiet.
    private var statusLine: String {
        if !voice.stageText.isEmpty { return voice.stageText }
        return voice.active ? (voice.answering ? "Talking…" : "Listening…") : "Tap to talk"
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
            CritterView(controller: critter, origin: gadkOrigin)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                header

                Spacer()

                if voice.active && !voice.caption.isEmpty {
                    SpeechBubble(text: voice.caption)
                        .transition(.scale.combined(with: .opacity))
                }

                Text(statusLine)
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundStyle(statusColor)
                    .animation(.easeInOut(duration: 0.15), value: voice.stageText)

                TalkButton(active: voice.active, answering: voice.answering) { voice.toggle() }
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
        .onChange(of: voice.active) { _ in critter.setState(critterState) }
        .onChange(of: voice.answering) { _ in critter.setState(critterState) }
        .onChange(of: voice.brainDispatched) { _ in
            // give the tool a beat to register in the ledger, then show the chip
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { critter.refreshPending() }
        }
        .onChange(of: voice.moveRequest) { mv in
            guard let mv, !mv.isEmpty else { return }
            critter.perform(mv)
            voice.moveRequest = nil        // re-arm for repeated identical moves
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: voice.active)
        .animation(.easeInOut(duration: 0.2), value: voice.caption)
        .sheet(isPresented: $showSettings) { ContentView() }
    }

    private var header: some View {
        HStack {
            Text("AI BUDDY").font(.pixel(13)).foregroundStyle(.white.opacity(0.85))
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.top, 6)
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

    private var gradient: [Color] {
        active
            ? [Color(red: 1.00, green: 0.42, blue: 0.42), Color(red: 0.82, green: 0.11, blue: 0.34)]
            : [Color(red: 0.55, green: 0.45, blue: 1.00), Color(red: 0.33, green: 0.20, blue: 0.85)]
    }
    private var glow: Color {
        active ? Color(red: 1.0, green: 0.3, blue: 0.4) : Color(red: 0.5, green: 0.35, blue: 1.0)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if active {
                    Circle()
                        .stroke(glow.opacity(0.45), lineWidth: 3)
                        .frame(width: 76, height: 76)
                        .scaleEffect(pulsing ? 1.45 : 1.0)
                        .opacity(pulsing ? 0 : 0.9)
                }
                Circle()
                    .fill(LinearGradient(colors: gradient,
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 76, height: 76)
                    .overlay(
                        Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1)
                    )
                    .shadow(color: glow.opacity(0.55), radius: 20, y: 8)
                Image(systemName: active ? "stop.fill" : "mic.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(answering ? 0.75 : 1)
                    .animation(answering
                               ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
                               : .default, value: answering)
            }
            .frame(width: 110, height: 110)   // generous hit target
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
