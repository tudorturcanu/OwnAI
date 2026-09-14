import SwiftUI
import Shimmer

struct ChatEmptyStateView: View {
    let isInputFocused: Bool
    let selectedModelName: String?
    let downloadingModelName: String?
    /// 0...1 while a model download is running, nil otherwise.
    var downloadProgress: Double? = nil
    /// Preformatted progress detail, e.g. "42% · about 3 min left".
    var downloadDetail: String? = nil
    let isWarmingUp: Bool
    let isAppleIntelligenceAvailable: Bool
    let personalityLabel: (name: String, icon: String)?
    let onDownloadModel: () -> Void
    let onSuggestion: (ChatSuggestion) -> Void
    /// Starts the hands-free voice conversation. nil hides the invitation
    /// (voice mode disabled, or no model ready to talk to).
    var onVoiceConversation: (() -> Void)? = nil

    @State private var suggestions: [ChatSuggestion] = ChatSuggestions.pool.shuffled().prefix(7).map { $0 }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 32) {
            modelStatusView
                .padding(.top, isInputFocused ? 10 : 20)
                .staggeredEntrance(index: 0, appeared: appeared, reduceMotion: reduceMotion)

            if !isInputFocused {
                Spacer()
            }

            VStack(spacing: isInputFocused ? 12 : 24) {
                if !isInputFocused {
                    SparkleView(size: 140)
                        .staggeredEntrance(index: 1, appeared: appeared, reduceMotion: reduceMotion)
                }

                VStack(spacing: 4) {
                    Text(String(localized: "Start a Conversation"))
                        .font(isInputFocused ? .display(.headline) : .display(.title2, weight: .bold))
                        .foregroundStyle(Color.adaptive(white: 0.15))
                        .staggeredEntrance(index: 2, appeared: appeared, reduceMotion: reduceMotion)

                    if let selectedModelName {
                        Text(String(format: String(localized: "Using %@"), selectedModelName))
                            .font(.caption)
                            .foregroundStyle(Color.adaptive(white: 0.4))
                    } else if let downloadingModelName {
                        VStack(spacing: 10) {
                            HStack(spacing: 8) {
                                if downloadProgress == nil {
                                    ProgressView()
                                        .controlSize(.small)
                                }

                                Text(downloadStatusText(for: downloadingModelName))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.brandAccent)
                            }

                            if let downloadProgress {
                                ProgressView(value: downloadProgress)
                                    .progressViewStyle(.linear)
                                    .tint(.brandAccent)
                                    .frame(maxWidth: 220)
                            }

                            if let downloadDetail {
                                Text(downloadDetail)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(Color.adaptive(white: 0.45))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                            }

                            Text(String(localized: "You can type your first message now — it will send as soon as the model is ready."))
                                .font(.caption2)
                                .foregroundStyle(Color.adaptive(white: 0.5))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 260)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(Color.brandAccent.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .accessibilityElement(children: .combine)
                    } else if !isAppleIntelligenceAvailable {
                        Button(action: onDownloadModel) {
                            HStack {
                                Image(systemName: "arrow.down.app")
                                    .accessibilityHidden(true)
                                Text(String(localized: "Download a Model"))
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(.brandAccent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.brandAccent.opacity(0.1))
                            .clipShape(Capsule())
                        }
                    } else {
                        Button(action: onDownloadModel) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.stack.3d.up")
                                    .accessibilityHidden(true)
                                Text(String(localized: "Select or download a model in Settings"))
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.brandAccent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.brandAccent.opacity(0.1))
                            .clipShape(Capsule())
                        }
                    }

                    if selectedModelName != nil, let onVoiceConversation {
                        Button(action: onVoiceConversation) {
                            HStack(spacing: 8) {
                                AppLottieView(animation: .voiceWave, tint: .brandAccent)
                                    .frame(width: 21, height: 14)
                                Text(String(localized: "Try a Voice Conversation"))
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(.brandAccent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.brandAccent.opacity(0.1))
                            .clipShape(Capsule())
                        }
                        .padding(.top, 6)
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
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { offset, suggestion in
                        SuggestionCard(icon: suggestion.icon, title: suggestion.title, subtitle: suggestion.subtitle) {
                            onSuggestion(suggestion)
                        }
                        .staggeredEntrance(index: 3 + min(offset, 3), appeared: appeared, reduceMotion: reduceMotion)
                    }
                }
                .padding(.horizontal, 20)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            guard !appeared else { return }
            appeared = true
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
                .shimmering(active: isWarmingUp && !reduceMotion, bandSize: 0.22)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.adaptiveBorder(opacity: 0.4), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        if isWarmingUp {
            return .brandAccent
        }
        if selectedModelName != nil {
            return .green
        }
        if downloadingModelName != nil {
            return .brandAccent
        }
        return .brandAccent
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
