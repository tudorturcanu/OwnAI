import Observation
import SwiftUI
import UIKit

// MARK: - Design language: Paper & Ink
//
// The app dresses like a well-set page: cool neutral paper, ink type,
// one deep teal accent, serif display headings and hairline rules instead of
// drop shadows. Every screen reads from the tokens below; individual views
// should not invent their own colours or heading fonts.
//
// Light mode is off-white paper with white cards on top. Dark mode keeps the
// same idea inverted — near-black slate paper with raised, slightly lighter
// cards — so the elevation ladder (paper → card → elevated card) survives the
// appearance switch.

enum AppDesign {
    /// Radius for cards, sheets and the composer.
    static let cardRadius: CGFloat = 18
    /// Radius for small controls, chips and icon wells.
    static let controlRadius: CGFloat = 12
    /// Width of the hairline rule drawn around raised surfaces.
    static let hairlineWidth: CGFloat = 1
    /// Widest the transcript and composer grow on regular widths (iPad, a
    /// Pro Max in landscape, iPhone Duo's inner display). Wider than any
    /// compact iPhone, so phones in portrait are unaffected.
    static let readableContentWidth: CGFloat = 720
}

/// Dismisses a sheet or cover. On iOS 26 it's the system close button: a
/// symbol with a "Close" title. The HIG asks for symbols over text-only bar
/// buttons because iPhone Duo's side toolbars keep text labels in a
/// horizontal bar. Earlier systems keep the familiar text button.
struct SheetCloseButton: View {
    var title: String = String(localized: "Done")
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: action)
        } else {
            Button(title, action: action)
        }
    }
}

extension View {
    /// Caps content at a comfortable line length and centers it, while the
    /// surrounding container (scroll view, background) stays full width.
    func readableContentWidth() -> some View {
        frame(maxWidth: AppDesign.readableContentWidth)
            .frame(maxWidth: .infinity)
    }
}

private enum Palette {
    // Light
    static var paperLight: UIColor { AppTheme.shared.paper.lightPaper }
    static var cardLight: UIColor { AppTheme.shared.paper.lightCard }
    static let elevatedLight = UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)
    static let inkLight = UIColor(red: 0.08, green: 0.10, blue: 0.11, alpha: 1)           // #14191C

    // Dark
    static var paperDark: UIColor { AppTheme.shared.paper.darkPaper }
    static var cardDark: UIColor { AppTheme.shared.paper.darkCard }
    static let elevatedDark = UIColor(red: 0.150, green: 0.170, blue: 0.185, alpha: 1)    // #262B2F
    static let inkDark = UIColor(red: 0.92, green: 0.94, blue: 0.94, alpha: 1)            // #EBF0F0

    static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    /// `base` moved `amount` (0...1) of the way toward `tint`.
    static func mix(_ base: UIColor, _ tint: UIColor, _ amount: CGFloat) -> UIColor {
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        base.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        tint.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        return UIColor(red: br + (tr - br) * amount, green: bg + (tg - bg) * amount, blue: bb + (tb - bb) * amount, alpha: 1)
    }
}

// MARK: - Original (system) palette
//
// The look the app shipped with before the Paper & Ink themes: the system blue
// accent, system-provided backgrounds and elevations, and pure grayscale. The
// brand tokens below fall back to these values whenever the user keeps (or
// returns to) the Original appearance, so the whole app reverts without any
// call site having to change.
private enum ClassicPalette {
    /// System blue, matching the `.blue` the app used at every accent call site.
    static var accent: UIColor { .systemBlue }
    static let deepLight = UIColor(red: 0.10, green: 0.42, blue: 0.85, alpha: 1)
    static let deepDark = UIColor(red: 0.14, green: 0.46, blue: 0.92, alpha: 1)
    static let light = UIColor(red: 0.45, green: 0.70, blue: 1.0, alpha: 1)

    // The original bubble was a saturated blue with white text. Because the ink
    // token is shared with primary body text, the bubble is kept as a light
    // blue tint here so the (dark) ink still reads on it.
    private static let bubbleBlue = UIColor(red: 0.20, green: 0.50, blue: 0.90, alpha: 1)
    static var userBubbleLight: UIColor { Palette.mix(.white, bubbleBlue, 0.16) }
    static var userBubbleDeepLight: UIColor { Palette.mix(.white, bubbleBlue, 0.27) }
    static var userBubbleDark: UIColor { Palette.mix(.secondarySystemBackground, bubbleBlue, 0.28) }
    static var userBubbleDeepDark: UIColor { Palette.mix(.secondarySystemBackground, bubbleBlue, 0.20) }
}

