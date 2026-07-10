import SwiftUI

struct SparkleView: View {
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
    }
}
