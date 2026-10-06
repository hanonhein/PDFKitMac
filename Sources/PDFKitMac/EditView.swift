import SwiftUI
import PDFKit

// MARK: - Tools and colours (same as Android)

enum EditTool: String, CaseIterable, Identifiable {
    case scroll, pen, highlight, eraser
    var id: Self { self }

    var label: String {
        switch self {
        case .scroll: "Scroll"
        case .pen: "Pen"
        case .highlight: "Highlight"
        case .eraser: "Eraser"
        }
    }

    var icon: String {
        switch self {
        case .scroll: "hand.raised"
        case .pen: "pencil.tip"
        case .highlight: "highlighter"
        case .eraser: "eraser"
        }
    }

    var hint: String {
        switch self {
        case .scroll: "Scroll and zoom the pages. Pick a tool to edit."
        case .pen: "Drag on the page to draw."
        case .highlight: "Drag over text to highlight it."
        case .eraser: "Click or drag over a line to remove it."
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

// MARK: - A pen or highlighter line on the page

final class InkAnnotation: PDFAnnotation {
    var points: [CGPoint] = []   // in page units
    var inkColor: NSColor = .black
    var lineWidth: CGFloat = 1
    var isHighlight = false

    // Keeps the annotation's box just around the line (PDFKit only redraws inside it)
    func updateBounds() {
        guard let first = points.first else { return }
        var box = CGRect(origin: first, size: .zero)
        points.forEach { box = box.union(CGRect(origin: $0, size: .zero)) }
        bounds = box.insetBy(dx: -lineWidth, dy: -lineWidth)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard points.count > 0 else { return }
        context.saveGState()
        page?.transform(context, for: box)   // line up with the page (see SignatureAnnotation)
        let color = isHighlight ? inkColor.withAlphaComponent(0.4) : inkColor
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(isHighlight ? .butt : .round)
        context.setLineJoin(.round)
        if isHighlight { context.setBlendMode(.multiply) }   // text under it stays readable
        context.move(to: points[0])
        if points.count == 1 {
            context.addLine(to: CGPoint(x: points[0].x + 0.1, y: points[0].y))   // a single click makes a dot
        }
        points.dropFirst().forEach { context.addLine(to: $0) }
        context.strokePath()
        context.restoreGState()
    }

    // Is this page point on (or very near) the line?
    func isNear(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        let limit = lineWidth / 2 + tolerance
        if points.count == 1 { return hypot(points[0].x - p.x, points[0].y - p.y) <= limit }
        for i in 1..<points.count where distance(p, points[i - 1], points[i]) <= limit { return true }
        return false
    }

    private func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

// MARK: - The PDF view you draw on

final class EditPDFView: PDFView {
    var tool = EditTool.scroll { didSet { window?.invalidateCursorRects(for: self) } }
    var penColor = hex(0xD32F2F)
    var penSize: CGFloat = 3          // 1...12, like Android
    var highlightColor = highlightColors[0]
    var highlightSize: CGFloat = 4    // 1...12
    var onChange: () -> Void = {}

    private var current: InkAnnotation?
    private var undoSteps: [() -> Void] = []
    var canUndo: Bool { !undoSteps.isEmpty }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        if tool == .scroll { super.resetCursorRects() } else { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func mouseDown(with event: NSEvent) {
        guard tool != .scroll else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: true) else { return }
        let p = convert(point, to: page)

        switch tool {
        case .pen, .highlight:
            // Sizes are parts of the page width as seen, so they look the same on any page (Android does this too)
            let box = page.bounds(for: .cropBox)
            let seenWidth = page.rotation % 180 == 0 ? box.width : box.height
            let ink = InkAnnotation(bounds: CGRect(origin: p, size: .zero), forType: .ink, withProperties: nil)
            ink.isHighlight = tool == .highlight
            ink.inkColor = tool == .highlight ? highlightColor : penColor
            ink.lineWidth = tool == .highlight ? seenWidth * highlightSize * 0.006 : seenWidth * penSize * 0.001
            ink.points = [p]
            ink.updateBounds()
            page.addAnnotation(ink)
            current = ink
        case .eraser:
            erase(at: p, on: page)
        case .scroll:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard tool != .scroll else { super.mouseDragged(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        if let current, let page = current.page {
            current.points.append(convert(point, to: page))
            current.updateBounds()
            refresh()
        } else if tool == .eraser, let page = page(for: point, nearest: true) {
            erase(at: convert(point, to: page), on: page)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard tool != .scroll else { super.mouseUp(with: event); return }
        if let line = current, let page = line.page {
            undoSteps.append { page.removeAnnotation(line) }
            onChange()
        }
        current = nil
        refresh()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            undo()
        } else {
            super.keyDown(with: event)
        }
    }

    private func erase(at p: CGPoint, on page: PDFPage) {
        let tolerance = 6 / max(scaleFactor, 0.1)
        for case let line as InkAnnotation in page.annotations where line.isNear(p, tolerance: tolerance) {
            page.removeAnnotation(line)
            undoSteps.append { page.addAnnotation(line) }
        }
        refresh()
        onChange()
    }

    func undo() {
        guard let step = undoSteps.popLast() else { return }
        step()
        refresh()
        onChange()
    }

    private func refresh() {
        needsDisplay = true
        documentView?.needsDisplay = true
        documentView?.subviews.forEach { $0.needsDisplay = true }
    }
}

// Puts EditPDFView inside SwiftUI and keeps its settings in step with the buttons
struct EditPDFViewer: NSViewRepresentable {
    let document: PDFDocument
    let controller: EditController

    func makeNSView(context: Context) -> EditPDFView {
        let view = EditPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        view.onChange = { [weak controller] in controller?.refreshUndo() }
        controller.view = view
        controller.push()
        return view
    }

    func updateNSView(_ view: EditPDFView, context: Context) {}
}

final class EditController: ObservableObject {
    weak var view: EditPDFView?
    @Published var tool = EditTool.scroll { didSet { push() } }
    @Published var penColor = hex(0xD32F2F) { didSet { push() } }
    @Published var penSize: Double = 3 { didSet { push() } }
    @Published var highlightColor = highlightColors[0] { didSet { push() } }
    @Published var highlightSize: Double = 4 { didSet { push() } }
    @Published var canUndo = false

    // Sends the chosen tool, colour and size to the PDF view
    func push() {
        guard let view else { return }
        view.tool = tool
        view.penColor = penColor
        view.penSize = penSize
        view.highlightColor = highlightColor
        view.highlightSize = highlightSize
    }

    func refreshUndo() { canUndo = view?.canUndo ?? false }
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
    }

    // Tool buttons, then the options for the chosen tool
    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(EditTool.allCases) { tool in
                    ToolButton(icon: tool.icon, label: tool.label, selected: controller.tool == tool) {
                        controller.tool = tool
                    }
                }
                Spacer()
                Button { controller.view?.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!controller.canUndo)
            }

            HStack(spacing: 14) {
                switch controller.tool {
                case .pen:
                    ColorMenu(colors: penColors, selected: $controller.penColor)
                    sizeSlider($controller.penSize)
                case .highlight:
                    ColorMenu(colors: highlightColors, selected: $controller.highlightColor)
                    sizeSlider($controller.highlightSize)
                default:
                    EmptyView()
                }
                Text(controller.tool.hint).font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .frame(height: 28)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func sizeSlider(_ value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text("Thickness").font(.subheadline)
            Slider(value: value, in: 1...12).frame(width: 140)
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
