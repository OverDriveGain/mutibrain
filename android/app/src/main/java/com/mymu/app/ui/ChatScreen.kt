package com.mymu.app.ui

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.MediaStore
import android.util.Base64
import android.webkit.MimeTypeMap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.KeyboardArrowUp
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.PanTool
import androidx.compose.material.icons.outlined.Videocam
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.node.LayoutModifierNode
import androidx.compose.ui.node.ModifierNodeElement
import androidx.compose.ui.node.invalidateMeasurement
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.mymu.app.core.ApiClient
import com.mymu.app.core.AppLimits
import com.mymu.app.core.AppState
import com.mymu.app.core.ChatCacheStore
import com.mymu.app.core.ChatMessage
import com.mymu.app.core.ChatScroll
import com.mymu.app.core.ConversationRegistry
import com.mymu.app.core.DemoData
import com.mymu.app.core.DraftStore
import com.mymu.app.core.Haptics
import com.mymu.app.core.Harness
import com.mymu.app.core.ModelDisplay
import com.mymu.app.core.PermissionMode
import com.mymu.app.core.PermissionModeStore
import com.mymu.app.core.ProjectsStore
import com.mymu.app.core.RecentlyViewedStore
import com.mymu.app.core.RelayClient
import com.mymu.app.core.UiTestHooks
import kotlin.math.abs
import androidx.core.content.FileProvider
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** A file staged in the composer, ready to send as `options.images`. */
private data class PendingAttachment(val name: String, val dataUrl: String, val isImage: Boolean) {
    val isVideo: Boolean get() = dataUrl.startsWith("data:video/")
}

/** One transcript entry: a lone message, a run of consecutive tool activity
 * collapsed behind a summary row, or the live-turn indicator. */
@Immutable
private sealed interface DisplayItem {
    val id: String
    data class Single(val m: ChatMessage, val key: String = m.id) : DisplayItem { override val id get() = key }
    data class ToolGroup(override val id: String, val members: List<ChatMessage>) : DisplayItem
    /** Rendered INLINE, in the exact spot the reply will land — not a floating
     * overlay — so the pulsing ball visually turns into the streamed text. */
    data object PendingIndicator : DisplayItem { override val id get() = PENDING_ID }
}

private const val PENDING_ID = "pending-indicator"

/** Vertical padding around the transcript column (LazyColumn contentPadding). */
private val columnPadding = 14.dp
/** Spacing between rows. Turn separation adds to this inside MessageRow. */
private val rowSpacing = 14.dp

/**
 * One conversation: the transcript, the live turn, and the composer — port of
 * iOS ChatView (wave 6).
 *
 * Local-first (Manar, 2026-10-24): the screen does NOT own the conversation —
 * it borrows the [RelayClient] store from [ConversationRegistry], which keeps
 * transcript, turn state and (while a turn runs) the socket alive across
 * Back/re-open. Opening a chat renders what the app already holds in the very
 * first frame; the server only ever continues it (a quiet merge — never a
 * loader over readable content, never a wholesale swap).
 *
 * Send choreography (ChatGPT app): the sent bubble flies up out of the
 * composer and settles at the TOP of the viewport; the pulsing ball sits where
 * the reply will begin. The "message to the top" is pure geometry: the active
 * turn (sent bubble + everything after it) is ONE LazyColumn item padded to
 * `viewport − 2·columnPadding` by a min-height (the guide's `.active-turn
 * { min-height }`), so the ONE scroll rule — stay at the bottom while
 * following — lands the bubble at the top and the reply grows into the blank
 * space below with zero motion until it overflows. (iOS measures a trailing
 * spacer instead because its single ForEach cannot wrap a sub-range; a
 * LazyColumn item can.) The min-height is resolved inside layout, in the same
 * pass as the viewport — see [TurnViewport].
 */
