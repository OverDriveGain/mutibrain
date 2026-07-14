import Foundation

/// ALL audio-graph mutations (engine connect/start/stop, node play/stop,
/// buffer scheduling) run on this ONE serial queue. Two engines (voice +
/// screenpipe mic) plus AVPlayer music share the audio session; their
/// config-change handlers used to mutate graphs from racing threads — an
/// NSException lottery that crashed the app. Serial queue + ExcCatch = no
/// lottery: a bad mutation becomes a beacon, not a crash.
enum AudioGraph {
    static let q = DispatchQueue(label: "audio.graph", qos: .userInitiated)

    /// Run a graph mutation with NSException protection; returns true on
    /// success, beacons the exception otherwise. MUST be called on `q`.
    @discardableResult
    static func guarded(_ label: String, _ block: () -> Void) -> Bool {
        if let err = ExcCatch(label, block) {
            GadkVoice.beacon("exc-\(err.localizedDescription)")
            return false
        }
        return true
    }
}
