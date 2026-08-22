//
//  MessageBubble.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import SwiftUI
import MarkdownUI
import Shimmer

struct AsyncCodeBlockView: View {
    let content: String
    let language: String?
    let theme: CodeTheme
    let isStreaming: Bool
    let textScale: Double
    
    @State private var highlightedText: AttributedString?
    
    var body: some View {
        Text(displayText)
            .task(id: highlightTaskID) {
                guard !isStreaming else { return }
                do {
                    try await Task.sleep(nanoseconds: 150_000_000)
                    
                    let result = SyntaxHighlighter.highlight(content, language: language, theme: theme, textScale: textScale)
                    
                    guard !Task.isCancelled else { return }
                    highlightedText = result
                } catch { }
            }
            .padding(12)
            .frame(minWidth: 100, alignment: .leading)
    }

    private var displayText: AttributedString {
        if isStreaming {
            var plainText = AttributedString(content)
            plainText.font = .monospacedSystemFont(ofSize: CGFloat(13 * textScale), weight: .regular)
            plainText.foregroundColor = theme.foreground
            return plainText
        }

        return highlightedText ?? SyntaxHighlighter.plainText(content, theme: theme, textScale: textScale)
    }

    private var highlightTaskID: String {
        isStreaming ? "streaming|\(language ?? "")|\(theme.rawValue)" : "\(content.hashValue)|\(language ?? "")|\(theme.rawValue)"
    }
}

/// Renders an assistant message's markdown body. Extracted as its own
/// `Equatable` view so SwiftUI memoizes the (expensive) markdown parse to exactly
/// these value inputs: when content/theme/scale are unchanged the parse is
/// skipped even though the surrounding bubble re-evaluates (e.g. on every
/// streamed token tick for other on-screen messages). The equality surface is
/// only these four value-typed fields, so — unlike a hand-rolled `==` over the
/// whole bubble and its closures — it can't silently drift as the bubble grows.
struct AssistantMarkdownView: View, Equatable {
    let content: String
    let isStreaming: Bool
    let theme: CodeTheme
    let textScale: Double

    private static let lightHaptic = UIImpactFeedbackGenerator(style: .light)

    /// URL scheme used to make inline `[Source n]` citations tappable. Taps are
    /// intercepted by the enclosing message via `\.openURL`; see `MessageBubble`.
    static let sourceURLScheme = "localai-source"

    /// Matches the `[Source n]` markers the model is instructed to emit so they
    /// can be turned into tappable links that map to the numbered source chips.
    private static let sourceMarkerRegex = try? NSRegularExpression(
        pattern: #"\[Source (\d+)\]"#
    )

    /// Matches a complete bare `<svg>…</svg>` document sitting in prose. Small
    /// models often forget the ```svg fence, which would leave the markup
    /// rendered as plain paragraph text instead of reaching the preview.
    private static let bareSVGRegex = try? NSRegularExpression(
        pattern: #"<svg\b[\s\S]*?</svg>"#,
        options: [.caseInsensitive]
    )

    /// Wraps unfenced `<svg>…</svg>` documents in a ```svg fence so they route
    /// through `RenderableCodeBlockView`. Render-only, like `linkifySources`.
    /// Text already inside a fence must pass through untouched (a nested fence
    /// would split the block), so only the outside-fence segments are rewritten.
    static func fenceBareSVG(_ text: String) -> String {
        guard text.contains("<svg"), text.contains("</svg>"),
              let regex = bareSVGRegex else { return text }
        let segments = text.components(separatedBy: "```")
        let rewritten = segments.enumerated().map { index, segment -> String in
            guard index.isMultiple(of: 2) else { return segment }
            let range = NSRange(segment.startIndex..., in: segment)
            return regex.stringByReplacingMatches(
                in: segment,
                range: range,
                withTemplate: "\n```svg\n$0\n```\n"
            )
        }
        return rewritten.joined(separator: "```")
    }

