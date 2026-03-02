import SwiftUI

struct ThinkingBubble: View {
    @State private var animationStep = 0
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Assistant Avatar/Icon
            Image(systemName: "sparkles")
                .font(.system(size: 20))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange, .pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(8)
                .background(Color.white)
                .clipShape(Circle())
                .shadow(color: Color.black.opacity(0.05), radius: 2)
            
            // Thinking dots
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Color(white: 0.6))
                        .frame(width: 6, height: 6)
                        .scaleEffect(animationStep == index ? 1.2 : 0.8)
                        .opacity(animationStep == index ? 1.0 : 0.4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(white: 0.95))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            
            Spacer()
        }
        .padding(.trailing, 60)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                // We'll use a timer instead for discrete steps
            }
            startTimer()
        }
    }
    
    private func startTimer() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                animationStep = (animationStep + 1) % 3
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