@Composable
fun ChatScreen(target: ChatTarget, onBack: () -> Unit, onOpen: (Route) -> Unit,
               store: ProjectsStore? = null) {
    val token = target.tokenOverride ?: AppState.token.collectAsStateWithLifecycle().value
        ?: (if (target.isDemo) "demo" else return)
    // The store for this conversation: the one already alive (re-open,
    // mid-turn or not) or a fresh one seeded synchronously from the RAM
    // snapshot — either way the first rendered frame carries the transcript.
    val relay = remember(target) {
        ConversationRegistry.client(token = token, sessionId = target.sessionId, isRemote = target.isRemote,
            projectPath = target.projectPath, origin = target.origin)
    }
    val api = remember(target) { ApiClient(token, target.origin) }
    val context = LocalContext.current
    val reduceMotion = LocalReduceMotion()

    val messages by relay.messages.collectAsStateWithLifecycle()
    val isLoading by relay.isLoading.collectAsStateWithLifecycle()
    val statusText by relay.statusText.collectAsStateWithLifecycle()
    val pendingPermission by relay.pendingPermission.collectAsStateWithLifecycle()
    val revision by relay.revision.collectAsStateWithLifecycle()
    val turnStartedAt by relay.turnStartedAt.collectAsStateWithLifecycle()
    val turnTokens by relay.turnTokens.collectAsStateWithLifecycle()
    val usage by relay.context.collectAsStateWithLifecycle()
    val syncing by relay.syncing.collectAsStateWithLifecycle()
    val activeTurnUserId by relay.activeTurnUserId.collectAsStateWithLifecycle()
    val hasMore by relay.hasMore.collectAsStateWithLifecycle()

    var permissionMode by remember(target) { mutableStateOf(PermissionModeStore.load(target.sessionId)) }
    var model by remember(target) { mutableStateOf<String?>(null) }
    var modelOptions by remember(target) { mutableStateOf<List<ApiClient.ModelOption>>(emptyList()) }
    var historyError by remember { mutableStateOf<String?>(null) }
    var loadingOlder by remember { mutableStateOf(false) }
    var expandedGroups by remember { mutableStateOf<Set<String>>(emptySet()) }
    // Follow intent, bottom contact, finger scrolling, the send-glide window:
    // a plain box, not Compose state — see ScrollGeometry.
    val geo = remember { ScrollGeometry() }
    val jumpButton = remember { JumpButtonState() }
    // Scroll choreography (port of iOS ChatView + ChatScrollTuning):
    var loadingHistory by remember { mutableStateOf(!target.isDemo && !relay.hasLoadedOnce) }
    // False until the opening transcript is pinned to the bottom — content is
    // hidden (loader shown) so the settling scroll is never visible.
    var revealed by remember { mutableStateOf(false) }
    // Bumped by the composer right before a send; drives the one send glide.
    var sendPin by remember { mutableIntStateOf(0) }
    // The active turn's geometry is on: the sent bubble (relay.activeTurnUserId)
    // is kept at the top of the viewport for the turn, and stays there after it
    // ends until the next send (ChatGPT keeps the space; collapsing it at turn
    // end would yank the reply down). True from a send in this screen, or on
    // open when the turn is still running.
    var anchorTurn by remember { mutableStateOf(relay.isLoading.value && relay.activeTurnUserId.value != null) }
    /** The VIEW side of a send — re-arm following, switch the active-turn
     * geometry on, fire the glide — shared by the composer and the DEBUG
     * stream simulation (iOS ChatView.beginSend). */
    fun beginSend() { geo.followMode = true; anchorTurn = true; sendPin += 1 }
    // Rows present when the screen opened (or already shown once) never
    // replay their insertion transition — only rows that ARRIVE animate, like
    // SwiftUI's transition-on-insert. Seeded from the store so a warm re-open
    // paints its transcript still.
    val knownIds = remember {
        relay.messages.value.flatMapTo(mutableSetOf<String>()) { listOfNotNull(it.id, it.clientId) }
    }

    // Lay the FIRST frame out at the end of the transcript (Compose clamps an
    // index past the item count to the last item and fills the viewport
    // backwards), so a warm re-open makes bottom contact — and reveals — on
    // its first layout instead of after the 50ms settle tap: iOS lays out at
    // the bottom and reveals in its first frame; a fresh list state starting
    // at item 0 painted the loader for a few frames first (emulator pass
    // 2026-10-24).
    val listState = rememberLazyListState(initialFirstVisibleItemIndex = relay.messages.value.size + 1)
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    val jumpThresholdPx = with(density) { ChatScroll.jumpButtonThresholdDp.dp.toPx() }
    val disarmDragPx = with(density) { ChatScroll.disarmDragDp.dp.toPx() }
    val keyboardDeltaPx = with(density) { ChatScroll.keyboardDeltaDp.dp.toPx() }
    val settleTolerancePx = with(density) { ChatScroll.settleToleranceDp.dp.toPx() }

    // Scroll curves (ChatScrollTuning parity). Reduce Motion: no travel.
    val followSpec: AnimationSpec<Float> = remember(reduceMotion) {
        if (reduceMotion) snap() else tween(ChatScroll.followDurationMs, easing = EaseOut)
    }
    val sendSpec: AnimationSpec<Float> = remember(reduceMotion) {
        if (reduceMotion) snap() else spring(ChatScroll.sendSpringDamping, ChatScroll.sendSpringStiffness)
    }
    val jumpSpec: AnimationSpec<Float> = remember(reduceMotion) {
        if (reduceMotion) snap() else tween(ChatScroll.jumpDurationMs, easing = EaseOut)
    }
    val keyboardSpec: AnimationSpec<Float> = remember(reduceMotion) {
        if (reduceMotion) snap() else tween(ChatScroll.keyboardOpenDurationMs, easing = EaseOut)
    }

    // Only messages that actually paint pixels (empty rows still cost spacing).
    val visibleMessages = remember(revision) {
        messages.filter { m ->
            when (m.kind) {
                "text" -> !m.bodyText.isBlank() || (m.images?.isNotEmpty() == true)
                "tool_use", "error" -> true
                "tool_result", "thinking" -> !(m.content ?: "").isBlank()
                else -> false
            }
        }
    }

    // Group runs of ≥3 consecutive tool/thinking rows; the live tail stays
    // ungrouped while a turn runs (collapsing live work looks stalled). The
    // live turn's indicator is the transcript's own last row: the ball where
    // the reply is about to appear, then (as rows land) the ball under them.
    val displayItems = remember(revision, isLoading, expandedGroups, loadingHistory, revealed) {
        val groupable = setOf("tool_use", "tool_result", "thinking")
        val out = mutableListOf<DisplayItem>()
        var run = mutableListOf<ChatMessage>()
        fun flush(isTail: Boolean) {
            if (run.isEmpty()) return
            val liveTail = isTail && isLoading
            if (run.size >= 3 && !liveTail) out.add(DisplayItem.ToolGroup("tg-${run[0].id}", run.toList()))
            else run.forEach { out.add(DisplayItem.Single(it)) }
            run = mutableListOf()
        }
        for (m in visibleMessages) {
            if (m.kind in groupable) run.add(m) else { flush(false); out.add(DisplayItem.Single(m)) }
        }
        flush(true)
        if (isLoading && !loadingHistory && revealed) out.add(DisplayItem.PendingIndicator)
        // Backstop (iOS e0528a4): LazyColumn throws on a repeated key, so a
        // duplicate id in the transcript gets a suffix instead of a crash.
        val seen = HashMap<String, Int>()
        out.map { item ->
            val n = seen.merge(item.id, 1, Int::plus)!!
            when {
                n == 1 -> item
                item is DisplayItem.Single -> item.copy(key = "${item.id}#$n")
                item is DisplayItem.ToolGroup -> item.copy(id = "${item.id}#$n")
                else -> item
            }
        }
    }

    // The active turn = the anchor bubble and everything after it. Rendered as
    // ONE item with a viewport-sized min-height (see the class comment); the
    // rows before it stay individual items.
    val anchorIndex = remember(displayItems, anchorTurn, activeTurnUserId) {
        if (!anchorTurn || activeTurnUserId == null) -1
        else displayItems.indexOfFirst { it is DisplayItem.Single && it.m.id == activeTurnUserId }
    }
    val headItems = if (anchorIndex >= 0) displayItems.subList(0, anchorIndex) else displayItems
    val turnItems = if (anchorIndex >= 0) displayItems.subList(anchorIndex, displayItems.size) else emptyList()
    // Keyed by the bubble's BIRTH id so the echo's id rebind doesn't rebuild
    // the whole turn (the row inside swaps instantly, see knownIds).
    val turnKey = (turnItems.firstOrNull() as? DisplayItem.Single)?.m?.let { "turn-${it.clientId ?: it.id}" }

    val lastAssistantTextId = remember(revision) {
        messages.lastOrNull { it.kind == "text" && it.role != "user" }?.id
    }

    // The screen only BORROWS the client: entering/leaving tells it whether
    // anyone is looking (presence, grace disconnect) — never tears it down.
    DisposableEffect(relay) {
        relay.viewAppeared()
        onDispose { relay.viewDisappeared() }
    }

    // Record the open in "last seen" (real ids only; rebind covers new chats).
    LaunchedEffect(relay) {
        if (target.isDemo) return@LaunchedEffect
        if (target.sessionId.isNotEmpty()) {
            RecentlyViewedStore.record(target.sessionId, target.projectId, target.isRemote,
                target.title, target.projectPath)
        }
        relay.onSessionIdRebound = { newId ->
            RecentlyViewedStore.record(newId, target.projectId, target.isRemote,
                target.title, target.projectPath)
        }
    }

    // Open path + model catalogue + attachment cap + status poll (iOS start()).
    LaunchedEffect(relay) {
        if (target.isDemo) {
            // Offline demo: canned transcript, no network, never written to
            // the real cache. `offline` keeps the store off the socket and
            // the history routes for good — a simulated turn's `complete`
            // must not reconcile against the real server.
            relay.persistenceEnabled = false
            relay.offline = true
            if (relay.messages.value.isEmpty()) {
                relay.setHistory(UiTestHooks.demoTranscript() ?: DemoData.messages)
            }
            modelOptions = DemoData.modelOptions
            model = DemoData.defaultModel
            loadingHistory = false
            // DEBUG stream simulation (UI tests): a whole SEND 1.2s after the
            // chat opens — the view choreography plus a fake turn through the
            // relay's real inbound path (iOS ChatView.start, MYMU_DEMO_STREAM).
            UiTestHooks.demoStream?.let { sim ->
                delay(1200)
                beginSend()
                relay.simulateTurn(UiTestHooks.simPrompt,
                    if (sim == "short") UiTestHooks.simReplyShort else UiTestHooks.simReply,
                    wholeBlock = sim == "block")
            }
            return@LaunchedEffect
        }
        launch { AppLimits.refresh(api) }
        launch {
            // Per-provider catalogue: an OpenCode/Codex conversation must not be
            // offered the Claude list. Prefix first, originating list's provider
            // second (same resolution as the header badge).
            val harness = Harness.from(relay.sessionId, target.provider)?.raw ?: "claude"
            try {
                modelOptions = api.models(provider = harness).first
            } catch (_: Exception) {}
            if (relay.sessionId.isNotEmpty()) {
                api.activeModel(provider = harness, sessionId = relay.sessionId)?.let { model = it }
            }
        }
        // Use the relay's CURRENT id — a new conversation starts with "" and
        // gets rebound by session_created; tab-return re-runs then fetch the
        // real id.
        val sid = relay.sessionId
        when {
            sid.isEmpty() -> {
                loadingHistory = false
                relay.connect()
            }
            relay.hasLoadedOnce -> {
                // LOCAL-FIRST re-open: the store holds this conversation
                // exactly as it was left (the same instance, or re-seeded from
                // its snapshot). It is already on screen. Re-attach the stream
                // — the server replays what this device missed, absorbed
                // against what's here — and let a quiet merge catch anything
                // older than the replay buffer. Nothing hides, nothing swaps.
                loadingHistory = false
                relay.ensureConnected()
            }
            else -> {
                // Cold open: disk snapshot first (instant, if one exists), then
                // the fetch merges in whatever is newer.
                if (target.isRemote && relay.messages.value.isEmpty()) {
                    ChatCacheStore.load(sid)?.let { cached ->
                        relay.adoptSnapshot(cached)
                        anchorTurn = relay.isLoading.value && relay.activeTurnUserId.value != null
                        loadingHistory = false
                    }
                }
                try {
                    relay.adoptHistory(api.history(sid))
                } catch (e: Exception) {
                    // With a cached transcript on screen, a failed refresh must
                    // not slap an error banner over readable content — the
                    // socket's own reconnect handling narrates connectivity.
                    if (relay.messages.value.isEmpty()) historyError = e.message
                }
                loadingHistory = false
                relay.connect()
            }
        }
        // Agent already working when the chat opens (or a turn starts
        // silently): check the live status endpoint now and every 10s as a
        // backstop. Also the authority that clears a "working" restored from a
        // snapshot when the agent has in fact finished.
        if (!target.isRemote) return@LaunchedEffect
        while (true) {
            relay.syncRunningState(api)
            delay(10_000)
        }
    }

    // Returning from the background: the killed socket still LOOKS open —
    // reconnect + reconcile + status sync right away. GOING to background:
    // tell the server we stopped watching, immediately (until the server's
    // presence TTL expired a reply would be push-SUPPRESSED).
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, relay) {
        val observer = LifecycleEventObserver { _, event ->
            if (target.isDemo) return@LifecycleEventObserver
            when (event) {
                Lifecycle.Event.ON_RESUME -> {
                    relay.ensureConnected()
                    scope.launch { relay.syncRunningState(api) }
                }
                Lifecycle.Event.ON_STOP -> relay.releasePresence()
                else -> {}
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // Pin helpers. The last item is the newest row (or the active-turn box);
    // item 0 is the load-earlier slot. scrollToItem lands on the item's TOP —
    // for a last item taller than the leftover space that sits above the true
    // bottom, so both helpers clamp the remaining distance afterwards.
    fun bottomDriftPx(): Float? {
        val info = listState.layoutInfo
        val lastIdx = info.totalItemsCount - 1
        val last = info.visibleItemsInfo.lastOrNull { it.index == lastIdx } ?: return null
        // Measured against where the bottom RESTS — the content end, above
        // the bottom column padding — not the raw viewport edge: a pin that
        // scrolled exactly this residue used to tuck the last row into the
        // padding, flush against the composer.
        return ((last.offset + last.size) - (info.viewportEndOffset - info.afterContentPadding)).toFloat()
    }
    suspend fun pinToBottom() {
        val lastIdx = listState.layoutInfo.totalItemsCount - 1
        if (lastIdx < 0) return
        // Bottom edge on screen: scroll exactly the residue, and NOTHING when
        // it already rests on the viewport bottom — the common case now that
        // the active turn's box resizes with the viewport inside layout
        // (iOS c7decec: "only the residue the blank space can't cover").
        bottomDriftPx()?.let { drift ->
            if (drift >= 0f) { if (drift > 0f) listState.scrollBy(drift); return }
        }
        listState.scrollToItem(lastIdx)
        bottomDriftPx()?.let { if (it > 0f) listState.scrollBy(it) }
    }
    /** Eased travel to the bottom with the given curve (follow / send / jump). */
    suspend fun glidePinToBottom(spec: AnimationSpec<Float>) {
        val lastIdx = listState.layoutInfo.totalItemsCount - 1
        if (lastIdx < 0) return
        val drift = bottomDriftPx()
        if (drift != null) {
            if (drift > 0f) listState.animateScrollBy(drift, spec)
            return
        }
        listState.animateScrollToItem(lastIdx)
        bottomDriftPx()?.let { if (it > 0f) listState.animateScrollBy(it, spec) }
    }
    // Pin the viewport to the bottom across the frames layout needs to resolve
    // real row heights (a single scroll lands short). Un-animated by design:
    // used where the user must NOT see travel (history load, keyboard dismiss).
    suspend fun settleToBottom() {
        pinToBottom()
        var elapsed = 0L
        for (tap in ChatScroll.settleTapsMs) {
            delay(tap - elapsed); elapsed = tap
            if (geo.followMode && !geo.userScrolling) pinToBottom()
        }
    }

    // At-bottom tracking (iOS BottomEdgeTracker): at bottom ⇔ the content's
    // bottom edge sits within the threshold of the viewport bottom.
    // Before the first layout pass nothing is at the bottom yet — a warm
    // re-open (no history loader) must not reveal until the settle has pinned.
    val atBottom by remember {
        derivedStateOf {
            val info = listState.layoutInfo
            if (info.totalItemsCount == 0) return@derivedStateOf false
            val last = info.visibleItemsInfo.lastOrNull() ?: return@derivedStateOf false
            last.index >= info.totalItemsCount - 1 &&
                last.offset + last.size <= info.viewportEndOffset + jumpThresholdPx
        }
    }
    // Read through snapshotFlow, never in composition: crossing the bottom
    // edge used to recompose the whole chat (iOS c7decec moved atBottom /
    // showJumpButton out of @State for the same reason). Only the ↓ button
    // recomposes now.
    LaunchedEffect(Unit) {
        snapshotFlow { atBottom }.collectLatest { near ->
            geo.atBottom = near
            if (near) {
                geo.followMode = true
                // Reveal on first bottom contact once the history has landed.
                if (!loadingHistory) revealed = true
                jumpButton.visible = false
            } else {
                // Debounced ↓ button: only SHOW once the bottom has stayed lost
                // for the appear delay — a send/stream append loses the bottom
                // for the beat before the eased follow catches up.
                delay(ChatScroll.jumpButtonAppearDelayMs)
                if (!geo.atBottom) jumpButton.visible = true
            }
        }
    }

    // The ball's insertion transition is per turn: forget it once the turn is
    // over so the next turn's ball arrives animated again.
    LaunchedEffect(isLoading) { if (!isLoading) knownIds.remove(PENDING_ID) }
    // Everything that lands BEFORE the reveal (snapshot, opening fetch) is the
    // initial transcript — never animated, even the rows the LazyColumn only
    // composes once they scroll into view.
    LaunchedEffect(revision, revealed) {
        if (revealed) return@LaunchedEffect
        for (m in messages) { knownIds += m.id; m.clientId?.let { knownIds += it } }
    }

    // "Stop following" = the USER moved the transcript toward older content by
    // more than a wobble (24dp, same threshold as iOS) — judged on the scroll
    // the list actually APPLIED during a finger scroll or its fling (iOS
    // c7decec: scroll-phase displacement), not on raw finger travel: a drag
    // pinned at the top edge, or a touch while the stream grows the content,
    // doesn't mean "I'm reading back". Programmatic scrolls never pass
    // through nested scroll, so only the user's own displacement counts.
    val scrollIntent = remember {
        object : NestedScrollConnection {
            override fun onPostScroll(consumed: androidx.compose.ui.geometry.Offset,
                                      available: androidx.compose.ui.geometry.Offset,
                                      source: NestedScrollSource): androidx.compose.ui.geometry.Offset {
                geo.userDisplacement += consumed.y
                if (geo.userDisplacement > disarmDragPx) geo.followMode = false
                return androidx.compose.ui.geometry.Offset.Zero
            }
            override suspend fun onPreFling(available: Velocity): Velocity {
                geo.flinging = true
                return Velocity.Zero
            }
            override suspend fun onPostFling(consumed: Velocity, available: Velocity): Velocity {
                geo.flinging = false
                return Velocity.Zero
            }
        }
    }
    // The finger phase (iOS scroll phase interacting): a new drag starts a new
    // displacement run; while it lasts (and through its fling) programmatic
    // pins stand down instead of fighting the finger.
    LaunchedEffect(listState) {
        listState.interactionSource.interactions.collect { i ->
            when (i) {
                is DragInteraction.Start -> { geo.dragging = true; geo.userDisplacement = 0f }
                is DragInteraction.Stop, is DragInteraction.Cancel -> geo.dragging = false
            }
        }
    }
    // A fling cut short (a pin, a tap) may never report onPostFling.
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }.collect { if (!it) geo.flinging = false }
    }

    // Follow content mutations (stream chunks included) with a beat, then an
    // EASED scroll — never instantly. The beat lets the appended row lay out
    // so the scroll targets a bottom that stopped moving; bursts coalesce into
    // one scheduled scroll. While the active turn still fits its box the
    // bottom hasn't moved and this is a no-op — the reply grows in place.
    LaunchedEffect(relay) {
        var pending = false
        relay.revision.collect {
            if (loadingHistory || !geo.followMode || pending) return@collect
            if (System.currentTimeMillis() < geo.glideUntil) return@collect
            pending = true
            scope.launch {
                delay(ChatScroll.followDelayMs)
                pending = false
                if (!geo.canPin()) return@launch
                glidePinToBottom(followSpec)
                delay(ChatScroll.followCorrectionMs)
                if (geo.canPin()) pinToBottom()
            }
        }
    }

    // Send: one soft glide to the bottom — which, thanks to the active turn's
    // min-height box, IS the sent bubble at the top of the viewport. A beat
    // first so the bubble and the box have real layout. One silent clamp after
    // the glide, and only for SMALL drift (composer collapse, keyboard insets);
    // anything bigger is real content and belongs to the eased follow — a
    // silent snap across a real row is what read as "scrolls, disappears,
    // reappears" (Manar).
    LaunchedEffect(sendPin) {
        if (sendPin == 0) return@LaunchedEffect
        geo.glideUntil = System.currentTimeMillis() + ChatScroll.sendSettleMs
        scope.launch { delay(ChatScroll.sendDelayMs); glidePinToBottom(sendSpec) }
        scope.launch {
            delay(ChatScroll.sendSettleMs)
            if (!geo.followMode || geo.userScrolling) return@launch
            val drift = bottomDriftPx()
            when {
                drift == null -> glidePinToBottom(followSpec)
                abs(drift) <= settleTolerancePx -> pinToBottom()
                drift > 0f -> glidePinToBottom(followSpec)
            }
        }
    }

    // Initial jump after history load: re-pin across several frames while the
    // transcript stays INVISIBLE (loader shown) — the user never watches the
    // view scroll fast to the bottom; it appears already sitting on the last
    // message. A hard fallback reveals even if bottom contact never reports.
    LaunchedEffect(loadingHistory) {
        if (loadingHistory) return@LaunchedEffect
        scope.launch { settleToBottom() }
        delay(ChatScroll.revealFallbackMs)
        revealed = true
    }

    // Phantom-gap guard: the content bottom may never REST above the viewport
    // bottom while there is enough content to fill the screen (a reconcile
    // shrinking the transcript, media rows resizing). Debounced: only a gap
    // that survives ~half a second is real; the repair is a silent clamp.
    val gapSlopPx = with(density) { 8.dp.toPx() }
    val hasPhantomGap by remember {
        derivedStateOf {
            val info = listState.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull() ?: return@derivedStateOf false
            if (last.index != info.totalItemsCount - 1) return@derivedStateOf false
            val overflows = info.visibleItemsInfo.firstOrNull()?.let { first ->
                first.index > 0 || first.offset < info.viewportStartOffset
            } ?: false
            overflows && last.offset + last.size < info.viewportEndOffset - gapSlopPx
        }
    }
    LaunchedEffect(Unit) {
        var repair: Job? = null
        snapshotFlow { hasPhantomGap }.collect { gap ->
            repair?.cancel()
            if (!gap) return@collect
            repair = scope.launch {
                delay(ChatScroll.gapRepairDebounceMs)
                if (!hasPhantomGap) return@launch
                pinToBottom()
                delay(ChatScroll.gapRepairConfirmMs)
                if (hasPhantomGap) pinToBottom()
            }
        }
    }

    // Row insertion transitions (ChatScrollTuning parity). Applied only to
    // rows that ARRIVE while the screen is up — see knownIds.
    fun <T> insertSpring(): FiniteAnimationSpec<T> =
        spring(ChatScroll.insertSpringDamping, ChatScroll.insertSpringStiffness)
    val userBubbleEnter: EnterTransition = remember(density) {
        val dy = with(density) { ChatScroll.userBubbleOffsetDp.dp.roundToPx() }
        slideInVertically(insertSpring<IntOffset>()) { dy } + fadeIn(insertSpring()) +
            scaleIn(insertSpring(), initialScale = ChatScroll.userBubbleScale,
                transformOrigin = TransformOrigin(1f, 1f))
    }
    val assistantRowEnter: EnterTransition = remember(density) {
        val dy = with(density) { ChatScroll.assistantRowOffsetDp.dp.roundToPx() }
        fadeIn(insertSpring()) + slideInVertically(insertSpring<IntOffset>()) { dy }
    }
    val pendingEnter: EnterTransition = remember {
        fadeIn(insertSpring()) + scaleIn(insertSpring(), initialScale = ChatScroll.pendingScale,
            transformOrigin = TransformOrigin(0f, 0.5f))
    }
    /** True exactly once per row id: the first time it is composed AFTER the
     * screen revealed. Rows seeded from the store, re-keyed rows (clientId)
     * and rows scrolled back into view never animate. */
    fun markNew(ids: List<String>): Boolean {
        val new = revealed && !reduceMotion && ids.none { it in knownIds }
        knownIds.addAll(ids)
        return new
    }

    /** One transcript row, with the transition that makes it ARRIVE the way the
     * choreography wants: the sent bubble flies up from the composer, the ball
     * scales in, a reply row fades in where the ball was. */
    val rowEnv = remember(target, token) { RowEnv(target.projectId, token, target.origin) }
    val toggleGroup: (String) -> Unit = remember {
        { id -> expandedGroups = if (id in expandedGroups) expandedGroups - id else expandedGroups + id }
    }
    @Composable
    fun transcriptRow(item: DisplayItem) {
        when (item) {
            is DisplayItem.Single -> {
                val m = item.m
                val isNew = remember(m.id) { markNew(listOfNotNull(m.id, m.clientId)) }
                TranscriptMessageRow(m, isNew, if (m.role == "user") userBubbleEnter else assistantRowEnter,
                    rowEnv, showActions = m.id == lastAssistantTextId)
            }
            is DisplayItem.ToolGroup -> {
                val isNew = remember(item.id) { markNew(item.members.map { it.id }) }
                TranscriptGroupRow(item, isNew, assistantRowEnter, rowEnv,
                    expanded = item.id in expandedGroups, onToggle = toggleGroup)
            }
            DisplayItem.PendingIndicator -> {
                val isNew = remember { markNew(listOf(PENDING_ID)) }
                RowEnter(isNew, pendingEnter) {
                    PendingIndicatorRow(statusText, messages, turnStartedAt, turnTokens)
                }
            }
        }
    }

    // The tab bar is hidden in chat, so nothing else pads the gesture nav bar:
    // without this the pill's bottom edge sat under the home indicator.
    // navigationBars first, then ime — Compose subtracts the consumed inset,
    // so with the keyboard up the total is exactly the keyboard height.
    Column(Modifier.fillMaxSize().navigationBarsPadding().imePadding()) {
        ChatTopBar(target, relay.sessionId, usage?.usedTokens, syncing, permissionMode,
            onMode = {
                permissionMode = it
                PermissionModeStore.save(it, relay.sessionId.ifEmpty { target.sessionId })
                Haptics.send()
            },
            model = model, modelOptions = modelOptions,
            onModel = { model = it; Haptics.send() },
            onBack = onBack,
            onOpen = onOpen,
            visibleMessagesProvider = { visibleMessages },
        )

        if (historyError != null) {
            Text(historyError ?: "", color = MyMuColors.danger,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
        }

        // Horizontal swipe → the agent-switcher HUD (agent chats only). Lives
        // on the transcript, not the whole screen, so composer drags never
        // raise it.
        val switcher = rememberAgentSwitcherState(store, target)
        val turnViewport = remember(density) { TurnViewport(with(density) { (columnPadding * 2).roundToPx() }) }
        // Keyboard/composer residue while riding the bottom: move the list
        // position by it inside the same measure (requestScrollToItem is read
        // by the list's measure that runs right after), instead of a pin one
        // frame later from onSizeChanged.
        turnViewport.onResidue = { residue ->
            if (geo.atBottom && geo.canPin()) Snapshot.withoutReadObservation {
                listState.requestScrollToItem(listState.firstVisibleItemIndex,
                    listState.firstVisibleItemScrollOffset + residue)
            }
        }

        Box(
            Modifier.weight(1f).fillMaxWidth().onSizeChanged { size ->
                // Viewport height changes = keyboard open/close or the composer
                // growing a line. Same three-branch pinning as iOS ChatView.
                // The handlers' copy only (a plain field): the active turn's
                // box sizes itself from the list INSIDE layout, so nothing
                // here recomposes the chat on keyboard frames.
                val prev = geo.viewportHeightPx
                geo.viewportHeightPx = size.height
                val delta = size.height - prev
                if (prev == 0 || !geo.followMode || abs(delta) <= 8) return@onSizeChanged
                geo.correction?.cancel()
                geo.correction = when {
                    // Keyboard OPENING: one animated pin riding the system
                    // animation, then a silent correction once it settles —
                    // repeated instant snaps mid-animation read as flaky.
                    // With the active turn resting on the bottom this is a
                    // no-op: its box shrank in the same pass, nothing scrolls.
                    delta < -keyboardDeltaPx -> scope.launch {
                        glidePinToBottom(keyboardSpec)
                        delay(ChatScroll.keyboardOpenCorrectionMs)
                        if (geo.canPin()) pinToBottom()
                    }
                    // Keyboard DISMISSING: a single pin loses the race against
                    // the inset animation — re-pin across the frames.
                    delta > keyboardDeltaPx -> scope.launch { settleToBottom() }
                    // Composer grew/shrank a line or two (typing wraps, chips,
                    // the pill changing shape) — and every frame of the IME
                    // inset animation: one instant pin plus ONE coalesced
                    // settle correction. During the send glide, stand down.
                    else -> if (geo.canPin()) scope.launch {
                        pinToBottom()
                        delay(ChatScroll.composerCorrectionMs)
                        if (geo.canPin()) pinToBottom()
                    } else null
                }
            },
        ) {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize().reportTurnViewport(turnViewport).nestedScroll(scrollIntent)
                    .agentSwitcherGesture(switcher)
                    // Hidden until pinned to the bottom (the reveal) — never
                    // let the user watch the opening settle scroll.
                    .alpha(if (revealed) 1f else 0f),
                contentPadding = PaddingValues(vertical = columnPadding),
                // Bottom-align SHORT transcripts (iOS: a few messages rest on
                // the composer instead of floating at the top); overflowing
                // content stacks normally from the top.
                verticalArrangement = remember {
                    object : Arrangement.Vertical {
                        override val spacing = rowSpacing
                        override fun androidx.compose.ui.unit.Density.arrange(
                            totalSize: Int, sizes: IntArray, outPositions: IntArray,
                        ) {
                            val gap = rowSpacing.roundToPx()
                            val content = sizes.sum() + gap * (sizes.size - 1).coerceAtLeast(0)
                            var y = (totalSize - content).coerceAtLeast(0)
                            sizes.forEachIndexed { i, size ->
                                outPositions[i] = y
                                y += size + gap
                            }
                        }
                    }
                },
            ) {
                item(key = "load-earlier") {
                    if (hasMore == true && !loadingHistory) {
                        // Reading column (tablet/foldable): cap at a comfortable
                        // line length instead of letting the row stretch
                        // edge-to-edge on wide screens; a no-op on phones.
                        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                        Row(
                            Modifier.widthIn(max = MyMuLayout.maxContentWidth).fillMaxWidth()
                                .padding(vertical = 4.dp),
                            horizontalArrangement = Arrangement.Center,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            TextButton(
                                enabled = !loadingOlder,
                                onClick = {
                                    scope.launch {
                                        if (loadingOlder || relay.sessionId.isEmpty()) return@launch
                                        loadingOlder = true
                                        try {
                                            val h = api.history(relay.sessionId, limit = 200,
                                                offset = relay.messages.value.size)
                                            val known = relay.messages.value.map { it.id }.toSet()
                                            val older = h.messages.filter { it.id !in known }
                                            // Content added ABOVE the viewport must
                                            // not replay insertion transitions.
                                            older.forEach { knownIds += it.id }
                                            if (older.isNotEmpty()) relay.prependHistory(older)
                                            relay.hasMore.value = (h.hasMore ?: false) && older.isNotEmpty()
                                        } catch (e: Exception) {
                                            historyError = e.message
                                        }
                                        loadingOlder = false
                                    }
                                },
                            ) {
                                if (loadingOlder) {
                                    CircularProgressIndicator(Modifier.size(12.dp),
                                        color = MyMuColors.primary, strokeWidth = 2.dp)
                                } else {
                                    Icon(Icons.Outlined.KeyboardArrowUp, contentDescription = null,
                                        tint = MyMuColors.primary, modifier = Modifier.size(14.dp))
                                }
                                Spacer(Modifier.width(6.dp))
                                Text(if (loadingOlder) "Loading…" else "Load earlier messages",
                                    color = MyMuColors.primary, style = MaterialTheme.typography.bodySmall)
                            }
                        }
                        }
                    }
                }
                items(headItems, key = { it.id }) { item ->
                    // Same reading-column cap as the load-earlier row above —
                    // horizontal only, the vertical bottom-align Arrangement
                    // below is untouched.
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                    Box(Modifier.widthIn(max = MyMuLayout.maxContentWidth).fillMaxWidth()) {
                        transcriptRow(item)
                    }
                    }
                }
                if (turnKey != null) {
                    // The active turn: sent bubble + everything after it, padded
                    // to the viewport by a min-height so ONE scroll rule (stay
                    // at the bottom) lands the bubble at the top and the reply
                    // grows into the blank space with zero motion.
                    item(key = turnKey) {
                        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                        Column(
                            Modifier.widthIn(max = MyMuLayout.maxContentWidth).fillMaxWidth()
                                // The min-height, sized INSIDE layout from the
                                // list's own measure (see TurnViewport).
                                .turnMinHeight(turnViewport),
                            verticalArrangement = Arrangement.spacedBy(rowSpacing),
                        ) {
                            for (item in turnItems) transcriptRow(item)
                        }
                        }
                    }
                }
            }

            // Loader while the transcript is hidden (history loading + the
            // settling scroll) — the chat appears already at the bottom.
            if (!revealed) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { MyMuLoader() }
            }

            JumpToBottomButton(jumpButton, revealed, reduceMotion,
                modifier = Modifier.align(Alignment.BottomEnd),
                onJump = {
                    geo.followMode = true
                    // Eased travel, then settle: the motion is the point — a
                    // cut leaves the user unsure whether the transcript moved
                    // or reloaded. The settle clamps residual drift.
                    scope.launch { glidePinToBottom(jumpSpec); settleToBottom() }
                })

            AgentSwitcherHud(switcher)
        }

        // Permission prompt — the one thing that must never be missable.
        val perm = pendingPermission
        if (perm != null && perm.requestId != null) {
            Column(
                Modifier.fillMaxWidth().background(MyMuColors.surface).padding(14.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.PanTool, contentDescription = null,
                        tint = MyMuColors.primary, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Permission: ${perm.toolName ?: "tool"}", color = MyMuColors.text,
                        fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.bodyMedium)
                }
                Row(Modifier.padding(top = 8.dp)) {
                    TextButton(onClick = { relay.answerPermission(perm.requestId!!, false) }) {
                        Text("Deny", color = MyMuColors.mutedText)
                    }
                    Spacer(Modifier.width(8.dp))
                    TextButton(
                        onClick = { relay.answerPermission(perm.requestId!!, true) },
                        modifier = Modifier.background(MyMuColors.primary, RoundedCornerShape(8.dp)),
                    ) {
                        Text("Allow", color = MyMuColors.background, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }

        ChatComposer(
            relay = relay,
            isDemo = target.isDemo,
            placeholder = if (target.isRemote) "Ask ${target.title}" else "Ask anything",
            pinnedHostNeedingLogin = target.pinnedHostNeedingLogin,
            permissionMode = permissionMode,
            model = model,
            // DraftStore identity (iOS ChatView): the AGENT for remote chats —
            // session ids rotate on agent restarts and the draft belongs to the
            // agent, not the socket — the session for local ones.
            draftKey = if (target.isRemote) target.projectId else target.sessionId.ifEmpty { target.projectId },
            onWillSend = { beginSend() },
        )
    }
}


/**
 * The scroll machinery's state, kept OUT of Compose state on purpose (iOS
 * c7decec ScrollGeometry): it changes on scroll frames, keyboard frames and
 * stream chunks, and only the handlers read it. Writing any of it never
 * recomposes anything — these used to be `mutableStateOf`s, and the ones read
 * in composition (atBottom, showJumpButton, the viewport height) recomposed
 * the whole chat on every bottom crossing and every keyboard frame.
 */
private class ScrollGeometry {
    /** The user's INTENT to ride the bottom. Only reading back (see
     * userDisplacement) turns it off; bottom contact, sending, or the ↓ button
     * turn it back on. */
    var followMode = true
    /** Position: the content's bottom edge is within the threshold. */
    var atBottom = false
    /** The finger is moving the transcript (drag, or the fling it released). */
    var dragging = false
    var flinging = false
    val userScrolling get() = dragging || flinging
    /** Net scroll the list applied since the current drag began; positive =
     * toward older content. */
    var userDisplacement = 0f
    /** While now < glideUntil (send + sendSettleMs) the instant pins and the
     * stream follow stand down, so the one send glide is actually visible. */
    var glideUntil = 0L
    /** The handlers' copy of the transcript viewport height. */
    var viewportHeightPx = 0
    /** One coalesced viewport-change pin — a burst of keyboard frames
     * schedules ONE, not one per frame. */
    var correction: Job? = null

    fun canPin() = followMode && !userScrolling && System.currentTimeMillis() >= glideUntil
}

/**
 * The transcript viewport handed from the list's measure to the active turn's
 * min-height in the SAME layout pass (the Compose form of iOS c7decec's
 * containerRelativeFrame).
 *
 * The active turn must span column top padding → bubble → rows → (blank) →
 * column bottom padding = the viewport, so resting at the bottom puts the
 * bubble one column padding below the top edge. Fed from onSizeChanged (the
 * old way) that min-height landed one pass late: on keyboard close the list
 * first filled the grown viewport by shifting the transcript DOWN, the late
 * box then grew and the pins pulled it back — the sent bubble dipped 186px
 * (71dp) on close and jumped 115px (44dp) up on open (pixel_7, 2026-10-29).
 * LazyItemScope.fillParentMaxHeight is a snapshot state written during the
 * list's measure, so it is late the same way (measured: the open stayed put,
 * but the close still flashed the bubble down for a frame or two).
 * Here the list's modifier measures first, and when the height changed it
 * invalidates the turn box's measurement directly — the list then remeasures
 * the box in that very pass, the box shrinks/grows with the viewport, and
 * nothing scrolls.
 */
private class TurnViewport(val verticalPaddingPx: Int) {
    var heightPx = 0
    var turnNode: TurnMinHeightNode? = null
    val minTurnHeightPx get() = (heightPx - verticalPaddingPx).coerceAtLeast(0)
    /** The viewport shrank by more than the active turn's blank space can
     * absorb: called from the list's measure, BEFORE the list lays out, with
     * that residue — so the bottom-keeping scroll lands in the same pass too
     * (otherwise the last row sits under the keyboard for a frame). */
    var onResidue: ((Int) -> Unit)? = null
}

private fun Modifier.reportTurnViewport(vp: TurnViewport): Modifier = this then TurnViewportElement(vp)

private data class TurnViewportElement(val vp: TurnViewport) : ModifierNodeElement<TurnViewportNode>() {
    override fun create() = TurnViewportNode(vp)
    override fun update(node: TurnViewportNode) { node.vp = vp }
}

private class TurnViewportNode(var vp: TurnViewport) : Modifier.Node(), LayoutModifierNode {
    override fun MeasureScope.measure(measurable: Measurable, constraints: Constraints): MeasureResult {
        if (constraints.hasBoundedHeight && constraints.maxHeight != vp.heightPx) {
            val shrink = vp.heightPx - constraints.maxHeight
            vp.heightPx = constraints.maxHeight
            vp.turnNode?.invalidateMeasurement()
            if (shrink > 0) {
                val residue = shrink - (vp.turnNode?.blankPx ?: 0)
                if (residue > 0) vp.onResidue?.invoke(residue)
            }
        }
        val p = measurable.measure(constraints)
        return layout(p.width, p.height) { p.place(0, 0) }
    }
}

private fun Modifier.turnMinHeight(vp: TurnViewport): Modifier = this then TurnMinHeightElement(vp)

private data class TurnMinHeightElement(val vp: TurnViewport) : ModifierNodeElement<TurnMinHeightNode>() {
    override fun create() = TurnMinHeightNode(vp)
    override fun update(node: TurnMinHeightNode) {
        if (node.vp !== vp) { node.detachFrom(); node.vp = vp; node.attachTo() }
    }
}

private class TurnMinHeightNode(var vp: TurnViewport) : Modifier.Node(), LayoutModifierNode {
    fun attachTo() { vp.turnNode = this }
    fun detachFrom() { if (vp.turnNode === this) vp.turnNode = null }
    override fun onAttach() = attachTo()
    override fun onDetach() = detachFrom()
    /** Blank space under the turn's rows at the last measure. */
    var blankPx = 0
    override fun MeasureScope.measure(measurable: Measurable, constraints: Constraints): MeasureResult {
        val min = vp.minTurnHeightPx.coerceIn(constraints.minHeight, constraints.maxHeight)
        // Rows at their natural height, top-aligned in a box at least `min` tall.
        val p = measurable.measure(constraints)
        blankPx = (min - p.height).coerceAtLeast(0)
        return layout(p.width, maxOf(p.height, min)) { p.place(0, 0) }
    }
}

/** Visibility of the ↓ button — read ONLY by [JumpToBottomButton], so showing or
 * hiding it recomposes that one composable. */
@Stable
private class JumpButtonState {
    var visible by mutableStateOf(false)
}

/** ↓ jump button: debounced appearance (ChatScreen's atBottom collector), fade
 * + scale so it arrives rather than popping into the corner. Reduced Motion
 * drops the scale (fade only) and the duration. */
@Composable
private fun JumpToBottomButton(state: JumpButtonState, revealed: Boolean, reduceMotion: Boolean,
                               modifier: Modifier, onJump: () -> Unit) {
    val ms = if (reduceMotion) 0 else ChatScroll.jumpButtonFadeMs
    AnimatedVisibility(
        visible = state.visible && revealed,
        modifier = modifier,
        enter = if (reduceMotion) fadeIn(tween(ms))
            else fadeIn(tween(ms)) + scaleIn(tween(ms), initialScale = 0.85f),
        exit = if (reduceMotion) fadeOut(tween(ms))
            else fadeOut(tween(ms)) + scaleOut(tween(ms), targetScale = 0.85f),
    ) {
        FloatingActionButton(
            onClick = onJump,
            containerColor = MyMuColors.elevated,
            contentColor = MyMuColors.text,
            shape = CircleShape,
            modifier = Modifier.padding(end = 16.dp, bottom = 10.dp).size(40.dp).testTag("jump-to-bottom"),
        ) {
            Icon(Icons.Filled.ArrowDownward, contentDescription = "Jump to bottom",
                modifier = Modifier.size(18.dp))
        }
    }
}

/** What every transcript row needs from the chat besides its message — equal
 * across recompositions, so it never defeats a row's skip. */
@Immutable
private data class RowEnv(val projectId: String, val token: String, val origin: String?)

/**
 * One message row as its own skippable composable — the Compose form of iOS
 * c7decec's Equatable TranscriptRows: when the chat recomposes for something
 * else (status strip, ball, banner, a stream chunk on ANOTHER row), a row whose
 * inputs didn't change is skipped. ChatMessage is compared by instance (strong
 * skipping; the relay keeps unchanged rows' instances), and its JSON payloads
 * (toolInput/toolResult: org.json objects) only ever by reference — org.json
 * doesn't override equals, so no row diff ever walks a tool payload (the iOS
 * AnyCodable == did, via String(describing:)).
 */
@Composable
private fun TranscriptMessageRow(m: ChatMessage, isNew: Boolean, enter: EnterTransition, env: RowEnv,
                                 showActions: Boolean) {
    RowEnter(isNew, enter) {
        MessageRow(m, env.projectId, env.token, env.origin, showActions = showActions)
    }
}

/** A collapsed tool run, skippable the same way ([DisplayItem] is @Immutable,
 * so a regrouped-but-identical run compares equal member by member). */
@Composable
private fun TranscriptGroupRow(group: DisplayItem.ToolGroup, isNew: Boolean, enter: EnterTransition,
                               env: RowEnv, expanded: Boolean, onToggle: (String) -> Unit) {
    RowEnter(isNew, enter) {
        ToolGroupRow(
            members = group.members,
            expanded = expanded,
            toggle = { onToggle(group.id) },
            projectId = env.projectId, token = env.token, origin = env.origin,
        )
    }
}

/** Plays `enter` once when `isNew`; otherwise the content is simply there
 * (SwiftUI transition-on-insert semantics). Removal is instant: Compose's
 * LazyColumn disposes a removed item outright, so the iOS removal fades
 * (ball dissolving, reconcile swaps) have no counterpart here. */
@Composable
private fun RowEnter(isNew: Boolean, enter: EnterTransition, content: @Composable () -> Unit) {
    val state = remember { MutableTransitionState(!isNew).apply { targetState = true } }
    AnimatedVisibility(visibleState = state, enter = enter, exit = ExitTransition.None) { content() }
}

// MARK: top bar --------------------------------------------------------------

@Composable
private fun ChatTopBar(
    target: ChatTarget,
    liveSessionId: String,
    usedTokens: Int?,
    syncing: Boolean,
    mode: PermissionMode,
    onMode: (PermissionMode) -> Unit,
    model: String?,
    modelOptions: List<ApiClient.ModelOption>,
    onModel: (String) -> Unit,
    onBack: () -> Unit,
    onOpen: (Route) -> Unit,
    visibleMessagesProvider: () -> List<ChatMessage>,
) {
    var modeMenu by remember { mutableStateOf(false) }
    var modelMenu by remember { mutableStateOf(false) }
    var actionsMenu by remember { mutableStateOf(false) }
    var showCommands by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val activeToken by AppState.token.collectAsStateWithLifecycle()

    Row(
        Modifier.fillMaxWidth().background(MyMuColors.background)
            .statusBarsPadding()
            .padding(horizontal = 4.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onBack) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = MyMuColors.text)
        }
        // Agent name over its status strip — the standard two-line inline title.
        Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Harness.from(liveSessionId, target.provider)?.let {
                    HarnessBadge(it)
                    Spacer(Modifier.width(5.dp))
                }
                Text(target.title, color = MyMuColors.text, fontWeight = FontWeight.SemiBold,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.titleMedium)
            }
            // Persistent "what's picked" strip: tokens · mode · model — and the
            // honest sync signal in place of the count while a history merge
            // is in flight (iOS ChatStatusStrip.syncing).
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (syncing) {
                    Text("syncing", color = MyMuColors.mutedText.copy(alpha = 0.8f),
                        fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelSmall,
                        modifier = Modifier.semantics { contentDescription = "Syncing with the server" })
                    Spacer(Modifier.width(7.dp))
                } else usedTokens?.takeIf { it > 0 }?.let { n ->
                    Text(stripTokensLabel(n), color = MyMuColors.mutedText,
                        fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.labelSmall)
                    Spacer(Modifier.width(7.dp))
                }
                Box {
                    Text(
                        modeGlyph(mode), color = modeTint(mode),
                        style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier
                            .background(MyMuColors.surface, RoundedCornerShape(6.dp))
                            .padding(horizontal = 6.dp, vertical = 1.dp)
                            .androidClickable { modeMenu = true }
                            .testTag("strip-permission"),
                    )
                    DropdownMenu(expanded = modeMenu, onDismissRequest = { modeMenu = false }) {
                        for (m in PermissionMode.entries) {
                            DropdownMenuItem(text = {
                                Column {
                                    Text(m.label + if (m == mode) "  ✓" else "")
                                    Text(m.detail, style = MaterialTheme.typography.labelSmall,
                                        color = MyMuColors.mutedText)
                                }
                            }, onClick = { modeMenu = false; onMode(m) })
                        }
                    }
                }
                if (modelOptions.isNotEmpty()) {
                    Spacer(Modifier.width(7.dp))
                    Box {
                        Text(
                            ModelDisplay.compact(model ?: "default"),
                            color = MyMuColors.primary, fontFamily = FontFamily.Monospace,
                            fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.labelSmall,
                            modifier = Modifier.androidClickable { modelMenu = true }.testTag("strip-model"),
                        )
                        DropdownMenu(expanded = modelMenu, onDismissRequest = { modelMenu = false }) {
                            for (option in modelOptions) {
                                DropdownMenuItem(text = {
                                    Column {
                                        Text(ModelDisplay.compact(option.value) +
                                            if (option.value == model) "  ✓" else "")
                                        Text(option.description ?: option.label,
                                            style = MaterialTheme.typography.labelSmall,
                                            color = MyMuColors.mutedText)
                                    }
                                }, onClick = { modelMenu = false; onModel(option.value) })
                            }
                        }
                    }
                }
            }
        }
        // ONE trailing control: the conversation menu.
        Box {
            IconButton(onClick = { actionsMenu = true }, modifier = Modifier.testTag("chat-menu")) {
                Icon(Icons.Outlined.MoreVert, contentDescription = "Conversation options",
                    tint = MyMuColors.primary)
            }
            DropdownMenu(expanded = actionsMenu, onDismissRequest = { actionsMenu = false }) {
                DropdownMenuItem(
                    text = { Text("Commands") },
                    onClick = { actionsMenu = false; showCommands = true },
                )
                DropdownMenuItem(
                    text = { Text("Files") },
                    onClick = {
                        actionsMenu = false
                        onOpen(Route.Files(target.projectId, target.title,
                            origin = target.origin, tokenOverride = target.tokenOverride))
                    },
                )
                DropdownMenuItem(
                    text = { Text("Export transcript") },
                    onClick = {
                        actionsMenu = false
                        val md = transcriptMarkdown(target.title, visibleMessagesProvider())
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, md)
                        }
                        context.startActivity(Intent.createChooser(send, "Export transcript"))
                    },
                )
            }
        }
    }

    if (showCommands) {
        SlashCommandSheet(
            api = ApiClient(target.tokenOverride ?: activeToken, target.origin),
            projectPath = target.projectPath,
            onPick = { cmd -> ComposerInsertBus.insert(cmd.invocation + " "); showCommands = false },
            onDismiss = { showCommands = false },
        )
    }
}