    /// Rewrites `[Source n]` markers into markdown links (`[Source n](localai-source://n)`)
    /// without touching the persisted message — this is render-only.
    static func linkifySources(_ text: String) -> String {
        guard text.contains("[Source "), let regex = sourceMarkerRegex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "[Source $1](\(sourceURLScheme)://$1)"
        )
    }

    var body: some View {
        // Render with MarkdownUI for both the live (streaming) and finished reply.
        // The engine throttles UI updates (~12/sec, with adaptive back-off if a
        // parse is slow), so re-parsing the growing response stays smooth. Code
        // blocks fall back to plain text while streaming via AsyncCodeBlockView.
        Markdown(Self.linkifySources(Self.fenceBareSVG(content)))
            .markdownTextStyle(\.link) {
                ForegroundColor(.accentColor)
                FontWeight(.semibold)
            }
            .markdownTextStyle {
                FontSize(CGFloat(17 * textScale))
            }
            .foregroundStyle(Color.adaptive(white: 0.15))
            // MarkdownUI's basic theme draws tables with no rules or row fills,
            // which reads as loosely spaced text rather than a table. Grid lines
            // plus zebra rows keep columns legible on a phone-width bubble.
            .markdownBlockStyle(\.table) { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(color: Color.adaptive(white: 0.82)))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(
                            Color.adaptive(white: 1.0),
                            Color.adaptive(white: 0.96)
                        )
                    )
                    .markdownMargin(top: 8, bottom: 8)
            }
            .markdownBlockStyle(\.tableCell) { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 {
                            FontWeight(.semibold)
                        }
                        FontSize(CGFloat(15 * textScale))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                if RenderableCodeBlockView.isPreviewable(
                    language: configuration.language,
                    content: configuration.content
                ) {
                    RenderableCodeBlockView(
                        content: configuration.content,
                        language: configuration.language,
                        theme: theme,
                        isStreaming: isStreaming,
                        textScale: textScale
                    )
                } else {
                    codeBlock(configuration)
                }
            }
    }

    @ViewBuilder
    private func codeBlock(_ configuration: CodeBlockConfiguration) -> some View {
                VStack(spacing: 0) {
                    HStack {
                        Text(configuration.language?.lowercased() ?? "code")
                            .font(.caption.bold())
                            .foregroundStyle(theme.foreground.opacity(0.8))
                        Spacer()
                        Button {
                            UIPasteboard.general.string = configuration.content
                            Self.lightHaptic.impactOccurred()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption2)
                                Text("Copy")
                                    .font(.caption.bold())
                            }
                            .foregroundStyle(theme.foreground)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(theme.background)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(theme.headerBackground)

                    ScrollView(.horizontal, showsIndicators: true) {
                        AsyncCodeBlockView(
                            content: configuration.content,
                            language: configuration.language,
                            theme: theme,
                            isStreaming: isStreaming,
                            textScale: textScale
                        )
                    }
                    .background(theme.background)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.borderColor, lineWidth: 1)
                )
                .padding(.vertical, 8)
    }
}

/// Memoized render of the "thinking" markdown. Same rationale as
/// ``AssistantMarkdownView``: keyed on its value inputs (including the
/// expanded color state) so the parse is skipped when nothing relevant changed.
struct ThinkingMarkdownView: View, Equatable {
    let text: String
    let isExpanded: Bool

    var body: some View {
        Markdown(text)
            .font(.callout)
            .markdownTextStyle {
                ForegroundColor(isExpanded ? Color.adaptive(white: 0.66) : Color.adaptive(white: 0.86))
            }
            .foregroundStyle(isExpanded ? Color.adaptive(white: 0.86) : Color.adaptive(white: 0.66))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Animated "typing" indicator: a pulse travels across three dots, driven by
/// `PhaseAnimator` for a smooth, self-sustaining loop (no fragile one-shot state).
/// Under Reduce Motion it renders three calm static dots.
struct TypingDots: View {
    let gradient: LinearGradient
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            dots { _ in (1.0, 0.55) }
        } else {
            // Phases 0–2 light each dot in turn; phase 3 is a brief rest beat
            // before the wave restarts.
            PhaseAnimator([0, 1, 2, 3]) { phase in
                dots { index in
                    phase == index ? (1.35, 1.0) : (0.7, 0.4)
                }
            } animation: { _ in .easeInOut(duration: 0.28) }
        }
    }

