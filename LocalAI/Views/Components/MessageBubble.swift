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

    var body: some View {
        Markdown(content)
            .markdownTextStyle {
                FontSize(CGFloat(17 * textScale))
            }
            .foregroundStyle(Color(white: 0.15))
            .markdownBlockStyle(\.codeBlock) { configuration in
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
                ForegroundColor(isExpanded ? Color(white: 0.66) : Color(white: 0.86))
            }
            .foregroundStyle(isExpanded ? Color(white: 0.86) : Color(white: 0.66))
            .frame(maxWidth: .infinity, alignment: .leading)
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
    let onTranslate: ((ChatMessage) -> Void)?
    let onSpeak: ((ChatMessage) -> Void)?
    let onSearchWeb: ((ChatMessage) -> Void)?
    let onFollowUp: ((ChatMessage, String) -> Void)?
    let showsQuickActions: Bool
    @AppStorage("codeTheme") private var codeThemeRaw = CodeTheme.defaultTheme.rawValue
    @AppStorage("messageTextScale") private var messageTextScale: Double = 1.0
    @Environment(SpeechManager.self) private var speechManager
    @State private var appeared = false
    @State private var isThinkingExpanded = false
    @State private var showCopied = false
    @State private var showStats = false
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
        onTranslate: ((ChatMessage) -> Void)? = nil,
        onSpeak: ((ChatMessage) -> Void)? = nil,
        onSearchWeb: ((ChatMessage) -> Void)? = nil,
        onFollowUp: ((ChatMessage, String) -> Void)? = nil,
        showsQuickActions: Bool = false
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
        self.onTranslate = onTranslate
        self.onSpeak = onSpeak
        self.onSearchWeb = onSearchWeb
        self.onFollowUp = onFollowUp
        self.showsQuickActions = showsQuickActions
    }

    var body: some View {
        let thinkingText = message.thinkingContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasThinking = !thinkingText.isEmpty
        let hasAnswerContent = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let sourceTitles = message.sourceTitles

        HStack(alignment: .top, spacing: 12) {
            if message.role == .user {
                Spacer(minLength: userLeadingInset)
            } else {
                // Assistant avatar
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.blue.opacity(0.15), .purple.opacity(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                    
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .scaleEffect(message.isStreaming ? 1.05 : 1.0)
                .animation(
                    message.isStreaming ?
                    .easeInOut(duration: 1.0).repeatForever(autoreverses: true) :
                    .default,
                    value: message.isStreaming
                )
            }
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                if message.role == .assistant && hasThinking {
                    thinkingCard(thinkingText: thinkingText, showsStreamingIndicator: message.isStreaming && !hasAnswerContent)
                }

                if message.role == .user || hasAnswerContent || !hasThinking {
                    messageCard
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
            
            if message.role == .assistant {
                Spacer(minLength: assistantTrailingInset)
            }
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
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
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
                .background(Color.white.opacity(0.85))
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
            .foregroundStyle(Color(white: 0.22))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.9))
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
                quickActionButton(
                    icon: isSpeakingThisMessage ? "speaker.slash.fill" : "speaker.wave.2",
                    label: isSpeakingThisMessage ? String(localized: "Stop") : String(localized: "Speak")
                ) {
                    onSpeak?(message)
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
                .stroke(Color.white.opacity(0.45), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 6, y: 3)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private func quickActionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(white: 0.35))
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
                    .padding(.top, message.content.isEmpty ? 0 : 4)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            if message.role == .user {
                LinearGradient(
                    colors: [Color(red: 0.2, green: 0.5, blue: 0.9), Color(red: 0.15, green: 0.45, blue: 0.85)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .clipShape(MessageShape(isUser: message.role == .user))
        .shadow(color: .black.opacity(message.role == .user ? 0.12 : 0.06), radius: message.role == .user ? 8 : 4, y: 3)
        .contentTransition(.interpolate)
        .animation(message.isStreaming ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: message.content)
        .contextMenu {
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

            // Copy Code Only — extracts fenced code blocks
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

            // Message Info / Stats
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

                // Translate Reply
                if let onTranslate {
                    Divider()
                    Button {
                        onTranslate(message)
                    } label: {
                        Label("Translate Reply", systemImage: "globe")
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

            // Share
            ShareLink(item: message.content) {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            if message.role == .assistant {
                Divider()
                Button(role: .destructive) {
                    reportContent(message.content)
                } label: {
                    Label("Report Inappropriate Content", systemImage: "flag")
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
        } else {
            let theme = CodeTheme(rawValue: codeThemeRaw) ?? .defaultTheme
            AssistantMarkdownView(
                content: message.content,
                isStreaming: message.isStreaming,
                theme: theme,
                textScale: messageTextScale
            )
            .equatable()
        }
    }

    private var streamingIndicator: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                message.role == .user ? .white.opacity(0.8) : .blue.opacity(0.6),
                                message.role == .user ? .white.opacity(0.6) : .purple.opacity(0.6)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 4, height: 4)
                    .opacity(appeared ? 1.0 : 0.3)
                    .scaleEffect(appeared ? 1.0 : 0.7)
                    .animation(
                        .easeInOut(duration: 0.6)
                        .repeatForever()
                        .delay(Double(i) * 0.2),
                        value: appeared
                    )
            }
        }
    }

    private func sourceChips(_ sourceTitles: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sourceTitles, id: \.self) { title in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                        Text(title)
                            .lineLimit(1)
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color(white: 0.4))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.92))
                    .clipShape(Capsule())
                }
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
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
                                .foregroundStyle(Color(white: 0.55))
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
                                colors: [Color.white.opacity(0.985), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 18)
                            .allowsHitTesting(false)
                        }
                        .overlay(alignment: .bottom) {
                            LinearGradient(
                                colors: [Color.clear, Color.white.opacity(0.985)],
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
                .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
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
        #if DEBUG
        print("[ThinkingBubble] \(event) | expanded=\(isThinkingExpanded) | textLength=\(thinkingText.count)")
        #endif
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
    .background(Color(white: 0.98))
    .environment(SpeechManager())
}
