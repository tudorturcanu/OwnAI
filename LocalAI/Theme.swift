import SwiftUI

// Central light/dark color mapping. The app's views were written against
// fixed light-mode grayscale values (`Color(white: x)`); `Color.adaptive`
// keeps those values in light mode and remaps them for dark mode, so every
// call site migrates mechanically without re-deciding each color's role.
//
// The mapping is piecewise by role, which correlates with lightness:
//   - dark values (< 0.6) are text -> flip to light text
//   - mid values (0.6..<0.88) are weak text/borders -> mid grays
//   - light values (>= 0.88) are surfaces -> dark surfaces, preserving the
//     relative elevation order (cards stay lighter than the screen behind
//     them, control fills stay darker than the card they sit on)
extension Color {
    static func adaptive(white value: Double, opacity: Double = 1) -> Color {
        Color(UIColor { traits in
            let resolved = traits.userInterfaceStyle == .dark ? darkValue(for: value) : value
            return UIColor(white: resolved, alpha: opacity)
        })
    }

    /// Card/sheet surface. Pure white in light mode; elevated dark gray in dark.
    static var adaptiveCard: Color {
        adaptive(white: 1.0)
    }

    private static func darkValue(for light: Double) -> Double {
        switch light {
        case ..<0.6:
            return min(0.95, 1.02 - light)
        case ..<0.88:
            return max(0.30, 1.15 - light)
        default:
            return 0.09 + (light - 0.88) * (0.08 / 0.12)
        }
    }
}
