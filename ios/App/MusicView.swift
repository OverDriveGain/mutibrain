import SwiftUI

private struct Album: Identifiable, Codable {
    let id: String
    let name: String?
    let artist: String?
    let songCount: Int?
    let coverUrl: String?
}

private struct Artist: Identifiable, Codable {
    let id: String
    let name: String?
    let albumCount: Int?
    let coverUrl: String?
}

private struct Playlist: Identifiable, Codable {
    let id: String
    let name: String?
    let comment: String?      // the description — "what is it good for"
    let songCount: Int?
    let coverUrl: String?
}

private enum Mode: String, CaseIterable { case browse = "Browse", queue = "Queue", playlists = "Playlists" }

/// Music tab: one search field that finds ANYTHING (songs, albums, artists),
/// a queue you manage directly (tap, drag-reorder, swipe-remove), playlists
/// with a description, and offline downloads. Deliberately a SIMPLE player —
/// all via the mymu-voice server (/music/*), which holds the Subsonic creds
/// and returns signed stream URLs.
struct MusicView: View {
    @ObservedObject private var player = SubsonicPlayer.shared
    @ObservedObject private var downloads = DownloadStore.shared
    @State private var mode: Mode = .browse
    @State private var query = ""
    @State private var songs: [Song] = []
    @State private var searchAlbums: [Album] = []
    @State private var artists: [Artist] = []
    @State private var albums: [Album] = []
    @State private var playlists: [Playlist] = []
    @State private var error: String?
    @State private var savePrompt = false
    @State private var saveName = ""
    @State private var saveDesc = ""
    @State private var descTarget: Playlist?
    @State private var descText = ""

