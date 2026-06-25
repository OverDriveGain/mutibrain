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
            DustMotes().ignoresSafeArea().allowsHitTesting(false)
            Vignette().ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 16) {
                header

                Spacer(minLength: 4)

                if voice.active && !voice.caption.isEmpty {
                    SpeechBubble(text: voice.caption)
                        .transition(.scale.combined(with: .opacity))
                }

                // pet + rug + reaction
                ZStack {
                    Rug().frame(width: 178, height: 54).offset(y: 122)
                    Ellipse().fill(PX.ink.opacity(0.16))
                        .frame(width: 132, height: 20).offset(y: 116)
                    if displayMood == .happy { Sparkles() }
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
            let W = geo.size.width, H = geo.size.height
            let floorY = H * 0.66
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [PX.wall.lighter, PX.wall], startPoint: .top, endPoint: .bottom)
                // dado rail (darker lower wall band)
                Rectangle().fill(PX.wallDk).frame(height: 54).offset(y: floorY - 54)
                Rectangle().fill(PX.ink.opacity(0.4)).frame(height: 3).offset(y: floorY - 54)

                PixelWindow().frame(width: 96, height: 104).position(x: W * 0.79, y: H * 0.155)
                PictureFrame().frame(width: 58, height: 66).position(x: W * 0.20, y: H * 0.14)
                ShelfPlant().frame(width: 70, height: 56).position(x: W * 0.18, y: H * 0.40)

                // floor
                Rectangle().fill(PX.floor).frame(height: H - floorY).offset(y: floorY)
                Rectangle().fill(PX.ink).frame(height: 4).offset(y: floorY - 2)
                ForEach(1..<5) { i in
                    Rectangle().fill(PX.floorDk.opacity(0.5)).frame(height: 2)
                        .offset(y: floorY + CGFloat(i) * (H - floorY) / 5)
                }
                ForEach(0..<6) { i in
                    Rectangle().fill(PX.floorDk.opacity(0.35)).frame(width: 2, height: (H - floorY) / 2)
                        .offset(x: CGFloat(i) * W / 6 + (i.isMultiple(of: 2) ? 0 : W / 12), y: floorY)
                }
            }
        }
    }
}

private struct PixelWindow: View {
    var body: some View {
        ZStack {
            Rectangle().fill(PX.ink)
            ZStack {
                LinearGradient(colors: [Color(hex: 0xAEE0FF), Color(hex: 0xE3F4FF)],
                               startPoint: .top, endPoint: .bottom)
                Circle().fill(Color(hex: 0xFFD86B)).frame(width: 20, height: 20).offset(x: 20, y: -22)
                HStack(spacing: -7) {
                    Circle().fill(.white).frame(width: 14, height: 14)
                    Circle().fill(.white).frame(width: 20, height: 20)
                    Circle().fill(.white).frame(width: 14, height: 14)
                }.offset(x: -8, y: 16)
                Rectangle().fill(PX.ink).frame(width: 4)
                Rectangle().fill(PX.ink).frame(height: 4)
            }
            .padding(6).clipped()
        }
    }
}

private struct PictureFrame: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Color(hex: 0x8A6B4A))
            VStack(spacing: 0) {
                Color(hex: 0xBFE3FF)
                Color(hex: 0x86C66A).frame(height: 22)
            }
            .overlay(Circle().fill(Color(hex: 0xFFD86B)).frame(width: 12, height: 12).offset(x: -12, y: -10))
            .padding(6).clipped()
        }
    }
}

private struct ShelfPlant: View {
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: -8) {
                    Circle().fill(Color(hex: 0x5FA85A)).frame(width: 20, height: 22)
                    Circle().fill(Color(hex: 0x6FBE63)).frame(width: 26, height: 30).offset(y: -6)
                    Circle().fill(Color(hex: 0x5FA85A)).frame(width: 20, height: 22)
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color(hex: 0xC8744A)).frame(width: 30, height: 22)
                        .overlay(Rectangle().stroke(PX.ink, lineWidth: 2))
                }
            }
            Rectangle().fill(Color(hex: 0x9A7250)).frame(height: 7)
                .overlay(Rectangle().fill(PX.ink).frame(height: 2), alignment: .bottom)
        }
    }
}

private struct Rug: View {
    var body: some View {
        ZStack {
            Ellipse().fill(Color(hex: 0xD9694F))
            Ellipse().fill(Color(hex: 0xEC9079)).padding(7)
            Ellipse().fill(Color(hex: 0xD9694F)).padding(15)
            Ellipse().strokeBorder(PX.ink.opacity(0.45), lineWidth: 2)
        }
    }
}

private struct Sparkles: View {
    static let star = ["..o..", ".ooo.", "ooooo", ".ooo.", "..o.."]
    private let pal: [Character: Color] = ["o": Color(hex: 0xFFF1A8)]
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                twinkle(CGSize(width: -90, height: -80), t)
                twinkle(CGSize(width: 96, height: -44), t + 1.3)
                twinkle(CGSize(width: 74, height: 70), t + 2.1)
            }
        }
    }
    private func twinkle(_ o: CGSize, _ phase: Double) -> some View {
        let tw = (sin(phase * 2.2) + 1) / 2
        return PixelSprite(rows: Sparkles.star, palette: pal)
            .frame(width: 16, height: 16)
            .opacity(0.25 + 0.65 * tw)
            .scaleEffect(0.7 + 0.3 * tw)
            .offset(o)
    }
}

private struct DustMotes: View {
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for i in 0..<16 {
                    let s = Double(i)
                    let x = (sin(s * 12.9 + t * 0.04) * 0.5 + 0.5) * size.width
                    let y = (s / 16 * size.height + t * 7).truncatingRemainder(dividingBy: size.height)
                    let a = 0.05 + 0.06 * (sin(t * 0.5 + s) * 0.5 + 0.5)
                    ctx.fill(Path(CGRect(x: x, y: y, width: 3, height: 3)), with: .color(.white.opacity(a)))
                }
            }
        }
    }
}

private struct Vignette: View {
    var body: some View {
        RadialGradient(colors: [.clear, PX.ink.opacity(0.16)],
                       center: .center, startRadius: 180, endRadius: 540)
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
        // big round sclera (3 wide × 5 tall)
        for x in c...(c+2) { for y in 14...18 { f(x, y, PX.white) } }
        // pupil 2×3
        for x in (c+1)...(c+2) { for y in 15...17 { f(x, y, PX.ink) } }
        // glints
        f(c+1, 15, PX.white)                                     // big sparkle
        f(c+2, 17, PX.white)                                     // small sparkle
        // soft lower lid
        for x in c...(c+2) { f(x, 18, Color(hex: 0xCED4E8)) }
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
