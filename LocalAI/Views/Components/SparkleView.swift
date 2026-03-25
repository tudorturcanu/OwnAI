import SwiftUI

struct SparkleView: View {
    @State private var animate = false

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 60, weight: .light))
            .foregroundStyle(
                LinearGradient(
                    colors: [.orange.opacity(0.8), .pink.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .opacity(animate ? 1.0 : 0.3)
            .scaleEffect(animate ? 1.1 : 0.95)
            .animation(
                .easeInOut(duration: 2.5).repeatForever(autoreverses: true),
                value: animate
            )
            .onAppear {
                animate = true
            }
    }
}
