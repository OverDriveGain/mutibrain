import SwiftUI
import Combine
import UIKit

/// In-chat agent switching (Manar, 2026-09-19). A live chat view can't be
/// page-dragged like a photo carousel — each chat owns a relay socket and a
/// freshly loaded transcript, so there is nothing real to show mid-drag.
/// Instead the swipe raises a FULL-SCREEN switcher over the transcript
/// (Manar's 2026-09-19 UX call — the old top chip was too small to read):
/// each page IS the agent's conversation as its chat renders it — same
/// MessageRow, same spacing, fed from the warm-start cache the destination
/// chat opens with (a cache miss shows the app's own loader). No card
/// chrome, no summary header: an earlier card design repeated what the
/// title strip and the transcript already said, and Manar killed it as
/// redundant (2026-09-20). After the raising swipe the pages swipe natively
/// (paged TabView — the standard iOS pager), with a scrollable title strip
/// on top naming every agent, the settle bar right under it.
/// When the finger lifts a short countdown "settles" the choice —
/// visible as a draining bar. Tapping the card commits immediately; TYPING
/// commits immediately too, carrying the draft into the new chat (the
/// composer stays reachable below the overlay). Swiping back to the current
/// agent (or letting it settle there) cancels. Only the COMMIT navigates,
/// reusing the notification path's machinery: a ChatTarget handed to
/// MainTabView, which swaps the visible chat route in place (RouteView's
/// .id(sessionId) rebuilds the conversation cleanly). The handover is a true
/// CROSS-DISSOLVE even though this whole view unmounts at the swap: commit
/// snapshots the window, MainTabView floats the snapshot over the swapped-in
/// chat and fades it out — and since the page IS the destination transcript,
/// the dissolve reads as the switcher chrome melting away (Manar's
/// 2026-09-20 call; the earlier fade-through-black showed a beat of black).
@MainActor
final class ChatSwitcher: ObservableObject {
    static let shared = ChatSwitcher()

    /// Set when a switch settles; MainTabView observes it and replaces the
    /// visible chat route in the CURRENT tab — same ChatTarget contract as
    /// PushManager.pendingTarget, minus the forced jump to the Agents tab.
    @Published var target: ChatTarget?

    /// Composer keystrokes, forwarded on every draft change. While the
    /// switcher is raised, typing means "switch NOW and take my text along" —
    /// watching the draft directly (not UIKit keyboard notifications) keeps
    /// this deterministic across SwiftUI's text-field backing changes.
    let typing = PassthroughSubject<String, Never>()

    /// Draft carried across a type-to-switch: the destination chat's composer
    /// consumes it, so the keystrokes that triggered the switch are not lost.
    var handoffDraft: String?
    func takeDraft() -> String? { defer { handoffDraft = nil }; return handoffDraft }

    /// Window snapshot taken at commit, set right before `target`. MainTabView
    /// floats it over the swapped-in chat and dissolves it — a real cross-fade
    /// across the route swap, which is otherwise impossible (the outgoing view
    /// unmounts the moment the path changes).
    var dissolveSnapshot: UIImage?
    func takeDissolveSnapshot() -> UIImage? { defer { dissolveSnapshot = nil }; return dissolveSnapshot }

    /// The candidate while the switcher is raised, nil when it is down. The
    /// hosting ChatView swaps its nav-bar title to THIS agent's identity so
    /// the top of the screen never contradicts the page being previewed (the
    /// stale original title over a different agent's conversation read as two
    /// agents at once — Manar, 2026-09-20).
    @Published var previewing: Project?
}

/// Attached to the transcript area of agent chats. Owns the horizontal-swipe
/// gesture, the full-screen switcher overlay, and the settle countdown.
@MainActor
struct AgentSwitcherModifier: ViewModifier {
    let currentProjectId: String
    let currentTitle: String
    /// Local sessions have no roster to switch across — the modifier is inert.
    let enabled: Bool

    @EnvironmentObject private var store: ProjectsStore

    /// Candidate roster index while the switcher is up; nil = idle (hidden).
    @State private var candidate: Int?
    /// Candidate when the ACTIVE raising drag began — that one drag steps
    /// relative to where it started; once the finger lifts, the overlay's own
    /// pager owns further swipes.
    @State private var dragBase: Int?
    @State private var dragging = false
    @State private var settleTask: Task<Void, Never>?
    /// 1 → 0 across the settle window; drawn as the draining bar.
    @State private var settleProgress: CGFloat = 1
    /// Reentry guard: a commit fired and the route swap is about to unmount
    /// this view — ignore further gestures/keystrokes in the gap.
    @State private var committing = false

