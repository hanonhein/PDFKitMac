import SwiftUI
import PDFKit

// Watermark, Page numbers, Compress and Grayscale (like the Android tools of the same names)

// MARK: - Redrawing pages with something on top

// Draws every page into a new PDF (turned pages come out the right way up), with extra drawing
// below (`paper`) or on top (`overlay`). Both get the page box as seen, counting up from the bottom-left.
// Text stays real text. A password the PDF had is kept.
func redrawPdf(_ document: PDFDocument, to url: URL, password: String?,
               paper: ((CGContext, CGRect) -> Void)? = nil,
               overlay: (Int, CGContext, CGRect) -> Void) -> Bool {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data),
          let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { return false }
    for i in 0..<document.pageCount {
        guard let page = document.page(at: i) else { continue }
        let box = page.bounds(for: .cropBox)
        var seen = CGRect(origin: .zero, size: page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width))
        let boxData = Data(bytes: &seen, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
        paper?(context, seen)
        page.draw(with: .cropBox, to: context)
        context.saveGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        overlay(i, context, seen)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
        context.endPDFPage()
    }
    context.closePDF()
    guard let made = PDFDocument(data: data as Data) else { return false }
    made.documentAttributes = document.documentAttributes
    if let password {
        return made.write(to: url, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password])
    }
    return made.write(to: url)
}

// Asks where to save, then runs `make` with the place chosen
private func saveWithPanel(_ name: String, make: (URL) -> Bool) -> SaveOutcome {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue = name
    guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
    return make(url) ? .saved(url) : .failed
}

private func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// MARK: - Watermark

private let watermarkColors: [NSColor] = [0x9E9E9E, 0xD32F2F, 0x1976D2, 0x388E3C, 0x000000].map(rgb)

func drawTextWatermark(_ text: String, color: NSColor, opacity: CGFloat, diagonal: Bool, in page: CGRect, context: CGContext) {
    // Measure at size 100, then fit the text along the diagonal (or across the page),
    // but never taller than about a third of the page, so it also fits wide pages
    let font = { (size: CGFloat) in NSFont.systemFont(ofSize: size, weight: .bold) }
    let measured100 = NSAttributedString(string: text, attributes: [.font: font(100)]).size()
    let room = diagonal ? hypot(page.width, page.height) * 0.75 : page.width * 0.85
    let size = min(100 * room / max(measured100.width, 1), 100 * min(page.width, page.height) * 0.3 / max(measured100.height, 1))
    let string = NSAttributedString(string: text, attributes: [.font: font(size), .foregroundColor: color.withAlphaComponent(opacity)])
    let measured = string.size()
    context.translateBy(x: page.midX, y: page.midY)
    if diagonal { context.rotate(by: atan2(page.height, page.width)) }   // from bottom-left up to top-right
    string.draw(at: CGPoint(x: -measured.width / 2, y: -measured.height / 2))
}

func drawPictureWatermark(_ image: NSImage, widthPart: CGFloat, opacity: CGFloat, in page: CGRect) {
    let w = page.width * widthPart
    let h = w * image.size.height / max(image.size.width, 1)
    image.draw(in: CGRect(x: page.midX - w / 2, y: page.midY - h / 2, width: w, height: h),
               from: .zero, operation: .sourceOver, fraction: opacity)
}

struct WatermarkView: View {
    @Binding var path: [Screen]
    @State private var file: PickedPdf?
    @State private var useImage = false
    @State private var text = "CONFIDENTIAL"
    @State private var colorIndex = 0
    @State private var opacity = 0.25
    @State private var diagonal = true
    @State private var picture: NSImage?
    @State private var pictureSize = 0.5
    @State private var showPicturePicker = false
    @State private var message: String?
    @State private var saved: URL?

