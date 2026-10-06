import SwiftUI
import AppKit

// The same colours as the Android app (blue / teal / orange), for light and dark mode.
enum Theme {
    static let blue = adaptive(light: 0x2F5BB7, dark: 0xB0C6FF)
    static let blueContainer = adaptive(light: 0xD9E2FF, dark: 0x13439D)
    static let onBlueContainer = adaptive(light: 0x001945, dark: 0xD9E2FF)

    static let teal = adaptive(light: 0x006A63, dark: 0x82D5CB)
    static let tealContainer = adaptive(light: 0x9EF2E7, dark: 0x00504A)
    static let onTealContainer = adaptive(light: 0x00201E, dark: 0x9EF2E7)

    static let orange = adaptive(light: 0x9A4600, dark: 0xFFB68B)
    static let orangeContainer = adaptive(light: 0xFFDBC8, dark: 0x763400)
    static let onOrangeContainer = adaptive(light: 0x321300, dark: 0xFFDBC8)

    static let background = adaptive(light: 0xF8F9FC, dark: 0x111318)
    static let surfaceLow = adaptive(light: 0xF2F3F7, dark: 0x1A1C20)

    // Makes a colour that switches by itself when the Mac is in dark mode
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        })
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum TileColor {
    case blue, orange, teal

    var background: Color {
        switch self {
        case .blue: Theme.blueContainer
        case .orange: Theme.orangeContainer
        case .teal: Theme.tealContainer
        }
    }

    var foreground: Color {
        switch self {
        case .blue: Theme.onBlueContainer
        case .orange: Theme.onOrangeContainer
        case .teal: Theme.onTealContainer
        }
    }
}
