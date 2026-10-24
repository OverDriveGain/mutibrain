import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// A file staged in the composer, ready to send as `options.images`.
struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let dataURL: String
    let isImage: Bool
    var isVideo: Bool { dataURL.hasPrefix("data:video/") }
}

/// The message composer — modeled on the ChatGPT iOS composer, state by state
/// (Manar, 2026-10-24, reference photos photo-1/photo-2). Isolated in its own
/// view so DRAFT keystrokes re-render only this small view, never the
/// transcript above it (whole-chat re-render per keystroke made typing crawl
/// in conversations with large histories).
///
/// STATE 1 — IDLE: nothing typed, not focused, no attachments.
///   One row, a 52pt capsule, inset 32pt from the screen edges (the ChatGPT
///   idle pill sits well inside the margins — narrower than the expanded one).
///
///       ( +   Ask <agent>                          (↑) )
///
///   • "+" is a bare 22pt glyph (no circle) on a 44pt tap target.
///   • placeholder 17pt muted; a tap ANYWHERE on the pill focuses the field.
///   • trailing slot: the send circle, dimmed (there is nothing to send) —
///     or, while the agent is working, the STOP circle (■), which aborts.
///   • no stroke: the fill alone (Theme.composer) defines the shape.
///
/// STATE 2 — EXPANDED: focused, or a draft / attachments exist.
///   Full width (inset 12pt), two rows, corner radius 28:
///
///       ┌────────────────────────────────────────────┐
///       │ [thumbs / file chips]        (only if any) │
///       │ typed text … (17pt, grows 1→8 lines)       │
///       │  +                                     (↑) │
///       └────────────────────────────────────────────┘
///
///   • the controls drop to their own row so the text owns the full width.
///   • SEND (34pt, brand fill, white bold arrow) is live with text or an
///     attachment, dimmed otherwise. STOP takes the slot while the agent
///     works and nothing is typed; typing mid-turn brings SEND back (remote
///     agents queue the message behind the running turn).
///   • "+" and the trailing control glide between the rows on every
///     expand/collapse (matched geometry); the pill springs between shapes
///     (0.32s). Reduce Motion: no travel, just the end state.
///
/// SEND: the text clears; the pill stays expanded while focused (the keyboard
/// stays up, as in ChatGPT) and the parent flies the bubble up into the
/// transcript (see ChatView). Attach errors render as one 12pt line under
/// the pill, cleared on the next attach.
struct ChatComposer: View {
    @ObservedObject var relay: RelayClient
    /// "Ask <agent>" for live agents, "Ask anything" for local sessions.
    let placeholder: String
    /// The agent is pinned to this host but the app has no saved login for it —
    /// arbitrary/binary files can't reach the agent (only image/PDF/text embed
    /// through the relay). Attaching an unsupported type warns instead of
    /// silently dropping it server-side.
    let pinnedHostNeedingLogin: String?
    /// Routed to the conversation's own host, so commands and models are read
    /// from the server the agent actually runs on.
    let api: APIClient
    let projectPath: String?
    /// Chosen in the toolbar menu, applied to every send from here.
    let permissionMode: PermissionMode
    let model: String?
    /// DraftStore identity for this conversation — agent (projectId) for
    /// remote chats, session for local ones.
    let draftKey: String
    /// Text the toolbar wants dropped into the draft (a picked slash command).
    /// A hand-off rather than lifting `input` to the parent: `input` must stay
    /// local or every keystroke re-renders the transcript.
    @Binding var pendingInsert: String?
    /// Parent hook fired right before a send (re-arms follow-mode), given the
    /// exact text about to go out — lets the parent notice a sent `/clear`.
    let onWillSend: (String) -> Void

