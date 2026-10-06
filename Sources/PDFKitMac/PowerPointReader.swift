import AppKit

// Turns a PowerPoint file (.pptx) into a PDF: one page per slide (based on Android PowerPointReader.kt).
// Drawn: backgrounds (also theme backgrounds), pictures (also cut to a shape), shapes and freeform
// shapes with their colours, text boxes (with the positions, sizes, colours, fonts and capitals
// from the slide's templates), tables and grouped shapes.
// Not drawn: charts, SmartArt, videos, animations, and some special effects.

private let emuPerPoint: CGFloat = 12700

func powerPointToPdf(_ url: URL, to output: URL) throws -> Bool {
    let zip = try OfficeZip(url, kindName: "PowerPoint", ext: ".pptx")
    guard let pres = zip.xml("ppt/presentation.xml") else { throw OfficeError("This is not a PowerPoint (.pptx) file.") }
    let presRels = zip.relations("ppt/presentation.xml")
    let size = pres.elements("sldSz").first
    let slideW = number(size, "cx") ?? 12_192_000
    let slideH = number(size, "cy") ?? 6_858_000
    let slides = pres.elements("sldId").compactMap { ($0.attr("r:id") ?? $0.attr("id")).flatMap { presRels[$0] } }.filter(zip.has)
    if slides.isEmpty { throw OfficeError("This presentation has no slides.") }

    let page = CGSize(width: max((slideW / emuPerPoint).rounded(), 72), height: max((slideH / emuPerPoint).rounded(), 72))
    let data = NSMutableData()
    var mediaBox = CGRect(origin: .zero, size: page)
    guard let consumer = CGDataConsumer(data: data),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return false }
    for path in slides {
        context.beginPDFPage(nil)
        // draw from the top down, like the slide's own positions
        context.translateBy(x: 0, y: page.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        SlideDrawer(zip: zip, context: context, slideW: slideW, slideH: slideH).draw(path)
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
    }
    context.closePDF()
    return (try? (data as Data).write(to: output)) != nil
}

private func number(_ e: XMLElement?, _ name: String) -> CGFloat? {
    e?.attr(name).flatMap(Double.init).map { CGFloat($0) }
}

// Maps shape positions (in EMU) inside groups to the slide: x' = a + x * b, y' = c + y * d
private struct Place {
    var a: CGFloat = 0, b: CGFloat = 1, c: CGFloat = 0, d: CGFloat = 1
    func x(_ v: CGFloat) -> CGFloat { a + v * b }
    func y(_ v: CGFloat) -> CGFloat { c + v * d }
}

// One placeholder's spot on a template (title, body, ...) and its text styles
private struct Placeholder {
    let type: String
    let idx: String?
    let box: CGRect?
    let bodyPr: XMLElement?
    let lstStyle: XMLElement?
}

private final class SlideDrawer {
    private let zip: OfficeZip
    private let context: CGContext
    private let k = 1 / emuPerPoint   // EMU -> points
    private let slideBox: CGRect
    private var themeColors: [String: NSColor] = [:]
    private var colorMap: [String: String] = [:]   // "tx1" -> "dk1"
    private var majorFont: String?                 // headings font of the theme
    private var minorFont: String?                 // body font of the theme
    private var masterStyles: XMLElement?          // p:txStyles
    private var layoutHolders: [Placeholder] = []
    private var masterHolders: [Placeholder] = []

    init(zip: OfficeZip, context: CGContext, slideW: CGFloat, slideH: CGFloat) {
        self.zip = zip
        self.context = context
        slideBox = CGRect(x: 0, y: 0, width: slideW / emuPerPoint, height: slideH / emuPerPoint)
    }

