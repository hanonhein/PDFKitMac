import SwiftUI
import PDFKit

// PDF info, Protect PDF and Remove password (like Android PdfInfoScreen.kt and PasswordScreens.kt)

// The layout every small tool screen shares: intro, content, messages, then the big button
struct ToolPage<Content: View>: View {
    let title: String
    let intro: String
    let actionLabel: String
    let actionEnabled: Bool
    let message: String?
    let saved: URL?
    @Binding var path: [Screen]
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(intro).foregroundStyle(Theme.textSecondary)
                content()
                if let message { Text(message).foregroundStyle(Theme.orange) }
                if let saved {
                    SavedBanner(text: "Saved \(saved.lastPathComponent)", showURL: saved, openURL: saved) { path.append(.viewer($0)) }
                }
                HStack {
                    Spacer()
                    Button(actionLabel, action: action)
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.blue)
                        .disabled(!actionEnabled)
                }
            }
            .padding(24)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle(title)
    }
}

// A titled box of options (like Android OptionSection)
struct OptionSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - PDF info

struct PdfInfoView: View {
    @Binding var path: [Screen]
    @State private var file: PickedPdf?
    @State private var title = ""
    @State private var author = ""
    @State private var subject = ""
    @State private var keywords = ""
    @State private var message: String?
    @State private var saved: URL?