// MARK: - Accent themes

/// The accent colours a user can pick in Settings. Each carries a light-mode
/// and a dark-mode trio: the accent itself, a deeper shade for gradient ends
/// and pressed states, and a lighter tint for highlights.
enum AppAccentTheme: String, CaseIterable, Identifiable {
    case teal, ocean, violet, rose, amber, forest, graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .teal: return String(localized: "Teal")
        case .ocean: return String(localized: "Ocean")
        case .violet: return String(localized: "Violet")
        case .rose: return String(localized: "Rose")
        case .amber: return String(localized: "Amber")
        case .forest: return String(localized: "Forest")
        case .graphite: return String(localized: "Graphite")
        }
    }

    struct Swatch {
        let accent: UIColor
        let deep: UIColor
        let light: UIColor

        init(_ accent: (Double, Double, Double), _ deep: (Double, Double, Double), _ light: (Double, Double, Double)) {
            self.accent = UIColor(red: accent.0, green: accent.1, blue: accent.2, alpha: 1)
            self.deep = UIColor(red: deep.0, green: deep.1, blue: deep.2, alpha: 1)
            self.light = UIColor(red: light.0, green: light.1, blue: light.2, alpha: 1)
        }
    }

    var lightSwatch: Swatch {
        switch self {
        case .teal: return Swatch((0.18, 0.64, 0.58), (0.12, 0.52, 0.47), (0.40, 0.80, 0.72))
        case .ocean: return Swatch((0.16, 0.47, 0.80), (0.10, 0.36, 0.66), (0.45, 0.70, 0.92))
        case .violet: return Swatch((0.44, 0.36, 0.78), (0.34, 0.26, 0.66), (0.66, 0.60, 0.92))
        case .rose: return Swatch((0.82, 0.34, 0.48), (0.68, 0.24, 0.38), (0.95, 0.62, 0.72))
        case .amber: return Swatch((0.82, 0.52, 0.14), (0.68, 0.40, 0.08), (0.96, 0.74, 0.40))
        case .forest: return Swatch((0.22, 0.56, 0.36), (0.14, 0.44, 0.28), (0.50, 0.78, 0.58))
        case .graphite: return Swatch((0.30, 0.34, 0.38), (0.20, 0.24, 0.28), (0.55, 0.60, 0.65))
        }
    }

    var darkSwatch: Swatch {
        switch self {
        case .teal: return Swatch((0.36, 0.80, 0.74), (0.26, 0.68, 0.62), (0.58, 0.90, 0.84))
        case .ocean: return Swatch((0.42, 0.68, 0.95), (0.30, 0.56, 0.86), (0.62, 0.80, 0.98))
        case .violet: return Swatch((0.66, 0.60, 0.95), (0.55, 0.48, 0.88), (0.80, 0.76, 0.98))
        case .rose: return Swatch((0.95, 0.55, 0.66), (0.88, 0.44, 0.56), (0.98, 0.74, 0.80))
        case .amber: return Swatch((0.96, 0.70, 0.32), (0.90, 0.58, 0.20), (0.99, 0.84, 0.55))
        case .forest: return Swatch((0.42, 0.78, 0.55), (0.30, 0.66, 0.44), (0.62, 0.88, 0.70))
        case .graphite: return Swatch((0.68, 0.72, 0.76), (0.55, 0.60, 0.65), (0.82, 0.85, 0.88))
        }
    }

    /// Preview colours for a swatch picker, following the current appearance.
    var accentColor: Color { Palette.dynamic(light: lightSwatch.accent, dark: darkSwatch.accent) }
    var deepColor: Color { Palette.dynamic(light: lightSwatch.deep, dark: darkSwatch.deep) }
    var lightColor: Color { Palette.dynamic(light: lightSwatch.light, dark: darkSwatch.light) }
}

/// The tone of the page itself: neutral off-white, a warm cream, or a cool
/// blue-grey. Cards follow the paper so they always sit one step above it.
enum AppPaperTone: String, CaseIterable, Identifiable {
    case neutral, warm, cool

    var id: String { rawValue }

