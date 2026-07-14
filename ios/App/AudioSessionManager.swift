import AVFoundation

/// ONE audio-session policy for the whole app. Every audio consumer (voice
/// conversation, screenpipe mic, music) calls `configure()` — nobody sets a
/// different category. That is the systematic fix for two bugs:
///
///  1. CRASH when talking after music: previously music set `.playback` (no
///     input) and then the voice engine installed a mic tap on it → invalid
///     input format → hard crash. One never-switching category = no crash.
///
///  2. QUIET / DUCKED music: the voice path used mode `.voiceChat`, whose
///     echo-canceller DUCKS every other sound, so music played under a
///     conversation was quiet. Mode `.default` does NOT duck — the assistant's
///     TTS and the music MIX at equal volume through the shared output mixer.
///     (Echo-cancellation for the mic is done at the ENGINE node level via
///     setVoiceProcessingEnabled, which does not require `.voiceChat`.)
///
/// `.playAndRecord` supports mic + playback simultaneously; `.defaultToSpeaker`
/// keeps it loud on the speaker. No `.mixWithOthers` (that made iOS suspend the
/// app in the background) — our own sounds mix internally regardless.
enum AudioSessionManager {
    static func configure() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default,
                           options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try? s.setActive(true)
        try? s.overrideOutputAudioPort(.speaker)
    }

    static func describe() -> String {
        let s = AVAudioSession.sharedInstance()
        let route = s.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        return "cat=\(s.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: ""))"
            + "-mode=\(s.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: ""))"
            + "-vol=\(Int(s.outputVolume * 100))-out=\(route)"
    }
}
