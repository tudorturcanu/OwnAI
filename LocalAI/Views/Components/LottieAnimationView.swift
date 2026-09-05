import SwiftUI
import Lottie

/// The bundled Lottie compositions in `LocalAI/Animations`. Keeping them as
/// an enum means a typo is a compile error rather than a silently empty view.
enum AppAnimation: String {
    /// Gradient four-point star with twinkles and orbiting dots. Loops.
    case sparkleHero = "sparkle-hero"
    /// Green circle pops in, then a tick draws itself. Plays once.
    case successCheck = "success-check"
    /// Five pulsing bars, tinted via `.tint`. Loops.
    case voiceWave = "voice-wave"
    /// A bookmark ribbon settles in with a small overshoot and wiggle. Plays once.
    case bookmarkPop = "bookmark-pop"
    /// An arrow bobs down into a tray, landing with a small pulse. Loops.
    case downloadIdle = "download-idle"

    /// Frame progress shown when Reduce Motion is on: the resting pose of
    /// each composition, never a mid-transition frame.
    var stillProgress: AnimationProgressTime {
        switch self {
        case .sparkleHero: return 0
        case .successCheck: return 1
        case .voiceWave: return 0.25
        case .bookmarkPop: return 1
        case .downloadIdle: return 0
        }
    }

    /// Fill/stroke keypaths that take the SwiftUI `.tint` colour. Compositions
    /// with baked-in gradients or multi-colour palettes leave this empty.
    var tintableKeypaths: [String] {
        switch self {
        case .sparkleHero: return []
        case .successCheck: return ["Circle.**.Circle Fill.Color"]
        case .voiceWave: return ["**.Bar Fill.Color"]
        case .bookmarkPop: return ["Bookmark.**.Bookmark Fill.Color"]
        case .downloadIdle: return ["**.Arrow Stroke.Color", "**.Tray Stroke.Color"]
        }
    }
}

/// SwiftUI wrapper around Lottie's `LottieView` with the app's conventions
/// baked in: honours Reduce Motion by showing a still frame, is hidden from
/// VoiceOver (callers label the surrounding element), and recolours the
/// composition from the environment tint where the animation allows it.
struct AppLottieView: View {
    let animation: AppAnimation
    /// false plays the composition once and holds its final frame.
    var loops: Bool = true
    var speed: Double = 1
    /// Overrides the environment tint for the tintable keypaths.
    var tint: Color? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.self) private var environment

    var body: some View {
        var view = LottieView(animation: .named(animation.rawValue))
            .resizable()
            .animationSpeed(speed)
            .playbackMode(
                reduceMotion
                    ? .paused(at: .progress(animation.stillProgress))
                    : .playing(.fromProgress(0, toProgress: 1, loopMode: loops ? .loop : .playOnce))
            )

        if let lottieColor = resolvedTint {
            for keypath in animation.tintableKeypaths {
                view = view.valueProvider(
                    ColorValueProvider(lottieColor),
                    for: AnimationKeypath(keypath: keypath)
                )
            }
        }

        return view.accessibilityHidden(true)
    }

    private var resolvedTint: LottieColor? {
        guard !animation.tintableKeypaths.isEmpty else { return nil }
        let color = (tint ?? .accentColor).resolve(in: environment)
        return LottieColor(
            r: Double(color.red),
            g: Double(color.green),
            b: Double(color.blue),
            a: Double(color.opacity)
        )
    }
}

#Preview("Animations") {
    VStack(spacing: 32) {
        AppLottieView(animation: .sparkleHero)
            .frame(width: 140, height: 140)
        AppLottieView(animation: .successCheck, loops: false, tint: .green)
            .frame(width: 60, height: 60)
        AppLottieView(animation: .voiceWave, tint: .blue)
            .frame(width: 30, height: 20)
        AppLottieView(animation: .bookmarkPop, loops: false, tint: .orange)
            .frame(width: 48, height: 48)
        AppLottieView(animation: .downloadIdle, tint: .blue)
            .frame(width: 64, height: 64)
    }
    .padding()
}
