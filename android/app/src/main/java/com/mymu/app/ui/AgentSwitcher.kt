package com.mymu.app.ui

import android.os.SystemClock
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChevronLeft
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalTextToolbar
import androidx.compose.ui.platform.TextToolbar
import androidx.compose.ui.platform.TextToolbarStatus
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.mymu.app.core.AppState
import com.mymu.app.core.DraftStore
import com.mymu.app.core.Haptics
import com.mymu.app.core.Harness
import com.mymu.app.core.Project
import com.mymu.app.core.ProjectsStore
import kotlin.math.abs
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * In-chat agent switching (port of iOS Views/AgentSwitcher.swift, b755c9a).
 * A live chat can't be page-dragged like a photo carousel — each chat owns a
 * relay socket and a freshly loaded transcript, so there is nothing real to
 * show mid-drag. Instead the swipe drives a small carousel HUD (the
 * camera-mode-picker pattern): swiping raises the HUD with the neighbor
 * agents visible left and right, each further swipe steps the candidate, and
 * when the finger lifts a short countdown "settles" the choice — visible as
 * a draining bar. Tapping the candidate commits immediately; TYPING commits
 * immediately too, carrying the draft into the new chat (the composer stays
 * reachable below the HUD). Swiping back to the current agent (or letting it
 * settle there) cancels. Only the COMMIT navigates: a ChatTarget handed to
 * MainTabs, which swaps the visible chat route in place (the stack keys
 * chats by session id, so the conversation rebuilds cleanly).
 */
object ChatSwitcher {
    /** Set when a switch settles; MainTabs replaces the visible chat route in
     * the CURRENT tab — same contract as PushManager.pendingTarget, minus the
     * forced jump to the Agents tab. */
    val target = MutableStateFlow<ChatTarget?>(null)

    /** Composer keystrokes, forwarded on every draft change (iOS
     * `ChatSwitcher.typing` PassthroughSubject). While the HUD is raised,
     * typing means "switch NOW and take my text along" — watching the draft
     * itself (not IME events) keeps this deterministic. Every emission carries
     * the FULL draft, so a hot flow that keeps only the newest value is exact:
     * `tryEmit` never fails, and a collector that lags a keystroke sees the
     * text it would have ended up with anyway. */
    val typing = MutableSharedFlow<String>(extraBufferCapacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    /** Draft carried across a type-to-switch: the destination chat's composer
     * consumes it, so the keystrokes that triggered the switch are not lost. */
    var handoffDraft: String? = null
    fun takeDraft(): String? = handoffDraft.also { handoffDraft = null }
}

/** Horizontal travel that raises the HUD and counts as the first step. Close
 * to the ORIGINAL light feel (iOS round 3, c376a47): text selection is
 * hard-gated by [TextSelectionGate], so the round-1 heavy thresholds (72dp,
 * 2.2× dominance, a velocity floor) that made intentional swipes feel dead
 * and flaky are gone. No velocity floor — it made moderate-speed swipes
 * silently do nothing. */
private val ACTIVATION = 44.dp
/** The axis is decided once, on the first ~25dp of every drag (iOS 981d688
 * DragGesture minimumDistance) — a drag that starts vertical is a scroll for
 * its whole life and can never raise the HUD, however it drifts sideways. */
private val AXIS_LOCK = 25.dp
/** Horizontal must beat vertical by this factor, both for the axis lock and
 * at activation (iOS AgentSwitcher.swift as of 981d688). */
private const val DOMINANCE = 2.2f
/** Additional travel per further step within one continuous drag. */
private val STEP = 130.dp
/** Leading strip left untouched — the system's back edge-gesture territory. */
private val EDGE_GUARD = 44.dp
/** Finger-up → commit. Long enough to read the name and swipe again, short
 * enough that settling never feels like waiting — 1.4s read as "stuck before
 * switching" (iOS c376a47). */
private const val SETTLE_MS = 900

/**
 * Hard gate against raising the switcher mid text-selection (port of iOS
 * TextSelectionMonitor, 8328e37). Thresholds alone are leaky — a selection
 * drag and a switch swipe are the same physical motion — so while a
 * selection is live, or within 0.6s of it clearing (the dismissing
 * tap-drag), the swipe refuses to activate.
 *
 * Compose exposes no public selection callback on SelectionContainer, but
 * every container shows the text toolbar (Copy / Select all) exactly while it
 * holds a selection and hides it when the selection clears — so the app-wide
 * [TrackTextSelection] wrapper around [LocalTextToolbar] is the signal.
 * Handle drags hide the toolbar too, but handles live in their own popup
 * window: those touches never reach the transcript's swipe listener.
 */
object TextSelectionGate {
    private const val CLEAR_GRACE_MS = 600L
    private var toolbar: TextToolbar? = null
    private var clearedAt = 0L

