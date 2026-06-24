import SwiftUI

/// The Tamagotchi home screen. A pixel pet that idles, shows moods, and reacts
/// to taps; you Feed/Rest it (scripted) and tap "Talk" to open the gadk voice
/// assistant (its brain). Screen+voice recording to screenpipe lives in Settings.
struct PetView: View {
    @StateObject private var pet = PetEngine()
    @State private var showVoice = false
    @State private var showSettings = false
    @State private var bob = false

    private let voiceURL = URL(string: "https://gadk.kaxtus.com/voice")!

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(.systemIndigo).opacity(0.20), Color(.systemBackground)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                header

                Spacer(minLength: 0)

                // Pet + reaction
                ZStack {
                    PixelPet(mood: pet.mood)
                        .frame(width: 220, height: 220)
                        .offset(y: bob ? -10 : 0)
                        .animation(.easeInOut(duration: pet.mood == .sleepy ? 2.2 : 0.9)
                                    .repeatForever(autoreverses: true), value: bob)
                        .onTapGesture { pet.pet() }

                    if let r = pet.reaction {
                        Text(r).font(.system(size: 44))
                            .offset(y: -120)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: pet.reaction)

                Text(pet.mood.label)
                    .font(.system(.title2, design: .rounded)).bold()
                    .foregroundStyle(.primary)

                stats

                Spacer(minLength: 0)

                controls
            }
            .padding()
        }
        .onAppear { bob = true }
        .sheet(isPresented: $showVoice, onDismiss: { pet.talked() }) {
            VoiceView(url: voiceURL)
        }
        .sheet(isPresented: $showSettings) { ContentView() }
    }

    private var header: some View {
        HStack {
            Text("AI Buddy")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stats: some View {
        VStack(spacing: 8) {
            StatBar(icon: "heart.fill", tint: .pink, value: pet.happiness)
            StatBar(icon: "bolt.fill", tint: .yellow, value: pet.energy)
            StatBar(icon: "fork.knife", tint: .orange, value: pet.fullness)
        }
        .frame(maxWidth: 280)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Button { showVoice = true } label: {
                Label("Talk to me", systemImage: "mic.fill")
                    .font(.system(.headline, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)

            HStack(spacing: 12) {
                ActionButton(title: "Feed", icon: "fork.knife") { pet.feed() }
                ActionButton(title: "Rest", icon: "moon.zzz.fill") { pet.rest() }
            }
        }
        .frame(maxWidth: 360)
    }
}

private struct StatBar: View {
    let icon: String; let tint: Color; let value: Double
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 22)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint)
                        .frame(width: max(6, geo.size.width * value))
                }
            }
            .frame(height: 10)
        }
    }
}

private struct ActionButton: View {
    let title: String; let icon: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(.subheadline, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .tint(.secondary)
    }
}

// MARK: - The pixel creature

/// A small procedurally-drawn pixel pet. The body is an ellipse rasterised onto
/// a 16×16 grid; ears/eyes/mouth/cheeks are placed per cell and vary by mood.
struct PixelPet: View {
    let mood: PetMood
    private let n = 16

    var body: some View {
        Canvas { ctx, size in
            let cell = min(size.width, size.height) / Double(n)
            func fill(_ c: Int, _ r: Int, _ color: Color) {
                guard c >= 0, r >= 0, c < n, r < n else { return }
                let rect = CGRect(x: Double(c) * cell, y: Double(r) * cell,
                                  width: cell + 0.6, height: cell + 0.6)
                ctx.fill(Path(rect), with: .color(color))
            }

            // ----- body cells (ellipse) + ears -----
            var cells = Set<[Int]>()
            for r in 0..<n {
                for c in 0..<n {
                    let dx = (Double(c) + 0.5 - 8.0) / 6.3
                    let dy = (Double(r) + 0.5 - 8.8) / 6.0
                    if dx * dx + dy * dy <= 1 { cells.insert([c, r]) }
                }
            }
            let ears: [[Int]] = [[4,1],[3,2],[4,2],[5,2], [11,1],[12,2],[11,2],[10,2]]
            ears.forEach { cells.insert($0) }

            // ----- draw body + outline -----
            for cell0 in cells {
                let c = cell0[0], r = cell0[1]
                let edge = [[c-1,r],[c+1,r],[c,r-1],[c,r+1]].contains { !cells.contains($0) }
                fill(c, r, edge ? Self.outline : bodyColor)
            }
            // inner ear pink
            [[4,2],[11,2]].forEach { fill($0[0], $0[1], Self.pink) }

            // ----- face per mood -----
            switch mood {
            case .happy:
                // ^  ^ happy eyes
                fill(5,7,Self.dark); fill(6,8,Self.dark)
                fill(10,7,Self.dark); fill(9,8,Self.dark)
                // smile
                fill(6,11,Self.dark); fill(7,12,Self.dark); fill(8,12,Self.dark); fill(9,11,Self.dark)
                // cheeks
                fill(4,10,Self.pink); fill(11,10,Self.pink)
            case .neutral:
                openEye(5, fill); openEye(9, fill)
                fill(7,12,Self.dark); fill(8,12,Self.dark)
            case .bored:
                // half-lidded flat eyes
                fill(5,8,Self.dark); fill(6,8,Self.dark)
                fill(9,8,Self.dark); fill(10,8,Self.dark)
                // flat mouth
                fill(6,12,Self.dark); fill(7,12,Self.dark); fill(8,12,Self.dark); fill(9,12,Self.dark)
            case .hungry:
                openEye(5, fill); openEye(9, fill)
                // little 'o' mouth
                fill(7,11,Self.dark); fill(8,11,Self.dark); fill(7,12,Self.dark); fill(8,12,Self.dark)
                // sweat drop
                fill(12,7,Self.sweat); fill(12,8,Self.sweat)
            case .sleepy:
                // closed eyes
                fill(5,8,Self.dark); fill(6,8,Self.dark)
                fill(9,8,Self.dark); fill(10,8,Self.dark)
                fill(7,12,Self.dark)
                // zzz
                fill(13,4,Self.dark); fill(14,4,Self.dark); fill(14,5,Self.dark); fill(13,6,Self.dark); fill(14,6,Self.dark)
            }
        }
    }

    private func openEye(_ col: Int, _ fill: (Int, Int, Color) -> Void) {
        fill(col, 7, Self.dark); fill(col + 1, 7, Self.dark)
        fill(col, 8, Self.dark); fill(col + 1, 8, Self.dark)
        fill(col, 7, Self.dark); fill(col + 1, 7, Self.white)   // highlight
    }

    private var bodyColor: Color {
        switch mood {
        case .happy:   return Color(red: 0.55, green: 0.82, blue: 0.45)
        case .neutral: return Color(red: 0.40, green: 0.75, blue: 0.78)
        case .bored:   return Color(red: 0.56, green: 0.60, blue: 0.70)
        case .hungry:  return Color(red: 0.93, green: 0.66, blue: 0.34)
        case .sleepy:  return Color(red: 0.62, green: 0.56, blue: 0.82)
        }
    }

    private static let outline = Color(red: 0.16, green: 0.17, blue: 0.24)
    private static let dark = Color(red: 0.12, green: 0.12, blue: 0.16)
    private static let white = Color.white
    private static let pink = Color(red: 0.98, green: 0.62, blue: 0.66)
    private static let sweat = Color(red: 0.45, green: 0.78, blue: 0.98)
}

#Preview { PetView() }