    /// Horizontal travel that raises the switcher and counts as the first
    /// step. Also the dead zone for returning to the drag base. Close to the
    /// ORIGINAL light feel: text selection is hard-gated by
    /// TextSelectionMonitor now, so the round-1 heavy thresholds (72pt travel,
    /// 2.2× dominance, 350pt/s velocity floor) that made intentional swipes
    /// feel dead and flaky are gone (Manar, 2026-09-29: "I want it smooth").
    private let activation: CGFloat = 44
    /// Additional travel per further step within the raising drag.
    private let stepWidth: CGFloat = 130
    /// Finger-up → commit. Long enough to read the card and swipe again,
    /// short enough that settling never feels like waiting — 1.4s read as
    /// "stuck before switching" (Manar, 2026-09-29). The env override
    /// exists for UI tests/screenshots ONLY: XCUITest's post-gesture idle
    /// wait outlives the window, so marketing shots hold the overlay open.
    private var settleDelay: Double {
        ProcessInfo.processInfo.environment["MYMU_SWITCHER_HOLD"] == "1" ? 30 : 0.9
    }
    /// Leading strip left untouched — that's the system back-swipe's edge
    /// (edge drags colliding with back navigation is the classic carousel
    /// mistake).
    private let edgeGuard: CGFloat = 44