    val blocksSwitcher: Boolean
        get() = toolbar?.status == TextToolbarStatus.Shown ||
            SystemClock.uptimeMillis() - clearedAt < CLEAR_GRACE_MS

    internal fun shown(t: TextToolbar) { toolbar = t }
    internal fun cleared() { clearedAt = SystemClock.uptimeMillis() }
}

/** Delegates to the platform toolbar and reports show/hide to the gate. */
private class SelectionTrackingToolbar(private val platform: TextToolbar) : TextToolbar {
    override val status: TextToolbarStatus get() = platform.status

    override fun showMenu(
        rect: Rect, onCopyRequested: (() -> Unit)?, onPasteRequested: (() -> Unit)?,
        onCutRequested: (() -> Unit)?, onSelectAllRequested: (() -> Unit)?,
    ) {
        platform.showMenu(rect, onCopyRequested, onPasteRequested, onCutRequested, onSelectAllRequested)
        TextSelectionGate.shown(platform)
    }

    override fun showMenu(
        rect: Rect, onCopyRequested: (() -> Unit)?, onPasteRequested: (() -> Unit)?,
        onCutRequested: (() -> Unit)?, onSelectAllRequested: (() -> Unit)?,
        onAutofillRequested: (() -> Unit)?,
    ) {
        platform.showMenu(rect, onCopyRequested, onPasteRequested, onCutRequested,
            onSelectAllRequested, onAutofillRequested)
        TextSelectionGate.shown(platform)
    }

    override fun hide() {
        val wasShown = platform.status == TextToolbarStatus.Shown
        platform.hide()
        if (wasShown) TextSelectionGate.cleared()
    }
}

/** Installs the selection-tracking toolbar for everything below it (the app
 * root wraps RootView in it, so every transcript SelectionContainer reports). */
@Composable
fun TrackTextSelection(content: @Composable () -> Unit) {
    val platform = LocalTextToolbar.current
    val tracking = remember(platform) { SelectionTrackingToolbar(platform) }
    CompositionLocalProvider(LocalTextToolbar provides tracking, content = content)
}

/** Gesture + HUD state for one chat. Roster/callbacks refresh per composition
 * (status dots stay live); the interaction state survives recomposition. */
class AgentSwitcherState internal constructor() {
    internal var roster: List<Project> = emptyList()
    internal var currentIndex = 0
    /** The chat's own projectId — the DraftStore key a type-to-switch clears
     * as the draft departs (remote chats key drafts by agent). */
    internal var currentProjectId = ""
    internal var activationPx = 0f
    internal var stepPx = 0f
    internal var edgeGuardPx = 0f
    internal var onCommit: (Project) -> Unit = {}

    /** Candidate roster index while the HUD is up; null = idle (no HUD). */
    var candidate by mutableStateOf<Int?>(null)
        private set

    /** 0 = countdown paused (finger down / idle); each positive value arms
     * one settle window — bumping it restarts the HUD's countdown effect. */
    var settleEpoch by mutableStateOf(0)
        private set
    private var epochCounter = 0

    /** Baseline for the ACTIVE drag: each drag steps relative to where the
     * last one left off, so repeated swipes keep walking the list. */
    private var dragBase = 0

    /** Reentry guard (iOS `committing`): a commit fired and the route swap is
     * about to dispose this chat — ignore further gestures and taps in the
     * gap. Keystrokes in the gap still refresh the handed-off draft. */
    private var committing = false

    /** Activation check for a horizontally-locked drag that hasn't raised
     * anything yet: enough travel, still decisively horizontal, away from the
     * back-swipe edge, and no live (or just-cleared) text selection. */
    internal fun tryActivate(startX: Float, dx: Float, dy: Float): Boolean {
        if (committing || roster.size < 2 || startX < edgeGuardPx) return false
        if (TextSelectionGate.blocksSwitcher) return false
        if (abs(dx) <= activationPx || abs(dx) <= abs(dy) * DOMINANCE) return false
        dragBase = candidate ?: currentIndex
        settleEpoch = 0 // pause a running countdown while the finger is down
        return true
    }

    /** [dx] = total horizontal travel of the active drag. */
    internal fun dragTo(dx: Float) {
        // Finger left pulls in the RIGHT neighbor (next), finger right the
        // LEFT one — carousel semantics. Crossing back under the activation
        // distance returns to the drag base, so an unfinished swipe cancels
        // itself.
        val offset = if (abs(dx) > activationPx) {
            val sign = if (dx < 0) 1 else -1
            sign * (1 + ((abs(dx) - activationPx) / stepPx).toInt())
        } else 0
        // The HUD only rises on a real first step, never at rest.
        if (candidate == null && offset == 0) return
        stepTo(dragBase + offset)
    }

    internal fun dragEnd() {
        if (candidate != null) settleEpoch = ++epochCounter
    }

