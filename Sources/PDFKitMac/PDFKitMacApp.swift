import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The start of the app: one window that shows the home screen.
@main
struct PDFKitMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("themeMode") private var themeMode = ThemeMode.system

    init() {
        // Needed so the window comes to the front when started from Terminal
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        Window("PDF Editor Kit", id: "main") {
            ContentView()
                .frame(minWidth: 720, minHeight: 560)
                .onAppear { themeMode.apply() }
                .onChange(of: themeMode) { themeMode.apply() }
        }
        .commands {
            // File > Open PDF… (⌘O)
            CommandGroup(replacing: .newItem) {
                Button("Open PDF…") { Router.shared.choosePdf() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }

        // PDF Editor Kit > Settings… (⌘,)
        Settings {
            SettingsView(showsAbout: true)
                .frame(width: 520, height: 560)
        }
    }
}

// Opens PDFs given by Finder: "Open With", or dropped on the Dock icon
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        if let pdf = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) { Router.shared.open(pdf) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
    case scan
    case settings
    case about
}

// The screens, shared so the menu and Finder can open a PDF too
final class Router: ObservableObject {
    static let shared = Router()
    @Published var path: [Screen] = []

    func open(_ url: URL) {
        path = [.viewer(url)]
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func choosePdf() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
}

struct ContentView: View {
    @ObservedObject private var router = Router.shared

    var body: some View {
        NavigationStack(path: $router.path) {
            HomeView(path: $router.path)
                .navigationDestination(for: Screen.self) { screen in
                    destination(screen)
                }
        }
        // drop a PDF anywhere on the home screen to open it
        .dropDestination(for: URL.self) { urls, _ in
            guard router.path.isEmpty, let pdf = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
            router.open(pdf)
            return true
        }
    }

    @ViewBuilder
    private func destination(_ screen: Screen) -> some View {
        let path = $router.path
        switch screen {
        case .viewer(let url): ViewerView(url: url)
        case .merge: MergeView(path: path)
        case .split: SplitView()
        case .pageTools: PageToolsView(path: path)
        case .sign(let url): SignView(url: url, path: path)
        case .edit(let url): EditView(url: url, path: path)
        case .convert: ConvertView(path: path)
        case .pdfInfo: PdfInfoView(path: path)
        case .protect: ProtectView(path: path)
        case .unlock: UnlockView(path: path)
        case .watermark: WatermarkView(path: path)
        case .pageNumbers: PageNumbersView(path: path)
        case .compress: CompressView(path: path)
        case .grayscale: GrayscaleView(path: path)
        case .pdfToText: PdfToTextView(path: path)
        case .extractImages: ExtractImagesView(path: path)
        case .ocr: OcrView(path: path)
        case .fillForm: FormView(path: path)
        case .scan: ScanView(path: path)
        case .settings: SettingsView(showsAbout: false, path: path)
        case .about: AboutView()
        }
    }
}
