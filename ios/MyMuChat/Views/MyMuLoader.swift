import SwiftUI

/// The MyMu brand loader — the "MyMu" wordmark with each letter fading in an
/// opacity wave (0.1 → 1 → 0.1) in sequence. Matches the web app's `.mymu-loader`
/// (1.6s period, 0.16s stagger). Shown while an agent is working.
struct MyMuLoader: View {
    var label: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let letters = ["M", "y", "M", "u"]
    private let period = 1.6
    private let stagger = 0.16

    var body: some View {
        Group {
            // Reduced Motion: the wordmark still says "working", just without
            // the perpetual opacity wave — a turn can run for minutes, and that
            // wave is exactly the sustained motion Reduce Motion asks to avoid.
            if reduceMotion {
                lettersRow { _ in 1 }
            } else {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    lettersRow { opacity(t: t, index: $0) }
                }
            }
        }
        .accessibilityLabel("Working")
    }

    private func lettersRow(opacity: @escaping (Int) -> Double) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 1) {
                ForEach(0..<letters.count, id: \.self) { i in
                    Text(letters[i])
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.primary)
                        .opacity(opacity(i))
                }
            }
            if let label {
                Text(label).font(.caption).foregroundColor(Theme.mutedText)
            }
        }
    }

    /// Piecewise opacity mirroring the CSS keyframes: 0.1 at 0/0.6/1.0, peak at 0.25.
    private func opacity(t: Double, index: Int) -> Double {
        let delay = Double(index) * stagger
        var phase = ((t - delay).truncatingRemainder(dividingBy: period)) / period
        if phase < 0 { phase += 1 }
        let low = 0.1, high = 1.0
        if phase < 0.25 { return low + (high - low) * (phase / 0.25) }
        if phase < 0.60 { return high - (high - low) * ((phase - 0.25) / 0.35) }
        return low
    }
}
