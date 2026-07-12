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
    private var audioWS: WebSocketClient?
    private var audioConverter: AVAudioConverter?
    private let audioTarget = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 16000, channels: 1,
                                            interleaved: true)!

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let cfg = SharedConfig.load()
        ingest = IngestClient(cfg: cfg)
        let ws = WebSocketClient(url: cfg.audioURL, token: cfg.token)
        ws.connect()
        audioWS = ws
    }

    override func broadcastFinished() {
        ingest = nil
        audioWS?.close()
        audioWS = nil
        audioConverter = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        if type == .audioMic {
            autoreleasepool { handleMic(sampleBuffer) }
            return
        }
        guard type == .video else { return }          // app-audio buffers: not wanted

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

    /// Mic CMSampleBuffer (device-native format, often 44.1/48 kHz) ->
    /// 16 kHz mono PCM16 -> the same audio WebSocket the in-app streamer uses.
    /// Lean on purpose: one pooled conversion per buffer, nothing retained.
    private func handleMic(_ sb: CMSampleBuffer) {
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
        audioWS?.sendBinary(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
    }
}
