import SwiftUI
import UIKit

// Keep the existing grayscale call sites while adapting their luminance to the
// system appearance. A value that is dark in light mode becomes correspondingly
// light in dark mode, which preserves the intended contrast hierarchy.
/// Row separator inside a card, for the grouped settings-style lists.
///
/// Dark mode draws a full point rather than deferring to `Divider()`'s single
/// device pixel: at 3× a hairline is a third of a point, and against the
/// raised card surface that disappears. Light mode keeps the stock `Divider()`
/// untouched — the complaint, and the measurement, were dark-mode only.
struct CardDivider: View {
    var leadingInset: CGFloat = 0

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if colorScheme == .dark {
                Color.adaptiveSeparator
                    .frame(height: 1)
            } else {
                Divider()
            }
        }
        .padding(.leading, leadingInset)
    }
}

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

    /// The base layer a screen paints edge to edge, behind everything else.
    /// Pure black in dark mode, which is what gives `adaptiveCard` something
    /// to sit above.
    static var adaptiveBackground: Color {
        Color(uiColor: .systemBackground)
    }

    /// Card/sheet surface that follows the system appearance.
    ///
    /// In dark mode this has to be a *raised* surface, not `.systemBackground`:
    /// that resolves to pure black, the same value the base layer paints, so
    /// cards used to dissolve into the background with only a hairline border
    /// separating them. `.secondarySystemBackground` is the system's own
    /// one-step elevation and reads as a card sitting on the base. Light mode
    /// deliberately keeps plain white — cards there already separate from the
    /// grey backgrounds behind them, and swapping in a tint would change an
    /// appearance that is not the problem.
    static var adaptiveCard: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? .secondarySystemBackground
                : .systemBackground
        })
    }

    /// Rim-light border for glass/material surfaces.
    static func adaptiveBorder(opacity: Double) -> Color {
        Color(uiColor: .separator).opacity(opacity)
    }

    /// A card that sits on top of another card.
    ///
    /// Dark mode needs a second step up the elevation ladder: `adaptiveCard`
    /// drawn on `adaptiveCard` is the same colour, so a nested card dissolves
    /// into its container the same way cards used to dissolve into the base
    /// background. The drop shadow that separates them in light mode is black,
    /// so it contributes nothing here. Light mode stays plain white — the
    /// shadow already does the work there.
    static var adaptiveElevatedCard: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? .tertiarySystemBackground
                : .systemBackground
        })
    }

    /// Edge for a card nested inside another card.
    ///
    /// Dark mode only. One step up the elevation ladder is a real but modest
    /// change in fill, so a nested card also gets a rim to define its edge.
    /// Light mode is `.clear` deliberately: the drop shadow already separates
    /// the two surfaces there, and that is the appearance nobody complained
    /// about.
    static var adaptiveNestedCardBorder: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.14)
                : .clear
        })
    }

    /// Separator between rows inside a card.
    ///
    /// `.separator` — what a plain `Divider()` uses — is tuned for Apple's own
    /// compact table rows. Measured against the raised card colour it lands at
    /// only about 2:1, which at a single device pixel is close to invisible on
    /// the taller, icon-led rows here. Dark mode gets a brighter value; light
    /// mode keeps the system one, which already reads fine on white.
    static var adaptiveSeparator: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.22)
                : .separator
        })
    }
}
