import SwiftUI
import UIKit

/// One conversation: the transcript, the live turn, and the composer.
///
/// Local-first (Manar, 2026-10-24): the view does NOT own the conversation —
/// it borrows the `RelayClient` store from `ConversationRegistry`, which keeps
/// transcript, turn state and (while a turn runs) the socket alive across
/// Back/re-open. Opening a chat renders what the app already holds in the
/// very first frame; the server only ever continues it (a quiet, animated
/// merge — never a loader over readable content, never a wholesale swap).
///
/// Send choreography (ChatGPT app): the sent bubble flies up out of the
/// composer and settles at the TOP of the viewport; the pulsing ball sits
/// where the reply will begin; the first text replaces the ball in place.
/// The "message to the top" is pure geometry: the active turn (sent bubble +
/// everything after it) is padded to the viewport height by `activeTurnSpacer`
/// (the guide's `.active-turn { min-height }`), so the ONE scroll rule — stay
/// at the bottom while following — lands the bubble at the top and the reply
/// grows into the blank space below with zero motion until it overflows.
@MainActor
struct ChatView: View {
    let sessionId: String
    let projectId: String
    let isRemote: Bool
    let title: String
    /// Agent→host pinning: host origin + token this conversation is routed to
    /// (nil = active account's host). Set when the agent is assigned to another
    /// host the app has a saved login for.
    let origin: String?
    private let chatToken: String
    /// The agent/project working directory — retained so the `session_created`
    /// rebind can re-record Recents with the same path the view opened with.
    private let projectPath: String?
    /// Pinned to a host with NO saved login: label shown by the composer's
    /// file warning ("log in to <host> to share files"). nil = files work.
    let pinnedHostNeedingLogin: String?

    @EnvironmentObject var appState: AppState
    /// Borrowed, not owned — see ConversationRegistry.
    @ObservedObject private var relay: RelayClient
    /// While the swipe switcher is raised, the nav title follows ITS candidate
    /// (identity + live status) instead of this chat's title + session stats —
    /// a stale title over another agent's conversation read as two agents at
    /// once.
    @ObservedObject private var switcher = ChatSwitcher.shared
    @State private var loadError: String?
    @State private var loadingHistory: Bool
    @State private var atBottom = true
    // Follow-mode = the user's INTENT to ride the bottom. Only an explicit upward
    // drag turns it off; reaching the bottom (any way), sending, or tapping the
    // pill turns it back on. Deriving intent from sentinel visibility alone made
    // following stop whenever content growth pushed the sentinel away (the old
    // flakiness), so intent and position are tracked separately now.
    @State private var followMode = true
    // Phantom-gap guard: the content bottom may never REST above the viewport
    // bottom (that's the "conversation looks blank until I scroll" bug — content
    // shrinks after we pinned the bottom, or an animated pin overshoots into
    // LazyVStack estimated space: end-of-turn reconcile, media rows resizing,
    // keyboard open/close). Measured from the WHOLE content block's frame.
    @State private var contentBottom: CGFloat = .greatestFiniteMagnitude
    @State private var viewportHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var gapRepair: Task<Void, Never>?
    /// Bumped by the composer right before a send — drives the one glide that
    /// lands the sent bubble at the top.
    @State private var sendTick = 0
    /// While set (send + ~0.5s), the instant composer/viewport pins stand down
    /// so the one animated glide is actually visible — no teleport mid-glide.
    @State private var glideUntil = Date.distantPast
    /// The active turn's geometry is on: the sent bubble (relay.activeTurnUserId)
    /// is kept at the top of the viewport for the turn, and stays there after
    /// it ends until the next send (ChatGPT keeps the space; collapsing it at
    /// turn end would yank the reply down). True from a send in this view, or
    /// on open when the turn is still running.
    @State private var anchorTurn: Bool
    /// Blank space under the active turn so it spans the viewport. Derived
    /// from measured row geometry (see ActiveTurnGeometryKey) — shrinks as the
    /// reply grows, so the content height stays put and nothing scrolls until
    /// the reply really overflows.
    @State private var activeTurnSpacer: CGFloat = 1
    @State private var revisionScrollPending = false
    /// Last distance-to-bottom the scroll-geometry tracker reported (debug HUD).
    @State private var debugTrackerDistance: CGFloat = 0
    /// The content block's bottom in GLOBAL space (debug HUD cross-check).
    @State private var debugGlobalBottom: CGFloat = 0
    /// Debounced visibility for the ↓ jump button (see onChange(of: atBottom)).
    @State private var showJumpButton = false
    @State private var jumpButtonTask: Task<Void, Never>?
    /// False until the opening transcript is pinned to the bottom — content is
    /// hidden (loader shown) so the settling scroll is never visible.
    @State private var revealed = false
    @State private var loadingOlder = false
    /// Conversation controls. They live up here, not in the composer, so the
    /// composer keeps only the two things you touch constantly — attach and
    /// send — and the rest sits in one toolbar menu out of the way.
    @State private var permissionMode: PermissionMode = .default
    @State private var model: String?
    @State private var modelOptions: [APIClient.ModelOption] = []
    @State private var showCommands = false
    @State private var pendingInsert: String?
    /// A `/clear` was just sent — true until the recovery poll below either
    /// catches the transcript resetting or times out. See `beginClearRecovery`.
    @State private var clearingConversation = false
    /// Tool groups the user opened. Collapsed is the default — the summary
    /// row is the point; expansion is per-conversation-view, not persisted.
    @State private var expandedGroups: Set<String> = []
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let previewMessages: [ChatMessage]?
    /// Provider handed over by the originating list (real for local sessions).
    private let provider: String?

    /// Vertical padding around the transcript column.
    private static let columnPadding: CGFloat = 14
    /// Spacing between rows. Turn separation adds to this inside MessageRow.
    private static let rowSpacing: CGFloat = 18

