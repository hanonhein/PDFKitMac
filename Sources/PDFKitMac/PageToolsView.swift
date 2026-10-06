import SwiftUI
import PDFKit

// One page in the grid. "id" stays the same when pages move around.
struct PageItem: Identifiable, Equatable {
    let id: Int
    let source: Int          // page in the original file (from 0), or -1 for a blank page
    var rotation = 0         // extra turn: 0, 90, 180, 270
    var crop: CropMargins?   // edges to cut away, nil = no crop
}

// How much to cut from each side, as a part of the page (0.05 = 5%), as the page is seen
struct CropMargins: Equatable {
    var left = 0.05, top = 0.05, right = 0.05, bottom = 0.05
}

// Rotate, delete, reorder, duplicate and extract pages, or add blank pages
struct PageToolsView: View {
    @Binding var path: [Screen]
    @State private var file: PickedPdf?
    @State private var pages: [PageItem] = []
    @State private var selected: Set<Int> = []
    @State private var nextId = 1
    @State private var showPicker = false
    @State private var message: String?
    @State private var savedURL: URL?
    @State private var showCrop = false

    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 16)]

    var body: some View {
        Group {
            if let file {
                editor(file)
            } else {
                chooseFile
            }
        }
        .background(Theme.background)
        .navigationTitle("Page Tools")
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { pick(url) }
        }
        .sheet(isPresented: $showCrop) {
            if let file, let first = pages.first(where: { isTarget($0) && $0.source >= 0 }) {
                CropSheet(item: first, document: file.document,
                          onApply: { crop($0); showCrop = false },
                          onCancel: { showCrop = false })
            }
        }
    }

    // Step 1: choose a PDF
    private var chooseFile: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 36))
                .foregroundStyle(TileColor.blue.foreground)
                .frame(width: 72, height: 72)
                .background(TileColor.blue.background, in: RoundedRectangle(cornerRadius: 20))
            Text("Rotate, delete, reorder, duplicate, crop and extract pages, or add blank pages.")
                .foregroundStyle(.secondary)
            Button("Choose PDF") { showPicker = true }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Theme.blue)
            Text("or drop a PDF here").font(.caption).foregroundStyle(.secondary)
            if let message {
                Text(message).foregroundStyle(Theme.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
            pick(url)
            return true
        }
    }

    // Step 2: the page grid with buttons
    private func editor(_ file: PickedPdf) -> some View {
        VStack(spacing: 0) {
            toolbar(file)
            Divider()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, item in
                        PageThumb(item: item, number: index + 1, isSelected: selected.contains(item.id),
                                  document: file.document)
                            .onTapGesture { toggle(item.id) }
                            .draggable(String(item.id))
                            .dropDestination(for: String.self) { ids, _ in
                                guard let id = ids.first.flatMap(Int.init) else { return false }
                                move(id, before: item.id)
                                return true
                            }
                    }
                }
                .padding(20)
            }

            Divider()
            bottomBar(file)
        }
    }

    private func toolbar(_ file: PickedPdf) -> some View {
        let any = !selected.isEmpty
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.headline).lineLimit(1)
                Text(any ? "\(selected.count) selected" : "\(pages.count) pages · click to select, drag to move")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button(selected.count == pages.count ? "Select none" : "Select all") {
                selected = selected.count == pages.count ? [] : Set(pages.map(\.id))
            }
            Button { rotate() } label: { Label(any ? "Rotate" : "Rotate all", systemImage: "rotate.right") }
            Button { delete() } label: { Label("Delete", systemImage: "trash") }
                .disabled(!any || selected.count == pages.count)
            Button { duplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .disabled(!any)
            Button { addBlank() } label: { Label("Blank page", systemImage: "doc.badge.plus") }
            Button { showCrop = true } label: { Label(any ? "Crop" : "Crop all", systemImage: "crop") }
                .disabled(!pages.contains { isTarget($0) && $0.source >= 0 })
            Button { save(onlySelected: true) } label: { Label("Extract", systemImage: "square.and.arrow.up") }
                .disabled(!any)
                .help("Save only the selected pages as a new PDF")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func bottomBar(_ file: PickedPdf) -> some View {
        VStack(spacing: 10) {
            if let message {
                Text(message).foregroundStyle(Theme.orange)
            }
            if let savedURL {
                SavedBanner(text: "Saved \(savedURL.lastPathComponent)", showURL: savedURL, openURL: savedURL) {
                    path.append(.viewer($0))
                }
            }
            HStack {
                Button("Change PDF") { showPicker = true }
                Spacer()
                Button { save(onlySelected: false) } label: {
                    Label("Save as new PDF", systemImage: "square.and.arrow.down")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Theme.blue)
                .disabled(pages.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func pick(_ url: URL) {
        message = nil
        savedURL = nil
        switch loadPickedPdf(url) {
        case .success(let picked):
            file = picked
            selected = []
            pages = (0..<picked.document.pageCount).map { PageItem(id: newId(), source: $0) }
        case .failure(let error):
            message = error.message
        }
    }

    private func newId() -> Int {
        nextId += 1
        return nextId
    }

    private func toggle(_ id: Int) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    // Changes the selected pages, or all pages if none are selected
    private func isTarget(_ item: PageItem) -> Bool {
        selected.isEmpty || selected.contains(item.id)
    }

    private func rotate() {
        for i in pages.indices where isTarget(pages[i]) {
            pages[i].rotation = (pages[i].rotation + 90) % 360
        }
    }

    private func delete() {
        pages.removeAll { selected.contains($0.id) }
        selected = []
    }

    private func duplicate() {
        var result: [PageItem] = []
        for item in pages {
            result.append(item)
            if selected.contains(item.id) {
                result.append(PageItem(id: newId(), source: item.source, rotation: item.rotation, crop: item.crop))
            }
        }
        pages = result
    }

    // Sets (or removes, with nil) the crop of the selected pages, or all pages. Blank pages are skipped.
    private func crop(_ margins: CropMargins?) {
        for i in pages.indices where isTarget(pages[i]) && pages[i].source >= 0 {
            pages[i].crop = margins
        }
    }

    // Adds a blank page after the last selected page, or at the end
    private func addBlank() {
        let last = pages.lastIndex { selected.contains($0.id) }
        pages.insert(PageItem(id: newId(), source: -1), at: last.map { $0 + 1 } ?? pages.count)
    }

    // Puts the dragged page where the page it was dropped on is
    private func move(_ id: Int, before targetId: Int) {
        guard id != targetId,
              let from = pages.firstIndex(where: { $0.id == id }),
              let to = pages.firstIndex(where: { $0.id == targetId }) else { return }
        let item = pages.remove(at: from)
        pages.insert(item, at: to)
    }

    // Saves the pages in their new order as a new PDF; with onlySelected, only the selected pages
    private func save(onlySelected: Bool) {
        guard let file else { return }
        message = nil
        savedURL = nil

        let chosen = onlySelected ? pages.filter { selected.contains($0.id) } : pages
        let output = buildPdf(from: chosen, source: file.document)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(baseName(file.name))_\(onlySelected ? "extract" : "pages").pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if output.write(to: url) {
            savedURL = url
        } else {
            message = "Could not save the PDF. Try another folder."
        }
    }
}

// Makes the new PDF: copies each page (with its extra turn) or adds a blank page
func buildPdf(from items: [PageItem], source: PDFDocument) -> PDFDocument {
    let output = PDFDocument()
    // Blank pages get the size of the file's first page (or A4)
    let blankSize = source.page(at: 0)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 595, height: 842)
    for item in items {
        let page: PDFPage?
        if item.source >= 0 {
            page = source.page(at: item.source)?.copy() as? PDFPage
        } else {
            page = PDFPage()
            page?.setBounds(CGRect(origin: .zero, size: blankSize.size), for: .mediaBox)
        }
        guard let page else { continue }
        page.rotation = (page.rotation + item.rotation) % 360
        if let crop = item.crop { applyCrop(crop, to: page) }
        output.insert(page, at: output.pageCount)
    }
    return output
}

// Cuts the edges off a page. The margins are for the page as seen (after turning),
// so they are swapped around to match how the page is stored in the file.
func applyCrop(_ m: CropMargins, to page: PDFPage) {
    let box = page.bounds(for: .cropBox)
    let (l, t, r, b): (Double, Double, Double, Double)
    switch ((page.rotation % 360) + 360) % 360 {
    case 90: (l, t, r, b) = (m.top, m.right, m.bottom, m.left)
    case 180: (l, t, r, b) = (m.right, m.bottom, m.left, m.top)
    case 270: (l, t, r, b) = (m.bottom, m.left, m.top, m.right)
    default: (l, t, r, b) = (m.left, m.top, m.right, m.bottom)
    }
    // PDF pages count up from the bottom-left corner
    let newBox = CGRect(
        x: box.minX + box.width * l,
        y: box.minY + box.height * b,
        width: box.width * max(1 - l - r, 0.05),
        height: box.height * max(1 - t - b, 0.05)
    )
    page.setBounds(newBox, for: .cropBox)
}

// The small window with 4 sliders and a preview of the page
struct CropSheet: View {
    let item: PageItem
    let document: PDFDocument
    let onApply: (CropMargins?) -> Void
    let onCancel: () -> Void
    @State private var margins: CropMargins
    @State private var image: NSImage?

    init(item: PageItem, document: PDFDocument, onApply: @escaping (CropMargins?) -> Void, onCancel: @escaping () -> Void) {
        self.item = item
        self.document = document
        self.onApply = onApply
        self.onCancel = onCancel
        _margins = State(initialValue: item.crop ?? CropMargins())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Crop pages").font(.title2.bold())
            Text("Cut away the edges of the page. The dark part will be removed.")
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 24) {
                preview.frame(width: 220, height: 280)

                VStack(alignment: .leading, spacing: 10) {
                    slider("Left", $margins.left)
                    slider("Top", $margins.top)
                    slider("Right", $margins.right)
                    slider("Bottom", $margins.bottom)
                }
                .frame(width: 240)
            }

            HStack {
                Button("Remove crop") { onApply(nil) }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Crop") { onApply(margins) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.blue)
            }
        }
        .padding(24)
        .task {
            // Picture of the page turned the same way as in the grid
            guard let page = document.page(at: item.source)?.copy() as? PDFPage else { return }
            page.rotation = (page.rotation + item.rotation) % 360
            let holder = PDFDocument()   // a page must belong to a document to be drawn
            holder.insert(page, at: 0)
            image = page.thumbnail(of: CGSize(width: 440, height: 560), for: .cropBox)
        }
    }

    private var preview: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        GeometryReader { geo in
                            let w = geo.size.width, h = geo.size.height
                            // Darken everything outside the crop
                            Path { p in
                                p.addRect(CGRect(origin: .zero, size: geo.size))
                                p.addRect(CGRect(x: w * margins.left, y: h * margins.top,
                                                 width: w * max(1 - margins.left - margins.right, 0.05),
                                                 height: h * max(1 - margins.top - margins.bottom, 0.05)))
                            }
                            .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                        }
                    }
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            } else {
                ProgressView()
            }
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label): \(Int((value.wrappedValue * 100).rounded()))%").font(.subheadline)
            Slider(value: value, in: 0...0.4)
        }
    }
}

// One small page picture in the grid
struct PageThumb: View {
    let item: PageItem
    let number: Int
    let isSelected: Bool
    let document: PDFDocument
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if item.source < 0 {
                        Rectangle().fill(.white)
                            .aspectRatio(0.707, contentMode: .fit)
                            .overlay(Text("Blank").font(.caption).foregroundStyle(.gray))
                    } else if let image {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                .rotationEffect(.degrees(Double(item.rotation)))
                .animation(.easeInOut(duration: 0.2), value: item.rotation)
                .frame(width: 130, height: 130)

                if item.crop != nil {
                    Image(systemName: "scissors")
                        .font(.caption.bold())
                        .foregroundStyle(TileColor.orange.foreground)
                        .padding(5)
                        .background(TileColor.orange.background, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(4)
                        .help("This page will be cropped")
                }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white, Theme.blue)
                        .padding(4)
                }
            }
            .padding(6)
            .background(isSelected ? Theme.blueContainer : Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(isSelected ? Theme.blue : .clear, lineWidth: 2))

            Text("\(number)").font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .task(id: item.source) {
            if item.source >= 0, image == nil {
                image = document.page(at: item.source)?.thumbnail(of: CGSize(width: 260, height: 260), for: .cropBox)
            }
        }
    }
}