    var title: String {
        switch self {
        case .neutral: return String(localized: "Neutral")
        case .warm: return String(localized: "Warm")
        case .cool: return String(localized: "Cool")
        }
    }

    var lightPaper: UIColor {
        switch self {
        case .neutral: return UIColor(red: 0.953, green: 0.957, blue: 0.949, alpha: 1)  // #F3F4F2
        case .warm: return UIColor(red: 0.965, green: 0.955, blue: 0.935, alpha: 1)     // #F6F3EE
        case .cool: return UIColor(red: 0.945, green: 0.955, blue: 0.965, alpha: 1)     // #F1F4F6
        }
    }

    var lightCard: UIColor {
        switch self {
        case .neutral: return UIColor(red: 0.992, green: 0.992, blue: 0.988, alpha: 1)
        case .warm: return UIColor(red: 0.995, green: 0.992, blue: 0.984, alpha: 1)
        case .cool: return UIColor(red: 0.988, green: 0.992, blue: 0.996, alpha: 1)
        }
    }

    var darkPaper: UIColor {
        switch self {
        case .neutral: return UIColor(red: 0.060, green: 0.070, blue: 0.078, alpha: 1)
        case .warm: return UIColor(red: 0.075, green: 0.070, blue: 0.064, alpha: 1)
        case .cool: return UIColor(red: 0.055, green: 0.065, blue: 0.082, alpha: 1)
        }
    }

    var darkCard: UIColor {
        switch self {
        case .neutral: return UIColor(red: 0.105, green: 0.120, blue: 0.132, alpha: 1)
        case .warm: return UIColor(red: 0.125, green: 0.118, blue: 0.108, alpha: 1)
        case .cool: return UIColor(red: 0.100, green: 0.115, blue: 0.135, alpha: 1)
        }
    }
}

// MARK: - Colour style

/// Which of the two colour worlds the app wears.
///
/// `.original` is the look the app shipped with: the system blue accent, the
/// system's own backgrounds and elevations, and the system font. This is the
/// default, so a fresh install always opens in the original appearance and the
/// accent / paper themes are strictly opt-in.
///
/// `.modern` turns on the Paper & Ink design: the user's chosen accent theme,
/// the warm paper tones and the serif display headings.
enum AppColorStyle: String, CaseIterable, Identifiable {
    case original, modern

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return String(localized: "Original")
        case .modern: return String(localized: "Modern")
        }
    }

    var subtitle: String {
        switch self {
        case .original: return String(localized: "The classic system look.")
        case .modern: return String(localized: "Paper & ink, with a colour of your choice.")
        }
    }
}

/// The selected accent theme and paper tone. Views that read `Color.brandAccent`,
/// `Color.adaptiveBackground` and friends inside their body observe this
/// object, so a change re-renders them live.
@Observable
final class AppTheme {
    static let shared = AppTheme()
    private static let styleKey = "appColorStyle"
    private static let accentKey = "appAccentTheme"
    private static let paperKey = "appPaperTone"

    /// The colour world the app wears. Defaults to `.original`, so the app
    /// always ships and first launches in the classic system look; the accent
    /// and paper themes only take effect once the user switches to `.modern`.
    var style: AppColorStyle {
        didSet {
            UserDefaults.standard.set(style.rawValue, forKey: Self.styleKey)
            AppAppearance.apply()
            applyAppIcon()
        }
    }

    var accent: AppAccentTheme {
        didSet {
            UserDefaults.standard.set(accent.rawValue, forKey: Self.accentKey)
            applyAppIcon()
        }
    }

    var paper: AppPaperTone {
        didSet { UserDefaults.standard.set(paper.rawValue, forKey: Self.paperKey) }
    }

    /// When on, the Home Screen icon is swapped for the variant tinted in the
    /// current accent. Off by default: iOS shows a system alert on every icon
    /// change, so this is something people opt into.
    var matchesAppIcon: Bool {
        didSet {
            UserDefaults.standard.set(matchesAppIcon, forKey: Self.iconKey)
            applyAppIcon()
        }
    }

    private static let iconKey = "appIconMatchesAccent"

