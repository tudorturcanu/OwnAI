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

    /// True when shown as the persistent sidebar of an iPad split layout:
    /// no own NavigationStack, no Done button, and selection must not dismiss.
    var isEmbedded: Bool = false

    @State private var asyncWordCount: String = "0"
    @State private var searchText = ""
    @State private var selectedFolderID: UUID? = nil    // nil = "All"
    @State private var exportConversation: ChatConversation?
    @State private var exportShareItems: [Any] = []
    @State private var isShareSheetPresented = false
    @State private var upgradeFeature: PremiumFeature?
    @State private var isNewFolderPresented = false
    @State private var newFolderName = ""
    @State private var newFolderEmoji = "📁"
    /// Set when "New Folder…" is reached from Move to Folder: the conversation
    /// that should land in the folder as soon as it exists.
    @State private var conversationAwaitingNewFolder: UUID?
    @State private var folderToEdit: ChatFolder?
    @State private var isEditFolderPresented = false
    @State private var editFolderName = ""
    @State private var editFolderEmoji = ""
    @State private var isMoveToFolderPresented = false
    @State private var conversationToMove: ChatConversation?
    @State private var isRenamePresented = false
    @State private var conversationToRename: ChatConversation?
    @State private var renameText = ""
    @State private var conversationForMemory: ChatConversation?
    @State private var showPinnedMessages = false
    @State private var pendingUpgradeAction: PendingUpgradeAction?

    private enum PendingUpgradeAction {
        case export(UUID)
        case moveToFolder(UUID)
        case createFolder
    }

    /// Matches for `resolvedSearchQuery`, keyed by conversation ID. Scanning the
    /// whole history is done off the main actor so typing stays responsive.
    @State private var searchHits: [UUID: ConversationSearchEngine.Hit] = [:]
    /// The query `searchHits` was produced for; lags `searchText` while debouncing.
    @State private var resolvedSearchQuery = ""

    private var folderStore: ChatFolderStore { ChatFolderStore.shared }

    // MARK: - Filtered Conversations

    private var trimmedSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedSearchQuery.isEmpty }

    /// True while the debounced background scan for the current query is pending.
    private var isSearchPending: Bool {
        isSearching && resolvedSearchQuery != trimmedSearchQuery
    }

    var filteredConversations: [ChatConversation] {
        var base = historyManager.conversations

        // Folder filter
        if let folderID = selectedFolderID {
            let assignedIDs = folderStore.conversations(in: folderID)
            base = base.filter { assignedIDs.contains($0.id) }
        }

        // Search filter — the results of the last completed scan stay on screen
        // while a newer query is still being matched, so the list never blinks.
        if isSearching {
            base = base.filter { searchHits[$0.id] != nil }
        }

        return base
    }

    private var totalSearchMatchCount: Int {
        filteredConversations.reduce(0) { $0 + (searchHits[$1.id]?.matchCount ?? 0) }
    }

    /// Re-runs whenever the query changes or conversations are added/removed.
    private var searchTaskID: String {
        "\(trimmedSearchQuery)|\(historyManager.conversations.count)"
    }

    private func runSearch() async {
        let query = trimmedSearchQuery
        guard !query.isEmpty else {
            searchHits = [:]
            resolvedSearchQuery = ""
            return
        }

        // Debounce: `.task(id:)` cancels this before the sleep returns when the
        // next keystroke arrives, so only settled queries reach the scan.
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }

        let conversations = historyManager.conversations
        let hits = await Task.detached(priority: .userInitiated) {
            ConversationSearchEngine.search(query: query, in: conversations)
        }.value
        guard !Task.isCancelled else { return }

        searchHits = hits
        resolvedSearchQuery = query
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
        Group {
            if isEmbedded {
                listContent
            } else {
                NavigationStack {
                    listContent
                }
            }
        }
        // Undo bar for the most recent delete
        .safeAreaInset(edge: .bottom) {
            if let pending = historyManager.pendingDeletion {
                undoDeleteBar(for: pending)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: historyManager.pendingDeletion?.conversation.id)
        // Export share sheet
        .sheet(isPresented: $isShareSheetPresented, onDismiss: { discardExportedConversation() }) {
            ShareSheet(items: exportShareItems)
        }
        // Upgrade gate
        .sheet(item: $upgradeFeature) { feature in
            UpgradeView(feature: feature) {
                let action = pendingUpgradeAction
                pendingUpgradeAction = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    resumeAfterUpgrade(action)
                }
            }
                .environment(monetizationManager)
        }
        // Per-chat memory (rolling continuity summary)
        .sheet(item: $conversationForMemory) { conversation in
            ConversationMemoryView(conversationID: conversation.id)
                .environment(historyManager)
        }
        // New folder alert
        .alert(String(localized: "New Folder"), isPresented: $isNewFolderPresented) {
            TextField(String(localized: "Folder name"), text: $newFolderName)
            TextField(String(localized: "Emoji"), text: $newFolderEmoji)
            Button(String(localized: "Create")) {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                let folder = folderStore.createFolder(
                    name: name.isEmpty ? String(localized: "New Folder") : name,
                    emoji: Self.sanitizedEmoji(newFolderEmoji)
                )
                if let conversationID = conversationAwaitingNewFolder {
                    folderStore.assignConversation(conversationID, to: folder.id)
                }
                conversationAwaitingNewFolder = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                conversationAwaitingNewFolder = nil
            }
        } message: {
            Text(String(localized: "Give this folder a name and an icon."))
        }
        // Rename folder alert
        .alert(String(localized: "Rename Folder"), isPresented: $isEditFolderPresented) {
            TextField(String(localized: "Folder name"), text: $editFolderName)
            TextField(String(localized: "Emoji"), text: $editFolderEmoji)
            Button(String(localized: "Save")) {
                if let folder = folderToEdit {
                    let name = editFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    folderStore.updateFolder(
                        id: folder.id,
                        name: name.isEmpty ? folder.name : name,
                        emoji: Self.sanitizedEmoji(editFolderEmoji, fallback: folder.emoji)
                    )
                }
                folderToEdit = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { folderToEdit = nil }
        } message: {
            Text(String(localized: "Change this folder's name or icon."))
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
                    conversationAwaitingNewFolder = c.id
                    newFolderName = ""
                    newFolderEmoji = "📁"
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

    private var listContent: some View {
        List {
            // Conversation Statistics
            if !historyManager.conversations.isEmpty && searchText.isEmpty && selectedFolderID == nil {
                conversationStatsCard
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            // Folder Chips (Pro)
            if monetizationManager.canUse(.chatFolders) && !folderStore.folders.isEmpty {
                folderChipsRow
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if isSearching && !filteredConversations.isEmpty {
                searchSummaryRow
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 2, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if filteredConversations.isEmpty {
                Group {
                    if !isSearching {
                        emptyState
                    } else if isSearchPending {
                        searchInProgressState
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                ForEach(groupedConversations, id: \.title) { section in
                    Section {
                        ForEach(section.conversations) { conversation in
                            ConversationRow(
                                conversation: conversation,
                                isSelected: conversation.id == historyManager.currentConversationID,
                                folderLabel: folderStore.folder(for: conversation.id).map { "\($0.emoji) \($0.name)" },
                                searchHit: searchHits[conversation.id]
                            ) {
                                historyManager.selectConversation(conversation.id)
                                requestJumpToMatch(in: conversation.id)
                                if !isEmbedded {
                                    dismiss()
                                }
                            } onDelete: {
                                withAnimation(.spring(response: 0.3)) {
                                    historyManager.deleteConversation(conversation.id)
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    handleExport(conversation)
                                } label: {
                                    Label(String(localized: "Export"), systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)

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
                                    Label(String(localized: "Rename"), systemImage: "pencil")
                                }

                                Button {
                                    handleExport(conversation)
                                } label: {
                                    Label(String(localized: "Export as Markdown"), systemImage: "square.and.arrow.up")
                                }

                                Button {
                                    handleMoveToFolder(conversation)
                                } label: {
                                    Label(String(localized: "Move to Folder"), systemImage: "folder")
                                }

                                Button {
                                    conversationForMemory = conversation
                                } label: {
                                    Label(String(localized: "Chat Memory"), systemImage: "brain")
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
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.adaptive(white: 0.4))
                            .textCase(nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.adaptive(white: 0.96))
        .navigationTitle(String(localized: "History"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if !isEmbedded {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) {
                        dismiss()
                    }
                    .fontWeight(.medium)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    if totalPinnedCount > 0 {
                        Button {
                            showPinnedMessages = true
                        } label: {
                            Image(systemName: "pin.fill")
                                .accessibilityLabel(String(localized: "Pinned Messages"))
                                .font(.body)
                                .foregroundStyle(.orange)
                        }
                    }

                    Button {
                        if monetizationManager.canUse(.chatFolders) {
                            presentNewFolderAlert()
                        } else {
                            pendingUpgradeAction = .createFolder
                            upgradeFeature = .chatFolders
                        }
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .accessibilityLabel(String(localized: "New Folder"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        historyManager.newConversation()
                        if !isEmbedded {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .accessibilityLabel(String(localized: "New Chat"))
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
        .task(id: searchTaskID) {
            await runSearch()
        }
    }

    // MARK: - Undo Delete

    private func undoDeleteBar(for pending: ChatHistoryManager.PendingDeletion) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "Chat deleted"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(pending.conversation.title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(String(localized: "Undo")) {
                withAnimation(.spring(response: 0.3)) {
                    _ = historyManager.undoLastDeletion()
                }
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.orange)
            .buttonStyle(.plain)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(white: 0, opacity: 0.85))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Search Results

    private var searchSummaryRow: some View {
        HStack(spacing: 8) {
            if isSearchPending {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "text.magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }

            Text(searchSummaryText)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.adaptive(white: 0.45))

            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
    }

    private var searchSummaryText: String {
        let conversationCount = filteredConversations.count
        let matchCount = totalSearchMatchCount
        let chatsPart = String(
            format: String(localized: "%lld chats", defaultValue: "%lld chats"),
            Int64(conversationCount)
        )
        guard matchCount > 0 else { return chatsPart }
        let messagesPart = String(
            format: String(localized: "%lld matching messages", defaultValue: "%lld matching messages"),
            Int64(matchCount)
        )
        return "\(chatsPart) · \(messagesPart)"
    }

    private var searchInProgressState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(String(localized: "Searching…"))
                .font(.subheadline)
                .foregroundStyle(Color.adaptive(white: 0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
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
            statItem(value: asyncWordCount, label: String(localized: "Words"), icon: "textformat.abc", tint: .orange)
        }
        .padding(.vertical, 16)
        .background(Color.adaptiveCard, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.04), radius: 10, y: 5)
        .padding(.bottom, 4)
        .task(id: totalMessages) {
            await fetchAbbreviatedWordCount(for: conversations)
        }
    }

    /// Computes total word count — called only when stats card is visible.
    /// Uses a sampling approach for very large histories to avoid blocking the main thread.
    private func fetchAbbreviatedWordCount(for conversations: [ChatConversation]) async {
        let totalWords = await Task.detached(priority: .userInitiated) {
            conversations.reduce(0) { sum, conv in
                sum + conv.messages.reduce(0) { $0 + $1.content.split { $0.isWhitespace }.count }
            }
        }.value
        self.asyncWordCount = abbreviatedNumber(totalWords)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color.adaptive(white: 0.9))
            .frame(width: 1, height: 36)
    }

    private func statItem(value: String, label: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(value)
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(Color.adaptive(white: 0.15))
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.adaptive(white: 0.5))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
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
                        Button {
                            folderToEdit = folder
                            editFolderName = folder.name
                            editFolderEmoji = folder.emoji
                            isEditFolderPresented = true
                        } label: {
                            Label(String(localized: "Rename Folder"), systemImage: "pencil")
                        }

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

    /// Keeps folder icons to a single glyph — the alert's text field accepts any
    /// keyboard input, but the chip layout assumes one character.
    private static func sanitizedEmoji(_ raw: String, fallback: String = "📁") -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return fallback }
        return String(first)
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
            .frame(minHeight: 44)
            .background(isSelected ? Color.orange : Color.adaptiveCard)
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? String(localized: "Selected") : "")
    }

    // MARK: - Actions

    /// Asks the chat view to open scrolled to the message that matched the search,
    /// so a result tap lands on the text the user was looking for.
    private func requestJumpToMatch(in conversationID: UUID) {
        guard isSearching,
              let hit = searchHits[conversationID],
              let messageID = hit.firstMatchMessageID else { return }

        NotificationCenter.default.post(
            name: .ownAIConversationSearchMatch,
            object: nil,
            userInfo: [
                ConversationSearchMatchKey.conversationID: conversationID,
                ConversationSearchMatchKey.messageID: messageID,
                ConversationSearchMatchKey.query: resolvedSearchQuery
            ]
        )
    }

    private func handleExport(_ conversation: ChatConversation) {
        guard monetizationManager.canUse(.conversationExport) else {
            pendingUpgradeAction = .export(conversation.id)
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
        do {
            try markdown.write(to: tempURL, atomically: true, encoding: .utf8)
            // The conversation store is encrypted at rest; the plain-text
            // hand-off copy gets the same protection and is deleted once the
            // share sheet closes.
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: tempURL.path
            )
            exportShareItems = [tempURL]
            isShareSheetPresented = true
        } catch {
        }
    }

    private func discardExportedConversation() {
        for case let url as URL in exportShareItems {
            try? FileManager.default.removeItem(at: url)
        }
        exportShareItems = []
    }

    private func handleMoveToFolder(_ conversation: ChatConversation) {
        guard monetizationManager.canUse(.chatFolders) else {
            pendingUpgradeAction = .moveToFolder(conversation.id)
            upgradeFeature = .chatFolders
            return
        }
        conversationToMove = conversation
        isMoveToFolderPresented = true
    }

    private func presentNewFolderAlert() {
        conversationAwaitingNewFolder = nil
        newFolderName = ""
        newFolderEmoji = "📁"
        isNewFolderPresented = true
    }

    private func resumeAfterUpgrade(_ action: PendingUpgradeAction?) {
        guard monetizationManager.hasPro, let action else { return }
        switch action {
        case .export(let conversationID):
            guard let conversation = historyManager.conversations.first(where: { $0.id == conversationID }) else { return }
            handleExport(conversation)
        case .moveToFolder(let conversationID):
            guard let conversation = historyManager.conversations.first(where: { $0.id == conversationID }) else { return }
            handleMoveToFolder(conversation)
        case .createFolder:
            presentNewFolderAlert()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 50, weight: .light))
                .foregroundStyle(Color.adaptive(white: 0.7))
                .accessibilityHidden(true)

            Text(String(localized: "No Conversations Yet"))
                .font(.headline)
                .foregroundStyle(Color.adaptive(white: 0.4))

            Text(String(localized: "Start a new chat to see it here"))
                .font(.subheadline)
                .foregroundStyle(Color.adaptive(white: 0.6))

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

extension Notification.Name {
    /// Posted when a history search result is tapped, so the chat can scroll to the match.
    static let ownAIConversationSearchMatch = Notification.Name("com.ownai.conversationSearchMatch")
}

/// Keys used in the `ownAIConversationSearchMatch` notification's `userInfo` dictionary.
enum ConversationSearchMatchKey {
    static let conversationID = "conversationID"
    static let messageID = "messageID"
    static let query = "query"
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: ChatConversation
    let isSelected: Bool
    let folderLabel: String?
    /// Present while a history search is active; drives the excerpt and match badge.
    var searchHit: ConversationSearchEngine.Hit?
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
                            LinearGradient(colors: [Color.adaptive(white: 0.92)], startPoint: .top, endPoint: .bottom)
                        )
                        .frame(width: 44, height: 44)

                    Image(systemName: "bubble.left.fill")
                        .font(.body)
                        .foregroundStyle(
                            isSelected ?
                            LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing) :
                            LinearGradient(colors: [Color.adaptive(white: 0.5)], startPoint: .top, endPoint: .bottom)
                        )
                }

                // Content
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(conversation.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.adaptive(white: 0.1))
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

                    if let searchHit, !searchHit.snippet.isEmpty {
                        Text(highlightedSnippet(for: searchHit))
                            .font(.caption)
                            .foregroundStyle(Color.adaptive(white: 0.45))
                            .lineLimit(2)
                    } else if let lastMessage = conversation.messages.last {
                        Text(lastMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60) + (lastMessage.content.count > 60 ? "…" : ""))
                            .font(.caption)
                            .foregroundStyle(Color.adaptive(white: 0.45))
                            .lineLimit(1)
                    }

                    Text(formattedDate)
                        .font(.caption2)
                        .foregroundStyle(Color.adaptive(white: 0.55))
                }

                Spacer()

                // Match count while searching, otherwise total message count
                if let searchHit, searchHit.matchCount > 0 {
                    Text("\(searchHit.matchCount)")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                } else if !conversation.messages.isEmpty {
                    Text("\(conversation.messages.count)")
                        .font(.caption.bold())
                        .foregroundStyle(Color.adaptive(white: 0.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.adaptive(white: 0.92))
                        .clipShape(Capsule())
                }
            }
            .padding(14)
            .background(
                isSelected ?
                Color.adaptiveCard :
                Color.adaptiveCard.opacity(0.8)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Applies the engine's highlight offsets to the excerpt so the matched words
    /// stand out. Built by concatenation rather than by mutating attributes at
    /// computed indices, which would be invalidated by each edit.
    private func highlightedSnippet(for hit: ConversationSearchEngine.Hit) -> AttributedString {
        let characters = Array(hit.snippet)
        guard !hit.highlightRanges.isEmpty else { return AttributedString(hit.snippet) }

        var result = AttributedString()
        var cursor = 0

        // Ranges arrive sorted and non-overlapping; clamping keeps a stale hit
        // from indexing past a shorter snippet.
        for range in hit.highlightRanges {
            let lower = min(max(range.lowerBound, cursor), characters.count)
            let upper = min(max(range.upperBound, lower), characters.count)
            guard upper > lower else { continue }

            if lower > cursor {
                result += AttributedString(String(characters[cursor..<lower]))
            }
            var highlighted = AttributedString(String(characters[lower..<upper]))
            highlighted.foregroundColor = .orange
            highlighted.font = .caption.weight(.bold)
            result += highlighted
            cursor = upper
        }

        if cursor < characters.count {
            result += AttributedString(String(characters[cursor...]))
        }
        return result
    }

    private var accessibilitySummary: String {
        var parts: [String] = [conversation.title]
        if let folderLabel {
            parts.append(folderLabel)
        }
        if let searchHit, searchHit.matchCount > 0 {
            parts.append(String(
                format: String(localized: "%lld matching messages", defaultValue: "%lld matching messages"),
                Int64(searchHit.matchCount)
            ))
        }
        parts.append(String(
            format: String(localized: "%lld messages", defaultValue: "%lld messages"),
            Int64(conversation.messages.count)
        ))
        parts.append(formattedDate)
        return parts.joined(separator: ", ")
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
