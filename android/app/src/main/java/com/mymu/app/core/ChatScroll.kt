package com.mymu.app.core

/**
 * Every timing that governs how the transcript follows the conversation, in one
 * place — the 1:1 port of iOS Core/ChatScrollTuning.swift (all values converted
 * to milliseconds, thresholds kept in dp).
 *
 * The shape of every scroll here is the same: **wait a beat, then ease** —
 * never an instant teleport. The beat exists because a scroll issued in the
 * same frame as an appended row targets a bottom that hasn't laid out yet; the
 * ease exists because a hard snap on every stream chunk reads as a twitch.
 *
 * Since 2026-10-24 (wave 6) there is ONE scroll rule — follow the bottom while
 * the user wants to follow — and the send-time "message to the top" is pure
 * GEOMETRY (the active turn's min-height box in ChatScreen), not a competing
 * scroll target. The old send-correction taps that fought the stream
 * (sendCorrections / glide window) are gone with it.
 *
 * Silent *corrections* are deliberately un-animated: they clamp residual drift
 * after the eased scroll has landed, and animating them would re-introduce the
 * motion they exist to remove.
 */
object ChatScroll {

    // incoming messages / stream chunks -------------------------------------

    /** Beat before following an incoming message, so the new row has real
     * layout to scroll to. Bursts of stream chunks coalesce into one scroll. */
    const val followDelayMs = 120L
    /** Duration of the eased follow scroll — the knob that decides how
     * "sudden" an arriving message feels. */
    const val followDurationMs = 280
    /** Silent clamp after the follow lands, catching rows that resize late
     * (images decoding, tool output expanding). */
    const val followCorrectionMs = 350L

    // send -------------------------------------------------------------------

    /** Beat before the post-send glide: the optimistic bubble AND the active-
     * turn box need one layout pass, or the glide targets a moving bottom. */
    const val sendDelayMs = 50L
    /** Silent clamp once the glide has landed and the composer/keyboard have
     * settled. Only applied for SMALL drift (see ChatScreen) — a real overflow
     * is the eased follow's job, never a snap. */
    const val sendSettleMs = 650L
    /** Drift (dp) a silent clamp is allowed to correct; anything larger is
     * real content growth and gets the eased follow instead. */
    const val settleToleranceDp = 40
    /** The post-send glide: a soft spring (iOS response 0.42 / damping 0.9),
     * so the sent bubble settles at the top rather than braking to a stop. */
    const val sendSpringStiffness = 224f
    const val sendSpringDamping = 0.9f

    // keyboard ---------------------------------------------------------------

    /** One animated pin ridden along the keyboard-opening animation. */
    const val keyboardOpenDurationMs = 250
    /** Silent clamp once that animation has settled. */
    const val keyboardOpenCorrectionMs = 450L
    /** Silent clamp after a small composer height change (typing wraps, chips). */
    const val composerCorrectionMs = 250L

    // jump-to-bottom button ---------------------------------------------------

    /** Duration of the eased scroll when the user taps the ↓ button. Longer
     * than a follow: a deliberate, often long jump reads as travel. */
    const val jumpDurationMs = 350
    /** Distance from the bottom (dp) past which the ↓ button appears. */
    const val jumpButtonThresholdDp = 24
    /** Fade/scale duration for the ↓ button appearing and disappearing. */
    const val jumpButtonFadeMs = 180
    /** The bottom must stay lost THIS long before the ↓ button shows — a send
     * or stream append loses the bottom for the beat before the eased follow
     * catches up, and the arrow blinking through that gap read as a glitch. */
    const val jumpButtonAppearDelayMs = 500L

    // settling / repair -------------------------------------------------------

    /** Re-pin taps used when landing at the bottom without animation (history
     * load, keyboard dismiss): row heights resolve over several frames. */
    val settleTapsMs = listOf(50L, 200L, 500L, 1000L)
    /** A phantom bottom gap must survive this long to count as real, not as a
     * rubber-band bounce or in-flight layout. */
    const val gapRepairDebounceMs = 500L
    /** Second repair pass, in case the first lost a race with an inset animation. */
    const val gapRepairConfirmMs = 200L
    /** Hard fallback that reveals the transcript even if bottom contact is
     * never reported, so an odd layout can't leave the chat permanently hidden. */
    const val revealFallbackMs = 700L

    // gestures ----------------------------------------------------------------

    /** Accumulated upward drag (dp) that means "stop following" — a real
     * "scroll up to read" clears it instantly, finger wobble doesn't. */
    const val disarmDragDp = 24
    /** Viewport height change (dp) treated as a keyboard open/close rather
     * than a composer growing a line. */
    const val keyboardDeltaDp = 60

    // row transitions / composer ------------------------------------------------

    /** Row insertions (the sent bubble flying up, the ball giving way to the
     * first text, a tool row landing): iOS spring(response 0.36, damping 0.86). */
    const val insertSpringStiffness = 305f
    const val insertSpringDamping = 0.86f
    /** How a just-sent user bubble enters: from below (where the composer is)
     * with a touch of scale — reads as the text leaving the box. */
    const val userBubbleOffsetDp = 56
    const val userBubbleScale = 0.94f
    /** How a new assistant row (first text, tool row) enters. */
    const val assistantRowOffsetDp = 6
    /** How the pending ball comes and goes (scale anchored at the leading edge). */
    const val pendingScale = 0.4f
    /** A reconcile that really brought something new: rows fade in rather
     * than popping. */
    const val reconcileFadeMs = 250
    /** The composer pill changing shape (idle capsule ↔ expanded two-row):
     * iOS spring(response 0.32, damping 0.86). */
    const val composerSpringStiffness = 386f
    const val composerSpringDamping = 0.86f
}