    init(sessionId: String, projectId: String, isRemote: Bool, title: String, token: String,
         projectPath: String? = nil, previewMessages: [ChatMessage]? = nil,
         origin: String? = nil, pinnedHostNeedingLogin: String? = nil,
         provider: String? = nil) {
        self.sessionId = sessionId
        self.projectId = projectId
        self.isRemote = isRemote
        self.title = title
        self.previewMessages = previewMessages
        self.origin = origin
        self.chatToken = token
        self.projectPath = projectPath
        self.pinnedHostNeedingLogin = pinnedHostNeedingLogin
        self.provider = provider
        // The store for this conversation: the one already alive (re-open,
        // mid-turn or not) or a fresh one seeded synchronously from the RAM
        // snapshot — either way the first rendered frame carries the
        // transcript. Previews (screenshots, demos) get a throwaway.
        let client: RelayClient
        if previewMessages == nil {
            client = ConversationRegistry.shared.client(token: token, sessionId: sessionId, isRemote: isRemote,
                                                        projectPath: projectPath, origin: origin)
        } else {
            client = RelayClient(token: token, sessionId: sessionId, isRemote: isRemote,
                                 projectPath: projectPath, origin: origin)
        }
        _relay = ObservedObject(wrappedValue: client)
        _loadingHistory = State(initialValue: previewMessages == nil && !client.hasLoadedOnce)
        _anchorTurn = State(initialValue: client.isLoading && client.activeTurnUserId != nil)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                messagesList
                    // Horizontal swipe → the full-screen agent switcher (agent
                    // chats only). Lives on the transcript, not the whole
                    // screen, so composer/text-selection drags never raise it —
                    // and the composer stays reachable below the raised
                    // overlay, which is what lets typing commit the switch.
                    .modifier(AgentSwitcherModifier(currentProjectId: projectId,
                                                    currentTitle: title,
                                                    enabled: isRemote))
                if clearingConversation { clearingBanner }
                if let p = relay.pendingPermission { permissionBanner(p) }
                ChatComposer(relay: relay,
                             placeholder: isRemote ? "Ask \(title)" : "Ask anything",
                             pinnedHostNeedingLogin: pinnedHostNeedingLogin,
                             api: APIClient(token: chatToken, origin: origin),
                             projectPath: projectPath,
                             permissionMode: permissionMode,
                             model: model,
                             draftKey: isRemote ? projectId : (sessionId.isEmpty ? projectId : sessionId),
                             pendingInsert: $pendingInsert,
                             onWillSend: { text in
                                 followMode = true
                                 anchorTurn = true
                                 sendTick += 1
                                 if isClearCommand(text) { beginClearRecovery() }
                             })
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // A conversation is full-screen content, not one more tab-bar screen —
        // the Projects/Chats/Agents/Archive bar only means something on the
        // list screens you picked this chat FROM. Hiding it here (rather than
        // never showing it at all) is what makes it reappear automatically on
        // Back, with the system's own slide, instead of needing a manual show.
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            // Agent name over its status strip — the standard two-line inline
            // title.
            ToolbarItem(placement: .principal) {
                if let p = switcher.previewing {
                    // Switcher raised: the bar belongs to the CANDIDATE — its
                    // harness, name, and live status. This chat's stats would
                    // be lies under another agent's name.
                    VStack(spacing: 1) {
                        HStack(spacing: 5) {
                            if let sid = p.remoteSessionId, let h = Harness(sessionId: sid) {
                                Image(h.assetName)
                                    .resizable().scaledToFit()
                                    .frame(width: 15, height: 15)
                                    .accessibilityLabel(h.label)
                            }
                            Text(p.displayName)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        HStack(spacing: 4) {
                            Circle().fill(AgentStatus.color(p)).frame(width: 6, height: 6)
                            Text(AgentStatus.text(p))
                                .font(.caption2)
                                .foregroundColor(Theme.mutedText)
                        }
                    }
                } else {
                    VStack(spacing: 1) {
                        HStack(spacing: 5) {
                            // Harness logo ahead of the name, same resolution rule
                            // as the lists: id prefix (live agents) first, the
                            // originating list's provider (local sessions) second.
                            if let h = Harness(sessionId: relay.sessionId, provider: provider) {
                                Image(h.assetName)
                                    .resizable().scaledToFit()
                                    .frame(width: 15, height: 15)
                                    .accessibilityLabel(h.label)
                            }
                            Text(title)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        // Persistent "what's picked" strip: context size · model ·
                        // permission mode — and the honest sync signal while a
                        // history merge is in flight.
                        ChatStatusStrip(usage: relay.context,
                                        mode: $permissionMode,
                                        model: $model,
                                        modelOptions: modelOptions,
                                        syncing: relay.syncing)
                    }
                }
            }
            // ONE trailing control. Several bare icons crowded the nav bar with
            // no breathing room against the edge; a single menu gives the
            // system's own spacing and hides choices you rarely need.
            ToolbarItem(placement: .navigationBarTrailing) {
                conversationMenu
            }
        }
        .task {
            // A brand-new local conversation opens with an empty draft id; recording
            // it now would leave a Recents entry that reopens blank. Record only once
            // there's a real id — immediately for existing/remote sessions, and on the
            // `session_created` rebind for a fresh one (wired below).
            if !sessionId.isEmpty {
                RecentlyViewedStore.shared.record(sessionId: sessionId, projectId: projectId,
                                                  isRemote: isRemote, title: title,
                                                  projectPath: projectPath)
            }
            relay.onSessionIdRebound = { newId in
                RecentlyViewedStore.shared.record(sessionId: newId, projectId: projectId,
                                                  isRemote: isRemote, title: title,
                                                  projectPath: projectPath)
            }
            await start()
        }
        // Refresh the server-authoritative attachment cap for this account's host
        // (best-effort; the composer reads AppLimits at attach time). Keeps the
        // limit out of the shipped binary — see AppLimits / GET /api/limits.
        .task { await AppLimits.shared.refresh(token: chatToken, origin: origin) }
        // Per-conversation memory, keyed on the live session id (it can rebind
        // mid-turn on session_created, so track it rather than reading once).
        .task(id: relay.sessionId) {
            permissionMode = PermissionModeStore.load(sessionId: relay.sessionId)
        }
        .onChange(of: permissionMode) { mode in
            PermissionModeStore.save(mode, sessionId: relay.sessionId)
        }
        // Model catalogue + whatever the session already resolves to. Best
        // effort: on failure the Model section simply doesn't appear. The
        // offline demo has no server to ask, so it seeds the same catalogue a
        // multi-harness server serves — the brain switcher is part of the demo.
        .task(id: relay.sessionId) {
            if appState.isDemo {
                modelOptions = DemoData.modelOptions
                if model == nil { model = DemoData.defaultModel }
                return
            }
            let client = APIClient(token: chatToken, origin: origin)
            if let result = try? await client.models() { modelOptions = result.options }
            if !relay.sessionId.isEmpty,
               let active = try? await client.activeModel(sessionId: relay.sessionId) {
                model = active
            }
        }
        .sheet(isPresented: $showCommands) {
            SlashCommandSheet(api: APIClient(token: chatToken, origin: origin),
                              projectPath: projectPath) { cmd in
                // Insert rather than send: commands usually take arguments, and
                // the agent interprets the slash itself.
                pendingInsert = cmd.invocation + " "
            }
        }
        // Agent already working when the chat opens (or a turn starts silently):
        // check the live status endpoint now and every 10s as a backstop. Also
        // the authority that clears a "working" restored from a snapshot when
        // the agent has in fact finished.
        .task {
            guard isRemote, previewMessages == nil, !appState.isDemo else { return }
            while !Task.isCancelled {
                await relay.syncRunningState(APIClient(token: chatToken, origin: origin))
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        // Returning from the background: the socket iOS killed still LOOKS open,
        // so without this kick the chat sat stale until the next failed I/O plus
        // the reconnect backoff. Reconnect + reconcile + status sync right away.
        // GOING to background: tell the server we stopped watching, immediately.
        // iOS never closes the socket cleanly, and until the server's presence
        // TTL expired (~60s) a reply would be push-SUPPRESSED as "user is
        // looking at it" — exactly the fast-reply window a real test hits.
        .onChange(of: scenePhase) { phase in
            guard previewMessages == nil, !appState.isDemo else { return }
            if phase == .active {
                relay.ensureConnected()
                Task { await relay.syncRunningState(APIClient(token: chatToken, origin: origin)) }
            } else if phase == .background {
                relay.releasePresence()
            }
        }
        .onAppear { relay.viewAppeared() }
        // Leaving does NOT tear the conversation down — the registry keeps
        // the store (and the socket while a turn runs); the client only learns
        // nobody is looking.
        .onDisappear { relay.viewDisappeared() }
    }

    // MARK: transcript

    private var messagesList: some View {
        GeometryReader { outer in
        ScrollViewReader { proxy in
            ScrollView {
                // NON-lazy on purpose (Manar's diagnosis, 2026-07-25): LazyVStack
                // only ESTIMATES unmeasured row heights, and bash/tool rows are
                // far taller than the estimate — at certain scroll offsets it
                // decided a visible message was off-screen and un-rendered it
                // ("messages hide when I scroll"), and every scrollTo landed in
                // estimated space (the overshoot family of bugs). A plain VStack
                // measures ALL rows up front: nothing hides, every scroll targets
                // real layout. History is capped (~200 rows) and MessageRow is
                // .equatable(), so the one-time layout cost is small and masked
                // by the reveal loader.
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    if loadingHistory {
                        MyMuLoader().frame(maxWidth: .infinity).padding(.top, 24)
                    }
                    // The first page is the most RECENT messages; anything older
                    // was previously unreachable on the phone. Explicit button
                    // rather than infinite scroll: fetching prepends content
                    // above the viewport, and doing that on a scroll gesture
                    // fights the bottom-anchoring this transcript relies on.
                    if relay.hasMore == true && !loadingHistory {
                        Button {
                            Task { await loadOlder() }
                        } label: {
                            HStack(spacing: 6) {
                                if loadingOlder {
                                    ProgressView().scaleEffect(0.7).tint(Theme.primary)
                                } else {
                                    Image(systemName: "arrow.up").font(.caption2)
                                }
                                Text(loadingOlder ? "Loading…" : "Load earlier messages")
                                    .font(.caption)
                            }
                            .foregroundColor(Theme.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .disabled(loadingOlder)
                    }
                    if let loadError {
                        Text(loadError).font(.footnote).foregroundColor(Theme.danger)
                    }
                    // ONE ForEach for the whole transcript: row identity never
                    // moves between containers, so starting a new turn can't
                    // re-create (and crossfade) the previous turn's rows.
                    ForEach(displayItems) { item in
                        row(item)
                    }
                    // Bottom anchor for scrollTo AND the active-turn spacer: the
                    // blank space that pads the sent bubble's turn out to the
                    // viewport height. Its top edge marks where the rows end.
                    // The column's bottom padding lives INSIDE it, so "scroll to
                    // bottom" (which aligns this view's bottom edge) reaches the
                    // true end of the content — with the padding outside, every
                    // pin stopped one padding short.
                    Color.clear
                        .frame(height: Self.columnPadding + max(1, anchorTurn ? activeTurnSpacer : 1))
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ActiveTurnGeometryKey.self,
                                                   value: [ActiveTurnGeometryKey.spacerTop: g.frame(in: .named("chatScroll")).minY])
                        })
                        .id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, Self.columnPadding)
                // Reading column (iPad): cap the transcript at a comfortable line
                // length instead of letting bubbles stretch edge-to-edge on wide
                // screens. A no-op on iPhone, where the viewport is already
                // narrower than the cap.
                .frame(maxWidth: Theme.maxContentWidth)
                // Bottom-align SHORT transcripts: force the content at least as tall
                // as the viewport and bottom-align it, so a few messages rest on the
                // composer instead of floating at the top. defaultScrollAnchor alone
                // does not do this — it only positions OVERFLOWING content. `.bottom`
                // (not `.bottomLeading`) also centers the capped column above within
                // the full-width scroll viewport.
                .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .bottom)
                // The whole content block's frame in scroll-viewport space: its
                // height (short-transcript alignment) AND where its bottom edge
                // sits (the gap guard). Always measured — unlike a lazy row, this
                // background can't be recycled away in the over-scrolled state.
                .background(GeometryReader { g in
                    Color.clear.preference(key: ContentFrameKey.self,
                                           value: ContentFrame(named: g.frame(in: .named("chatScroll")),
                                                               global: g.frame(in: .global)))
                })
            }
            // Native bottom anchoring for LONG transcripts: the scroll rests at the
            // true bottom on open and sticks there as content grows or shrinks, which
            // is what the manual scrollTo/settle timers were approximating.
            .defaultScrollAnchor(.bottom)
            .coordinateSpace(name: "chatScroll")
            // Scroll-driven bottom tracking (iOS 18+). The ContentFrameKey
            // preference below only re-fires on LAYOUT changes — a pure finger
            // scroll lays nothing out, so `atBottom` froze at true: the ↓ jump
            // button never appeared and follow-mode never re-armed on a manual
            // return to the bottom. ScrollGeometry fires on every offset change;
            // the preference stays as the layout-time signal (and the only one
            // on iOS 17).
            .modifier(BottomEdgeTracker(threshold: ChatScroll.jumpButtonThreshold) { nearBottom, distance in
                debugTrackerDistance = distance
                if nearBottom != atBottom {
                    atBottom = nearBottom
                    if nearBottom { followMode = true }
                }
            })
            .onAppear { viewportHeight = outer.size.height }
            .onChange(of: outer.size.height) { h in
                let delta = h - viewportHeight
                viewportHeight = h
                guard followMode, abs(delta) > 8 else { return }
                if delta < -60 {
                    // Keyboard OPENING: ride the system animation with ONE
                    // animated pin — repeated instant snaps mid-animation yanked
                    // the transcript up "in a flaky way". A silent correction
                    // after the animation settles catches any drift.
                    withAnimation(.easeOut(duration: ChatScroll.keyboardOpenDuration)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + ChatScroll.keyboardOpenCorrection) {
                        if followMode { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                } else if delta > 60 {
                    // Keyboard DISMISSING (viewport grows): a single scrollTo
                    // loses the race against the inset animation and the view
                    // settles over-scrolled (blank strip below the last message,
                    // "have to scroll up") — re-pin across the animation frames.
                    settleToBottom(proxy)
                } else {
                    // Composer grew/shrank a line or two (typing wraps, clearing
                    // on send, attachment chips). These small deltas used to be
                    // ignored, hiding the transcript's last lines behind the
                    // composer — one instant pin plus a settle correction keeps
                    // the bottom flush without animation storms. During a send
                    // glide, stand down: the glide owns this.
                    guard Date() >= glideUntil else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                    DispatchQueue.main.asyncAfter(deadline: .now() + ChatScroll.composerCorrection) {
                        if followMode { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
            .onPreferenceChange(ContentFrameKey.self) { cf in
                let frame = cf.named
                debugGlobalBottom = cf.global.maxY
                contentHeight = frame.height
                contentBottom = frame.maxY
                // Geometry-derived bottom-ness (replaces the lazy sentinel's
                // appear/disappear): at bottom ⇔ the content's bottom edge sits
                // at/inside the viewport. Reaching it re-arms follow-mode, same
                // as the sentinel's onAppear used to.
                let nearBottom = frame.maxY <= viewportHeight + ChatScroll.jumpButtonThreshold
                // First bottom CONTACT reveals — not just a change-edge.
                // `atBottom` STARTS true, and a warm-started transcript lays
                // out already at the bottom, so the onChange-only reveal could
                // never fire and stranded the chat behind the 0.7s fallback
                // (the "still a second of loading" Manar reported, 2026-09-19).
                if nearBottom, !loadingHistory, !revealed { revealed = true }
                if nearBottom != atBottom {
                    atBottom = nearBottom
                    if nearBottom { followMode = true }
                }
                scheduleGapRepair(proxy)
            }
            // The active turn's measured extent → the spacer that pads it out
            // to the viewport. Rows growing (the reply streaming) shrink the
            // spacer by the same amount, so the content height — and the
            // scroll position — stay put until the turn genuinely overflows.
            .onPreferenceChange(ActiveTurnGeometryKey.self) { geo in
                guard anchorTurn, viewportHeight > 0,
                      let anchorTop = geo[ActiveTurnGeometryKey.anchorTop],
                      let spacerTop = geo[ActiveTurnGeometryKey.spacerTop] else { return }
                // Rows from the sent bubble's top edge to where the spacer
                // starts (the VStack spacing before the spacer excluded).
                let rowsHeight = spacerTop - Self.rowSpacing - anchorTop
                // The turn must span: column top padding → bubble → rows →
                // spacing → spacer → column bottom padding = the viewport, so
                // that resting at the bottom puts the bubble's top exactly one
                // column padding below the top edge.
                let box = viewportHeight - Self.columnPadding * 2 - Self.rowSpacing
                let wanted = max(1, box - rowsHeight)
                guard abs(wanted - activeTurnSpacer) > 0.5 else { return }
                let grew = wanted > activeTurnSpacer
                activeTurnSpacer = wanted
                // The spacer GROWING (re-open mid-turn, keyboard dismissed, the
                // ball leaving at turn end) adds content below the fold; stay
                // on the bottom silently so the bubble keeps its place. A
                // shrink (the reply growing into the box) moves nothing and
                // needs no scroll. During the send glide the glide owns it.
                if grew, followMode, Date() >= glideUntil {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            // Send: one soft glide to the bottom — which, thanks to the active
            // turn's spacer, IS the sent bubble at the top of the viewport. A
            // beat first so the bubble and the spacer have real layout. One
            // silent clamp after the glide, and only for SMALL drift (composer
            // collapse, keyboard insets); anything bigger is real content and
            // belongs to the eased follow — a silent snap across a real row is
            // what read as "scrolls, disappears, reappears" (Manar).
            .onChange(of: sendTick) { _ in
                glideUntil = Date().addingTimeInterval(ChatScroll.sendSettle)
                DispatchQueue.main.asyncAfter(deadline: .now() + ChatScroll.sendDelay) {
                    withAnimation(ChatScroll.sendAnimation) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + ChatScroll.sendSettle) {
                    guard followMode else { return }
                    let drift = contentBottom - viewportHeight
                    if abs(drift) <= ChatScroll.settleTolerance {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } else if drift > 0 {
                        withAnimation(ChatScroll.followAnimation) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            // An explicit upward drag is the ONE gesture that means "stop following".
            // 24pt: a real "scroll up to read" clears it instantly, but the finger
            // wobble of a tap or an interactive keyboard-dismiss drag doesn't —
            // a 12pt trigger disarmed following almost every touch, so replies
            // streamed in below the fold ("chat scrolled away after I sent").
            .simultaneousGesture(
                DragGesture().onChanged { v in
                    if v.translation.height > 24 { followMode = false }
                }
            )
            // Follow content mutations (stream chunks included) with a beat, then
            // an EASED scroll — never instantly. The beat (followDelay) lets the
            // just-appended row lay out, so the scroll targets a bottom that has
            // stopped moving; bursts coalesce into one scheduled scroll. The ease
            // (followDuration) is what keeps an arriving message from reading as a
            // twitch. While the active turn still fits its box the bottom hasn't
            // moved and this is a no-op — the reply grows in place.
            .onChange(of: relay.revision) { _ in
                guard followMode, Date() >= glideUntil else { return }
                if revisionScrollPending { return }
                revisionScrollPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + ChatScroll.followDelay) {
                    revisionScrollPending = false
                    guard followMode, Date() >= glideUntil else { return }
                    withAnimation(ChatScroll.followAnimation) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + ChatScroll.followCorrection) {
                        if followMode, Date() >= glideUntil {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
            // Initial jump after history load: row heights settle over several
            // frames, so re-pin the bottom a few times, non-animated. The transcript
            // stays INVISIBLE (opacity 0 + loader) while that happens — the user
            // must never watch the view "scroll fast to the bottom"; it appears
            // already sitting on the last message (the iMessage open behavior).
            .onChange(of: loadingHistory) { loading in
                if !loading {
                    settleToBottom(proxy)
                    armRevealFallback()
                }
            }
            .onChange(of: atBottom) { isAtBottom in
                if isAtBottom && !loadingHistory { revealed = true }
                // Debounced ↓ button: hide instantly on bottom contact, but only
                // SHOW once the bottom has stayed lost for the appear delay — a
                // send/stream append loses the bottom for the beat before the
                // follow glide lands, and the arrow blinking through that beat
                // read as a glitch (Manar, 2026-09-13).
                jumpButtonTask?.cancel()
                if isAtBottom {
                    showJumpButton = false
                } else {
                    jumpButtonTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(ChatScroll.jumpButtonAppearDelay * 1_000_000_000))
                        guard !Task.isCancelled, !atBottom else { return }
                        showJumpButton = true
                    }
                }
            }
            .opacity(revealed ? 1 : 0)
            .overlay {
                if !revealed {
                    MyMuLoader().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showJumpButton && revealed {
                    Button {
                        followMode = true
                        // Eased travel, then settle: the VStack is non-lazy so
                        // every row is really measured and an animated jump can't
                        // land in estimated space any more (the old reason this
                        // was a hard cut). The settle re-pins any residual drift.
                        glideToBottom(proxy)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .frame(width: 36, height: 36)
                            .background(Theme.elevated)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    }
                    .accessibilityIdentifier("jump-to-bottom")
                    .padding(.trailing, 16)
                    .padding(.bottom, 10)
                    // Fade + scale in, so the button arrives as the user scrolls
                    // away rather than popping into the corner. Reduced Motion
                    // drops the scale (fade only).
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: ChatScroll.jumpButtonFade), value: showJumpButton)
            // Field-debugging HUD for scroll edge cases (Manar's step 4 reports):
            // MYMU_SCROLL_DEBUG=1 paints the live geometry the scroll rules
            // read, so a flaky moment can be read off a screenshot. DEBUG only.
            .overlay(alignment: .topLeading) {
                #if DEBUG
                if Self.scrollDebug {
                    Text(String(format: "vp %.0f ch %.0f cb %.0f gb %.0f trk %.0f\natBottom %@ follow %@ anchor %@ spacer %.0f jump %@",
                                viewportHeight, contentHeight, contentBottom, debugGlobalBottom, debugTrackerDistance,
                                atBottom ? "Y" : "n", followMode ? "Y" : "n", anchorTurn ? "Y" : "n",
                                activeTurnSpacer, showJumpButton ? "Y" : "n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.yellow)
                        .padding(4)
                        .background(Color.black.opacity(0.6))
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("scroll-debug")
                }
                #endif
            }
        }
        }
    }

    #if DEBUG
    private static let scrollDebug = ProcessInfo.processInfo.environment["MYMU_SCROLL_DEBUG"] == "1"
    #endif

    /// One transcript row, with the transition that makes it ARRIVE the way
    /// the choreography wants: the sent bubble flies up from the composer, the
    /// ball dissolves, a reply row fades in where the ball was. The sent
    /// bubble (the active turn's anchor) also reports its top edge for the
    /// spacer maths.
    @ViewBuilder
    private func row(_ item: DisplayItem) -> some View {
        switch item {
        case .single(let m):
            let isAnchor = anchorTurn && m.id == relay.activeTurnUserId
            MessageRow(message: m, projectId: projectId, token: chatToken,
                       origin: origin, showActions: m.id == lastAssistantTextId)
                .equatable()
                .background(GeometryReader { g in
                    Color.clear.preference(key: ActiveTurnGeometryKey.self,
                                           value: isAnchor ? [ActiveTurnGeometryKey.anchorTop: g.frame(in: .named("chatScroll")).minY] : [:])
                })
                .id(m.id)
                .transition(m.role == "user" ? ChatScroll.userBubbleTransition : ChatScroll.assistantRowTransition)
        case .toolGroup(let id, let members):
            ToolGroupRow(members: members,
                         expanded: expandedGroups.contains(id),
                         toggle: {
                             if expandedGroups.contains(id) { expandedGroups.remove(id) }
                             else { expandedGroups.insert(id) }
                         },
                         projectId: projectId, token: chatToken, origin: origin)
                .id(id)
                .transition(ChatScroll.assistantRowTransition)
        case .pendingIndicator:
            pendingIndicatorRow
                .id("pending-indicator")
                .transition(ChatScroll.pendingTransition)
        }
    }

    /// True when the transcript's bottom edge is resting visibly above the fold
    /// while there is enough content to fill the screen — a phantom blank strip
    /// (over-scrolled past the end). Reading history puts the bottom BELOW the
    /// fold (maxY > viewport), so this can never fire on a user who scrolled up.
    private var hasPhantomGap: Bool {
        viewportHeight > 0
            && contentHeight > viewportHeight + 1
            && contentBottom < viewportHeight - 8
    }

    /// Debounced repair: rubber-band bounces and in-flight layout put the
    /// sentinel above the fold transiently, so only a gap that SURVIVES ~½s is
    /// real. scrollTo just clamps to the true bottom — a no-op when legitimate.
    private func scheduleGapRepair(_ proxy: ScrollViewProxy) {
        gapRepair?.cancel()
        guard hasPhantomGap else { return }
        gapRepair = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(ChatScroll.gapRepairDebounce * 1_000_000_000))
            guard !Task.isCancelled, hasPhantomGap else { return }
            proxy.scrollTo("bottom", anchor: .bottom)
            // One scrollTo can lose to an in-flight inset animation (keyboard) —
            // confirm the pin took, repair once more if the gap survived.
            try? await Task.sleep(nanoseconds: UInt64(ChatScroll.gapRepairConfirm * 1_000_000_000))
            guard !Task.isCancelled, hasPhantomGap else { return }
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    /// Reveal on first bottom contact (see onPreferenceChange / onChange
    /// (atBottom)) with a hard fallback so an odd layout can never leave the
    /// chat permanently hidden.
    private func armRevealFallback() {
        DispatchQueue.main.asyncAfter(deadline: .now() + ChatScroll.revealFallback) { revealed = true }
    }

    /// One transcript entry: a lone message, a run of consecutive tool
    /// activity collapsed behind a summary row (web parity: ToolGroupContainer),
    /// or the live-turn indicator.
    enum DisplayItem: Identifiable {
        case single(ChatMessage)
        case toolGroup(id: String, [ChatMessage])
        /// Rendered INLINE, in the exact spot the reply will land — not a
        /// floating overlay — so the pulsing ball visually turns into the
        /// streamed text (ChatGPT app feel; Manar, field ref 2026-10-24).
        case pendingIndicator
        var id: String {
            switch self {
            case .single(let m): return m.id
            case .toolGroup(let id, _): return id
            case .pendingIndicator: return "pending-indicator"
            }
        }
    }

    /// Group runs of ≥3 consecutive tool/thinking rows. The run at the
    /// transcript's END stays ungrouped while a turn is live — collapsing work
    /// as it happens would make the agent look stalled; it folds up when the
    /// next text lands or the turn ends. Group id = first member's id: stable
    /// as members append, unique per group.
    private var displayItems: [DisplayItem] {
        let groupable: Set<String> = ["tool_use", "tool_result", "thinking"]
        var out: [DisplayItem] = []
        var run: [ChatMessage] = []
        func flush(isTail: Bool) {
            defer { run = [] }
            guard !run.isEmpty else { return }
            let liveTail = isTail && relay.isLoading
            if run.count >= 3 && !liveTail {
                out.append(.toolGroup(id: "tg-\(run[0].id)", run))
            } else {
                out.append(contentsOf: run.map { .single($0) })
            }
        }
        for m in visibleMessages {
            if groupable.contains(m.kind) {
                run.append(m)
            } else {
                flush(isTail: false)
                out.append(.single(m))
            }
        }
        flush(isTail: true)
        // The live turn's indicator is the transcript's own last row: the ball
        // where the reply is about to appear, then (as rows land) the ball
        // under them — "more coming" — with the activity read-out beside it.
        if relay.isLoading, !loadingHistory, revealed {
            out.append(.pendingIndicator)
        }
        return out
    }

    /// The pulsing ball in the gutter, the activity/elapsed/token read-out in
    /// one muted line beside it. The row is as tall as a text line so the
    /// first streamed line replaces it without a height jump.
    private var pendingIndicatorRow: some View {
        HStack(alignment: .center, spacing: 10) {
            PulsingBallIndicator()
            if visibleActivity != nil || relay.turnStartedAt != nil || (relay.turnTokens ?? 0) > 0 {
                HStack(spacing: 4) {
                    if let activity = visibleActivity {
                        Text(activity + "…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.text.opacity(0.75))
                            .lineLimit(1)
                    }
                    if let t = relay.turnStartedAt {
                        TimelineView(.periodic(from: t, by: 1)) { ctx in
                            Text((visibleActivity != nil ? "· " : "") + Self.elapsedLabel(from: t, to: ctx.date))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Theme.mutedText)
                        }
                    }
                    if let tok = relay.turnTokens, tok > 0 {
                        let needsSeparator = visibleActivity != nil || relay.turnStartedAt != nil
                        Text((needsSeparator ? "· " : "") + "\(Self.tokensLabel(tok)) tokens")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.mutedText)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(minHeight: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Generating response")
    }

    /// Only messages that actually paint pixels. Hidden kinds (thinking, system,
    /// stream bookkeeping…) used to render as EMPTY rows — and LazyVStack still
    /// inserts its 18pt spacing around each one, so a run of 30 tool-internal
    /// messages produced a ~500pt phantom gap (the "big space" in heavy
    /// tool-driven conversations). Filtering here removes the empty rows entirely.
    private var visibleMessages: [ChatMessage] {
        // isBlank early-exits at the first non-whitespace character and allocates
        // nothing — trimmingCharacters COPIED each message's whole content, which
        // made this filter O(total transcript bytes) per render (typing crawled
        // in conversations holding megabyte tool outputs).
        func isBlank(_ s: String) -> Bool { s.allSatisfy(\.isWhitespace) }
        return relay.messages.filter { m in
            switch m.kind {
            case "text":
                return !isBlank(m.bodyText) || (m.images?.isEmpty == false)
            case "tool_use", "error":
                return true
            // Reasoning models (DeepSeek via opencode) spend most of a turn here.
            // Hiding it left the transcript blank while the model worked, which
            // read as the app being frozen.
            case "tool_result", "thinking":
                return !isBlank(m.content ?? "")
            default:
                return false
            }
        }
    }

    /// Id of the newest assistant text message — the only one that gets a visible
    /// action row (the apps keep older messages clean; long-press still copies).
    private var lastAssistantTextId: String? {
        relay.messages.last(where: { $0.kind == "text" && $0.role != "user" })?.id
    }

    /// The activity worth spelling out. A generic "Working" duplicates the
    /// ball beside it and reads as message text, so it shows nothing —
    /// only a specific activity ("Reading files", "Running a command") does.
    private var visibleActivity: String? {
        let activity = turnActivity
        return activity == "Working" ? nil : activity
    }

    /// What the agent is doing right now, from the newest transcript frame.
    /// A specific backend status ("Waiting for permission") wins over it.
    private var turnActivity: String {
        if let s = relay.statusText, !s.isEmpty, s != "Processing", s != "Working..." { return s }
        for m in relay.messages.reversed() {
            switch m.kind {
            case "tool_use":
                return Self.activityLabel(for: m.toolName)
            case "tool_result", "error":
                return "Working"     // last tool finished — deciding the next step
            case "text":
                return m.role == "user" ? "Working" : "Writing"
            default:
                continue
            }
        }
        return "Working"
    }

    /// Human activity label for a tool in use (mirrors the web client's map).
    static func activityLabel(for tool: String?) -> String {
        switch tool ?? "" {
        case "Bash": return "Running a command"
        case "Read": return "Reading files"
        case "Edit", "Write", "ApplyPatch", "MultiEdit", "NotebookEdit": return "Editing files"
        case "Grep", "Glob": return "Searching the code"
        case "WebFetch", "WebSearch": return "Browsing the web"
        case "Task", "Agent": return "Running a subagent"
        case "TodoWrite": return "Planning"
        case "SendUserFile": return "Sending a file"
        case "AskUserQuestion": return "Asking a question"
        case "": return "Working"
        case let t: return "Using \(t)"
        }
    }

    /// Pin the viewport to the bottom across the frames layout needs to resolve
    /// real row heights (a single scroll lands mid-list or past the end).
    /// Un-animated by design: used where the user must NOT see travel (history
    /// load, keyboard dismiss). For a visible jump use `glideToBottom`.
    private func settleToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo("bottom", anchor: .bottom)
        for delay in ChatScroll.settleTaps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if followMode { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// Visible, eased travel to the bottom — the jump-to-bottom button. Unlike
    /// `settleToBottom` the motion is the point: the user asked to go somewhere,
    /// and a cut leaves them unsure whether the transcript moved or reloaded.
    /// The un-animated settle taps follow to clamp any residual drift once the
    /// glide has landed.
    private func glideToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(ChatScroll.jumpAnimation) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + ChatScroll.jumpDuration) {
            if followMode { settleToBottom(proxy) }
        }
    }

    // MARK: /clear

    /// Slash commands run entirely inside the agent's own CLI — the relay
    /// forwards `/clear` as plain text with no special handling on either end,
    /// so a local clear often never emits the "complete" frame that normally
    /// triggers a reconcile. Without that frame the transcript just sits
    /// stale until the conversation is closed and reopened (the bug Manar
    /// reported — "I have to go out and come back"). This banner is the
    /// client reacting on its own, like the harness does: visible feedback
    /// the moment it's pressed, backed by `beginClearRecovery` polling the
    /// history fetch directly instead of waiting on a frame that may not come.
    private var clearingBanner: some View {
        HStack(spacing: 10) {
            MyMuLoader()
            Text("Clearing conversation…")
                .font(.subheadline)
                .foregroundColor(Theme.mutedText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.border), alignment: .top)
    }

    private func isClearCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/clear"
    }

    /// Polls the history fetch directly (bypassing the normal `isLoading`-gated
    /// reconcile) until the transcript visibly resets or a bounded number of
    /// tries elapses. `forceReconcile` reuses the existing `mergingLiveTail`
    /// merge — already built to trust the fetch wholesale on a `/clear`/
    /// compaction restart — so this adds a polling loop on top, not new merge
    /// logic. Also kicks `ensureConnected()` once up front: the same dead-
    /// socket-after-backgrounding risk applies here too.
    private func beginClearRecovery() {
        clearingConversation = true
        anchorTurn = false
        let beforeCount = relay.messages.count
        let beforeFirstId = relay.messages.first?.id
        relay.ensureConnected()
        Task {
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await relay.forceReconcile()
                if relay.messages.count < beforeCount || relay.messages.first?.id != beforeFirstId {
                    break
                }
            }
            clearingConversation = false
            // A /clear has nothing left to "complete" — if isLoading is still
            // stuck true once the fetch has settled, there's no real turn
            // running and the working indicator would otherwise hang forever.
            if relay.isLoading { relay.isLoading = false }
        }
    }

    private func permissionBanner(_ p: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundColor(Theme.primary)
                Text("Permission: \(p.toolName ?? "tool")").font(.subheadline).fontWeight(.semibold).foregroundColor(Theme.text)
            }
            HStack {
                Button("Deny") {
                    if let id = p.requestId { relay.answerPermission(requestId: id, allow: false) }
                }
                .buttonStyle(.bordered)
                .tint(Theme.mutedText)
                Button("Allow") {
                    if let id = p.requestId { relay.answerPermission(requestId: id, allow: true) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.primary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.border), alignment: .top)
    }

    /// "412" / "4.2k" / "112k" — tokens generated this turn, CLI-style.
    static func tokensLabel(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 100_000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n / 1000)k"
    }

    /// "42s" / "4m 12s" / "1h 04m" — how long the agent has been working.
    static func elapsedLabel(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }

    // MARK: open

    private func start() async {
        if let previewMessages {
            relay.setHistory(previewMessages)
            relay.isLoading = true
            loadingHistory = false
            #if DEBUG
            // Simulate a turn COMPLETING: drop the loader + shrink the transcript
            // (like the end-of-turn history reconcile) to prove no gap opens below.
            if ProcessInfo.processInfo.environment["MYMU_DEMO_SHRINK"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    relay.isLoading = false
                    relay.setHistory(Array(previewMessages.prefix(max(1, previewMessages.count - 5))))
                }
            }
            #endif
            return
        }
        // Offline demo agent chat: render the canned per-agent transcript, no
        // network (there is no token — a fetch just produced an error screen).
        // Same content the swipe switcher previews, so a switch commit lands
        // on identical pixels, and the reviewer's demo swipe works offline.
        if appState.isDemo && isRemote {
            relay.persistenceEnabled = false
            if relay.messages.isEmpty {
                relay.setHistory(DemoData.agentTranscripts[relay.sessionId] ?? DemoData.messages)
            }
            loadingHistory = false
            return
        }
        // Use the relay's CURRENT id — a new conversation starts with "" and gets
        // rebound by session_created; tab-return re-runs then fetch the real id.
        let sid = relay.sessionId
        guard !sid.isEmpty else {
            loadingHistory = false
            relay.connect()
            return
        }
        if relay.hasLoadedOnce {
            // LOCAL-FIRST re-open: the store holds this conversation exactly as
            // it was left (the same instance, or re-seeded from its snapshot).
            // It is already on screen. Re-attach the stream — the server
            // replays what this device missed, absorbed against what's here —
            // and let a quiet merge catch anything older than the replay
            // buffer. Nothing hides, nothing swaps wholesale.
            loadingHistory = false
            armRevealFallback()
            relay.ensureConnected()
            return
        }
        // Cold open: disk snapshot first (instant, if one exists), then the
        // fetch merges in whatever is newer.
        let cacheable = isRemote && !appState.isDemo
        if cacheable, relay.messages.isEmpty, let cached = await ChatCacheStore.shared.load(sessionId: sid) {
            relay.adoptSnapshot(cached)
            anchorTurn = relay.isLoading && relay.activeTurnUserId != nil
            loadingHistory = false
        }
        do {
            let h = try await APIClient(token: chatToken, origin: origin).history(sessionId: sid)
            relay.adoptHistory(h)
        } catch {
            // With a cached transcript on screen, a failed refresh must not
            // slap an error banner over readable content — the socket's own
            // reconnect handling narrates connectivity.
            if relay.messages.isEmpty { loadError = error.localizedDescription }
        }
        loadingHistory = false
        relay.connect()
    }

    /// Conversation actions: commands, files, export. Mode and model picking
    /// live on the status strip under the title, not in here.
    private var conversationMenu: some View {
        Menu {
            // Permission and model moved OUT of here onto the status strip
            // under the title — picking happens where the state shows. This
            // menu keeps only the actions, so it's three rows and never
            // paginates (the old flat version ran to three screens).
            Section {
                Button {
                    showCommands = true
                } label: {
                    Text("Commands")
                    Image(systemName: "slash.circle")
                }
                NavigationLink {
                    FilesView(projectId: projectId, token: chatToken, title: title, origin: origin)
                } label: {
                    Text("Files")
                    Image(systemName: "folder")
                }
                // Exports what's LOADED, not the whole server-side session —
                // "Load earlier messages" first if you want the rest.
                ShareLink(item: transcriptMarkdown) {
                    Text("Export transcript")
                    Image(systemName: "square.and.arrow.up")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").foregroundColor(Theme.primary)
        }
        .accessibilityIdentifier("chat-menu")
        .accessibilityLabel("Conversation options. Permission mode: \(permissionMode.label)")
    }

    /// The loaded transcript as markdown, for ShareLink. Tool calls collapse to
    /// a one-line note — a share sheet is for reading and pasting elsewhere, and
    /// raw tool payloads (often tens of KB) would swamp the actual conversation.
    private var transcriptMarkdown: String {
        var out = ["# \(title)"]
        for m in visibleMessages {
            switch m.kind {
            case "text":
                let who = m.role == "user" ? "You" : "Agent"
                out.append("**\(who):** \(m.bodyText.trimmingCharacters(in: .whitespacesAndNewlines))")
            case "tool_use":
                out.append("_→ \(m.toolName ?? "tool")_")
            case "thinking":
                out.append("_(thinking)_")
            case "error":
                out.append("> ⚠︎ \(m.content ?? "error")")
            default:
                break
            }
        }
        return out.joined(separator: "\n\n")
    }

    /// Fetch the page BEFORE the oldest message currently held and prepend it.
    /// Offset is the count we already have: the endpoint pages backwards from
    /// the newest message, so "how many we've seen" is exactly the offset of the
    /// next older page.
    private func loadOlder() async {
        guard !loadingOlder, !relay.sessionId.isEmpty else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let h = try await APIClient(token: chatToken, origin: origin)
                .history(sessionId: relay.sessionId, limit: 200, offset: relay.messages.count)
            // Drop anything already present: a turn landing mid-fetch shifts the
            // window, which would otherwise duplicate rows.
            let known = Set(relay.messages.map(\.id))
            let older = h.messages.filter { !known.contains($0.id) }
            if !older.isEmpty { relay.prependHistory(older) }
            relay.hasMore = (h.hasMore ?? false) && !older.isEmpty
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// Reports whether the scroll position rests within `threshold` of the content's
/// bottom edge, re-evaluated on EVERY scroll offset change — the signal a finger
/// scroll actually produces (layout-time preferences don't fire for it). No-op
/// below iOS 18, where the ContentFrameKey preference remains the only tracker.
private struct BottomEdgeTracker: ViewModifier {
    let threshold: CGFloat
    /// (nearBottom, distance of the visible rect's bottom from the content's end)
    let onChange: (Bool, CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { g in
                g.contentSize.height - g.visibleRect.maxY
            } action: { _, distance in
                onChange(distance <= threshold, distance)
            }
        } else {
            content
        }
    }
}

/// Frame of the whole transcript block in the scroll view's own coordinate
/// space — height drives short-transcript alignment, maxY (the content's bottom
/// edge, directly comparable to the viewport height) drives the gap guard.
private struct ContentFrame: Equatable {
    var named: CGRect = .zero
    var global: CGRect = .zero
}

private struct ContentFrameKey: PreferenceKey {
    static var defaultValue = ContentFrame()
    /// Keep the one real measurement: with sibling subtrees now emitting
    /// preferences of their own (the row geometry), SwiftUI feeds this
    /// reducer their DEFAULT for this key too — a "last value wins" reducer
    /// ended up delivering a zero frame, which silently blinded every rule
    /// reading contentBottom/contentHeight (found with the scroll HUD,
    /// 2026-10-24).
    static func reduce(value: inout ContentFrame, nextValue: () -> ContentFrame) {
        let next = nextValue()
        if next != ContentFrame() { value = next }
    }
}

/// The two edges the active-turn spacer is computed from, in scroll space:
/// the sent bubble's top and the spacer's own top (= where the rows end).
/// Their difference is scroll-invariant; both come from one layout pass.
private struct ActiveTurnGeometryKey: PreferenceKey {
    static let anchorTop = "anchorTop"
    static let spacerTop = "spacerTop"
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// A collapsed run of consecutive tool activity: "▸ 7 steps · Bash, Read,
/// Edit". Tapping expands to the full rows in place. Keeps long transcripts
/// readable — a working agent produces dozens of tool rows per reply, and flat
/// they bury the actual conversation.
struct ToolGroupRow: View {
    let members: [ChatMessage]
    let expanded: Bool
    let toggle: () -> Void
    let projectId: String
    let token: String
    let origin: String?

    /// Unique tool names in first-use order; thinking reads as "thinking".
    private var summary: String {
        var seen: [String] = []
        for m in members {
            let name = m.kind == "thinking" ? "thinking" : (m.toolName ?? "tool")
            if m.kind == "tool_result" { continue }
            if !seen.contains(name) { seen.append(name) }
        }
        let names = seen.prefix(4).joined(separator: ", ")
        return seen.count > 4 ? names + "…" : names
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.mutedText)
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption2).foregroundColor(Theme.primary)
                    Text("\(members.count) steps")
                        .font(.caption.weight(.medium)).foregroundColor(Theme.text)
                    Text(summary)
                        .font(.caption).foregroundColor(Theme.mutedText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(members.count) tool steps, \(expanded ? "expanded" : "collapsed")")
            if expanded {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(members) { m in
                        MessageRow(message: m, projectId: projectId, token: token,
                                   origin: origin, showActions: false)
                            .equatable()
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.border).frame(width: 2).padding(.vertical, 2)
                }
            }
        }
    }
}

/// Subtitle strip under the agent name — tiny, and now the CONTROL surface:
/// "385k tokens · [mode icon] · sol5.2". The icon and the model shortcut are
/// both tappable menus, so changing mode or model happens exactly where the
/// state is displayed instead of two levels deep in the conversation menu.
/// The token count stays a plain number (the window total was a per-server
/// env-var guess and stays gone). Model shortcuts come from
/// ModelDisplay.compact ("opus4.7", "ds-v4-pro"); the model control only
/// renders when the server actually served a catalogue. While a history merge
/// is in flight the count gives way to a quiet "syncing" — the honest signal
/// that the server is being asked, without hiding anything.
struct ChatStatusStrip: View {
    let usage: ContextUsage?
    @Binding var mode: PermissionMode
    @Binding var model: String?
    let modelOptions: [APIClient.ModelOption]
    var syncing = false

    private var tokensLabel: String? {
        guard let n = usage?.usedTokens, n > 0 else { return nil }
        if n >= 1_000_000 { return String(format: "%.1fM tokens", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(Int((Double(n) / 1_000).rounded()))k tokens" }
        return "\(n) tokens"
    }

    var body: some View {
        HStack(spacing: 7) {
            if syncing {
                Text("syncing")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(Theme.mutedText.opacity(0.8))
                    .accessibilityLabel("Syncing with the server")
            } else if let t = tokensLabel {
                Text(t)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(Theme.mutedText)
            }
            Menu {
                ForEach(PermissionMode.allCases) { m in
                    Button {
                        mode = m
                        Haptics.send()
                    } label: {
                        Text(m.label)
                        Text(m.detail)
                        Image(systemName: m == mode ? "checkmark" : m.symbol)
                    }
                }
            } label: {
                // Generous frame around a small glyph — the visible mark stays
                // subtle but the tap target doesn't fight fingertips.
                Image(systemName: mode.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(mode == .default ? Theme.mutedText.opacity(0.8) : mode.tint)
                    .frame(minWidth: 26, minHeight: 20)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("strip-permission")
            .accessibilityLabel("Permission mode: \(mode.label)")
            if !modelOptions.isEmpty {
                Menu {
                    ForEach(modelOptions) { option in
                        Button {
                            model = option.value
                            Haptics.send()
                        } label: {
                            Text(ModelDisplay.compact(option.value))
                            Text(option.description ?? option.label)
                            Image(systemName: option.value == model ? "checkmark" : "cpu")
                        }
                    }
                } label: {
                    Text(ModelDisplay.compact(model ?? "default"))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.primary)
                        .frame(minHeight: 20)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("strip-model")
                .accessibilityLabel("Model: \(ModelDisplay.compact(model ?? "default"))")
            }
        }
        .lineLimit(1)
        .animation(.easeOut(duration: 0.2), value: syncing)
    }
}