    private init() {
        let storedStyle = UserDefaults.standard.string(forKey: Self.styleKey) ?? ""
        style = AppColorStyle(rawValue: storedStyle) ?? .original
        let storedAccent = UserDefaults.standard.string(forKey: Self.accentKey) ?? ""
        accent = AppAccentTheme(rawValue: storedAccent) ?? .teal
        let storedPaper = UserDefaults.standard.string(forKey: Self.paperKey) ?? ""
        paper = AppPaperTone(rawValue: storedPaper) ?? .neutral
        matchesAppIcon = UserDefaults.standard.bool(forKey: Self.iconKey)
    }

    /// Asset catalog name of the icon variant for the current accent.
    private var desiredIconName: String? {
        guard style == .modern, matchesAppIcon else { return nil }
        return "AppIcon-" + accent.rawValue.prefix(1).uppercased() + accent.rawValue.dropFirst()
    }

    /// Pending icon swap. Each theme write cancels the previous one, so
    /// skimming through accent swatches performs a single swap (and a single
    /// system alert) for where the finger stopped, not one per swatch.
    @ObservationIgnored private var pendingIconSwap: Task<Void, Never>?

    /// Swaps the Home Screen icon to match the accent (or back to the default).
    /// No-op when nothing would change, so launches never trigger the alert.
    func applyAppIcon() {
        pendingIconSwap?.cancel()
        pendingIconSwap = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            let application = UIApplication.shared
            guard application.supportsAlternateIcons else { return }
            let target = self.desiredIconName
            guard application.alternateIconName != target else { return }
            do {
                try await application.setAlternateIconName(target)
            } catch {
                // The icon is cosmetic; a failure here is not worth surfacing.
            }
        }
    }
}

extension Color {
    private static var themeLight: AppAccentTheme.Swatch { AppTheme.shared.accent.lightSwatch }
    private static var themeDark: AppAccentTheme.Swatch { AppTheme.shared.accent.darkSwatch }

    /// Whether the app is wearing the original system look. Read inside the
    /// token accessors below (and thus inside the view bodies that call them),
    /// so flipping the style in Settings re-renders every themed surface.
    private static var isOriginal: Bool { AppTheme.shared.style == .original }

