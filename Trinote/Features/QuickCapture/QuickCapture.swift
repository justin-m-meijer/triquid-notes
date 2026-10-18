import SwiftUI
import UIKit
import Vision
import VisionKit

/// Photo and document-scan capture from the welcome screen. A capture is staged as a share-import
/// package, so the existing import flow asks where to put it, names the note and opens it.
@MainActor
enum QuickCapture {
    static var canTakePhoto: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    static var canScan: Bool { VNDocumentCameraViewController.isSupported }

    /// A new note with the photo in its body.
    static func stagePhoto(_ image: UIImage, appState: AppState) throws {
        guard let data = image.normalizedToUpOrientation().jpegData(compressionQuality: 0.85) else {
            throw CaptureError.encodingFailed
        }
        // No filename: the importer titles images by capture time.
        let payload = SharedImportPayload(
            filename: nil,
            mimeType: "image/jpeg",
            uti: "public.jpeg",
            kind: .image,
            text: nil,
            hasBinaryData: true
        )
        try stage(payload, data: data, appState: appState)
    }

    /// A new note with the scan as a PDF attachment and its recognized text as the body, so the
    /// note is searchable.
    static func stageScan(_ pages: [UIImage], appState: AppState) async throws {
        guard !pages.isEmpty else { throw CaptureError.emptyScan }
        let pdf = pdfData(from: pages)
        let text = await recognizedText(in: pages)
        let stamp = Date.now.formatted(.verbatim(
            "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits)",
            timeZone: .current,
            calendar: .current
        ))
        let payload = SharedImportPayload(
            filename: String(localized: "Scan \(stamp).pdf", comment: "Quick capture: scanned document filename; argument is date and time"),
            mimeType: "application/pdf",
            uti: "com.adobe.pdf",
            kind: .file,
            text: nil,
            hasBinaryData: true,
            bodyText: text
        )
        try stage(payload, data: pdf, appState: appState)
    }

    /// One page per scanned image, fitted to A4 width.
    nonisolated static func pdfData(from pages: [UIImage]) -> Data {
        let pageWidth: CGFloat = 595
        let bounds = CGRect(x: 0, y: 0, width: pageWidth, height: pageWidth * 1.414)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { context in
            for page in pages {
                let size = page.size
                let height = size.width > 0 ? pageWidth * size.height / size.width : bounds.height
                context.beginPage(withBounds: CGRect(x: 0, y: 0, width: pageWidth, height: height), pageInfo: [:])
                page.draw(in: CGRect(x: 0, y: 0, width: pageWidth, height: height))
            }
        }
    }

    /// On-device text recognition, one paragraph per line, pages separated by a blank line.
    nonisolated static func recognizedText(in pages: [UIImage]) async -> String {
        var pageTexts: [String] = []
        for page in pages {
            guard let cgImage = page.cgImage else { continue }
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let observations = (try? await request.perform(on: cgImage, orientation: page.imageOrientation.cgOrientation)) ?? []
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            if !lines.isEmpty { pageTexts.append(lines.joined(separator: "\n")) }
        }
        return pageTexts.joined(separator: "\n\n")
    }

    private static func stage(_ payload: SharedImportPayload, data: Data, appState: AppState) throws {
        try SharedImportStore.write(payload: payload, binaryData: data)
        appState.shareImport.checkForPendingPayload()
        // The "shared from another app" explanation does not apply; go straight to the parent picker.
        appState.shareImport.continueFromExplanation()
    }

    enum CaptureError: LocalizedError {
        case encodingFailed
        case emptyScan

        var errorDescription: String? {
            switch self {
            case .encodingFailed: String(localized: "The photo could not be saved.", comment: "Quick capture error")
            case .emptyScan: String(localized: "The scan has no pages.", comment: "Quick capture error")
            }
        }
    }
}

private extension UIImage.Orientation {
    var cgOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}

/// The system camera, returning the photo taken.
struct PhotoCaptureView: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: PhotoCaptureView
        init(parent: PhotoCaptureView) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}

/// The system document scanner (edge detection, perspective correction), returning the pages.
struct DocumentScanView: UIViewControllerRepresentable {
    var onScan: ([UIImage]) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // VisionKit calls the delegate on the main thread but does not annotate the protocol.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScanView
        init(parent: DocumentScanView) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            parent.onScan((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onCancel()
        }
    }
}
