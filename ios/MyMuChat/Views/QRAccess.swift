import SwiftUI
import UIKit
import VisionKit
import CoreImage.CIFilterBuiltins

/// QR-based access hand-off (Manar, 2026-09-19): one device shows a QR that
/// encodes server + username (password optional, typed in at share time —
/// the app never has it stored); another device scans it and lands on a
/// prefilled sign-in. The payload is a `mymu://login?...` URL — so the plain
/// iPhone CAMERA also works: iOS shows "Open in MyMu" and the app opens with
/// the fields entered (Manar's actual flow; the first JSON payload only
/// worked from the in-app scanner and the camera sent it to Safari).
/// Legacy JSON payloads and bare server URLs still parse.
struct AccessPayload: Codable, Equatable {
    var mymu: Int = 1
    var origin: String
    var username: String?
    var password: String?

    /// The QR/link form: mymu://login?origin=…&username=…[&password=…]
    var qrString: String {
        var comps = URLComponents()
        comps.scheme = "mymu"
        comps.host = "login"
        var items = [URLQueryItem(name: "origin", value: origin)]
        if let username { items.append(URLQueryItem(name: "username", value: username)) }
        if let password { items.append(URLQueryItem(name: "password", value: password)) }
        comps.queryItems = items
        return comps.string ?? origin
    }

    /// mymu:// links first (QRs + onOpenURL share this parser), then legacy
    /// JSON with the marker, then bare server addresses (people QR their
    /// server URL more often than one thinks).
    static func parse(_ raw: String) -> AccessPayload? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("mymu://"), let comps = URLComponents(string: s) {
            let q = { (name: String) in comps.queryItems?.first(where: { $0.name == name })?.value }
            guard let origin = q("origin"), !origin.isEmpty else { return nil }
            return AccessPayload(origin: origin, username: q("username"), password: q("password"))
        }
        if let data = s.data(using: .utf8),
           let p = try? JSONDecoder().decode(AccessPayload.self, from: data), p.mymu == 1 {
            return p
        }
        guard !s.isEmpty, !s.contains("{"), !s.contains(" ") else { return nil }
        return AccessPayload(origin: s)
    }
}

// MARK: - Share (generate)

/// Sheet showing the access QR for an account. Origin + username come from
/// the ACTIVE account; the password is typed here if (and only if) the QR
/// should carry a full sign-in — it lives in this sheet's state and nowhere
/// else.
struct AccessQRSheet: View {
    let origin: String
    let username: String
    @State private var password = ""
    @Environment(\.dismiss) private var dismiss

    private var payload: AccessPayload {
        AccessPayload(origin: origin, username: username,
                      password: password.isEmpty ? nil : password)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 18) {
                    if let img = Self.qrImage(payload.qrString) {
                        Image(uiImage: img)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 240, height: 240)
                            .padding(14)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    VStack(spacing: 3) {
                        Text(username).font(.headline).foregroundColor(Theme.text)
                        Text(origin).font(.footnote).foregroundColor(Theme.mutedText)
                    }
                    // Password stays OUT of the QR until typed — sharing just
                    // server+user is the safe default; the full sign-in QR is
                    // an explicit act.
                    HStack(spacing: 10) {
                        Image(systemName: "lock").foregroundColor(Theme.mutedText).frame(width: 20)
                        SecureField("", text: $password,
                                    prompt: Text("Password (optional — include to sign in on scan)")
                                        .foregroundColor(Theme.mutedText))
                            .foregroundColor(Theme.text)
                    }
                    .padding(12)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
                    Text(password.isEmpty
                         ? "Scan with the iPhone camera — MyMu opens with server and username entered; the password is typed there."
                         : "This QR now signs in directly — anyone who scans it gets access.")
                        .font(.caption)
                        .foregroundColor(password.isEmpty ? Theme.mutedText : Theme.danger)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(24)
            }
            .navigationTitle("Access QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    /// Crisp CoreImage QR (nearest-neighbor upscale; .interpolation(.none)
    /// keeps the modules sharp at display size).
    static func qrImage(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Scan

/// Camera QR scanner for the login screen. VisionKit's DataScanner — no
/// AVCapture plumbing; first recognized QR wins and the sheet dismisses.
struct QRScanSheet: View {
    let onScan: (AccessPayload) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rejected = false

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    ScannerRepresentable { raw in
                        if let payload = AccessPayload.parse(raw) {
                            dismiss()
                            onScan(payload)
                        } else {
                            rejected = true
                        }
                    }
                    .ignoresSafeArea()
                    .overlay(alignment: .bottom) {
                        Text(rejected ? "Not a MyMu access code — keep scanning."
                                      : "Point at an access QR from another MyMu.")
                            .font(.footnote)
                            .foregroundColor(rejected ? Theme.danger : Theme.mutedText)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Theme.background.opacity(0.85))
                            .clipShape(Capsule())
                            .padding(.bottom, 24)
                    }
                } else {
                    // Simulator, camera restriction, or permission denied.
                    VStack(spacing: 10) {
                        Image(systemName: "camera.on.rectangle").font(.title2).foregroundColor(Theme.mutedText)
                        Text("Camera scanning isn't available on this device.\nCheck camera access for MyMu in Settings.")
                            .font(.footnote).foregroundColor(Theme.mutedText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
                }
            }
            .navigationTitle("Scan access QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

private struct ScannerRepresentable: UIViewControllerRepresentable {
    let onRaw: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onRaw: onRaw) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onRaw: (String) -> Void
        init(onRaw: @escaping (String) -> Void) { self.onRaw = onRaw }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let code) = item, let s = code.payloadStringValue {
                    onRaw(s)
                    return
                }
            }
        }
    }
}
