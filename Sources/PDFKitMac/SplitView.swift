import SwiftUI
import PDFKit

enum SplitMode: String, CaseIterable, Identifiable {
    case everyPage, everyN, ranges
    var id: Self { self }

    var label: String {
        switch self {
        case .everyPage: "Every page"
        case .everyN: "Every few pages"
        case .ranges: "Custom ranges"
        }
    }

    var description: String {
        switch self {
        case .everyPage: "Each page becomes its own PDF"
        case .everyN: "For example, every 2 pages become one PDF"
        case .ranges: "You type which pages go together"
        }
    }
}

// Cut one PDF into several smaller PDFs
struct SplitView: View {
    @State private var file: PickedPdf?
    @State private var mode = SplitMode.everyPage
    @State private var everyText = "2"
    @State private var rangesText = ""
    @State private var showPicker = false
    @State private var message: String?
    @State private var savedFolder: URL?
    @State private var savedCount = 0

    // The page groups (0-based) that will each become one PDF. nil = the typed text is not valid yet.
    private var parts: [ClosedRange<Int>]? {
        guard let file else { return nil }
        let count = file.document.pageCount
        switch mode {
        case .everyPage:
            return (0..<count).map { $0...$0 }
        case .everyN:
            guard let n = Int(everyText), n >= 1 else { return nil }
            return stride(from: 0, to: count, by: n).map { $0...min($0 + n - 1, count - 1) }
        case .ranges:
            return parseRanges(rangesText, pageCount: count)
        }
    }

    private var actionLabel: String {
        if file == nil { return "Choose a PDF first" }
        guard let parts else { return mode == .ranges ? "Type the page ranges" : "Type how many pages" }
        return parts.count == 1 ? "Split into 1 file" : "Split into \(parts.count) files"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Cut a PDF into smaller PDFs. Your original file stays unchanged.")
                    .foregroundStyle(.secondary)

                fileBox

                if file != nil {
                    section("How to split") {
                        Picker("", selection: $mode) {
                            ForEach(SplitMode.allCases) { mode in
                                VStack(alignment: .leading) {
                                    Text(mode.label)
                                    Text(mode.description).font(.subheadline).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                                .tag(mode)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }

                    if mode == .everyN {
                        section("Pages in each PDF") {
                            TextField("Number of pages, like 2", text: $everyText)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 200)
                            hint(parts == nil ? "Type a number, like 2" : "Makes \(parts?.count ?? 0) PDFs", isError: parts == nil)
                        }
                    }

                    if mode == .ranges {
                        section("Page ranges") {
                            TextField("For example: 1-3, 4-6, 9", text: $rangesText)
                                .textFieldStyle(.roundedBorder)
                            let bad = !rangesText.trimmingCharacters(in: .whitespaces).isEmpty && parts == nil
                            hint(bad ? "Use page numbers from 1 to \(file?.document.pageCount ?? 0), like 1-3, 5"
                                     : "Each range becomes its own PDF.", isError: bad)
                        }
                    }
                }

                if let message {
                    Text(message).foregroundStyle(Theme.orange)
                }

                if let savedFolder {
                    SavedBanner(text: "Saved \(savedCount) PDF\(savedCount == 1 ? "" : "s") in \(savedFolder.lastPathComponent)",
                                showURL: savedFolder)
                }

                HStack {
                    Spacer()
                    Button(actionLabel) { split() }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.blue)
                        .disabled(parts == nil)
                }
            }
            .padding(24)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("Split PDF")
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { pick(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
            pick(url)
            return true
        }
    }

    // Shows the chosen file, or a button to choose one
    private var fileBox: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .foregroundStyle(TileColor.orange.foreground)
                .frame(width: 40, height: 40)
                .background(TileColor.orange.background, in: RoundedRectangle(cornerRadius: 12))
            if let file {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).lineLimit(1)
                    Text(file.document.pageCount == 1 ? "1 page" : "\(file.document.pageCount) pages")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Text("No PDF chosen. Click the button or drop a file here.").foregroundStyle(.secondary)
            }
            Spacer()
            Button(file == nil ? "Choose PDF" : "Change") { showPicker = true }
        }
        .padding(14)
        .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 20))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 20))
    }

    private func hint(_ text: String, isError: Bool) -> some View {
        Text(text).font(.caption).foregroundStyle(isError ? Theme.orange : .secondary)
    }

    private func pick(_ url: URL) {
        message = nil
        savedFolder = nil
        switch loadPickedPdf(url) {
        case .success(let picked): file = picked
        case .failure(let error): message = error.message
        }
    }

    // Asks for a folder, then saves one PDF per part into it
    private func split() {
        guard let file, let parts else { return }
        message = nil
        savedFolder = nil

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save here"
        panel.message = "Choose a folder for the \(parts.count) new PDF\(parts.count == 1 ? "" : "s")"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let base = baseName(file.name)
        var saved: [URL] = []
        for range in parts {
            let label = range.count == 1 ? "page\(range.lowerBound + 1)" : "pages\(range.lowerBound + 1)-\(range.upperBound + 1)"
            let url = freeFileURL(in: folder, name: "\(base)_\(label)", ext: "pdf")
            if copyPages(Array(range), from: file.document).write(to: url) {
                saved.append(url)
            }
        }

        if saved.count == parts.count {
            savedCount = saved.count
            savedFolder = folder
        } else {
            message = "Could only save \(saved.count) of \(parts.count) files. Try another folder."
        }
    }
}

// Turns "1-3, 4-6, 9" into page groups (0-based). Returns nil if anything is wrong.
func parseRanges(_ text: String, pageCount: Int) -> [ClosedRange<Int>]? {
    let pieces = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    if pieces.isEmpty { return nil }
    var result: [ClosedRange<Int>] = []
    for piece in pieces {
        let ends = piece.split(separator: "-", omittingEmptySubsequences: false)
            .map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard ends.count <= 2, let first = ends.first ?? nil, let last = ends.last ?? nil,
              first >= 1, last <= pageCount, first <= last else { return nil }
        result.append((first - 1)...(last - 1))
    }
    return result
}
