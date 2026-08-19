//
//  ChatHistory.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import Foundation
import Observation
import SwiftUI

enum AssistantOutputSanitizer {
    struct Parts: Equatable {
        let content: String
        let thinkingContent: String?
    }

    nonisolated private static let controlMarkers = [
        "<end_of_turn>",
        "<start_of_turn>",
        "<|eot_id|>",
        "<|end_of_text|>",
        "<|start_header_id|>",
        "<|end_header_id|>",
        "<eos>",
        "<bos>",
        "</s>",
        "[/INST]",
        "[INST]"
    ]
    nonisolated private static let thinkingOpenMarker = "<think>"
    nonisolated private static let thinkingCloseMarker = "</think>"

    nonisolated static func sanitize(_ content: String) -> String {
        parts(from: content).content
    }

    nonisolated static func parts(from content: String) -> Parts {
        let withoutPartialMarker = stripTrailingPartialMarker(from: content)
        let truncated = truncateAtFirstControlMarker(in: withoutPartialMarker)
        let extracted = extractThinkingSegments(from: truncated)
        let visibleContent = stripStandaloneThinkingMarkers(from: extracted.content)

        let sanitizedContent = normalizeSegment(
            visibleContent,
            trimWhitespace: withoutPartialMarker != content || truncated != withoutPartialMarker || extracted.containsThinking || visibleContent != extracted.content
        )
        let sanitizedThinking = normalizeSegment(extracted.thinkingContent, trimWhitespace: true)

        return Parts(
            content: sanitizedContent,
            thinkingContent: sanitizedThinking.isEmpty ? nil : sanitizedThinking
        )
    }

    nonisolated static func containsControlMarker(_ content: String) -> Bool {
        firstControlMarkerIndex(in: content) != nil
    }

    /// Rebuilds the tagged form these parts came from, so reasoning survives a
    /// round trip through `parts(from:)`. Streaming buffers, the response
    /// character limit, and message editing all re-derive content this way;
    /// dropping the block here is what makes a chain of thought vanish from a
    /// finished message.
    nonisolated static func canonicalized(_ parts: Parts) -> String {
        let thinking = parts.thinkingContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !thinking.isEmpty else { return parts.content }

        let answer = parts.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let block = "\(thinkingOpenMarker)\(thinking)\(thinkingCloseMarker)"
        return answer.isEmpty ? block : "\(block)\n\(answer)"
    }

    nonisolated private static func truncateAtFirstControlMarker(in content: String) -> String {
        guard let index = firstControlMarkerIndex(in: content) else {
            return content
        }
        return String(content[..<index])
    }

    nonisolated private static func firstControlMarkerIndex(in content: String) -> String.Index? {
        controlMarkers.compactMap { marker in
            content.range(of: marker)?.lowerBound
        }
        .min()
    }

    nonisolated private static func stripTrailingPartialMarker(from content: String) -> String {
        guard !content.isEmpty else { return content }

        let minimumPartialLength = 4
        var longestSuffixLength = 0

        for marker in controlMarkers + [thinkingOpenMarker, thinkingCloseMarker] {
            guard marker.count > minimumPartialLength else { continue }

            for prefixLength in stride(from: marker.count - 1, through: minimumPartialLength, by: -1) {
                let prefix = String(marker.prefix(prefixLength))
                if content.hasSuffix(prefix) {
                    longestSuffixLength = max(longestSuffixLength, prefixLength)
                    break
                }
            }
        }

        guard longestSuffixLength > 0 else { return content }
        return String(content.dropLast(longestSuffixLength))
    }

    nonisolated private static func stripStandaloneThinkingMarkers(from content: String) -> String {
        guard !content.isEmpty else { return content }

        // Some models emit a stray closing tag without a matching <think> block.
        // That tag should never reach the visible answer text.
        return content
            .replacingOccurrences(of: thinkingCloseMarker, with: "")
            .replacingOccurrences(of: thinkingOpenMarker, with: "")
    }

