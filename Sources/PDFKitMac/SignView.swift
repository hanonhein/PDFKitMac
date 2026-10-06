import SwiftUI
import PDFKit

// MARK: - Saved signature

// Keeps the last signature as a picture, so it can be used again next time
enum SignatureStore {
    private static var fileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFKitMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("signature.png")
    }

    static func load() -> NSImage? {
        NSImage(contentsOf: fileURL)
    }

    static func save(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: fileURL)
    }
}

// MARK: - The signature on the page

// A picture placed on a page. It is drawn upright even when the page is turned.
final class SignatureAnnotation: PDFAnnotation {
    var image: NSImage?
    var isPicked = false   // shows a dashed frame and corner dots while you move it

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let turn = CGFloat(page?.rotation ?? 0) * .pi / 180

        context.saveGState()
        // Apple gives us an unturned canvas; this lines it up with the page (turn and crop)
        page?.transform(context, for: box)

        context.saveGState()
        // Turn around the middle, so the picture looks straight on a turned page
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: turn)
        let upright = (page?.rotation ?? 0) % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
        let rect = CGRect(x: -upright.width / 2, y: -upright.height / 2, width: upright.width, height: upright.height)
        context.draw(cg, in: rect)
        context.restoreGState()

        if isPicked {
            context.setStrokeColor(NSColor.systemBlue.cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(bounds)
            context.setFillColor(NSColor.systemBlue.cgColor)
            for corner in [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                           CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)] {
                context.fillEllipse(in: CGRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8))
            }
        }
        context.restoreGState()
    }
}

// MARK: - The PDF view that lets you move and resize signatures

final class SignPDFView: PDFView {
    var onPickedChange: (SignatureAnnotation?) -> Void = { _ in }
    private(set) var picked: SignatureAnnotation? {
        didSet {
            oldValue?.isPicked = false
            picked?.isPicked = true
            onPickedChange(picked)
            refresh()
        }
    }

    private enum Drag { case move(start: CGPoint, original: CGRect), resize(center: CGPoint, startDistance: CGFloat, original: CGRect) }
    private var drag: Drag?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else { picked = nil; super.mouseDown(with: event); return }
        let p = convert(point, to: page)
        let grab = 10 / max(scaleFactor, 0.1)   // how close (in page units) counts as "on the corner"

        // Top-most signature under the mouse (a bit of extra room so the corners are easy to grab)
        let hit = page.annotations.reversed().compactMap { $0 as? SignatureAnnotation }
            .first { $0.bounds.insetBy(dx: -grab, dy: -grab).contains(p) }

        guard let hit else { picked = nil; super.mouseDown(with: event); return }
        picked = hit
        window?.makeFirstResponder(self)

        let b = hit.bounds
        let corners = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                       CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.maxY)]
        let center = CGPoint(x: b.midX, y: b.midY)
        if corners.contains(where: { hypot($0.x - p.x, $0.y - p.y) <= grab }) {
            drag = .resize(center: center, startDistance: max(hypot(p.x - center.x, p.y - center.y), 1), original: b)
        } else {
            drag = .move(start: p, original: b)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let picked, let page = picked.page, let drag else { super.mouseDragged(with: event); return }
        let p = convert(convert(event.locationInWindow, from: nil), to: page)
        switch drag {
        case .move(let start, let original):
            picked.bounds = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
        case .resize(let center, let startDistance, let original):
            // Bigger or smaller from the middle, keeping the same shape
            let scale = max(hypot(p.x - center.x, p.y - center.y) / startDistance, 0.1)
            let size = CGSize(width: max(original.width * scale, 20), height: max(original.height * scale, 20 * original.height / original.width))
            picked.bounds = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        }
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        if drag == nil { super.mouseUp(with: event) }
        drag = nil
    }

    // Delete or Backspace removes the picked signature
    override func keyDown(with event: NSEvent) {
        if picked != nil, event.keyCode == 51 || event.keyCode == 117 {
            removePicked()
        } else {
            super.keyDown(with: event)
        }
    }

    // Puts a signature in the middle of the page you are looking at
    func place(_ image: NSImage) {
        guard let page = currentPage, image.size.width > 0 else { return }
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let seenWidth = turned ? box.height : box.width
        let width = seenWidth * 0.3
        let height = width * image.size.height / image.size.width
        let size = turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        let rect = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)

        let annotation = SignatureAnnotation(bounds: rect, forType: .stamp, withProperties: nil)
        annotation.image = image
        page.addAnnotation(annotation)
        picked = annotation
        window?.makeFirstResponder(self)
    }

    func removePicked() {
        guard let picked, let page = picked.page else { return }
        page.removeAnnotation(picked)
        self.picked = nil
    }

    func unpick() { picked = nil }

    private func refresh() {
        needsDisplay = true
        documentView?.needsDisplay = true
        documentView?.subviews.forEach { $0.needsDisplay = true }
    }
}

