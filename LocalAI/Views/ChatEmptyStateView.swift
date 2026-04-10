import SwiftUI

struct ChatEmptyStateView: View {
    let isInputFocused: Bool
    let selectedModelName: String?
    let isAppleIntelligenceAvailable: Bool
    let personalityLabel: (name: String, icon: String)?
    let onDownloadModel: () -> Void
    let onSuggestion: (String) -> Void

    var body: some View {
        VStack(spacing: 32) {
            modelStatusView
                .padding(.top, isInputFocused ? 10 : 20)

            if !isInputFocused {
                Spacer()
            }

            VStack(spacing: isInputFocused ? 12 : 24) {
                if !isInputFocused {
                    SparkleView()
                }

                VStack(spacing: 4) {
                    Text("Start a Conversation")
                        .font(isInputFocused ? .headline : .title2.bold())
                        .foregroundStyle(Color(white: 0.15))

                    if let selectedModelName {
                        Text("Using \(selectedModelName)")
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.4))
                    } else if !isAppleIntelligenceAvailable {
                        Button(action: onDownloadModel) {
                            HStack {
                                Image(systemName: "arrow.down.app")
                                Text("Download a Model")
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(Capsule())
                        }
                    } else {
                        Text("Select or download a model in Settings")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if let personalityLabel {
                        HStack(spacing: 4) {
                            Image(systemName: personalityLabel.icon)
                                .font(.caption2)
                            Text(LocalizedStringKey(personalityLabel.name))
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(Color(white: 0.45))
                        .padding(.top, 2)
                    }
                }
            }

            Spacer()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    SuggestionCard(icon: "lightbulb.fill", title: "Tell me", subtitle: "something fascinating") {
                        onSuggestion(String(localized: "Tell me something fascinating"))
                    }
                    SuggestionCard(icon: "atom", title: "Explain", subtitle: "complex topics simply") {
                        onSuggestion(String(localized: "Explain a complex topic like black holes simply"))
                    }
                    SuggestionCard(icon: "pencil.line", title: "Write", subtitle: "an email or story") {
                        onSuggestion(String(localized: "Write a short creative story about a robot"))
                    }
                    SuggestionCard(icon: "book.fill", title: "Discover", subtitle: "my next book") {
                        onSuggestion(String(localized: "Help me discover my next book"))
                    }
                    SuggestionCard(icon: "map.fill", title: "Plan", subtitle: "my weekend trip") {
                        onSuggestion(String(localized: "Help me plan a relaxing weekend trip"))
                    }
                    SuggestionCard(icon: "bolt.fill", title: "Boost", subtitle: "my productivity") {
                        onSuggestion(String(localized: "How can I boost my productivity?"))
                    }
                    SuggestionCard(icon: "ladybug.fill", title: "Debug", subtitle: "my code snippet") {
                        onSuggestion(String(localized: "Help me debug this Swift code snippet:\n"))
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
    }

    private var modelStatusView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(selectedModelName == nil ? Color.orange : Color.green)
                .frame(width: 8, height: 8)

            Text(selectedModelName == nil ? "No Model Selected" : "Ready to Chat")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color(white: 0.35))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.4), lineWidth: 1)
        )
    }
}