    nonisolated private static func extractThinkingSegments(from content: String) -> (content: String, thinkingContent: String, containsThinking: Bool) {
        guard !content.isEmpty else {
            return (content: "", thinkingContent: "", containsThinking: false)
        }

        let firstNonWhitespace = skipLeadingWhitespace(in: content, from: content.startIndex)
        guard firstNonWhitespace < content.endIndex else {
            return (content: content, thinkingContent: "", containsThinking: false)
        }

        // Two shapes open a reasoning block at the start of a response. The
        // explicit one is a leading "<think>". The implicit one is an
        // unmatched "</think>": models whose chat template pre-fills the
        // opening tag into the generation prompt (Nemotron 3, DeepSeek R1,
        // GLM) start generating *inside* the block, so their first token is
        // reasoning and the only tag they ever emit is the closing one.
        // Those templates split their own history on "</think>" for exactly
        // this reason — treating that tail as the answer matches them.
        let opensExplicitly = content[firstNonWhitespace...].hasPrefix(thinkingOpenMarker)
        let firstCloseRange = content.range(of: thinkingCloseMarker, range: firstNonWhitespace..<content.endIndex)
        let opensImplicitly = !opensExplicitly && firstCloseRange.map { closeRange in
            content.range(of: thinkingOpenMarker, range: firstNonWhitespace..<closeRange.lowerBound) == nil
        } == true

        guard opensExplicitly || opensImplicitly else {
            return (content: content, thinkingContent: "", containsThinking: false)
        }

        var cursor = firstNonWhitespace
        var visibleStart = cursor
        var thinkingSegments: [String] = []
        var isInsideThinking = opensImplicitly

        while cursor < content.endIndex {
            if !isInsideThinking {
                guard content[cursor...].hasPrefix(thinkingOpenMarker) else { break }
                cursor = content.index(cursor, offsetBy: thinkingOpenMarker.count)
                isInsideThinking = true
            }

            guard let closeRange = content.range(of: thinkingCloseMarker, range: cursor..<content.endIndex) else {
                // Still reasoning: the block is open and nothing has closed it
                // yet, so there is no answer to show.
                thinkingSegments.append(String(content[cursor..<content.endIndex]))
                return (
                    content: String(content[..<firstNonWhitespace]),
                    thinkingContent: thinkingSegments.joined(separator: "\n\n"),
                    containsThinking: true
                )
            }

            thinkingSegments.append(String(content[cursor..<closeRange.lowerBound]))
            cursor = closeRange.upperBound
            visibleStart = cursor
            isInsideThinking = false

            // Only a run of back-to-back blocks keeps counting as reasoning;
            // anything else starts the visible answer.
            cursor = skipLeadingWhitespace(in: content, from: cursor)
        }

        return (
            content: String(content[visibleStart..<content.endIndex]),
            thinkingContent: thinkingSegments.joined(separator: "\n\n"),
            containsThinking: true
        )
    }

    nonisolated private static func skipLeadingWhitespace(in content: String, from index: String.Index) -> String.Index {
        var cursor = index
        while cursor < content.endIndex, content[cursor].isWhitespace {
            cursor = content.index(after: cursor)
        }
        return cursor
    }

    nonisolated private static func normalizeSegment(_ content: String, trimWhitespace: Bool) -> String {
        trimWhitespace ? content.trimmingCharacters(in: .whitespacesAndNewlines) : content
    }
}

/// Represents a single chat conversation
struct ChatConversation: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    let createdAt: Date
    var updatedAt: Date
    // Model-written summary of turns that rolling condensation folded away
    // during generation. Persisted so continuity survives app restarts and
    // conversation switches: when a fresh session is built for this chat, the
    // summary rides along with the recent transcript. Optional, so history
    // saved before this field existed decodes unchanged.
    var rollingSummary: String?

    init(id: UUID = UUID(), title: String = "New Chat", messages: [ChatMessage] = [], createdAt: Date = Date(), updatedAt: Date = Date(), rollingSummary: String? = nil) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.rollingSummary = rollingSummary
    }
    
    /// Generate a title from the first user message
    mutating func generateTitle() {
        if let firstUserMessage = messages.first(where: { $0.role == .user }) {
            title = Self.fallbackTitle(for: firstUserMessage.content)
        }
    }

    static func fallbackTitle(for content: String) -> String {
        String(content.prefix(30)) + (content.count > 30 ? "..." : "")
    }
}

/// Manages chat history and persistence
@MainActor
@Observable
final class ChatHistoryManager {
    
    var conversations: [ChatConversation] = [] {
        didSet { rebuildConversationIndex() }
    }
    var currentConversationID: UUID?
    var persistenceNotice: String?
    @ObservationIgnored private let store: ChatHistoryStore
    @ObservationIgnored private var isPersistenceAvailable = true
    @ObservationIgnored private var hasActivePersistenceFailure = false
    @ObservationIgnored private var pendingSaveWorkItem: DispatchWorkItem?
    @ObservationIgnored private let saveQueue = DispatchQueue(
        label: "alice.turcanu.LocalAI.chat-history-save",
        qos: .utility
    )
    @ObservationIgnored @AppStorage("historyRetentionDays") private var historyRetentionDays: Int = 0
    @ObservationIgnored private var lastStreamingSaveByConversationID: [UUID: Date] = [:]
    @ObservationIgnored private let streamingSaveInterval: TimeInterval = 1.5

    // MARK: - O(1) Lookup Index
    /// Maps conversation UUID → index in `conversations` array.
    /// Rebuilt on every mutation of `conversations`.
    @ObservationIgnored private var conversationIndexMap: [UUID: Int] = [:]

    private func rebuildConversationIndex() {
        conversationIndexMap = Dictionary(
            uniqueKeysWithValues: conversations.enumerated().map { ($1.id, $0) }
        )
    }
    
    var currentConversation: ChatConversation? {
        get {
            guard let id = currentConversationID, let index = conversationIndexMap[id] else { return nil }
            return conversations[index]
        }
        set {
            if let newValue = newValue, let index = conversationIndexMap[newValue.id] {
                conversations[index] = newValue
            }
        }
    }

