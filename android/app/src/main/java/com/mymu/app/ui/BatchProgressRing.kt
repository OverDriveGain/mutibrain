package com.mymu.app.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp

/**
 * Determinate activity ring for LONG batch operations — the Agents tab's
 * usage-probe fan-out wears it around the account icon (iOS BatchProgressRing,
 * c376a47). Deliberately DISTINCT from the app's ordinary indeterminate
 * spinners (Manar, 2026-09-29: a long fan-out must not use the same progress
 * as quick everyday loads): the arc's LENGTH is real batch completion
 * (done/total), and the whole arc slowly orbits so a stalled probe still reads
 * as alive, not frozen (App Store download idiom).
 *
 * Reduced Motion: no orbit — the arc rests at 12 o'clock and only its length
 * moves (and snaps rather than easing), same as MyMuLoader's still branch.
 */
@Composable
fun BatchProgressRing(fraction: Float, modifier: Modifier = Modifier) {
    val reduceMotion = LocalReduceMotion()
    // A hairline of arc is always shown so 0/N doesn't render bare.
    val sweep by animateFloatAsState(
        targetValue = fraction.coerceIn(0.06f, 1f),
        animationSpec = if (reduceMotion) snap() else tween(350),
        label = "batch-ring-sweep",
    )
    val orbit = if (reduceMotion) 0f else {
        val transition = rememberInfiniteTransition(label = "batch-ring")
        val angle by transition.animateFloat(
            initialValue = 0f, targetValue = 360f,
            animationSpec = infiniteRepeatable(tween(1800, easing = LinearEasing)),
            label = "batch-ring-orbit",
        )
        angle
    }
    Canvas(modifier.size(31.dp)) {
        val width = 2.dp.toPx()
        val inset = width / 2
        val arcSize = androidx.compose.ui.geometry.Size(size.width - width, size.height - width)
        val topLeft = androidx.compose.ui.geometry.Offset(inset, inset)
        drawArc(MyMuColors.border.copy(alpha = 0.7f), 0f, 360f, useCenter = false,
            topLeft = topLeft, size = arcSize, style = Stroke(width))
        drawArc(MyMuColors.primary, -90f + orbit, 360f * sweep, useCenter = false,
            topLeft = topLeft, size = arcSize, style = Stroke(width, cap = StrokeCap.Round))
    }
}