    private var origin: URL {
        let u = SharedConfig.load().gadkURL
        var c = URLComponents(); c.scheme = u.scheme; c.host = u.host; c.port = u.port
        return c.url ?? u
    }
    private var creds: (app: String, token: String) {
        let q = URLComponents(url: SharedConfig.load().gadkURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return (q.first { $0.name == "app" }?.value ?? "", q.first { $0.name == "token" }?.value ?? "")
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).padding(.horizontal).padding(.top, 6)

                content
                if player.current != nil { NowPlayingBar() }
            }
            .navigationTitle("Music")
            .toolbar {
                if mode == .queue && !player.queue.isEmpty {
                    ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Save") { saveName = ""; saveDesc = ""; savePrompt = true }
                    }
                }
            }
            .searchable(text: $query, prompt: "Songs, albums, artists…")
            .onSubmit(of: .search) { Task { await search() } }
            .onChange(of: query) { v in
                if v.isEmpty { songs = []; searchAlbums = []; artists = []; Task { await loadAlbums() } }
            }
            .onChange(of: mode) { m in if m == .playlists { Task { await loadPlaylists() } } }
            .task { await loadAlbums(); await loadPlaylists() }
            .alert("Save playlist", isPresented: $savePrompt) {
                TextField("Name", text: $saveName)
                TextField("Description (optional)", text: $saveDesc)
                Button("Cancel", role: .cancel) {}
                Button("Save") { Task { await savePlaylist() } }
            } message: { Text("Save the current queue as a playlist.") }
            .alert("Describe playlist", isPresented: Binding(
                get: { descTarget != nil }, set: { if !$0 { descTarget = nil } })) {
                TextField("What is it good for?", text: $descText)
                Button("Cancel", role: .cancel) { descTarget = nil }
                Button("Save") { Task { await saveDescription() } }
            } message: { Text(descTarget?.name ?? "") }
        }
    }

    @ViewBuilder private var content: some View {
        if let error, mode == .browse {
            unavailable(error)
        } else {
            switch mode {
            case .browse:    browseView
            case .queue:     queueView
            case .playlists: playlistsView
            }
        }
    }

    // MARK: Browse (recent albums grid, or universal search results)
    @ViewBuilder private var browseView: some View {
        if !songs.isEmpty || !artists.isEmpty || !searchAlbums.isEmpty {
            List {
                if !artists.isEmpty {
                    Section("Artists") {
                        ForEach(artists) { ar in
                            HStack(spacing: 12) {
                                Cover(url: ar.coverUrl, size: 44, round: true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ar.name ?? "Artist").font(.body).lineLimit(1)
                                    Text("Artist").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "play.circle").foregroundStyle(.tint)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await playArtist(ar, queueOnly: false) } }
                            .contextMenu {
                                Button { Task { await playArtist(ar, queueOnly: false) } } label: { Label("Play", systemImage: "play.fill") }
                                Button { Task { await playArtist(ar, queueOnly: true) } } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
                            }
                        }
                    }
                }
                if !searchAlbums.isEmpty {
                    Section("Albums") {
                        ForEach(searchAlbums) { album in
                            HStack(spacing: 12) {
                                Cover(url: album.coverUrl, size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.name ?? "Album").font(.body).lineLimit(1)
                                    Text(album.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(); Image(systemName: "play.circle").foregroundStyle(.tint)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await playAlbum(album, queueOnly: false) } }
                            .contextMenu {
                                Button { Task { await playAlbum(album, queueOnly: false) } } label: { Label("Play", systemImage: "play.fill") }
                                Button { Task { await playAlbum(album, queueOnly: true) } } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
                            }
                        }
                    }
                }
                if !songs.isEmpty {
                    Section("Songs") {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                            songRow(song, playing: player.current?.id == song.id)
                                .onTapGesture { player.play(songs, startAt: i) }
                        }
                    }
                }
            }.listStyle(.insetGrouped)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    ForEach(albums) { album in
                        AlbumCell(album: album)
                            .onTapGesture { Task { await playAlbum(album, queueOnly: false) } }
                            .contextMenu {
                                Button { Task { await playAlbum(album, queueOnly: false) } } label: { Label("Play", systemImage: "play.fill") }
                                Button { Task { await playAlbum(album, queueOnly: true) } } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
                            }
                    }
                }.padding()
            }
        }
    }

    // MARK: Queue (direct manipulation: tap, drag to reorder, swipe to remove)
    @ViewBuilder private var queueView: some View {
        if player.queue.isEmpty {
            unavailable("Nothing queued yet — play something from Browse.")
        } else {
            List {
                ForEach(Array(player.queue.enumerated()), id: \.offset) { i, song in
                    songRow(song, playing: i == player.index)
                        .onTapGesture { player.playAt(i) }
                }
                .onMove { player.moveInQueue(from: $0, to: $1) }
                .onDelete { player.removeFromQueue(at: $0.first ?? 0) }
            }.listStyle(.plain)
        }
    }

    // MARK: Playlists (+ the downloads shelf)
    @ViewBuilder private var playlistsView: some View {
        List {
            Section {
                NavigationLink { DownloadsList() } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.15))
                                .frame(width: 44, height: 44)
                            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Downloaded").font(.body)
                            Text("\(downloads.songs.count) songs, plays offline")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Playlists") {
                if playlists.isEmpty {
                    Text("No saved playlists yet — make a queue and tap Save.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(playlists) { pl in
                    HStack(spacing: 12) {
                        Cover(url: pl.coverUrl, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pl.name ?? "Playlist").font(.body).lineLimit(1)
                            Text(sub(pl)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(); Image(systemName: "play.circle").foregroundStyle(.tint)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await playPlaylist(pl, queueOnly: false) } }
                    .contextMenu {
                        Button { Task { await playPlaylist(pl, queueOnly: false) } } label: { Label("Play", systemImage: "play.fill") }
                        Button { Task { await playPlaylist(pl, queueOnly: true) } } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
                        Button { descTarget = pl; descText = pl.comment ?? "" } label: { Label("Describe", systemImage: "text.quote") }
                        Button(role: .destructive) { Task { await deletePlaylist(pl) } } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                .onDelete { idx in
                    if let i = idx.first, playlists.indices.contains(i) {
                        let pl = playlists[i]
                        Task { await deletePlaylist(pl) }
                    }
                }
            }
        }.listStyle(.insetGrouped)
    }

    private func sub(_ pl: Playlist) -> String {
        let count = "\(pl.songCount ?? 0) songs"
        if let c = pl.comment, !c.isEmpty { return "\(c) · \(count)" }
        return count
    }

    // MARK: Song row (shared): art, titles, duration, download state + menu
    private func songRow(_ song: Song, playing: Bool) -> some View {
        HStack(spacing: 12) {
            Cover(url: song.coverUrl, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.displayTitle).font(.body).lineLimit(1)
                Text(song.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if downloads.isDownloaded(song.id) {
                Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(.secondary)
            } else if downloads.inFlight.contains(song.id) {
                ProgressView().controlSize(.small)
            }
            if playing {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
            } else if let d = song.duration {
                Text(Self.mmss(d)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button { player.play([song]) } label: { Label("Play", systemImage: "play.fill") }
            Button { player.addToQueue([song]) } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
            if downloads.isDownloaded(song.id) {
                Button(role: .destructive) { downloads.remove(song.id) } label: { Label("Remove Download", systemImage: "trash") }
            } else if !downloads.inFlight.contains(song.id) {
                Button { downloads.download(song) } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
            if !playlists.isEmpty {
                Menu {
                    ForEach(playlists) { pl in
                        Button(pl.name ?? "Playlist") { Task { await addToPlaylist(song, pl) } }
                    }
                } label: { Label("Add to Playlist", systemImage: "music.note.list") }
            }
        }
    }

    static func mmss(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }

    private func unavailable(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list").font(.largeTitle).foregroundStyle(.secondary)
            Text(msg).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Networking
    private func musicURL(_ path: String, _ extra: [String: String] = [:]) -> URL {
        var c = URLComponents(url: origin.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.queryItems = ([("app", creds.app), ("token", creds.token)] + extra.map { ($0, $1) })
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        return c.url!
    }
    private func fetch<T: Decodable>(_ url: URL, _ key: String, method: String = "GET",
                                     body: [String: Any]? = nil) async throws -> [T] {
        var req = URLRequest(url: url); req.httpMethod = method
        if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                       req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let arr = obj?[key] else {
            throw NSError(domain: "music", code: 1, userInfo: [NSLocalizedDescriptionKey: (obj?["error"] as? String) ?? "no data"])
        }
        let d = try JSONSerialization.data(withJSONObject: arr)
        return try JSONDecoder().decode([T].self, from: d)
    }

    private func loadAlbums() async {
        guard !creds.token.isEmpty else { error = "Not configured"; return }
        error = nil
        do { albums = try await fetch(musicURL("music/search"), "albums") } catch { self.error = error.localizedDescription }
    }
    private func search() async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        error = nil
        let url = musicURL("music/search", ["q": query])
        do {
            async let s: [Song] = fetch(url, "songs")
            async let al: [Album] = fetch(url, "albums")
            async let ar: [Artist] = fetch(url, "artists")
            (songs, searchAlbums, artists) = try await (s, al, ar)
        } catch { self.error = error.localizedDescription }
    }
    private func loadPlaylists() async {
        do { playlists = try await fetch(musicURL("music/playlists"), "playlists") } catch { self.error = error.localizedDescription }
    }
    private func playAlbum(_ album: Album, queueOnly: Bool) async {
        do {
            let t: [Song] = try await fetch(musicURL("music/album", ["id": album.id]), "songs")
            guard !t.isEmpty else { return }
            queueOnly ? player.addToQueue(t) : player.play(t)
        } catch { self.error = error.localizedDescription }
    }
    private func playArtist(_ ar: Artist, queueOnly: Bool) async {
        do {
            let t: [Song] = try await fetch(musicURL("music/artist", ["name": ar.name ?? ""]), "songs")
            guard !t.isEmpty else { return }
            queueOnly ? player.addToQueue(t) : player.play(t)
        } catch { self.error = error.localizedDescription }
    }
    private func playPlaylist(_ pl: Playlist, queueOnly: Bool) async {
        do {
            let t: [Song] = try await fetch(musicURL("music/playlist", ["id": pl.id]), "songs")
            guard !t.isEmpty else { return }
            queueOnly ? player.addToQueue(t) : player.play(t)
        } catch { self.error = error.localizedDescription }
    }
    private func savePlaylist() async {
        let name = saveName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !player.queue.isEmpty else { return }
        var body: [String: Any] = ["name": name, "songIds": player.queue.map { $0.id }]
        let desc = saveDesc.trimmingCharacters(in: .whitespaces)
        if !desc.isEmpty { body["comment"] = desc }
        var r = URLRequest(url: musicURL("music/playlists")); r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: r)
        await loadPlaylists()
    }
    private func saveDescription() async {
        guard let pl = descTarget else { return }
        var r = URLRequest(url: musicURL("music/playlist", ["id": pl.id])); r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["comment": descText])
        _ = try? await URLSession.shared.data(for: r)
        descTarget = nil
        await loadPlaylists()
    }
    private func addToPlaylist(_ song: Song, _ pl: Playlist) async {
        var r = URLRequest(url: musicURL("music/playlist", ["id": pl.id])); r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["songIds": [song.id]])
        _ = try? await URLSession.shared.data(for: r)
        await loadPlaylists()
    }
    private func deletePlaylist(_ pl: Playlist) async {
        var r = URLRequest(url: musicURL("music/playlist", ["id": pl.id])); r.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: r)
        await loadPlaylists()
    }
}

// MARK: - Downloads list (offline shelf)

private struct DownloadsList: View {
    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var player = SubsonicPlayer.shared

    var body: some View {
        Group {
            if downloads.songs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No downloads yet — long-press a song and tap Download,\nor say \u{201C}download this song\u{201D}.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(downloads.songs.enumerated()), id: \.element.id) { i, song in
                        HStack(spacing: 12) {
                            Cover(url: song.coverUrl, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.displayTitle).font(.body).lineLimit(1)
                                Text(song.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if player.current?.id == song.id {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { player.play(downloads.songs, startAt: i) }
                    }
                    .onDelete { idx in if let i = idx.first, downloads.songs.indices.contains(i) { downloads.remove(downloads.songs[i].id) } }
                }.listStyle(.plain)
            }
        }
        .navigationTitle("Downloaded")
    }
}

// MARK: - Rows / cells

private struct AlbumCell: View {
    let album: Album
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Cover(url: album.coverUrl, size: nil).aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(album.name ?? "").font(.subheadline).bold().lineLimit(1)
            Text(album.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

private struct Cover: View {
    let url: String?; let size: CGFloat?
    var round: Bool = false
    var body: some View {
        AsyncImage(url: URL(string: url ?? "")) { img in img.resizable().scaledToFill() } placeholder: {
            ZStack { Color.gray.opacity(0.2); Image(systemName: round ? "music.mic" : "music.note").foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: round ? (size ?? 44) / 2 : 8))
    }
}

// MARK: - Now Playing bar (mini player: art, titles, transport, thin scrubber)

private struct NowPlayingBar: View {
    @ObservedObject private var player = SubsonicPlayer.shared
    @State private var scrub: Double? = nil

    private var dur: Double { max(player.duration, 1) }

    var body: some View {
        VStack(spacing: 6) {
            SeekBar(progress: (scrub ?? player.position) / dur,
                    onScrub: { f in scrub = f * dur },
                    onCommit: { if let s = scrub { player.seek(to: s) }; scrub = nil })
            HStack(spacing: 12) {
                Cover(url: player.current?.coverUrl, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.displayTitle ?? "").font(.subheadline).bold().lineLimit(1)
                    HStack(spacing: 6) {
                        Text(player.current?.displayArtist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text("\(fmt(scrub ?? player.position)) / \(fmt(dur))")
                            .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button { player.prev() } label: { Image(systemName: "backward.fill") }
                Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3) }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let i = Int(s); return String(format: "%d:%02d", i / 60, i % 60)
    }
}

/// A thin Apple-Music-style scrubber: drag anywhere on it to seek.
private struct SeekBar: View {
    let progress: Double            // 0...1
    let onScrub: (Double) -> Void   // fraction while dragging
    let onCommit: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(Color.accentColor)
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
            .frame(height: 3)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in onScrub(max(0, min(1, v.location.x / geo.size.width))) }
                    .onEnded { _ in onCommit() }
            )
        }
        .frame(height: 16)
        .padding(.horizontal, 14)
    }
}
