//
//  MessageBubble.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import SwiftUI
import MarkdownUI

struct MessageBubble: View {
    let message: ChatMessage
    let showsContinue: Bool
    let onContinue: (() -> Void)?
    @State private var appeared = false
    private let userLeadingInset: CGFloat = 60
    private let assistantTrailingInset: CGFloat = 16

    init(
        message: ChatMessage,
        showsContinue: Bool = false,
        onContinue: (() -> Void)? = nil
    ) {
        self.message = message
        self.showsContinue = showsContinue
        self.onContinue = onContinue
    }
    
    var body: some View {
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
            
            // Message content
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 8) {
                    Group {
                        if message.role == .user {
                            Text(message.content)
                        } else {
                            Markdown(message.content)
                                .markdownBlockStyle(\.codeBlock) { configuration in
                                    VStack(spacing: 0) {
                                        // Header
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
                                        
                                        // Code Content
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
                    .font(.body)
                    .foregroundStyle(message.role == .user ? .white : Color(white: 0.15))
                    
                    // Streaming indicator inside bubble
                    if message.isStreaming {
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
                .contentTransition(.interpolate) // Morph text layout smoothly
                .animation(.spring(response: 0.4, dampingFraction: 0.9), value: message.content)
                // Context Menu for Copy
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = message.content
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    
                    if message.role == .assistant {
                        Button(role: .destructive) {
                            reportContent(message.content)
                        } label: {
                            Label("Report Inappropriate Content", systemImage: "flag")
                        }
                    }
                }

                if showsContinue, let onContinue {
                    Button(action: onContinue) {
                        Label("Continue", systemImage: "arrow.trianglehead.clockwise")
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
            }
            
            if message.role == .assistant {
                Spacer(minLength: assistantTrailingInset)
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .scaleEffect(appeared ? 1 : 0.95)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                appeared = true
            }
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
        MessageBubble(message: ChatMessage(role: .assistant, content: "Thinking...", isStreaming: true))
    }
    .padding()
    .background(Color(white: 0.98))
}
