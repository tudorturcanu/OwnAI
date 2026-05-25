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
    @Environment(MonetizationManager.self) private var monetizationManager

    @State private var searchText = ""
    @State private var selectedFolderID: UUID? = nil    // nil = "All"
    @State private var exportConversation: ChatConversation?
    @State private var exportShareItems: [Any] = []
    @State private var isShareSheetPresented = false
    @State private var upgradeFeature: PremiumFeature?
    @State private var isNewFolderPresented = false
    @State private var newFolderName = ""
    @State private var newFolderEmoji = "📁"
    @State private var isMoveToFolderPresented = false
    @State private var conversationToMove: ChatConversation?
    @State private var isRenamePresented = false
    @State private var conversationToRename: ChatConversation?
    @State private var renameText = ""
    @State private var showPinnedMessages = false

    private var folderStore: ChatFolderStore { ChatFolderStore.shared }

    // MARK: - Filtered Conversations

    var filteredConversations: [ChatConversation] {
        var base = historyManager.conversations

        // Folder filter
        if let folderID = selectedFolderID {
            let assignedIDs = folderStore.conversations(in: folderID)
            base = base.filter { assignedIDs.contains($0.id) }
        }

        // Search filter
        if !searchText.isEmpty {
            base = base.filter { conversation in
                conversation.title.localizedCaseInsensitiveContains(searchText) ||
                conversation.messages.contains { message in
                    message.content.localizedCaseInsensitiveContains(searchText)
                }
            }
        }

        return base
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
        if !today.isEmpty { groups.append((String(localized: "Today"), today)) }
        if !yesterday.isEmpty { groups.append((String(localized: "Yesterday"), yesterday)) }
        if !previous7Days.isEmpty { groups.append((String(localized: "Previous 7 Days"), previous7Days)) }
        if !earlier.isEmpty { groups.append((String(localized: "Earlier"), earlier)) }
        return groups
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                    // Conversation Statistics
                    if !historyManager.conversations.isEmpty && searchText.isEmpty && selectedFolderID == nil {
                        conversationStatsCard
                    }

                    // Folder Chips (Pro)
                    if monetizationManager.canUse(.chatFolders) && !folderStore.folders.isEmpty {
                        folderChipsRow
                    }

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
                                        isSelected: conversation.id == historyManager.currentConversationID,
                                        folderLabel: folderStore.folder(for: conversation.id).map { "\($0.emoji) \($0.name)" }
                                    ) {
                                        historyManager.selectConversation(conversation.id)
                                        dismiss()
                                    } onDelete: {
                                        withAnimation(.spring(response: 0.3)) {
                                            historyManager.deleteConversation(conversation.id)
                                        }
                                    }
                                    .swipeActions(edge: .leading) {
                                        // Export (Pro)
                                        Button {
                                            handleExport(conversation)
                                        } label: {
                                            Label(String(localized: "Export"), systemImage: "square.and.arrow.up")
                                        }
                                        .tint(.blue)

                                        // Move to Folder (Pro)
                                        Button {
                                            handleMoveToFolder(conversation)
                                        } label: {
                                            Label(String(localized: "Folder"), systemImage: "folder")
                                        }
                                        .tint(.orange)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            withAnimation(.spring(response: 0.3)) {
                                                historyManager.deleteConversation(conversation.id)
                                            }
                                        } label: {
                                            Label(String(localized: "Delete"), systemImage: "trash")
                                        }
                                    }
                                    .contextMenu {
                                        Button {
                                            renameText = conversation.title
                                            conversationToRename = conversation
                                            isRenamePresented = true
                                        } label: {
                                            Label(
                                                String(localized: "Rename"),
                                                systemImage: "pencil"
                                            )
                                        }

                                        Button {
                                            handleExport(conversation)
                                        } label: {
                                            Label(
                                                String(localized: "Export as Markdown"),
                                                systemImage: "square.and.arrow.up"
                                            )
                                        }

                                        Button {
                                            handleMoveToFolder(conversation)
                                        } label: {
                                            Label(
                                                String(localized: "Move to Folder"),
                                                systemImage: "folder"
                                            )
                                        }

                                        Divider()

                                        Button(role: .destructive) {
                                            withAnimation(.spring(response: 0.3)) {
                                                historyManager.deleteConversation(conversation.id)
                                            }
                                        } label: {
                                            Label(String(localized: "Delete"), systemImage: "trash")
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
            .navigationTitle(String(localized: "History"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) {
                        dismiss()
                    }
                    .fontWeight(.medium)
                }

                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        // Pinned messages button
                        if totalPinnedCount > 0 {
                            Button {
                                showPinnedMessages = true
                            } label: {
                                Image(systemName: "pin.fill")
                                    .font(.body)
                                    .foregroundStyle(.orange)
                            }
                        }

                        // Folders button (Pro)
                        Button {
                            if monetizationManager.canUse(.chatFolders) {
                                newFolderName = ""
                                newFolderEmoji = "📁"
                                isNewFolderPresented = true
                            } else {
                                upgradeFeature = .chatFolders
                            }
                        } label: {
                            Image(systemName: "folder.badge.plus")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }

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
            }
            .searchable(text: $searchText, placement: .automatic, prompt: String(localized: "Search history"))
        }
        // Export share sheet
        .sheet(isPresented: $isShareSheetPresented, onDismiss: { exportShareItems = [] }) {
            ShareSheet(items: exportShareItems)
        }
        // Upgrade gate
        .sheet(item: $upgradeFeature) { feature in
            UpgradeView(feature: feature)
                .environment(monetizationManager)
        }
        // New folder alert
        .alert(String(localized: "New Folder"), isPresented: $isNewFolderPresented) {
            TextField(String(localized: "Folder name"), text: $newFolderName)
            Button(String(localized: "Create")) {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                folderStore.createFolder(name: name.isEmpty ? String(localized: "New Folder") : name)
            }
            Button(String(localized: "Cancel"), role: .cancel) { }
        } message: {
            Text(String(localized: "Give this folder a name."))
        }
        // Move to folder action sheet
        .confirmationDialog(
            String(localized: "Move to Folder"),
            isPresented: $isMoveToFolderPresented,
            titleVisibility: .visible
        ) {
            if let c = conversationToMove {
                // Existing folders
                ForEach(folderStore.folders) { folder in
                    Button("\(folder.emoji) \(folder.name)") {
                        folderStore.assignConversation(c.id, to: folder.id)
                    }
                }

                // Remove from folder
                if folderStore.folderID(for: c.id) != nil {
                    Button(String(localized: "Remove from Folder"), role: .destructive) {
                        folderStore.assignConversation(c.id, to: nil)
                    }
                }

                Button(String(localized: "New Folder…")) {
                    newFolderName = ""
                    isNewFolderPresented = true
                }

                Button(String(localized: "Cancel"), role: .cancel) { }
            }
        }
        // Rename conversation alert
        .alert(String(localized: "Rename Conversation"), isPresented: $isRenamePresented) {
            TextField(String(localized: "Conversation name"), text: $renameText)
            Button(String(localized: "Rename")) {
                if let conversation = conversationToRename {
                    historyManager.updateTitle(renameText, for: conversation.id)
                }
                conversationToRename = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                conversationToRename = nil
            }
        } message: {
            Text(String(localized: "Enter a new name for this conversation."))
        }
        // Pinned messages sheet
        .sheet(isPresented: $showPinnedMessages) {
            PinnedMessagesView()
                .environment(historyManager)
        }
    }

    // MARK: - Statistics Card

    private var conversationStatsCard: some View {
        let conversations = historyManager.conversations
        let totalConversations = conversations.count
        let totalMessages = conversations.reduce(0) { $0 + $1.messages.count }

        return HStack(spacing: 0) {
            statItem(value: "\(totalConversations)", label: String(localized: "Chats"), icon: "bubble.left.and.bubble.right.fill", tint: .blue)
            statDivider
            statItem(value: "\(totalMessages)", label: String(localized: "Messages"), icon: "text.bubble.fill", tint: .purple)
            statDivider
            statItem(value: abbreviatedWordCount(for: conversations), label: String(localized: "Words"), icon: "textformat.abc", tint: .orange)
        }
        .padding(.vertical, 16)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.04), radius: 10, y: 5)
        .padding(.bottom, 4)
    }

    /// Computes total word count — called only when stats card is visible.
    /// Uses a sampling approach for very large histories to avoid blocking the main thread.
    private func abbreviatedWordCount(for conversations: [ChatConversation]) -> String {
        let totalWords = conversations.reduce(0) { sum, conv in
            sum + conv.messages.reduce(0) { $0 + $1.content.split { $0.isWhitespace }.count }
        }
        return abbreviatedNumber(totalWords)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color(white: 0.9))
            .frame(width: 1, height: 36)
    }

    private func statItem(value: String, label: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Color(white: 0.15))
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color(white: 0.5))
        }
        .frame(maxWidth: .infinity)
    }

    private func abbreviatedNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private var totalPinnedCount: Int {
        historyManager.conversations.reduce(0) { sum, conv in
            sum + conv.messages.filter(\.isPinned).count
        }
    }

    // MARK: - Folder Chips

    private var folderChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                folderChip(
                    id: nil,
                    label: String(localized: "All"),
                    systemImage: "tray.full.fill"
                )

                ForEach(folderStore.folders) { folder in
                    folderChip(
                        id: folder.id,
                        label: "\(folder.emoji) \(folder.name)",
                        systemImage: nil
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            if selectedFolderID == folder.id { selectedFolderID = nil }
                            folderStore.deleteFolder(id: folder.id)
                        } label: {
                            Label(String(localized: "Delete Folder"), systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func folderChip(id: UUID?, label: String, systemImage: String?) -> some View {
        let isSelected = selectedFolderID == id
        return Button {
            withAnimation(.spring(response: 0.3)) {
                selectedFolderID = id
            }
        } label: {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                }
                Text(label)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? Color.orange : Color.white)
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func handleExport(_ conversation: ChatConversation) {
        guard monetizationManager.canUse(.conversationExport) else {
            upgradeFeature = .conversationExport
            return
        }
        let markdown = ConversationExporter.export(
            messages: conversation.messages,
            title: conversation.title,
            format: .markdown
        )
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(ConversationExporter.fileName(title: conversation.title, format: .markdown))
        try? markdown.write(to: tempURL, atomically: true, encoding: .utf8)
        exportShareItems = [tempURL]
        isShareSheetPresented = true
    }

    private func handleMoveToFolder(_ conversation: ChatConversation) {
        guard monetizationManager.canUse(.chatFolders) else {
            upgradeFeature = .chatFolders
            return
        }
        conversationToMove = conversation
        isMoveToFolderPresented = true
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 50, weight: .light))
                .foregroundStyle(Color(white: 0.7))

            Text(String(localized: "No Conversations Yet"))
                .font(.headline)
                .foregroundStyle(Color(white: 0.4))

            Text(String(localized: "Start a new chat to see it here"))
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
    let folderLabel: String?
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
                    HStack(spacing: 6) {
                        Text(conversation.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color(white: 0.1))
                            .lineLimit(1)

                        if let folderLabel {
                            Text(folderLabel)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.1), in: Capsule())
                                .lineLimit(1)
                        }
                    }

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
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var formattedDate: String {
        Self.relativeDateFormatter.localizedString(for: conversation.updatedAt, relativeTo: Date())
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
        .environment(MonetizationManager())
}

