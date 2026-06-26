import ReplayKit
import CoreImage
import CoreMedia

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

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        ingest = IngestClient(cfg: SharedConfig.load())
    }

    override func broadcastFinished() {
        ingest = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video else { return }          // mic audio is captured by the app, not here

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
}