    @State private var input = ""
    @State private var attachments: [PendingAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var attachError: String?
    @State private var photoPickerPresented = false
    @State private var cameraPresented = false
    /// Focus handle so a type-to-switch hand-off can keep the keyboard up in
    /// the destination composer — and the idle→expanded state key.
    @FocusState private var inputFocused: Bool
    // iPad: a SwiftUI Menu is a popover, and toggling .fileImporter/.photosPicker
    // from inside a Menu item is swallowed as the popover dismisses — the picker
    // never presents (App Store 2.1(a) reject, iPadOS 26). A confirmationDialog
    // finishes dismissing BEFORE its action fires, so the picker presents on iPad
    // and iPhone alike.
    @State private var showAttachDialog = false
    @Namespace private var controls
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// STATE 2 whenever there is something to show or the field has focus.
    private var expanded: Bool { inputFocused || !input.isEmpty || !attachments.isEmpty }
    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }
    /// Mid-turn sends are allowed for remote agents — the relay queues them
    /// into the agent's own message queue (same as the web app), so typed text
    /// always SENDS; local sessions keep stop-while-working (no queue there).
    private var sendAllowed: Bool { canSend && (!relay.isLoading || relay.supportsMidTurnSend) }
    private var showsStop: Bool { relay.isLoading && !canSend }
    private var motion: Animation? { reduceMotion ? nil : ChatScroll.composerAnimation }

