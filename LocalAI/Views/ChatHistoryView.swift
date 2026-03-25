//
//  ChatHistoryView.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import SwiftUI

struct ChatHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ChatHistoryManager.self) private var historyManager
    @State private var searchText = ""
    
    var filteredConversations: [ChatConversation] {
        if searchText.isEmpty {
            return historyManager.conversations
        } else {
            return historyManager.conversations.filter { conversation in
                conversation.title.localizedCaseInsensitiveContains(searchText) ||
                conversation.messages.contains { message in
                    message.content.localizedCaseInsensitiveContains(searchText)
                }
            }
        }
    }

    private var groupedConversations: [(title: String, conversations: [ChatConversation])] {
        let calendar = Calendar.current
        let now = Date()
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? .distantPast

        var today: [ChatConversation] = []
        var yesterday: [ChatConversation] = []
        var previous7Days: [ChatConversation] = []
        var earlier: [ChatConversation] = []

        for conversation in filteredConversations {
            if calendar.isDateInToday(conversation.updatedAt) {
                today.append(conversation)
            } else if calendar.isDateInYesterday(conversation.updatedAt) {
                yesterday.append(conversation)
            } else if conversation.updatedAt >= sevenDaysAgo {
                previous7Days.append(conversation)
            } else {
                earlier.append(conversation)
            }
        }

        var groups: [(title: String, conversations: [ChatConversation])] = []
        if !today.isEmpty { groups.append(("Today", today)) }
        if !yesterday.isEmpty { groups.append(("Yesterday", yesterday)) }
        if !previous7Days.isEmpty { groups.append(("Previous 7 Days", previous7Days)) }
        if !earlier.isEmpty { groups.append(("Earlier", earlier)) }
        return groups
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                    if filteredConversations.isEmpty {
                        if searchText.isEmpty {
                            emptyState
                        } else {
                            ContentUnavailableView.search(text: searchText)
                        }
                    } else {
                        ForEach(groupedConversations, id: \.title) { section in
                            Section {
                                ForEach(section.conversations) { conversation in
                                    ConversationRow(
                                        conversation: conversation,
                                        isSelected: conversation.id == historyManager.currentConversationID
                                    ) {
                                        historyManager.selectConversation(conversation.id)
                                        dismiss()
                                    } onDelete: {
                                        withAnimation(.spring(response: 0.3)) {
                                            historyManager.deleteConversation(conversation.id)
                                        }
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            withAnimation(.spring(response: 0.3)) {
                                                historyManager.deleteConversation(conversation.id)
                                            }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            } header: {
                                Text(section.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color(white: 0.4))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 4)
                                    .background(Color(white: 0.96))
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .background(Color(white: 0.96))
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.medium)
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        historyManager.newConversation()
                        dismiss()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.orange, .pink],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                }
            }
            .searchable(text: $searchText, placement: .automatic, prompt: "Search history")
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 50, weight: .light))
                .foregroundStyle(Color(white: 0.7))
            
            Text("No Conversations Yet")
                .font(.headline)
                .foregroundStyle(Color(white: 0.4))
            
            Text("Start a new chat to see it here")
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.6))
            
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: ChatConversation
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                // Icon
                ZStack {
                    Circle()
                        .fill(
                            isSelected ?
                            LinearGradient(colors: [.orange.opacity(0.2), .pink.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing) :
                            LinearGradient(colors: [Color(white: 0.92)], startPoint: .top, endPoint: .bottom)
                        )
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: "bubble.left.fill")
                        .font(.body)
                        .foregroundStyle(
                            isSelected ?
                            LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing) :
                            LinearGradient(colors: [Color(white: 0.5)], startPoint: .top, endPoint: .bottom)
                        )
                }
                
                // Content
                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color(white: 0.1))
                        .lineLimit(1)

                    if let lastMessage = conversation.messages.last {
                        Text(lastMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60) + (lastMessage.content.count > 60 ? "…" : ""))
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.45))
                            .lineLimit(1)
                    }
                    
                    Text(formattedDate)
                        .font(.caption2)
                        .foregroundStyle(Color(white: 0.55))
                }
                
                Spacer()
                
                // Message count
                if !conversation.messages.isEmpty {
                    Text("\(conversation.messages.count)")
                        .font(.caption.bold())
                        .foregroundStyle(Color(white: 0.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(white: 0.92))
                        .clipShape(Capsule())
                }
            }
            .padding(14)
            .background(
                isSelected ?
                Color.white :
                Color.white.opacity(0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        isSelected ?
                        LinearGradient(colors: [.orange.opacity(0.4), .pink.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing) :
                        LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom),
                        lineWidth: isSelected ? 1.5 : 0
                    )
            )
            .shadow(color: .black.opacity(isHovered ? 0.06 : 0.03), radius: isHovered ? 8 : 4, y: isHovered ? 4 : 2)
        }
        .buttonStyle(ConversationButtonStyle())
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
    
    private var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: conversation.updatedAt, relativeTo: Date())
    }
}

struct ConversationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

#Preview {
    ChatHistoryView()
        .environment(ChatHistoryManager())
}
