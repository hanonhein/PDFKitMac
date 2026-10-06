import SwiftUI
import PDFKit

// PDF to text and Extract images (like Android ExtractScreens.kt)

// MARK: - PDF to text

struct PdfToTextView: View {
    @Binding var path: [Screen]
    @State private var file: PickedPdf?
    @State private var message: String?
    @State private var savedFile: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Copies all the words of a PDF into a text file. Scanned pages have no text; use \"Recognize text (OCR)\" for those.")
                    .foregroundStyle(Theme.textSecondary)
                PasswordPdfPicker(file: $file) { message = nil; savedFile = nil }
                if let message { Text(message).foregroundStyle(Theme.orange) }
                if let savedFile {
                    SavedBanner(text: "Saved \(savedFile.lastPathComponent)", showURL: savedFile, openURL: savedFile) { NSWorkspace.shared.open($0) }
                }
                HStack {
                    Spacer()
                    Button(file == nil ? "Choose a PDF first" : "Save text", action: save)
                        .controlSize(.large).buttonStyle(.borderedProminent).tint(Theme.blue)
                        .disabled(file == nil)
                }
            }
            .padding(24)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("PDF to text")
    }

    private func save() {
        guard let file else { return }
        message = nil
        savedFile = nil
        let pages = (0..<file.document.pageCount).map {
            (file.document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if pages.allSatisfy(\.isEmpty) {
            message = "This PDF has no text. It may be a scan; try \"Recognize text (OCR)\"."
            return
        }
        let text = pages.enumerated().map { "--- Page \($0.offset + 1) ---\n\($0.element)" }.joined(separator: "\n\n")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(baseName(file.name)).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            savedFile = url
        } catch {
            message = "Could not save the file. Try another folder."
        }
    }
}

// MARK: - Finding the pictures inside a PDF

struct FoundImage: Identifiable {
    let id = UUID()
    let preview: NSImage
    let data: Data        // the file to save
    let ext: String       // "jpg" or "png"
    let pixelSize: CGSize
    let page: Int         // first page it is on (from 1)
}

// Every picture stored inside the PDF, each only once. JPEG photos are saved exactly as they are.
func findImages(_ document: PDFDocument) -> [FoundImage] {
    var found: [FoundImage] = []
    var seen = Set<Int>()   // a picture used on many pages counts once (remembered by its address)

    func scan(_ resources: CGPDFDictionaryRef, page: Int, depth: Int) {
        var xObjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return }
        CGPDFDictionaryApplyBlock(xObjects, { _, value, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream), let stream else { return true }
            guard seen.insert(unsafeBitCast(stream, to: Int.self)).inserted, let dict = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<Int8>?
            CGPDFDictionaryGetName(dict, "Subtype", &subtype)
            let kind = subtype.map { String(cString: $0) }
            if kind == "Form", depth < 3 {
                // a group of drawings can hold pictures too
                var inner: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dict, "Resources", &inner), let inner { scan(inner, page: page, depth: depth + 1) }
            } else if kind == "Image", let image = readImage(stream, dict, page: page) {
                found.append(image)
            }
            return true
        }, nil)
    }

    for i in 0..<document.pageCount {
        guard let page = document.page(at: i)?.pageRef, let pageDict = page.dictionary else { continue }
        var resources: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(pageDict, "Resources", &resources), let resources {
            scan(resources, page: i + 1, depth: 0)
        }
    }
    return found
}

private func integer(_ dict: CGPDFDictionaryRef, _ key: String) -> Int? {
    var value: CGPDFInteger = 0
    return CGPDFDictionaryGetInteger(dict, key, &value) ? value : nil
}

private func readImage(_ stream: CGPDFStreamRef, _ dict: CGPDFDictionaryRef, page: Int) -> FoundImage? {
    guard let width = integer(dict, "Width"), let height = integer(dict, "Height"),
          width * height >= 32 * 32 else { return nil }   // skip tiny bits like bullets and lines
    var isMask: CGPDFBoolean = 0
    if CGPDFDictionaryGetBoolean(dict, "ImageMask", &isMask), isMask != 0 { return nil }

    var format = CGPDFDataFormat.raw
    guard let cfData = CGPDFStreamCopyData(stream, &format) else { return nil }
    let data = cfData as Data
    let size = CGSize(width: width, height: height)

    switch format {
    case .jpegEncoded:
        // a JPEG photo: keep the file exactly as it is
        guard let preview = NSImage(data: data) else { return nil }
        return FoundImage(preview: preview, data: data, ext: "jpg", pixelSize: size, page: page)
    case .JPEG2000:
        guard let preview = NSImage(data: data), let png = pngData(preview) else { return nil }
        return FoundImage(preview: preview, data: png, ext: "png", pixelSize: size, page: page)
    default:
        // plain pixels: build a picture from them (grey, RGB or CMYK; 1, 2, 4, 8 or 16 bits per colour)
        let bits = integer(dict, "BitsPerComponent") ?? 8
        guard [1, 2, 4, 8, 16].contains(bits), let space = colorSpace(dict) else { return nil }
        let components = space.numberOfComponents
        if components > 1 && bits < 8 { return nil }   // the Mac only draws colour pictures with 8 or 16 bits
        let rowBytes = (width * components * bits + 7) / 8
        // PDF stores 16-bit values with the big byte first
        let info = bits == 16 ? CGBitmapInfo.byteOrder16Big.rawValue : 0
        guard data.count >= rowBytes * height, let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * components,
                               bytesPerRow: rowBytes, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | info),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let image = NSImage(cgImage: cg, size: size)
        guard let png = pngData(image) else { return nil }
        return FoundImage(preview: image, data: png, ext: "png", pixelSize: size, page: page)
    }
}