    func draw(_ slidePath: String) {
        guard let slide = zip.xml(slidePath) else { return }
        let slideRels = zip.relations(slidePath)
        let layoutPath = slideRels.values.first { $0.contains("/slideLayouts/") }
        let layout = layoutPath.flatMap { zip.xml($0) }
        let layoutRels = layoutPath.map { zip.relations($0) } ?? [:]
        let masterPath = layoutRels.values.first { $0.contains("/slideMasters/") }
        let master = masterPath.flatMap { zip.xml($0) }
        let masterRels = masterPath.map { zip.relations($0) } ?? [:]

        // colours and fonts of the theme
        if let theme = masterRels.values.first(where: { $0.contains("/theme/") }).flatMap({ zip.xml($0) }) {
            for c in theme.elements("clrScheme").first?.childElements ?? [] {
                let hex = c.child("srgbClr")?.attr("val") ?? c.child("sysClr")?.attr("lastClr")
                themeColors[c.localName ?? ""] = hexColor(hex) ?? .black
            }
            majorFont = theme.elements("majorFont").first?.child("latin")?.attr("typeface")
            minorFont = theme.elements("minorFont").first?.child("latin")?.attr("typeface")
        }
        // which theme colour is "text" and which is "background": the master's map,
        // changed by the layout, then by the slide (a layout can swap them for white text on dark)
        for a in master?.elements("clrMap").first?.attributes ?? [] {
            if let n = a.localName, let v = a.stringValue { colorMap[n] = v }
        }
        for doc in [layout, slide as XMLDocument?] {
            for a in doc?.elements("overrideClrMapping").first?.attributes ?? [] {
                if let n = a.localName, let v = a.stringValue { colorMap[n] = v }
            }
        }
        masterStyles = master?.elements("txStyles").first
        layoutHolders = layout.map(placeholders) ?? []
        masterHolders = master.map(placeholders) ?? []

        context.saveGState()
        NSColor.white.setFill()
        slideBox.fill()
        // background: from the slide, else its layout, else the master
        for (doc, rels) in [(slide as XMLDocument?, slideRels), (layout, layoutRels), (master, masterRels)] {
            if let bg = doc?.elements("bg").first { background(bg, rels); break }
        }
        let hideMaster = slide.rootElement()?.attr("showMasterSp") == "0"
        if !hideMaster {
            if layout?.rootElement()?.attr("showMasterSp") != "0", let t = master?.elements("spTree").first {
                tree(t, masterRels, Place(), template: true)
            }
            if let t = layout?.elements("spTree").first { tree(t, layoutRels, Place(), template: true) }
        }
        if let t = slide.elements("spTree").first { tree(t, slideRels, Place(), template: false) }
        context.restoreGState()
    }

    private func placeholders(_ doc: XMLDocument) -> [Placeholder] {
        doc.elements("sp").compactMap { sp in
            guard let ph = sp.elements("ph").first else { return nil }
            return Placeholder(type: ph.attr("type") ?? "body", idx: ph.attr("idx"),
                               box: sp.child("spPr").flatMap { box($0.child("xfrm"), Place()) },
                               bodyPr: sp.child("txBody")?.child("bodyPr"),
                               lstStyle: sp.child("txBody")?.child("lstStyle"))
        }
    }

    private func generalType(_ type: String) -> String {
        switch type {
        case "ctrTitle": "title"
        case "subTitle", "obj": "body"
        default: type
        }
    }

    // Where a placeholder on the slide sits on its layout
    private func layoutHolder(_ type: String, _ idx: String?) -> Placeholder? {
        idx.flatMap { i in layoutHolders.first { $0.idx == i } }
            ?? layoutHolders.first { $0.type == type }
            ?? layoutHolders.first { $0.type == generalType(type) }
    }

    private func masterHolder(_ type: String) -> Placeholder? {
        masterHolders.first { $0.type == generalType(type) }
    }

    private func background(_ bg: XMLElement, _ rels: [String: String]) {
        if let pr = bg.child("bgPr") {
            if let c = color(pr.child("solidFill")) ?? color(pr.child("gradFill")?.elements("gs").first) {
                c.setFill(); slideBox.fill(); return
            }
            if let blip = pr.child("blipFill") { picture(blip, rels, slideBox, clip: nil) }
        } else if let ref = bg.child("bgRef"), let c = color(ref) {
            // a background from the theme's list; its colour is a good match
            c.setFill(); slideBox.fill()
        }
    }