    private func dots(
        _ style: @escaping (Int) -> (scale: CGFloat, opacity: Double)
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                let appearance = style(index)
                Circle()
                    .fill(gradient)
                    .frame(width: 4, height: 4)
                    .scaleEffect(appearance.scale)
                    .opacity(appearance.opacity)
            }
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let showsContinue: Bool
    let onContinue: (() -> Void)?
    let recoveryAction: RecoveryAction?
    let onEdit: ((ChatMessage) -> Void)?
    let onRegenerateMore: ((ChatMessage) -> Void)?
    let onRegenerateLess: ((ChatMessage) -> Void)?
    let smartReplyStyles: [SmartReplyStyle]
    let onSmartReplyStyle: ((ChatMessage, SmartReplyStyle) -> Void)?
    let followUpSuggestions: [String]
    let onBranchFromHere: ((ChatMessage) -> Void)?
    let onTogglePin: ((ChatMessage) -> Void)?
    let onSpeak: ((ChatMessage) -> Void)?
    let onSearchWeb: ((ChatMessage) -> Void)?
    let onFollowUp: ((ChatMessage, String) -> Void)?
    let showsQuickActions: Bool
    /// Only the active row observes this object. Completed rows and ChatView
    /// stay outside the token-by-token invalidation graph.
    let streamingState: ChatStreamingState?
    @AppStorage("codeTheme") private var codeThemeRaw = CodeTheme.defaultTheme.rawValue
    @AppStorage("messageTextScale") private var messageTextScale: Double = 1.0
    @Environment(SpeechManager.self) private var speechManager
    @Environment(ModelManager.self) private var modelManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var isThinkingExpanded = false
    @State private var showCopied = false
    @State private var showStats = false
    /// The `[Source n]` citation the reader last tapped, used to briefly pulse the
    /// matching chip so they can connect an inline citation to its document.
    @State private var highlightedSourceNumber: Int?
    @State private var highlightClearTask: Task<Void, Never>?
    private let userLeadingInset: CGFloat = 60
    private let assistantTrailingInset: CGFloat = 16
    private let collapsedThinkingHeight: CGFloat = 76
    private static let lightHaptic = UIImpactFeedbackGenerator(style: .light)

    init(
        message: ChatMessage,
        showsContinue: Bool = false,
        onContinue: (() -> Void)? = nil,
        recoveryAction: RecoveryAction? = nil,
        onEdit: ((ChatMessage) -> Void)? = nil,
        onRegenerateMore: ((ChatMessage) -> Void)? = nil,
        onRegenerateLess: ((ChatMessage) -> Void)? = nil,
        smartReplyStyles: [SmartReplyStyle] = [],
        onSmartReplyStyle: ((ChatMessage, SmartReplyStyle) -> Void)? = nil,
        followUpSuggestions: [String] = [],
        onBranchFromHere: ((ChatMessage) -> Void)? = nil,
        onTogglePin: ((ChatMessage) -> Void)? = nil,
        onSpeak: ((ChatMessage) -> Void)? = nil,
        onSearchWeb: ((ChatMessage) -> Void)? = nil,
        onFollowUp: ((ChatMessage, String) -> Void)? = nil,
        showsQuickActions: Bool = false,
        streamingState: ChatStreamingState? = nil
    ) {
        self.message = message
        self.showsContinue = showsContinue
        self.onContinue = onContinue
        self.recoveryAction = recoveryAction
        self.onEdit = onEdit
        self.onRegenerateMore = onRegenerateMore
        self.onRegenerateLess = onRegenerateLess
        self.smartReplyStyles = smartReplyStyles
        self.onSmartReplyStyle = onSmartReplyStyle
        self.followUpSuggestions = followUpSuggestions
        self.onBranchFromHere = onBranchFromHere
        self.onTogglePin = onTogglePin
        self.onSpeak = onSpeak
        self.onSearchWeb = onSearchWeb
        self.onFollowUp = onFollowUp
        self.showsQuickActions = showsQuickActions
        self.streamingState = streamingState
    }

    /// The message split into reasoning and answer. While the engine is
    /// producing a reply both the live buffer and the persisted placeholder
    /// hold the tagged form — history deliberately skips sanitizing on that hot
    /// path — so the split has to happen here. Rendering either one whole would
    /// print the chain of thought into the bubble as if it were the answer.
    private var displayedParts: AssistantOutputSanitizer.Parts {
        if let streamingState {
            return AssistantOutputSanitizer.parts(from: streamingState.content)
        }
        if message.isStreaming {
            return AssistantOutputSanitizer.parts(from: message.content)
        }
        return AssistantOutputSanitizer.Parts(
            content: message.content,
            thinkingContent: message.thinkingContent
        )
    }

    /// The text actually shown in the bubble — the live streaming answer while
    /// the engine is producing it, otherwise the persisted message content.
    private var displayedContent: String {
        displayedParts.content
    }

