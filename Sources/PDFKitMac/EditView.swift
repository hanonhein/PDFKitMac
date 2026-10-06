import SwiftUI
import PDFKit

// MARK: - Tools and colours (same as Android)

enum EditTool: String, CaseIterable, Identifiable {
    case scroll, select, pen, highlight, eraser, text, shape
    var id: Self { self }

    var label: String {
        switch self {
        case .scroll: "Scroll"
        case .select: "Select"
        case .pen: "Pen"
        case .highlight: "Highlight"
        case .eraser: "Eraser"
        case .text: "Text"
        case .shape: "Shapes"
        }
    }

    var icon: String {
        switch self {
        case .scroll: "hand.raised"
        case .select: "arrow.up.and.down.and.arrow.left.and.right"
        case .pen: "pencil.tip"
        case .highlight: "highlighter"
        case .eraser: "eraser"
        case .text: "textformat"
        case .shape: "square.on.circle"
        }
    }

    var hint: String {
        switch self {
        case .scroll: "Scroll and zoom the pages. Pick a tool to edit."
        case .select: "Click something you added to select it. Drag to move it, or a picture's corner to resize. Delete key removes it."
        case .pen: "Drag on the page to draw."
        case .highlight: "Drag over text to highlight it."
        case .eraser: "Click or drag over anything you added to remove it."
        case .text: "Click on the page to add text. Click existing text to change it."
        case .shape: "Drag on the page to draw the shape."
        }
    }
}

private func hex(_ value: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}

let penColors: [NSColor] = [
    0x000000, 0x5F6368, 0xFFFFFF,
    0xD32F2F, 0xE91E63, 0x9C27B0,
    0x3F51B5, 0x1976D2, 0x0097A7,
    0x388E3C, 0x8BC34A, 0xFBC02D,
    0xF57C00, 0x795548, 0x607D8B
].map(hex)

let highlightColors: [NSColor] = [0xFFEB3B, 0x69F0AE, 0xFF80AB, 0x40C4FF, 0xFFAB40, 0xB388FF].map(hex)

// What the Text tool asks the screen for: type new text, or change existing text
struct TextRequest: Identifiable {
    let id = UUID()
    let initial: String
    let isNew: Bool
    let onDone: (String?) -> Void   // nil = delete (for existing text) or cancel
}

// MARK: - The PDF view you edit on

final class EditPDFView: PDFView {
    var tool = EditTool.scroll {
        didSet {
            if tool != .select { picked = nil }
            window?.invalidateCursorRects(for: self)
        }
    }
    var color = hex(0xD32F2F)        // pen, shapes and text
    var penSize: CGFloat = 3          // 1...12, like Android
    var highlightColor = highlightColors[0]
    var highlightSize: CGFloat = 4    // 1...12
    var textSize: CGFloat = 4         // 1...12
    var shapeKind = ShapeKind.rectangle
    var onChange: () -> Void = {}
    var onTextRequest: (TextRequest) -> Void = { _ in }

    private var drawing: MarkAnnotation?   // the pen line or shape being drawn right now
    private var dragLast: CGPoint?          // Select: where the mouse was
    private var dragTotal = CGVector.zero   // Select: how far it moved, for undo
    private var resizing: (original: CGRect, startDistance: CGFloat)?   // Select: dragging a picture's corner
    private var undoSteps: [() -> Void] = []
    var canUndo: Bool { !undoSteps.isEmpty }

