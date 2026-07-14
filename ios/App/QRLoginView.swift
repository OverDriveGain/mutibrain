import SwiftUI
import AVFoundation

/// Log in by pointing the camera at the subscriber's voice QR (shown on the
/// server's /admin page). The QR encodes the full tokenized voice URL
/// (https://…/voice?app=<name>&token=<tok>). On scan we VALIDATE before
/// saving: the URL must parse with app+token, and the server must accept the
/// token (GET /config?app=&token= → 200). Bad/stale QR = clear error, nothing
/// overwritten.
struct QRLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let onLogin: (String) -> Void

    @State private var status: String = "Point the camera at your voice QR code"
    @State private var busy = false

    var body: some View {
        NavigationView {
            ZStack {
                QRCameraView { code in handleScan(code) }
                    .ignoresSafeArea()
                VStack {
                    Spacer()
                    Text(status)
                        .font(.callout.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.bottom, 40)
                        .padding(.horizontal, 24)
                }
                if busy { ProgressView().scaleEffect(1.6) }
            }
            .navigationTitle("Scan to log in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func handleScan(_ code: String) {
        guard !busy else { return }
        guard let url = URL(string: code),
              let scheme = url.scheme, ["http", "https"].contains(scheme),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let app = comps.queryItems?.first(where: { $0.name == "app" })?.value, !app.isEmpty,
              let token = comps.queryItems?.first(where: { $0.name == "token" })?.value, !token.isEmpty
        else {
            status = "Not a voice login QR (need …/voice?app=…&token=…)"
            return
        }
        busy = true
        status = "Checking with \(url.host ?? "server")…"

        var probe = URLComponents()
        probe.scheme = scheme
        probe.host = url.host
        probe.port = url.port
        probe.path = "/config"
        probe.queryItems = [.init(name: "app", value: app), .init(name: "token", value: token)]
        URLSession.shared.dataTask(with: probe.url!) { _, resp, err in
            DispatchQueue.main.async {
                busy = false
                let ok = (resp as? HTTPURLResponse)?.statusCode == 200
                if ok {
                    GadkVoice.beacon("qr-login-ok-\(app)")
                    onLogin(code)
                    dismiss()
                } else if let err {
                    status = "Can't reach the server: \(err.localizedDescription)"
                } else {
                    status = "Server rejected this code (expired token?) — get a fresh QR from /admin"
                }
            }
        }.resume()
    }
}

/// Thin AVCapture wrapper that reports QR payloads. Camera permission is
/// requested on first use; a denial shows a hint instead of a black screen.
private struct QRCameraView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ vc: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var lastCode: String?
        private var lastAt = Date.distantPast

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.startCamera() : self?.showDenied()
                }
            }
        }

        private func startCamera() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return showDenied() }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return showDenied() }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.frame = view.bounds
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }

        private func showDenied() {
            let label = UILabel()
            label.text = "Camera access needed — enable it in Settings > AI Assistant"
            label.textColor = .white
            label.numberOfLines = 0
            label.textAlignment = .center
            label.frame = view.bounds.insetBy(dx: 32, dy: 0)
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(label)
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let obj = objects.first as? AVMetadataMachineReadableCodeObject,
                  obj.type == .qr, let code = obj.stringValue else { return }
            // debounce: the camera fires the same code many times per second
            if code == lastCode, Date().timeIntervalSince(lastAt) < 3 { return }
            lastCode = code
            lastAt = Date()
            onCode?(code)
        }
    }
}