// Puts SignPDFView inside SwiftUI
struct SignPDFViewer: NSViewRepresentable {
    let document: PDFDocument
    let controller: SignController

    func makeNSView(context: Context) -> SignPDFView {
        let view = SignPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        view.onPickedChange = { [weak controller] in controller?.hasPicked = $0 != nil }
        controller.view = view
        return view
    }

    func updateNSView(_ view: SignPDFView, context: Context) {}
}

// Lets the SwiftUI buttons talk to the PDF view
final class SignController: ObservableObject {
    weak var view: SignPDFView?
    @Published var hasPicked = false
}

// MARK: - Saving

// Saves a new PDF. Pages with things we added (signatures, pen, highlighter) are redrawn
// with them burned in; the other pages are copied as they are.
func writeMarkedPdf(_ document: PDFDocument, to url: URL) -> Bool {
    let output = PDFDocument()
    var helpers: [PDFDocument] = []   // must stay alive until "output" is saved

    for index in 0..<document.pageCount {
        guard let page = document.page(at: index) else { continue }
        let added = page.annotations.filter { $0 is SignatureAnnotation || $0 is InkAnnotation }
        if added.isEmpty {
            if let copy = page.copy() as? PDFPage { output.insert(copy, at: output.pageCount) }
            continue
        }

        // Draw the page (with its signatures) into a new one-page PDF
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        var mediaBox = CGRect(origin: .zero, size: turned ? CGSize(width: box.height, height: box.width) : box.size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { continue }
        context.beginPDFPage(nil)
        page.draw(with: .cropBox, to: context)
        context.endPDFPage()
        context.closePDF()

        if let flat = PDFDocument(data: data as Data), let flatPage = flat.page(at: 0) {
            helpers.append(flat)
            output.insert(flatPage, at: output.pageCount)
        }
    }
    return withExtendedLifetime(helpers) { output.write(to: url) }
}

// MARK: - The Sign screen

struct SignView: View {
    let url: URL
    @Binding var path: [Screen]
    @StateObject private var controller = SignController()
    @State private var document: PDFDocument?
    @State private var loadError: String?
    @State private var showPad = false
    @State private var showSaved = false
    @State private var savedURL: URL?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            if let document {
                HStack(spacing: 8) {
                    Text("Drag the signature to move it. Drag a corner to resize it.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button { startSigning() } label: { Label("Add signature", systemImage: "signature") }
                    Button { controller.view?.removePicked() } label: { Label("Remove", systemImage: "trash") }
                        .disabled(!controller.hasPicked)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()

                SignPDFViewer(document: document, controller: controller)

                Divider()
                VStack(spacing: 8) {
                    if let message { Text(message).foregroundStyle(Theme.orange) }
                    if let savedURL {
                        SavedBanner(text: "Saved \(savedURL.lastPathComponent)", showURL: savedURL, openURL: savedURL) {
                            path.append(.viewer($0))
                        }
                    }
                    HStack {
                        Spacer()
                        Button { save() } label: { Label("Save as new PDF", systemImage: "square.and.arrow.down") }
                            .controlSize(.large)
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.blue)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            } else {
                Text(loadError ?? "Opening…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .navigationTitle("Sign: \(url.lastPathComponent)")
        .onAppear(perform: load)
        .sheet(isPresented: $showPad) {
            SignaturePad(
                onDone: { image in
                    SignatureStore.save(image)
                    showPad = false
                    controller.view?.place(image)
                },
                onCancel: { showPad = false }
            )
        }
        .sheet(isPresented: $showSaved) {
            if let saved = SignatureStore.load() {
                SavedSignatureSheet(
                    image: saved,
                    onUse: { showSaved = false; controller.view?.place(saved) },
                    onDrawNew: { showSaved = false; DispatchQueue.main.async { showPad = true } },
                    onCancel: { showSaved = false }
                )
            }
        }
    }

    private func load() {
        guard document == nil else { return }
        switch loadPickedPdf(url) {
        case .success(let picked):
            document = picked.document
            // Start right away with the signature, like on Android
            DispatchQueue.main.async { startSigning() }
        case .failure(let error):
            loadError = error.message
        }
    }

    // Use the saved signature, or draw a new one
    private func startSigning() {
        if SignatureStore.load() != nil { showSaved = true } else { showPad = true }
    }

    private func save() {
        guard let document else { return }
        message = nil
        savedURL = nil
        controller.view?.unpick()   // don't save the dashed frame

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(baseName(url.lastPathComponent))_signed.pdf"
        guard panel.runModal() == .OK, let target = panel.url else { return }

        if writeMarkedPdf(document, to: target) {
            savedURL = target
        } else {
            message = "Could not save the PDF. Try another folder."
        }
    }
}

// MARK: - Drawing pad

private let inkColors: [(name: String, color: NSColor)] = [
    ("Black", .black),
    ("Blue", NSColor(srgbRed: 0x0D / 255, green: 0x47 / 255, blue: 0xA1 / 255, alpha: 1)),
    ("Red", NSColor(srgbRed: 0xB7 / 255, green: 0x1C / 255, blue: 0x1C / 255, alpha: 1))
]

// A white pad where you sign with the mouse or trackpad
struct SignaturePad: View {
    let onDone: (NSImage) -> Void
    let onCancel: () -> Void
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    @State private var ink = inkColors[0].color
    private let lineWidth: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Draw your signature").font(.title2.bold())
            Text("Sign with your mouse or trackpad in the box below.").foregroundStyle(.secondary)

            Canvas { context, _ in
                for points in strokes + [current] where points.count > 1 {
                    context.stroke(path(points), with: .color(Color(nsColor: ink)),
                                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: 520, height: 220)
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.gray.opacity(0.4)))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { current.append($0.location) }
                    .onEnded { _ in strokes.append(current); current = [] }
            )

            HStack(spacing: 12) {
                ForEach(inkColors, id: \.name) { item in
                    Circle()
                        .fill(Color(nsColor: item.color))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(Theme.blue, lineWidth: item.color == ink ? 3 : 0).padding(-4))
                        .onTapGesture { ink = item.color }
                        .help(item.name)
                }
                Spacer()
                Button("Clear") { strokes = [] }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Use signature") {
                    if let image = signatureImage() { onDone(image) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.blue)
                .disabled(!strokes.contains { $0.count > 1 })
            }
        }
        .padding(24)
    }

    private func path(_ points: [CGPoint]) -> Path {
        var p = Path()
        p.move(to: points[0])
        points.dropFirst().forEach { p.addLine(to: $0) }
        return p
    }

    // Draws the strokes onto a see-through picture, cut to just the signature (sharp: 3x size)
    private func signatureImage() -> NSImage? {
        let points = strokes.filter { $0.count > 1 }.flatMap { $0 }
        guard !points.isEmpty else { return nil }
        let pad = lineWidth * 2
        let minX = points.map(\.x).min()! - pad, maxX = points.map(\.x).max()! + pad
        let minY = points.map(\.y).min()! - pad, maxY = points.map(\.y).max()! + pad
        let size = CGSize(width: max(maxX - minX, 1), height: max(maxY - minY, 1))
        let scale: CGFloat = 3

        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // The pad counts down from the top; pictures count up from the bottom
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setStrokeColor(ink.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for points in strokes where points.count > 1 {
            context.move(to: CGPoint(x: points[0].x - minX, y: points[0].y - minY))
            points.dropFirst().forEach { context.addLine(to: CGPoint(x: $0.x - minX, y: $0.y - minY)) }
            context.strokePath()
        }
        guard let cg = context.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: size)
    }
}

// Shown when a signature was saved before: use it, or draw a new one
struct SavedSignatureSheet: View {
    let image: NSImage
    let onUse: () -> Void
    let onDrawNew: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your signature").font(.title2.bold())
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(height: 90)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Draw new", action: onDrawNew)
                Button("Use it", action: onUse)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.blue)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
