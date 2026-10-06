import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - What you can convert (same list as Android)

enum ConvertFrom: String, CaseIterable, Identifiable {
    case pdf, images, word, excel, powerpoint, rtf, text
    var id: Self { self }

    var label: String {
        switch self {
        case .pdf: "PDF"
        case .images: "Images"
        case .word: "Word"
        case .excel: "Excel"
        case .powerpoint: "PowerPoint"
        case .rtf: "RTF"
        case .text: "Text"
        }
    }

    var icon: String {
        switch self {
        case .pdf: "doc.richtext"
        case .images: "photo"
        case .word: "doc.text"
        case .excel: "tablecells"
        case .powerpoint: "rectangle.on.rectangle"
        case .rtf: "doc.plaintext"
        case .text: "textformat"
        }
    }

    var isReady: Bool { [.pdf, .images, .word, .excel, .rtf, .text].contains(self) }
}

enum PdfTarget: String, CaseIterable, Identifiable {
    case word, excel, powerpoint, jpg, png, rtf, txt, html, xml
    var id: Self { self }

    var label: String {
        switch self {
        case .word: "Word"
        case .excel: "Excel"
        case .powerpoint: "PowerPoint"
        case .jpg: "JPG"
        case .png: "PNG"
        case .rtf: "RTF"
        case .txt: "Text"
        case .html: "HTML"
        case .xml: "XML"
        }
    }

    var icon: String {
        switch self {
        case .word: "doc.text"
        case .excel: "tablecells"
        case .powerpoint: "rectangle.on.rectangle"
        case .jpg, .png: "photo"
        case .rtf, .txt: "doc.plaintext"
        case .html: "globe"
        case .xml: "chevron.left.forwardslash.chevron.right"
        }
    }

    var description: String {
        switch self {
        case .word: "Makes a Word file you can edit. The words and paragraphs are kept; the layout, pictures and fonts may change."
        case .excel: "Each page becomes a sheet and each line a row. Columns are found from the spacing, so tables work best."
        case .powerpoint: "Each page becomes one slide, looking exactly like the page (as a picture)."
        case .jpg: "Every page becomes a picture. JPG files are small, good for sharing."
        case .png: "Every page becomes a picture. PNG pictures are sharper, but bigger files."
        case .rtf: "Rich Text: opens in TextEdit, Word and most text apps. The words and paragraphs are kept."
        case .txt: "Only the words, as a plain .txt file."
        case .html: "A web page with the words of every page. Opens in any browser."
        case .xml: "The words in a structured XML file (pages and paragraphs), for other programs."
        }
    }

    var isReady: Bool { true }

    var fileExtension: String {
        switch self {
        case .word: "docx"
        case .excel: "xlsx"
        case .powerpoint: "pptx"
        default: rawValue
        }
    }
}

// MARK: - Converting

// Draws one page as a picture, `width` pixels wide, on white (like Android: 1600 wide)
func renderPage(_ page: PDFPage, width: Int) -> CGImage? {
    let box = page.bounds(for: .cropBox)
    let turned = page.rotation % 180 != 0
    let seen = turned ? CGSize(width: box.height, height: box.width) : box.size
    let scale = CGFloat(width) / seen.width
    let height = max(Int((seen.height * scale).rounded()), 1)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.setFillColor(.white)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .cropBox, to: context)   // also draws anything added to the page, turned the right way
    return context.makeImage()
}

func imageData(_ image: CGImage, png: Bool) -> Data? {
    let rep = NSBitmapImageRep(cgImage: image)
    return png ? rep.representation(using: .png, properties: [:])
               : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
}

// All the words of the PDF, page by page
func pdfText(_ document: PDFDocument) -> String {
    (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .joined(separator: "\n\n")
}

// Each picture becomes one A4-wide page, as tall as the picture needs (like Android)
func imagesToPdf(_ images: [NSImage], to url: URL) -> Bool {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data),
          let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { return false }
    for image in images {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), cg.width > 0 else { continue }
        let width: CGFloat = 595
        var box = CGRect(x: 0, y: 0, width: width, height: max((width * CGFloat(cg.height) / CGFloat(cg.width)).rounded(), 1))
        let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
        context.interpolationQuality = .high
        context.draw(cg, in: box)
        context.endPDFPage()
    }
    context.closePDF()
    return (try? (data as Data).write(to: url)) != nil
}

// MARK: - The Convert screen