    // Draws every shape of a shape tree (or group), in order
    private func tree(_ parent: XMLElement, _ rels: [String: String], _ place: Place, template: Bool) {
        for child in parent.childElements {
            switch child.localName {
            case "sp": shape(child, rels, place, template: template)
            case "pic":
                guard let spPr = child.child("spPr"), let r = box(spPr.child("xfrm"), place),
                      let blip = child.child("blipFill") else { continue }
                // a picture can be cut to a shape (for example a circle or a freeform blob)
                let clip = (spPr.child("custGeom") != nil || (spPr.child("prstGeom")?.attr("prst") ?? "rect") != "rect")
                    ? geometryPath(spPr, r) : nil
                picture(blip, rels, r, clip: clip)
            case "cxnSp": connector(child, place)
            case "graphicFrame":
                if let tbl = child.elements("tbl").first, let r = box(child.child("xfrm"), place) { table(tbl, r) }
            case "grpSp":
                tree(child, rels, groupPlace(child.child("grpSpPr")?.child("xfrm"), place), template: template)
            default: break
            }
        }
    }

    private func groupPlace(_ xfrm: XMLElement?, _ outer: Place) -> Place {
        guard let xfrm else { return outer }
        let off = xfrm.child("off"), ext = xfrm.child("ext"), chOff = xfrm.child("chOff"), chExt = xfrm.child("chExt")
        func f(_ e: XMLElement?, _ n: String) -> CGFloat { number(e, n) ?? 0 }
        let sx = f(chExt, "cx") > 0 ? f(ext, "cx") / f(chExt, "cx") : 1
        let sy = f(chExt, "cy") > 0 ? f(ext, "cy") / f(chExt, "cy") : 1
        let ga = f(off, "x") - f(chOff, "x") * sx
        let gc = f(off, "y") - f(chOff, "y") * sy
        return Place(a: outer.a + ga * outer.b, b: sx * outer.b, c: outer.c + gc * outer.d, d: sy * outer.d)
    }

    // The box of an a:xfrm (or p:xfrm), on the slide, in points
    private func box(_ xfrm: XMLElement?, _ place: Place) -> CGRect? {
        guard let off = xfrm?.child("off"), let ext = xfrm?.child("ext") else { return nil }
        let x = number(off, "x") ?? 0, y = number(off, "y") ?? 0
        let w = number(ext, "cx") ?? 0, h = number(ext, "cy") ?? 0
        let left = place.x(x) * k, top = place.y(y) * k
        return CGRect(x: left, y: top, width: place.x(x + w) * k - left, height: place.y(y + h) * k - top)
    }