    func conversation(id: UUID?) -> ChatConversation? {
        guard let id else { return nil }
        guard let index = conversationIndexMap[id], index < conversations.count else { return nil }
        return conversations[index]
    }

    func messages(in conversationID: UUID?) -> [ChatMessage] {
        conversation(id: conversationID)?.messages ?? []
    }

    /// Walks only the tail used for prompt reconstruction instead of copying
    /// a long conversation and filtering most of it away.
    func recentCompletedMessages(
        in conversationID: UUID?,
        excluding messageID: UUID? = nil,
        limit: Int
    ) -> [ChatMessage] {
        guard limit > 0,
              let conversationID,
              let index = conversationIndexMap[conversationID],
              index < conversations.count else { return [] }

        var result: [ChatMessage] = []
        result.reserveCapacity(limit)
        for message in conversations[index].messages.reversed() {
            guard message.id != messageID, !message.isStreaming else { continue }
            result.append(message)
            if result.count == limit { break }
        }
        return result.reversed()
    }

    func containsMessage(_ messageID: UUID, in conversationID: UUID?) -> Bool {
        guard let conversationID,
              let convIndex = conversationIndexMap[conversationID],
              convIndex < conversations.count else { return false }
        return conversations[convIndex].messages.contains { $0.id == messageID }
    }

    func message(id messageID: UUID, in conversationID: UUID?) -> ChatMessage? {
        guard let conversationID,
              let convIndex = conversationIndexMap[conversationID],
              convIndex < conversations.count else { return nil }
        return conversations[convIndex].messages.first { $0.id == messageID }
    }
    
    init(store: ChatHistoryStore? = nil) {
        self.store = store ?? ChatHistoryStore()
        loadConversations()
        let removedDuplicateDrafts = deduplicateEmptyConversations()
        applyRetentionPolicy()
        
        // Start with a new conversation on app launch if the current one isn't already empty
        if conversations.isEmpty || !isReusableDraftConversation(conversations[0]) {
            newConversation()
        } else {
            if currentConversationID == nil {
                currentConversationID = conversations.first?.id
            }
            if removedDuplicateDrafts {
                saveConversations(immediately: true, changedConversationIDs: Set())
            }
        }
    }
    