    /// The one brand colour, chosen by the user in Settings. Buttons, links,
    /// active states, tints. Falls back to the system blue in the original look.
    static var brandAccent: Color {
        isOriginal ? Color(uiColor: ClassicPalette.accent)
                   : Palette.dynamic(light: themeLight.accent, dark: themeDark.accent)
    }
    /// Darker shade for the far end of accent gradients and pressed states.
    static var brandAccentDeep: Color {
        isOriginal ? Palette.dynamic(light: ClassicPalette.deepLight, dark: ClassicPalette.deepDark)
                   : Palette.dynamic(light: themeLight.deep, dark: themeDark.deep)
    }
    /// Lighter end of the accent gradient: highlights and the top of hero fills.
    static var brandAccentLight: Color {
        isOriginal ? Color(uiColor: ClassicPalette.light)
                   : Palette.dynamic(light: themeLight.light, dark: themeDark.light)
    }
    /// Tinted well behind an accent glyph or chip label.
    static var brandAccentSoft: Color { brandAccent.opacity(0.12) }
    /// Primary text and the user's own chat bubble. Follows the system label
    /// colour in the original look.
    static var brandInk: Color {
        isOriginal ? Color(uiColor: .label)
                   : Palette.dynamic(light: Palette.inkLight, dark: Palette.inkDark)
    }
    /// The user's own chat bubble: a soft accent tint with ink text, so it reads
    /// as a highlight on the page rather than a dark block.
    static var userBubble: Color {
        isOriginal
            ? Palette.dynamic(light: ClassicPalette.userBubbleLight, dark: ClassicPalette.userBubbleDark)
            : Palette.dynamic(
                light: Palette.mix(Palette.elevatedLight, themeLight.accent, 0.16),
                dark: Palette.mix(Palette.cardDark, themeDark.accent, 0.26)
            )
    }
    static var userBubbleDeep: Color {
        isOriginal
            ? Palette.dynamic(light: ClassicPalette.userBubbleDeepLight, dark: ClassicPalette.userBubbleDeepDark)
            : Palette.dynamic(
                light: Palette.mix(Palette.elevatedLight, themeLight.accent, 0.27),
                dark: Palette.mix(Palette.cardDark, themeDark.accent, 0.18)
            )
    }
    /// Hairline rule around cards, chips and the composer. The original look
    /// leaned on drop shadows, so it uses the quiet system separator here.
    static var brandHairline: Color {
        if isOriginal {
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(white: 1, alpha: 0.14)
                    : UIColor.separator.resolvedColor(with: traits)
            })
        }
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.14)
                : Palette.inkLight.withAlphaComponent(0.12)
        })
    }

    /// Grayscale that follows the page. In the modern look values map onto the
    /// ink→paper axis so "gray" fills pick up the surface warmth; in the
    /// original look they are the pure black↔white grayscale the app shipped
    /// with. Dark mode mirrors the value either way.
    static func adaptive(white value: Double, opacity: Double = 1) -> Color {
        let clampedValue = min(max(value, 0), 1)
        let original = isOriginal
        return Color(uiColor: UIColor { traits in
            let resolvedValue = traits.userInterfaceStyle == .dark
                ? 1 - clampedValue
                : clampedValue
            if original {
                return UIColor(white: resolvedValue, alpha: opacity)
            }
            return blend(Palette.inkLight, Palette.elevatedLight, fraction: resolvedValue, alpha: opacity)
        })
    }

    private static func blend(_ from: UIColor, _ to: UIColor, fraction: Double, alpha: Double) -> UIColor {
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        from.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        to.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        let f = CGFloat(fraction)
        return UIColor(
            red: fr + (tr - fr) * f,
            green: fg + (tg - fg) * f,
            blue: fb + (tb - fb) * f,
            alpha: alpha
        )
    }

    /// The base layer a screen paints edge to edge, behind everything else.
    /// System background in the original look; off-white paper (never pure
    /// white or black) in the modern look, so cards have something to sit above.
    static var adaptiveBackground: Color {
        isOriginal ? Color(uiColor: .systemBackground)
                   : Palette.dynamic(light: Palette.paperLight, dark: Palette.paperDark)
    }

    /// Base for settings-style screens whose content is a stack of cards.
    /// The original look paints the system grouped grey here so white cards
    /// read as raised, exactly like iOS Settings; on the plain system
    /// background a white card is invisible in light mode. The modern look
    /// already separates paper from card, so it keeps the paper base.
    static var adaptiveGroupedBackground: Color {
        isOriginal ? Color(uiColor: .systemGroupedBackground) : adaptiveBackground
    }

    /// Card/sheet surface: one step up from the background. Dark mode needs a
    /// raised system fill so cards don't dissolve into the black base.
    static var adaptiveCard: Color {
        if isOriginal {
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? .secondarySystemBackground : .systemBackground
            })
        }
        return Palette.dynamic(light: Palette.cardLight, dark: Palette.cardDark)
    }

    /// Rim-light border for raised surfaces. `opacity` scales the hairline so
    /// existing call sites that pass 0.4–0.5 land on a visible but quiet rule.
    static func adaptiveBorder(opacity: Double) -> Color {
        if isOriginal {
            return Color(uiColor: .separator).opacity(opacity)
        }
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.28 * opacity)
                : Palette.inkLight.withAlphaComponent(0.24 * opacity)
        })
    }

    /// A card that sits on top of another card: the second step up.
    static var adaptiveElevatedCard: Color {
        if isOriginal {
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? .tertiarySystemBackground : .systemBackground
            })
        }
        return Palette.dynamic(light: Palette.elevatedLight, dark: Palette.elevatedDark)
    }

    /// Edge for a card nested inside another card. Dark mode only in the
    /// original look — light mode relied on the drop shadow there.
    static var adaptiveNestedCardBorder: Color {
        if isOriginal {
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : .clear
            })
        }
        return brandHairline
    }

    /// Separator between rows inside a card. Tuned to read on the raised card
    /// colour at a full point, not a device pixel.
    static var adaptiveSeparator: Color {
        if isOriginal {
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(white: 1, alpha: 0.22)
                    : UIColor.separator.resolvedColor(with: traits)
            })
        }
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.18)
                : Palette.inkLight.withAlphaComponent(0.10)
        })
    }
}

/// Lets `.foregroundStyle(.brandAccent)` and `.tint(.brandAccent)` read the
/// same way `.blue` used to at the hundreds of existing call sites.
extension ShapeStyle where Self == Color {
    static var brandAccent: Color { Color.brandAccent }
    static var brandAccentDeep: Color { Color.brandAccentDeep }
    static var brandAccentLight: Color { Color.brandAccentLight }
    static var brandAccentSoft: Color { Color.brandAccentSoft }
    static var brandInk: Color { Color.brandInk }
    static var brandHairline: Color { Color.brandHairline }
}

