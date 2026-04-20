//
//  MessageBubble.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import SwiftUI
import MarkdownUI
import Shimmer

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
    let onBranchFromHere: ((ChatMessage) -> Void)?
    let onTogglePin: ((ChatMessage) -> Void)?
    @State private var appeared = false
    @State private var isThinkingExpanded = false
    @State private var showCopied = false
    private let userLeadingInset: CGFloat = 60
    private let assistantTrailingInset: CGFloat = 16
    private let collapsedThinkingHeight: CGFloat = 76

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
        onBranchFromHere: ((ChatMessage) -> Void)? = nil,
        onTogglePin: ((ChatMessage) -> Void)? = nil
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
        self.onBranchFromHere = onBranchFromHere
        self.onTogglePin = onTogglePin
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
                   !smartReplyStyles.isEmpty,
                   let onSmartReplyStyle {
                    smartReplyStyleChips(
                        styles: smartReplyStyles,
                        action: { style in onSmartReplyStyle(message, style) }
                    )
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

    private func smartReplyStyleChips(
        styles: [SmartReplyStyle],
        action: @escaping (SmartReplyStyle) -> Void
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(styles) { style in
                    Button {
                        action(style)
                    } label: {
                        Label(style.title, systemImage: style.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(white: 0.22))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.9))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(String(localized: "Rewrites the latest reply in this style."))
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 12)
        }
        .frame(maxWidth: 320, alignment: .leading)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func thinkingMarkdown(_ thinkingText: String) -> some View {
        Markdown(thinkingText)
            .font(.callout)
            .markdownTextStyle {
                ForegroundColor(isThinkingExpanded ? Color(white: 0.66) : Color(white: 0.86))
            }
            .foregroundStyle(isThinkingExpanded ? Color(white: 0.86) : Color(white: 0.66))
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .background(
            message.role == .user ?
            AnyShapeStyle(
                LinearGradient(
                    colors: [.blue, .blue.opacity(0.9)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            ) :
            AnyShapeStyle(Color.white)
        )
        .clipShape(MessageShape(isUser: message.role == .user))
        .shadow(color: .black.opacity(message.role == .user ? 0.1 : 0.04), radius: 6, y: 3)
        .contentTransition(.interpolate)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: message.content)
        .contextMenu {
            Button {
                UIPasteboard.general.string = message.content
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showCopied = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showCopied = false
                    }
                }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button {
                UIPasteboard.general.string = markdownRepresentation
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showCopied = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showCopied = false
                    }
                }
            } label: {
                Label("Copy as Markdown", systemImage: "doc.plaintext")
            }

            if let onTogglePin {
                Button {
                    onTogglePin(message)
                } label: {
                    Label(message.isPinned ? "Unpin" : "Pin", systemImage: message.isPinned ? "pin.slash" : "pin")
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

            if message.role == .assistant {
                Button(role: .destructive) {
                    reportContent(message.content)
                } label: {
                    Label("Report Inappropriate Content", systemImage: "flag")
                }
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
                    .font(.body)
                    .foregroundStyle(.white)
            }
        } else {
            Markdown(message.content)
                .font(.body)
                .foregroundStyle(Color(white: 0.15))
                .markdownBlockStyle(\.codeBlock) { configuration in
                    VStack(spacing: 0) {
                        HStack {
                            Text(configuration.language?.lowercased() ?? "code")
                                .font(.caption.bold())
                                .foregroundStyle(Color(white: 0.4))
                            Spacer()
                            Button {
                                UIPasteboard.general.string = configuration.content
                                let generator = UIImpactFeedbackGenerator(style: .light)
                                generator.impactOccurred()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption2)
                                    Text("Copy")
                                        .font(.caption.bold())
                                }
                                .foregroundStyle(Color.black.opacity(0.7))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white)
                                .clipShape(Capsule())
                                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(white: 0.95))

                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(SyntaxHighlighter.highlight(configuration.content, language: configuration.language))
                                .padding(12)
                                .frame(minWidth: 100, alignment: .leading)
                        }
                        .background(Color(white: 0.98))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(white: 0.85), lineWidth: 1)
                    )
                    .padding(.vertical, 8)
                }
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
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    isThinkingExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(message.isStreaming ? "Thinking…" : "Thoughts")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(message.isStreaming ? Color.black.opacity(0.8) : Color.black)
                        .shimmering(active: message.isStreaming, bandSize: 0.18)

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
        .background(Color.white.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
        .padding(.trailing, 4)
    }

    private func scrollThinkingToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
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
}