    private var roster: [Project] { store.agents }
    /// projectId first; title as fallback (notification-born chats can carry
    /// a projectId minted from a rotated session id).
    private var currentIndex: Int? {
        roster.firstIndex { $0.projectId == currentProjectId }
            ?? roster.firstIndex { $0.displayName == currentTitle }
    }

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(dragGesture)
            .overlay {
                if let c = candidate, roster.indices.contains(c) { switcherOverlay(c) }
            }
            .onReceive(ChatSwitcher.shared.typing) { handleTyping($0) }
            // Leaving the chat with the switcher still raised (back swipe)
            // must not strand the title override on the next screen.
            .onDisappear {
                if candidate != nil { ChatSwitcher.shared.previewing = nil }
            }
    }

    // MARK: gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 25, coordinateSpace: .local)
            .onChanged { v in
                guard enabled, !committing, let current = currentIndex, roster.count > 1 else { return }
                let w = v.translation.width
                if !dragging {
                    // A LIVE TEXT SELECTION blocks activation outright. The
                    // thresholds below can only make accidental raises rarer —
                    // a fast handle drag momentarily beats any speed bar
                    // (2026-09-29 round 2: thresholds alone still swiped while
                    // marking text). The monitor knows selection state exactly,
                    // and keeps blocking for a beat after it clears so the
                    // dismissing tap-drag can't raise the switcher either.
                    guard !TextSelectionMonitor.shared.blocksSwitcher else { return }
                    // Activation: decisively horizontal (the transcript's own
                    // scroll stays vertical) and away from the back-swipe edge.
                    // No velocity floor — it made moderate-speed swipes
                    // silently do nothing, which read as flaky.
                    guard abs(w) > activation,
                          abs(w) > abs(v.translation.height) * 1.6,
                          v.startLocation.x > edgeGuard else { return }
                    dragging = true
                    dragBase = candidate ?? current
                    cancelSettle()
                }
                guard let base = dragBase else { return }
                // Finger left pulls in the RIGHT neighbor (next), finger right
                // the LEFT one — standard carousel semantics. Crossing back
                // under the activation distance returns to the drag base, so
                // an unfinished swipe cancels itself.
                var offset = 0
                if abs(w) > activation {
                    let sign = w < 0 ? 1 : -1
                    offset = sign * (1 + Int((abs(w) - activation) / stepWidth))
                }
                step(to: base + offset)
            }
            .onEnded { _ in
                guard dragging else { return }
                dragging = false
                dragBase = candidate
                startSettle()
            }
    }

    /// Move the candidate (clamped to the roster) with a tick per real step.
    private func step(to index: Int) {
        let next = min(max(index, 0), roster.count - 1)
        guard next != candidate else { return }
        Haptics.tick()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { candidate = next }
        ChatSwitcher.shared.previewing = roster[next]
    }

    /// The overlay pager's selection. Set fires only for the pager's OWN
    /// swipes (programmatic candidate changes update `get` silently), so it
    /// both steps and re-arms the countdown.
    private var pagerSelection: Binding<Int> {
        Binding(
            get: { candidate ?? currentIndex ?? 0 },
            set: { i in
                guard !committing else { return }
                step(to: i)
                if !dragging {
                    cancelSettle()
                    startSettle()
                }
            })
    }

    // MARK: settle

    private func startSettle() {
        settleProgress = 1
        withAnimation(.linear(duration: settleDelay)) { settleProgress = 0 }
        settleTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func cancelSettle() {
        settleTask?.cancel()
        settleTask = nil
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { settleProgress = 1 }
    }

    /// Swiped/settled back onto the current agent, or tapped it — cancel.
    private func dismiss() {
        cancelSettle()
        dragBase = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { candidate = nil }
        ChatSwitcher.shared.previewing = nil
    }

    /// The settled choice. Landing on the current agent just dismisses — that
    /// is the cancel gesture, not an error.
    private func commit() {
        guard !committing else { return }
        settleTask?.cancel()
        settleTask = nil
        dragBase = nil
        guard let c = candidate else { return }
        guard roster.indices.contains(c), c != currentIndex else {
            dismiss()
            return
        }
        let agent = roster[c]
        Haptics.send()
        committing = true
        // Swap NOW — no staged outgoing animation (that read as a stall).
        // The snapshot floats over the incoming chat (warm-started from the
        // very cache this page rendered) and dissolves, so the two identical
        // transcripts merge and only the switcher chrome visibly fades. Same
        // target construction as the Agents list row — RouteView then applies
        // agent→host pinning and session-keyed identity for free. Snapshot
        // FIRST (it must capture the candidate-titled nav bar), then release
        // the title override so the incoming chat renders its own.
        ChatSwitcher.shared.dissolveSnapshot = Self.windowSnapshot()
        ChatSwitcher.shared.previewing = nil
        ChatSwitcher.shared.target = ChatTarget(
            sessionId: agent.remoteSessionId ?? agent.projectId.replacingOccurrences(of: "remote:", with: ""),
            projectId: agent.projectId, isRemote: true, title: agent.displayName)
    }

    /// The whole key window as an image — nav bar, strip, page, composer.
    /// afterScreenUpdates:false grabs the frame already on screen, so capture
    /// adds no visible hitch. The keyboard lives in its own window and stays
    /// on top of the dissolve untouched.
    private static func windowSnapshot() -> UIImage? {
        guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = scene.keyWindow else { return nil }
        return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }

    /// Typing while the switcher is up overrides the countdown: switch NOW,
    /// and hand the draft to the destination composer so nothing typed is
    /// lost. A keystroke landing in the commit→unmount gap still refreshes
    /// the handed-off draft.
    private func handleTyping(_ text: String) {
        guard enabled, !text.isEmpty else { return }
        if committing {
            ChatSwitcher.shared.handoffDraft = text
            DraftStore.clear(currentProjectId)
            return
        }
        guard let c = candidate else { return }
        guard c != currentIndex else {
            dismiss()
            return
        }
        // The draft departs with the user — clear the origin's stored copy so
        // coming back later doesn't resurrect text that moved to another agent.
        ChatSwitcher.shared.handoffDraft = text
        DraftStore.clear(currentProjectId)
        commit()
    }

    // MARK: overlay

    private func switcherOverlay(_ c: Int) -> some View {
        ZStack {
            // The current conversation, faded behind a blur veil.
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.45)
            }

            VStack(spacing: 0) {
                AgentTitleStrip(roster: roster, candidate: c, currentIndex: currentIndex) { i in
                    cancelSettle()
                    step(to: i)
                    startSettle()
                }

                // The settle countdown, draining under the strip — the only
                // switcher chrome besides the strip itself.
                Capsule()
                    .fill(Theme.primary.opacity(0.9))
                    .frame(height: 3)
                    .scaleEffect(x: settleProgress, y: 1, anchor: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 6)

                // Native paged swiping between the agents' real conversation
                // views — the raising drag steps via the custom gesture (the
                // finger is still down on the transcript underneath); every
                // swipe after that is the system pager's own physics.
                TabView(selection: pagerSelection) {
                    ForEach(roster.indices, id: \.self) { i in
                        // Paged TabView builds ALL children eagerly — with a
                        // real fleet that meant every agent's transcript (dozens
                        // of UITextView rows) materialized in the raise frame,
                        // a visible hitch mid-drag (Manar, 2026-09-29: "laggy").
                        // Only the candidate ±1 render content; far pages are
                        // empty shells that fill in off-screen as they near.
                        AgentSwitchPage(agent: roster[i], isDemo: store.isDemo,
                                        near: abs(i - c) <= 1, onTap: commit)
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // A touch on the pager pauses the countdown; lifting re-arms
                // it (the selection binding re-arms again once the page
                // settles — harmless double start).
                .simultaneousGesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { _ in if !committing { cancelSettle() } }
                        .onEnded { _ in if !committing { startSettle() } })
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 1.04)))
    }
}

