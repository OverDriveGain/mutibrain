import SwiftUI

/// The three resting places of the chat drawer under the swarm (2026-10-24).
///
/// Manar's brief: switching between TALKING and WRITING must be one gesture,
/// the swarm stays the living background ("put the voice in the background and
/// drag a chat"), and the chat itself is MyMu's conversation, untouched.
/// ChatGPT was the reference (its transcript pushes up and the voice orb moves
/// to the top) but not the model — here the whole screen RE-COMPOSES around a
/// seam you drag:
///
///   closed  — voice. Full-bleed swarm, the mic below it, and at the very
///             bottom a one-line PEEK of the brain (its name + live state)
///             that is also the handle.
///   half    — both. The drawer rests at ~56%: the swarm shrinks and re-centres
///             in the top part (the embed shifts its own stage, nothing is
///             resized), the mic rides the SEAM between the two, and the MyMu
///             conversation is fully usable below. Typing lifts it to full.
///   full    — writing. The conversation owns the screen; the nav bar's
///             waveform button is the way back to voice (drops to half and
///             starts the mic).
///
/// The drawer is a plain bottom-aligned view inside the tab's safe area, not a
/// `.sheet`: a sheet can neither start as a peek bar nor let the view behind
/// it re-compose while it moves.
enum DrawerDetent: Equatable {
    case closed, half, full
}

/// Resting heights for a container (the Buddy tab's safe area; with the
/// keyboard up the container is what remains above it, so `full` tracks it).
struct DrawerMetrics {
    let container: CGFloat
    /// The peek row: grabber + the brain's name/state line.
    static let peek: CGFloat = 52

    var closed: CGFloat { Self.peek }
    var half: CGFloat { max(Self.peek, (container * 0.56).rounded()) }
    var full: CGFloat { max(Self.peek, container) }

    func height(_ d: DrawerDetent) -> CGFloat {
        switch d {
        case .closed: return closed
        case .half: return half
        case .full: return full
        }
    }
    func clamp(_ h: CGFloat) -> CGFloat { min(full, max(closed, h)) }

    /// Where a release lands: the resting height nearest to where the drag
    /// would have coasted (`projected` = height + the gesture's predicted
    /// remaining travel), so a flick crosses to the next detent and a slow
    /// drag settles where it is.
    func nearest(to projected: CGFloat) -> DrawerDetent {
        let stops: [(DrawerDetent, CGFloat)] = [(.closed, closed), (.half, half), (.full, full)]
        return stops.min { abs($0.1 - projected) < abs($1.1 - projected) }!.0
    }
}

private let drawerCorner: CGFloat = 24

/// The drawer chrome + its drag. The HOST owns the height (it is what moves
/// the mic and the swarm in step); the drawer reports drags from its handle
/// zone and leaves everything below that zone — the transcript's scroll, the
/// composer — to the content.
struct ChatDrawer<Content: View>: View {
    let height: CGFloat
    /// Drags must START within this many points of the drawer's top to count
    /// (the grabber row + the nav bar). `.infinity` while closed: the whole
    /// peek row is the handle.
    let handleZone: CGFloat
    /// Live drag delta in points, positive = up.
    let onDrag: (CGFloat) -> Void
    /// Release: final delta + the gesture's predicted remaining travel
    /// (positive = up), for the detent choice.
    let onRelease: (CGFloat, CGFloat) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 36, height: 5)
                .padding(.top, 7)
                .padding(.bottom, 6)
                .accessibilityElement()
                .accessibilityLabel("Chat drawer handle")
                .accessibilityIdentifier("drawer-grabber")
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .background(Theme.background)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: drawerCorner, topTrailingRadius: drawerCorner))
        .overlay(alignment: .top) {
            // a hairline so the black sheet reads as a surface over the near-black stage
            UnevenRoundedRectangle(topLeadingRadius: drawerCorner, topTrailingRadius: drawerCorner)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                .frame(height: height)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.5), radius: 20, y: -8)
        .coordinateSpace(name: "chat-drawer")
        .simultaneousGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .named("chat-drawer"))
                .onChanged { v in
                    guard v.startLocation.y <= handleZone else { return }
                    onDrag(-v.translation.height)
                }
                .onEnded { v in
                    guard v.startLocation.y <= handleZone else { return }
                    onRelease(-v.translation.height,
                              -(v.predictedEndTranslation.height - v.translation.height))
                }
        )
    }
}