    private func shape(_ sp: XMLElement, _ rels: [String: String], _ place: Place, template: Bool) {
        let ph = sp.elements("ph").first
        if template && ph != nil { return }   // empty "Click to add title" boxes are not shown
        let spPr = sp.child("spPr")
        let xfrm = spPr?.child("xfrm")
        let type = ph.map { $0.attr("type") ?? "body" }
        let holder = type.flatMap { layoutHolder($0, ph?.attr("idx")) }
        let mHolder = type.flatMap(masterHolder)
        guard let r = box(xfrm, place) ?? holder?.box ?? mHolder?.box else { return }

        context.saveGState()
        let angle = (number(xfrm, "rot") ?? 0) / 60000
        if angle != 0 {
            context.translateBy(x: r.midX, y: r.midY)
            context.rotate(by: angle * .pi / 180)   // the canvas is flipped, so this turns clockwise like PowerPoint
            context.translateBy(x: -r.midX, y: -r.midY)
        }

        // fill and outline: from the shape, else from its theme style
        let style = sp.child("style")
        var fill: NSColor?
        let path = geometryPath(spPr, r)
        if spPr?.child("noFill") != nil {
            fill = nil
        } else if let f = spPr?.child("solidFill") {
            fill = color(f)
        } else if let g = spPr?.child("gradFill") {
            fill = color(g.elements("gs").first)
        } else if let blip = spPr?.child("blipFill") {
            picture(blip, rels, r, clip: path)
        } else if let ref = style?.child("fillRef"), ref.attr("idx") != "0" {
            fill = color(ref)
        }
        let ln = spPr?.child("ln")
        var stroke: NSColor?
        if ln?.child("noFill") != nil {
            stroke = nil
        } else if let f = ln?.child("solidFill") {
            stroke = color(f)
        } else if let ref = style?.child("lnRef"), ref.attr("idx") != "0" {
            stroke = color(ref)
        }
        let isLine = spPr?.child("prstGeom")?.attr("prst") == "line"
        if let fill, !isLine { fill.setFill(); path.fill() }
        if let stroke {
            stroke.setStroke()
            path.lineWidth = (number(ln, "w") ?? 12700) * k
            path.stroke()
        }

        if let body = sp.child("txBody") {
            // text styles, most important first: this box, its layout spot, the master's spot, the master's defaults
            let defaults: XMLElement?
            switch type.map(generalType) {
            case nil: defaults = masterStyles?.child("otherStyle")
            case "title": defaults = masterStyles?.child("titleStyle")
            case "body": defaults = masterStyles?.child("bodyStyle")
            default: defaults = masterStyles?.child("otherStyle")
            }
            let chain = [body.child("lstStyle"), holder?.lstStyle, mHolder?.lstStyle, defaults].compactMap { $0 }
            let fontRefColor = color(style?.child("fontRef"))
            text(body, r, styles: chain, templateBodyPr: holder?.bodyPr ?? mHolder?.bodyPr,
                 isTitle: type == "title" || type == "ctrTitle", baseColor: fontRefColor)
        }
        context.restoreGState()
    }

    // MARK: Shapes

