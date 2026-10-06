import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// Combine several PDFs into one, in the order shown in the list
struct MergeView: View {
    @Binding var path: [Screen]
    @State private var files: [PickedPdf] = []
    @State private var showPicker = false
    @State private var message: String?
    @State private var savedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Combine several PDFs into one. Drag the rows to change the order. You can also drop PDFs here from Finder.")
                .foregroundStyle(.secondary)

            if files.isEmpty {
                emptyBox
            } else {
                List {
                    ForEach(files) { file in
                        row(file)
                    }
                    .onMove { from, to in files.move(fromOffsets: from, toOffset: to) }
                }
                .scrollContentBackground(.hidden)
                .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 20))
            }

            if let message {
                Text(message).foregroundStyle(Theme.orange)
            }

            if let savedURL {
                SavedBanner(text: "Saved \(savedURL.lastPathComponent)", showURL: savedURL, openURL: savedURL) {
                    path.append(.viewer($0))
                }
            }

            HStack {
                Button {
                    showPicker = true
                } label: {
                    Label("Add PDFs", systemImage: "plus")
                }
                .controlSize(.large)

                Spacer()

                Button(files.count < 2 ? "Add at least 2 PDFs" : "Merge \(files.count) PDFs") {
                    merge()
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Theme.blue)
                .disabled(files.count < 2)
            }
        }
        .padding(24)
        .frame(maxWidth: 800, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
        .navigationTitle("Merge PDFs")
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls.filter { $0.pathExtension.lowercased() == "pdf" })
            return true
        }
    }

    private var emptyBox: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 36))
                .foregroundStyle(Theme.teal)
            Text("No PDFs yet")
                .font(.headline)
            Text("Click \"Add PDFs\" or drop files here.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 20))
    }

    private func row(_ file: PickedPdf) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
            Image(systemName: "doc.fill")
                .foregroundStyle(TileColor.teal.foreground)
                .frame(width: 34, height: 34)
                .background(TileColor.teal.background, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(1)
                Text(file.document.pageCount == 1 ? "1 page" : "\(file.document.pageCount) pages")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                files.removeAll { $0.id == file.id }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .padding(.vertical, 4)
    }

    // Opens each picked file and adds it to the list
    private func add(_ urls: [URL]) {
        message = nil
        savedURL = nil
        var skipped: [String] = []
        for url in urls {
            switch loadPickedPdf(url) {
            case .success(let file): files.append(file)
            case .failure(let error): skipped.append(error.message)
            }
        }
        if !skipped.isEmpty {
            message = "Skipped: " + skipped.joined(separator: ", ")
        }
    }

    // Copies every page of every file, in order, into one new PDF and asks where to save it
    private func merge() {
        message = nil
        savedURL = nil

        let output = PDFDocument()
        for file in files {
            copyPages(Array(0..<file.document.pageCount), from: file.document, into: output)
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let firstName = files.first.map { baseName($0.name) } ?? "document"
        panel.nameFieldStringValue = "\(firstName)_merged.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if output.write(to: url) {
            savedURL = url
        } else {
            message = "Could not save the merged PDF. Try another folder."
        }
    }
}
