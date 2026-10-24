import SwiftUI

/// The "thinking" indicator shown INLINE in the transcript, in the exact spot
/// the reply will stream into — a single ball that gently grows and shrinks
/// before the first token arrives, then gives way to the real text the moment
/// it starts (matching the ChatGPT app; Manar, field reference 2026-10-24).
/// Mirrors the design guide's gentle-pulse keyframes: dim/small at the edges,
/// bright/full at the midpoint.
struct PulsingBallIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let period = 1.1

    var body: some View {
        Group {
            if reduceMotion {
                ball(scale: 1, opacity: 0.75)
            } else {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let phase = (t.truncatingRemainder(dividingBy: period)) / period
                    let eased = phase < 0.5 ? phase * 2 : (1 - phase) * 2
                    ball(scale: 0.8 + eased * 0.2, opacity: 0.35 + eased * 0.65)
                }
            }
        }
        .accessibilityLabel("Working")
    }

    /// 14pt — the ChatGPT ball sits in the gutter at roughly the x-height of
    /// the text that replaces it.
    private func ball(scale: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(Theme.primary)
            .frame(width: 14, height: 14)
            .scaleEffect(scale)
            .opacity(opacity)
    }
}
