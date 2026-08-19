import SwiftUI

// The app is light-mode only. These helpers keep call sites unchanged from
// when they supported dark mode, but now just wrap fixed grayscale values.
extension Color {
    static func adaptive(white value: Double, opacity: Double = 1) -> Color {
        Color(white: value, opacity: opacity)
    }

    /// Card/sheet surface. Pure white.
    static var adaptiveCard: Color {
        adaptive(white: 1.0)
    }

    /// Rim-light border for glass/material surfaces.
    static func adaptiveBorder(opacity: Double) -> Color {
        Color.white.opacity(opacity)
    }
}