    // The outline of a shape: a ready-made one (rect, ellipse, ...) or a freeform one
    private func geometryPath(_ spPr: XMLElement?, _ r: CGRect) -> NSBezierPath {
        if let cust = spPr?.child("custGeom"), let path = freeform(cust, r) { return path }
        switch spPr?.child("prstGeom")?.attr("prst") ?? "rect" {
        case "ellipse": return NSBezierPath(ovalIn: r)
        case "roundRect":
            let radius = min(r.width, r.height) * 0.1667
            return NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        case "line":
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.line(to: CGPoint(x: r.maxX, y: r.maxY))
            return p
        case "triangle":
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.midX, y: r.minY)); p.line(to: CGPoint(x: r.maxX, y: r.maxY)); p.line(to: CGPoint(x: r.minX, y: r.maxY))
            p.close()
            return p
        default: return NSBezierPath(rect: r)
        }
    }

    // A freeform shape (a:custGeom): its paths, scaled into the box r
    private func freeform(_ cust: XMLElement, _ r: CGRect) -> NSBezierPath? {
        let shapeW = r.width / k, shapeH = r.height / k   // the shape's own size, in EMU
        var guides = Guides(w: shapeW, h: shapeH)
        for gd in cust.child("avLst")?.childElements ?? [] { guides.add(gd.attr("name"), gd.attr("fmla")) }
        for gd in cust.child("gdLst")?.childElements ?? [] { guides.add(gd.attr("name"), gd.attr("fmla")) }

        let result = NSBezierPath()
        for path in cust.child("pathLst")?.childElements ?? [] where path.localName == "path" {
            // each path has its own units; stretch them to the box
            let pw = number(path, "w") ?? shapeW, ph = number(path, "h") ?? shapeH
            let sx = pw > 0 ? r.width / pw : k, sy = ph > 0 ? r.height / ph : k
            func point(_ pt: XMLElement?) -> CGPoint {
                CGPoint(x: r.minX + guides.value(pt?.attr("x")) * sx, y: r.minY + guides.value(pt?.attr("y")) * sy)
            }
            var current = CGPoint(x: r.minX, y: r.minY)
            for cmd in path.childElements {
                let pts = cmd.childElements.filter { $0.localName == "pt" }
                switch cmd.localName {
                case "moveTo": current = point(pts.first); result.move(to: current)
                case "lnTo": current = point(pts.first); result.line(to: current)
                case "cubicBezTo" where pts.count == 3:
                    current = point(pts[2])
                    result.curve(to: current, controlPoint1: point(pts[0]), controlPoint2: point(pts[1]))
                case "quadBezTo" where pts.count == 2:
                    let c = point(pts[0]); let end = point(pts[1])
                    result.curve(to: end, controlPoint1: CGPoint(x: current.x + 2 / 3 * (c.x - current.x), y: current.y + 2 / 3 * (c.y - current.y)),
                                 controlPoint2: CGPoint(x: end.x + 2 / 3 * (c.x - end.x), y: end.y + 2 / 3 * (c.y - end.y)))
                    current = end
                case "arcTo":
                    // an arc of an ellipse, starting at the current point
                    let wR = guides.value(cmd.attr("wR")) * sx, hR = guides.value(cmd.attr("hR")) * sy
                    let start = guides.value(cmd.attr("stAng")) / 60000 * .pi / 180
                    let swing = guides.value(cmd.attr("swAng")) / 60000 * .pi / 180
                    let center = CGPoint(x: current.x - wR * cos(start), y: current.y - hR * sin(start))
                    let steps = max(Int(abs(swing) / (.pi / 16)), 1)
                    for i in 1...steps {
                        let a = start + swing * CGFloat(i) / CGFloat(steps)
                        current = CGPoint(x: center.x + wR * cos(a), y: center.y + hR * sin(a))
                        if result.isEmpty { result.move(to: current) } else { result.line(to: current) }
                    }
                case "close": result.close()
                default: break
                }
            }
        }
        return result.isEmpty ? nil : result
    }

    private func connector(_ cxn: XMLElement, _ place: Place) {
        guard let spPr = cxn.child("spPr"), let r = box(spPr.child("xfrm"), place) else { return }
        let xfrm = spPr.child("xfrm")
        let ln = spPr.child("ln")
        guard let c = color(ln?.child("solidFill")) ?? color(cxn.child("style")?.child("lnRef")) else { return }
        let flipH = xfrm?.attr("flipH") == "1", flipV = xfrm?.attr("flipV") == "1"
        let p = NSBezierPath()
        p.move(to: CGPoint(x: flipH ? r.maxX : r.minX, y: flipV ? r.maxY : r.minY))
        p.line(to: CGPoint(x: flipH ? r.minX : r.maxX, y: flipV ? r.minY : r.maxY))
        p.lineWidth = (number(ln, "w") ?? 12700) * k
        c.setStroke()
        p.stroke()
    }

    // A picture fill: a:blip with optional cropping (a:srcRect), optionally cut to a shape
    private func picture(_ blipFill: XMLElement, _ rels: [String: String], _ r: CGRect, clip: NSBezierPath?) {
        guard let embed = blipFill.child("blip")?.attr("r:embed") ?? blipFill.child("blip")?.attr("embed"),
              let path = rels[embed], let data = zip.data(path),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2000
              ] as CFDictionary) else { return }
        let crop = blipFill.child("srcRect")
        func cut(_ n: String) -> CGFloat { (number(crop, n) ?? 0) / 100000 }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        // NSImage counts from the bottom-left corner
        let from = CGRect(x: w * cut("l"), y: h * cut("b"), width: w * (1 - cut("l") - cut("r")), height: h * (1 - cut("t") - cut("b")))
        guard from.width > 0, from.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        clip?.addClip()
        NSImage(cgImage: cg, size: CGSize(width: w, height: h))
            .draw(in: r, from: from, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func table(_ tbl: XMLElement, _ r: CGRect) {
        guard let grid = tbl.child("tblGrid") else { return }
        let widths = grid.childElements.map { number($0, "w") ?? 0 }
        var y = r.minY
        for tr in tbl.childElements where tr.localName == "tr" {
            var x = r.minX
            let rowH = (number(tr, "h") ?? 370_840) * k
            var col = 0
            for tc in tr.childElements where tc.localName == "tc" {
                let span = tc.attr("gridSpan").flatMap(Int.init) ?? 1
                let w = (col..<min(col + span, widths.count)).reduce(0) { $0 + widths[$1] } * k
                let cell = CGRect(x: x, y: y, width: w, height: rowH)
                if tc.attr("hMerge") != "1" && tc.attr("vMerge") != "1" {
                    if let c = color(tc.child("tcPr")?.child("solidFill")) { c.setFill(); cell.fill() }
                    NSColor(srgbRed: 0x9E / 255, green: 0x9E / 255, blue: 0x9E / 255, alpha: 1).setStroke()
                    let border = NSBezierPath(rect: cell)
                    border.lineWidth = 0.75
                    border.stroke()
                    if let body = tc.child("txBody") {
                        text(body, cell, styles: [masterStyles?.child("otherStyle")].compactMap { $0 }, templateBodyPr: nil, isTitle: false, baseColor: nil)
                    }
                }
                x += w
                col += span
            }
            y += rowH
        }
    }

    // MARK: Text

    // Text of a shape, laid out inside its box. `styles` are lists of level styles (a:lvl1pPr ...),
    // most important first: the first one that sets something wins.
    private func text(_ body: XMLElement, _ r: CGRect, styles: [XMLElement], templateBodyPr: XMLElement?, isTitle: Bool, baseColor: NSColor?) {
        let bodyPr = body.child("bodyPr")
        func inset(_ n: String, _ d: CGFloat) -> CGFloat { (number(bodyPr, n) ?? number(templateBodyPr, n) ?? d) * k }
        let left = inset("lIns", 91440), right = inset("rIns", 91440), top = inset("tIns", 45720), bottom = inset("bIns", 45720)
        let anchor = bodyPr?.attr("anchor") ?? templateBodyPr?.attr("anchor") ?? (isTitle ? "ctr" : "t")
        let fontScale = (number(bodyPr?.child("normAutofit"), "fontScale") ?? 100000) / 100000

        let out = NSMutableAttributedString()
        var counter = 0
        for (i, p) in body.childElements.filter({ $0.localName == "p" }).enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            let start = out.length
            let pPr = p.child("pPr")
            let level = min(pPr?.attr("lvl").flatMap(Int.init) ?? 0, 8)
            // this paragraph's level style in each list
            let levelStyles = [pPr].compactMap { $0 } + styles.compactMap { $0.child("lvl\(level + 1)pPr") }
            let defaults = levelStyles.compactMap { $0.child("defRPr") }

            func runAttributes(_ rPr: XMLElement?) -> (attributes: [NSAttributedString.Key: Any], caps: Bool) {
                let props = [rPr].compactMap { $0 } + defaults
                let size = max((props.lazy.compactMap { number($0, "sz") }.first.map { $0 / 100 } ?? 18) * fontScale, 1)
                let bold = props.lazy.compactMap { $0.attr("b") }.first == "1"
                let italic = props.lazy.compactMap { $0.attr("i") }.first == "1"
                let caps = props.lazy.compactMap { $0.attr("cap") }.first.map { $0 == "all" || $0 == "small" } ?? false
                let typeface = props.lazy.compactMap { $0.child("latin")?.attr("typeface") }.first ?? (isTitle ? "+mj-lt" : "+mn-lt")
                let colour = props.lazy.compactMap { self.color($0.child("solidFill")) }.first ?? baseColor ?? resolve("tx1") ?? .black
                var attributes: [NSAttributedString.Key: Any] = [.font: font(typeface, size: size, bold: bold, italic: italic), .foregroundColor: colour]
                if let u = props.lazy.compactMap({ $0.attr("u") }).first, u != "none" { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                return (attributes, caps)
            }

            let plain = runAttributes(nil).attributes
            if let bullet = pPr?.child("buChar")?.attr("char") {
                out.append(NSAttributedString(string: String(repeating: "    ", count: level) + bullet + " ", attributes: plain))
            }
            if pPr?.child("buAutoNum") != nil {
                counter += 1
                out.append(NSAttributedString(string: String(repeating: "    ", count: level) + "\(counter). ", attributes: plain))
            }
            for item in p.childElements {
                var piece: String
                switch item.localName {
                case "r", "fld": piece = item.child("t")?.stringValue ?? ""
                case "br": piece = "\u{2028}"   // a line break inside the paragraph
                default: continue
                }
                if piece.isEmpty { continue }
                let run = runAttributes(item.child("rPr"))
                if run.caps { piece = piece.uppercased() }
                out.append(NSAttributedString(string: piece, attributes: run.attributes))
            }
            if out.length == start {
                out.append(NSAttributedString(string: " ", attributes: runAttributes(p.child("endParaRPr")).attributes))   // an empty line keeps its height
            }
            let style = NSMutableParagraphStyle()
            let spacing = levelStyles.lazy.compactMap { number($0.child("lnSpc")?.child("spcPct"), "val") }.first
            style.lineHeightMultiple = spacing.map { $0 / 100000 } ?? 1
            switch levelStyles.lazy.compactMap({ $0.attr("algn") }).first {
            case "ctr": style.alignment = .center
            case "r": style.alignment = .right
            case "just": style.alignment = .justified
            default: style.alignment = .left
            }
            out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
        }
        if out.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }

        let width = max(r.width - left - right, 1)
        let height = out.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let boxH = r.height - top - bottom
        let y: CGFloat
        switch anchor {
        case "ctr": y = r.minY + top + (boxH - height) / 2
        case "b": y = r.maxY - bottom - height
        default: y = r.minY + top
        }
        out.draw(with: CGRect(x: r.minX + left, y: y, width: width, height: height + 2),
                 options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    // The theme's fonts ("+mj-lt" = headings, "+mn-lt" = body), or a named font; the Mac's own font if it isn't installed
    private func font(_ typeface: String, size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        let name: String?
        switch typeface {
        case "+mj-lt": name = majorFont
        case "+mn-lt": name = minorFont
        default: name = typeface
        }
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        if let name, let f = NSFontManager.shared.font(withFamily: name, traits: traits, weight: 5, size: size) ?? NSFont(name: name, size: size) {
            return f
        }
        var f = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    // MARK: Colours

    // The colour inside a fill element (srgbClr, schemeClr, sysClr or prstClr), with brightness changes
    private func color(_ holder: XMLElement?) -> NSColor? {
        guard let c = holder?.childElements.first else { return nil }
        var base: NSColor?
        switch c.localName {
        case "srgbClr": base = hexColor(c.attr("val"))
        case "schemeClr": base = c.attr("val").flatMap(resolve)
        case "sysClr": base = hexColor(c.attr("lastClr"))
        case "prstClr": base = c.attr("val") == "black" ? .black : (c.attr("val") == "white" ? .white : nil)
        default: base = nil
        }
        guard var result = base?.usingColorSpace(.sRGB) else { return nil }
        let lumMod = number(c.child("lumMod"), "val").map { $0 / 100000 }
        let lumOff = number(c.child("lumOff"), "val").map { $0 / 100000 }
        if lumMod != nil || lumOff != nil {
            var (h, s, l) = toHSL(result)
            l = min(max(l * (lumMod ?? 1) + (lumOff ?? 0), 0), 1)
            result = fromHSL(h, s, l)
        }
        if let a = number(c.child("alpha"), "val") { result = result.withAlphaComponent(min(max(a / 100000, 0), 1)) }
        return result
    }

    // "tx1" -> a theme colour, using the colour map (which a layout can swap)
    private func resolve(_ name: String) -> NSColor? {
        let mapped = colorMap[name] ?? ["tx1": "dk1", "bg1": "lt1", "tx2": "dk2", "bg2": "lt2"][name] ?? name
        return themeColors[mapped]
    }
}

// MARK: - Freeform shape formulas

// Works out the named values ("guides") of a freeform shape, like "*/ 4602990 w 6538195"
private struct Guides {
    private var values: [String: CGFloat]

    init(w: CGFloat, h: CGFloat) {
        let ss = min(w, h)
        values = ["w": w, "h": h, "l": 0, "t": 0, "r": w, "b": h, "hc": w / 2, "vc": h / 2,
                  "wd2": w / 2, "hd2": h / 2, "wd4": w / 4, "hd4": h / 4, "wd8": w / 8, "hd8": h / 8,
                  "ss": ss, "ssd2": ss / 2, "ssd4": ss / 4, "ssd8": ss / 8, "ls": max(w, h),
                  "cd2": 10_800_000, "cd4": 5_400_000, "cd8": 2_700_000, "3cd4": 16_200_000]
    }

    // A plain number or the name of a value worked out before
    func value(_ s: String?) -> CGFloat {
        guard let s else { return 0 }
        if let v = Double(s) { return CGFloat(v) }
        return values[s] ?? 0
    }

    mutating func add(_ name: String?, _ formula: String?) {
        guard let name, let formula else { return }
        let parts = formula.split(separator: " ").map(String.init)
        guard let op = parts.first else { return }
        let a = parts.count > 1 ? value(parts[1]) : 0
        let b = parts.count > 2 ? value(parts[2]) : 0
        let c = parts.count > 3 ? value(parts[3]) : 0
        let result: CGFloat
        switch op {
        case "val": result = a
        case "*/": result = c != 0 ? a * b / c : 0
        case "+-": result = a + b - c
        case "+/": result = c != 0 ? (a + b) / c : 0
        case "?:": result = a > 0 ? b : c
        case "abs": result = abs(a)
        case "max": result = max(a, b)
        case "min": result = min(a, b)
        case "pin": result = b < a ? a : (b > c ? c : b)
        case "sqrt": result = sqrt(max(a, 0))
        case "mod": result = sqrt(a * a + b * b + c * c)
        case "sin": result = a * sin(b / 60000 * .pi / 180)
        case "cos": result = a * cos(b / 60000 * .pi / 180)
        case "tan": result = a * tan(b / 60000 * .pi / 180)
        case "at2": result = atan2(b, a) * 180 / .pi * 60000
        case "cat2": result = a * cos(atan2(c, b))
        case "sat2": result = a * sin(atan2(c, b))
        default: result = 0
        }
        values[name] = result
    }
}

private func hexColor(_ hex: String?) -> NSColor? {
    guard let hex, hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

// Hue, saturation, lightness (PowerPoint changes brightness this way)
private func toHSL(_ c: NSColor) -> (CGFloat, CGFloat, CGFloat) {
    let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
    let maxV = max(r, g, b), minV = min(r, g, b)
    let l = (maxV + minV) / 2
    guard maxV != minV else { return (0, 0, l) }
    let d = maxV - minV
    let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
    var h: CGFloat
    if maxV == r { h = (g - b) / d + (g < b ? 6 : 0) } else if maxV == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
    h /= 6
    return (h, s, l)
}

private func fromHSL(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat) -> NSColor {
    guard s > 0 else { return NSColor(srgbRed: l, green: l, blue: l, alpha: 1) }
    func hue(_ p: CGFloat, _ q: CGFloat, _ t0: CGFloat) -> CGFloat {
        var t = t0
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1 / 6 { return p + (q - p) * 6 * t }
        if t < 1 / 2 { return q }
        if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
        return p
    }
    let q = l < 0.5 ? l * (1 + s) : l + s - l * s
    let p = 2 * l - q
    return NSColor(srgbRed: hue(p, q, h + 1 / 3), green: hue(p, q, h), blue: hue(p, q, h - 1 / 3), alpha: 1)
}
