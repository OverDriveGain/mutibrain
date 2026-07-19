import Foundation

/// Offline music. Keeps ORIGINAL files (Subsonic download.view — never
/// transcoded) in Documents/MusicDownloads plus an index.json of Song
/// metadata, so downloaded tracks survive relaunches and play with no
/// network: SubsonicPlayer transparently swaps in the local file whenever
/// one exists (see playCurrent()).
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    @Published private(set) var songs: [Song] = []          // downloaded, newest first
    @Published private(set) var inFlight: Set<String> = []  // song ids being fetched

    private let dir: URL
    private let indexURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("MusicDownloads", isDirectory: true)
        indexURL = dir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([Song].self, from: data) {
            // keep only entries whose audio file is still on disk
            songs = saved.filter { localURL($0.id) != nil }
        }
    }

    func isDownloaded(_ id: String) -> Bool { localURL(id) != nil }

    /// The local audio file for a song id, if downloaded (any extension).
    func localURL(_ id: String) -> URL? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        for n in names where n.hasPrefix(id + ".") && n != "index.json" {
            return dir.appendingPathComponent(n)
        }
        return nil
    }

    func download(_ song: Song) {
        guard !isDownloaded(song.id), !inFlight.contains(song.id),
              let url = URL(string: song.downloadUrl ?? song.streamUrl) else { return }
        inFlight.insert(song.id)
        Task {
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: url)
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                // AVPlayer picks the demuxer from the file EXTENSION for local
                // files — derive it from the served MIME type (library is
                // mostly mp3; flac/m4a/ogg covered too).
                let ext = Self.ext(for: http.value(forHTTPHeaderField: "Content-Type"))
                let dest = dir.appendingPathComponent("\(song.id).\(ext)")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                await MainActor.run {
                    self.inFlight.remove(song.id)
                    self.songs.removeAll { $0.id == song.id }
                    self.songs.insert(song, at: 0)
                    self.persist()
                }
                GadkVoice.beacon("dl-ok-\(song.id)")
            } catch {
                await MainActor.run { self.inFlight.remove(song.id) }
                GadkVoice.beacon("dl-fail-\(song.id)")
            }
        }
    }

    func remove(_ id: String) {
        if let u = localURL(id) { try? FileManager.default.removeItem(at: u) }
        songs.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(songs) { try? data.write(to: indexURL) }
    }

    private static func ext(for mime: String?) -> String {
        switch (mime ?? "").lowercased().split(separator: ";").first.map(String.init) ?? "" {
        case "audio/mpeg": return "mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac": return "m4a"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/ogg", "application/ogg": return "ogg"
        case "audio/wav", "audio/x-wav": return "wav"
        default: return "mp3"
        }
    }
}