/** Cross-component hand-off for "insert this into the draft" (slash commands). */
object ComposerInsertBus {
    val pending = androidx.compose.runtime.mutableStateOf<String?>(null)
    fun insert(text: String) { pending.value = text }
}

private fun stripTokensLabel(n: Int): String = when {
    n >= 1_000_000 -> "%.1fM tokens".format(n / 1_000_000.0)
    n >= 1_000 -> "${Math.round(n / 1_000.0)}k tokens"
    else -> "$n tokens"
}

private fun modeGlyph(m: PermissionMode): String = when (m) {
    PermissionMode.DEFAULT -> "ask"
    PermissionMode.ACCEPT_EDITS -> "edits"
    PermissionMode.PLAN -> "plan"
    PermissionMode.BYPASS_PERMISSIONS -> "bypass"
}

@Composable
private fun modeTint(m: PermissionMode): Color = when (m) {
    PermissionMode.DEFAULT -> MyMuColors.mutedText
    PermissionMode.BYPASS_PERMISSIONS -> MyMuColors.danger
    else -> MyMuColors.primary
}

/** The loaded transcript as markdown, for the share sheet. */
private fun transcriptMarkdown(title: String, visible: List<ChatMessage>): String {
    val out = mutableListOf("# $title")
    for (m in visible) {
        when (m.kind) {
            "text" -> out.add("**${if (m.role == "user") "You" else "Agent"}:** ${m.bodyText.trim()}")
            "tool_use" -> out.add("_→ ${m.toolName ?: "tool"}_")
            "thinking" -> out.add("_(thinking)_")
            "error" -> out.add("> ⚠︎ ${m.content ?: "error"}")
        }
    }
    return out.joinToString("\n\n")
}

