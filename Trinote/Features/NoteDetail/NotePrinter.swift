import SwiftUI
import UIKit

/// Prints a note with the system print sheet: a PDF or image as itself, a text note as its text.
@MainActor
enum NotePrinter {
    static var isAvailable: Bool { UIPrintInteractionController.isPrintingAvailable }

    static func print(data: Data, title: String) {
        let controller = UIPrintInteractionController.shared
        controller.printInfo = printInfo(title)
        controller.printingItem = data
        controller.present(animated: true)
    }

    /// Note HTML with its title on top. Images the page loads from the server are left out.
    static func print(html: String, title: String) {
        let escapedTitle = MarkdownToNoteHTML.escapeHTML(title)
        let formatter = UIMarkupTextPrintFormatter(markupText: "<h1>\(escapedTitle)</h1>\(html)")
        formatter.perPageContentInsets = UIEdgeInsets(top: 48, left: 48, bottom: 48, right: 48)
        let controller = UIPrintInteractionController.shared
        controller.printInfo = printInfo(title)
        controller.printFormatter = formatter
        controller.present(animated: true)
    }

    static func print(note: NoteItem, viewModel: NoteDetailViewModel) {
        let title = note.title
        if note.type == .file || note.type == .image, let data = viewModel.content, !data.isEmpty {
            print(data: data, title: title)
        } else if let html = viewModel.contentString, !html.isEmpty {
            print(html: html, title: title)
        }
    }

    private static func printInfo(_ title: String) -> UIPrintInfo {
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = title
        info.outputType = .general
        return info
    }
}

/// Full Screen, Share and Print for a PDF, the same in a PDF note and under a note's text.
struct PDFActionBar: View {
    let data: Data
    let fileName: String
    let onFullScreen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onFullScreen) {
                Label(String(localized: "Full Screen", comment: "Open the PDF file note full screen"), systemImage: "arrow.up.left.and.arrow.down.right")
            }
            ShareLink(item: shareFile) {
                Label(String(localized: "Share", comment: "Share file note"), systemImage: "square.and.arrow.up")
            }
            if NotePrinter.isAvailable {
                Button {
                    NotePrinter.print(data: data, title: fileName)
                } label: {
                    Label(String(localized: "Print", comment: "Print a note or PDF"), systemImage: "printer")
                }
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .font(.subheadline)
    }

    private var shareFile: URL {
        let name = fileName.lowercased().hasSuffix(".pdf") ? fileName : fileName + ".pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? data.write(to: url)
        return url
    }
}
