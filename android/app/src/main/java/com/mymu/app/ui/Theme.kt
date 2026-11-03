package com.mymu.app.ui

import android.provider.Settings
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * MyMu brand palette — pitch-black, high-contrast. The purple IS the identity.
 * (1:1 port of iOS Core/Theme.swift; the app is dark-only on both platforms.)
 */
object MyMuColors {
    val background = Color(0xFF000000)   // conversation bg — pitch black
    val surface = Color(0xFF111113)      // cards / composer (barely lifted)
    val elevated = Color(0xFF232328)     // hover / selected
    val primary = Color(0xFFAA88DD)      // brand accent — "the M" (unchanged)
    val text = Color(0xFFF2F2F7)         // crisp near-white
    val mutedText = Color(0xFFA3A3AC)    // secondary — readable on black
    val border = Color(0xFF232328)
    val danger = Color(0xFFE5484D)       // sharper error red
    val userBubble = Color(0x38AA88DD)   // primary at 22% alpha
    val assistantBubble = Color(0xFF141416)
    /** The composer pill — lifted a notch above `surface` so it reads as a
     * control on pitch black WITHOUT a stroke (the ChatGPT composer has no
     * border; its fill alone defines the shape). Port of iOS Theme.composer. */
    val composer = Color(0xFF1C1C1F)
}

/**
 * Reading-column cap (tablet/foldable parity with iOS's iPad behavior): past
 * this width, the transcript and composer center instead of stretching
 * edge-to-edge. A no-op on phones, where the viewport is already narrower
 * than the cap. (1:1 port of iOS Theme.maxContentWidth.)
 */
object MyMuLayout {
    val maxContentWidth: Dp = 720.dp
}

/**
 * Shared spacing scale — reuse one of these instead of picking a new number
 * per call site. (Port of iOS Theme.Spacing; not yet retrofitted into every
 * existing padding literal, same as the iOS change that introduced it.)
 */
object MyMuSpacing {
    val xs: Dp = 4.dp
    val sm: Dp = 8.dp
    val md: Dp = 12.dp
    val lg: Dp = 16.dp
    val xl: Dp = 24.dp
    val xxl: Dp = 32.dp
}

/**
 * Shared corner-radius scale (port of iOS Theme.Radius).
 *  - chip: MessageRow's error card + injected-context detail box (10dp)
 *  - media: MediaViews' delivered image/video/audio rounding (12dp — Android's
 *    own literal, kept; iOS uses 16, see the wave-5 README note)
 *  - bubble: MessageRow's user text bubble (22dp — ChatGPT geometry, wave 6)
 *  - composer: the EXPANDED composer pill (28dp — wave 6; the idle capsule is
 *    half its 52dp height)
 */
object MyMuRadius {
    val chip: Dp = 10.dp
    val media: Dp = 12.dp
    val bubble: Dp = 22.dp
    val composer: Dp = 28.dp
}

/**
 * Android's system-level motion-reduction signal: Compose has no built-in
 * equivalent of iOS's `@Environment(\.accessibilityReduceMotion)`, so this
 * reads the same "Remove animations" developer/accessibility setting other
 * Android apps check — the animator duration scale is 0 when the user has
 * turned system animations off. Read once per call site; this setting is
 * toggled rarely enough that live-observing it isn't worth the complexity.
 */
@Composable
fun LocalReduceMotion(): Boolean {
    val context = LocalContext.current
    return remember {
        try {
            Settings.Global.getFloat(
                context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f,
            ) == 0f
        } catch (_: Exception) {
            false
        }
    }
}

private val MyMuColorScheme = darkColorScheme(
    primary = MyMuColors.primary,
    onPrimary = MyMuColors.background,
    background = MyMuColors.background,
    onBackground = MyMuColors.text,
    surface = MyMuColors.surface,
    onSurface = MyMuColors.text,
    surfaceVariant = MyMuColors.elevated,
    onSurfaceVariant = MyMuColors.mutedText,
    error = MyMuColors.danger,
    outline = MyMuColors.border,
)

@Composable
fun MyMuTheme(content: @Composable () -> Unit) {
    // Dark-only by design, regardless of system setting — same as iOS.
    isSystemInDarkTheme() // observed but unused; keeps the recompose scope honest
    MaterialTheme(colorScheme = MyMuColorScheme, content = content)
}
