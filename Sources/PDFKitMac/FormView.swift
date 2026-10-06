import SwiftUI
import PDFKit

// Fill form: type into the boxes of a PDF form right on the page, then save a new file
// (like Android FormScreen.kt, which shows the boxes as a list instead).

// The boxes you can fill (text boxes, tick boxes, lists) on all pages
func formFields(_ document: PDFDocument) -> [PDFAnnotation] {
    (0..<document.pageCount).flatMap { document.page(at: $0)?.annotations ?? [] }
        .filter { $0.type == "Widget" && $0.widgetFieldType != .signature }
}

struct FormView: View {
    @Binding var path: [Screen]
    @State private var file: PickedPdf?
    @State private var fieldCount = 0
    @State private var lock = false
    @State private var message: String?
    @State private var saved: URL?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Fill in the boxes of a PDF form, then save it as a new file. Click a box to type; Tab goes to the next box.")
                    .foregroundStyle(Theme.textSecondary)
                PasswordPdfPicker(file: $file, onPick: picked)
                if file != nil && fieldCount == 0 {
                    Text("This PDF has no boxes to fill. To write on any PDF, use Edit PDF and its Text tool.")
                        .foregroundStyle(Theme.orange)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            if let file, fieldCount > 0 {
                Divider()
                PDFViewer(document: file.document)   // Apple's viewer lets you fill the boxes on the page
                Divider()
                VStack(spacing: 8) {
                    if let message { Text(message).foregroundStyle(Theme.orange) }
                    if let saved {
                        SavedBanner(text: "Saved \(saved.lastPathComponent)", showURL: saved, openURL: saved) { path.append(.viewer($0)) }
                    }
                    HStack {
                        Text("\(fieldCount) box\(fieldCount == 1 ? "" : "es") to fill").foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Toggle("Lock the answers", isOn: $lock)
                            .help("The answers become part of the page and can't be changed any more")
                        Button("Save filled form", action: save)
                            .controlSize(.large).buttonStyle(.borderedProminent).tint(Theme.blue)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            } else {
                Spacer()
            }
        }
        .background(Theme.background)
        .navigationTitle("Fill form")
    }

    private func picked() {
        message = nil
        saved = nil
        fieldCount = file.map { formFields($0.document).count } ?? 0
    }

    private func save() {
        guard let file else { return }
        message = nil
        saved = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(baseName(file.name))_filled.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let ok: Bool
        if lock {
            // draw each page with its answers into a new PDF: the boxes become plain text
            ok = redrawPdf(file.document, to: url, password: file.password) { _, _, _ in }
        } else if let password = file.password {
            ok = file.document.write(to: url, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password])
        } else {
            ok = file.document.write(to: url)
        }
        if ok { saved = url } else { message = "Could not save the PDF. Try another folder." }
    }
}
