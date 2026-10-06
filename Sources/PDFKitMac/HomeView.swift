import SwiftUI
import UniformTypeIdentifiers

// One tool on the home screen (same list as the Android app)
struct Feature: Identifiable {
    let id = UUID()
    let icon: String       // SF Symbol name
    let title: String
    let subtitle: String
    let color: TileColor
    var opensPdf = false   // true = pick a PDF and open it in the viewer
    var screen: Screen?    // the tool screen to go to (nil = coming soon)
}

// The big tiles
let mainFeatures = [
    Feature(icon: "doc.text", title: "View PDF", subtitle: "Read and zoom", color: .blue, opensPdf: true),
    Feature(icon: "pencil", title: "Edit PDF", subtitle: "Draw, text, shapes", color: .orange),
    Feature(icon: "arrow.left.arrow.right", title: "Convert", subtitle: "To and from PDF", color: .teal),
    Feature(icon: "arrow.triangle.merge", title: "Merge PDFs", subtitle: "Combine into one", color: .teal, screen: .merge),
    Feature(icon: "arrow.triangle.branch", title: "Split PDF", subtitle: "Cut into parts", color: .orange, screen: .split),
    Feature(icon: "square.grid.2x2", title: "Page Tools", subtitle: "Rotate, sort, delete", color: .blue, screen: .pageTools),
    Feature(icon: "signature", title: "Sign PDF", subtitle: "Add your signature", color: .orange)
]

// The smaller tools, in groups
let toolGroups: [(String, [Feature])] = [
    ("Scan & text", [
        Feature(icon: "doc.viewfinder", title: "Scan document", subtitle: "Camera to PDF, auto crop", color: .blue),
        Feature(icon: "character.bubble", title: "Recognize text (OCR)", subtitle: "Make scans searchable", color: .teal),
        Feature(icon: "doc.plaintext", title: "PDF to text", subtitle: "Save all words as .txt", color: .teal),
        Feature(icon: "photo.on.rectangle", title: "Extract images", subtitle: "Save the pictures inside", color: .teal)
    ]),
    ("Edit & secure", [
        Feature(icon: "square.and.pencil", title: "Fill form", subtitle: "Type into PDF forms", color: .orange),
        Feature(icon: "lock", title: "Protect PDF", subtitle: "Add a password", color: .orange),
        Feature(icon: "lock.open", title: "Remove password", subtitle: "When you know it", color: .orange),
        Feature(icon: "drop", title: "Watermark", subtitle: "Text or logo on every page", color: .blue),
        Feature(icon: "list.number", title: "Page numbers", subtitle: "Number every page", color: .teal),
        Feature(icon: "info.circle", title: "PDF info", subtitle: "Title, author and more", color: .blue)
    ]),
    ("Optimize", [
        Feature(icon: "arrow.down.right.and.arrow.up.left", title: "Compress PDF", subtitle: "Make the file smaller", color: .teal),
        Feature(icon: "circle.lefthalf.filled", title: "Grayscale", subtitle: "Black & white pages", color: .blue)
    ])
]

struct HomeView: View {
    @Binding var path: [Screen]
    @State private var showPicker = false

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 28)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(mainFeatures) { feature in
                        FeatureCard(feature: feature) { open(feature) }
                    }
                }

                ForEach(toolGroups, id: \.0) { group in
                    Text(group.0)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                        .padding(.bottom, 8)

                    VStack(spacing: 0) {
                        ForEach(group.1) { tool in
                            ToolRow(feature: tool) { open(tool) }
                        }
                    }
                    .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 20))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("PDF Kit")
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result {
                path.append(.viewer(url))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppLogo(size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("PDF Kit").font(.title.bold())
                Text("What would you like to do today?")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func open(_ feature: Feature) {
        if feature.opensPdf {
            showPicker = true
        } else if let screen = feature.screen {
            path.append(screen)
        } else {
            path.append(.comingSoon(feature.title))
        }
    }
}

// A big coloured tile
struct FeatureCard: View {
    let feature: Feature
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: feature.icon)
                    .font(.system(size: 26))
                Spacer(minLength: 0)
                Text(feature.title).font(.headline)
                Text(feature.subtitle).font(.subheadline).opacity(0.8)
            }
            .foregroundStyle(feature.color.foreground)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .padding(18)
            .background(feature.color.background, in: RoundedRectangle(cornerRadius: 24))
            .contentShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }
}

// One line in a tool group
struct ToolRow: View {
    let feature: Feature
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: feature.icon)
                    .font(.system(size: 17))
                    .foregroundStyle(feature.color.foreground)
                    .frame(width: 40, height: 40)
                    .background(feature.color.background, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.title)
                    Text(feature.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Simple stand-in for the app logo (the real icon comes in a later step)
struct AppLogo: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28)
            .fill(Theme.blue)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "doc.richtext")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.white)
            )
    }
}
