import SwiftUI

/// Album for the browse grid (recently added).
private struct Album: Identifiable, Codable {
    let id: String
    let name: String?
    let artist: String?
    let songCount: Int?
    let coverUrl: String?
}

/// Music tab: search the library or browse recent albums, tap to play, with a
/// now-playing bar. All calls go through the mymu-voice server (/music/*),
/// which holds the Subsonic creds and returns signed stream URLs.
struct MusicView: View {
    @ObservedObject private var player = SubsonicPlayer.shared
    @State private var query = ""
    @State private var songs: [Song] = []
    @State private var albums: [Album] = []
    @State private var loading = false
    @State private var error: String?

    // Base + auth pulled from the configured gadk URL (same app+token as /panel).
    private var origin: URL {
        let u = SharedConfig.load().gadkURL
        var c = URLComponents(); c.scheme = u.scheme; c.host = u.host; c.port = u.port
        return c.url ?? u
    }
    private var creds: (app: String, token: String) {
        let q = URLComponents(url: SharedConfig.load().gadkURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return (q.first { $0.name == "app" }?.value ?? "",
                q.first { $0.name == "token" }?.value ?? "")
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                content
                if player.current != nil { NowPlayingBar() }
            }
            .navigationTitle("Music")
            .searchable(text: $query, prompt: "Search your library")
            .onSubmit(of: .search) { Task { await search() } }
            .onChange(of: query) { v in if v.isEmpty { songs = []; Task { await loadAlbums() } } }
            .task { await loadAlbums() }
        }
    }

    @ViewBuilder private var content: some View {
        if let error {
            ContentUnavailableView_compat("Music unavailable", systemImage: "music.note", desc: error)
        } else if loading && songs.isEmpty && albums.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !songs.isEmpty {
            List(Array(songs.enumerated()), id: \.element.id) { i, song in
                SongRow(song: song, playing: player.current?.id == song.id)
                    .contentShape(Rectangle())
                    .onTapGesture { player.play(songs, startAt: i) }
            }
            .listStyle(.plain)
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

    // MARK: - Networking

    private func musicURL(_ path: String, _ extra: [String: String] = [:]) -> URL {
        var c = URLComponents(url: origin.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.queryItems = ([("app", creds.app), ("token", creds.token)] + extra.map { ($0, $1) })
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        return c.url!
    }

    private func fetch<T: Decodable>(_ url: URL, _ key: String) async throws -> [T] {
        let (data, _) = try await URLSession.shared.data(from: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let arr = obj?[key] else {
            throw NSError(domain: "music", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: (obj?["error"] as? String) ?? "no data"])
        }
        let d = try JSONSerialization.data(withJSONObject: arr)
        return try JSONDecoder().decode([T].self, from: d)
    }

    private func loadAlbums() async {
        guard !creds.token.isEmpty else { error = "Not configured"; return }
        loading = true; error = nil
        do { albums = try await fetch(musicURL("music/search"), "albums") }
        catch { self.error = error.localizedDescription }
        loading = false
    }

    private func search() async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        loading = true; error = nil
        do { songs = try await fetch(musicURL("music/search", ["q": query]), "songs") }
        catch { self.error = error.localizedDescription }
        loading = false
    }

    private func playAlbum(_ album: Album) async {
        do {
            let tracks: [Song] = try await fetch(musicURL("music/album", ["id": album.id]), "songs")
            if !tracks.isEmpty { player.play(tracks) }
        } catch { self.error = error.localizedDescription }
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
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }
            Button { player.next() } label: { Image(systemName: "forward.fill") }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .foregroundStyle(.primary)
    }
}

/// iOS 16-safe stand-in for ContentUnavailableView (iOS 17+).
private struct ContentUnavailableView_compat: View {
    let title: String; let systemImage: String; let desc: String
    init(_ title: String, systemImage: String, desc: String) {
        self.title = title; self.systemImage = systemImage; self.desc = desc
    }
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(desc).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
