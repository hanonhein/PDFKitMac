import SwiftUI
import PDFKit

// Shared pieces used by the tool screens (Merge, Split, ...)

// One PDF the user picked
struct PickedPdf: Identifiable {
    let id = UUID()
    let name: String
    let document: PDFDocument
    var password: String? = nil   // the password it was opened with, if it has one
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

// "report_page1.pdf", or "report_page1 (2).pdf" if that name is already taken
func freeFileURL(in folder: URL, name: String, ext: String) -> URL {
    var url = folder.appendingPathComponent("\(name).\(ext)")
    var number = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = folder.appendingPathComponent("\(name) (\(number)).\(ext)")
        number += 1
    }
    return url
}

// A rounded square with a coloured icon (same as Android IconBadge)
struct IconBadge: View {
    let icon: String
    let color: TileColor
    let size: CGFloat

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.42))
            .foregroundStyle(color.foreground)
            .frame(width: size, height: size)
            .background(color.background, in: RoundedRectangle(cornerRadius: size * 0.3))
    }
}

// MARK: - Choosing one PDF, which may have a password

// Opens a PDF even if it has a password (the picker below then asks for it)
func loadPdfAllowingPassword(_ url: URL) -> Result<PickedPdf, PdfLoadError> {
    let hasAccess = url.startAccessingSecurityScopedResource()
    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
    guard let document = PDFDocument(url: url) else {
        return .failure(PdfLoadError("\(url.lastPathComponent) is not a valid PDF"))
    }
    return .success(PickedPdf(name: url.lastPathComponent, document: document))
}

// "1.4 MB"
func fileSizeText(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

// A box that shows the chosen PDF (or a button to choose one). If the PDF has a password,
// it asks for it right here; `file` is only set once the PDF can be read.
struct PasswordPdfPicker: View {
    @Binding var file: PickedPdf?
    var onPick: () -> Void = {}
    @State private var waiting: PickedPdf?   // picked, but still needs its password
    @State private var password = ""
    @State private var wrong = false
    @State private var message: String?
    @State private var showPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconBadge(icon: (file ?? waiting)?.document.isEncrypted == true ? "lock.doc" : "doc.fill", color: .orange, size: 40)
                if let shown = file ?? waiting {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shown.name).lineLimit(1)
                        Text(file == nil ? "This PDF has a password" :
                                (shown.document.pageCount == 1 ? "1 page" : "\(shown.document.pageCount) pages"))
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Text("No PDF chosen. Click the button or drop a file here.").foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button(file == nil && waiting == nil ? "Choose PDF" : "Change") { showPicker = true }
            }

            if waiting != nil {
                HStack {
                    SecureField("Password of this PDF", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit(unlock)
                    Button("Open", action: unlock).disabled(password.isEmpty)
                }
                if wrong { Text("That password is not right. Try again.").font(.caption).foregroundStyle(Theme.orange) }
            }
            if let message { Text(message).font(.caption).foregroundStyle(Theme.orange) }
        }
        .padding(14)
        .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 20))
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { pick(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
            pick(url)
            return true
        }
    }

    private func pick(_ url: URL) {
        message = nil
        wrong = false
        password = ""
        file = nil
        waiting = nil
        switch loadPdfAllowingPassword(url) {
        case .success(let picked):
            if picked.document.isLocked { waiting = picked } else { file = picked; onPick() }
        case .failure(let error):
            message = error.message
        }
    }

    private func unlock() {
        guard var picked = waiting else { return }
        if picked.document.unlock(withPassword: password) {
            picked.password = password
            file = picked
            waiting = nil
            wrong = false
            onPick()
        } else {
            wrong = true
        }
    }
}

enum SaveOutcome {
    case saved(URL)
    case cancelled
    case failed
}

// Asks where to save a PDF, then saves it (with a password if given)
func savePdfWithPanel(_ document: PDFDocument, suggestedName: String, password: String? = nil) -> SaveOutcome {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue = suggestedName
    guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
    let ok: Bool
    if let password {
        ok = document.write(to: url, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password])
    } else {
        ok = document.write(to: url)
    }
    return ok ? .saved(url) : .failed
}