    /// Save conversations to disk
    func saveConversations(
        immediately: Bool = false,
        changedConversationIDs: Set<UUID>? = nil,
        deletedConversationIDs: Set<UUID> = []
    ) {
        guard isPersistenceAvailable else { return }
        let fullSnapshot = changedConversationIDs == nil ? conversations : nil
        let changedConversations: [ChatConversation]
        if let changedConversationIDs {
            changedConversations = conversations.filter { changedConversationIDs.contains($0.id) }
        } else {
            changedConversations = []
        }
        let orderedConversationIDs = conversations.map(\.id)
        let selectedConversationID = currentConversationID
        let store = store
        let delay: TimeInterval = immediately ? 0 : 0.6
        
        pendingSaveWorkItem?.cancel()
        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem {
            guard let workItem, !workItem.isCancelled else { return }
            do {
                if let fullSnapshot {
                    try store.persist(
                        conversations: fullSnapshot,
                        currentConversationID: selectedConversationID,
                        changedConversationIDs: nil,
                        deletedConversationIDs: deletedConversationIDs
                    )
                } else {
                    try store.persistChanges(
                        changedConversations: changedConversations,
                        currentConversationID: selectedConversationID,
                        orderedConversationIDs: orderedConversationIDs,
                        deletedConversationIDs: deletedConversationIDs
                    )
                }
                Task { @MainActor [weak self] in
                    self?.recordPersistenceSuccess()
                }
            } catch {
                PerformanceLogger.safeDiagnostic(
                    "ChatHistory persist failed error=\(error.localizedDescription) type=\(String(describing: type(of: error)))"
                )
                Task { @MainActor [weak self] in
                    self?.hasActivePersistenceFailure = true
                    self?.persistenceNotice = String(localized: "Chat history could not be saved. Your current chats remain available until the app closes.")
                }
            }
        }
        guard let workItem else { return }
        pendingSaveWorkItem = workItem
        
        if delay == 0 {
            saveQueue.async(execute: workItem)
        } else {
            saveQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }
    
    /// Load conversations from disk
    func loadConversations() {
        do {
            let snapshot = try store.loadSnapshot()
            let decoded = snapshot.conversations
            
            // Sanitize: Fix stuck streaming state
            self.conversations = decoded.map { conversation in
                let updatedMessages = conversation.messages.compactMap { message -> ChatMessage? in
                    if message.isStreaming {
                        // If it was streaming but has content, keep it but stop streaming
                        if message.role == .assistant {
                            let normalized = normalizedAssistantMessage(message, isStreaming: false)
                            if !normalized.content.isEmpty || normalized.thinkingContent != nil {
                                return normalized
                            }
                            return nil
                        }
                        if !message.content.isEmpty {
                            return ChatMessage(
                                id: message.id,
                                role: message.role,
                                content: message.content,
                                sourceTitles: message.sourceTitles,
                                imageFileName: message.imageFileName,
                                retryPromptSeed: message.retryPromptSeed,
                                isStreaming: false
                            )
                        } else {
                            // If it was streaming and empty (interrupted thinking), remove it
                            return nil
                        }
                    }
                    if message.role == .assistant {
                        let normalized = normalizedAssistantMessage(message, isStreaming: false)
                        if normalized.content.isEmpty && normalized.thinkingContent == nil {
                            return nil
                        }
                        return normalized
                    }
                    return ChatMessage(
                        id: message.id,
                        role: message.role,
                        content: message.content,
                        sourceTitles: message.sourceTitles,
                        imageFileName: message.imageFileName,
                        retryPromptSeed: message.retryPromptSeed,
                        isStreaming: false
                    )
                }
                
                var updatedConversation = conversation
                updatedConversation.messages = updatedMessages
                return updatedConversation
            }
            currentConversationID = snapshot.currentConversationID
            if let recovery = snapshot.recoverySummary {
                if !recovery.indexRepairWasSaved {
                    persistenceNotice = recovery.unavailableConversationCount > 0
                        ? String(format: String(localized: "%lld chats could not be opened. The remaining history was recovered for this launch, but the repaired index could not be saved."), Int64(recovery.unavailableConversationCount))
                        : String(localized: "Your conversations were recovered for this launch, but the repaired chat history index could not be saved.")
                } else if recovery.rebuiltIndex {
                    persistenceNotice = recovery.unavailableConversationCount > 0
                        ? String(format: String(localized: "%lld chats could not be opened. The remaining chat history and its index were recovered."), Int64(recovery.unavailableConversationCount))
                        : String(localized: "The chat history index was repaired and your conversations were recovered.")
                } else {
                    persistenceNotice = String(format: String(localized: "%lld chats could not be opened. The remaining chat history was recovered."), Int64(recovery.unavailableConversationCount))
                }
            }
        } catch {
            PerformanceLogger.safeDiagnostic(
                "ChatHistory load failed error=\(error.localizedDescription) type=\(String(describing: type(of: error)))"
            )
            isPersistenceAvailable = false
            hasActivePersistenceFailure = true
            persistenceNotice = String(localized: "Chat history could not be opened. To protect existing files, new chat changes will not be saved during this launch.")
        }
    }

    /// File protection and Keychain access can be temporarily unavailable
    /// during launch. Retry after protected data becomes available and merge
    /// any messages created in the meantime instead of sacrificing either set.
    func retryPersistenceIfNeeded() {
        guard !isPersistenceAvailable else { return }
        do {
            let snapshot = try store.loadSnapshot()
            var recoveredByID = Dictionary(
                uniqueKeysWithValues: snapshot.conversations.map { ($0.id, $0) }
            )
            for conversation in conversations {
                recoveredByID[conversation.id] = conversation
            }
            let currentOrder = conversations.map(\.id)
            let currentIDs = Set(currentOrder)
            let remainingRecovered = snapshot.conversations
                .map(\.id)
                .filter { !currentIDs.contains($0) }
            conversations = (currentOrder + remainingRecovered).compactMap { recoveredByID[$0] }
            if currentConversationID == nil {
                currentConversationID = snapshot.currentConversationID ?? conversations.first?.id
            }
            isPersistenceAvailable = true
            hasActivePersistenceFailure = false
            persistenceNotice = nil
            saveConversations(immediately: true, changedConversationIDs: nil)
        } catch {
            PerformanceLogger.safeDiagnostic(
                "ChatHistory retry failed error=\(error.localizedDescription) type=\(String(describing: type(of: error)))"
            )
            hasActivePersistenceFailure = true
        }
    }

    private func recordPersistenceSuccess() {
        guard hasActivePersistenceFailure else { return }
        hasActivePersistenceFailure = false
        persistenceNotice = nil
    }

    func dismissPersistenceNotice() {
        persistenceNotice = nil
    }

    func applyRetentionPolicy() {
        guard historyRetentionDays > 0 else { return }

        // A conversation awaiting undo is already out of the list; finish it off
        // rather than leaving its attachments behind after a retention sweep.
        commitPendingDeletion()

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -historyRetentionDays, to: Date()) ?? .distantPast
        let expiredConversationIDs = conversations
            .filter { $0.updatedAt < cutoffDate }
            .map(\.id)
        let originalCount = conversations.count
        conversations.removeAll { $0.updatedAt < cutoffDate }

        if !expiredConversationIDs.isEmpty {
            let documentManager = DocumentManager.shared
            expiredConversationIDs.forEach { conversationID in
                documentManager.clearDocuments(for: conversationID)
            }
        }

        if conversations.isEmpty {
            currentConversationID = nil
            newConversation()
            return
        }

        if let currentConversationID, !conversations.contains(where: { $0.id == currentConversationID }) {
            self.currentConversationID = conversations.first?.id
        }

        if conversations.count != originalCount {
            saveConversations(
                immediately: true,
                changedConversationIDs: Set(),
                deletedConversationIDs: Set(expiredConversationIDs)
            )
        }
    }

