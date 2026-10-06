import AppKit
import PDFKit

// Makes Excel and PowerPoint files (same files as Android OfficeWriters.kt).
// These files are zip folders full of XML; we write the parts, then zip them.

private let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
private let relTypes = "http://schemas.openxmlformats.org/package/2006/relationships"
private let docRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

private func rootRels(_ target: String) -> String {
    xmlHeader + "<Relationships xmlns=\"\(relTypes)\"><Relationship Id=\"rId1\" Type=\"\(docRel)/officeDocument\" Target=\"\(target)\"/></Relationships>"
}

func officeEscape(_ text: String) -> String {
    var out = ""
    for c in text.unicodeScalars {
        switch c {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        default:
            if c.value >= 0x20 || c == "\t" || c == "\n" { out.unicodeScalars.append(c) }
        }
    }
    return out
}

// Writes the parts into a temporary folder, then zips them with the Mac's own zip tool
func writeZip(_ files: [(path: String, data: Data)], to url: URL) -> Bool {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
        for file in files {
            let target = folder.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: target)
        }
        let zipped = folder.appendingPathComponent("out.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = folder
        zip.arguments = ["-X", "-q", "-r", zipped.path] + files.map(\.path)
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { return false }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: zipped, to: url)
        return true
    } catch {
        return false
    }
}

private extension String {
    var utf8Data: Data { Data(utf8) }
}

// MARK: - Finding table columns on a PDF page

// Each line of the page, split into cells where there is a big gap between words (like Android).
// What counts as "big" is measured on each line itself (its normal spaces and letter widths),
// so it works for any text size.
func pageRows(_ page: PDFPage) -> [[String]] {
    guard let string = page.string, !string.isEmpty else { return [] }
    let text = string as NSString

    // 1. The letters of each line, with where they sit
    struct Letter { let text: String; let minX: CGFloat; let maxX: CGFloat; let spaceBefore: Bool }
    var lines: [[Letter]] = [[]]
    var spaceBefore = false
    for i in 0..<text.length {
        let c = text.character(at: i)
        if c == 0x0A || c == 0x0D { lines.append([]); spaceBefore = false; continue }
        if c == 0x20 || c == 0x09 || c == 0xA0 { spaceBefore = true; continue }
        // A one-letter selection gives the letter's real box. (characterBounds(at:) can be
        // one letter off from page.string, which mixes up the gaps.)
        guard let box = page.selection(for: NSRange(location: i, length: 1))?.bounds(for: page) else { continue }
        lines[lines.count - 1].append(Letter(text: String(utf16CodeUnits: [c], count: 1),
                                             minX: box.minX, maxX: box.maxX, spaceBefore: spaceBefore))
        spaceBefore = false
    }

    // 2. Split each line where the gap is much bigger than a normal space on that line
    var rows: [[String]] = []
    for letters in lines where !letters.isEmpty {
        let widths = letters.map { $0.maxX - $0.minX }.filter { $0 > 0 }
        let letterWidth = widths.isEmpty ? 5 : widths.reduce(0, +) / CGFloat(widths.count)
        let spaceGaps = zip(letters.dropFirst(), letters).filter { $0.0.spaceBefore }.map { $0.0.minX - $0.1.maxX }.filter { $0 > 0 }.sorted()
        // A normal space: from the smaller spaces on the line (big column gaps can't fool it),
        // or from the letter width when the line has only a few spaces (like a short table row)
        let normalSpace = spaceGaps.count < 3 ? letterWidth * 0.5 : spaceGaps[spaceGaps.count / 4]
        let columnGap = max(normalSpace * 2.5, letterWidth * 2.5)

        var cells: [String] = []
        var cell = ""
        var lastEnd: CGFloat?
        for letter in letters {
            if let end = lastEnd {
                let gap = letter.minX - end
                if gap > columnGap {
                    cells.append(cell)   // a big gap starts a new column
                    cell = ""
                } else if letter.spaceBefore {
                    cell += " "
                }
            }
            cell += letter.text
            lastEnd = letter.maxX
        }
        cells.append(cell)
        rows.append(cells.map { $0.trimmingCharacters(in: .whitespaces) })
    }
    return rows
}

// MARK: - Excel (.xlsx)

// 0 -> "A", 25 -> "Z", 26 -> "AA"
func columnName(_ index: Int) -> String {
    var n = index + 1
    var name = ""
    while n > 0 {
        let rem = (n - 1) % 26
        name = String(UnicodeScalar(65 + rem)!) + name
        n = (n - 1) / 26
    }
    return name
}