struct ConvertView: View {
    @Binding var path: [Screen]
    @State private var from = ConvertFrom.pdf
    @State private var target = PdfTarget.jpg

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    FormatMenu(title: "From", label: from.label, icon: from.icon) {
                        ForEach(ConvertFrom.allCases) { option in
                            Button(option.isReady ? option.label : "\(option.label) (coming soon)") { from = option }
                                .disabled(!option.isReady)
                        }
                    }
                    Image(systemName: "arrow.right").foregroundStyle(Theme.textSecondary)
                    if from == .pdf {
                        FormatMenu(title: "To", label: target.label, icon: target.icon) {
                            ForEach(PdfTarget.allCases) { option in
                                Button(option.isReady ? option.label : "\(option.label) (coming soon)") { target = option }
                                    .disabled(!option.isReady)
                            }
                        }
                    } else {
                        FormatMenu(title: "To", label: "PDF", icon: "doc.richtext") { EmptyView() }
                    }
                }

                switch from {
                case .pdf: PdfToFormat(target: target, path: $path)
                case .images: ImagesToPdf(path: $path)
                case .text: TextToPdf(path: $path)
                case .rtf, .word, .excel: FileToPdf(kind: from, path: $path).id(from)
                default: EmptyView()
                }
            }
            .padding(24)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("Convert")
    }
}

// A "From" or "To" box that opens a menu
struct FormatMenu<Items: View>: View {
    let title: String
    let label: String
    let icon: String
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 10) {
                IconBadge(icon: icon, color: .teal, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption).foregroundStyle(Theme.textSecondary)
                    Text(label).font(.headline).foregroundStyle(Theme.text)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            .padding(12)
            .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.outlineVariant))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
    }
}

// PDF -> JPG / PNG / Text
private struct PdfToFormat: View {
    let target: PdfTarget
    @Binding var path: [Screen]
    @State private var file: PickedPdf?
    @State private var showPicker = false
    @State private var busy: String?
    @State private var message: String?
    @State private var saved: (text: String, url: URL, open: URL?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(target.description).foregroundStyle(Theme.textSecondary)

            HStack(spacing: 12) {
                IconBadge(icon: "doc.fill", color: .teal, size: 40)
                if let file {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).lineLimit(1)
                        Text(file.document.pageCount == 1 ? "1 page" : "\(file.document.pageCount) pages")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Text("No PDF chosen. Click the button or drop a file here.").foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button(file == nil ? "Choose PDF" : "Change") { showPicker = true }
            }
            .padding(14)
            .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 20))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
                pick(url)
                return true
            }

            if let message { Text(message).foregroundStyle(Theme.orange) }
            if let saved {
                SavedBanner(text: saved.text, showURL: saved.url, openURL: saved.open) { NSWorkspace.shared.open($0) }
            }

            HStack {
                if let busy {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button(file == nil ? "Choose a PDF first" : "Convert to \(target.label)") { convert() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.blue)
                    .disabled(file == nil || busy != nil)
            }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { pick(url) }
        }
        .onChange(of: target) { saved = nil; message = nil }
    }

    // PDF -> Excel (one sheet per page) or PowerPoint (one slide per page, as a picture)
    private func makeOfficeFile(_ file: PickedPdf, base: String) {
        let document = file.document
        let isExcel = target == .excel
        if isExcel && readPages(document).allSatisfy({ $0.paragraphs().isEmpty }) {
            message = "No words were found. If this is a scanned PDF, use \"Recognize text (OCR)\" first."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: target.fileExtension) ?? .data]
        panel.nameFieldStringValue = "\(base).\(target.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        busy = "Converting…"
        Task { @MainActor in
            let ok: Bool
            if isExcel {
                let sheets = (0..<document.pageCount).compactMap { document.page(at: $0) }.map(pageRows)
                ok = writeXlsx(sheets, to: url)
            } else {
                let size = slideSize(for: document)
                var slides: [Data] = []
                for i in 0..<document.pageCount {
                    busy = "Making slide \(i + 1) of \(document.pageCount)…"
                    await Task.yield()   // lets the screen show the progress
                    if let page = document.page(at: i), let image = renderPage(page, width: size.pictureWidth),
                       let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.88]) {
                        slides.append(jpeg)
                    }
                }
                ok = writePptx(slides, slideWidth: size.width, slideHeight: size.height, to: url)
            }
            busy = nil
            if ok {
                saved = ("Saved \(url.lastPathComponent)", url, url)
            } else {
                message = "Could not save the file. Try another folder."
            }
        }
    }

    private func pick(_ url: URL) {
        message = nil
        saved = nil
        switch loadPickedPdf(url) {
        case .success(let picked): file = picked
        case .failure(let error): message = error.message
        }
    }

    private func convert() {
        guard let file else { return }
        message = nil
        saved = nil
        let base = baseName(file.name)

        if target == .excel || target == .powerpoint {
            makeOfficeFile(file, base: base)
            return
        }

        if target != .jpg && target != .png {
            // Word-based files: the words of every page
            let pages = readPages(file.document)
            if pages.allSatisfy({ $0.paragraphs().isEmpty }) {
                message = "No words were found. If this is a scanned PDF, use \"Recognize text (OCR)\" first."
                return
            }
            if target == .word {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
                panel.nameFieldStringValue = "\(base).docx"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                if writeDocx(pagesToWord(pages), to: url) {
                    saved = ("Saved \(url.lastPathComponent)", url, url)
                } else {
                    message = "Could not save the file. Try another folder."
                }
                return
            }
            let content: String
            switch target {
            case .rtf: content = pagesToRtf(pages)
            case .html: content = pagesToHtml(pages, title: base)
            case .xml: content = pagesToXml(pages, title: base)
            default: content = pdfText(file.document)
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: target.fileExtension) ?? .data]
            panel.nameFieldStringValue = "\(base).\(target.fileExtension)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                saved = ("Saved \(url.lastPathComponent)", url, url)
            } catch {
                message = "Could not save the file. Try another folder."
            }
            return
        }

        // JPG / PNG: one picture per page, into a folder you choose
        let png = target == .png
        let ext = png ? "png" : "jpg"
        let count = file.document.pageCount
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save here"
        panel.message = "Choose a folder for the \(count) picture\(count == 1 ? "" : "s")"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let document = file.document
        busy = "Converting…"
        Task { @MainActor in
            var urls: [URL] = []
            for i in 0..<count {
                busy = "Converting page \(i + 1) of \(count)…"
                await Task.yield()   // lets the screen show the progress
                guard let page = document.page(at: i), let image = renderPage(page, width: 1600),
                      let data = imageData(image, png: png) else { continue }
                let url = freeFileURL(in: folder, name: "\(base)_page\(i + 1)", ext: ext)
                if (try? data.write(to: url)) != nil { urls.append(url) }
            }
            busy = nil
            if urls.count == count, let first = urls.first {
                saved = ("Saved \(count) picture\(count == 1 ? "" : "s") in \(folder.lastPathComponent)", first, count == 1 ? first : nil)
            } else {
                message = "Could only save \(urls.count) of \(count) pictures. Try another folder."
            }
        }
    }
}

