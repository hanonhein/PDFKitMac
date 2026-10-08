import SwiftUI
import PDFKit
import CoreImage
import UniformTypeIdentifiers

// Scan document: add photos of paper, then save them as a PDF, optionally black & white and searchable (like Android ScanScreen.kt).

// MARK: - Black & white

// "Document" look: white paper, dark writing, no colour, no shadows.
// Apple's Document Enhancer whitens the paper; then the colour is taken away.
func documentLook(_ image: CGImage) -> CGImage {
    var output = CIImage(cgImage: image)
    if let enhance = CIFilter(name: "CIDocumentEnhancer") {
        enhance.setValue(output, forKey: kCIInputImageKey)
        enhance.setValue(1.0, forKey: "inputAmount")
        if let enhanced = enhance.outputImage { output = enhanced }
    }
    if let gray = CIFilter(name: "CIColorControls") {
        gray.setValue(output, forKey: kCIInputImageKey)
        gray.setValue(0, forKey: kCIInputSaturationKey)
        gray.setValue(1.1, forKey: kCIInputContrastKey)
        if let result = gray.outputImage { output = result }
    }
    return CIContext().createCGImage(output, from: CGRect(x: 0, y: 0, width: image.width, height: image.height)) ?? image
}

// MARK: - The Scan screen

struct ScannedPage: Identifiable {
    let id = UUID()
    let image: CGImage
}

struct ScanView: View {
    @Binding var path: [Screen]
    @State private var pages: [ScannedPage] = []
    @State private var blackAndWhite = true
    @State private var searchable = true
    @State private var showPicturePicker = false
    @State private var busy: String?
    @State private var message: String?
    @State private var saved: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Turn photos of paper into a PDF. Make them black and white like a scanner, and make the text searchable.")
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 12) {
                    Button { showPicturePicker = true } label: { Label("From pictures", systemImage: "photo.on.rectangle") }
                        .controlSize(.large)
                }

                if !pages.isEmpty {
                    Text(pages.count == 1 ? "1 page" : "\(pages.count) pages").font(.subheadline.weight(.semibold))
                    List {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                            HStack(spacing: 12) {
                                Text("\(index + 1)").font(.caption).foregroundStyle(Theme.textSecondary).frame(width: 22)
                                Image(nsImage: NSImage(cgImage: blackAndWhite ? documentLook(page.image) : page.image,
                                                       size: CGSize(width: page.image.width, height: page.image.height)))
                                    .resizable().scaledToFit().frame(width: 60, height: 80)
                                Text("Page \(index + 1)")
                                Spacer()
                                Button { pages.removeAll { $0.id == page.id } } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless).help("Remove this page")
                            }
                            .padding(.vertical, 2)
                        }
                        .onMove { pages.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 280)
                    .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 20))

                    OptionSection(title: "Options") {
                        Picker("", selection: $blackAndWhite) {
                            Text("Document (B&W)").tag(true)
                            Text("Color").tag(false)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                        Toggle("Make text searchable (OCR)", isOn: $searchable)
                    }
                }

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
                    Button(pages.isEmpty ? "Scan or add pages first" : "Save PDF", action: save)
                        .controlSize(.large).buttonStyle(.borderedProminent).tint(Theme.blue)
                        .disabled(pages.isEmpty || busy != nil)
                }
            }
            .padding(24)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("Scan document")

        .fileImporter(isPresented: $showPicturePicker, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                if let image = loadPicture(from: url, maxPixels: 2400)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    pages.append(ScannedPage(image: image))
                }
            }
            saved = nil
        }
    }

    private func save() {
        message = nil
        saved = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        panel.nameFieldStringValue = "Scan \(stamp.string(from: Date())).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let images = pages.map { blackAndWhite ? documentLook($0.image) : $0.image }
        let withText = searchable
        busy = "Making PDF…"
        Task { @MainActor in
            // each picture becomes one A4-wide page (like Images to PDF)
            let plain = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
            defer { try? FileManager.default.removeItem(at: plain) }
            guard imagesToPdf(images.map { NSImage(cgImage: $0, size: CGSize(width: $0.width, height: $0.height)) }, to: plain),
                  let made = PDFDocument(url: plain) else {
                busy = nil
                message = "Could not make the PDF."
                return
            }
            var ok = true
            if withText {
                var words: [Int: [OcrWord]] = [:]
                for (i, image) in images.enumerated() {
                    busy = "Reading text on page \(i + 1) of \(images.count)…"
                    words[i] = await Task.detached { recognizeWords(in: image, language: nil) }.value
                }
                busy = "Saving…"
                ok = redrawPdf(made, to: url, password: nil) { i, context, page in
                    drawInvisibleWords(words[i] ?? [], in: page, context: context)
                }
            } else {
                ok = made.write(to: url)
            }
            busy = nil
            if ok { saved = url } else { message = "Could not save the PDF. Try another folder." }
        }
    }
}