extension LinearGradient {
    /// Mint → teal → deep teal. The decorative gradient behind heroes,
    /// primary buttons and icon wells.
    static var brandAccent: LinearGradient {
        LinearGradient(
            colors: [Color.brandAccentLight, Color.brandAccent, Color.brandAccentDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Fill for the user's message bubble.
    static var userBubble: LinearGradient {
        LinearGradient(
            colors: [Color.userBubble, Color.userBubbleDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Soft tinted well behind an accent glyph.
    static var brandAccentSoft: LinearGradient {
        LinearGradient(
            colors: [Color.brandAccentLight.opacity(0.22), Color.brandAccentDeep.opacity(0.10)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension Font {
    /// Display face for headings and hero copy. Serif in the modern look; the
    /// plain system face in the original look, which never used serif. Body
    /// text stays in the system sans for readability at small sizes.
    static func display(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        let design: Font.Design = AppTheme.shared.style == .modern ? .serif : .default
        return .system(style, design: design).weight(weight)
    }
}

/// Row separator inside a card, for the grouped settings-style lists.
///
/// Drawn at a full point rather than deferring to `Divider()`'s single device
/// pixel: on the warm card surfaces a hairline disappears at 3×.
struct CardDivider: View {
    var leadingInset: CGFloat = 0

    var body: some View {
        Color.adaptiveSeparator
            .frame(height: 1)
            .padding(.leading, leadingInset)
    }
}

/// Hairline rule plus card fill, the standard treatment for a raised surface.
struct PaperCardModifier: ViewModifier {
    var radius: CGFloat = AppDesign.cardRadius
    var fill: Color = .adaptiveCard

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(Color.brandHairline, lineWidth: AppDesign.hairlineWidth))
    }
}

extension View {
    /// Paper card: warm fill with a hairline rule, no drop shadow.
    func paperCard(radius: CGFloat = AppDesign.cardRadius, fill: Color = .adaptiveCard) -> some View {
        modifier(PaperCardModifier(radius: radius, fill: fill))
    }
}

/// Serif titles in UIKit-owned chrome (navigation bars), matching `Font.display`
/// — in the modern look only. The original look keeps the system nav-bar font,
/// so this clears any serif styling when that style is active.
///
/// `UINavigationBar.appearance()` only affects bars created afterwards, so a
/// switch made at runtime fully lands on the next launch; already-visible bars
/// keep their current font until they are recreated.
enum AppAppearance {
    static func apply() {
        let navigation = UINavigationBar.appearance()

        guard AppTheme.shared.style == .modern else {
            navigation.largeTitleTextAttributes = nil
            navigation.titleTextAttributes = nil
            return
        }

        let large = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .largeTitle)
        let inline = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .headline)

        if let serifLarge = large.withDesign(.serif)?.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.bold]]) {
            navigation.largeTitleTextAttributes = [.font: UIFont(descriptor: serifLarge, size: 0)]
        }
        if let serifInline = inline.withDesign(.serif)?.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]]) {
            navigation.titleTextAttributes = [.font: UIFont(descriptor: serifInline, size: 0)]
        }
    }
}

/// Stock `List`/`Form` screens: swap the stock grouped background for the
/// theme's grouped base so they match the hand-built card screens.
struct PaperListModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Color.adaptiveGroupedBackground.ignoresSafeArea())
    }
}

extension View {
    func paperList() -> some View {
        modifier(PaperListModifier())
    }
}


/// Fade-and-rise entrance for a group of views that appear together. Each
/// element starts `index * 70 ms` after the previous one. Under Reduce Motion
/// everything is simply visible.
struct StaggeredEntrance: ViewModifier {
    let index: Int
    let appeared: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let shown = appeared || reduceMotion
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 16)
            .scaleEffect(shown ? 1 : 0.98)
            .animation(
                reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.82).delay(Double(index) * 0.07),
                value: shown
            )
    }
}

extension View {
    func staggeredEntrance(index: Int, appeared: Bool, reduceMotion: Bool) -> some View {
        modifier(StaggeredEntrance(index: index, appeared: appeared, reduceMotion: reduceMotion))
    }
}
