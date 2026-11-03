package com.manarz.myagent.home

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.manarz.myagent.chat.BrainPeek
import com.manarz.myagent.chat.Dictation
import com.manarz.myagent.chat.DrawerChat
import com.manarz.myagent.core.AppBuild
import com.manarz.myagent.core.AppEvent
import com.manarz.myagent.core.Beacon
import com.manarz.myagent.core.Events
import com.manarz.myagent.core.Target
import com.manarz.myagent.push.PushModule
import com.manarz.myagent.voice.GadkVoice
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

enum class Detent { CLOSED, HALF, FULL }

/** iOS DrawerMetrics, in dp (the embed's setStage takes CSS px = dp in a WebView). */
private class Metrics(val container: Float) {
    val closed = PEEK
    val half = max(PEEK, (container * 0.56f).roundToInt().toFloat())
    val full = max(PEEK, container)
    fun height(d: Detent) = when (d) { Detent.CLOSED -> closed; Detent.HALF -> half; Detent.FULL -> full }
    fun clamp(h: Float) = min(full, max(closed, h))
    fun nearest(h: Float) = listOf(Detent.CLOSED to closed, Detent.HALF to half, Detent.FULL to full)
        .minBy { abs(it.second - h) }.first
    companion object { const val PEEK = 52f }
}

/**
 * Home — the Android port of iOS PetView: the swarm (embed WebView) full-bleed,
 * the native voice under it, and the brain's MyMu conversation as a drawer
 * (closed peek / half / full). The mic rides the seam between the two.
 */
@Composable
fun HomeScreen(
    detent: Detent,
    onDetent: (Detent) -> Unit,
    onSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val ctl = remember { CritterController() }
    val active by GadkVoice.active.collectAsState()
    val answering by GadkVoice.answering.collectAsState()
    val caption by GadkVoice.caption.collectAsState()
    val stage by GadkVoice.stageText.collectAsState()
    val connectStage by GadkVoice.connectStage.collectAsState()
    val mic by GadkVoice.micLevel.collectAsState()
    val out by GadkVoice.outLevel.collectAsState()
    var important by remember { mutableStateOf<Pair<String, String>?>(null) }
    val haptic = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()

    val critterState = when {
        !active -> "idle"
        answering -> "talking"
        connectStage.isEmpty() -> "listening"
        else -> connectStage
    }

    // ---- voice → avatar
    LaunchedEffect(critterState) {
        ctl.setState(critterState)
        if (!active) {
            ctl.setLevel(0f)
            // a stop on a page that isn't listening yet: say idle again a beat later
            delay(500); if (!GadkVoice.active.value) ctl.setState("idle")
            delay(1500); if (!GadkVoice.active.value) ctl.setState("idle")
        }
    }
    LaunchedEffect(mic, active, answering) { if (active && !answering) ctl.setLevel(mic) }
    LaunchedEffect(out, answering) { if (answering) ctl.setLevel(out) }
    LaunchedEffect(Unit) { GadkVoice.moves.collect { ctl.perform(it.name, it.duration) } }
    LaunchedEffect(Unit) { GadkVoice.brainDispatched.collect { delay(600); ctl.refreshPending() } }
    LaunchedEffect(Unit) {
        Events.flow.collect { e ->
            when (e) {
                is AppEvent.Important -> { haptic.performHapticFeedback(HapticFeedbackType.LongPress); important = e.id to e.text }
                is AppEvent.ImportantDone -> if (important?.first == e.id) important = null
                else -> {}
            }
        }
    }
    DisposableEffect(Unit) {
        Beacon.send("app-launched")
        ctl.startFeeds(Target.current())
        onDispose { ctl.stopFeeds() }
    }

    BoxWithConstraints(modifier.fillMaxSize().background(Color(0xFF050608))) {
        val m = Metrics(maxHeight.value)
        val density = LocalDensity.current
        val height = remember { Animatable(m.height(detent)) }
        var dragging by remember { mutableStateOf(false) }
        var dragStart by remember { mutableStateOf(0f) }

        fun stage(h: Float, drag: Boolean) {
            val rise = max(0f, h - m.closed)
            val p = min(1f, rise / max(1f, m.half - m.closed))
            ctl.setStage(rise / 2, 1 - 0.22f * p, Metrics.PEEK, drag)
        }

        fun snap(target: Detent) {
            val changed = target != detent
            if (target != Detent.FULL) Dictation.cancel()
            dragging = false
            onDetent(target)
            scope.launch { height.animateTo(m.height(target), spring(dampingRatio = 0.86f, stiffness = Spring.StiffnessMediumLow)) }
            stage(m.height(target), false)
            if (changed) { haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove); Beacon.send("drawer-${target.name.lowercase()}") }
        }

        // the container changed (keyboard, rotation) or the detent was set from outside
        LaunchedEffect(m.container, detent) { if (!dragging) { height.snapTo(m.height(detent)); stage(m.height(detent), false) } }
        LaunchedEffect(height.value) { if (dragging) stage(height.value, true) }

        val dragState = rememberDraggableState { deltaPx ->
            val d = with(density) { deltaPx.toDp().value }
            scope.launch { height.snapTo(m.clamp(height.value - d)) }
        }

        // ---- the swarm, full-bleed
        AndroidView(
            factory = { c -> makeCritterWebView(c, ctl, homeFragment()) },
            modifier = Modifier.fillMaxSize(),
            onRelease = { it.destroy() },
        )

        // ---- header, important card, caption
        Column(
            Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 18.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(Modifier.fillMaxWidth().padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(AppBuild.header, color = Color.White.copy(alpha = 0.85f), fontSize = 13.sp, fontFamily = FontFamily.Monospace)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onSettings, modifier = Modifier.size(44.dp).semantics { contentDescription = "Settings" }) {
                    Icon(Icons.Filled.Settings, null, tint = Color.White.copy(alpha = 0.7f))
                }
            }
            AnimatedVisibility(important != null, enter = slideInVertically() + fadeIn(), exit = slideOutVertically() + fadeOut()) {
                important?.let { (id, text) ->
                    ImportantCard(text) { PushModule.ackReminder(id); important = null }
                }
            }
            AnimatedVisibility(active && caption.isNotEmpty(), enter = fadeIn(tween(200)), exit = fadeOut(tween(200))) {
                Text(caption, color = Color.White.copy(alpha = 0.5f), fontSize = 13.sp, textAlign = TextAlign.Center,
                    maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.fillMaxWidth())
            }
        }

        // ---- the drawer
        val h = height.value
        Box(
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .height(h.dp)
                .clip(RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp))
                .background(Color(0xFF0E0D16))
                .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp)),
        ) {
            Column(Modifier.fillMaxSize()) {
                // grabber + drag zone (the whole peek row while closed)
                Box(
                    Modifier.fillMaxWidth().height(if (detent == Detent.CLOSED) Metrics.PEEK.dp else 28.dp)
                        .draggable(dragState, Orientation.Vertical,
                            onDragStarted = { dragging = true; dragStart = height.value },
                            onDragStopped = { v ->
                                val coast = -with(density) { v.toDp().value } * 0.15f
                                snap(m.nearest(height.value + coast))
                            })
                        .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {
                            if (detent == Detent.CLOSED) snap(Detent.HALF)
                        },
                ) {
                    Box(Modifier.align(Alignment.TopCenter).padding(top = 7.dp).width(38.dp).height(5.dp)
                        .clip(CircleShape).background(Color.White.copy(alpha = 0.28f)))
                    if (detent == Detent.CLOSED && !dragging)
                        BrainPeek(Modifier.fillMaxSize().padding(start = 20.dp, end = 20.dp, top = 12.dp))
                }
                if (detent != Detent.CLOSED || dragging) {
                    DrawerChat(full = detent == Detent.FULL, onDictate = {
                        if (GadkVoice.active.value) GadkVoice.stop()
                        Dictation.toggle()
                    }, modifier = Modifier.weight(1f))
                }
            }
        }

        // ---- the mic, riding the seam
        val resting = detent == Detent.CLOSED && !dragging
        val p = min(1f, max(0f, (h - m.closed) / max(1f, m.half - m.closed)))
        val hideMic = detent == Detent.FULL && !dragging
        Column(
            Modifier.align(Alignment.BottomCenter)
                .offset { IntOffset(
                    x = with(density) { (-p * (maxWidth.value / 2 - 58)).dp.roundToPx() },
                    y = with(density) { (-(if (resting) m.closed + 12 else h - 42)).dp.roundToPx() },
                ) }
                .alpha(if (hideMic) 0f else 1f),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (stage.startsWith("✗"))
                Text(stage, color = Color(0xFFFF5A5A).copy(alpha = 0.85f), fontSize = 13.sp, fontWeight = FontWeight.Medium,
                    textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 24.dp))
            TalkButton(active, answering, onSeam = !resting, enabled = !hideMic) { GadkVoice.toggle() }
        }
    }
}

