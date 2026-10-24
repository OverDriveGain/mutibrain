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
    ///
    /// BLUETOOTH (2026-09-13, Manar: "voice doesn't go to headphones, forced
    /// on speaker"): .voiceChat cannot route output over A2DP — with HFP
    /// disallowed and BT connected, iOS fell back to the SPEAKER. So the
    /// conversation state additionally allows HFP (.allowBluetooth), exactly
    /// what every VoIP call does: assistant voice + headset mic ride the
    /// hands-free profile (speech-band audio is fine for SPEECH). The
    /// 2026-07-15 music ruling is untouched — music only ever plays in
    /// `.media`, which stays A2DP-only, so it can never hit the call codec.
    static func conversation() {
        apply(category: .playAndRecord, mode: .voiceChat, state: .conversation,
              extraOptions: [.allowBluetooth])
    }

    /// Fully release the session — ONLY when nothing at all is using audio.
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
    }

    private static func apply(category: AVAudioSession.Category,
                              mode: AVAudioSession.Mode, state newState: State,
                              extraOptions: AVAudioSession.CategoryOptions = []) {
        let s = AVAudioSession.sharedInstance()
        do {
            // BASE = A2DP only, never HFP: with .playAndRecord and a live
            // input, iOS pins Bluetooth to the HANDS-FREE profile so it can
            // use the headset mic — and then MUSIC plays over the 8/16 kHz
            // mono phone-call codec (prod beacons: out=BluetoothHFP at
            // vol=100 = Manar's "low quality / effect on it"). With A2DP-only
            // the BT output rides the full-band stereo media link and the mic
            // falls back to the iPhone's built-in mic (AEC works fine with
            // it). The CONVERSATION state opts back into HFP via extraOptions
            // (see conversation()) — voiceChat can't output over A2DP, and a
            // voice call over the hands-free profile IS the platform standard.
            var options: AVAudioSession.CategoryOptions =
                [.defaultToSpeaker, .allowBluetoothA2DP]
            options.formUnion(extraOptions)
            try s.setCategory(category, mode: mode, options: options)
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