// Each page becomes a sheet; each line a row; big gaps between words become new columns
func writeXlsx(_ sheets: [[[String]]], to url: URL) -> Bool {
    var files: [(path: String, data: Data)] = []
    let number = try! NSRegularExpression(pattern: "^-?\\d{1,15}(\\.\\d+)?$")

    for (s, rows) in sheets.enumerated() {
        var xml = xmlHeader + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
        for (r, cells) in rows.enumerated() {
            xml += "<row r=\"\(r + 1)\">"
            for (c, value) in cells.enumerated() where !value.isEmpty {
                let ref = columnName(c) + "\(r + 1)"
                let isNumber = number.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
                // keep leading zeros (like phone numbers "0123") as text
                let keepAsText = value.count > 1 && value.hasPrefix("0") && !value.hasPrefix("0.")
                if isNumber && !keepAsText {
                    xml += "<c r=\"\(ref)\"><v>\(value)</v></c>"
                } else {
                    xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(officeEscape(value))</t></is></c>"
                }
            }
            xml += "</row>"
        }
        xml += "</sheetData></worksheet>"
        files.append(("xl/worksheets/sheet\(s + 1).xml", xml.utf8Data))
    }

    let ids = sheets.indices
    let sheetList = ids.map { "<sheet name=\"Page \($0 + 1)\" sheetId=\"\($0 + 1)\" r:id=\"rId\($0 + 1)\"/>" }.joined()
    let sheetRels = ids.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"\(docRel)/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined()
    let overrides = ids.map {
        "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
    }.joined()

    let parts: [(path: String, data: Data)] = [
        ("[Content_Types].xml", (xmlHeader +
            "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" +
            "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" +
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
            "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>" +
            overrides + "</Types>").utf8Data),
        ("_rels/.rels", rootRels("xl/workbook.xml").utf8Data),
        ("xl/workbook.xml", (xmlHeader +
            "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"\(docRel)\">" +
            "<sheets>\(sheetList)</sheets></workbook>").utf8Data),
        ("xl/_rels/workbook.xml.rels", (xmlHeader + "<Relationships xmlns=\"\(relTypes)\">\(sheetRels)</Relationships>").utf8Data)
    ]
    return writeZip(parts + files, to: url)
}

// MARK: - PowerPoint (.pptx)

