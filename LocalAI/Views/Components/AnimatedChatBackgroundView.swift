import SwiftUI

struct AnimatedChatBackgroundView: View {
    let isEmpty: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: 12.0) / 12.0
            let angle = phase * Double.pi * 2.0

            LinearGradient(
                stops: [
                    .init(color: Color(
                        red: 0.9 + 0.05 * sin(angle),
                        green: 0.85 + 0.05 * cos(angle),
                        blue: 1.0
                    ), location: 0),
                    .init(color: Color(
                        red: 1.0,
                        green: 0.95 + 0.03 * sin(angle + 1),
                        blue: 0.9 + 0.04 * cos(angle + 1)
                    ), location: 0.5),
                    .init(color: .white, location: 1.0)
                ],
                startPoint: UnitPoint(
                    x: 0.0 + 0.15 * sin(angle),
                    y: 0.0 + 0.1 * cos(angle)
                ),
                endPoint: UnitPoint(
                    x: 1.0 - 0.1 * cos(angle),
                    y: 1.0 - 0.15 * sin(angle)
                )
            )
        }
        .opacity(isEmpty ? 1 : 0.3)
        .animation(.default, value: isEmpty)
    }
}
