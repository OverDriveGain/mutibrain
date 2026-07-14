import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// A song with a server-signed stream URL (creds stay on the mymu-voice server;
/// the app only ever holds URLs). Decoded from /music/* and play_music results.
struct Song: Identifiable, Codable, Equatable {
    let id: String
    let title: String?
    let artist: String?
    let album: String?
    let duration: Int?
    let streamUrl: String
    let coverUrl: String?

    var displayTitle: String { title ?? "Unknown" }
    var displayArtist: String { artist ?? "" }
}

/// App-wide music player: streams from Navidrome via AVPlayer, with a queue,
/// lock-screen / control-center transport, and background playback. One
/// instance so the Music tab, the now-playing bar, and voice-triggered playback
/// all drive the same engine.
final class SubsonicPlayer: NSObject, ObservableObject {
    static let shared = SubsonicPlayer()

    @Published private(set) var queue: [Song] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var isPlaying = false

    /// True once music owns the audio session — so GadkVoice.stop() won't
    /// deactivate the shared session out from under the music.
    static private(set) var isActive = false

    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }

    private let player = AVPlayer()
    private var endObserver: NSObjectProtocol?

    override init() {
        super.init()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in self?.next() }
        setupRemoteCommands()
        player.addObserver(self, forKeyPath: "timeControlStatus", options: [.new], context: nil)
    }

    // MARK: - Public control

    /// Replace the queue and start at `startAt`. This is what voice + taps call.
    func play(_ songs: [Song], startAt: Int = 0) {
        guard !songs.isEmpty else { return }
        Self.isActive = true
        queue = songs
        index = max(0, min(startAt, songs.count - 1))
        activateSession()
        playCurrent()
    }

    /// Append to the current queue (or start it if empty).
    func addToQueue(_ songs: [Song]) {
        if queue.isEmpty { play(songs) } else { queue.append(contentsOf: songs) }
    }

    /// Jump to a queue position (tapping a row in the Queue view).
    func playAt(_ i: Int) {
        guard queue.indices.contains(i) else { return }
        Self.isActive = true
        index = i
        activateSession()
        playCurrent()
    }

    /// Remove a queue entry, keeping playback sensible.
    func removeFromQueue(at i: Int) {
        guard queue.indices.contains(i) else { return }
        queue.remove(at: i)
        if queue.isEmpty { player.pause(); index = 0; return }
        if i < index { index -= 1 }
        else if i == index { index = min(index, queue.count - 1); playCurrent() }
    }

    func toggle() {
        if player.timeControlStatus == .playing { player.pause() }
        else { activateSession(); player.play() }
    }

    func next() {
        guard index + 1 < queue.count else { player.pause(); return }
        index += 1
        playCurrent()
    }

    func prev() {
        // restart the track if we're >3s in, else go to the previous one
        if player.currentTime().seconds > 3 || index == 0 {
            player.seek(to: .zero)
        } else {
            index -= 1
            playCurrent()
        }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    // MARK: - Engine

    private func playCurrent() {
        guard let song = current, let url = URL(string: song.streamUrl) else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
        updateNowPlaying()
    }

    /// The ONE shared session — same policy the voice + recorder use, so
    /// nothing switches categories (that switching is what crashed the app and
    /// what quieted the music). Mode .default -> music MIXES with the assistant
    /// at equal volume instead of being ducked.
    private func activateSession() {
        AudioSessionManager.configure()
    }

    // MARK: - Now Playing / remote transport

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.prev(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { self?.seek(to: e.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let song = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.displayTitle,
            MPMediaItemPropertyArtist: song.displayArtist,
            MPMediaItemPropertyAlbumTitle: song.album ?? "",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        if let d = song.duration { info[MPMediaItemPropertyPlaybackDuration] = d }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime().seconds
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadArtwork(song)
    }

    private func loadArtwork(_ song: Song) {
        guard let s = song.coverUrl, let url = URL(string: s) else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let img = UIImage(data: data),
                  SubsonicPlayer.shared.current?.id == song.id else { return }
            let art = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            DispatchQueue.main.async {
                MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = art
            }
        }.resume()
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                              change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "timeControlStatus" {
            DispatchQueue.main.async {
                self.isPlaying = self.player.timeControlStatus == .playing
                MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] =
                    self.isPlaying ? 1.0 : 0.0
            }
        }
    }
}
