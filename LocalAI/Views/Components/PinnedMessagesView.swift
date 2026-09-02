//
//  PinnedMessagesView.swift
//  LocalAI
//
//  Displays all pinned messages across conversations.
//

import SwiftUI
import MarkdownUI

struct PinnedMessagesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ChatHistoryManager.self) private var historyManager

    private var pinnedItems: [(conversation: ChatConversation, message: ChatMessage)] {
        historyManager.conversations.flatMap { conversation in
            conversation.messages.filter(\.isPinned).map { message in
                (conversation: conversation, message: message)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if pinnedItems.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(pinnedItems, id: \.message.id) { item in
                                pinnedCard(item.conversation, item.message)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    }
                }
            }
            .background(Color.adaptive(white: 0.96).ignoresSafeArea())
            .navigationTitle(String(localized: "Pinned Messages"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) {
                        dismiss()
                    }
                    .fontWeight(.medium)
                }
            }
        }
    }

    private func pinnedCard(_ conversation: ChatConversation, _ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "pin.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                Text(conversation.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.adaptive(white: 0.45))
                    .lineLimit(1)

                Spacer()

                Text(message.role == .user ? String(localized: "You") : String(localized: "AI"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(message.role == .user ? .blue : .purple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (message.role == .user ? Color.blue : Color.purple).opacity(0.1),
                        in: Capsule()
                    )
            }

            // Content
            if message.role == .assistant {
                Markdown(message.content)
                    .font(.callout)
                    .foregroundStyle(Color.adaptive(white: 0.2))
                    .lineLimit(6)
            } else {
                Text(message.content)
                    .font(.callout)
                    .foregroundStyle(Color.adaptive(white: 0.2))
                    .lineLimit(6)
            }

            // Actions
            HStack(spacing: 16) {
                Button {
                    UIPasteboard.general.string = message.content
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                    UIAccessibility.post(notification: .announcement, argument: String(localized: "Copied"))
                } label: {
                    Label(String(localized: "Copy"), systemImage: "doc.on.doc")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.adaptive(white: 0.45))
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)

                Button {
                    historyManager.selectConversation(conversation.id)
                    dismiss()
                } label: {
                    Label(String(localized: "Go to Chat"), systemImage: "arrow.right.circle")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.3)) {
                        historyManager.togglePinned(messageID: message.id, in: conversation.id)
                    }
                } label: {
                    Label(String(localized: "Unpin"), systemImage: "pin.slash")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(Color.adaptiveCard, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.04), radius: 10, y: 5)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "pin.slash")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color.adaptive(white: 0.65))
                .accessibilityHidden(true)

            Text(String(localized: "No Pinned Messages"))
                .font(.headline)
                .foregroundStyle(Color.adaptive(white: 0.4))

            Text(String(localized: "Long-press any message and tap Pin to save it here."))
                .font(.subheadline)
                .foregroundStyle(Color.adaptive(white: 0.6))
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
