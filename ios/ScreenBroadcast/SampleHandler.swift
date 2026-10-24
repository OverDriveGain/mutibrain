import ReplayKit
import CoreImage
import CoreMedia
import AVFoundation

/// Runs in its own process while a system-wide broadcast is active. Receives
/// every screen frame of the WHOLE device, downscales + JPEG-encodes a throttled
/// subset, and streams them to the server. Keeps going after the user leaves the
/// app (that's the point of a broadcast upload extension).
///
/// Extensions are memory-capped (~50 MB), so we downscale hard, throttle the
/// frame rate, and never retain sample buffers.
class SampleHandler: RPBroadcastSampleHandler {
    private var ingest: IngestClient?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private var lastSent = CFAbsoluteTimeGetCurrent()
    // Memory is the enemy in a ~50MB extension. Keep it lean so iOS never kills us:
    // 1 fps, hard downscale, modest quality, and free every intermediate promptly.
    private let minInterval: TimeInterval = 1.0   // ~1 fps (plenty for a screen memory)
    private let maxWidth: CGFloat = 480
    private let jpegQuality: CGFloat = 0.4

    // ---- system-level mic (deeper than any app session) --------------------
    // ReplayKit hands us mic buffers HERE, in the broadcast process: no
    // AVAudioSession politics, so YouTube/lock/app-suspension can't stop it.
    // The user enables the mic via the toggle in the broadcast start sheet.
    //
    // We convert each mic buffer to 16 kHz mono PCM16, accumulate ~20 s, then
    // POST the segment (WAV-wrapped) to the screenpipe central via /ingest-audio
    // (the screenpipe massam, audio half). WAV needs no encoder (lean for the
    // ~50 MB extension) and ffmpeg/faster-whisper sniff the container regardless
    // of the declared mime, so it decodes fine. Replaces the old /v1/audio WS,
    // which never existed server-side (HTTP 403).
    // Capture APP audio too (the audio the device plays: the far side of a
    // call, media, etc.) — not just the mic. ReplayKit delivers it as
    // `.audioApp`; we run it through the SAME converter+accumulator as the
    // mic, so both mix into one mono segment = the whole call, both sides.
    // Build-time constant (App Groups are stripped in this build, so a
    // runtime toggle can't reach the extension). NOTE: this is INDISCRIMINATE
    // — while broadcasting it records ALL device playback, not only calls.
    private let captureAppAudio = true
    private let audioSampleRate = 16000
    private let audioSegmentSeconds: Double = 20
    private var audioIngest: AudioIngestClient?
    private var audioConverter: AVAudioConverter?
    private let audioTarget = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 16000, channels: 1,
                                            interleaved: true)!
    private var pcmAccum = Data()
    private var segmentStart = Date()
    private let audioLock = NSLock()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let cfg = SharedConfig.load()
        ingest = IngestClient(cfg: cfg)
        audioIngest = AudioIngestClient(cfg: cfg)
        segmentStart = Date()
    }

    override func broadcastFinished() {
        ingest = nil
        flushAudioSegment()          // ship whatever's buffered
        audioIngest = nil
        audioConverter = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        if type == .audioMic {
            autoreleasepool { handleAudio(sampleBuffer) }
            return
        }
        if type == .audioApp {
            if captureAppAudio { autoreleasepool { handleAudio(sampleBuffer) } }
            return                                     // else: app audio ignored
        }
        guard type == .video else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSent >= minInterval else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // autoreleasepool: release CoreImage intermediates + the JPEG data this turn,
        // so peak memory stays well under the extension cap.
        autoreleasepool {
            var image = CIImage(cvPixelBuffer: pixelBuffer)
            let width = image.extent.width
            guard width > 0 else { return }
            if width > maxWidth {
                let scale = maxWidth / width
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            guard let jpeg = ciContext.jpegRepresentation(
                of: image,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: jpegQuality]
            ) else { return }
            lastSent = now
            ingest?.sendFrame(jpeg: jpeg)   // drops the frame if a POST is still in flight
        }
    }

    /// Audio CMSampleBuffer — mic OR app playback (device-native format,
    /// often 44.1/48 kHz) -> 16 kHz mono PCM16 -> accumulated and flushed as a
    /// WAV segment to /ingest-audio. Both sources feed this same accumulator,
    /// so a call's two sides mix into one chronological mono track. Lean on
    /// purpose: one pooled conversion per buffer, nothing retained beyond the
    /// growing PCM accumulator.
    private func handleAudio(_ sb: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let srcFormat = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0,
              let src = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                         frameCapacity: AVAudioFrameCount(frames)) else { return }
        src.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frames),
            into: src.mutableAudioBufferList) == noErr else { return }

        if audioConverter == nil || audioConverter!.inputFormat != srcFormat {
            audioConverter = AVAudioConverter(from: srcFormat, to: audioTarget)
        }
        guard let conv = audioConverter else { return }
        let cap = AVAudioFrameCount(Double(frames) * audioTarget.sampleRate / srcFormat.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: audioTarget, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return src
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }

        audioLock.lock()
        pcmAccum.append(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
        let elapsed = Date().timeIntervalSince(segmentStart)
        let cap20 = audioSampleRate * 2 * Int(audioSegmentSeconds)   // bytes in a full segment
        let ready = elapsed >= audioSegmentSeconds || pcmAccum.count >= cap20
        audioLock.unlock()
        if ready { flushAudioSegment() }
    }

    /// Wrap the accumulated PCM16 as a WAV and POST it as one /ingest-audio
    /// segment, then reset the accumulator. No-op when empty.
    private func flushAudioSegment() {
        audioLock.lock()
        let pcm = pcmAccum
        let start = segmentStart
        pcmAccum = Data()
        segmentStart = Date()
        audioLock.unlock()
        guard !pcm.isEmpty else { return }
        let wav = Self.wav(fromPCM16: pcm, sampleRate: audioSampleRate, channels: 1)
        audioIngest?.sendSegment(wav, mime: "audio/wav", timestamp: start)
    }

    /// Minimal 44-byte RIFF/WAVE header + PCM16 payload (no encoder needed).
    private static func wav(fromPCM16 pcm: Data, sampleRate: Int, channels: Int) -> Data {
        let byteRate = sampleRate * channels * 2
        let blockAlign = channels * 2
        let dataLen = pcm.count
        var h = Data()
        func le32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        func le16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        h.append(contentsOf: Array("RIFF".utf8)); le32(36 + dataLen)
        h.append(contentsOf: Array("WAVE".utf8))
        h.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(channels)
        le32(sampleRate); le32(byteRate); le16(blockAlign); le16(16)
        h.append(contentsOf: Array("data".utf8)); le32(dataLen)
        h.append(pcm)
        return h
    }
}
