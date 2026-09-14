import SwiftUI

/// Warm paper behind the chat transcript.
///
/// Two soft radial washes — a terracotta glow high on the page and a faint
/// ink shadow low on it — give the paper a little depth without turning it
/// into a screen-saver. The washes are plain radial gradients (no blur filter)
/// whose offsets are animated once by Core Animation, so the per-frame cost is
/// a single composite. Motion pauses whenever the scene is not active and
/// under Reduce Motion.
struct AnimatedChatBackgroundView: View {
    let isEmpty: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var drifting = false

    private struct Wash {
        let anchor: CGPoint       // fraction of the container size
        let color: Color
        let radiusFactor: CGFloat // fraction of the container width
        let opacityScale: Double
        let drift: CGSize         // travel from one extreme to the other
        let duration: Double
    }

    private let washes: [Wash] = [
        Wash(anchor: CGPoint(x: 0.82, y: 0.12), color: .brandAccentLight, radiusFactor: 0.55, opacityScale: 1.1, drift: CGSize(width: -40, height: 30), duration: 22),
        Wash(anchor: CGPoint(x: 0.18, y: 0.88), color: .brandInk, radiusFactor: 0.6, opacityScale: 0.35, drift: CGSize(width: 40, height: -30), duration: 26)
    ]

    var body: some View {
        ZStack {
            Color.adaptiveBackground.ignoresSafeArea()

            // Vertical wash: mint at the top of the page fading to plain paper
            // by the middle, with a whisper of teal returning at the bottom.
            LinearGradient(
                stops: [
                    .init(color: Color.brandAccentLight.opacity(isEmpty ? 0.30 : 0.14), location: 0),
                    .init(color: Color.brandAccent.opacity(isEmpty ? 0.10 : 0.05), location: 0.35),
                    .init(color: Color.brandAccent.opacity(0), location: 0.6),
                    .init(color: Color.brandAccentDeep.opacity(isEmpty ? 0.08 : 0.04), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            // Breathes between 85% and 115% strength on a slow cycle so the
            // page feels alive without ever drawing the eye.
            .opacity(drifting ? 1.15 : 0.85)
            .animation(
                drifting
                    ? .easeInOut(duration: 9).repeatForever(autoreverses: true)
                    : .easeInOut(duration: 0.6),
                value: drifting
            )
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.5), value: isEmpty)

            GeometryReader { proxy in
                let size = proxy.size
                let baseOpacity = isEmpty ? 0.16 : 0.06

                ZStack {
                    ForEach(washes.indices, id: \.self) { index in
                        let wash = washes[index]
                        let radius = size.width * wash.radiusFactor
                        let outer = radius + 120
                        let color = wash.color.opacity(baseOpacity * wash.opacityScale)

                        Circle()
                            .fill(
                                RadialGradient(
                                    stops: [
                                        .init(color: color, location: 0),
                                        .init(color: color, location: radius / outer * 0.5),
                                        .init(color: color.opacity(0), location: 1)
                                    ],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: outer
                                )
                            )
                            .frame(width: outer * 2, height: outer * 2)
                            .position(x: size.width * wash.anchor.x, y: size.height * wash.anchor.y)
                            .offset(
                                x: drifting ? wash.drift.width / 2 : -wash.drift.width / 2,
                                y: drifting ? wash.drift.height / 2 : -wash.drift.height / 2
                            )
                            .animation(
                                drifting
                                    ? .easeInOut(duration: wash.duration).repeatForever(autoreverses: true)
                                    : .easeInOut(duration: 0.6),
                                value: drifting
                            )
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.5), value: isEmpty)
            }
            .accessibilityHidden(true)
        }
        .ignoresSafeArea()
        .onAppear { updateDrifting() }
        .onChange(of: scenePhase) { _, _ in updateDrifting() }
        .onChange(of: reduceMotion) { _, _ in updateDrifting() }
    }

    private func updateDrifting() {
        let shouldDrift = !reduceMotion && scenePhase == .active
        if drifting != shouldDrift {
            drifting = shouldDrift
        }
    }
}

#Preview {
    AnimatedChatBackgroundView(isEmpty: true)
}
