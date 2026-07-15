import AVFoundation

/// The ONE owner of the app's AVAudioSession, with exactly two states. This
/// follows the STANDARD iOS pattern (what Siri/Maps do) instead of fighting it:
///
///  - `.media` (the resting state): playAndRecord + mode .default. The
///    always-on screenpipe mic keeps its input; music (AVPlayer) plays at FULL
///    MEDIA VOLUME — in this mode output rides the normal media-volume domain.
///
///  - `.conversation` (only while the user talks to the assistant):
///    playAndRecord + mode .voiceChat with echo-cancellation on the voice
///    engine. iOS treats it as a call and DUCKS other audio — so music dips
///    under the assistant's voice by the system's own standard behavior, and
///    comes back up when the conversation ends and we return to `.media`.
///
/// We deliberately do NOT try to play the assistant's voice and music at full
/// volume simultaneously: call audio and media audio live in different volume
/// domains on iOS (the beacons showed vol jumping 100→25 across a mode flip),
/// and every first-party experience ducks instead of mixing. Standard wins.
///
/// RULES: nobody else calls setCategory/setMode. State changes happen on
/// AudioGraph.q, strictly ordered with engine teardowns (mutating the session
/// under a live graph is what got the app watchdog-killed).
enum AudioSessionManager {

    enum State: String { case media, conversation }

    private(set) static var state: State = .media

    /// The resting state — full-media-volume playback + recorder input.
    static func media() {
        apply(category: .playAndRecord, mode: .default, state: .media)
    }

    /// Call mode for the voice conversation. iOS flips to the call-volume
    /// domain and ducks other audio (that IS the wanted standard behavior).
    static func conversation() {
        apply(category: .playAndRecord, mode: .voiceChat, state: .conversation)
    }

    /// Fully release the session — ONLY when nothing at all is using audio.
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
    }

    private static func apply(category: AVAudioSession.Category,
                              mode: AVAudioSession.Mode, state newState: State) {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(category, mode: mode,
                              options: [.defaultToSpeaker, .allowBluetooth,
                                        .allowBluetoothA2DP])
            try s.setActive(true)
        } catch {
            GadkVoice.beacon("session-\(newState.rawValue)-FAILED-\(error.localizedDescription)")
        }
        state = newState
        GadkVoice.beacon("session-\(newState.rawValue)-\(describe())")
    }

    static func describe() -> String {
        let s = AVAudioSession.sharedInstance()
        let route = s.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        return "cat=\(s.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: ""))"
            + "-mode=\(s.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: ""))"
            + "-vol=\(Int(s.outputVolume * 100))-out=\(route)"
    }
}
