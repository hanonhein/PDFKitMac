import SwiftUI
import PDFKit
import Vision
import CoreText

// Recognize text (OCR): reads the words on scanned pages with Apple's Vision (offline) and adds them
// as invisible text, so the pages look the same but can be searched, selected and copied
// (like Android OcrScreen.kt, which uses Tesseract and English only).

// One word found on a page: its text and its box as a part of the page (0...1, from the bottom-left)
struct OcrWord {
    let text: String
    let box: CGRect
}

// The languages Vision can read on this Mac
func ocrLanguages() -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    return (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
}

// Reads the words in a picture. language nil = find out by itself.
func recognizeWords(in image: CGImage, language: String?) -> [OcrWord] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    if let language {
        request.recognitionLanguages = [language]
    } else {
        request.automaticallyDetectsLanguage = true
    }
    try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

    var words: [OcrWord] = []
    for line in request.results ?? [] {
        guard let best = line.topCandidates(1).first else { continue }
        let text = best.string
        // a box per word (split at spaces, so "due:" keeps its punctuation),
        // so selecting text later highlights the right spot
        var found = false
        var index = text.startIndex
        while index < text.endIndex {
            guard let start = text[index...].firstIndex(where: { !$0.isWhitespace }) else { break }
            let end = text[start...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            if let box = try? best.boundingBox(for: start..<end)?.boundingBox {
                words.append(OcrWord(text: String(text[start..<end]), box: box))
                found = true
            }
            index = end
        }
        if !found { words.append(OcrWord(text: text, box: line.boundingBox)) }
    }
    return words
}

// Writes words as invisible text: each word stretched to fill its box
func drawInvisibleWords(_ words: [OcrWord], in page: CGRect, context: CGContext) {
    context.saveGState()
    context.setTextDrawingMode(.invisible)
    for word in words {
        let box = CGRect(x: page.minX + word.box.minX * page.width, y: page.minY + word.box.minY * page.height,
                         width: word.box.width * page.width, height: word.box.height * page.height)
        guard box.width > 0, box.height > 0 else { continue }
        let font = CTFontCreateWithName("Helvetica" as CFString, box.height * 0.9, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: word.text, attributes: [.font: font]))
        let natural = CTLineGetTypographicBounds(line, nil, nil, nil)
        guard natural > 0 else { continue }
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: box.minX, y: box.minY + box.height * 0.2)
        context.scaleBy(x: box.width / CGFloat(natural), y: 1)   // as wide as the word on the picture
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
    context.restoreGState()
}

struct OcrView: View {
    @Binding var path: [Screen]
    @State private var file: PickedPdf?
    @State private var language = "auto"
    @State private var busy: String?
    @State private var message: String?
    @State private var info: String?
    @State private var saved: URL?
    private let languages = ocrLanguages()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Reads the words on scanned pages so you can search, select and copy them. The pages look the same.")
                    .foregroundStyle(Theme.textSecondary)
                Text("Works offline with Apple's text recognition. It takes a second or two per page. Pages that already have text are left as they are.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                PasswordPdfPicker(file: $file) { saved = nil; message = nil; info = nil }
                if file != nil {
                    OptionSection(title: "Language of the text") {
                        Picker("", selection: $language) {
                            Text("Automatic").tag("auto")
                            Divider()
                            ForEach(languages, id: \.self) { code in
                                Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
                    }
                }
                if let info { Label(info, systemImage: "text.viewfinder").foregroundStyle(Theme.teal) }
                if let message { Text(message).foregroundStyle(Theme.orange) }
                if let saved {
                    SavedBanner(text: "Saved \(saved.lastPathComponent)", showURL: saved, openURL: saved) { path.append(.viewer($0)) }
                }
                HStack {
                    if let busy {
                        ProgressView().controlSize(.small)
                        Text(busy).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button(file == nil ? "Choose a PDF first" : "Recognize text", action: run)
                        .controlSize(.large).buttonStyle(.borderedProminent).tint(Theme.blue)
                        .disabled(file == nil || busy != nil)
                }
            }
            .padding(24)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("Recognize text (OCR)")
    }

    private func run() {
        guard let file else { return }
        message = nil
        info = nil
        saved = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(baseName(file.name))_ocr.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let document = file.document
        let chosen = language == "auto" ? nil : language
        busy = "Starting…"
        Task { @MainActor in
            var wordsPerPage: [Int: [OcrWord]] = [:]
            var skipped = 0
            for i in 0..<document.pageCount {
                guard let page = document.page(at: i) else { continue }
                // a page with real text doesn't need reading (it would get the words twice)
                if (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count > 20 { skipped += 1; continue }
                busy = "Reading page \(i + 1) of \(document.pageCount)…"
                // about 300 dots per inch on A4 width: what text recognition likes best (like Android)
                guard let image = renderPage(page, width: 2400) else { continue }
                wordsPerPage[i] = await Task.detached { recognizeWords(in: image, language: chosen) }.value
            }
            busy = "Saving…"
            await Task.yield()
            let ok = redrawPdf(document, to: url, password: file.password) { i, context, page in
                if let words = wordsPerPage[i] { drawInvisibleWords(words, in: page, context: context) }
            }
            busy = nil
            let count = wordsPerPage.values.reduce(0) { $0 + $1.count }
            if !ok {
                message = "Could not save the PDF. Try another folder."
                return
            }
            saved = url
            if skipped == document.pageCount {
                info = "All pages already had text, so nothing needed reading."
            } else if count == 0 {
                info = "No words were found. The pages may be too blurry, or in a language Apple's text recognition doesn't know."
            } else {
                info = "\(count) words found. You can now search and copy the text."
                    + (skipped > 0 ? " \(skipped) page\(skipped == 1 ? "" : "s") already had text." : "")
            }
        }
    }
}
