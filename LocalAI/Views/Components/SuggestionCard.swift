import SwiftUI

struct SuggestionCard: View {
    let title: String
    let subtitle: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color(white: 0.1))
                    .fixedSize(horizontal: false, vertical: true)
                
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color(white: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(width: 210, alignment: .topLeading)
            .frame(minHeight: 100)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.7))
                    .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.1).ignoresSafeArea()
        SuggestionCard(title: "Tell me", subtitle: "something fascinating") {}
    }
}
