package com.mymu.app.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

private const val PERIOD_MS = 1100

/**
 * The "thinking" indicator shown INLINE in the transcript, in the exact spot
 * the reply will stream into — a single ball that gently grows and shrinks
 * before the first token arrives, then gives way to the real text the moment
 * it starts (matching the ChatGPT app; Manar, field reference 2026-10-24).
 * Port of iOS Views/PulsingBallIndicator.swift: dim/small at the edges,
 * bright/full at the midpoint; Reduce Motion shows a still ball.
 */
@Composable
fun PulsingBallIndicator(modifier: Modifier = Modifier) {
    if (LocalReduceMotion()) {
        Ball(scale = 1f, opacity = 0.75f, modifier)
        return
    }
    val transition = rememberInfiniteTransition(label = "pulsing-ball")
    val phase by transition.animateFloat(
        initialValue = 0f, targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(PERIOD_MS, easing = LinearEasing)),
        label = "phase",
    )
    val eased = if (phase < 0.5f) phase * 2 else (1 - phase) * 2
    Ball(scale = 0.8f + eased * 0.2f, opacity = 0.35f + eased * 0.65f, modifier)
}

/** 14dp — the ChatGPT ball sits in the gutter at roughly the x-height of the
 * text that replaces it. */
@Composable
private fun Ball(scale: Float, opacity: Float, modifier: Modifier) {
    Box(
        modifier
            .semantics { contentDescription = "Working" }
            .size(14.dp)
            .scale(scale)
            .alpha(opacity)
            .background(MyMuColors.primary, CircleShape),
    )
}