    func updateRetention(days: Int) {
        historyRetentionDays = max(0, days)
        applyRetentionPolicy()
    }

    func clearAllConversations() {
        // Nothing may survive a "delete everything", so close any undo window first.
        commitPendingDeletion()
        let documentManager = DocumentManager.shared
        let deletedConversationIDs = Set(conversations.map(\.id))
        conversations.forEach { conversation in
            documentManager.clearDocuments(for: conversation.id)
            conversation.messages.forEach { message in
                if let fileName = message.imageFileName {
                    ImageAttachmentManager.shared.deleteImage(named: fileName)
                }
            }
        }
        ImageAttachmentManager.shared.deleteAllImages()
        let freshConversation = ChatConversation()
        conversations = [freshConversation]
        currentConversationID = freshConversation.id
        saveConversations(
            immediately: true,
            changedConversationIDs: Set([freshConversation.id]),
            deletedConversationIDs: deletedConversationIDs
        )
    }
    
    
    /// Create a new conversation
    func newConversation() {
        _ = deduplicateEmptyConversations()

        if let existingEmptyIndex = conversations.firstIndex(where: isReusableDraftConversation) {
            let existingEmptyConversation = conversations.remove(at: existingEmptyIndex)
            conversations.insert(existingEmptyConversation, at: 0)
            currentConversationID = existingEmptyConversation.id
            saveConversations(immediately: true, changedConversationIDs: Set())
            return
        }

        let conversation = ChatConversation()
        conversations.insert(conversation, at: 0)
        currentConversationID = conversation.id
        saveConversations(immediately: true, changedConversationIDs: Set([conversation.id]))
    }
    
    /// Select a conversation
    func selectConversation(_ id: UUID) {
        currentConversationID = id
        saveConversations(immediately: true, changedConversationIDs: Set())
    }
    
    /// Delete a conversation.
    ///
    /// The conversation leaves the list and its file immediately, but its
    /// attachments (images and imported documents) are only destroyed once the
    /// undo window closes — a full-swipe delete has no confirmation step, so
    /// `undoLastDeletion()` has to be able to bring everything back intact.
    func deleteConversation(_ id: UUID) {
        guard let removedIndex = conversationIndexMap[id], removedIndex < conversations.count else { return }

        // Only one deletion can be pending; committing first keeps attachment
        // cleanup from being postponed indefinitely by repeated deletes.
        commitPendingDeletion()

        let removedConversation = conversations[removedIndex]
        let wasCurrent = currentConversationID == id
        conversations.remove(at: removedIndex)

        // If we deleted the current conversation, select another or create new
        var replacementDraftID: UUID?
        if wasCurrent {
            if let first = conversations.first {
                currentConversationID = first.id
            } else {
                let freshConversation = ChatConversation()
                conversations = [freshConversation]
                currentConversationID = freshConversation.id
                replacementDraftID = freshConversation.id
            }
        }

        pendingDeletion = PendingDeletion(
            conversation: removedConversation,
            index: removedIndex,
            wasCurrent: wasCurrent,
            replacementDraftID: replacementDraftID
        )
        schedulePendingDeletionCommit()

        saveConversations(
            immediately: true,
            changedConversationIDs: replacementDraftID.map { Set([$0]) } ?? Set(),
            deletedConversationIDs: Set([id])
        )
    }

    // MARK: - Undo Delete

    struct PendingDeletion {
        let conversation: ChatConversation
        /// Position the conversation occupied, so undo restores the original order.
        let index: Int
        let wasCurrent: Bool
        /// Empty chat created only because this deletion emptied the list; undo
        /// removes it again so no stray draft is left behind.
        let replacementDraftID: UUID?
    }

    /// The most recent deletion, while it can still be undone.
    private(set) var pendingDeletion: PendingDeletion?

    @ObservationIgnored private var pendingDeletionCommitTask: Task<Void, Never>?
    /// How long the user has to undo before attachments are destroyed.
    @ObservationIgnored private let undoDeleteWindow: Duration = .seconds(6)

