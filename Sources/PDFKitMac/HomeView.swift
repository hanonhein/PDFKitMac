import SwiftUI
import UniformTypeIdentifiers

// One tool on the home screen (same list as the Android app)
struct Feature: Identifiable {
    let id = UUID()
    let icon: String       // SF Symbol name
    let title: String
    let subtitle: String
    let color: TileColor
    var opensPdf: ((URL) -> Screen)?   // pick a PDF first, then go to this screen
    var screen: Screen?    // the tool screen to go to (nil = coming soon)
}

// The big tiles
let mainFeatures = [
    Feature(icon: "doc.text", title: "View PDF", subtitle: "Read and zoom", color: .blue, opensPdf: { .viewer($0) }),
    Feature(icon: "pencil", title: "Edit PDF", subtitle: "Draw, text, shapes", color: .orange, opensPdf: { .edit($0) }),
    Feature(icon: "arrow.left.arrow.right", title: "Convert", subtitle: "To and from PDF", color: .teal, screen: .convert),
    Feature(icon: "arrow.triangle.merge", title: "Merge PDFs", subtitle: "Combine into one", color: .teal, screen: .merge),
    Feature(icon: "arrow.triangle.branch", title: "Split PDF", subtitle: "Cut into parts", color: .orange, screen: .split),
    Feature(icon: "square.grid.2x2", title: "Page Tools", subtitle: "Rotate, sort, delete", color: .blue, screen: .pageTools),
    Feature(icon: "signature", title: "Sign PDF", subtitle: "Add your signature", color: .orange, opensPdf: { .sign($0) })
]

// The smaller tools, in groups
let toolGroups: [(String, [Feature])] = [
    ("Scan & text", [
        Feature(icon: "doc.viewfinder", title: "Scan document", subtitle: "Camera to PDF, auto crop", color: .blue),
        Feature(icon: "character.bubble", title: "Recognize text (OCR)", subtitle: "Make scans searchable", color: .teal),
        Feature(icon: "doc.plaintext", title: "PDF to text", subtitle: "Save all words as .txt", color: .teal, screen: .pdfToText),
        Feature(icon: "photo.on.rectangle", title: "Extract images", subtitle: "Save the pictures inside", color: .teal, screen: .extractImages)
    ]),
    ("Edit & secure", [
        Feature(icon: "square.and.pencil", title: "Fill form", subtitle: "Type into PDF forms", color: .orange),
        Feature(icon: "lock", title: "Protect PDF", subtitle: "Add a password", color: .orange, screen: .protect),
        Feature(icon: "lock.open", title: "Remove password", subtitle: "When you know it", color: .orange, screen: .unlock),
        Feature(icon: "drop", title: "Watermark", subtitle: "Text or logo on every page", color: .blue, screen: .watermark),
        Feature(icon: "list.number", title: "Page numbers", subtitle: "Number every page", color: .teal, screen: .pageNumbers),
        Feature(icon: "info.circle", title: "PDF info", subtitle: "Title, author and more", color: .blue, screen: .pdfInfo)
    ]),
    ("Optimize", [
        Feature(icon: "arrow.down.right.and.arrow.up.left", title: "Compress PDF", subtitle: "Make the file smaller", color: .teal, screen: .compress),
        Feature(icon: "circle.lefthalf.filled", title: "Grayscale", subtitle: "Black & white pages", color: .blue, screen: .grayscale)
    ])
]

struct HomeView: View {
    @Binding var path: [Screen]
    @State private var showPicker = false
    @State private var afterPick: ((URL) -> Screen)?

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
                        .foregroundStyle(Theme.textSecondary)
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
            if case .success(let url) = result, let afterPick {
                path.append(afterPick(url))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppLogo(size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("PDF Kit").font(.title.bold()).foregroundStyle(Theme.text)
                Text("What would you like to do today?")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func open(_ feature: Feature) {
        if let opensPdf = feature.opensPdf {
            afterPick = opensPdf
            showPicker = true
        } else if let screen = feature.screen {
            path.append(screen)
        } else {
            path.append(.comingSoon(feature.title))
        }
    }
}

// A big tile: a card with a thin border and a coloured icon square (same as Android)
struct FeatureCard: View {
    let feature: Feature
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                IconBadge(icon: feature.icon, color: feature.color, size: 48)
                Spacer(minLength: 0)
                Text(feature.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(feature.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 118)
            .padding(16)
            .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.outlineVariant, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20))
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
                IconBadge(icon: feature.icon, color: feature.color, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.title).foregroundStyle(Theme.text)
                    Text(feature.subtitle).font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// The PDF Kit logo (same picture as Android, web and Windows), with rounded corners
struct AppLogo: View {
    let size: CGFloat
    private static let image = Bundle.main.url(forResource: "pdfkit-icon", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image).resizable()
            } else {
                Theme.blue   // only if the picture is missing
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28))
    }
}
