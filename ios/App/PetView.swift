import SwiftUI

/// The Tamagotchi home screen — pixel pet living in a little room. Tap the pet to
/// play; Feed/Rest care for it; "Talk to me" runs gadk inline (the pet's brain)
/// and a speech bubble shows what it says. Screen+voice recording lives in Settings.
struct PetView: View {
    @StateObject private var pet = PetEngine()
    @StateObject private var voice = VoiceState()
    @State private var showSettings = false
    @State private var bob = false

    private var displayMood: PetMood { voice.active ? .happy : pet.mood }

    var body: some View {
        ZStack {
            RoomBackground().ignoresSafeArea()

            VStack(spacing: 16) {
                header

                Spacer(minLength: 4)

                if voice.active && !voice.caption.isEmpty {
                    SpeechBubble(text: voice.caption)
                        .transition(.scale.combined(with: .opacity))
                }

                // pet + ground shadow + reaction
                ZStack {
                    Ellipse().fill(PX.ink.opacity(0.18))
                        .frame(width: 150, height: 26).offset(y: 116)
                    PixelPet(mood: displayMood, lively: voice.answering)
                        .frame(width: 230, height: 230)
                        .offset(y: bob ? -10 : 0)
                        .animation(.easeInOut(duration: displayMood == .sleepy ? 2.4 : (voice.answering ? 0.45 : 1.0))
                                    .repeatForever(autoreverses: true), value: bob)
                        .onTapGesture { pet.pet() }
                    if let r = pet.reaction {
                        Text(r).font(.system(size: 40)).offset(y: -130)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: pet.reaction)

                Text((voice.active ? (voice.answering ? "TALKING" : "LISTENING") : displayMood.label).uppercased())
                    .font(.pixel(13)).foregroundStyle(PX.ink)
                    .padding(.top, 4)

                Spacer(minLength: 4)

                PixelPanel {
                    VStack(spacing: 9) {
                        PixelStatBar(icon: "heart.fill", tint: PX.heart, value: pet.happiness)
                        PixelStatBar(icon: "bolt.fill", tint: PX.bolt, value: pet.energy)
                        PixelStatBar(icon: "fork.knife", tint: PX.food, value: pet.fullness)
                    }
                }
                .frame(maxWidth: 320)

                controls
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
        .onAppear { bob = true }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: voice.active)
        .animation(.easeInOut(duration: 0.2), value: voice.caption)
        .onChange(of: voice.active) { isActive in if !isActive { pet.talked() } }
        .sheet(isPresented: $showSettings) { ContentView() }
    }

    private var header: some View {
        HStack {
            Text("AI BUDDY").font(.pixel(13)).foregroundStyle(PX.ink)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(PX.ink.opacity(0.8))
            }
        }
        .padding(.top, 4)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            VoiceBridge(url: SharedConfig.load().gadkURL, state: voice)
                .frame(height: 60)
                .overlay(Rectangle().stroke(PX.ink, lineWidth: 3))   // pixel frame
            HStack(spacing: 10) {
                PixelButton(title: "FEED", icon: "fork.knife", fill: PX.cream) { pet.feed() }
                PixelButton(title: "REST", icon: "moon.zzz.fill", fill: PX.cream) { pet.rest() }
            }
        }
        .frame(maxWidth: 360)
    }
}

// MARK: - Room