// The picture's colours: grey, RGB or CMYK (also when given by a colour profile)
private func colorSpace(_ dict: CGPDFDictionaryRef) -> CGColorSpace? {
    var name: UnsafePointer<Int8>?
    if CGPDFDictionaryGetName(dict, "ColorSpace", &name), let name {
        switch String(cString: name) {
        case "DeviceGray", "CalGray": return CGColorSpaceCreateDeviceGray()
        case "DeviceRGB", "CalRGB": return CGColorSpace(name: CGColorSpace.sRGB)
        case "DeviceCMYK": return CGColorSpaceCreateDeviceCMYK()
        default: return nil
        }
    }
    // [/ICCBased stream]: the profile says how many colours (N)
    var array: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(dict, "ColorSpace", &array), let array else { return nil }
    var first: UnsafePointer<Int8>?
    guard CGPDFArrayGetName(array, 0, &first), let first, String(cString: first) == "ICCBased" else { return nil }
    var profile: CGPDFStreamRef?
    guard CGPDFArrayGetStream(array, 1, &profile), let profile, let pdict = CGPDFStreamGetDictionary(profile) else { return nil }
    switch integer(pdict, "N") {
    case 1: return CGColorSpaceCreateDeviceGray()
    case 3: return CGColorSpace(name: CGColorSpace.sRGB)
    case 4: return CGColorSpaceCreateDeviceCMYK()
    default: return nil
    }
}

private func pngData(_ image: NSImage) -> Data? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
}

// MARK: - Extract images screen

struct ExtractImagesView: View {
    @Binding var path: [Screen]
    @State private var file: PickedPdf?
    @State private var images: [FoundImage] = []
    @State private var chosen: Set<UUID> = []
    @State private var searched = false
    @State private var message: String?
    @State private var savedFolder: URL?
    @State private var savedCount = 0

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Finds every photo and picture inside the PDF. Look at them, then save the ones you want.")
                    .foregroundStyle(Theme.textSecondary)
                PasswordPdfPicker(file: $file, onPick: find)

                if searched && images.isEmpty {
                    Text("No pictures were found in this PDF.").foregroundStyle(Theme.orange)
                }
                if !images.isEmpty {
                    HStack {
                        Text("\(images.count) picture\(images.count == 1 ? "" : "s") found · \(chosen.count) chosen")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button(chosen.count == images.count ? "Choose none" : "Choose all") {
                            chosen = chosen.count == images.count ? [] : Set(images.map(\.id))
                        }
                    }
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(images) { item in
                            let isChosen = chosen.contains(item.id)
                            VStack(spacing: 6) {
                                Image(nsImage: item.preview)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 120)
                                    .frame(maxWidth: .infinity)
                                Text("\(Int(item.pixelSize.width)) × \(Int(item.pixelSize.height)) · page \(item.page)")
                                    .font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            .padding(8)
                            .background(isChosen ? Theme.blueContainer : Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(isChosen ? Theme.blue : .clear, lineWidth: 2))
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isChosen ? Theme.blue : Theme.textSecondary)
                                    .padding(6)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { if isChosen { chosen.remove(item.id) } else { chosen.insert(item.id) } }
                        }
                    }
                }

                if let message { Text(message).foregroundStyle(Theme.orange) }
                if let savedFolder {
                    SavedBanner(text: "Saved \(savedCount) picture\(savedCount == 1 ? "" : "s") in \(savedFolder.lastPathComponent)", showURL: savedFolder)
                }
                HStack {
                    Spacer()
                    Button(chosen.isEmpty ? "Choose pictures to save" : "Save \(chosen.count) picture\(chosen.count == 1 ? "" : "s")", action: save)
                        .controlSize(.large).buttonStyle(.borderedProminent).tint(Theme.blue)
                        .disabled(chosen.isEmpty)
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("Extract images")
    }

    private func find() {
        message = nil
        savedFolder = nil
        guard let file else { return }
        images = findImages(file.document)
        chosen = Set(images.map(\.id))   // all chosen to start with
        searched = true
    }

    private func save() {
        guard let file else { return }
        message = nil
        savedFolder = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save here"
        panel.message = "Choose a folder for the pictures"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var count = 0
        for (n, item) in images.filter({ chosen.contains($0.id) }).enumerated() {
            let url = freeFileURL(in: folder, name: "\(baseName(file.name))_image\(n + 1)", ext: item.ext)
            if (try? item.data.write(to: url)) != nil { count += 1 }
        }
        if count == chosen.count {
            savedCount = count
            savedFolder = folder
        } else {
            message = "Could only save \(count) of \(chosen.count) pictures. Try another folder."
        }
    }
}