    private func schedulePendingDeletionCommit() {
        pendingDeletionCommitTask?.cancel()
        let window = undoDeleteWindow
        pendingDeletionCommitTask = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            self?.commitPendingDeletion()
        }
    }

    /// Restores the last deleted conversation, including its images and documents.
    @discardableResult
    func undoLastDeletion() -> Bool {
        guard let pending = pendingDeletion else { return false }
        pendingDeletionCommitTask?.cancel()
        pendingDeletionCommitTask = nil
        pendingDeletion = nil

        // Drop the placeholder chat this deletion created — unless the user has
        // since typed into it, in which case it is real content now.
        var removedDraftIDs: Set<UUID> = []
        if let draftID = pending.replacementDraftID,
           let draftIndex = conversationIndexMap[draftID],
           draftIndex < conversations.count,
           isReusableDraftConversation(conversations[draftIndex]) {
            conversations.remove(at: draftIndex)
            removedDraftIDs.insert(draftID)
        }

        let insertionIndex = min(pending.index, conversations.count)
        conversations.insert(pending.conversation, at: insertionIndex)

        let currentWasRemovedDraft = currentConversationID.map(removedDraftIDs.contains) ?? false
        if pending.wasCurrent || currentConversationID == nil || currentWasRemovedDraft {
            currentConversationID = pending.conversation.id
        }

        saveConversations(
            immediately: true,
            changedConversationIDs: Set([pending.conversation.id]),
            deletedConversationIDs: removedDraftIDs
        )
        return true
    }

    /// Destroys the attachments of a deletion that can no longer be undone.
    func commitPendingDeletion() {
        guard let pending = pendingDeletion else { return }
        pendingDeletionCommitTask?.cancel()
        pendingDeletionCommitTask = nil
        pendingDeletion = nil

        DocumentManager.shared.clearDocuments(for: pending.conversation.id)
        pending.conversation.messages
            .compactMap(\.imageFileName)
            .forEach(deleteImageIfUnreferenced)
    }

    /// Delete a single message from the current conversation
    func deleteMessage(id: UUID) {
        guard let currentConversationID,
              let convIndex = conversationIndexMap[currentConversationID],
              convIndex < conversations.count else { return }
        let removedImageFileName = conversations[convIndex].messages
            .first(where: { $0.id == id })?
            .imageFileName
        conversations[convIndex].messages.removeAll { $0.id == id }
        if let removedImageFileName {
            deleteImageIfUnreferenced(removedImageFileName)
        }
        saveConversations(immediately: true, changedConversationIDs: Set([conversations[convIndex].id]))
    }

    func togglePinned(messageID: UUID, in conversationID: UUID?) {
        guard let conversationID,
              let convIndex = conversationIndexMap[conversationID],
              convIndex < conversations.count,
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageID }) else { return }

        var message = conversations[convIndex].messages[msgIndex]
        message.isPinned.toggle()
        conversations[convIndex].messages[msgIndex] = message
        saveConversations(immediately: true, changedConversationIDs: Set([conversationID]))
    }

    func truncateConversation(after messageID: UUID, in conversationID: UUID?) {
        guard let conversationID,
              let convIndex = conversationIndexMap[conversationID],
              convIndex < conversations.count,
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageID }) else { return }

        let removedImageFileNames = conversations[convIndex].messages
            .suffix(from: msgIndex + 1)
            .compactMap(\.imageFileName)
        conversations[convIndex].messages = Array(conversations[convIndex].messages.prefix(msgIndex + 1))
        removedImageFileNames.forEach(deleteImageIfUnreferenced)
        conversations[convIndex].updatedAt = Date()
        saveConversations(immediately: true, changedConversationIDs: Set([conversationID]))
    }

    @discardableResult
    func branchConversation(from messageID: UUID) async -> Bool {
        guard let baseID = currentConversationID,
              let baseConversation = conversation(id: baseID),
              let idx = baseConversation.messages.firstIndex(where: { $0.id == messageID }) else { return false }

        var duplicatedImageFileNames: [String] = []
        var branchedMessages: [ChatMessage] = []
        for message in baseConversation.messages.prefix(idx + 1) {
            let duplicatedImageFileName: String?
            if let imageFileName = message.imageFileName {
                guard let copy = ImageAttachmentManager.shared.duplicateImage(named: imageFileName) else {
                    duplicatedImageFileNames.forEach(ImageAttachmentManager.shared.deleteImage)
                    return false
                }
                duplicatedImageFileNames.append(copy)
                duplicatedImageFileName = copy
            } else {
                duplicatedImageFileName = nil
            }

            branchedMessages.append(ChatMessage(
                role: message.role,
                content: message.content,
                thinkingContent: message.thinkingContent,
                sourceTitles: message.sourceTitles,
                imageFileName: duplicatedImageFileName,
                retryPromptSeed: message.retryPromptSeed,
                isPinned: message.isPinned,
                isStreaming: false
            ))
        }

        var branched = ChatConversation(
            title: baseConversation.title,
            messages: branchedMessages,
            createdAt: Date(),
            updatedAt: Date()
        )
        if branched.title == "New Chat" {
            branched.generateTitle()
        }

        await DocumentManager.shared.cloneDocuments(from: baseID, to: branched.id)

        conversations.insert(branched, at: 0)
        currentConversationID = branched.id
        saveConversations(immediately: true, changedConversationIDs: Set([branched.id]))
        return true
    }

    private func deleteImageIfUnreferenced(_ fileName: String) {
        let isStillReferenced = conversations.contains { conversation in
            conversation.messages.contains { $0.imageFileName == fileName }
        }
        guard !isStillReferenced else { return }
        ImageAttachmentManager.shared.deleteImage(named: fileName)
    }
    
    /// Add a message to the current conversation
    func addMessage(_ message: ChatMessage) {
        addMessage(message, to: currentConversationID)
    }

    func addMessage(_ message: ChatMessage, to conversationID: UUID?) {
        guard let conversationID,
              let index = conversationIndexMap[conversationID],
              index < conversations.count else { return }

        let sanitizedMessage = sanitizedAssistantMessage(message)
        
        conversations[index].messages.append(sanitizedMessage)
        conversations[index].updatedAt = Date()
        
        // Generate title from first user message
        if conversations[index].messages.count == 1 && sanitizedMessage.role == .user {
            conversations[index].generateTitle()
        }
        
        if index > 0 {
            var updatedConversations = conversations
            let conversation = updatedConversations.remove(at: index)
            updatedConversations.insert(conversation, at: 0)
            conversations = updatedConversations
        }
        
        saveConversations(changedConversationIDs: Set([conversations[0].id]))
    }
    
    /// Update a message in the current conversation
    func updateMessage(id: UUID, content: String, isStreaming: Bool, sourceTitles: [String]? = nil) {
        updateMessage(
            id: id,
            in: currentConversationID,
            content: content,
            isStreaming: isStreaming,
            sourceTitles: sourceTitles
        )
    }

    func updateMessage(
        id: UUID,
        in conversationID: UUID?,
        content: String,
        isStreaming: Bool,
        sourceTitles: [String]? = nil,
        imageFileName: String? = nil,
        retryPromptSeed: String? = nil
    ) {
        guard let conversationID,
              let convIndex = conversationIndexMap[conversationID],
              convIndex < conversations.count else { return }
        guard let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == id }) else { return }

        let role = conversations[convIndex].messages[msgIndex].role
        let preservedSourceTitles = sourceTitles ?? conversations[convIndex].messages[msgIndex].sourceTitles
        let preservedPinned = conversations[convIndex].messages[msgIndex].isPinned
        let preservedImageFileName = imageFileName ?? conversations[convIndex].messages[msgIndex].imageFileName
        let preservedRetryPromptSeed = retryPromptSeed ?? conversations[convIndex].messages[msgIndex].retryPromptSeed
        if role == .assistant {
            conversations[convIndex].messages[msgIndex] = assistantMessage(
                id: id,
                content: content,
                isStreaming: isStreaming,
                sourceTitles: preservedSourceTitles,
                imageFileName: preservedImageFileName,
                retryPromptSeed: preservedRetryPromptSeed
            )
            conversations[convIndex].messages[msgIndex].isPinned = preservedPinned
        } else {
            conversations[convIndex].messages[msgIndex] = ChatMessage(
                id: id,
                role: role,
                content: content,
                sourceTitles: preservedSourceTitles,
                imageFileName: preservedImageFileName,
                retryPromptSeed: preservedRetryPromptSeed,
                isPinned: preservedPinned,
                isStreaming: isStreaming
            )
        }
        
        // Persist partial assistant output as it streams so app refreshes don't
        // discard the in-progress response. Streaming saves stay throttled to
        // avoid disk churn during fast token updates.
        if isStreaming {
            saveStreamingUpdateIfNeeded(for: conversationID)
        } else {
            lastStreamingSaveByConversationID.removeValue(forKey: conversationID)
            saveConversations(immediately: true, changedConversationIDs: Set([conversations[convIndex].id]))
        }
    }

    private func saveStreamingUpdateIfNeeded(for conversationID: UUID) {
        let now = Date()
        guard now.timeIntervalSince(lastStreamingSaveByConversationID[conversationID] ?? .distantPast) >= streamingSaveInterval else {
            return
        }

        lastStreamingSaveByConversationID[conversationID] = now
        saveConversations(changedConversationIDs: Set([conversationID]))
    }

    /// Persists a throttled streaming snapshot without publishing it through
    /// `conversations`. This avoids copying the full history and invalidating
    /// every message row for each token batch.
    func persistStreamingSnapshot(
        messageID: UUID,
        conversationID: UUID,
        content: String
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastStreamingSaveByConversationID[conversationID] ?? .distantPast) >= streamingSaveInterval,
              let convIndex = conversationIndexMap[conversationID],
              convIndex < conversations.count,
              let messageIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        lastStreamingSaveByConversationID[conversationID] = now
        var conversation = conversations[convIndex]
        let existing = conversation.messages[messageIndex]
        conversation.messages[messageIndex] = ChatMessage(
            id: existing.id,
            role: existing.role,
            content: content,
            thinkingContent: existing.thinkingContent,
            sourceTitles: existing.sourceTitles,
            imageFileName: existing.imageFileName,
            retryPromptSeed: existing.retryPromptSeed,
            isPinned: existing.isPinned,
            isStreaming: true
        )
        conversation.updatedAt = now

        let orderedIDs = conversations.map(\.id)
        let selectedID = currentConversationID
        let store = store
        saveQueue.async { [weak self] in
            do {
                try store.persistConversation(
                    conversation,
                    currentConversationID: selectedID,
                    orderedConversationIDs: orderedIDs
                )
                Task { @MainActor in
                    self?.recordPersistenceSuccess()
                }
            } catch {
                PerformanceLogger.safeDiagnostic(
                    "ChatHistory streaming persist failed error=\(error.localizedDescription) type=\(String(describing: type(of: error)))"
                )
                Task { @MainActor in
                    self?.hasActivePersistenceFailure = true
                    self?.persistenceNotice = String(localized: "Chat history could not be saved. Your current chats remain available until the app closes.")
                }
            }
        }
    }

    func updateTitle(_ title: String, for conversationID: UUID?) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty,
              let conversationID,
              let convIndex = conversationIndexMap[conversationID],
              convIndex < conversations.count,
              conversations[convIndex].title != trimmedTitle else {
            return
        }

        conversations[convIndex].title = trimmedTitle
        conversations[convIndex].updatedAt = Date()
        saveConversations(immediately: true, changedConversationIDs: Set([conversationID]))
    }
    
    /// Stores the summary rolling condensation produced for a conversation.
    /// Debounced save: the summary only matters for future session rebuilds,
    /// so it doesn't need the immediate write updateTitle uses.
    func updateRollingSummary(_ summary: String, for conversationID: UUID?) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let conversationID,
              let convIndex = conversationIndexMap[conversationID],
              convIndex < conversations.count,
              conversations[convIndex].rollingSummary != trimmed else {
            return
        }

        conversations[convIndex].rollingSummary = trimmed
        saveConversations(changedConversationIDs: Set([conversationID]))
    }

    /// Forgets the continuity summary a rolling condensation stored for this
    /// conversation, so future session rebuilds start from the visible
    /// messages alone. Immediate save: the user just made a privacy choice
    /// and it must survive a prompt app kill.
    func clearRollingSummary(for conversationID: UUID) {
        guard let convIndex = conversationIndexMap[conversationID],
              convIndex < conversations.count,
              conversations[convIndex].rollingSummary != nil else {
            return
        }

        conversations[convIndex].rollingSummary = nil
        saveConversations(immediately: true, changedConversationIDs: Set([conversationID]))
    }

    /// Get messages for current conversation
    var currentMessages: [ChatMessage] {
        currentConversation?.messages ?? []
    }

    private func sanitizedAssistantMessage(_ message: ChatMessage) -> ChatMessage {
        guard message.role == .assistant else { return message }
        return ChatMessage(
            id: message.id,
            role: message.role,
            content: AssistantOutputSanitizer.sanitize(message.content),
            thinkingContent: message.thinkingContent?.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceTitles: message.sourceTitles,
            imageFileName: message.imageFileName,
            retryPromptSeed: message.retryPromptSeed,
            isStreaming: message.isStreaming
        )
    }

    private func assistantMessage(
        id: UUID,
        content: String,
        isStreaming: Bool,
        sourceTitles: [String] = [],
        imageFileName: String? = nil,
        retryPromptSeed: String? = nil
    ) -> ChatMessage {
        // Skip heavy sanitization logic while streaming to avoid O(N^2) overhead
        if isStreaming {
            return ChatMessage(
                id: id,
                role: .assistant,
                content: content,
                thinkingContent: nil,
                sourceTitles: sourceTitles,
                imageFileName: imageFileName,
                retryPromptSeed: retryPromptSeed,
                isStreaming: true
            )
        }
        
        let parts = AssistantOutputSanitizer.parts(from: content)
        return ChatMessage(
            id: id,
            role: .assistant,
            content: parts.content,
            thinkingContent: parts.thinkingContent,
            sourceTitles: sourceTitles,
            imageFileName: imageFileName,
            retryPromptSeed: retryPromptSeed,
            isStreaming: false
        )
    }

    private func normalizedAssistantMessage(_ message: ChatMessage, isStreaming: Bool) -> ChatMessage {
        if message.thinkingContent != nil {
            return ChatMessage(
                id: message.id,
                role: .assistant,
                content: AssistantOutputSanitizer.sanitize(message.content),
                thinkingContent: message.thinkingContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceTitles: message.sourceTitles,
                imageFileName: message.imageFileName,
                retryPromptSeed: message.retryPromptSeed,
                isStreaming: isStreaming
            )
        }
        return assistantMessage(
            id: message.id,
            content: message.content,
            isStreaming: isStreaming,
            sourceTitles: message.sourceTitles,
            imageFileName: message.imageFileName,
            retryPromptSeed: message.retryPromptSeed
        )
    }

    private func deduplicateEmptyConversations() -> Bool {
        var keptEmptyConversationID: UUID?
        var removedDuplicates = false
        conversations.removeAll { conversation in
            guard isReusableDraftConversation(conversation) else { return false }
            if keptEmptyConversationID == nil {
                keptEmptyConversationID = conversation.id
                return false
            }
            removedDuplicates = true
            if currentConversationID == conversation.id {
                currentConversationID = keptEmptyConversationID
            }
            return true
        }
        return removedDuplicates
    }

    private func isReusableDraftConversation(_ conversation: ChatConversation) -> Bool {
        conversation.messages.isEmpty && !DocumentManager.shared.hasDocuments(in: conversation.id)
    }
}
