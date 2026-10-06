import SwiftUI
import PDFKit

// Shared pieces used by the tool screens (Merge, Split, ...)

// One PDF the user picked
struct PickedPdf: Identifiable {
    let id = UUID()
    let name: String
    let document: PDFDocument
}

// Opens a picked file. Returns an error message instead if it can't be used.
func loadPickedPdf(_ url: URL) -> Result<PickedPdf, PdfLoadError> {
    let hasAccess = url.startAccessingSecurityScopedResource()
    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

    guard let document = PDFDocument(url: url) else {
        return .failure(PdfLoadError("\(url.lastPathComponent) is not a valid PDF"))
    }
    if document.isLocked {
        return .failure(PdfLoadError("\(url.lastPathComponent) has a password, remove it first"))
    }
    return .success(PickedPdf(name: url.lastPathComponent, document: document))
}

struct PdfLoadError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// Makes a new PDF from some pages (0-based page numbers) of another PDF
@discardableResult
func copyPages(_ pages: [Int], from source: PDFDocument, into output: PDFDocument = PDFDocument()) -> PDFDocument {
    for index in pages {
        if let page = source.page(at: index)?.copy() as? PDFPage {
            output.insert(page, at: output.pageCount)
        }
    }
    return output
}

// "report.pdf" -> "report"
func baseName(_ fileName: String) -> String {
    (fileName as NSString).deletingPathExtension
}

// The green "Saved" bar shown after a tool finishes
struct SavedBanner: View {
    let text: String
    let showURL: URL
    var openURL: URL?
    var onOpen: (URL) -> Void = { _ in }

    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal)
            Text(text)
            Spacer()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([showURL]) }
            if let openURL {
                Button("Open") { onOpen(openURL) }
            }
        }
        .padding(12)
        .background(Theme.tealContainer.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}
