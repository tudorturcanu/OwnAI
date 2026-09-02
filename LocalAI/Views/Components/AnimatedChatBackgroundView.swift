import SwiftUI

struct AnimatedChatBackgroundView: View {
    let isEmpty: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Base background
            Color.adaptiveCard.ignoresSafeArea()
            
            // Aurora Blobs. Keep a still composition when Reduce Motion is on
            // instead of continuously moving decorative content.
            if reduceMotion {
                aurora(time: 0)
            } else {
                TimelineView(.animation) { timeline in
                    aurora(time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.5), value: isEmpty)
        .ignoresSafeArea()
    }

    private func aurora(time: TimeInterval) -> some View {
        Canvas { context, size in
            let t = time

            func drawBlob(at center: CGPoint, color: Color, radius: CGFloat, offset: CGFloat) {
                let x = center.x + cos(t * 0.4 + offset) * 60
                let y = center.y + sin(t * 0.6 + offset) * 60
                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                context.fill(Circle().path(in: rect), with: .color(color))
            }

            context.addFilter(.blur(radius: 100))
            let baseOpacity = isEmpty ? 0.18 : 0.05

            drawBlob(
                at: CGPoint(x: size.width * 0.2, y: size.height * 0.2),
                color: Color.blue.opacity(baseOpacity),
                radius: size.width * 0.5,
                offset: 0
            )
            drawBlob(
                at: CGPoint(x: size.width * 0.8, y: size.height * 0.3),
                color: Color.purple.opacity(baseOpacity),
                radius: size.width * 0.6,
                offset: 2
            )
            drawBlob(
                at: CGPoint(x: size.width * 0.4, y: size.height * 0.7),
                color: Color.teal.opacity(baseOpacity * 0.7),
                radius: size.width * 0.5,
                offset: 4
            )
            drawBlob(
                at: CGPoint(x: size.width * 0.7, y: size.height * 0.8),
                color: Color.pink.opacity(baseOpacity * 0.5),
                radius: size.width * 0.4,
                offset: 5
            )
        }
        .accessibilityHidden(true)
    }
}
