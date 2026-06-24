import SwiftUI

// MARK: - Palette (cozy retro)

enum PX {
    static let ink      = Color(hex: 0x20223A)   // outline / text
    static let wall     = Color(hex: 0x8FA6E3)   // room wall
    static let wallDk   = Color(hex: 0x7A90D6)
    static let floor     = Color(hex: 0xE7C58C)  // room floor
    static let floorDk  = Color(hex: 0xD3A969)
    static let cream    = Color(hex: 0xFDF4DD)   // panel fill
    static let creamDk  = Color(hex: 0xE9D9B0)
    static let indigo   = Color(hex: 0x6A5CFF)
    static let indigoDk = Color(hex: 0x4E40D8)
    static let heart    = Color(hex: 0xFF4D6D)
    static let bolt     = Color(hex: 0xFFC83D)
    static let food     = Color(hex: 0xFF8A3D)
    static let blush    = Color(hex: 0xFF9BB0)
    static let white    = Color(hex: 0xFFFFFF)
}

extension Font {
    /// Press Start 2P (bundled). Falls back to a rounded system font if missing.
    static func pixel(_ size: CGFloat) -> Font {
        .custom("Press Start 2P", size: size)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
    func adjust(_ d: Double) -> Color {
        let u = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        u.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: max(0, min(1, s - d * 0.15)),
                     brightness: max(0, min(1, b + d)))
    }
    var lighter: Color { adjust(0.16) }
    var darker: Color { adjust(-0.16) }
}

// MARK: - Chunky pixel panel (hard corners + bevel)

struct PixelPanel<Content: View>: View {
    var fill: Color = PX.cream
    var border: Color = PX.ink
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(14)
            .background(
                ZStack {
                    Rectangle().fill(border)                       // outer outline
                    Rectangle().fill(fill).padding(3)              // inner fill
                    // bevel: light top/left, dark bottom/right
                    VStack(spacing: 0) {
                        Rectangle().fill(fill.lighter).frame(height: 3)
                        Spacer()
                        Rectangle().fill(fill.darker).frame(height: 3)
                    }.padding(3)
                }
            )
    }
}

// MARK: - Pixel button

struct PixelButton: View {
    let title: String
    var icon: String? = nil
    var fill: Color = PX.cream
    var textColor: Color = PX.ink
    let action: () -> Void
    @State private var down = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .black)) }
                Text(title).font(.pixel(11))
            }
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                ZStack {
                    Rectangle().fill(PX.ink)
                    Rectangle().fill(fill).padding(3)
                    VStack(spacing: 0) {
                        Rectangle().fill(fill.lighter).frame(height: 3)
                        Spacer(); Rectangle().fill(fill.darker).frame(height: 3)
                    }.padding(3)
                }
            )
            .offset(y: down ? 2 : 0)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in down = true }.onEnded { _ in down = false })
    }
}

// MARK: - Segmented pixel stat bar

struct PixelStatBar: View {
    let icon: String
    let tint: Color
    let value: Double           // 0...1
    private let segments = 10

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 18)
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { i in
                    Rectangle()
                        .fill(Double(i) / Double(segments) < value ? tint : PX.ink.opacity(0.14))
                        .frame(height: 12)
                }
            }
            .padding(2)
            .background(Rectangle().fill(PX.ink.opacity(0.85)))
        }
    }
}

// MARK: - Authored sprite renderer (for food / props)

struct PixelSprite: View {
    let rows: [String]
    let palette: [Character: Color]

    var body: some View {
        let w = rows.map(\.count).max() ?? 1
        let h = rows.count
        Canvas { ctx, size in
            let cell = min(size.width / Double(w), size.height / Double(h))
            let ox = (size.width - cell * Double(w)) / 2
            let oy = (size.height - cell * Double(h)) / 2
            for (r, row) in rows.enumerated() {
                for (c, ch) in row.enumerated() {
                    guard let color = palette[ch] else { continue }
                    ctx.fill(Path(CGRect(x: ox + Double(c) * cell, y: oy + Double(r) * cell,
                                         width: cell + 0.5, height: cell + 0.5)),
                             with: .color(color))
                }
            }
        }
        .aspectRatio(Double(w) / Double(h), contentMode: .fit)
    }
}

enum Sprites {
    // a little onigiri (rice ball) — used for the feed animation
    static let riceBall = [
        "..ooo..",
        ".owwwo.",
        "owwwwwo",
        "onnwnno",
        "onnwnno",
        ".ooooo.",
    ]
    static let ricePalette: [Character: Color] = [
        "o": PX.ink, "w": PX.white, "n": Color(hex: 0x2C3A2E),
    ]
}
