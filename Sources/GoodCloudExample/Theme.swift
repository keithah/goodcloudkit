import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Color {
    /// A color that adapts between light and dark appearance without needing an asset catalog.
    static func adaptive(light: Color, dark: Color) -> Color {
        #if os(macOS)
        return Color(NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        }))
        #else
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #endif
    }
}

/// Central design tokens for the demo app: a single accent color, card surfaces, and semantic
/// success/danger colors, all of which adapt to light and dark appearance.
enum Theme {
    static let accent = Color.adaptive(
        light: Color(red: 0.13, green: 0.47, blue: 0.98),
        dark: Color(red: 0.40, green: 0.66, blue: 1.0)
    )

    static let pageBackground = Color.adaptive(
        light: Color(red: 0.95, green: 0.96, blue: 0.98),
        dark: Color(red: 0.07, green: 0.07, blue: 0.09)
    )

    static let cardBackground = Color.adaptive(
        light: Color.white,
        dark: Color(red: 0.13, green: 0.13, blue: 0.15)
    )

    static let secondaryText = Color.adaptive(
        light: Color(white: 0.45),
        dark: Color(white: 0.65)
    )

    static let success = Color.adaptive(
        light: Color(red: 0.16, green: 0.66, blue: 0.33),
        dark: Color(red: 0.32, green: 0.78, blue: 0.46)
    )

    static let danger = Color.adaptive(
        light: Color(red: 0.82, green: 0.20, blue: 0.24),
        dark: Color(red: 0.95, green: 0.38, blue: 0.38)
    )

    static let cardCornerRadius: CGFloat = 12
}
