import SwiftUI

// Settings and About (like Android SettingsScreen.kt and AboutScreen.kt).
// Left out on purpose: "Colors from wallpaper" (Android only) and ad privacy settings (the Mac app has no ads).

enum ThemeMode: String, CaseIterable, Identifiable {
    case system = "System default", light = "Light", dark = "Dark"
    var id: Self { self }

    // Light, dark, or follow the Mac
    func apply() {
        switch self {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

struct SettingsView: View {
    let showsAbout: Bool   // the ⌘, window shows About below; the screen in the app links to it
    var path: Binding<[Screen]>? = nil
    @AppStorage("themeMode") private var themeMode = ThemeMode.system

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OptionSection(title: "Theme") {
                    Picker("", selection: $themeMode) {
                        ForEach(ThemeMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                if showsAbout {
                    AboutContent()
                } else if let path {
                    Button { path.wrappedValue.append(.about) } label: {
                        HStack(spacing: 14) {
                            IconBadge(icon: "info.circle", color: .blue, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("About PDF Editor Kit").foregroundStyle(Theme.text)
                                Text("Version, privacy and other versions").font(.subheadline).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
                        }
                        .padding(14)
                        .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 20))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("Settings")
    }
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            AboutContent()
                .padding(24)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("About")
    }
}

struct AboutContent: View {
    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                AppLogo(size: 72)
                Text("PDF Editor Kit").font(.title2.bold()).foregroundStyle(Theme.text)
                Text("Version \(appVersion) for Mac").foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)

            OptionSection(title: "Your privacy") {
                promise("wifi.slash", "Works offline", "Every tool works without internet.")
                promise("lock", "Your files stay on your Mac", "Your PDFs are never uploaded.")
                promise("gift", "Free, no ads, no sign-up", "PDF Editor Kit for Mac is free to use.")
            }

            OptionSection(title: "Also on") {
                Text("Android, Windows and the web: the same app with the same tools.")
                    .foregroundStyle(Theme.textSecondary)
                Link("Website", destination: URL(string: "https://hanonhein.github.io/")!)
            }

            OptionSection(title: "Made with") {
                Text("Only Apple's own tools (SwiftUI, PDFKit, Vision, Core Image). No other companies' code is inside.")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func promise(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(icon: icon, color: .teal, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.text)
                Text(text).font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
