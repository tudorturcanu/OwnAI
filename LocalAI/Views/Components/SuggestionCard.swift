import SwiftUI

struct SuggestionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var cardWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 280 : 210
    }
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.orange, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.orange.opacity(0.12), .pink.opacity(0.12)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Color.adaptive(white: 0.1))
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.adaptive(white: 0.4))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(width: cardWidth, alignment: .topLeading)
            .frame(minHeight: 110)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.adaptiveCard.opacity(0.7))
                    .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.adaptiveBorder(opacity: 0.5), lineWidth: 1)
            )
        }
        .buttonStyle(PressedScaleButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(String(localized: "Sends this as your first message."))
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.1).ignoresSafeArea()
        SuggestionCard(icon: "lightbulb.fill", title: "Tell me", subtitle: "something fascinating") {}
    }
}
