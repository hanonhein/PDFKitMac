import Foundation

// Word (.docx), Excel (.xlsx) and PowerPoint (.pptx) files are zip folders full of XML files.
// This opens them (like Android OfficeZip.kt).

struct OfficeError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

final class OfficeZip {
    private let folder: URL   // where the zip was unpacked

    // Unpacks the file into a private temporary folder. The Mac's unzip tool refuses
    // paths that try to escape the folder ("../"), so a bad file can't write elsewhere.
    init(_ url: URL, kindName: String, ext: String) throws {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 200 * 1024 * 1024 { throw OfficeError("This file is too big to convert.") }

        folder = FileManager.default.temporaryDirectory.appendingPathComponent("office-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-qq", "-o", url.path, "-d", folder.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        if unzip.terminationStatus > 1 || !has("[Content_Types].xml") {
            let article = "AEIOU".contains(kindName.first ?? "x") ? "an" : "a"
            throw OfficeError("This is not \(article) \(kindName) (\(ext)) file. Older files (like .xls or .ppt) are not supported: " +
                              "open the file in its app and save it as \(ext) first.")
        }
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    private func fileURL(_ path: String) -> URL { folder.appendingPathComponent(path) }

    func has(_ path: String) -> Bool { FileManager.default.fileExists(atPath: fileURL(path).path) }

    func data(_ path: String) -> Data? { try? Data(contentsOf: fileURL(path)) }

    func xml(_ path: String) -> XMLDocument? {
        guard let data = data(path) else { return nil }
        // never load anything from outside the file (safety)
        return try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    }

    // "xl/_rels/workbook.xml.rels": relationship id -> full path inside the zip
    func relations(_ partPath: String) -> [String: String] {
        let parts = partPath.split(separator: "/").map(String.init)
        let folder = parts.dropLast().joined(separator: "/")
        let relsPath = (folder.isEmpty ? "" : folder + "/") + "_rels/" + (parts.last ?? "") + ".rels"
        guard let doc = xml(relsPath) else { return [:] }
        var map: [String: String] = [:]
        for rel in doc.elements("Relationship") {
            if let id = rel.attr("Id"), let target = rel.attr("Target") {
                map[id] = resolvePath(folder, target)
            }
        }
        return map
    }
}

// "../media/image1.png" seen from "ppt/slides" -> "ppt/media/image1.png"
func resolvePath(_ folder: String, _ target: String) -> String {
    if target.hasPrefix("/") { return String(target.dropFirst()) }
    var parts = folder.isEmpty ? [] : folder.split(separator: "/").map(String.init)
    for part in target.split(separator: "/").map(String.init) {
        switch part {
        case "..": if !parts.isEmpty { parts.removeLast() }
        case ".", "": break
        default: parts.append(part)
        }
    }
    return parts.joined(separator: "/")
}

// MARK: - Small XML helpers (match tags by their short name, like "c" for "<x:c>")

extension XMLNode {
    // All elements with this short name, anywhere inside
    func elements(_ name: String) -> [XMLElement] {
        (try? nodes(forXPath: ".//*[local-name()='\(name)']"))?.compactMap { $0 as? XMLElement } ?? []
    }
}

extension XMLElement {
    // Direct children (not grandchildren)
    var childElements: [XMLElement] { children?.compactMap { $0 as? XMLElement } ?? [] }

    func child(_ name: String) -> XMLElement? { childElements.first { $0.localName == name } }

    // An attribute by its short name ("id" also finds "r:id")
    func attr(_ name: String) -> String? {
        attributes?.first { $0.name == name || $0.localName == name }?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }
}
