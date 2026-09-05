import SwiftUI

/// Soft aurora behind the chat transcript.
///
/// Deliberately not a `TimelineView(.animation)` + `Canvas`: that re-rasterized
/// four screen-sized circles through a 100 pt Gaussian blur on every display
/// frame for as long as the chat was open, which kept the GPU busy and the
/// phone warm even while idle. The blobs are now radial gradients (no blur
/// filter at all) whose offsets are animated once by Core Animation, so the
/// per-frame cost is a plain composite. Motion pauses whenever the scene is
/// not active and under Reduce Motion.
struct AnimatedChatBackgroundView: View {
    let isEmpty: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var drifting = false

    private struct Blob {
        let anchor: CGPoint      // fraction of the container size
        let color: Color
        let radiusFactor: CGFloat // fraction of the container width
        let opacityScale: Double
        let drift: CGSize        // travel from one extreme to the other
        let duration: Double
    }

    private let blobs: [Blob] = [
        Blob(anchor: CGPoint(x: 0.2, y: 0.2), color: .blue,   radiusFactor: 0.5, opacityScale: 1.0, drift: CGSize(width: 60, height: 60), duration: 16),
        Blob(anchor: CGPoint(x: 0.8, y: 0.3), color: .purple, radiusFactor: 0.6, opacityScale: 1.0, drift: CGSize(width: -60, height: 50), duration: 19),
        Blob(anchor: CGPoint(x: 0.4, y: 0.7), color: .teal,   radiusFactor: 0.5, opacityScale: 0.7, drift: CGSize(width: 50, height: -60), duration: 14),
        Blob(anchor: CGPoint(x: 0.7, y: 0.8), color: .pink,   radiusFactor: 0.4, opacityScale: 0.5, drift: CGSize(width: -55, height: -45), duration: 21)
    ]

    var body: some View {
        ZStack {
            Color.adaptiveBackground.ignoresSafeArea()

            GeometryReader { proxy in
                let size = proxy.size
                let baseOpacity = isEmpty ? 0.18 : 0.05

                ZStack {
                    ForEach(blobs.indices, id: \.self) { index in
                        let blob = blobs[index]
                        let radius = size.width * blob.radiusFactor
                        // Gradient extends past the nominal radius to mimic the
                        // soft edge the old 100 pt blur produced.
                        let outer = radius + 100
                        let color = blob.color.opacity(baseOpacity * blob.opacityScale)

                        Circle()
                            .fill(
                                RadialGradient(
                                    stops: [
                                        .init(color: color, location: 0),
                                        .init(color: color, location: radius / outer * 0.6),
                                        .init(color: color.opacity(0), location: 1)
                                    ],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: outer
                                )
                            )
                            .frame(width: outer * 2, height: outer * 2)
                            .position(x: size.width * blob.anchor.x, y: size.height * blob.anchor.y)
                            .offset(
                                x: drifting ? blob.drift.width / 2 : -blob.drift.width / 2,
                                y: drifting ? blob.drift.height / 2 : -blob.drift.height / 2
                            )
                            .animation(
                                drifting
                                    ? .easeInOut(duration: blob.duration).repeatForever(autoreverses: true)
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
