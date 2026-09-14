import SwiftUI

struct ThinkingBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Assistant Avatar/Icon
            Image(systemName: "sparkles")
                .font(.system(size: 20))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.brandAccent, .brandAccentDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(8)
                .background(Color.adaptiveCard)
                .clipShape(Circle())
                .shadow(color: Color.black.opacity(0.05), radius: 2)

            // Thinking dots
            dots
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.adaptive(white: 0.95))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Spacer()
        }
        .padding(.trailing, 60)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Thinking"))
    }

    /// Driven by TimelineView rather than a scheduled Timer. A Timer added to
    /// the default run-loop mode stops firing for as long as a scroll is
    /// tracking, so the indicator visibly froze whenever the user dragged the
    /// transcript while a reply was pending. The continuous phase also reads as
    /// one travelling wave instead of a three-step cycle.
    @ViewBuilder
    private var dots: some View {
        if reduceMotion {
            dotRow(phase: nil)
        } else {
            TimelineView(.animation) { timeline in
                dotRow(phase: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func dotRow(phase: TimeInterval?) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                // Each dot trails the one before it, so the crest travels left
                // to right. Nil phase (Reduce Motion) settles every dot at the
                // midpoint of its own range rather than freezing mid-wave.
                let wave = phase.map { sin($0 * 3.2 - Double(index) * 0.7) } ?? 0
                let level = (wave + 1) / 2

                Circle()
                    .fill(Color.adaptive(white: 0.6))
                    .frame(width: 6, height: 6)
                    .scaleEffect(0.8 + 0.4 * level)
                    .opacity(0.4 + 0.6 * level)
                    .offset(y: -2 * level)
            }
        }
    }
}

#Preview {
    VStack {
        ThinkingBubble()
        Spacer()
    }
    .padding()
    .background(Color.gray.opacity(0.1))
}