// MARK: pending indicator -----------------------------------------------------

/** Human activity label for a tool in use (mirrors the web client's map). */
fun activityLabel(tool: String?): String = when (tool ?: "") {
    "Bash" -> "Running a command"
    "Read" -> "Reading files"
    "Edit", "Write", "ApplyPatch", "MultiEdit", "NotebookEdit" -> "Editing files"
    "Grep", "Glob" -> "Searching the code"
    "WebFetch", "WebSearch" -> "Browsing the web"
    "Task", "Agent" -> "Running a subagent"
    "TodoWrite" -> "Planning"
    "SendUserFile" -> "Sending a file"
    "AskUserQuestion" -> "Asking a question"
    "" -> "Working"
    else -> "Using ${tool}"
}

/** "42s" / "4m 12s" / "1h 04m" — how long the agent has been working. */
fun elapsedLabel(seconds: Long): String {
    val s = seconds.coerceAtLeast(0)
    if (s < 60) return "${s}s"
    if (s < 3600) return "${s / 60}m ${"%02d".format(s % 60)}s"
    return "${s / 3600}h ${"%02d".format((s % 3600) / 60)}m"
}

/** "412" / "4.2k" / "112k" — tokens generated this turn, CLI-style. */
fun turnTokensLabel(n: Int): String = when {
    n < 1000 -> "$n"
    n < 100_000 -> "%.1fk".format(n / 1000.0)
    else -> "${n / 1000}k"
}