struct ChatFolder: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var emoji: String

    init(id: UUID = UUID(), name: String, emoji: String = "📁") {
        self.id = id
        self.name = name
        self.emoji = emoji
    }
}

@MainActor
@Observable
final class ChatFolderStore {
    static let shared = ChatFolderStore()

    private static let foldersKey = "chatFolders.folders.v1"
    private static let assignmentsKey = "chatFolders.assignments.v1"

    private(set) var folders: [ChatFolder] = []

    /// Maps conversationID (UUID string) → folderID (UUID string)
    private var assignments: [String: String] = [:]

    private init() {
        load()
    }

    // MARK: - Folder Management

    @discardableResult
    func createFolder(name: String, emoji: String = "📁") -> ChatFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = ChatFolder(
            name: trimmed.isEmpty ? String(localized: "New Folder") : trimmed,
            emoji: emoji
        )
        folders.append(folder)
        persist()
        return folder
    }

    func updateFolder(id: UUID, name: String, emoji: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        folders[index].name = trimmed.isEmpty ? String(localized: "New Folder") : trimmed
        folders[index].emoji = emoji
        persist()
    }

    func deleteFolder(id: UUID) {
        folders.removeAll { $0.id == id }
        // Remove all assignments for this folder
        assignments = assignments.filter { $0.value != id.uuidString }
        persist()
    }

    func moveFolders(fromOffsets: IndexSet, toOffset: Int) {
        folders.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    // MARK: - Assignment

    func assignConversation(_ conversationID: UUID, to folderID: UUID?) {
        if let folderID {
            assignments[conversationID.uuidString] = folderID.uuidString
        } else {
            assignments.removeValue(forKey: conversationID.uuidString)
        }
        persist()
    }

    func folderID(for conversationID: UUID) -> UUID? {
        guard let rawID = assignments[conversationID.uuidString] else { return nil }
        return UUID(uuidString: rawID)
    }

    func folder(for conversationID: UUID) -> ChatFolder? {
        guard let folderID = folderID(for: conversationID) else { return nil }
        return folders.first { $0.id == folderID }
    }

    func conversations(in folderID: UUID) -> Set<UUID> {
        Set(
            assignments
                .filter { $0.value == folderID.uuidString }
                .compactMap { UUID(uuidString: $0.key) }
        )
    }

    // MARK: - Persistence

    private func persist() {
        if let foldersData = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(foldersData, forKey: Self.foldersKey)
        }
        if let assignData = try? JSONEncoder().encode(assignments) {
            UserDefaults.standard.set(assignData, forKey: Self.assignmentsKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.foldersKey),
           let decoded = try? JSONDecoder().decode([ChatFolder].self, from: data) {
            folders = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.assignmentsKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            assignments = decoded
        }
    }
}
