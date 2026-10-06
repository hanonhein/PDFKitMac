import AppKit

// Reads an Excel file (.xlsx): every sheet, as rows of cell texts (like Android ExcelReader.kt).
// Numbers, dates and percents are shown the way they look in Excel (common formats).

struct Sheet {
    let name: String
    let rows: [[String]]
}

private let maxRows = 5000   // per sheet, so huge sheets don't use too much memory

func readExcel(_ url: URL) throws -> [Sheet] {
    let zip = try OfficeZip(url, kindName: "Excel", ext: ".xlsx")
    guard let workbook = zip.xml("xl/workbook.xml") else { throw OfficeError("This is not an Excel (.xlsx) file.") }
    let rels = zip.relations("xl/workbook.xml")
    // Texts are stored once and used by number; rich text is made of pieces
    let shared: [String] = zip.xml("xl/sharedStrings.xml")?.elements("si").map { si in
        si.elements("t").map { $0.stringValue ?? "" }.joined()
    } ?? []
    let formats = NumberFormats(zip)

    let sheets: [Sheet] = workbook.elements("sheet").compactMap { s in
        guard let id = s.attr("r:id") ?? s.attr("id"), let path = rels[id], let doc = zip.xml(path) else { return nil }
        var rows: [[String]] = []
        for row in doc.elements("row") {
            if rows.count >= maxRows { break }
            let rowNumber = row.attr("r").flatMap(Int.init) ?? rows.count + 1
            while rows.count < rowNumber - 1 && rows.count < maxRows { rows.append([]) }   // empty rows in between
            var cells: [String] = []
            for c in row.childElements where c.localName == "c" {
                let col = c.attr("r").map(columnIndex) ?? cells.count
                while cells.count < col { cells.append("") }
                cells.append(cellText(c, shared: shared, formats: formats))
            }
            while let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty { cells.removeLast() }
            rows.append(cells)
        }
        while rows.last?.isEmpty == true { rows.removeLast() }
        return Sheet(name: s.attr("name") ?? "Sheet", rows: rows)
    }
    if sheets.allSatisfy({ $0.rows.isEmpty }) { throw OfficeError("This Excel file has no data.") }
    return sheets
}

private func cellText(_ c: XMLElement, shared: [String], formats: NumberFormats) -> String {
    let value = c.child("v")?.stringValue
    switch c.attr("t") {
    case "s": return value.flatMap(Int.init).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
    case "inlineStr": return c.child("is")?.elements("t").map { $0.stringValue ?? "" }.joined() ?? ""
    case "str", "e": return value ?? ""
    case "b": return value == "1" ? "TRUE" : "FALSE"
    default:
        guard let value else { return "" }
        guard let number = Double(value) else { return value }
        return formats.format(number, style: c.attr("s").flatMap(Int.init) ?? 0)
    }
}

// "B12" -> 1 (column B, counted from 0)
private func columnIndex(_ ref: String) -> Int {
    var n = 0
    for ch in ref.unicodeScalars {
        guard ch.value >= 65 && ch.value <= 90 else { break }
        n = n * 26 + Int(ch.value - 64)
    }
    return max(n - 1, 0)
}

// How each cell style shows numbers (from xl/styles.xml)
private struct NumberFormats {
    private var styleFormat: [Int] = []      // style number -> format id
    private var custom: [Int: String] = [:]  // format id -> format code like "0.00%"

    private static let builtIn: [Int: String] = [
        1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00",
        9: "0%", 10: "0.00%", 11: "0.00E+00",
        14: "m/d/yy", 15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy",
        18: "h:mm AM/PM", 19: "h:mm:ss AM/PM", 20: "h:mm", 21: "h:mm:ss", 22: "m/d/yy h:mm",
        37: "#,##0", 38: "#,##0", 39: "#,##0.00", 40: "#,##0.00",
        45: "mm:ss", 46: "[h]:mm:ss", 47: "mm:ss.0", 49: "@"
    ]

    init(_ zip: OfficeZip) {
        guard let doc = zip.xml("xl/styles.xml") else { return }
        for f in doc.elements("numFmt") {
            if let id = f.attr("numFmtId").flatMap(Int.init), let code = f.attr("formatCode") { custom[id] = code }
        }
        styleFormat = doc.elements("cellXfs").first?.childElements.filter { $0.localName == "xf" }
            .map { $0.attr("numFmtId").flatMap(Int.init) ?? 0 } ?? []
    }