// Each page becomes one slide showing the page as a picture (so it looks exactly the same).
// Sizes are in EMU (12700 per point).
func writePptx(_ slideImages: [Data], slideWidth w: Int, slideHeight h: Int, to url: URL) -> Bool {
    let p = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"\(docRel)\" " +
        "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
    let emptyTree = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>" +
        "<p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
    var files: [(path: String, data: Data)] = []

    for (i, jpeg) in slideImages.enumerated() {
        let n = i + 1
        files.append(("ppt/media/image\(n).jpeg", jpeg))
        files.append(("ppt/slides/slide\(n).xml", (xmlHeader +
            "<p:sld \(p)><p:cSld><p:spTree>\(emptyTree)" +
            "<p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"Page \(n)\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>" +
            "<p:blipFill><a:blip r:embed=\"rId2\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>" +
            "<p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(w)\" cy=\"\(h)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr>" +
            "</p:pic></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>").utf8Data))
        files.append(("ppt/slides/_rels/slide\(n).xml.rels", (xmlHeader + "<Relationships xmlns=\"\(relTypes)\">" +
            "<Relationship Id=\"rId1\" Type=\"\(docRel)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>" +
            "<Relationship Id=\"rId2\" Type=\"\(docRel)/image\" Target=\"../media/image\(n).jpeg\"/>" +
            "</Relationships>").utf8Data))
    }

    let ids = slideImages.indices
    let slideIds = ids.map { "<p:sldId id=\"\(256 + $0)\" r:id=\"rId\($0 + 3)\"/>" }.joined()
    let slideRels = ids.map { "<Relationship Id=\"rId\($0 + 3)\" Type=\"\(docRel)/slide\" Target=\"slides/slide\($0 + 1).xml\"/>" }.joined()
    let slideTypes = ids.map {
        "<Override PartName=\"/ppt/slides/slide\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
    }.joined()
    let solid = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
    let theme = xmlHeader +
        "<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"Office Theme\"><a:themeElements>" +
        "<a:clrScheme name=\"Office\">" +
        "<a:dk1><a:sysClr val=\"windowText\" lastClr=\"000000\"/></a:dk1><a:lt1><a:sysClr val=\"window\" lastClr=\"FFFFFF\"/></a:lt1>" +
        "<a:dk2><a:srgbClr val=\"44546A\"/></a:dk2><a:lt2><a:srgbClr val=\"E7E6E6\"/></a:lt2>" +
        "<a:accent1><a:srgbClr val=\"4472C4\"/></a:accent1><a:accent2><a:srgbClr val=\"ED7D31\"/></a:accent2>" +
        "<a:accent3><a:srgbClr val=\"A5A5A5\"/></a:accent3><a:accent4><a:srgbClr val=\"FFC000\"/></a:accent4>" +
        "<a:accent5><a:srgbClr val=\"5B9BD5\"/></a:accent5><a:accent6><a:srgbClr val=\"70AD47\"/></a:accent6>" +
        "<a:hlink><a:srgbClr val=\"0563C1\"/></a:hlink><a:folHlink><a:srgbClr val=\"954F72\"/></a:folHlink></a:clrScheme>" +
        "<a:fontScheme name=\"Office\"><a:majorFont><a:latin typeface=\"Calibri Light\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont>" +
        "<a:minorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme>" +
        "<a:fmtScheme name=\"Office\"><a:fillStyleLst>\(solid)\(solid)\(solid)</a:fillStyleLst>" +
        "<a:lnStyleLst>" + String(repeating: "<a:ln w=\"6350\">\(solid)</a:ln>", count: 3) + "</a:lnStyleLst>" +
        "<a:effectStyleLst>" + String(repeating: "<a:effectStyle><a:effectLst/></a:effectStyle>", count: 3) + "</a:effectStyleLst>" +
        "<a:bgFillStyleLst>\(solid)\(solid)\(solid)</a:bgFillStyleLst></a:fmtScheme>" +
        "</a:themeElements></a:theme>"

    let parts: [(path: String, data: Data)] = [
        ("[Content_Types].xml", (xmlHeader +
            "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" +
            "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" +
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
            "<Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/>" +
            "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/>" +
            "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/>" +
            "<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/>" +
            "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>" +
            slideTypes + "</Types>").utf8Data),
        ("_rels/.rels", rootRels("ppt/presentation.xml").utf8Data),
        ("ppt/presentation.xml", (xmlHeader +
            "<p:presentation \(p) saveSubsetFonts=\"1\">" +
            "<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst>" +
            "<p:sldIdLst>\(slideIds)</p:sldIdLst>" +
            "<p:sldSz cx=\"\(w)\" cy=\"\(h)\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/>" +
            "</p:presentation>").utf8Data),
        ("ppt/_rels/presentation.xml.rels", (xmlHeader + "<Relationships xmlns=\"\(relTypes)\">" +
            "<Relationship Id=\"rId1\" Type=\"\(docRel)/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>" +
            "<Relationship Id=\"rId2\" Type=\"\(docRel)/theme\" Target=\"theme/theme1.xml\"/>" +
            slideRels + "</Relationships>").utf8Data),
        ("ppt/slideMasters/slideMaster1.xml", (xmlHeader +
            "<p:sldMaster \(p)><p:cSld><p:spTree>\(emptyTree)</p:spTree></p:cSld>" +
            "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" " +
            "accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>" +
            "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst></p:sldMaster>").utf8Data),
        ("ppt/slideMasters/_rels/slideMaster1.xml.rels", (xmlHeader + "<Relationships xmlns=\"\(relTypes)\">" +
            "<Relationship Id=\"rId1\" Type=\"\(docRel)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>" +
            "<Relationship Id=\"rId2\" Type=\"\(docRel)/theme\" Target=\"../theme/theme1.xml\"/>" +
            "</Relationships>").utf8Data),
        ("ppt/slideLayouts/slideLayout1.xml", (xmlHeader +
            "<p:sldLayout \(p) type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(emptyTree)</p:spTree></p:cSld>" +
            "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>").utf8Data),
        ("ppt/slideLayouts/_rels/slideLayout1.xml.rels", (xmlHeader + "<Relationships xmlns=\"\(relTypes)\">" +
            "<Relationship Id=\"rId1\" Type=\"\(docRel)/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/>" +
            "</Relationships>").utf8Data),
        ("ppt/theme/theme1.xml", theme.utf8Data)
    ]
    return writeZip(parts + files, to: url)
}

// Slide size from the first page's shape; the long side is 13.33 inches (like Android)
func slideSize(for document: PDFDocument) -> (width: Int, height: Int, pictureWidth: Int) {
    var ratio: CGFloat = 4.0 / 3.0
    if let page = document.page(at: 0) {
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let w = turned ? box.height : box.width, h = turned ? box.width : box.height
        if h > 0 { ratio = w / h }
    }
    let long: CGFloat = 12_192_000
    let (w, h) = ratio >= 1 ? (long, long / ratio) : (long * ratio, long)
    let clamp = { (v: CGFloat) in Int(min(max(v.rounded(), 914_400), 51_206_400)) }
    return (clamp(w), clamp(h), ratio >= 1 ? 1920 : 1300)
}