    /** Move the candidate (clamped to the roster) with a tick per real step. */
    private fun stepTo(index: Int) {
        if (roster.isEmpty()) return
        val next = index.coerceIn(0, roster.size - 1)
        if (next == candidate) return
        candidate = next
        Haptics.tick()
    }

    /** Side-chip tap: step there and rewind the countdown. */
    internal fun tapStep(index: Int) {
        if (committing) return
        stepTo(index)
        settleEpoch = ++epochCounter
    }

    /** The settled choice. Landing on the current agent just dismisses — that
     * IS the cancel gesture, not an error. Also the center chip's tap action:
     * committing NOW is the advertised way to skip the delay (typing is the
     * other, see [handleTyping]). */
    internal fun settle() {
        if (committing) return
        val c = candidate ?: return
        settleEpoch = 0
        candidate = null
        if (c == currentIndex || c !in roster.indices) return
        Haptics.send()
        committing = true
        onCommit(roster[c])
    }

    /** Typing while the HUD is up overrides the countdown: switch NOW, and
     * hand the draft to the destination composer so nothing typed is lost
     * (iOS AgentSwitcherModifier.handleTyping). The draft departs with the
     * user — the origin's stored copy is cleared so coming back later doesn't
     * resurrect text that moved to another agent. The composer saved this
     * text to that very key a moment ago, which is why it saves BEFORE it
     * forwards: the clear must win. A keystroke landing in the commit→dispose
     * gap still refreshes the handed-off draft. */
    internal fun handleTyping(text: String) {
        if (text.isEmpty()) return
        if (committing) {
            ChatSwitcher.handoffDraft = text
            DraftStore.clear(currentProjectId)
            return
        }
        val c = candidate ?: return
        if (c == currentIndex) {
            settle() // the cancel gesture: dismiss, keep typing here
            return
        }
        ChatSwitcher.handoffDraft = text
        DraftStore.clear(currentProjectId)
        settle()
    }
}

/** Null when switching doesn't apply: local sessions, no store, roster < 2,
 * or the current agent can't be found in it. */
@Composable
fun rememberAgentSwitcherState(store: ProjectsStore?, target: ChatTarget): AgentSwitcherState? {
    if (store == null || !target.isRemote) return null
    val projects by store.projects.collectAsStateWithLifecycle()
    val roster = store.rosterOf(projects) // HOST PATCH (MyAgent): curated roster
    // projectId first; title as fallback (notification-born chats can carry a
    // projectId minted from a rotated session id).
    val currentIndex = roster.indexOfFirst { it.projectId == target.projectId }
        .takeIf { it >= 0 }
        ?: roster.indexOfFirst { it.displayName == target.title }.takeIf { it >= 0 }
    if (currentIndex == null || roster.size < 2) return null

    val density = LocalDensity.current
    val state = remember(target.sessionId) { AgentSwitcherState() }
    state.roster = roster
    state.currentIndex = currentIndex
    state.currentProjectId = target.projectId
    state.activationPx = with(density) { ACTIVATION.toPx() }
    state.stepPx = with(density) { STEP.toPx() }
    state.edgeGuardPx = with(density) { EDGE_GUARD.toPx() }
    state.onCommit = { agent ->
        // Same target construction as the Agents list row — host pinning and
        // session-keyed identity come along for free.
        val route = AppState.routeForAgent(agent.displayName)
        ChatSwitcher.target.value = ChatTarget(
            sessionId = agent.remoteSessionId ?: agent.projectId.removePrefix("remote:"),
            projectId = agent.projectId, title = agent.displayName, isRemote = true,
            origin = route?.first, tokenOverride = route?.second,
            pinnedHostNeedingLogin = AppState.pinnedHostNeedingLogin(agent.displayName),
            isDemo = store.isDemo)
    }
    // The composer's keystrokes (iOS `.onReceive(ChatSwitcher.shared.typing)`).
    // Local chats never get here (state is null above), so typing in them is
    // inert — the iOS `enabled` guard.
    LaunchedEffect(state) {
        ChatSwitcher.typing.collect { state.handleTyping(it) }
    }
    return state
}

/** The swipe listener, attached to the transcript. Axis-locked (iOS 981d688):
 * the first ~25dp decide horizontal (≥ 2.2× the vertical travel) or not, and
 * a drag that isn't horizontal from the start never raises the HUD. Observes
 * without consuming until it activates, so the list's vertical scroll and
 * the text-selection gestures keep working; a change some child already
 * consumed (list scroll, selection drag, a code card's horizontal scroll)
 * before activation means the drag belongs to that child. */
fun Modifier.agentSwitcherGesture(state: AgentSwitcherState?): Modifier {
    state ?: return this
    return pointerInput(state) {
        val lockPx = AXIS_LOCK.toPx()
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            val start = down.position
            var horizontal = false
            var active = false
            while (true) {
                val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                if (!change.pressed) break
                val d = change.position - start
                if (!active) {
                    if (change.isConsumed) break
                    if (!horizontal) {
                        if (d.getDistance() < lockPx) continue
                        if (abs(d.x) <= abs(d.y) * DOMINANCE) break // vertical for life
                        horizontal = true
                    }
                    if (!state.tryActivate(start.x, d.x, d.y)) continue
                    active = true
                }
                change.consume()
                state.dragTo(d.x)
            }
            if (active) state.dragEnd()
        }
    }
}