private struct RoomBackground: View {
    var body: some View {
        GeometryReader { geo in
            let floorY = geo.size.height * 0.66
            ZStack(alignment: .topLeading) {
                Rectangle().fill(PX.wall)                                  // wall
                // window (top corner, behind the pet)
                ZStack {
                    Rectangle().fill(PX.ink).frame(width: 92, height: 92)
                    Rectangle().fill(Color(hex: 0xBFE3FF)).frame(width: 80, height: 80)
                    Rectangle().fill(PX.ink).frame(width: 5, height: 80)
                    Rectangle().fill(PX.ink).frame(width: 80, height: 5)
                }
                .position(x: geo.size.width * 0.80, y: geo.size.height * 0.17)
                // floor
                Rectangle().fill(PX.floor)
                    .frame(height: geo.size.height - floorY)
                    .offset(y: floorY)
                // baseboard
                Rectangle().fill(PX.ink).frame(height: 4).offset(y: floorY - 2)
                // floor planks
                ForEach(1..<5) { i in
                    Rectangle().fill(PX.floorDk.opacity(0.6)).frame(height: 2)
                        .offset(y: floorY + CGFloat(i) * (geo.size.height - floorY) / 5)
                }
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

// MARK: - The pixel creature (procedural, shaded, expressive)

struct PixelPet: View {
    let mood: PetMood
    var lively: Bool = false
    private let n = 32

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let blink = t.truncatingRemainder(dividingBy: 3.4) < 0.13
            Canvas { ctx, size in draw(into: ctx, size: size, blink: blink) }
        }
    }

    private func draw(into ctx: GraphicsContext, size: CGSize, blink: Bool) {
        let cell = min(size.width, size.height) / Double(n)
        func f(_ c: Int, _ r: Int, _ color: Color) {
            guard c >= 0, r >= 0, c < n, r < n else { return }
            ctx.fill(Path(CGRect(x: Double(c) * cell, y: Double(r) * cell,
                                 width: cell + 0.6, height: cell + 0.6)), with: .color(color))
        }

        let base = bodyColor, hi = base.lighter, sh = base.darker

        // ---- silhouette: body blob + ears + feet ----
        let cx = 16.0, cy = 17.6, rx = 11.0, ry = 10.6, p = 2.4
        func inBody(_ c: Int, _ r: Int) -> Bool {
            let dx = (Double(c) + 0.5 - cx) / rx, dy = (Double(r) + 0.5 - cy) / ry
            return pow(abs(dx), p) + pow(abs(dy), p) <= 1
        }
        func inEar(_ c: Int, _ r: Int, _ center: Double) -> Bool {
            guard r >= 2, r <= 9 else { return false }
            let half = Double(r - 2) * 0.85
            return Double(c) >= center - half && Double(c) <= center + half
        }
        func inFoot(_ c: Int, _ r: Int, _ fx: Double) -> Bool {
            let dx = (Double(c) + 0.5 - fx) / 3.0, dy = (Double(r) + 0.5 - 28.0) / 2.4
            return dx * dx + dy * dy <= 1
        }
        var solid = Set<[Int]>()
        for r in 0..<n { for c in 0..<n {
            if inBody(c, r) || inEar(c, r, 9.5) || inEar(c, r, 22.5)
                || inFoot(c, r, 11.0) || inFoot(c, r, 21.0) { solid.insert([c, r]) }
        }}

        // ---- shade body ----
        for cellp in solid {
            let c = cellp[0], r = cellp[1]
            let edge = [[c-1,r],[c+1,r],[c,r-1],[c,r+1]].contains { !solid.contains($0) }
            if edge { f(c, r, PX.ink); continue }
            let light = -(((Double(c) - cx) / rx) + ((Double(r) - cy) / ry))
            if light > 0.62 { f(c, r, hi) }
            else if light < -0.7 { f(c, r, sh) }
            else { f(c, r, base) }
        }
        // top-left sparkle highlight
        [[10,9],[11,9],[10,10]].forEach { f($0[0], $0[1], hi.lighter) }
        // inner ears (blush)
        [[9,7],[10,7],[9,8], [22,7],[23,7],[23,8]].forEach { f($0[0], $0[1], PX.blush) }

        // ---- face ----
        let cheeks = (mood == .happy || mood == .neutral)
        if cheeks { [[9,20],[8,20], [23,20],[24,20]].forEach { f($0[0], $0[1], PX.blush) } }

        if blink && mood != .sleepy {
            closedEye(11, f); closedEye(20, f)
        } else {
            switch mood {
            case .happy:   smileEye(11, f); smileEye(20, f)
            case .neutral, .hungry: openEye(10, f); openEye(19, f)
            case .bored:   sleepyLid(11, f); sleepyLid(20, f)
            case .sleepy:  closedEye(11, f); closedEye(20, f)
            }
        }

        // mouth
        switch mood {
        case .happy:
            f(14,22,PX.ink); f(15,23,PX.ink); f(16,23,PX.ink); f(17,23,PX.ink); f(18,22,PX.ink)
        case .neutral:
            f(15,22,PX.ink); f(16,23,PX.ink); f(17,22,PX.ink)            // :3 cat mouth
        case .bored:
            f(14,23,PX.ink); f(15,23,PX.ink); f(16,23,PX.ink); f(17,23,PX.ink)
        case .hungry:
            f(15,22,PX.ink); f(16,22,PX.ink); f(17,22,PX.ink)
            f(15,23,PX.heart); f(16,23,PX.heart); f(17,23,PX.heart)      // open / tongue
            f(24,15,Color(hex: 0x7FC7FF)); f(24,16,Color(hex: 0x7FC7FF)) // sweat
        case .sleepy:
            f(16,23,PX.ink)
            // zzz
            [[26,5],[27,5],[27,6],[26,7],[27,7]].forEach { f($0[0], $0[1], PX.ink) }
        }
    }

    // eye styles (center column of a ~3-wide eye)
    private func openEye(_ c: Int, _ f: (Int, Int, Color) -> Void) {
        for x in c...(c+2) { for y in 15...18 { f(x, y, PX.white) } }
        for x in c...(c+2) { f(x, 15, PX.ink) }                 // top lid
        f(c+1, 17, PX.ink); f(c+2, 17, PX.ink); f(c+1, 18, PX.ink); f(c+2, 18, PX.ink) // pupil
        f(c, 16, PX.white)                                       // shine
    }
    private func smileEye(_ c: Int, _ f: (Int, Int, Color) -> Void) {
        f(c, 17, PX.ink); f(c+1, 16, PX.ink); f(c+2, 17, PX.ink)   // ∪ happy
    }
    private func sleepyLid(_ c: Int, _ f: (Int, Int, Color) -> Void) {
        f(c, 16, PX.ink); f(c+1, 16, PX.ink); f(c+2, 16, PX.ink)
        f(c+1, 17, PX.ink)
    }
    private func closedEye(_ c: Int, _ f: (Int, Int, Color) -> Void) {
        f(c, 17, PX.ink); f(c+1, 17, PX.ink); f(c+2, 17, PX.ink)
    }

    private var bodyColor: Color {
        switch mood {
        case .happy:   return Color(hex: 0x7BD66A)
        case .neutral: return Color(hex: 0x46C0C6)
        case .bored:   return Color(hex: 0x8A93BF)
        case .hungry:  return Color(hex: 0xEFA85A)
        case .sleepy:  return Color(hex: 0x9A86E0)
        }
    }
}

#Preview { PetView() }