/**
 * The pulsing ball in the gutter, the activity/elapsed/token read-out in one
 * muted line beside it (iOS ChatView.pendingIndicatorRow). The row is as tall
 * as a text line so the first streamed line replaces it without a height
 * jump. A generic "Working" duplicates the ball and reads as message text, so
 * only a specific activity ("Reading files", "Running a command") is spelled.
 */
@Composable
private fun PendingIndicatorRow(statusText: String?, messages: List<ChatMessage>,
                                turnStartedAt: Long?, turnTokens: Int?) {
    // What the agent is doing right now, from the newest transcript frame. A
    // specific backend status ("Waiting for permission") wins over it.
    val activity = run {
        val s = statusText
        if (!s.isNullOrEmpty() && s != "Processing" && s != "Working...") s
        else {
            var label = "Working"
            loop@ for (m in messages.asReversed()) {
                when (m.kind) {
                    "tool_use" -> { label = activityLabel(m.toolName); break@loop }
                    "tool_result", "error" -> { label = "Working"; break@loop }
                    "text" -> { label = if (m.role == "user") "Working" else "Writing"; break@loop }
                }
            }
            label
        }
    }
    val visibleActivity = if (activity == "Working") null else activity

    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(turnStartedAt) {
        while (true) { now = System.currentTimeMillis(); delay(1_000) }
    }

    Row(
        Modifier.fillMaxWidth().heightIn(min = 24.dp).padding(horizontal = 16.dp)
            .semantics(mergeDescendants = true) { contentDescription = "Generating response" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        PulsingBallIndicator()
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            visibleActivity?.let {
                Text("$it…", color = MyMuColors.text.copy(alpha = 0.75f), fontSize = 12.sp,
                    fontWeight = FontWeight.Medium, maxLines = 1)
            }
            turnStartedAt?.let { start ->
                Text((if (visibleActivity != null) "· " else "") + elapsedLabel((now - start) / 1000),
                    color = MyMuColors.mutedText, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
            }
            turnTokens?.takeIf { it > 0 }?.let { tok ->
                val needsSeparator = visibleActivity != null || turnStartedAt != null
                Text((if (needsSeparator) "· " else "") + "${turnTokensLabel(tok)} tokens",
                    color = MyMuColors.mutedText, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
            }
        }
    }
}

// MARK: composer -------------------------------------------------------------

/** Types the relay can EMBED as content blocks: image/PDF/text reach any
 * agent; everything else needs the file to LAND on the agent's host. */
private val embeddableTextExts = setOf(
    "txt", "md", "markdown", "json", "csv", "tsv", "xml", "yaml", "yml", "toml", "ini", "cfg",
    "conf", "env", "log", "js", "jsx", "ts", "tsx", "mjs", "cjs", "py", "rb", "go", "rs", "java",
    "c", "cpp", "cc", "h", "hpp", "cs", "php", "sh", "bash", "zsh", "sql", "html", "htm", "css",
    "scss", "less", "vue", "svelte", "svg", "dockerfile", "gitignore", "lua", "r", "kt", "swift",
)

/** CaptureVideo with the recording capped at the server attachment limit
 * (MediaStore.EXTRA_SIZE_LIMIT) — the Android form of iOS's 720p clip
 * quality: a hand-held clip stays sendable instead of bouncing at the cap. */
private class CaptureVideoCapped(private val maxBytes: Long) : ActivityResultContracts.CaptureVideo() {
    override fun createIntent(context: Context, input: Uri): Intent =
        super.createIntent(context, input).putExtra(MediaStore.EXTRA_SIZE_LIMIT, maxBytes)
}

private fun embedsWithoutLanding(mime: String, name: String): Boolean {
    if (mime.startsWith("image/") || mime.startsWith("text/") || mime == "application/pdf") return true
    return name.substringAfterLast('.', "").lowercase() in embeddableTextExts
}

/**
 * The message composer — modeled on the ChatGPT iOS composer, state by state
 * (port of iOS Views/ChatComposer.swift, wave 6).
 *
 * STATE 1 — IDLE: nothing typed, not focused, no attachments. One row, a 52dp
 *   capsule, inset 32dp from the screen edges: `( +  Ask <agent>       (↑) )`.
 *   "+" is a bare 22dp glyph on a 44dp tap target; the placeholder is 17sp
 *   muted; a tap ANYWHERE on the pill focuses the field. Trailing slot: the
 *   send circle, dimmed — or, while the agent is working, the STOP circle.
 *   No stroke: the fill alone (MyMuColors.composer) defines the shape.
 *
 * STATE 2 — EXPANDED: focused, or a draft / attachments exist. Full width
 *   (inset 12dp), two rows, corner radius 28: [thumbs/chips] / typed text
 *   (17sp, grows 1→8 lines) / `+` … `(↑)`. SEND (34dp, brand fill, white bold
 *   arrow) is live with text or an attachment, dimmed otherwise. STOP takes
 *   the slot while the agent works and nothing is typed; typing mid-turn
 *   brings SEND back (remote agents queue the message behind the running turn).
 *
 * The idle↔expanded change is one animated layout change (animateContentSize
 * + animated inset/radius) — Compose has no matchedGeometryEffect, so the "+"
 * and the trailing control re-appear in their new row rather than gliding.
 * Reduce Motion: no travel, just the end state.
 *
 * SEND: the text clears; the pill stays expanded while focused (the keyboard
 * stays up, as in ChatGPT) and the parent flies the bubble up into the
 * transcript. Attach errors render as one 12sp line under the pill.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ChatComposer(
    relay: RelayClient,
    isDemo: Boolean,
    placeholder: String,
    pinnedHostNeedingLogin: String?,
    permissionMode: PermissionMode,
    model: String?,
    /** DraftStore identity for this conversation — agent (projectId) for
     * remote chats, session for local ones. */
    draftKey: String,
    onWillSend: () -> Unit,
) {
    // Arriving from a type-to-switch: the draft typed into the previous chat
    // lands here (focus is retaken below so the keyboard never drops
    // mid-thought). Otherwise restore whatever was left unsent last time this
    // conversation was open. First composition only, like iOS onAppear — the
    // route is keyed by session, so a switch composes a fresh composer.
    val handoff = remember { ChatSwitcher.takeDraft() }
    var input by remember { mutableStateOf(handoff ?: DraftStore.load(draftKey) ?: "") }
    // Every draft change: remember it for this conversation, then tell the
    // switcher (typing while its HUD is raised means "switch NOW", and the
    // full draft rides along). Save BEFORE forwarding — a type-to-switch
    // clears this key as the draft departs, and the clear must win over the
    // save. Every write to `input` funnels through here, so programmatic sets
    // (the slash insert, the send clear) count like iOS `.onChange(of: input)`.
    fun setInput(text: String) {
        input = text
        DraftStore.save(text, draftKey)
        ChatSwitcher.typing.tryEmit(text)
    }
    var attachments by remember { mutableStateOf<List<PendingAttachment>>(emptyList()) }
    var attachError by remember { mutableStateOf<String?>(null) }
    var attachMenu by remember { mutableStateOf(false) }
    val isLoading by relay.isLoading.collectAsStateWithLifecycle()
    val attachmentLimit by AppLimits.attachmentBytes.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val reduceMotion = LocalReduceMotion()
    val focusRequester = remember { FocusRequester() }
    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    val keyboard = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current

    // Type-to-switch arrival: retake focus so the keyboard never drops
    // mid-thought (iOS `inputFocused = true` on the next run loop — the field
    // must be attached before it can take focus, hence an effect, not the
    // initializer above).
    LaunchedEffect(Unit) {
        if (handoff != null) {
            focusRequester.requestFocus()
            keyboard?.show()
        }
    }

    // Keyboard dismissed (Back, or a drag) ⇒ the field stands down. Compose
    // keeps focus on a field whose IME went away, which left the pill
    // EXPANDED with a cursor and no keyboard — a state iOS cannot be in
    // (keyboard gone = resigned first responder = IDLE). Only the shown→hidden
    // edge counts: on a fresh focus the IME is not up yet. (Emulator pass
    // 2026-10-24.)
    val imeVisible = WindowInsets.isImeVisible
    var imeWasVisible by remember { mutableStateOf(false) }
    LaunchedEffect(imeVisible) {
        if (imeWasVisible && !imeVisible && focused) focusManager.clearFocus()
        imeWasVisible = imeVisible
    }

    // Slash-command hand-off from the toolbar sheet.
    LaunchedEffect(ComposerInsertBus.pending.value) {
        ComposerInsertBus.pending.value?.let { text ->
            val gap = if (input.isEmpty() || input.endsWith(" ")) "" else " "
            setInput(input + gap + text)
            ComposerInsertBus.pending.value = null
        }
    }

    // Every attach source (library, camera, files) funnels through ingest →
    // ONE gate: server size cap, then the pinned-host reachability check for
    // types the relay can't embed (iOS 4dee00b appendAttachment). Reads run
    // off the main thread — videos are tens of MB.
    val attachScope = rememberCoroutineScope()

    // [clearError] false = one item of a multi-pick batch: the batch clears
    // once up front, so an earlier item's refusal ("Video is too large") stays
    // visible instead of being wiped by the next item's success (emulator
    // pass 2026-10-28; iOS addPickedAttachment has the same per-item reset).
    suspend fun ingest(uri: Uri, forcedName: String? = null, clearError: Boolean = true) {
        if (clearError) attachError = null
        val resolver = context.contentResolver
        val mime = resolver.getType(uri) ?: "application/octet-stream"
        val kind = when {
            mime.startsWith("image/") -> "Photo"
            mime.startsWith("video/") -> "Video"
            else -> "File"
        }
        val name = forcedName ?: uri.lastPathSegment?.substringAfterLast('/')
            ?: "attachment-${attachments.size + 1}"
        // Pinned-host check up front: a type that can't reach that host is
        // refused before anything is read.
        if (pinnedHostNeedingLogin != null && !embedsWithoutLanding(mime, name)) {
            attachError = "Can't share this file: the agent runs on $pinnedHostNeedingLogin, " +
                "which you're not signed in to. Add that account to send files."
            return
        }
        val tooLarge = "$kind is too large (max ${attachmentLimit / (1024 * 1024)} MB)."
        val dataUrl = try {
            withContext(Dispatchers.IO) {
                // Size first (provider column, else descriptor length) so an
                // oversized video is refused without ever being read into memory.
                val size = knownContentSize(resolver, uri)
                if (size != null && size > attachmentLimit) return@withContext Result.failure(Exception(tooLarge))
                val bytes = resolver.openInputStream(uri)?.use { it.readBytes() }
                    ?: return@withContext Result.failure(Exception("Couldn't read that file."))
                if (bytes.size > attachmentLimit) return@withContext Result.failure(Exception(tooLarge))
                Result.success("data:$mime;base64," + Base64.encodeToString(bytes, Base64.NO_WRAP))
            }
        } catch (e: Exception) {
            Result.failure(Exception("Couldn't read that file. (${e.message})"))
        }
        dataUrl.onFailure { attachError = it.message; return }
        attachments = attachments + PendingAttachment(name, dataUrl.getOrThrow(), mime.startsWith("image/"))
    }

    /** "photo-3.jpg" / "video-4.mp4" — the container's real extension rides
     * along so the agent gets a playable file (iOS addPickedAttachment). */
    fun pickedName(uri: Uri, index: Int): String {
        val mime = context.contentResolver.getType(uri) ?: "image/jpeg"
        val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
            ?: if (mime.startsWith("video/")) "mp4" else "jpg"
        return (if (mime.startsWith("video/")) "video" else "photo") + "-$index.$ext"
    }

    // Library: photos AND videos, up to 5 at once (iOS "Photo or video").
    val photoPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(5)) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        attachScope.launch {
            attachError = null
            for (uri in uris) ingest(uri, forcedName = pickedName(uri, attachments.size + 1), clearError = false)
        }
    }
    val filePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let { attachScope.launch { ingest(it) } }
    }

    // Camera (iOS CameraPicker): the system capture apps via TakePicture /
    // CaptureVideo, writing into cacheDir/camera through the app FileProvider.
    // The manifest declares CAMERA for the login screen's QR scanner
    // (QRAccess.kt) — and an app that declares it must HOLD it to fire these
    // intents (SecurityException otherwise), so `launchCamera` asks first.
    // The pending target is saveable: the camera app may outlive our process.
    val hasCamera = remember {
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)
    }
    var captureFile by rememberSaveable { mutableStateOf<String?>(null) }
    fun captureTarget(ext: String): Uri {
        val dir = File(context.cacheDir, "camera").apply { mkdirs() }
        val file = File(dir, "capture-${System.currentTimeMillis()}.$ext")
        captureFile = file.absolutePath
        return FileProvider.getUriForFile(context, "${context.packageName}.files" /* HOST PATCH: host FileProvider */, file)
    }
    fun onCaptured(ok: Boolean, ext: String) {
        val path = captureFile ?: return
        captureFile = null
        val file = File(path)
        if (!ok || !file.exists() || file.length() == 0L) { file.delete(); return }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files" /* HOST PATCH: host FileProvider */, file)
        attachScope.launch {
            ingest(uri, forcedName = "camera-${attachments.size + 1}.$ext")
            file.delete() // the bytes are staged; the capture file is spent
        }
    }
    val takePicture = rememberLauncherForActivityResult(
        ActivityResultContracts.TakePicture()) { ok -> onCaptured(ok, "jpg") }
    val captureVideo = rememberLauncherForActivityResult(
        CaptureVideoCapped(attachmentLimit.toLong())) { ok -> onCaptured(ok, "mp4") }
    fun fireCamera(video: Boolean) {
        try {
            if (video) captureVideo.launch(captureTarget("mp4"))
            else takePicture.launch(captureTarget("jpg"))
        } catch (_: ActivityNotFoundException) {
            captureFile = null
            attachError = "No camera app available."
        }
    }
    // Which capture the permission prompt was raised for; resumed on grant.
    var cameraAfterPermission by rememberSaveable { mutableStateOf<Boolean?>(null) }
    val cameraPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()) { ok ->
        val video = cameraAfterPermission ?: return@rememberLauncherForActivityResult
        cameraAfterPermission = null
        if (ok) fireCamera(video)
        else attachError = "Camera access is off for MyMu — allow it in Settings."
    }
    fun launchCamera(video: Boolean) {
        attachError = null
        if (context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            fireCamera(video)
            return
        }
        cameraAfterPermission = video
        cameraPermission.launch(Manifest.permission.CAMERA)
    }

    // STATE 2 whenever there is something to show or the field has focus.
    val expanded = focused || input.isNotEmpty() || attachments.isNotEmpty()
    val canSend = input.trim().isNotEmpty() || attachments.isNotEmpty()
    // Mid-turn sends are allowed for remote agents — the relay queues them into
    // the agent's own message queue, so typed text always SENDS; local
    // sessions keep stop-while-working (no queue there).
    val sendAllowed = canSend && (!isLoading || relay.supportsMidTurnSend)
    val showsStop = isLoading && !canSend

    fun send() {
        if (!sendAllowed) return
        Haptics.send()
        onWillSend()
        val text = input
        val files = attachments.map { mapOf("name" to it.name, "data" to it.dataUrl) }
        setInput("") // save("") removes the stored draft — the send clears it naturally
        attachments = emptyList()
        if (!isDemo) relay.send(text, files, permissionMode, model)
    }

    fun <T> motion(): FiniteAnimationSpec<T> =
        if (reduceMotion) snap() else spring(ChatScroll.composerSpringDamping, ChatScroll.composerSpringStiffness)
    val inset by animateDpAsState(if (expanded) 12.dp else 32.dp, motion(), label = "composer-inset")
    // Idle: a true capsule (radius = half the 52dp height). Expanded: the 28dp
    // corner of the ChatGPT pill.
    val radius by animateDpAsState(if (expanded) MyMuRadius.composer else 26.dp, motion(), label = "composer-radius")

    @Composable
    fun plusButton() {
        Box {
            // Live in the demo too: iOS lets the reviewer open the attach
            // options offline (UXSmoke test1), and a staged file simply never
            // leaves the device there (send() skips the relay).
            Box(
                Modifier.size(44.dp)
                    .clickable(interactionSource = remember { MutableInteractionSource() },
                        indication = null) { attachMenu = true }
                    .semantics { contentDescription = "Add attachment" }
                    .testTag("composer-attach"),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Outlined.Add, contentDescription = null,
                    tint = MyMuColors.text.copy(alpha = 0.9f), modifier = Modifier.size(22.dp))
            }
            DropdownMenu(expanded = attachMenu, onDismissRequest = { attachMenu = false }) {
                // iOS: "Camera" (one capture UI with a photo/video toggle).
                // Android's capture intents are one-mode, hence two entries.
                if (hasCamera) {
                    DropdownMenuItem(text = { Text("Camera · photo") }, onClick = {
                        attachMenu = false
                        launchCamera(video = false)
                    })
                    DropdownMenuItem(text = { Text("Camera · video") }, onClick = {
                        attachMenu = false
                        launchCamera(video = true)
                    })
                }
                DropdownMenuItem(text = { Text("Photo or video") }, onClick = {
                    attachMenu = false
                    photoPicker.launch(androidx.activity.result.PickVisualMediaRequest(
                        ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                })
                DropdownMenuItem(text = { Text("Attach file") }, onClick = {
                    attachMenu = false
                    filePicker.launch(arrayOf("*/*"))
                })
            }
        }
    }

    /** The slot at the pill's trailing edge: SEND (live or dimmed) or STOP. */
    @Composable
    fun trailingControl() {
        Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) {
            AnimatedContent(
                targetState = showsStop,
                transitionSpec = {
                    (fadeIn(motion()) + scaleIn(motion())) togetherWith (fadeOut(motion()) + scaleOut(motion()))
                },
                label = "composer-trailing",
            ) { stop ->
                if (stop) {
                    Box(
                        Modifier.size(34.dp).background(MyMuColors.primary, CircleShape)
                            .clickable(interactionSource = remember { MutableInteractionSource() },
                                indication = null) { relay.abort() }
                            .semantics { contentDescription = "Stop" }
                            .testTag("composer-stop"),
                        contentAlignment = Alignment.Center,
                    ) {
                        Box(Modifier.size(12.dp).background(Color.White, RoundedCornerShape(2.5.dp)))
                    }
                } else {
                    Box(
                        Modifier.size(34.dp)
                            .background(if (sendAllowed) MyMuColors.primary else MyMuColors.elevated, CircleShape)
                            .clickable(enabled = sendAllowed,
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null) { send() }
                            .semantics { contentDescription = "Send" }
                            .testTag("composer-send"),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Filled.ArrowUpward, contentDescription = null,
                            tint = if (sendAllowed) Color.White else MyMuColors.mutedText.copy(alpha = 0.7f),
                            modifier = Modifier.size(16.dp))
                    }
                }
            }
        }
    }

    Column(Modifier.fillMaxWidth().background(MyMuColors.background)) {
        // Same reading-column cap as the transcript above it, so the pill lines
        // up with the bubbles instead of stretching wider on tablets.
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Column(
                Modifier.widthIn(max = MyMuLayout.maxContentWidth).fillMaxWidth()
                    .padding(start = inset, end = inset, top = 6.dp, bottom = 8.dp)
                    .animateContentSize(motion())
                    .heightIn(min = 52.dp)
                    .background(MyMuColors.composer, RoundedCornerShape(radius))
                    // Tapping the pill anywhere (not only the text) raises the
                    // keyboard — the whole shape IS the field.
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {
                        focusRequester.requestFocus()
                        keyboard?.show()
                    },
            ) {
                if (attachments.isNotEmpty()) {
                    AttachmentChips(attachments, onRemove = { a -> attachments = attachments.filter { it != a } },
                        modifier = Modifier.padding(top = 10.dp, start = 10.dp, end = 10.dp))
                }
                // The text row. The field keeps ONE structural identity across
                // both states (its siblings change, it never does), so focus
                // survives the idle↔expanded switch it triggers.
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = if (expanded) 0.dp else 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (!expanded) plusButton()
                    BasicTextField(
                        value = input,
                        onValueChange = { setInput(it) },
                        modifier = Modifier.weight(1f)
                            .focusRequester(focusRequester)
                            .testTag("composer-input")
                            .padding(
                                start = if (expanded) 16.dp else 2.dp,
                                end = if (expanded) 16.dp else 6.dp,
                                top = if (expanded) 13.dp else 14.dp,
                                bottom = if (expanded) 4.dp else 14.dp,
                            ),
                        textStyle = TextStyle(color = MyMuColors.text, fontSize = 17.sp, lineHeight = 22.sp),
                        cursorBrush = SolidColor(MyMuColors.primary),
                        maxLines = 8,
                        interactionSource = interactionSource,
                        decorationBox = { inner ->
                            Box(contentAlignment = Alignment.CenterStart) {
                                if (input.isEmpty()) {
                                    Text(placeholder, color = MyMuColors.mutedText, fontSize = 17.sp,
                                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                                inner()
                            }
                        },
                    )
                    if (!expanded) trailingControl()
                }
                if (expanded) {
                    // The controls drop to their own row so the text owns the
                    // full width.
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 6.dp).padding(bottom = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        plusButton()
                        Spacer(Modifier.weight(1f))
                        trailingControl()
                    }
                }
            }
        }
        if (attachError != null) {
            Text(attachError ?: "", color = MyMuColors.danger, fontSize = 12.sp,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 8.dp))
        }
    }
}