    private var ready: Bool {
        file != nil && (useImage ? picture != nil : !text.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        ToolPage(title: "Watermark", intro: "Adds see-through text or a logo to every page.",
                 actionLabel: file == nil ? "Choose a PDF first" : "Add watermark", actionEnabled: ready,
                 message: message, saved: saved, path: $path, action: save) {
            PasswordPdfPicker(file: $file) { saved = nil; message = nil }
            if file != nil {
                Picker("", selection: $useImage) {
                    Text("Text").tag(false)
                    Text("Picture").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)

                if useImage {
                    OptionSection(title: "Picture") {
                        HStack(spacing: 12) {
                            if let picture {
                                Image(nsImage: picture).resizable().scaledToFit().frame(width: 60, height: 60)
                            }
                            Button(picture == nil ? "Choose picture" : "Change picture") { showPicturePicker = true }
                        }
                        Text("Size: \(Int(pictureSize * 100))% of page width").font(.subheadline)
                        Slider(value: $pictureSize, in: 0.1...1)
                    }
                } else {
                    OptionSection(title: "Text") {
                        TextField("Watermark text", text: $text).textFieldStyle(.roundedBorder)
                        HStack(spacing: 10) {
                            ForEach(watermarkColors.indices, id: \.self) { i in
                                Circle()
                                    .fill(Color(nsColor: watermarkColors[i]))
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().stroke(Theme.blue, lineWidth: colorIndex == i ? 3 : 0).padding(-4))
                                    .onTapGesture { colorIndex = i }
                            }
                            Spacer()
                            Toggle("Diagonal", isOn: $diagonal)
                        }
                    }
                }
                OptionSection(title: "See-through") {
                    Text("\(Int(opacity * 100))% visible").font(.subheadline)
                    Slider(value: $opacity, in: 0.05...1)
                }
            }
        }
        .fileImporter(isPresented: $showPicturePicker, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { picture = loadPicture(from: url) }
        }
    }

    private func save() {
        guard let file, ready else { return }
        message = nil
        saved = nil
        let words = text.trimmingCharacters(in: .whitespaces)
        let color = watermarkColors[colorIndex]
        let outcome = saveWithPanel("\(baseName(file.name))_watermark.pdf") { url in
            redrawPdf(file.document, to: url, password: file.password) { _, context, page in
                if useImage, let picture {
                    drawPictureWatermark(picture, widthPart: pictureSize, opacity: opacity, in: page)
                } else {
                    drawTextWatermark(words, color: color, opacity: opacity, diagonal: diagonal, in: page, context: context)
                }
            }
        }
        switch outcome {
        case .saved(let url): saved = url
        case .failed: message = "Could not save the PDF. Try another folder."
        case .cancelled: break
        }
    }
}

// MARK: - Page numbers

enum NumberPosition: String, CaseIterable, Identifiable {
    case bottomCenter = "Bottom center", bottomRight = "Bottom right", bottomLeft = "Bottom left"
    case topCenter = "Top center", topRight = "Top right"
    var id: Self { self }
}

enum NumberStyle: String, CaseIterable, Identifiable {
    case number = "1, 2, 3", pageOf = "Page 1 of 10", dash = "- 1 -"
    var id: Self { self }

    func text(_ n: Int, of total: Int) -> String {
        switch self {
        case .number: "\(n)"
        case .pageOf: "Page \(n) of \(total)"
        case .dash: "- \(n) -"
        }
    }
}

// Writes the number on one page, upright as the page is seen (same sizes as Android)
func drawPageNumber(_ text: String, at position: NumberPosition, in page: CGRect) {
    let size = min(max(page.width * 0.022, 8), 14)
    let string = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor(white: 0.2, alpha: 1)
    ])
    let width = string.size().width
    let margin = size * 2.2
    let x: CGFloat
    switch position {
    case .bottomCenter, .topCenter: x = (page.width - width) / 2
    case .bottomRight, .topRight: x = page.width - margin - width
    case .bottomLeft: x = margin
    }
    let font = NSFont.systemFont(ofSize: size)
    let isTop = position == .topCenter || position == .topRight
    let baseline = isTop ? page.height - margin : margin - size
    string.draw(at: CGPoint(x: x, y: baseline + font.descender))
}

struct PageNumbersView: View {
    @Binding var path: [Screen]
    @State private var file: PickedPdf?
    @State private var position = NumberPosition.bottomCenter
    @State private var style = NumberStyle.number
    @State private var message: String?
    @State private var saved: URL?

