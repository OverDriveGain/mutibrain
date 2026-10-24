import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// System camera for the composer's "Camera" attach option: shoot a photo OR
/// record a video and stage it as an attachment. UIImagePickerController rather
/// than a custom AVFoundation session — the stock capture UI (mode toggle,
/// flash, flip) is exactly what "attach from camera" should be, and it handles
/// the permission prompt itself (NSCameraUsageDescription /
/// NSMicrophoneUsageDescription must cover it).
struct CameraPicker: UIViewControllerRepresentable {
    enum Capture {
        case photo(UIImage)
        /// tmp URL handed over by the picker — read it BEFORE returning to the
        /// caller's next runloop turn; the system reclaims the file eventually.
        case movie(URL)
    }

    let onCapture: (Capture) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        // 720p keeps a hand-held clip inside the server attachment cap; full
        // 4K blows through it in seconds and the send would just bounce.
        picker.videoQuality = .typeIFrame1280x720
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL {
                parent.onCapture(.movie(url))
            } else if let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage {
                parent.onCapture(.photo(image))
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
