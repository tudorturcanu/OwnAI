import SwiftUI

/// The empty-state and onboarding hero: a gradient sparkle that breathes and
/// slowly turns, with twinkles and orbiting dots. Backed by the bundled
/// `sparkle-hero` Lottie composition, which stills itself under Reduce Motion
/// to match the static AnimatedChatBackgroundView behind it.
struct SparkleView: View {
    var size: CGFloat = 120

    var body: some View {
        AppLottieView(animation: .sparkleHero, speed: 0.9)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

#Preview {
    SparkleView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray.opacity(0.1))
}