    var body: some View {
        ToolPage(title: "Page numbers", intro: "Adds a number to every page. Your original file stays unchanged.",
                 actionLabel: file == nil ? "Choose a PDF first" : "Add page numbers", actionEnabled: file != nil,
                 message: message, saved: saved, path: $path, action: save) {
            PasswordPdfPicker(file: $file) { saved = nil; message = nil }
            if file != nil {
                OptionSection(title: "Position") {
                    Picker("", selection: $position) {
                        ForEach(NumberPosition.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                OptionSection(title: "Style") {
                    Picker("", selection: $style) {
                        ForEach(NumberStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }
        }
    }

    private func save() {
        guard let file else { return }
        message = nil
        saved = nil
        let total = file.document.pageCount
        let outcome = saveWithPanel("\(baseName(file.name))_numbered.pdf") { url in
            redrawPdf(file.document, to: url, password: file.password) { i, _, page in
                drawPageNumber(style.text(i + 1, of: total), at: position, in: page)
            }
        }
        switch outcome {
        case .saved(let url): saved = url
        case .failed: message = "Could not save the PDF. Try another folder."
        case .cancelled: break
        }
    }
}

// MARK: - Compress

enum CompressLevel: String, CaseIterable, Identifiable {
    case low = "Low", medium = "Medium", high = "High"
    var id: Self { self }

    var description: String {
        switch self {
        case .low: "Best quality, a bit smaller"
        case .medium: "Good quality, smaller"
        case .high: "Smallest file, lower quality"
        }
    }

    // Apple's own picture options: save as JPEG, and/or make pictures screen-sized
    var options: [PDFDocumentWriteOption: Any] {
        switch self {
        case .low: [.saveImagesAsJPEGOption: true]
        case .medium: [.optimizeImagesForScreenOption: true]
        case .high: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        }
    }
}

struct CompressView: View {
    @Binding var path: [Screen]
    @State private var file: PickedPdf?
    @State private var level = CompressLevel.medium
    @State private var message: String?
    @State private var saved: URL?
    @State private var result: String?

    var body: some View {
        ToolPage(title: "Compress PDF",
                 intro: "Makes the photos inside the PDF smaller. Text stays sharp. Works best for PDFs with many photos or scans.",
                 actionLabel: file == nil ? "Choose a PDF first" : "Compress", actionEnabled: file != nil,
                 message: message, saved: saved, path: $path, action: save) {
            PasswordPdfPicker(file: $file) { saved = nil; message = nil; result = nil }
            if file != nil {
                OptionSection(title: "Compression level") {
                    Picker("", selection: $level) {
                        ForEach(CompressLevel.allCases) { level in
                            VStack(alignment: .leading) {
                                Text(level.rawValue)
                                Text(level.description).font(.subheadline).foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.vertical, 2)
                            .tag(level)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }
            if let result {
                Label(result, systemImage: "arrow.down.right.and.arrow.up.left").foregroundStyle(Theme.teal)
            }
        }
    }

    private func size(_ url: URL?) -> Int? {
        url.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
    }

    private func save() {
        guard let file else { return }
        message = nil
        saved = nil
        result = nil
        let before = size(file.document.documentURL)
        let outcome = saveWithPanel("\(baseName(file.name))_compressed.pdf") { url in
            var options = level.options
            if let password = file.password {
                options[.userPasswordOption] = password
                options[.ownerPasswordOption] = password
            }
            return file.document.write(to: url, withOptions: options)
        }
        switch outcome {
        case .saved(let url):
            saved = url
            if let before, let after = size(url) {
                if after < before {
                    let percent = Int((1 - Double(after) / Double(before)) * 100)
                    result = "\(fileSizeText(before)) → \(fileSizeText(after)) (\(percent)% smaller)"
                } else {
                    result = "\(fileSizeText(before)) → \(fileSizeText(after)). This PDF has few photos, so it could not get smaller."
                }
            }
        case .failed: message = "Could not save the PDF. Try another folder."
        case .cancelled: break
        }
    }
}

// MARK: - Grayscale

struct GrayscaleView: View {
    @Binding var path: [Screen]
    @State private var file: PickedPdf?
    @State private var message: String?
    @State private var saved: URL?

    var body: some View {
        ToolPage(title: "Grayscale", intro: "Turns every page black and white, for cheaper printing.",
                 actionLabel: file == nil ? "Choose a PDF first" : "Make black & white", actionEnabled: file != nil,
                 message: message, saved: saved, path: $path, action: save) {
            PasswordPdfPicker(file: $file) { saved = nil; message = nil }
        }
    }

    private func save() {
        guard let file else { return }
        message = nil
        saved = nil
        let outcome = saveWithPanel("\(baseName(file.name))_grayscale.pdf") { url in
            redrawPdf(file.document, to: url, password: file.password,
                      paper: { context, page in
                          context.setFillColor(gray: 1, alpha: 1)   // white paper, so empty parts stay white
                          context.fill(page)
                      },
                      overlay: { _, context, page in
                          // grey on top in "saturation" mode takes all colour away; text stays real text
                          context.setBlendMode(.saturation)
                          context.setFillColor(gray: 0.5, alpha: 1)
                          context.fill(page)
                      })
        }
        switch outcome {
        case .saved(let url): saved = url
        case .failed: message = "Could not save the PDF. Try another folder."
        case .cancelled: break
        }
    }
}