    func format(_ number: Double, style: Int) -> String {
        let id = style < styleFormat.count ? styleFormat[style] : 0
        var code = custom[id] ?? Self.builtIn[id] ?? "General"
        code = String(code.split(separator: ";", omittingEmptySubsequences: false).first ?? "")   // the part for positive numbers
        code = code.replacingOccurrences(of: "\\[[^]]*]", with: "", options: .regularExpression)    // colours like [Red]
        code = code.replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)   // quoted text
        let lower = code.lowercased()
        let isDate = (14...22).contains(id) || (45...47).contains(id) ||
            lower.contains("y") || lower.contains("d") || (lower.contains("m") && !lower.contains("0")) || lower.contains("h:")
        if isDate { return excelDate(number, code: lower) }
        if code.contains("%") { return decimal(number * 100, decimals: decimalsIn(code), grouping: code.contains(",")) + "%" }
        if lower == "general" || code.trimmingCharacters(in: .whitespaces).isEmpty { return general(number) }
        if code.contains("0") || code.contains("#") { return decimal(number, decimals: decimalsIn(code), grouping: code.contains(",")) }
        return general(number)
    }

    private func decimalsIn(_ code: String) -> Int {
        guard let dot = code.firstIndex(of: ".") else { return 0 }
        return code[code.index(after: dot)...].prefix { $0 == "0" || $0 == "#" }.count
    }

    private func decimal(_ number: Double, decimals: Int, grouping: Bool) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // like Excel's own file values: 1,234.50
        f.numberStyle = .decimal
        f.usesGroupingSeparator = grouping
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        return f.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    // Like Excel's "General": no extra zeros, at most about 10 digits
    private func general(_ number: Double) -> String {
        if number == number.rounded() && abs(number) < 1e15 { return String(Int64(number)) }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.usesSignificantDigits = true
        f.maximumSignificantDigits = 10
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    // Excel counts days from 30 Dec 1899
    private func excelDate(_ number: Double, code: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.date(from: DateComponents(year: 1899, month: 12, day: 30))!
        let days = floor(number)
        let seconds = ((number - days) * 86400).rounded()
        let time = start.addingTimeInterval(days * 86400 + seconds)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: time)
        let hasDate = code.contains("y") || code.contains("d") || code.contains("mmm") || code == "m/d/yy" || !code.contains("h")
        let hasTime = code.contains("h") || code.contains("s")
        let date = hasDate ? String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!) : ""
        let clock = hasTime ? String(format: "%02d:%02d", parts.hour!, parts.minute!) : ""
        return [date, clock].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Excel -> PDF

// Every sheet becomes a table with grid lines; wide sheets use a sideways (landscape) page (like Android)
func excelToPdf(_ sheets: [Sheet], to url: URL) -> Bool {
    let baseSize: CGFloat = 9
    let measureFont = NSFont.systemFont(ofSize: baseSize)
    func textWidth(_ s: String) -> CGFloat {
        (s.components(separatedBy: .newlines).first ?? "" as String).size(withAttributes: [.font: measureFont]).width
    }
    // The natural width of each column (longest text, within limits)
    let natural: [[CGFloat]] = sheets.map { sheet in
        let cols = sheet.rows.map(\.count).max() ?? 0
        return (0..<cols).map { c in
            let longest = sheet.rows.prefix(500).map { c < $0.count ? textWidth($0[c]) : 0 }.max() ?? 0
            return min(max(longest, 24), 180) + 8
        }
    }
    let portraitUsable = a4Size.width - 2 * pageMargin
    let landscape = natural.contains { $0.reduce(0, +) > portraitUsable }
    let page = landscape ? CGSize(width: a4Size.height, height: a4Size.width) : a4Size
    let margin: CGFloat = 36
    let usable = page.width - 2 * margin
    let pad: CGFloat = 3

    let data = NSMutableData()
    var mediaBox = CGRect(origin: .zero, size: page)
    guard let consumer = CGDataConsumer(data: data),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return false }
    let graphics = NSGraphicsContext(cgContext: context, flipped: true)
    var y = margin             // from the top of the page
    var pageOpen = false

    func newPage() {
        if pageOpen { NSGraphicsContext.restoreGraphicsState(); context.endPDFPage() }
        context.beginPDFPage(nil)
        // draw from the top down
        context.translateBy(x: 0, y: page.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        pageOpen = true
        y = margin
    }

    for (i, sheet) in sheets.enumerated() where !sheet.rows.isEmpty {
        newPage()   // each sheet starts on a new page
        let title = NSAttributedString(string: sheet.name, attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.black])
        title.draw(at: CGPoint(x: margin, y: y))
        y += title.size().height + 6

        // shrink the columns (and the letters) when the sheet is wider than the page
        let widths0 = natural[i]
        let scale = min(1, usable / max(widths0.reduce(0, +), 1))
        let fontSize = max(baseSize * scale, 6)
        var widths = widths0.map { $0 * scale }
        let total = widths.reduce(0, +)
        if total > usable { widths = widths.map { $0 * usable / total } }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.black]

        for row in sheet.rows {
            let cells = widths.indices.map { $0 < row.count ? row[$0] : "" }
            // the row is as tall as its tallest cell (long text wraps)
            let heights = zip(cells, widths).map { text, w in
                NSAttributedString(string: text, attributes: attributes)
                    .boundingRect(with: CGSize(width: max(w - 2 * pad, 4), height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin]).height
            }
            let rowHeight = max((heights.max() ?? 0) + 2 * pad, fontSize + 6)
            if y + rowHeight > page.height - margin { newPage() }

            var x = margin
            for (text, w) in zip(cells, widths) {
                let cell = CGRect(x: x, y: y, width: w, height: rowHeight)
                NSColor(srgbRed: 0x9E / 255, green: 0x9E / 255, blue: 0x9E / 255, alpha: 1).setStroke()
                let border = NSBezierPath(rect: cell)
                border.lineWidth = 0.6
                border.stroke()
                NSAttributedString(string: text, attributes: attributes)
                    .draw(with: cell.insetBy(dx: pad, dy: pad), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                x += w
            }
            y += rowHeight
        }
    }
    if pageOpen { NSGraphicsContext.restoreGraphicsState(); context.endPDFPage() }
    context.closePDF()
    return (try? (data as Data).write(to: url)) != nil
}
