import SwiftUI
import AppKit

// The start of the app: one window that shows the home screen.
@main
struct PDFKitMacApp: App {
    init() {
        // Needed so the window comes to the front when started from Terminal
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("PDF Kit") {
            ContentView()
                .frame(minWidth: 720, minHeight: 560)
        }
    }
}

// Which screen is showing
enum Screen: Hashable {
    case viewer(URL)
    case merge
    case split
    case pageTools
    case sign(URL)
    case edit(URL)
    case convert
    case pdfInfo
    case protect
    case unlock
    case watermark
    case pageNumbers
    case compress
    case grayscale
    case pdfToText
    case extractImages
    case ocr
    case fillForm
    case comingSoon(String)
}

struct ContentView: View {
    @State private var path: [Screen] = []

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(path: $path)
                .navigationDestination(for: Screen.self) { screen in
                    switch screen {
                    case .viewer(let url):
                        ViewerView(url: url)
                    case .merge:
                        MergeView(path: $path)
                    case .split:
                        SplitView()
                    case .pageTools:
                        PageToolsView(path: $path)
                    case .sign(let url):
                        SignView(url: url, path: $path)
                    case .edit(let url):
                        EditView(url: url, path: $path)
                    case .convert:
                        ConvertView(path: $path)
                    case .pdfInfo:
                        PdfInfoView(path: $path)
                    case .protect:
                        ProtectView(path: $path)
                    case .unlock:
                        UnlockView(path: $path)
                    case .watermark:
                        WatermarkView(path: $path)
                    case .pageNumbers:
                        PageNumbersView(path: $path)
                    case .compress:
                        CompressView(path: $path)
                    case .grayscale:
                        GrayscaleView(path: $path)
                    case .pdfToText:
                        PdfToTextView(path: $path)
                    case .extractImages:
                        ExtractImagesView(path: $path)
                    case .ocr:
                        OcrView(path: $path)
                    case .fillForm:
                        FormView(path: $path)
                    case .comingSoon(let name):
                        ComingSoonView(name: name)
                    }
                }
        }
    }
}

// Shown for tools that are not built yet
struct ComingSoonView: View {
    let name: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hammer")
                .font(.system(size: 40))
                .foregroundStyle(Theme.blue)
            Text(name).font(.title2.bold())
            Text("Coming soon to the Mac version.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .navigationTitle(name)
    }
}