// Images -> PDF: each picture becomes one page, in this order
private struct ImagesToPdf: View {
    @Binding var path: [Screen]
    @State private var images: [(id: UUID, name: String, image: NSImage)] = []
    @State private var showPicker = false
    @State private var message: String?
    @State private var savedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Make a PDF from pictures (JPG, PNG, HEIC and more). Each picture becomes one page, in this order. Drag to change the order, or drop pictures here from Finder.")
                .foregroundStyle(Theme.textSecondary)

            if images.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 36)).foregroundStyle(Theme.teal)
                    Text("No pictures yet").font(.headline)
                    Text("Click \"Add pictures\" or drop files here.").foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
                .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 20))
            } else {
                Text(images.count == 1 ? "1 picture" : "\(images.count) pictures").font(.subheadline.weight(.semibold))
                List {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 12) {
                            Text("\(index + 1)").font(.caption).foregroundStyle(Theme.textSecondary).frame(width: 22)
                            Image(nsImage: item.image).resizable().scaledToFit().frame(width: 48, height: 48)
                            Text(item.name).lineLimit(1)
                            Spacer()
                            Button { images.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                                .help("Remove")
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { images.move(fromOffsets: $0, toOffset: $1) }
                }
                .scrollContentBackground(.hidden)
                .frame(minHeight: 260)
                .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 20))
            }

            if let message { Text(message).foregroundStyle(Theme.orange) }
            if let savedURL {
                SavedBanner(text: "Saved \(savedURL.lastPathComponent)", showURL: savedURL, openURL: savedURL) {
                    path.append(.viewer($0))
                }
            }

            HStack {
                Button { showPicker = true } label: { Label("Add pictures", systemImage: "plus") }
                    .controlSize(.large)
                Spacer()
                Button("Create PDF") { create() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.blue)
                    .disabled(images.isEmpty)
            }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        }
    }

    private func add(_ urls: [URL]) {
        message = nil
        savedURL = nil
        var skipped: [String] = []
        for url in urls {
            // Same size limit as Android (2000 pixels), so the PDF stays a sensible size
            if let image = loadPicture(from: url, maxPixels: 2000) {
                images.append((UUID(), url.lastPathComponent, image))
            } else {
                skipped.append(url.lastPathComponent)
            }
        }
        if !skipped.isEmpty { message = "Not a picture: " + skipped.joined(separator: ", ") }
    }

    private func create() {
        message = nil
        savedURL = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = images.count == 1 ? "\(baseName(images[0].name)).pdf" : "images.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if imagesToPdf(images.map(\.image), to: url) {
            savedURL = url
        } else {
            message = "Could not save the PDF. Try another folder."
        }
    }
}