/// Scrollable roster strip over the pager — every agent by name with its live
/// status dot, candidate highlighted and kept centered (the camera-mode-picker
/// idiom). Tapping a name steps straight there.
private struct AgentTitleStrip: View {
    let roster: [Project]
    let candidate: Int
    let currentIndex: Int?
    let onPick: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(roster.indices, id: \.self) { i in chip(i) }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            }
            .onAppear { proxy.scrollTo(candidate, anchor: .center) }
            .onChange(of: candidate) { c in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    proxy.scrollTo(c, anchor: .center)
                }
            }
        }
    }

    private func chip(_ i: Int) -> some View {
        let p = roster[i]
        let selected = i == candidate
        return HStack(spacing: 6) {
            Circle().fill(AgentStatus.color(p)).frame(width: 6, height: 6)
            Text(p.displayName)
                .font(.footnote.weight(selected ? .semibold : .regular))
                .foregroundColor(selected ? Theme.text : Theme.mutedText)
                .lineLimit(1)
            if i == currentIndex {
                Text("now").font(.caption2).foregroundColor(Theme.primary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(selected ? Theme.elevated : .clear)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(selected ? Theme.primary.opacity(0.7) : .clear, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { onPick(i) }
        .id(i)
        .accessibilityIdentifier("switcher-chip-\(p.displayName)")
        .accessibilityLabel("Switch to \(p.displayName)")
        .accessibilityAddTraits(.isButton)
    }
}

/// One full-screen page of the switcher: the agent's conversation EXACTLY as
/// its chat renders it — same MessageRow, same spacing and padding as the
/// transcript — fed from the warm-start cache the destination opens with, so
/// swiping pages through the real views, not summaries of them. A RAM miss
/// falls back to the disk snapshot behind the app's own loader, mirroring
/// what the chat itself shows while history loads. Tapping commits NOW —
/// the advertised way to skip the delay (typing is the other).
private struct AgentSwitchPage: View {
    let agent: Project
    /// Demo roster has no server-fed cache — pages fall back to the canned
    /// per-agent transcripts so the switcher demos (and screenshots) properly.
    let isDemo: Bool
    /// Within ±1 of the candidate. Far pages render an empty shell (no cache
    /// read, no MessageRow/UITextView build) so raising the switcher only pays
    /// for the pages that can actually be seen; content fills in off-screen
    /// when the page nears.
    let near: Bool
    let onTap: () -> Void

    /// nil = still looking (loader shows); [] = looked, nothing to show.
    @State private var messages: [ChatMessage]?

    var body: some View {
        ZStack {
            Theme.background
            if !near {
                // Empty shell — content arrives via .task when the page nears.
            } else if let messages {
                if messages.isEmpty {
                    Text("No conversation yet")
                        .font(.caption).foregroundColor(Theme.mutedText)
                } else {
                    transcript(messages)
                }
            } else {
                MyMuLoader()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .task(id: near ? agent.remoteSessionId : nil) {
            guard near, messages == nil else { return }
            await load()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("switcher-card-\(agent.displayName)")
        .accessibilityLabel("Switch to \(agent.displayName)")
        .accessibilityAddTraits(.isButton)
    }

    private func load() async {
        guard let sid = agent.remoteSessionId, !sid.isEmpty else {
            messages = []
            return
        }
        // A conversation visited this session has a LIVE store (possibly
        // mid-turn) — preview that, it's exactly what the switch lands on.
        if let live = ConversationRegistry.shared.peek(sessionId: sid), !live.messages.isEmpty {
            messages = tail(live.messages)
            return
        }
        if let hit = ChatCacheStore.shared.cached(sessionId: sid) {
            messages = tail(hit.messages)
            return
        }
        if let disk = await ChatCacheStore.shared.load(sessionId: sid) {
            messages = tail(disk.messages)
            return
        }
        messages = isDemo ? tail(DemoData.agentTranscripts[sid] ?? []) : []
    }

    /// Same visibility rules as ChatView.visibleMessages, capped to the tail —
    /// the page is bottom-aligned and clipped, so the cap only bounds layout
    /// work, never leaves dead space.
    private func tail(_ all: [ChatMessage]) -> [ChatMessage] {
        func isBlank(_ s: String) -> Bool { s.allSatisfy(\.isWhitespace) }
        let visible = all.filter { m in
            switch m.kind {
            case "text":
                return !isBlank(m.bodyText) || (m.images?.isEmpty == false)
            case "tool_use", "error":
                return true
            case "tool_result", "thinking":
                return !isBlank(m.content ?? "")
            default:
                return false
            }
        }
        return Array(visible.suffix(12))
    }

    /// Rendered inside the same bottom-anchored scroll machinery the chat
    /// itself uses (defaultScrollAnchor + minHeight bottom alignment), so the
    /// page always rests on the LAST message — plain overflow alignment let
    /// long real-world transcripts show their top instead (Manar, 2026-09-20).
    /// Scrolling is disabled: the anchor is only the "open at the end" rule.
    private func transcript(_ msgs: [ChatMessage]) -> some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(msgs) { m in
                        MessageRow(message: m, projectId: agent.projectId, token: "")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .bottomLeading)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDisabled(true)
            // The page is a preview: rows must not swallow taps (text
            // selection, context menus) — a tap anywhere means "switch here".
            .allowsHitTesting(false)
        }
    }
}
