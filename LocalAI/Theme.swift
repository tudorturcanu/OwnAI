import SwiftUI
import UIKit

// Keep the existing grayscale call sites while adapting their luminance to the
// system appearance. A value that is dark in light mode becomes correspondingly
// light in dark mode, which preserves the intended contrast hierarchy.
extension Color {
    static func adaptive(white value: Double, opacity: Double = 1) -> Color {
        let clampedValue = min(max(value, 0), 1)
        return Color(uiColor: UIColor { traits in
            let resolvedValue = traits.userInterfaceStyle == .dark
                ? 1 - clampedValue
                : clampedValue
            return UIColor(white: resolvedValue, alpha: opacity)
        })
    }

    /// Card/sheet surface that follows the system appearance.
    static var adaptiveCard: Color {
        Color(uiColor: .systemBackground)
    }

    /// Rim-light border for glass/material surfaces.
    static func adaptiveBorder(opacity: Double) -> Color {
        Color(uiColor: .separator).opacity(opacity)
    }
}
