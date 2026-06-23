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
    private var ws: WebSocketClient?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private var lastSent = CFAbsoluteTimeGetCurrent()
    private let minInterval: TimeInterval = 0.5   // ~2 fps
    private let maxWidth: CGFloat = 720
    private let jpegQuality: CGFloat = 0.5
    private var inFlight = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let cfg = SharedConfig.load()
        let client = WebSocketClient(url: cfg.screenURL, token: cfg.token)
        client.connect()
        ws = client
    }

    override func broadcastFinished() {
        ws?.close()
        ws = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video else { return }          // ignore app/mic audio tracks here
        guard !inFlight else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSent >= minInterval else { return }
        lastSent = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let width = image.extent.width
        if width > maxWidth {
            let scale = maxWidth / width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        guard let jpeg = ciContext.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: jpegQuality]
        ) else { return }

        inFlight = true
        ws?.sendBinary(jpeg)
        inFlight = false
    }
}
