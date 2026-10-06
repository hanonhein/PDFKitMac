import AppKit
import PDFKit

// MARK: - Reading the words of a PDF (same rules as Android PdfText.kt)

// The words of one page, line by line
struct PageText {
    let lines: [String]
    let width: CGFloat
    let height: CGFloat

    // Joins lines into paragraphs: an empty line, a list item or a short line ends a paragraph
    func paragraphs() -> [String] {
        guard !lines.isEmpty else { return [] }
        let longest = max(lines.map(\.count).max() ?? 1, 1)
        var result: [String] = []
        var current = ""
        let listStart = try! NSRegularExpression(pattern: "^(\\d+|[a-zA-Z])[.)]\\s")

        for (i, raw) in lines.enumerated() {
            let line = raw.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.isEmpty { result.append(current) }
                current = ""
                continue
            }
            let startsList = "•●▪◦-–*".contains(line.first!) ||
                listStart.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
            if !current.isEmpty && startsList {
                result.append(current)
                current = ""
            }
            if current.isEmpty {
                current = line
            } else if current.hasSuffix("-"), line.first!.isLowercase {
                current.removeLast()   // a word cut at the end of the line
                current += line
            } else {
                current += " " + line
            }
            // a short line ends its paragraph (the text stopped before the edge)
            let isShort = Double(raw.trimmingCharacters(in: .whitespaces).count) < Double(longest) * 0.6
            if isShort && i < lines.count - 1 {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

func readPages(_ document: PDFDocument) -> [PageText] {
    (0..<document.pageCount).compactMap { document.page(at: $0) }.map { page in
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let lines = (page.string ?? "").components(separatedBy: .newlines)
        return PageText(lines: lines, width: turned ? box.height : box.width, height: turned ? box.width : box.height)
    }
}

// MARK: - Writing RTF, HTML and XML (same files as Android OfficeWriters.kt)

private func xmlEscape(_ text: String) -> String {
    var out = ""
    for c in text.unicodeScalars {
        switch c {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&apos;"
        default:
            // characters XML doesn't allow are left out
            if c.value >= 0x20 || c == "\t" || c == "\n" || c == "\r" { out.unicodeScalars.append(c) }
        }
    }
    return out
}

// RTF files are plain ASCII: other letters are written as \uNNNN?
private func rtfEscape(_ text: String) -> String {
    var out = ""
    for unit in text.utf16 {
        switch unit {
        case 0x5C: out += "\\\\"
        case 0x7B: out += "\\{"
        case 0x7D: out += "\\}"
        case 0x09: out += "\\tab "
        case 32...126: out.unicodeScalars.append(Unicode.Scalar(unit)!)
        case 0..<32: break
        default: out += "\\u\(Int16(bitPattern: unit))?"
        }
    }
    return out
}

func pagesToRtf(_ pages: [PageText]) -> String {
    var s = "{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0\\fswiss Arial;}}\\uc1\\f0\\fs22\n"
    for (i, page) in pages.enumerated() {
        if i > 0 { s += "\\page\n" }
        for p in page.paragraphs() { s += "\\pard\\sa160 \(rtfEscape(p))\\par\n" }
    }
    return s + "}"
}

func pagesToHtml(_ pages: [PageText], title: String) -> String {
    var s = "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n"
    s += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
    s += "<title>\(xmlEscape(title))</title>\n"
    s += "<style>body{font-family:system-ui,sans-serif;max-width:46em;margin:2em auto;padding:0 1em;line-height:1.55;color:#202124}"
    s += "section{border-bottom:1px solid #ddd;padding-bottom:1.5em;margin-bottom:1.5em}h2{font-size:.8em;color:#777;font-weight:600}</style>\n"
    s += "</head>\n<body>\n"
    for (i, page) in pages.enumerated() {
        s += "<section id=\"page-\(i + 1)\">\n<h2>Page \(i + 1)</h2>\n"
        for p in page.paragraphs() { s += "<p>\(xmlEscape(p).replacingOccurrences(of: "\t", with: " "))</p>\n" }
        s += "</section>\n"
    }
    return s + "</body>\n</html>\n"
}

func pagesToXml(_ pages: [PageText], title: String) -> String {
    var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    s += "<document title=\"\(xmlEscape(title))\" pages=\"\(pages.count)\">\n"
    for (i, page) in pages.enumerated() {
        s += "  <page number=\"\(i + 1)\" width=\"\(Int(page.width.rounded()))\" height=\"\(Int(page.height.rounded()))\">\n"
        for p in page.paragraphs() { s += "    <paragraph>\(xmlEscape(p))</paragraph>\n" }
        s += "  </page>\n"
    }
    return s + "</document>\n"
}

// MARK: - Making a PDF from text (same page size, margins and spacing as Android RichPdf.kt)

let a4Size = CGSize(width: 595, height: 842)
let pageMargin: CGFloat = 56

// Plain text in the normal style: 11 point, a little space between lines
func plainTextStyle(_ text: String) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.lineHeightMultiple = 1.15
    return NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black, .paragraphStyle: style
    ])
}

