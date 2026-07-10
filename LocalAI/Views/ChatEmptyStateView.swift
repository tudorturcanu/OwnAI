import SwiftUI
import Shimmer

struct ChatEmptyStateView: View {
    let isInputFocused: Bool
    let selectedModelName: String?
    let downloadingModelName: String?
    let isWarmingUp: Bool
    let isAppleIntelligenceAvailable: Bool
    let personalityLabel: (name: String, icon: String)?
    let onDownloadModel: () -> Void
    let onSuggestion: (String) -> Void

    @State private var suggestions: [ChatSuggestion] = ChatSuggestions.pool.shuffled().prefix(7).map { $0 }

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
                    Text(String(localized: "Start a Conversation"))
                        .font(isInputFocused ? .headline : .title2.bold())
                        .foregroundStyle(Color.adaptive(white: 0.15))

                    if let selectedModelName {
                        Text(String(format: String(localized: "Using %@"), selectedModelName))
                            .font(.caption)
                            .foregroundStyle(Color.adaptive(white: 0.4))
                    } else if let downloadingModelName {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)

                            Text(downloadStatusText(for: downloadingModelName))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.blue)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(Capsule())
                    } else if !isAppleIntelligenceAvailable {
                        Button(action: onDownloadModel) {
                            HStack {
                                Image(systemName: "arrow.down.app")
                                    .accessibilityHidden(true)
                                Text(String(localized: "Download a Model"))
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(Capsule())
                        }
                    } else {
                        Text(String(localized: "Select or download a model in Settings"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if let personalityLabel {
                        HStack(spacing: 4) {
                            Image(systemName: personalityLabel.icon)
                                .font(.caption2)
                                .accessibilityHidden(true)
                            Text(LocalizedStringKey(personalityLabel.name))
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(Color.adaptive(white: 0.45))
                        .padding(.top, 2)
                    }
                }
            }

            Spacer()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(suggestions) { suggestion in
                        SuggestionCard(icon: suggestion.icon, title: suggestion.title, subtitle: suggestion.subtitle) {
                            onSuggestion(suggestion.prompt)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            suggestions = ChatSuggestions.pool.shuffled().prefix(7).map { $0 }
        }
    }

    private var modelStatusView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.adaptive(white: 0.35))
                .shimmering(active: isWarmingUp, bandSize: 0.22)
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

    private var statusColor: Color {
        if isWarmingUp {
            return .blue
        }
        if selectedModelName != nil {
            return .green
        }
        if downloadingModelName != nil {
            return .blue
        }
        return .orange
    }

    private var statusTitle: String {
        if isWarmingUp {
            return String(localized: "Warming up")
        }
        if selectedModelName != nil {
            return String(localized: "Ready to Chat")
        }
        if downloadingModelName != nil {
            return String(localized: "Downloading Model")
        }
        return String(localized: "No Model Selected")
    }

    private func downloadStatusText(for modelName: String) -> String {
        return String(
            format: String(
                localized: "Downloading %@",
                defaultValue: "Downloading %@"
            ),
            modelName
        )
    }
}
