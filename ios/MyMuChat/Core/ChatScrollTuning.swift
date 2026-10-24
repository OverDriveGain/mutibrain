import Foundation
import SwiftUI
import UIKit

/// Every timing that governs how the transcript moves, in one place.
///
/// The shape of every scroll here is the same: **wait a beat, then ease** —
/// never an instant teleport. The beat exists because a scroll issued in the
/// same frame as an appended row targets a bottom that hasn't laid out yet; the
/// ease exists because a hard snap on every stream chunk reads as a twitch.
///
/// Since 2026-10-24 there is ONE scroll rule — follow the bottom while the
/// user wants to follow — and the send-time "message to the top" is pure
/// GEOMETRY (the active turn's min-height box in ChatView), not a competing
/// scroll target. The old send-correction taps that fought the stream
/// (sendCorrections / glideUntil) are gone with it.
///
/// Silent *corrections* are deliberately un-animated: they clamp residual drift
/// after the eased scroll has landed, and animating them would re-introduce the
/// motion they exist to remove.
enum ChatScroll {

    // MARK: incoming messages / stream chunks

    /// Beat before following an incoming message, so the new row has real layout
    /// to scroll to. Bursts of stream chunks coalesce into one scroll per beat.
    static let followDelay: TimeInterval = 0.12
    /// Duration of the eased follow scroll. This is the knob that decides how
    /// "sudden" an arriving message feels — raise it for a slower glide.
    static let followDuration: TimeInterval = 0.28
    /// Silent clamp after the follow lands, catching rows that resize late
    /// (images decoding, tool output expanding).
    static let followCorrection: TimeInterval = 0.35

    // MARK: send

    /// Beat before the post-send glide: the optimistic bubble AND the active-
    /// turn box need one layout pass, or the glide targets a moving bottom.
    static let sendDelay: TimeInterval = 0.05
    /// Silent clamp once the glide has landed and the composer/keyboard have
    /// settled. Only applied for SMALL drift (see ChatView) — a real overflow
    /// is the eased follow's job, never a snap.
    static let sendSettle: TimeInterval = 0.65
    /// Drift (pt) a silent clamp is allowed to correct; anything larger is
    /// real content growth and gets the eased follow instead.
    static let settleTolerance: CGFloat = 40

    // MARK: keyboard

    /// One animated pin ridden along the keyboard-opening animation.
    static let keyboardOpenDuration: TimeInterval = 0.25
    /// Silent clamp once that animation has settled.
    static let keyboardOpenCorrection: TimeInterval = 0.45
    /// Silent clamp after a small composer height change (typing wraps, chips).
    static let composerCorrection: TimeInterval = 0.25

    // MARK: jump-to-bottom button

    /// Duration of the eased scroll when the user taps the ↓ button. Longer than
    /// a follow: this is a deliberate, often long jump, and easing it is what
    /// makes it read as travel rather than a cut.
    static let jumpDuration: TimeInterval = 0.35
    /// Distance from the bottom (pt) past which the ↓ button appears.
    static let jumpButtonThreshold: CGFloat = 24
    /// Fade/scale duration for the ↓ button appearing and disappearing.
    static let jumpButtonFade: TimeInterval = 0.18
    /// The bottom must stay lost THIS long before the ↓ button shows. A send or
    /// stream append grows the content an instant before the eased follow
    /// catches up (~0.3s), and the arrow blinking through that gap read as a
    /// glitch. Longer than followDelay+followDuration; shorter than a human
    /// "I scrolled up, where's my way back" moment.
    static let jumpButtonAppearDelay: TimeInterval = 0.5

    // MARK: settling / repair

    /// Re-pin taps used when landing at the bottom without animation (history
    /// load, keyboard dismiss): row heights resolve over several frames.
    static let settleTaps: [TimeInterval] = [0.05, 0.2, 0.5, 1.0]
    /// A phantom bottom gap must survive this long to count as real, not as a
    /// rubber-band bounce or in-flight layout.
    static let gapRepairDebounce: TimeInterval = 0.5
    /// Second repair pass, in case the first lost a race with an inset animation.
    static let gapRepairConfirm: TimeInterval = 0.2
    /// Hard fallback that reveals the transcript even if bottom contact is never
    /// reported, so an odd layout can't leave the chat permanently hidden.
    static let revealFallback: TimeInterval = 0.7

    // MARK: derived

    private static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// The eased curve used for a follow scroll.
    static var followAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: followDuration) }
    /// The post-send glide: a soft spring, so the sent bubble settles at the
    /// top rather than braking to a stop.
    static var sendAnimation: Animation? { reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9) }
    /// The eased curve used for the jump-to-bottom button.
    static var jumpAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: jumpDuration) }
    /// Row insertions (the sent bubble flying up, the ball giving way to the
    /// first text, a tool row landing). Applied by the store at the mutation
    /// so the view's transitions run in the same transaction.
    static var insertAnimation: Animation? { reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.86) }
    /// A reconcile that really brought something new: rows fade in rather
    /// than popping (Manar: "spits a lot of messages").
    static var reconcileAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.25) }
    /// The composer pill changing shape (idle capsule ↔ expanded two-row).
    static var composerAnimation: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86) }

    /// How a just-sent user bubble enters: from below (where the composer is)
    /// with a touch of scale — reads as the text leaving the box.
    static var userBubbleTransition: AnyTransition {
        reduceMotion ? .opacity
            : .asymmetric(insertion: .offset(y: 56).combined(with: .opacity)
                              .combined(with: .scale(scale: 0.94, anchor: .bottomTrailing)),
                          removal: .opacity)
    }
    /// How the pending ball comes and goes.
    static var pendingTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.4, anchor: .leading))
    }
    /// How a new assistant row (first text, tool row) enters.
    static var assistantRowTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6))
    }
}
