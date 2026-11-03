package com.mymu.app.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private const val PERIOD_S = 1.6f
private const val STAGGER_S = 0.16f
private val LETTERS = listOf("M", "y", "M", "u")

/** Piecewise opacity mirroring the web CSS keyframes: 0.1 at 0/0.6/1.0, peak at 0.25. */
private fun letterOpacity(t: Float, index: Int): Float {
    val delay = index * STAGGER_S
    var phase = ((t - delay) % PERIOD_S) / PERIOD_S
    if (phase < 0f) phase += 1f
    val low = 0.1f
    val high = 1.0f
    return when {
        phase < 0.25f -> low + (high - low) * (phase / 0.25f)
        phase < 0.60f -> high - (high - low) * ((phase - 0.25f) / 0.35f)
        else -> low
    }
}

/**
 * The MyMu brand loader — the "MyMu" wordmark with each letter fading in an
 * opacity wave (0.1 → 1 → 0.1) in sequence. Matches the web app's `.mymu-loader`
 * (1.6s period, 0.16s stagger) and the iOS MyMuLoader 1:1. Shown while lists
 * load and while an agent is working.
 *
 * Reduced Motion (system "Remove animations"): the wordmark still reads as
 * "working", just without the perpetual opacity wave — a turn can run for
 * minutes, and that wave is exactly the sustained motion Reduce Motion asks
 * to avoid (iOS parity: MyMuLoader's accessibilityReduceMotion branch).
 */
@Composable
fun MyMuLoader(label: String? = null, modifier: Modifier = Modifier) {
    if (LocalReduceMotion()) {
        LettersRow(modifier, label) { 1f }
    } else {
        val transition = rememberInfiniteTransition(label = "mymu-loader")
        val t by transition.animateFloat(
            initialValue = 0f,
            targetValue = PERIOD_S,
            animationSpec = infiniteRepeatable(
                tween(durationMillis = (PERIOD_S * 1000).toInt(), easing = LinearEasing)),
            label = "clock",
        )
        LettersRow(modifier, label) { i -> letterOpacity(t, i) }
    }
}

@Composable
private fun LettersRow(modifier: Modifier, label: String?, opacity: (Int) -> Float) {
    Row(
        modifier.semantics { contentDescription = "Working" },
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
            LETTERS.forEachIndexed { i, letter ->
                Text(
                    letter,
                    color = MyMuColors.primary,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.alpha(opacity(i)),
                )
            }
        }
        if (label != null) {
            Text(label, color = MyMuColors.mutedText, style = MaterialTheme.typography.labelSmall)
        }
    }
}