/** The carousel HUD, dropped from the transcript's top edge. */
@Composable
fun BoxScope.AgentSwitcherHud(state: AgentSwitcherState?) {
    state ?: return
    val candidate = state.candidate

    // Draining settle bar: full while the finger is down, drains linearly
    // once it lifts; every new epoch restarts the run, and a run that
    // survives to zero commits. Cancelling is free — a restarted effect
    // kills the previous animation mid-flight.
    val progress = remember { Animatable(1f) }
    LaunchedEffect(state.settleEpoch, candidate != null) {
        if (candidate == null) return@LaunchedEffect
        progress.snapTo(1f)
        if (state.settleEpoch == 0) return@LaunchedEffect
        progress.animateTo(0f, tween(SETTLE_MS, easing = LinearEasing))
        state.settle()
    }

    androidx.compose.animation.AnimatedVisibility(
        visible = candidate != null,
        modifier = Modifier.align(Alignment.TopCenter),
        enter = fadeIn(tween(200)) + slideInVertically(tween(200)) { -it },
        exit = fadeOut(tween(200)) + slideOutVertically(tween(200)) { -it },
    ) {
        // The exit animation keeps composing after candidate goes null —
        // hold the last real value so the card doesn't blank mid-slide.
        var shown by remember { mutableStateOf(0) }
        candidate?.let { shown = it }
        val c = shown.coerceIn(0, (state.roster.size - 1).coerceAtLeast(0))
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier
                .padding(top = 6.dp)
                .background(MyMuColors.surface.copy(alpha = 0.97f), RoundedCornerShape(14.dp))
                .border(1.dp, MyMuColors.border, RoundedCornerShape(14.dp))
                .padding(horizontal = 12.dp, vertical = 9.dp),
        ) {
            // Only the candidate ±1 ever compose — the lazy-page tuning iOS
            // needed for its full-transcript pager (c376a47) is built in here.
            SideChip(state, c - 1, leadingChevron = true)
            CenterChip(state, c, progress.value)
            SideChip(state, c + 1, leadingChevron = false)
        }
    }
}

/** A neighbor, dimmed. Tapping it steps there (and rewinds the countdown),
 * so the HUD is usable without further swiping. */
@Composable
private fun SideChip(state: AgentSwitcherState, index: Int, leadingChevron: Boolean) {
    if (index !in state.roster.indices) {
        // Keep the card symmetric at the roster's ends.
        Spacer(Modifier.width(84.dp))
        return
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.widthIn(max = 84.dp).clickable { state.tapStep(index) },
    ) {
        if (leadingChevron) {
            Icon(Icons.Outlined.ChevronLeft, contentDescription = null,
                tint = MyMuColors.mutedText, modifier = Modifier.size(14.dp))
        }
        Text(state.roster[index].displayName, color = MyMuColors.mutedText,
            style = MaterialTheme.typography.labelMedium,
            maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (!leadingChevron) {
            Icon(Icons.Outlined.ChevronRight, contentDescription = null,
                tint = MyMuColors.mutedText, modifier = Modifier.size(14.dp))
        }
    }
}

/** The candidate: harness logo + name + live status dot over the settle bar.
 * Tapping commits NOW — the advertised way to skip the delay. */
@Composable
private fun CenterChip(state: AgentSwitcherState, index: Int, progress: Float) {
    val agent = state.roster.getOrNull(index) ?: return
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(5.dp),
        modifier = Modifier.widthIn(min = 130.dp).clickable { state.settle() },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            agent.remoteSessionId?.let { Harness.fromSessionId(it) }?.let { HarnessBadge(it) }
            Text(agent.displayName, color = MyMuColors.text,
                style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.widthIn(max = 160.dp))
            Box(Modifier.size(6.dp).background(AgentStatus.color(agent), CircleShape))
        }
        // Centered shrink, like the iOS scaleEffect(anchor: .center) drain.
        Box(Modifier.width(110.dp).height(3.dp), contentAlignment = Alignment.Center) {
            Box(Modifier.fillMaxWidth(progress.coerceIn(0f, 1f)).fillMaxHeight()
                .background(MyMuColors.primary.copy(alpha = 0.9f), CircleShape))
        }
    }
}