    var body: some View {
        ToolPage(title: "PDF info", intro: "Change the title and author that other apps show for this PDF.",
                 actionLabel: file == nil ? "Choose a PDF first" : "Save info", actionEnabled: file != nil,
                 message: message, saved: saved, path: $path, action: save) {
            PasswordPdfPicker(file: $file, onPick: load)
            if let file {
                OptionSection(title: "Details") {
                    TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                    TextField("Author", text: $author).textFieldStyle(.roundedBorder)
                    TextField("Subject", text: $subject).textFieldStyle(.roundedBorder)
                    TextField("Keywords (separate with commas)", text: $keywords).textFieldStyle(.roundedBorder)
                }
                OptionSection(title: "About this file") {
                    ForEach(facts(file), id: \.0) { fact in
                        HStack(alignment: .top) {
                            Text(fact.0).foregroundStyle(Theme.textSecondary).frame(width: 140, alignment: .leading)
                            Text(fact.1).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private func attribute(_ key: PDFDocumentAttribute) -> Any? { file?.document.documentAttributes?[key] }

    private func load() {
        message = nil
        saved = nil
        title = attribute(.titleAttribute) as? String ?? ""
        author = attribute(.authorAttribute) as? String ?? ""
        subject = attribute(.subjectAttribute) as? String ?? ""
        let words = attribute(.keywordsAttribute)
        keywords = (words as? [String])?.joined(separator: ", ") ?? (words as? String) ?? ""
    }

    // Things you can read but not change
    private func facts(_ file: PickedPdf) -> [(String, String)] {
        let d = file.document
        let dateFormat = DateFormatter()
        dateFormat.dateStyle = .medium
        dateFormat.timeStyle = .short
        var list: [(String, String)] = [("Pages", "\(d.pageCount)")]
        if let url = d.documentURL, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            list.append(("File size", fileSizeText(size)))
        }
        list.append(("PDF version", "\(d.majorVersion).\(d.minorVersion)"))
        if let first = d.page(at: 0) {
            let b = first.bounds(for: .mediaBox)
            list.append(("Page size", String(format: "%.0f × %.0f mm", b.width / 72 * 25.4, b.height / 72 * 25.4)))
        }
        if let date = attribute(.creationDateAttribute) as? Date { list.append(("Created", dateFormat.string(from: date))) }
        if let date = attribute(.modificationDateAttribute) as? Date { list.append(("Changed", dateFormat.string(from: date))) }
        if let app = attribute(.creatorAttribute) as? String, !app.isEmpty { list.append(("Made with", app)) }
        if let app = attribute(.producerAttribute) as? String, !app.isEmpty { list.append(("PDF made by", app)) }
        list.append(("Password", d.isEncrypted ? "Yes" : "No"))
        return list
    }

    private func save() {
        guard let file else { return }
        message = nil
        saved = nil
        var attributes = file.document.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = title.trimmingCharacters(in: .whitespaces)
        attributes[PDFDocumentAttribute.authorAttribute] = author.trimmingCharacters(in: .whitespaces)
        attributes[PDFDocumentAttribute.subjectAttribute] = subject.trimmingCharacters(in: .whitespaces)
        attributes[PDFDocumentAttribute.keywordsAttribute] = keywords.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        file.document.documentAttributes = attributes
        // a PDF with a password keeps it
        switch savePdfWithPanel(file.document, suggestedName: "\(baseName(file.name))_info.pdf", password: file.password) {
        case .saved(let url): saved = url
        case .failed: message = "Could not save the PDF. Try another folder."
        case .cancelled: break
        }
    }
}

// MARK: - Protect PDF

struct ProtectView: View {
    @Binding var path: [Screen]
    @State private var file: PickedPdf?
    @State private var password = ""
    @State private var repeatPassword = ""
    @State private var visible = false
    @State private var message: String?
    @State private var saved: URL?

    private var tooShort: Bool { !password.isEmpty && password.count < 4 }
    private var mismatch: Bool { !repeatPassword.isEmpty && password != repeatPassword }
    private var ready: Bool { file != nil && password.count >= 4 && password == repeatPassword }

    var body: some View {
        ToolPage(title: "Protect PDF", intro: "Anyone who opens the new PDF must type this password.",
                 actionLabel: file == nil ? "Choose a PDF first" : "Add password", actionEnabled: ready,
                 message: message, saved: saved, path: $path, action: save) {
            PasswordPdfPicker(file: $file) { saved = nil; message = nil }
            if file != nil {
                OptionSection(title: "Password") {
                    HStack {
                        Group {
                            if visible {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        Button { visible.toggle() } label: { Image(systemName: visible ? "eye.slash" : "eye") }
                            .buttonStyle(.borderless)
                            .help(visible ? "Hide password" : "Show password")
                    }
                    if tooShort { Text("Use at least 4 characters").font(.caption).foregroundStyle(Theme.orange) }
                    Group {
                        if visible {
                            TextField("Type it again", text: $repeatPassword)
                        } else {
                            SecureField("Type it again", text: $repeatPassword)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    if mismatch { Text("The passwords are not the same").font(.caption).foregroundStyle(Theme.orange) }
                    Label("Remember this password. If you forget it, the PDF can't be opened, not even by this app.",
                          systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func save() {
        guard let file, ready else { return }
        message = nil
        saved = nil
        // a file that had an old password gets the new one
        switch savePdfWithPanel(file.document, suggestedName: "\(baseName(file.name))_protected.pdf", password: password) {
        case .saved(let url): saved = url
        case .failed: message = "Could not save the PDF. Try another folder."
        case .cancelled: break
        }
    }
}

// MARK: - Remove password

struct UnlockView: View {
    @Binding var path: [Screen]
    @State private var file: PickedPdf?
    @State private var message: String?
    @State private var saved: URL?

    private var hasPassword: Bool { file?.document.isEncrypted == true }

    var body: some View {
        ToolPage(title: "Remove password", intro: "Makes a copy that opens without a password. You need to know the current password.",
                 actionLabel: file == nil ? "Choose a PDF first" : (hasPassword ? "Remove password" : "This PDF has no password"),
                 actionEnabled: file != nil && hasPassword,
                 message: message, saved: saved, path: $path, action: save) {
            PasswordPdfPicker(file: $file) { saved = nil; message = nil }
        }
    }

    private func save() {
        guard let file else { return }
        message = nil
        saved = nil
        // Saving the opened PDF would keep its password, so the pages go into a new PDF
        let copy = copyPages(Array(0..<file.document.pageCount), from: file.document)
        copy.documentAttributes = file.document.documentAttributes
        switch savePdfWithPanel(copy, suggestedName: "\(baseName(file.name))_unlocked.pdf") {
        case .saved(let url): saved = url
        case .failed: message = "Could not save the PDF. Try another folder."
        case .cancelled: break
        }
    }
}