@Composable
private fun TalkButton(active: Boolean, answering: Boolean, onSeam: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val glow = if (active) Color(0xFFFF4D66) else Color(0xFF8059FF)
    val pulse = rememberInfiniteTransition(label = "pulse")
    val ring by pulse.animateFloat(1f, 1.45f, infiniteRepeatable(tween(1400), RepeatMode.Restart), label = "ring")
    val breathe by pulse.animateFloat(1f, 0.75f, infiniteRepeatable(tween(500), RepeatMode.Reverse), label = "breathe")
    Box(
        Modifier.size(96.dp)
            .clip(CircleShape)
            .clickable(enabled = enabled, interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onClick)
            .semantics { contentDescription = if (active) "Stop talking" else "Talk" },
        contentAlignment = Alignment.Center,
    ) {
        if (onSeam) Box(Modifier.size(60.dp).clip(CircleShape).background(Color(0xDB120F1F))
            .border(1.dp, Color.White.copy(alpha = 0.16f), CircleShape))
        if (active) Box(Modifier.size(64.dp).scale(ring).alpha((1.45f - ring) / 0.45f * 0.7f)
            .border(2.dp, glow.copy(alpha = 0.35f), CircleShape))
        Icon(
            if (active) Icons.Filled.Stop else Icons.Filled.Mic, null,
            tint = if (active) Color(0xFFFF7373) else Color.White.copy(alpha = 0.85f),
            modifier = Modifier.size(if (onSeam) 28.dp else 38.dp).alpha(if (answering) breathe else 1f),
        )
    }
}

/** An important reminder that arrived while the app was open: stays until Done. */
@Composable
private fun ImportantCard(text: String, onDone: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Color(0xFFDB2B3D)).padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Filled.Warning, null, tint = Color.White)
        Column(Modifier.weight(1f)) {
            Text("Important reminder", color = Color.White.copy(alpha = 0.85f), fontSize = 12.sp, fontWeight = FontWeight.Bold)
            Text(text, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 3)
        }
        TextButton(onClick = onDone, modifier = Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.22f))) {
            Text("Done", color = Color.White, fontWeight = FontWeight.Bold)
        }
    }
}
