import SwiftUI

private struct Album: Identifiable, Codable {
    let id: String
    let name: String?
    let artist: String?
    let songCount: Int?
    let coverUrl: String?
}

private struct Playlist: Identifiable, Codable {
    let id: String
    let name: String?
    let songCount: Int?
    let coverUrl: String?
}

private enum Mode: String, CaseIterable { case browse = "Browse", queue = "Queue", playlists = "Playlists" }

/// Music tab: browse/search the library, manage the current queue (save it as a
/// playlist), and load saved playlists. All via the mymu-voice server (/music/*),
/// which holds the Subsonic creds and returns signed stream URLs.
struct MusicView: View {
    @ObservedObject private var player = SubsonicPlayer.shared
    @State private var mode: Mode = .browse
    @State private var query = ""
    @State private var songs: [Song] = []
    @State private var albums: [Album] = []
    @State private var playlists: [Playlist] = []
    @State private var error: String?
    @State private var savePrompt = false
    @State private var saveName = ""

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
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Save") { saveName = ""; savePrompt = true }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search your library")
            .onSubmit(of: .search) { Task { await search() } }
            .onChange(of: query) { v in if v.isEmpty { songs = []; Task { await loadAlbums() } } }
            .onChange(of: mode) { m in if m == .playlists { Task { await loadPlaylists() } } }
            .task { await loadAlbums() }
            .alert("Save playlist", isPresented: $savePrompt) {
                TextField("Name", text: $saveName)
                Button("Cancel", role: .cancel) {}
                Button("Save") { Task { await savePlaylist() } }
            } message: { Text("Save the current queue as a playlist.") }
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

    // MARK: Browse
    @ViewBuilder private var browseView: some View {
        if !songs.isEmpty {
            List(Array(songs.enumerated()), id: \.element.id) { i, song in
                SongRow(song: song, playing: player.current?.id == song.id)
                    .contentShape(Rectangle())
                    .onTapGesture { player.play(songs, startAt: i) }
                    .contextMenu {
                        Button { player.play(songs, startAt: i) } label: { Label("Play", systemImage: "play.fill") }
                        Button { player.addToQueue([song]) } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
                    }
            }.listStyle(.plain)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    ForEach(albums) { album in
                        AlbumCell(album: album).onTapGesture { Task { await playAlbum(album) } }
                    }
                }.padding()
            }
        }
    }

    // MARK: Queue
    @ViewBuilder private var queueView: some View {
        if player.queue.isEmpty {
            unavailable("Nothing queued yet — play something from Browse.")
        } else {
            List {
                ForEach(Array(player.queue.enumerated()), id: \.offset) { i, song in
                    SongRow(song: song, playing: i == player.index)
                        .contentShape(Rectangle())
                        .onTapGesture { player.playAt(i) }
                }
                .onDelete { player.removeFromQueue(at: $0.first ?? 0) }
            }.listStyle(.plain)
        }
    }

    // MARK: Playlists
    @ViewBuilder private var playlistsView: some View {
        if playlists.isEmpty {
            unavailable("No saved playlists yet — make a queue and tap Save.")
        } else {
            List(playlists) { pl in
                HStack(spacing: 12) {
                    Cover(url: pl.coverUrl, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pl.name ?? "Playlist").font(.body).lineLimit(1)
                        Text("\(pl.songCount ?? 0) songs").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(); Image(systemName: "play.circle").foregroundStyle(.tint)
                }
                .contentShape(Rectangle())
                .onTapGesture { Task { await playPlaylist(pl) } }
            }.listStyle(.plain)
        }
    }

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
        do { songs = try await fetch(musicURL("music/search", ["q": query]), "songs") } catch { self.error = error.localizedDescription }
    }
    private func loadPlaylists() async {
        do { playlists = try await fetch(musicURL("music/playlists"), "playlists") } catch { self.error = error.localizedDescription }
    }
    private func playAlbum(_ album: Album) async {
        do { let t: [Song] = try await fetch(musicURL("music/album", ["id": album.id]), "songs"); if !t.isEmpty { player.play(t) } }
        catch { self.error = error.localizedDescription }
    }
    private func playPlaylist(_ pl: Playlist) async {
        do { let t: [Song] = try await fetch(musicURL("music/playlist", ["id": pl.id]), "songs"); if !t.isEmpty { player.play(t) } }
        catch { self.error = error.localizedDescription }
    }
    private func savePlaylist() async {
        let name = saveName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !player.queue.isEmpty else { return }
        let ids = player.queue.map { $0.id }
        _ = try? await URLSession.shared.data(
            for: {
                var r = URLRequest(url: musicURL("music/playlists")); r.httpMethod = "POST"
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name, "songIds": ids])
                return r
            }())
        await loadPlaylists()
    }
}

// MARK: - Rows / cells

private struct SongRow: View {
    let song: Song; let playing: Bool
    var body: some View {
        HStack(spacing: 12) {
            Cover(url: song.coverUrl, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.displayTitle).font(.body).lineLimit(1)
                Text(song.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if playing { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint) }
        }
    }
}

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
    var body: some View {
        AsyncImage(url: URL(string: url ?? "")) { img in img.resizable().scaledToFill() } placeholder: {
            ZStack { Color.gray.opacity(0.2); Image(systemName: "music.note").foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct NowPlayingBar: View {
    @ObservedObject private var player = SubsonicPlayer.shared
    var body: some View {
        HStack(spacing: 12) {
            Cover(url: player.current?.coverUrl, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.displayTitle ?? "").font(.subheadline).bold().lineLimit(1)
                Text(player.current?.displayArtist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { player.prev() } label: { Image(systemName: "backward.fill") }
            Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3) }
            Button { player.next() } label: { Image(systemName: "forward.fill") }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}