// Text -> PDF: type or paste text, or open a .txt file
private struct TextToPdf: View {
    @Binding var path: [Screen]
    @State private var text = ""
    @State private var title = "text"
    @State private var showPicker = false
    @State private var message: String?
    @State private var savedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Type or paste text, or open a .txt file. All languages are supported.")
                .foregroundStyle(Theme.textSecondary)
            Button { showPicker = true } label: { Label("Open a text file", systemImage: "doc.text") }
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 260)
                .padding(6)
                .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.outlineVariant))

            if let message { Text(message).foregroundStyle(Theme.orange) }
            if let savedURL {
                SavedBanner(text: "Saved \(savedURL.lastPathComponent)", showURL: savedURL, openURL: savedURL) {
                    path.append(.viewer($0))
                }
            }
            HStack {
                Spacer()
                Button("Create PDF") { create() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.blue)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.plainText]) { result in
            guard case .success(let url) = result else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            // Most text files are UTF-8; older ones are often Latin-1
            if let read = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) {
                text = read
                title = baseName(url.lastPathComponent)
                message = nil
            } else {
                message = "This file could not be read."
            }
        }
    }

    private func create() {
        message = nil
        savedURL = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(title.isEmpty ? "text" : title).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if attributedTextToPdf(plainTextStyle(text), to: url) {
            savedURL = url
        } else {
            message = "Could not save the PDF. Try another folder."
        }
    }
}

// A file (RTF now; Word, Excel, PowerPoint later) -> PDF
private struct FileToPdf: View {
    let kind: ConvertFrom
    @Binding var path: [Screen]
    @State private var file: URL?
    @State private var showPicker = false
    @State private var message: String?
    @State private var savedURL: URL?

    private var description: String {
        switch kind {
        case .rtf: "Turns a Rich Text file (.rtf) into a PDF. Paragraphs, bold, italic and sizes are kept."
        case .word: "Turns a Word file (.docx or .doc) into a PDF. Headings, bold and italic, lists and page breaks are kept."
        case .excel: "Turns an Excel file (.xlsx) into a PDF. Every sheet becomes a table; wide sheets are fitted on sideways pages."
        default: ""
        }
    }

    private var types: [UTType] {
        switch kind {
        case .rtf: [.rtf]
        case .word: [UTType(filenameExtension: "docx"), UTType(filenameExtension: "doc")].compactMap { $0 }
        case .excel: [UTType(filenameExtension: "xlsx")].compactMap { $0 }
        default: []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(description).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 12) {
                IconBadge(icon: kind.icon, color: .teal, size: 40)
                Text(file?.lastPathComponent ?? "No \(kind.label) file chosen.")
                    .foregroundStyle(file == nil ? Theme.textSecondary : Theme.text)
                    .lineLimit(1)
                Spacer()
                Button(file == nil ? "Choose \(kind.label) file" : "Change") { showPicker = true }
            }
            .padding(14)
            .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 20))

            if let message { Text(message).foregroundStyle(Theme.orange) }
            if let savedURL {
                SavedBanner(text: "Saved \(savedURL.lastPathComponent)", showURL: savedURL, openURL: savedURL) {
                    path.append(.viewer($0))
                }
            }
            HStack {
                Spacer()
                Button("Create PDF") { create() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.blue)
                    .disabled(file == nil)
            }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: types) { result in
            if case .success(let url) = result { file = url; message = nil; savedURL = nil }
        }
    }

    private func create() {
        guard let file else { return }
        message = nil
        savedURL = nil
        // Read first, so problems show before asking where to save
        var sheets: [Sheet] = []
        var content: NSAttributedString?
        if kind == .excel {
            do { sheets = try readExcel(file) } catch {
                message = (error as? OfficeError)?.message ?? "This file could not be read."
                return
            }
        } else {
            content = readStyledFile(file)
            if content == nil {
                message = "This file could not be read."
                return
            }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(baseName(file.lastPathComponent)).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ok = kind == .excel ? excelToPdf(sheets, to: url) : attributedTextToPdf(content!, to: url)
        if ok {
            savedURL = url
        } else {
            message = "Could not save the PDF. Try another folder."
        }
    }
}