    var body: some View {
        VStack(spacing: 0) {
            pill
                .padding(.horizontal, expanded ? 12 : 32)
                .padding(.top, 6)
                .padding(.bottom, 8)
                // Same reading-column cap as the transcript above it, so the
                // pill lines up with the bubbles instead of stretching wider on
                // iPad.
                .frame(maxWidth: Theme.maxContentWidth)
                .frame(maxWidth: .infinity)
            if let attachError {
                Text(attachError).font(.caption2).foregroundColor(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .background(Theme.background)
        .animation(motion, value: expanded)
        .animation(motion, value: showsStop)
        .animation(motion, value: sendAllowed)
        .animation(motion, value: attachments.count)
        .animation(motion, value: attachError == nil)
        // Every draft change: remember it for this conversation, then tell
        // the switcher (typing while its overlay is raised means "switch
        // NOW", and the full draft rides along). Save BEFORE send — a
        // type-to-switch clears this key as the draft departs, and the clear
        // must win over the save.
        .onChange(of: input) { text in
            DraftStore.save(text, for: draftKey)
            ChatSwitcher.shared.typing.send(text)
        }
        // Arriving from a type-to-switch: the draft typed into the previous
        // chat lands here, and focus is retaken so the keyboard never drops
        // mid-thought. Otherwise, restore whatever was left unsent last time
        // this conversation was open.
        .onAppear {
            if let draft = ChatSwitcher.shared.takeDraft() {
                input = draft
                DispatchQueue.main.async { inputFocused = true }
            } else if input.isEmpty, let saved = DraftStore.load(draftKey) {
                input = saved
            }
        }
        // Toolbar picked a slash command: append it to the draft and clear the
        // hand-off so the same pick can happen again later.
        .onChange(of: pendingInsert) { text in
            guard let text, !text.isEmpty else { return }
            let gap = input.isEmpty || input.hasSuffix(" ") ? "" : " "
            input += gap + text
            pendingInsert = nil
        }
        .confirmationDialog("Add attachment", isPresented: $showAttachDialog, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Camera") { cameraPresented = true }
            }
            Button("Photo or video") { photoPickerPresented = true }
            Button("Attach file") { showFileImporter = true }
            Button("Cancel", role: .cancel) { }
        }
        .photosPicker(isPresented: $photoPickerPresented, selection: $photoItems,
                      maxSelectionCount: 5, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [UTType.item],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { addFileAttachment(url) }
        }
        .fullScreenCover(isPresented: $cameraPresented) {
            CameraPicker { capture in
                switch capture {
                case .photo(let image): addCameraPhoto(image)
                case .movie(let url): addCameraMovie(url)
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { for item in items { await addPickedAttachment(item) } }
        }
    }

    // MARK: the pill

    private var pill: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !attachments.isEmpty {
                attachmentChips
                    .padding(.top, 10)
                    .padding(.horizontal, 10)
                    .transition(.opacity)
            }
            // The text row. The field itself keeps ONE structural identity across
            // both states (its siblings change, it never does), so focus survives
            // the idle↔expanded switch it triggers.
            HStack(alignment: .center, spacing: 4) {
                if !expanded {
                    plusButton.matchedGeometryEffect(id: "plus", in: controls)
                }
                TextField("", text: $input,
                          prompt: Text(placeholder).foregroundColor(Theme.mutedText),
                          axis: .vertical)
                    .accessibilityIdentifier("composer-input")
                    .focused($inputFocused)
                    .lineLimit(1...8)
                    .font(.system(size: 17))
                    .foregroundColor(Theme.text)
                    .tint(Theme.primary)
                    .padding(.leading, expanded ? 16 : 2)
                    .padding(.trailing, expanded ? 16 : 6)
                    .padding(.top, expanded ? 13 : 14)
                    .padding(.bottom, expanded ? 4 : 14)
                if !expanded {
                    trailingControl.matchedGeometryEffect(id: "trailing", in: controls)
                }
            }
            .padding(.horizontal, expanded ? 0 : 6)
            if expanded {
                HStack(spacing: 0) {
                    plusButton.matchedGeometryEffect(id: "plus", in: controls)
                    Spacer(minLength: 12)
                    trailingControl.matchedGeometryEffect(id: "trailing", in: controls)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
        .frame(minHeight: 52)
        .background(
            // Idle: a true capsule (radius = half the 52pt height). Expanded:
            // the 28pt continuous corner of the ChatGPT pill.
            RoundedRectangle(cornerRadius: expanded ? Theme.Radius.composer : 26, style: .continuous)
                .fill(Theme.composer)
                .contentShape(Rectangle())
                // Tapping the pill anywhere (not only the text) raises the
                // keyboard — the whole shape IS the field.
                .onTapGesture { inputFocused = true }
        )
    }

    private var plusButton: some View {
        Button { showAttachDialog = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(Theme.text.opacity(0.9))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composer-attach")
        .accessibilityLabel("Add attachment")
    }

    /// The slot at the pill's trailing edge: SEND (live or dimmed) or STOP.
    private var trailingControl: some View {
        ZStack {
            if showsStop {
                Button { relay.abort() } label: {
                    ZStack {
                        Circle().fill(Theme.primary)
                        RoundedRectangle(cornerRadius: 2.5).fill(Color.white).frame(width: 12, height: 12)
                    }
                    .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer-stop")
                .accessibilityLabel("Stop generating")
                .transition(.scale.combined(with: .opacity))
            } else {
                Button(action: send) {
                    ZStack {
                        Circle().fill(sendAllowed ? Theme.primary : Theme.elevated)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(sendAllowed ? .white : Theme.mutedText.opacity(0.7))
                    }
                    .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(!sendAllowed)
                .accessibilityIdentifier("composer-send")
                .accessibilityLabel("Send")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 44, height: 44)
    }

    private func send() {
        guard sendAllowed else { return }
        Haptics.send()
        let text = input
        onWillSend(text)
        let files = attachments.map { ["name": $0.name, "data": $0.dataURL] }
        input = ""
        attachments = []
        relay.send(text, attachments: files, permissionMode: permissionMode, model: model)
    }

    /// Staged attachments INSIDE the pill (ChatGPT keeps them in the composer,
    /// above the text): photos as thumbnails, everything else as a named chip.
    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    ZStack(alignment: .topTrailing) {
                        if a.isImage {
                            DataURLImage(dataURL: a.dataURL)
                                .frame(width: 60, height: 60)
                                .background(Theme.elevated)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: a.isVideo ? "video" : "doc")
                                    .font(.caption2).foregroundColor(Theme.primary)
                                Text(a.name).font(.caption).foregroundColor(Theme.text).lineLimit(1)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Theme.elevated)
                            .clipShape(Capsule())
                        }
                        Button {
                            attachments.removeAll { $0.id == a.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(Theme.text)
                                .background(Circle().fill(Theme.background).padding(2))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("Remove \(a.name)")
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: attachment ingestion

    // The attachment cap is SERVER-authoritative — read at runtime from
    // AppLimits (GET /api/limits), never hardcoded here. That's what lets the
    // limit change server-side (CCUI_MAX_ATTACHMENT_MB + restart) and apply to
    // already-shipped builds with no App Store resubmission. AppLimits carries a
    // cold-start fallback until the server answers. The cap doubles as the
    // memory guard: iOS holds the whole file (Data + base64, ~2.3× peak) in RAM.
    private var maxAttachmentBytes: Int { AppLimits.shared.attachmentBytes }
    private var maxAttachmentLabel: String { AppLimits.shared.attachmentLabel }

    /// Library pick — images AND videos (`matching` includes both). Images
    /// re-encode to JPEG (keeps HEIC out of the pipeline); videos ride verbatim
    /// with their real container mime so the agent gets a playable file.
    private func addPickedAttachment(_ item: PhotosPickerItem) async {
        attachError = nil
        let isMovie = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            attachError = isMovie ? "Couldn’t load that video." : "Couldn’t load that photo."
            return
        }
        if isMovie {
            let type = item.supportedContentTypes.first { $0.conforms(to: .movie) }
            let ext = type?.preferredFilenameExtension ?? "mp4"
            let mime = type?.preferredMIMEType ?? "video/mp4"
            appendAttachment(name: "video-\(attachments.count + 1).\(ext)",
                             mime: mime, data: data, kindLabel: "Video")
            return
        }
        guard let img = UIImage(data: data), let jpeg = img.jpegData(compressionQuality: 0.85) else {
            attachError = "Couldn’t load that photo."
            return
        }
        appendAttachment(name: "photo-\(attachments.count + 1).jpg",
                         mime: "image/jpeg", data: jpeg, kindLabel: "Photo")
    }

    // MARK: camera capture

    private func addCameraPhoto(_ image: UIImage) {
        attachError = nil
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
            attachError = "Couldn’t process that photo."
            return
        }
        appendAttachment(name: "camera-\(attachments.count + 1).jpg",
                         mime: "image/jpeg", data: jpeg, kindLabel: "Photo")
    }

    private func addCameraMovie(_ url: URL) {
        attachError = nil
        guard let data = try? Data(contentsOf: url) else {
            attachError = "Couldn’t read the recorded video."
            return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "video/quicktime"
        appendAttachment(name: "camera-\(attachments.count + 1).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)",
                         mime: mime, data: data, kindLabel: "Video")
    }

    /// Single append gate every source funnels through: size cap (server-
    /// authoritative) and the pinned-host reachability check for types the
    /// relay can't embed as content blocks (video landed here with the camera —
    /// same rule the file path always applied).
    private func appendAttachment(name: String, mime: String, data: Data, kindLabel: String) {
        guard data.count <= maxAttachmentBytes else {
            attachError = "\(kindLabel) is too large (max \(maxAttachmentLabel))."
            return
        }
        if let host = pinnedHostNeedingLogin, !Self.embedsWithoutLanding(mime: mime, name: name) {
            attachError = "Can’t share this file: the agent runs on \(host), which you’re not signed in to. Add that account (profile → Add account) to send files."
            return
        }
        attachments.append(PendingAttachment(
            name: name,
            dataURL: "data:\(mime);base64,\(data.base64EncodedString())",
            isImage: mime.hasPrefix("image/")))
    }

    /// Types the relay can EMBED as content blocks (server toUserContent):
    /// image/PDF/text reach any agent; everything else needs the file to LAND on
    /// the agent's host — impossible without a login there.
    private static let embeddableTextExts: Set<String> = [
        "txt", "md", "markdown", "json", "csv", "tsv", "xml", "yaml", "yml", "toml", "ini", "cfg",
        "conf", "env", "log", "js", "jsx", "ts", "tsx", "mjs", "cjs", "py", "rb", "go", "rs", "java",
        "c", "cpp", "cc", "h", "hpp", "cs", "php", "sh", "bash", "zsh", "sql", "html", "htm", "css",
        "scss", "less", "vue", "svelte", "svg", "dockerfile", "gitignore", "lua", "r", "kt", "swift",
    ]
    private static func embedsWithoutLanding(mime: String, name: String) -> Bool {
        if mime.hasPrefix("image/") || mime.hasPrefix("text/") || mime == "application/pdf" { return true }
        return embeddableTextExts.contains((name as NSString).pathExtension.lowercased())
    }

    private func addFileAttachment(_ url: URL) {
        attachError = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            attachError = "Couldn’t read that file."
            return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        appendAttachment(name: url.lastPathComponent, mime: mime, data: data, kindLabel: "File")
    }
}
