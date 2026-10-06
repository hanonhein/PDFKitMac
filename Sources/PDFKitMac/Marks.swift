import AppKit
import PDFKit

// Everything you add to a page (pen line, shape, text, signature) is a "mark".
// Marks are stored in page units, like the PDF itself, so they stay in place at any zoom.
class MarkAnnotation: PDFAnnotation {
    var isPicked = false   // shows a dashed frame while it is selected

    // Draws the mark. The canvas is already lined up with the page.
    func drawMark(in context: CGContext) {}

    func moveBy(dx: CGFloat, dy: CGFloat) {
        bounds = bounds.offsetBy(dx: dx, dy: dy)
    }

    // Is this page point on the mark?
    func isNear(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
    }

    func drawPickedFrame(in context: CGContext) {
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(bounds.insetBy(dx: -2, dy: -2))
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        // Apple gives us an unturned canvas; this lines it up with the page (turn and crop)
        page?.transform(context, for: box)
        context.saveGState()
        drawMark(in: context)
        context.restoreGState()
        if isPicked { drawPickedFrame(in: context) }
        context.restoreGState()
    }

    // MARK: Helpers for marks that must look straight on a turned page (text, pictures)

    var pageTurn: Int { ((page?.rotation ?? 0) % 360 + 360) % 360 }

    // The mark's size as you see it (width and height swap on a page turned 90 or 270)
    var seenSize: CGSize {
        pageTurn % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
    }

    // Turns the canvas so drawing inside `body` looks straight. body gets the rect to draw in.
    func drawUpright(in context: CGContext, _ body: (CGRect) -> Void) {
        let size = seenSize
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: CGFloat(pageTurn) * .pi / 180)
        body(CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        context.restoreGState()
    }
}

// The page width as you see it (the height if the page is turned on its side)
func seenWidth(of page: PDFPage) -> CGFloat {
    let box = page.bounds(for: .cropBox)
    return page.rotation % 180 == 0 ? box.width : box.height
}

// A box of the given seen size, whose seen top-left corner is at point p (page units)
func boxFromSeenTopLeft(_ p: CGPoint, seenSize s: CGSize, on page: PDFPage) -> CGRect {
    // Which way "right" and "down" point on the page, for each turn
    let (right, down): (CGVector, CGVector)
    switch ((page.rotation % 360) + 360) % 360 {
    case 90: (right, down) = (CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0))
    case 180: (right, down) = (CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1))
    case 270: (right, down) = (CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0))
    default: (right, down) = (CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1))
    }
    let center = CGPoint(x: p.x + right.dx * s.width / 2 + down.dx * s.height / 2,
                         y: p.y + right.dy * s.width / 2 + down.dy * s.height / 2)
    let size = page.rotation % 180 == 0 ? s : CGSize(width: s.height, height: s.width)
    return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
}

private func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    let t = lengthSquared == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

// MARK: - Pen and highlighter

final class InkAnnotation: MarkAnnotation {
    var points: [CGPoint] = []
    var inkColor: NSColor = .black
    var lineWidth: CGFloat = 1
    var isHighlight = false

    // Keeps the box just around the line (PDFKit only redraws inside it)
    func updateBounds() {
        guard let first = points.first else { return }
        var box = CGRect(origin: first, size: .zero)
        points.forEach { box = box.union(CGRect(origin: $0, size: .zero)) }
        bounds = box.insetBy(dx: -lineWidth, dy: -lineWidth)
    }

    override func drawMark(in context: CGContext) {
        guard !points.isEmpty else { return }
        context.setStrokeColor((isHighlight ? inkColor.withAlphaComponent(0.4) : inkColor).cgColor)
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
    }

    override func moveBy(dx: CGFloat, dy: CGFloat) {
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        updateBounds()
    }

    override func isNear(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        let limit = lineWidth / 2 + tolerance
        if points.count == 1 { return hypot(points[0].x - p.x, points[0].y - p.y) <= limit }
        return (1..<points.count).contains { distance(p, toSegment: points[$0 - 1], points[$0]) <= limit }
    }
}

// MARK: - Shapes

enum ShapeKind: String, CaseIterable, Identifiable {
    case line, rectangle, circle, arrow
    var id: Self { self }
    var label: String { rawValue.capitalized }
}

final class ShapeAnnotation: MarkAnnotation {
    var kind = ShapeKind.line
    var start = CGPoint.zero
    var end = CGPoint.zero
    var inkColor: NSColor = .black
    var lineWidth: CGFloat = 1

    func updateBounds() {
        let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
        bounds = box.insetBy(dx: -lineWidth * 6 - 2, dy: -lineWidth * 6 - 2)   // room for the arrow head
    }