/** Staged attachments INSIDE the pill (ChatGPT keeps them in the composer,
 * above the text): photos as 60dp thumbnails, everything else as a named chip,
 * each with a remove button on its top-trailing corner. */
@Composable
private fun AttachmentChips(attachments: List<PendingAttachment>, onRemove: (PendingAttachment) -> Unit,
                            modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(top = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        for (a in attachments) {
            Box(Modifier.padding(top = 5.dp, end = 5.dp)) {
                if (a.isImage) {
                    Box(Modifier.size(60.dp).background(MyMuColors.elevated, RoundedCornerShape(12.dp))) {
                        DataUrlImage(a.dataUrl, modifier = Modifier.size(60.dp))
                    }
                } else {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .background(MyMuColors.elevated, CircleShape)
                            .padding(horizontal = 10.dp, vertical = 8.dp),
                    ) {
                        Icon(if (a.isVideo) Icons.Outlined.Videocam else Icons.Outlined.Description,
                            contentDescription = null, tint = MyMuColors.primary,
                            modifier = Modifier.size(12.dp))
                        Spacer(Modifier.width(6.dp))
                        Text(a.name, color = MyMuColors.text, style = MaterialTheme.typography.bodySmall,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                Box(
                    Modifier.align(Alignment.TopEnd).offset(x = 5.dp, y = (-5).dp)
                        .size(16.dp).background(MyMuColors.background, CircleShape)
                        .clickable { onRemove(a) },
                ) {
                    Icon(Icons.Filled.Cancel, contentDescription = "Remove",
                        tint = MyMuColors.text, modifier = Modifier.size(16.dp))
                }
            }
        }
    }
}

/** Plain clickable without the file needing per-site interaction sources. */
private fun Modifier.androidClickable(onClick: () -> Unit): Modifier =
    this.clickable(onClick = onClick)
