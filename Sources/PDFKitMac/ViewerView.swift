import SwiftUI
import PDFKit

// Shows a PDF. Apple's PDFView already does scrolling, zoom (pinch or Cmd +/-) and text selection.
struct ViewerView: View {
    let url: URL
    @State private var document: PDFDocument?

    var body: some View {
        Group {
            if let document {
                PDFViewer(document: document)
            } else {
                Text("Could not open this PDF.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(url.lastPathComponent)
        .onAppear {
            // Files picked by the user need "permission" to be read
            let hasAccess = url.startAccessingSecurityScopedResource()
            document = PDFDocument(url: url)
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }
    }
}

// Puts Apple's PDFView (an AppKit view) inside SwiftUI
struct PDFViewer: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