    override func drawMark(in context: CGContext) {
        context.setStrokeColor(inkColor.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
        switch kind {
        case .line:
            context.move(to: start); context.addLine(to: end)
        case .rectangle:
            context.addRect(box)
        case .circle:
            context.addEllipse(in: box)
        case .arrow:
            context.move(to: start); context.addLine(to: end)
            // The two short lines of the head (same sizes as Android)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = max(lineWidth * 5, 12)
            let spread = 28 * CGFloat.pi / 180
            for a in [angle + .pi - spread, angle + .pi + spread] {
                context.move(to: end)
                context.addLine(to: CGPoint(x: end.x + cos(a) * length, y: end.y + sin(a) * length))
            }
        }
        context.strokePath()
    }

    override func moveBy(dx: CGFloat, dy: CGFloat) {
        start = CGPoint(x: start.x + dx, y: start.y + dy)
        end = CGPoint(x: end.x + dx, y: end.y + dy)
        updateBounds()
    }

    override func isNear(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .line, .arrow: return distance(p, toSegment: start, end) <= lineWidth / 2 + tolerance
        default:
            let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
            return box.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    override func drawPickedFrame(in context: CGContext) {
        let saved = bounds
        bounds = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
            .insetBy(dx: -lineWidth, dy: -lineWidth)
        super.drawPickedFrame(in: context)
        bounds = saved
    }
}

// MARK: - Text

final class TextAnnotation: MarkAnnotation {
    var text = ""
    var inkColor: NSColor = .black
    var fontSize: CGFloat = 12

    var attributed: NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: inkColor])
    }

    // Makes the box fit the text, keeping its seen top-left corner where it was
    func fitText(topLeft: CGPoint? = nil) {
        guard let page else { return }
        let size = attributed.size()
        let corner = topLeft ?? seenTopLeft
        bounds = boxFromSeenTopLeft(corner, seenSize: CGSize(width: ceil(size.width) + 2, height: ceil(size.height)), on: page)
    }

    // The seen top-left corner of the box, in page units
    private var seenTopLeft: CGPoint {
        switch pageTurn {
        case 90: CGPoint(x: bounds.minX, y: bounds.minY)
        case 180: CGPoint(x: bounds.maxX, y: bounds.minY)
        case 270: CGPoint(x: bounds.maxX, y: bounds.maxY)
        default: CGPoint(x: bounds.minX, y: bounds.maxY)
        }
    }

    override func drawMark(in context: CGContext) {
        let string = attributed
        drawUpright(in: context) { rect in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            string.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

// MARK: - Pictures (signatures, photos, stamps)

// Makes a picture mark in the middle of the page, `part` of the seen page width wide
func makeImageMark(_ image: NSImage, on page: PDFPage, part: CGFloat) -> ImageAnnotation {
    let box = page.bounds(for: .cropBox)
    let width = seenWidth(of: page) * part
    let height = width * image.size.height / max(image.size.width, 1)
    let size = page.rotation % 180 == 0 ? CGSize(width: width, height: height) : CGSize(width: height, height: width)
    let rect = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
    let mark = ImageAnnotation(bounds: rect, forType: .stamp, withProperties: nil)
    mark.image = image
    return mark
}

// Is page point p on one of the corners of this box?
func isOnCorner(_ p: CGPoint, of b: CGRect, tolerance: CGFloat) -> Bool {
    [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.maxY)]
        .contains { hypot($0.x - p.x, $0.y - p.y) <= tolerance }
}

// A box made bigger or smaller from its middle, keeping its shape.
// `startDistance` is how far from the middle the drag started; p is where the mouse is now.
func resized(_ original: CGRect, startDistance: CGFloat, to p: CGPoint) -> CGRect {
    let center = CGPoint(x: original.midX, y: original.midY)
    let scale = max(hypot(p.x - center.x, p.y - center.y) / max(startDistance, 1), 0.1)
    let minSide: CGFloat = 20
    var size = CGSize(width: original.width * scale, height: original.height * scale)
    if min(size.width, size.height) < minSide {
        let fix = minSide / min(size.width, size.height)
        size = CGSize(width: size.width * fix, height: size.height * fix)
    }
    return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
}

// Big photos are made smaller (longest side 1600 pixels), so the saved PDF doesn't get huge
func loadPicture(from url: URL, maxPixels: Int = 1600) -> NSImage? {
    let hasAccess = url.startAccessingSecurityScopedResource()
    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,   // photos from phones stay the right way up
              kCGImageSourceThumbnailMaxPixelSize: maxPixels
          ] as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
}

// Ready-made stamps: the word and its colour (same as Android)
let stampList: [(text: String, color: UInt32)] = [
    ("APPROVED", 0x2E7D32), ("DRAFT", 0x1565C0), ("CONFIDENTIAL", 0xC62828),
    ("REVIEWED", 0x6A1B9A), ("PAID", 0x2E7D32), ("COPY", 0x455A64)
]

// Draws a stamp: a rounded frame with a bold word inside, on a see-through background (same sizes as Android)
func makeStamp(_ text: String, color hexValue: UInt32) -> NSImage {
    let color = NSColor(srgbRed: CGFloat((hexValue >> 16) & 0xFF) / 255, green: CGFloat((hexValue >> 8) & 0xFF) / 255,
                        blue: CGFloat(hexValue & 0xFF) / 255, alpha: 1)
    let font = NSFont.systemFont(ofSize: 120, weight: .bold)
    let word = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: 120 * 0.08])
    let textSize = word.size()
    let border: CGFloat = 14, padX: CGFloat = 60, padY: CGFloat = 36
    let size = CGSize(width: ceil(textSize.width + padX * 2), height: ceil(textSize.height + padY * 2))

    return NSImage(size: size, flipped: false) { rect in
        color.setStroke()
        let frame = NSBezierPath(roundedRect: rect.insetBy(dx: border / 2, dy: border / 2), xRadius: 36, yRadius: 36)
        frame.lineWidth = border
        frame.stroke()
        word.draw(at: CGPoint(x: padX, y: (rect.height - textSize.height) / 2))
        return true
    }
}