// Lays the text out on as many A4 pages as it needs and saves the PDF
func attributedTextToPdf(_ text: NSAttributedString, to url: URL) -> Bool {
    // Text without its own colour would follow dark mode; on paper it must be black
    let fixed = NSMutableAttributedString(attributedString: text)
    fixed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: fixed.length)) { value, range, _ in
        if value == nil { fixed.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
    }
    let storage = NSTextStorage(attributedString: fixed)
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)

    // One text box per page, until all the text fits
    let boxSize = CGSize(width: a4Size.width - pageMargin * 2, height: a4Size.height - pageMargin * 2)
    var boxes: [NSTextContainer] = []
    repeat {
        let box = NSTextContainer(size: boxSize)
        box.lineFragmentPadding = 0
        layout.addTextContainer(box)
        boxes.append(box)
        layout.ensureLayout(for: box)
    } while NSMaxRange(layout.glyphRange(for: boxes.last!)) < layout.numberOfGlyphs && boxes.count < 5000

    let data = NSMutableData()
    var mediaBox = CGRect(origin: .zero, size: a4Size)
    guard let consumer = CGDataConsumer(data: data),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return false }
    for box in boxes {
        context.beginPDFPage(nil)
        // Text is laid out from the top down, PDF pages count from the bottom up
        context.translateBy(x: 0, y: a4Size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let range = layout.glyphRange(for: box)
        let origin = CGPoint(x: pageMargin, y: pageMargin)
        layout.drawBackground(forGlyphRange: range, at: origin)
        layout.drawGlyphs(forGlyphRange: range, at: origin)
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
    }
    context.closePDF()
    return (try? (data as Data).write(to: url)) != nil
}

// Opens an RTF or Word file with its bold, italic, sizes and page breaks (the Mac reads these by itself)
func readStyledFile(_ url: URL) -> NSAttributedString? {
    let hasAccess = url.startAccessingSecurityScopedResource()
    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
    let type: NSAttributedString.DocumentType
    switch url.pathExtension.lowercased() {
    case "docx": type = .officeOpenXML
    case "doc": type = .docFormat
    default: type = .rtf
    }
    guard let text = try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil) else { return nil }
    if type == .officeOpenXML {
        let fixed = NSMutableAttributedString(attributedString: text)
        restoreCellColors(from: url, in: fixed)
        return fixed
    }
    return text
}

// The Mac's Word reader keeps tables but forgets the cells' background colours
// (so white text on a blue header becomes invisible). We read the colours from the
// Word file ourselves and give them back to the cells, in the same order.
func restoreCellColors(from docx: URL, in text: NSMutableAttributedString) {
    // A .docx is a zip; the text is in word/document.xml
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-p", docx.path, "word/document.xml"]
    let pipe = Pipe()
    unzip.standardOutput = pipe
    unzip.standardError = FileHandle.nullDevice
    guard (try? unzip.run()) != nil else { return }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    unzip.waitUntilExit()
    guard let xml = try? XMLDocument(data: data),
          let cells = try? xml.nodes(forXPath: "//*[local-name()='tc']") else { return }

    // Each cell's fill colour, like "2E75B6" (nil = no colour)
    let fills: [NSColor?] = cells.map { cell in
        guard let shading = try? cell.nodes(forXPath: "./*[local-name()='tcPr']/*[local-name()='shd']").first as? XMLElement,
              let fill = shading.attributes?.first(where: { $0.localName == "fill" })?.stringValue,
              fill.count == 6, let value = UInt32(fill, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    // The table cells the Mac made, in the order they appear
    var blocks: [NSTextTableBlock] = []
    var seen = Set<ObjectIdentifier>()
    text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
        for case let block as NSTextTableBlock in (value as? NSParagraphStyle)?.textBlocks ?? [] {
            if seen.insert(ObjectIdentifier(block)).inserted { blocks.append(block) }
        }
    }

    // Only when every cell matches up; otherwise colours could land on the wrong cells
    guard blocks.count == fills.count else { return }
    for (block, fill) in zip(blocks, fills) {
        if let fill { block.backgroundColor = fill }
    }
}

// The words of the PDF as a Word document: one paragraph per paragraph, a page break between pages
func pagesToWord(_ pages: [PageText]) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.paragraphSpacing = 8
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .paragraphStyle: style]
    let text = NSMutableAttributedString()
    for (i, page) in pages.enumerated() {
        if i > 0 { text.append(NSAttributedString(string: "\u{000C}", attributes: attributes)) }   // page break
        for p in page.paragraphs() { text.append(NSAttributedString(string: p + "\n", attributes: attributes)) }
    }
    return text
}

func writeDocx(_ text: NSAttributedString, to url: URL) -> Bool {
    guard let data = try? text.data(from: NSRange(location: 0, length: text.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]) else { return false }
    return (try? data.write(to: url)) != nil
}