    private(set) var picked: MarkAnnotation? {
        didSet {
            if oldValue !== picked { oldValue?.isPicked = false }
            picked?.isPicked = true
            refresh()
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        switch tool {
        case .scroll: super.resetCursorRects()
        case .select: addCursorRect(bounds, cursor: .openHand)
        case .text: addCursorRect(bounds, cursor: .iBeam)
        default: addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // How close (in page units) counts as "on it"
    private var tolerance: CGFloat { 6 / max(scaleFactor, 0.1) }

    private func topMark(at p: CGPoint, on page: PDFPage) -> MarkAnnotation? {
        page.annotations.reversed().compactMap { $0 as? MarkAnnotation }.first { $0.isNear(p, tolerance: tolerance) }
    }

    override func mouseDown(with event: NSEvent) {
        guard tool != .scroll else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: true) else { return }
        let p = convert(point, to: page)
        let width = seenWidth(of: page)

        switch tool {
        case .pen, .highlight:
            // Sizes are parts of the seen page width, so they look the same on any page (like Android)
            let ink = InkAnnotation(bounds: CGRect(origin: p, size: .zero), forType: .ink, withProperties: nil)
            ink.isHighlight = tool == .highlight
            ink.inkColor = tool == .highlight ? highlightColor : color
            ink.lineWidth = tool == .highlight ? width * highlightSize * 0.006 : width * penSize * 0.001
            ink.points = [p]
            ink.updateBounds()
            page.addAnnotation(ink)
            drawing = ink

        case .shape:
            let shape = ShapeAnnotation(bounds: CGRect(origin: p, size: .zero), forType: .square, withProperties: nil)
            shape.kind = shapeKind
            shape.inkColor = color
            shape.lineWidth = width * penSize * 0.001
            shape.start = p
            shape.end = p
            shape.updateBounds()
            page.addAnnotation(shape)
            drawing = shape

        case .eraser:
            erase(at: p, on: page)

        case .text:
            if let existing = topMark(at: p, on: page) as? TextAnnotation {
                editText(existing)
            } else {
                newText(at: p, on: page)
            }

        case .select:
            // A picked picture's corner is just outside it, so check that first
            if let image = picked as? ImageAnnotation, image.page == page, isOnCorner(p, of: image.bounds, tolerance: tolerance * 1.5) {
                let b = image.bounds
                resizing = (b, hypot(p.x - b.midX, p.y - b.midY))
                return
            }
            picked = topMark(at: p, on: page)
            if let text = picked as? TextAnnotation, event.clickCount == 2 {
                editText(text)
            } else if let image = picked as? ImageAnnotation, isOnCorner(p, of: image.bounds, tolerance: tolerance * 1.5) {
                let b = image.bounds
                resizing = (b, hypot(p.x - b.midX, p.y - b.midY))
            } else if picked != nil {
                dragLast = p
                dragTotal = .zero
            }

        case .scroll:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard tool != .scroll else { super.mouseDragged(with: event); return }
        let point = convert(event.locationInWindow, from: nil)

        if let ink = drawing as? InkAnnotation, let page = ink.page {
            ink.points.append(convert(point, to: page))
            ink.updateBounds()
        } else if let shape = drawing as? ShapeAnnotation, let page = shape.page {
            shape.end = convert(point, to: page)
            shape.updateBounds()
        } else if tool == .eraser, let page = page(for: point, nearest: true) {
            erase(at: convert(point, to: page), on: page)
        } else if tool == .select, let mark = picked, let page = mark.page, let resizing {
            mark.bounds = resized(resizing.original, startDistance: resizing.startDistance, to: convert(point, to: page))
        } else if tool == .select, let mark = picked, let page = mark.page, let last = dragLast {
            let p = convert(point, to: page)
            mark.moveBy(dx: p.x - last.x, dy: p.y - last.y)
            dragTotal.dx += p.x - last.x
            dragTotal.dy += p.y - last.y
            dragLast = p
        }
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        guard tool != .scroll else { super.mouseUp(with: event); return }
        if let mark = drawing, let page = mark.page {
            // A shape needs a little drag; a plain click doesn't make one
            if let shape = mark as? ShapeAnnotation, hypot(shape.end.x - shape.start.x, shape.end.y - shape.start.y) < tolerance {
                page.removeAnnotation(shape)
            } else {
                undoSteps.append { page.removeAnnotation(mark) }
            }
        }
        if let mark = picked, dragLast != nil, dragTotal != .zero {
            let back = dragTotal
            undoSteps.append { mark.moveBy(dx: -back.dx, dy: -back.dy) }
        }
        if let mark = picked, let resizing, mark.bounds != resizing.original {
            let original = resizing.original
            undoSteps.append { mark.bounds = original }
        }
        drawing = nil
        dragLast = nil
        resizing = nil
        refresh()
        onChange()
    }

    override func keyDown(with event: NSEvent) {
        // Delete or Backspace removes the selected mark
        if let mark = picked, event.keyCode == 51 || event.keyCode == 117 {
            remove(mark)
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Actions

    private func erase(at p: CGPoint, on page: PDFPage) {
        for case let mark as MarkAnnotation in page.annotations where mark.isNear(p, tolerance: tolerance) {
            page.removeAnnotation(mark)
            undoSteps.append { page.addAnnotation(mark) }
        }
        onChange()
    }

    func remove(_ mark: MarkAnnotation) {
        guard let page = mark.page else { return }
        if picked === mark { picked = nil }
        mark.isPicked = false
        page.removeAnnotation(mark)
        undoSteps.append { page.addAnnotation(mark) }
        refresh()
        onChange()
    }

    func removePicked() {
        if let picked { remove(picked) }
    }

    private func newText(at p: CGPoint, on page: PDFPage) {
        let size = seenWidth(of: page) * (0.01 + textSize * 0.004)   // same as Android
        let color = self.color
        onTextRequest(TextRequest(initial: "", isNew: true) { [weak self] typed in
            guard let self, let typed, !typed.isEmpty else { return }
            let mark = TextAnnotation(bounds: CGRect(origin: p, size: .zero), forType: .freeText, withProperties: nil)
            mark.text = typed
            mark.inkColor = color
            mark.fontSize = size
            page.addAnnotation(mark)
            mark.fitText(topLeft: p)
            self.undoSteps.append { page.removeAnnotation(mark) }
            self.refresh()
            self.onChange()
        })
    }

    private func editText(_ mark: TextAnnotation) {
        onTextRequest(TextRequest(initial: mark.text, isNew: false) { [weak self] typed in
            guard let self else { return }
            guard let typed, !typed.isEmpty else { self.remove(mark); return }
            let old = mark.text
            mark.text = typed
            mark.fitText()
            self.undoSteps.append { mark.text = old; mark.fitText() }
            self.refresh()
            self.onChange()
        })
    }

    // Puts a picture (signature, photo or stamp) in the middle of the page you are looking at, and selects it
    func place(_ image: NSImage, part: CGFloat) {
        guard let page = currentPage, image.size.width > 0 else { return }
        let mark = makeImageMark(image, on: page, part: part)
        page.addAnnotation(mark)
        undoSteps.append { page.removeAnnotation(mark) }
        picked = mark
        window?.makeFirstResponder(self)
        onChange()
    }

    func undo() {
        guard let step = undoSteps.popLast() else { return }
        picked = nil
        step()
        refresh()
        onChange()
    }

    func unpick() { picked = nil }

    private func refresh() {
        needsDisplay = true
        documentView?.needsDisplay = true
        documentView?.subviews.forEach { $0.needsDisplay = true }
    }
}

// Puts EditPDFView inside SwiftUI
struct EditPDFViewer: NSViewRepresentable {
    let document: PDFDocument
    let controller: EditController

    func makeNSView(context: Context) -> EditPDFView {
        let view = EditPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        view.onChange = { [weak controller] in controller?.refresh() }
        view.onTextRequest = { [weak controller] in controller?.textRequest = $0 }
        controller.view = view
        controller.push()
        return view
    }

    func updateNSView(_ view: EditPDFView, context: Context) {}
}

// Keeps the buttons and the PDF view in step
final class EditController: ObservableObject {
    weak var view: EditPDFView?
    @Published var tool = EditTool.scroll { didSet { push() } }
    @Published var color = hex(0xD32F2F) { didSet { push() } }
    @Published var penSize: Double = 3 { didSet { push() } }
    @Published var highlightColor = highlightColors[0] { didSet { push() } }
    @Published var highlightSize: Double = 4 { didSet { push() } }
    @Published var textSize: Double = 4 { didSet { push() } }
    @Published var shapeKind = ShapeKind.rectangle { didSet { push() } }
    @Published var canUndo = false
    @Published var hasPicked = false
    @Published var textRequest: TextRequest?

    func push() {
        guard let view else { return }
        view.tool = tool
        view.color = color
        view.penSize = penSize
        view.highlightColor = highlightColor
        view.highlightSize = highlightSize
        view.textSize = textSize
        view.shapeKind = shapeKind
        refresh()
    }

    // Switches to Select (so you can move it right away), then places the picture
    func place(_ image: NSImage, part: CGFloat) {
        tool = .select
        view?.place(image, part: part)
    }

    func refresh() {
        canUndo = view?.canUndo ?? false
        hasPicked = view?.picked != nil
    }
}

// MARK: - The Edit screen

struct EditView: View {
    let url: URL
    @Binding var path: [Screen]
    @StateObject private var controller = EditController()
    @State private var document: PDFDocument?
    @State private var loadError: String?
    @State private var savedURL: URL?
    @State private var message: String?
    @State private var showPad = false
    @State private var showSaved = false
    @State private var showStamps = false
    @State private var showPicturePicker = false

    var body: some View {
        VStack(spacing: 0) {
            if let document {
                toolbar
                Divider()
                EditPDFViewer(document: document, controller: controller)
                Divider()
                bottomBar
            } else {
                Text(loadError ?? "Opening…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .navigationTitle("Edit: \(url.lastPathComponent)")
        .onAppear(perform: load)
        .sheet(item: $controller.textRequest) { request in
            TextSheet(request: request) { controller.textRequest = nil }
        }
        .sheet(isPresented: $showPad) {
            SignaturePad(
                onDone: { image in
                    SignatureStore.save(image)
                    showPad = false
                    controller.place(image, part: 0.3)
                },
                onCancel: { showPad = false }
            )
        }
        .sheet(isPresented: $showSaved) {
            if let saved = SignatureStore.load() {
                SavedSignatureSheet(
                    image: saved,
                    onUse: { showSaved = false; controller.place(saved, part: 0.3) },
                    onDrawNew: { showSaved = false; DispatchQueue.main.async { showPad = true } },
                    onCancel: { showSaved = false }
                )
            }
        }
        .sheet(isPresented: $showStamps) {
            StampSheet(
                onPick: { image in showStamps = false; controller.place(image, part: 0.35) },
                onCancel: { showStamps = false }
            )
        }
        .fileImporter(isPresented: $showPicturePicker, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            if let image = loadPicture(from: url) {
                controller.place(image, part: 0.5)
            } else {
                message = "Could not open that picture."
            }
        }
    }

    // Tool buttons, then the options for the chosen tool
    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                ForEach(EditTool.allCases) { tool in
                    ToolButton(icon: tool.icon, label: tool.label, selected: controller.tool == tool) {
                        controller.tool = tool
                    }
                }
                Divider().frame(height: 36).padding(.horizontal, 6)
                // These add something once, so they are buttons, not tools (like Android)
                ToolButton(icon: "signature", label: "Sign", selected: false) {
                    if SignatureStore.load() != nil { showSaved = true } else { showPad = true }
                }
                ToolButton(icon: "photo", label: "Picture", selected: false) { showPicturePicker = true }
                ToolButton(icon: "seal", label: "Stamp", selected: false) { showStamps = true }
                Spacer()
                Button { controller.view?.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!controller.canUndo)
            }

            HStack(spacing: 14) {
                switch controller.tool {
                case .pen:
                    ColorMenu(colors: penColors, selected: $controller.color)
                    sizeSlider("Thickness", $controller.penSize)
                case .highlight:
                    ColorMenu(colors: highlightColors, selected: $controller.highlightColor)
                    sizeSlider("Thickness", $controller.highlightSize)
                case .text:
                    ColorMenu(colors: penColors, selected: $controller.color)
                    sizeSlider("Text size", $controller.textSize)
                case .shape:
                    Picker("", selection: $controller.shapeKind) {
                        ForEach(ShapeKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 300)
                    ColorMenu(colors: penColors, selected: $controller.color)
                    sizeSlider("Thickness", $controller.penSize)
                case .select where controller.hasPicked:
                    Button { controller.view?.removePicked() } label: { Label("Delete", systemImage: "trash") }
                default:
                    EmptyView()
                }
                Text(controller.tool.hint)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
            }
            .frame(height: 28)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func sizeSlider(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.subheadline)
            Slider(value: value, in: 1...12).frame(width: 120)
        }
    }

    private var bottomBar: some View {
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
    }

    private func load() {
        guard document == nil else { return }
        switch loadPickedPdf(url) {
        case .success(let picked): document = picked.document
        case .failure(let error): loadError = error.message
        }
    }

    private func save() {
        guard let document else { return }
        message = nil
        savedURL = nil
        controller.view?.unpick()   // don't save the dashed frame
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(baseName(url.lastPathComponent))_edited.pdf"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        if writeMarkedPdf(document, to: target) {
            savedURL = target
        } else {
            message = "Could not save the PDF. Try another folder."
        }
    }
}

// Type new text, or change existing text (like Android's TextMarkDialog)
struct TextSheet: View {
    let request: TextRequest
    let close: () -> Void
    @State private var text: String

    init(request: TextRequest, close: @escaping () -> Void) {
        self.request = request
        self.close = close
        _text = State(initialValue: request.initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.isNew ? "Add text" : "Edit text").font(.title2.bold())
            TextEditor(text: $text)
                .font(.body)
                .frame(width: 380, height: 110)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.outlineVariant))
            HStack {
                if !request.isNew {
                    Button("Delete") { request.onDone(nil); close() }
                }
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    let typed = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                    close()
                    request.onDone(typed)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.blue)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
    }
}

// A tool button: icon with a pill behind it when chosen, label below (like Android)
struct ToolButton: View {
    let icon: String
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .frame(width: 48, height: 26)
                    .background(selected ? Theme.tealContainer : .clear, in: Capsule())
                    .foregroundStyle(selected ? Theme.onTealContainer : Theme.textSecondary)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
            }
            .frame(width: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// The current colour; click it to choose another
struct ColorMenu: View {
    let colors: [NSColor]
    @Binding var selected: NSColor
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Circle()
                .fill(Color(nsColor: selected))
                .frame(width: 24, height: 24)
                .overlay(Circle().stroke(Theme.outlineVariant, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help("Choose a colour")
        .popover(isPresented: $open) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 10), count: 5), spacing: 10) {
                ForEach(colors.indices, id: \.self) { i in
                    Circle()
                        .fill(Color(nsColor: colors[i]))
                        .frame(width: 32, height: 32)
                        .overlay(Circle().stroke(Theme.outlineVariant, lineWidth: 1))
                        .overlay {
                            if colors[i] == selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(colors[i].brightness > 0.6 ? .black : .white)
                            }
                        }
                        .onTapGesture { selected = colors[i]; open = false }
                }
            }
            .padding(14)
        }
    }
}

private extension NSColor {
    var brightness: CGFloat {
        let c = usingColorSpace(.sRGB) ?? self
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }
}

// Choose a ready-made stamp (like Android's StampPickerDialog)
struct StampSheet: View {
    let onPick: (NSImage) -> Void
    let onCancel: () -> Void
    private let stamps = stampList.map { makeStamp($0.text, color: $0.color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a stamp").font(.title2.bold())
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(stamps.indices, id: \.self) { i in
                    Button { onPick(stamps[i]) } label: {
                        Image(nsImage: stamps[i])
                            .resizable()
                            .scaledToFit()
                            .frame(height: 34)
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