    /// Reasoning for the thinking card, live while streaming so the card fills
    /// in as the model works instead of appearing only once it finishes.
    private var displayedThinking: String {
        displayedParts.thinkingContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        let thinkingText = displayedThinking
        let hasThinking = !thinkingText.isEmpty
        let hasAnswerContent = !displayedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let sourceTitles = message.sourceTitles

        HStack(alignment: .top, spacing: 12) {
            if message.role == .user {
                Spacer(minLength: userLeadingInset)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                if message.role == .assistant && hasThinking {
                    thinkingCard(thinkingText: thinkingText, showsStreamingIndicator: message.isStreaming && !hasAnswerContent)
                }

                if message.role == .user || hasAnswerContent || !hasThinking {
                    messageCard
                        // Surface the context-menu actions to VoiceOver users
                        // directly on the message content.
                        .accessibilityActions {
                            Button(String(localized: "Copy")) {
                                copyAndShowToast(message.content)
                            }
                            if let onTogglePin {
                                Button(message.isPinned ? String(localized: "Unpin") : String(localized: "Pin")) {
                                    onTogglePin(message)
                                }
                            }
                            if let onSpeak, message.role == .assistant {
                                Button(String(localized: "Speak")) {
                                    onSpeak(message)
                                }
                            }
                        }
                }

                if message.role == .assistant && !sourceTitles.isEmpty {
                    sourceChips(sourceTitles)
                }

                if showsContinue, let onContinue {
                    actionButton(
                        title: "Continue",
                        systemImage: "arrow.trianglehead.clockwise",
                        action: onContinue
                    )
                }

                if let recoveryAction {
                    actionButton(
                        title: recoveryAction.title,
                        systemImage: recoveryAction.systemImage,
                        action: recoveryAction.action
                    )
                }

                if message.role == .assistant,
                   (!smartReplyStyles.isEmpty || !followUpSuggestions.isEmpty) {
                    assistantActionChips(
                        styles: smartReplyStyles,
                        suggestions: followUpSuggestions,
                        styleAction: { style in onSmartReplyStyle?(message, style) },
                        followUpAction: { suggestion in onFollowUp?(message, suggestion) }
                    )
                }

                // Quick Actions Bar for last assistant message
                if showsQuickActions && message.role == .assistant && !message.isStreaming {
                    quickActionsBar
                }
            }
            .frame(maxWidth: message.role == .assistant ? .infinity : nil, alignment: .leading)
            .environment(\.openURL, sourceOpenURLAction)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .scaleEffect(appeared ? 1 : 0.95)
        .overlay(alignment: message.role == .user ? .bottomTrailing : .bottomLeading) {
            if showCopied {
                Text("Copied")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.75))
                    .clipShape(Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .offset(y: 28)
            }
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8)) {
                appeared = true
            }
            if message.role == .assistant && message.content.isEmpty && message.thinkingContent == nil {
                Self.lightHaptic.impactOccurred()
            }
        }
    }

    private func actionButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.adaptiveCard.opacity(0.85))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.leading, 4)
    }

    struct RecoveryAction {
        let title: String
        let systemImage: String
        let action: () -> Void
    }

    private func assistantActionChips(
        styles: [SmartReplyStyle],
        suggestions: [String],
        styleAction: @escaping (SmartReplyStyle) -> Void,
        followUpAction: @escaping (String) -> Void
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(styles) { style in
                    Button {
                        styleAction(style)
                    } label: {
                        actionChipLabel(title: style.title, systemImage: style.systemImage)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(String(localized: "Rewrites the latest reply in this style."))
                }

                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        followUpAction(suggestion)
                    } label: {
                        actionChipLabel(title: suggestion, systemImage: "arrow.turn.down.right")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 12)
        }
        .frame(maxWidth: 320, alignment: .leading)
        .padding(.top, 2)
    }

    private func actionChipLabel(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.adaptive(white: 0.22))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.adaptiveCard.opacity(0.9))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
    }

    // MARK: - Quick Actions Bar

    private var quickActionsBar: some View {
        HStack(spacing: 2) {
            quickActionButton(icon: "doc.on.doc", label: String(localized: "Copy")) {
                copyAndShowToast(message.content)
            }

            if onSpeak != nil {
                let isSpeakingThisMessage = speechManager.isSpeaking && speechManager.currentlySpeakingMessageID == message.id
                if isSpeakingThisMessage && speechManager.isPreparingSpeechOutput {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 34, height: 30)
                        .accessibilityLabel(String(localized: "Preparing voice"))
                } else {
                    quickActionButton(
                        icon: isSpeakingThisMessage ? "speaker.slash.fill" : "speaker.wave.2",
                        label: isSpeakingThisMessage ? String(localized: "Stop") : String(localized: "Speak")
                    ) {
                        onSpeak?(message)
                    }
                }
            }

            quickActionButton(
                icon: message.isPinned ? "pin.slash.fill" : "pin",
                label: message.isPinned ? String(localized: "Unpin") : String(localized: "Pin")
            ) {
                onTogglePin?(message)
            }

            quickActionButton(icon: "square.and.arrow.up", label: String(localized: "Share")) {
                let activityVC = UIActivityViewController(
                    activityItems: [message.content],
                    applicationActivities: nil
                )
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController {
                    rootVC.present(activityVC, animated: true)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.adaptiveBorder(opacity: 0.45), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 6, y: 3)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private func quickActionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.adaptive(white: 0.35))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func thinkingMarkdown(_ thinkingText: String) -> some View {
        ThinkingMarkdownView(text: thinkingText, isExpanded: isThinkingExpanded)
            .equatable()
    }

    private var messageCard: some View {
        messageCardChrome
            // Keep the menu host free of content animations. Attaching
            // `.contextMenu` to the same view as `.animation` makes iOS lay out
            // every row at once (the stacked/overlapping menu you see on long press).
            // The menu is attached to an invisible `Color.clear` overlay instead,
            // so the `preview:` closure must always be supplied explicitly — the
            // system default preview snapshots whatever view the modifier is
            // attached to (the invisible overlay, not `messageCardChrome`), which
            // renders as a blank card sized to the row. For assistant replies we
            // reuse `messageCardChrome` itself so the lifted preview is pixel-for-
            // pixel identical to what's on screen (no bubble, transparent
            // background — no ghosting seam).
            .overlay {
                if message.role == .user {
                    Color.clear
                        .contentShape(Rectangle())
                        .contextMenu {
                            messageContextMenuContent
                        } preview: {
                            messageContextMenuPreview
                        }
                } else {
                    Color.clear
                        .contentShape(Rectangle())
                        .contextMenu {
                            messageContextMenuContent
                        } preview: {
                            // Assistant replies render with a transparent
                            // background. A context-menu preview inherits that
                            // transparency, so the dimmed chat behind the lifted
                            // platter — the *next* message's text — bleeds
                            // through and reads as ghosting over the preview.
                            // Give the preview an opaque chat-surface background
                            // so only this message shows.
                            messageCardChrome
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(Color.adaptive(white: 0.98))
                        }
                }
            }
            .alert("Message Info", isPresented: $showStats) {
                Button("OK", role: .cancel) { }
            } message: {
                let stats = messageStats(for: message.content)
                Text("\(stats.words) words · \(stats.characters) characters\n~\(stats.readingTime) min read")
            }
    }

    private var messageCardChrome: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.isPinned {
                HStack(spacing: 6) {
                    Image(systemName: "pin.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Pinned")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            messageContent

            if message.isStreaming {
                streamingIndicator
                    .padding(.top, displayedContent.isEmpty ? 0 : 4)
                    .transition(.opacity)
            }
        }
        // User messages keep the chat bubble; assistant replies render as plain
        // text on the chat background (no bubble, no shadow) for a cleaner read.
        .padding(.horizontal, message.role == .user ? 16 : 0)
        .padding(.vertical, message.role == .user ? 12 : 4)
        .background {
            if message.role == .user {
                LinearGradient(
                    colors: [Color(red: 0.2, green: 0.5, blue: 0.9), Color(red: 0.15, green: 0.45, blue: 0.85)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .clipShape(message.role == .user ? AnyShape(MessageShape(isUser: true)) : AnyShape(Rectangle()))
        .shadow(
            color: message.role == .user ? .black.opacity(0.12) : .clear,
            radius: message.role == .user ? 8 : 0,
            y: message.role == .user ? 3 : 0
        )
        .contentTransition(.interpolate)
        // No animation on the content swap WHILE streaming: animating the
        // per-token MarkdownUI re-render cross-fades old vs new and reads as
        // flicker. Stream the text in instantly; only the finalized reply gets
        // a gentle settling spring.
        .animation(
            message.isStreaming || reduceMotion
                ? nil
                : .spring(response: 0.4, dampingFraction: 0.9),
            value: displayedContent
        )
    }

    /// Bubble preview for user-message long press. Assistant replies skip the
    /// lift preview entirely to avoid ghosting over MarkdownUI content.
    private var messageContextMenuPreview: some View {
        Text(displayedContent)
            .font(.system(size: 17 * messageTextScale))
            .foregroundStyle(.white)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                LinearGradient(
                    colors: [Color(red: 0.2, green: 0.5, blue: 0.9), Color(red: 0.15, green: 0.45, blue: 0.85)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .clipShape(AnyShape(MessageShape(isUser: true)))
    }

    @ViewBuilder
    private var messageContextMenuContent: some View {
        Button {
            copyAndShowToast(message.content)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        Button {
            copyAndShowToast(markdownRepresentation)
        } label: {
            Label("Copy as Markdown", systemImage: "doc.plaintext")
        }

        if message.role == .assistant, let codeOnly = extractCodeBlocks(from: message.content), !codeOnly.isEmpty {
            Button {
                copyAndShowToast(codeOnly)
            } label: {
                Label("Copy Code Only", systemImage: "curlybraces")
            }
        }

        Divider()

        if let onTogglePin {
            Button {
                onTogglePin(message)
            } label: {
                Label(message.isPinned ? "Unpin" : "Pin", systemImage: message.isPinned ? "pin.slash" : "pin")
            }
        }

        Button {
            showStats = true
        } label: {
            Label("Message Info", systemImage: "info.circle")
        }

        if let onSpeak {
            let isSpeakingThisMessage = speechManager.isSpeaking && speechManager.currentlySpeakingMessageID == message.id
            Button {
                onSpeak(message)
            } label: {
                Label(
                    isSpeakingThisMessage ? "Stop Speaking" : "Read Aloud",
                    systemImage: isSpeakingThisMessage ? "speaker.slash" : "speaker.wave.2"
                )
            }
        }

        if let onSearchWeb {
            Button {
                onSearchWeb(message)
            } label: {
                Label("Search on Web", systemImage: "magnifyingglass")
            }
        }

        if message.role == .user, let onEdit {
            Button {
                onEdit(message)
            } label: {
                Label("Edit & Re-run", systemImage: "pencil")
            }
        }

        if message.role == .assistant {
            if let onRegenerateMore {
                Button {
                    onRegenerateMore(message)
                } label: {
                    Label("Regenerate (More)", systemImage: "plus.magnifyingglass")
                }
            }
            if let onRegenerateLess {
                Button {
                    onRegenerateLess(message)
                } label: {
                    Label("Regenerate (Less)", systemImage: "minus.magnifyingglass")
                }
            }
        }

        if let onBranchFromHere {
            Button {
                onBranchFromHere(message)
            } label: {
                Label("Branch from Here", systemImage: "arrow.branch")
            }
        }

        ShareLink(item: message.content) {
            Label("Share", systemImage: "square.and.arrow.up")
        }

        if message.role == .assistant {
            Divider()
            Button {
                reportProblem(message.content)
            } label: {
                Label("Report a Problem", systemImage: "exclamationmark.bubble")
            }
            Button(role: .destructive) {
                reportContent(message.content)
            } label: {
                Label("Report Inappropriate Content", systemImage: "flag")
            }
        }
    }

    private var markdownRepresentation: String {
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch message.role {
        case .user:
            if message.imageFileName != nil {
                return "**You (with image):**\n\n\(trimmed)"
            }
            return "**You:**\n\n\(trimmed)"
        case .assistant:
            if let thinking = message.thinkingContent?.trimmingCharacters(in: .whitespacesAndNewlines),
               !thinking.isEmpty {
                return "**Assistant:**\n\n\(trimmed)\n\n<details>\n<summary>Thoughts</summary>\n\n\(thinking)\n\n</details>"
            }
            return "**Assistant:**\n\n\(trimmed)"
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        if message.role == .user {
            VStack(alignment: .trailing, spacing: 8) {
                if let imageFileName = message.imageFileName,
                   let uiImage = ImageAttachmentManager.shared.loadImage(named: imageFileName) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: 200, maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text(message.content)
                    .font(.system(size: 17 * messageTextScale))
                    .foregroundStyle(.white)
            }
        } else if !displayedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Only render the markdown body when there's actual text. An empty
            // Markdown("") block expands to full width, which made the initial
            // streaming placeholder (just the typing dots) render as a huge bubble.
            let theme = CodeTheme(rawValue: codeThemeRaw) ?? .defaultTheme
            AssistantMarkdownView(
                content: displayedContent,
                isStreaming: message.isStreaming,
                theme: theme,
                textScale: messageTextScale
            )
            .equatable()
        }
    }

    private var streamingIndicator: some View {
        TypingDots(
            gradient: LinearGradient(
                colors: [
                    message.role == .user ? .white.opacity(0.8) : .blue.opacity(0.6),
                    message.role == .user ? .white.opacity(0.6) : .purple.opacity(0.6)
                ],
                startPoint: .leading,
                endPoint: .trailing
            ),
            reduceMotion: reduceMotion
        )
    }

    /// Intercepts taps on inline `[Source n]` citation links (see
    /// `AssistantMarkdownView.linkifySources`). Source links pulse the matching
    /// chip; any other URL falls through to the system handler.
    private var sourceOpenURLAction: OpenURLAction {
        OpenURLAction { url in
            guard url.scheme == AssistantMarkdownView.sourceURLScheme,
                  let number = Int(url.host ?? "") else {
                return .systemAction
            }
            highlightSource(number)
            return .handled
        }
    }

    private func highlightSource(_ number: Int) {
        guard number >= 1, number <= message.sourceTitles.count else { return }
        Self.lightHaptic.impactOccurred()
        highlightClearTask?.cancel()
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7)) {
            highlightedSourceNumber = number
        }
        highlightClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                highlightedSourceNumber = nil
            }
        }
    }

    private func sourceChips(_ sourceTitles: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(sourceTitles.enumerated()), id: \.offset) { index, title in
                        let number = index + 1
                        let isHighlighted = highlightedSourceNumber == number
                        HStack(spacing: 6) {
                            Text("\(number)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 16, height: 16)
                                .background(isHighlighted ? Color.accentColor : Color.adaptive(white: 0.55))
                                .clipShape(Circle())
                            Text(title)
                                .lineLimit(1)
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(isHighlighted ? Color.accentColor : Color.adaptive(white: 0.4))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isHighlighted ? Color.accentColor.opacity(0.12) : Color.adaptiveCard.opacity(0.92))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.accentColor, lineWidth: isHighlighted ? 1.5 : 0)
                        )
                        .scaleEffect(isHighlighted ? 1.05 : 1)
                        .id(number)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: 280, alignment: .leading)
            .onChange(of: highlightedSourceNumber) { _, newValue in
                guard let newValue else { return }
                withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func thinkingCard(thinkingText: String, showsStreamingIndicator: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                debugLogThinking("toggle tapped", thinkingText: thinkingText)
                Self.lightHaptic.impactOccurred()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    isThinkingExpanded.toggle()
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.isStreaming ? "Thinking…" : "Thoughts")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(message.isStreaming ? Color.black.opacity(0.8) : Color.black)
                            .shimmering(active: message.isStreaming, bandSize: 0.18)

                        if !message.isStreaming, !thinkingText.isEmpty {
                            let wordCount = thinkingText.split { $0.isWhitespace }.count
                            Text("\(wordCount) words")
                                .font(.caption2)
                                .foregroundStyle(Color.adaptive(white: 0.55))
                        }
                    }

                    Spacer()

                    Image(systemName: isThinkingExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.black)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Group {
                if isThinkingExpanded {
                    thinkingMarkdown(thinkingText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) {
                            thinkingMarkdown(thinkingText)

                            Color.clear
                                .frame(height: 1)
                                .id("thinking-bottom")
                        }
                        .frame(height: collapsedThinkingHeight)
                        .onAppear {
                            debugLogThinking("collapsed scroll appeared", thinkingText: thinkingText)
                            guard message.isStreaming else { return }
                            scrollThinkingToBottom(proxy, animated: false)
                        }
                        .onChange(of: thinkingText) {
                            debugLogThinking("collapsed thinking text changed", thinkingText: thinkingText)
                            guard message.isStreaming else { return }
                            scrollThinkingToBottom(proxy, animated: true)
                        }
                        .overlay(alignment: .top) {
                            LinearGradient(
                                colors: [Color.adaptiveCard.opacity(0.985), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 18)
                            .allowsHitTesting(false)
                        }
                        .overlay(alignment: .bottom) {
                            LinearGradient(
                                colors: [Color.clear, Color.adaptiveCard.opacity(0.985)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 24)
                            .allowsHitTesting(false)
                        }
                    }
                }
            }
            .onChange(of: isThinkingExpanded) {
                debugLogThinking("expanded changed", thinkingText: thinkingText)
            }
            .onAppear {
                debugLogThinking("thinking content appeared", thinkingText: thinkingText)
            }
            .onChange(of: thinkingText) {
                if isThinkingExpanded {
                    debugLogThinking("expanded thinking text changed", thinkingText: thinkingText)
                }
            }

            if showsStreamingIndicator {
                streamingIndicator
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.adaptiveBorder(opacity: 0.4), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 10, y: 5)
        .padding(.trailing, 4)
    }

    private func scrollThinkingToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        Task { @MainActor in
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("thinking-bottom", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("thinking-bottom", anchor: .bottom)
            }
        }
    }

    private func debugLogThinking(_ event: String, thinkingText: String) {
    }

    // Quality feedback from the exact moment of dissatisfaction, pre-filled
    // with the context needed to reproduce (model, device, OS, app version) —
    // the only signal channel for problems users would otherwise take to the
    // App Store.
    private func reportProblem(_ content: String) {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let modelName = modelManager.selectedModel?.name ?? "Unknown"
        let device = UIDevice.current
        let excerpt = content.count > 800 ? String(content.prefix(800)) + "…" : content

        let subject = "Own AI Problem Report"
        let body = """
        What went wrong with this response?

        (Describe the problem here)

        ---
        Model: \(modelName)
        Device: \(device.model), iOS \(device.systemVersion)
        App version: \(appVersion)

        Response excerpt:
        "\(excerpt)"
        """
        let mailto = "mailto:alice.turcanu91@gmail.com?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&body=\(body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"

        if let url = URL(string: mailto) {
            UIApplication.shared.open(url)
        }
    }

    private func reportContent(_ content: String) {
        let subject = "Inappropriate AI Content Report"
        let body = "The following AI response was flagged as inappropriate:\n\n\"\(content)\"\n\nPlease provide details on why this content is inappropriate:"
        let mailto = "mailto:alice.turcanu91@gmail.com?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&body=\(body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"

        if let url = URL(string: mailto) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Code Extraction

    /// Extracts fenced code blocks (```...```) from markdown text.
    private static let codeBlockRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "```(?:\\w+)?\n(.*?)```", options: [.dotMatchesLineSeparators])
    }()

    private func extractCodeBlocks(from content: String) -> String? {
        guard let regex = Self.codeBlockRegex else { return nil }
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: range)
        guard !matches.isEmpty else { return nil }

        let blocks = matches.compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: content) else { return nil }
            return String(content[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return blocks.joined(separator: "\n\n")
    }

    // MARK: - Message Stats

    private func messageStats(for content: String) -> (words: Int, characters: Int, readingTime: Int) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split { $0.isWhitespace }.count
        let characters = trimmed.count
        let readingTime = max(1, Int(ceil(Double(words) / 200.0)))
        return (words, characters, readingTime)
    }

    // MARK: - Clipboard Helper

    private func copyAndShowToast(_ text: String) {
        UIPasteboard.general.string = text
        Self.lightHaptic.impactOccurred()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showCopied = true
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.3)) {
                showCopied = false
            }
        }
    }
}

