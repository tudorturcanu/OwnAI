import SwiftUI

/// The empty-state and onboarding hero: a four-point star in the app's own
/// accent that breathes slowly, with two smaller twinkles that fade in and
/// out. Drawn in SwiftUI so it always follows the palette; the old Lottie
/// composition carried a baked-in orange/pink gradient that no tint could
/// override. Stills itself under Reduce Motion.
struct SparkleView: View {
    var size: CGFloat = 120

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    @State private var orbiting = false

    var body: some View {
        ZStack {
            // Soft halo behind the star.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.brandAccent.opacity(0.18), Color.brandAccent.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.55
                    )
                )
                .frame(width: size * 1.1, height: size * 1.1)
                .scaleEffect(breathing ? 1.06 : 0.96)

            FourPointStar()
                .fill(LinearGradient.brandAccent)
                .frame(width: size * 0.62, height: size * 0.62)
                .scaleEffect(breathing ? 1.0 : 0.94)
                .rotationEffect(.degrees(breathing ? 3 : -3))

            // Twinkle and dot ride a slow orbit around the star.
            ZStack {
                FourPointStar()
                    .fill(Color.brandAccent)
                    .frame(width: size * 0.16, height: size * 0.16)
                    .offset(x: size * 0.28, y: -size * 0.26)
                    .opacity(breathing ? 1 : 0.35)

                Circle()
                    .fill(Color.brandAccentDeep)
                    .frame(width: size * 0.05, height: size * 0.05)
                    .offset(x: -size * 0.3, y: size * 0.22)
                    .opacity(breathing ? 0.4 : 1)
            }
            .rotationEffect(.degrees(orbiting ? 360 : 0))
            .animation(
                reduceMotion ? nil : .linear(duration: 24).repeatForever(autoreverses: false),
                value: orbiting
            )
        }
        .frame(width: size, height: size)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
            value: breathing
        )
        .onAppear {
            guard !reduceMotion else { return }
            breathing = true
            orbiting = true
        }
        .accessibilityHidden(true)
    }
}

/// Four-point star with concave sides, the shape the sparkle hero is built from.
struct FourPointStar: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.24
        var path = Path()
        for index in 0..<8 {
            let angle = Angle.degrees(Double(index) * 45 - 90).radians
            let radius = index.isMultiple(of: 2) ? outer : inner
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if index == 0 {
                path.move(to: point)
            } else {
                // Curve through the inner points so the sides bow inward.
                let previousAngle = Angle.degrees(Double(index - 1) * 45 - 90).radians
                let previousRadius = (index - 1).isMultiple(of: 2) ? outer : inner
                let previous = CGPoint(x: center.x + cos(previousAngle) * previousRadius, y: center.y + sin(previousAngle) * previousRadius)
                let control = CGPoint(x: (previous.x + point.x) / 2 + (center.x - (previous.x + point.x) / 2) * 0.35,
                                      y: (previous.y + point.y) / 2 + (center.y - (previous.y + point.y) / 2) * 0.35)
                path.addQuadCurve(to: point, control: control)
            }
        }
        path.closeSubpath()
        return path
    }
}

#Preview {
    SparkleView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.adaptiveBackground)
}