// MARK: - Message Shape

struct MessageShape: Shape {
    let isUser: Bool
    
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 18
        let tailRadius: CGFloat = 6
        
        var path = Path()
        
        if isUser {
            // User message - rounded with tail on right
            path.move(to: CGPoint(x: radius, y: 0))
            path.addLine(to: CGPoint(x: rect.width - radius, y: 0))
            path.addArc(
                center: CGPoint(x: rect.width - radius, y: radius),
                radius: radius,
                startAngle: .degrees(-90),
                endAngle: .degrees(0),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: rect.width, y: rect.height - tailRadius))
            path.addArc(
                center: CGPoint(x: rect.width - tailRadius, y: rect.height - tailRadius),
                radius: tailRadius,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: radius, y: rect.height))
            path.addArc(
                center: CGPoint(x: radius, y: rect.height - radius),
                radius: radius,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: 0, y: radius))
            path.addArc(
                center: CGPoint(x: radius, y: radius),
                radius: radius,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
        } else {
            // Assistant message - rounded with tail on left
            path.move(to: CGPoint(x: radius, y: 0))
            path.addLine(to: CGPoint(x: rect.width - radius, y: 0))
            path.addArc(
                center: CGPoint(x: rect.width - radius, y: radius),
                radius: radius,
                startAngle: .degrees(-90),
                endAngle: .degrees(0),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: rect.width, y: rect.height - radius))
            path.addArc(
                center: CGPoint(x: rect.width - radius, y: rect.height - radius),
                radius: radius,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: tailRadius, y: rect.height))
            path.addArc(
                center: CGPoint(x: tailRadius, y: rect.height - tailRadius),
                radius: tailRadius,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: 0, y: radius))
            path.addArc(
                center: CGPoint(x: radius, y: radius),
                radius: radius,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
        }
        
        path.closeSubpath()
        return path
    }
}

#Preview {
    VStack(spacing: 16) {
        MessageBubble(message: ChatMessage(role: .user, content: "Hello! How are you today?"))
        MessageBubble(message: ChatMessage(role: .assistant, content: "I'm doing great! I'm running completely on your device. How can I help you today?"))
        MessageBubble(message: ChatMessage(role: .assistant, content: "Thinking…", isStreaming: true))
    }
    .padding()
    .background(Color.adaptive(white: 0.98))
    .environment(SpeechManager())
    .environment(ModelManager())
}
