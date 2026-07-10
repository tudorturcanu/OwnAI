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
        guard firstNonWhitespace < content.endIndex,
              content[firstNonWhitespace...].hasPrefix(thinkingOpenMarker) else {
            return (content: content, thinkingContent: "", containsThinking: false)
        }

        var cursor = firstNonWhitespace
        var visibleStart = cursor
        var thinkingSegments: [String] = []

        while cursor < content.endIndex,
              content[cursor...].hasPrefix(thinkingOpenMarker) {
            let thinkingStart = content.index(cursor, offsetBy: thinkingOpenMarker.count)

            guard let closeRange = content.range(of: thinkingCloseMarker, range: thinkingStart..<content.endIndex) else {
                thinkingSegments.append(String(content[thinkingStart..<content.endIndex]))
                return (
                    content: String(content[..<firstNonWhitespace]),
                    thinkingContent: thinkingSegments.joined(separator: "\n\n"),
                    containsThinking: true
                )
            }

            thinkingSegments.append(String(content[thinkingStart..<closeRange.lowerBound]))
            cursor = closeRange.upperBound
            visibleStart = cursor

            let nextTokenStart = skipLeadingWhitespace(in: content, from: cursor)
            guard nextTokenStart < content.endIndex,
                  content[nextTokenStart...].hasPrefix(thinkingOpenMarker) else {
                return (
                    content: String(content[visibleStart..<content.endIndex]),
                    thinkingContent: thinkingSegments.joined(separator: "\n\n"),
                    containsThinking: true
                )
            }

            cursor = nextTokenStart
        }

        return (content: content, thinkingContent: "", containsThinking: false)
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
    
    init(id: UUID = UUID(), title: String = "New Chat", messages: [ChatMessage] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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
    @ObservationIgnored private let store: ChatHistoryStore
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
        let snapshot = conversations
        let selectedConversationID = currentConversationID
        let store = store
        let delay: TimeInterval = immediately ? 0 : 0.6
        
        pendingSaveWorkItem?.cancel()
        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem {
            guard let workItem, !workItem.isCancelled else { return }
            do {
                try store.persist(
                    conversations: snapshot,
                    currentConversationID: selectedConversationID,
                    changedConversationIDs: changedConversationIDs,
                    deletedConversationIDs: deletedConversationIDs
                )
            } catch {
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
        } catch {
        }
    }

    func applyRetentionPolicy() {
        guard historyRetentionDays > 0 else { return }

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
    
    /// Delete a conversation
    func deleteConversation(_ id: UUID) {
        if let conversation = conversations.first(where: { $0.id == id }) {
            conversation.messages.forEach { message in
                if let fileName = message.imageFileName {
                    ImageAttachmentManager.shared.deleteImage(named: fileName)
                }
            }
        }
        DocumentManager.shared.clearDocuments(for: id)
        conversations.removeAll { $0.id == id }
        
        // If we deleted the current conversation, select another or create new
        if currentConversationID == id {
            if let first = conversations.first {
                currentConversationID = first.id
            } else {
                let freshConversation = ChatConversation()
                conversations = [freshConversation]
                currentConversationID = freshConversation.id
                saveConversations(
                    immediately: true,
                    changedConversationIDs: Set([freshConversation.id]),
                    deletedConversationIDs: Set([id])
                )
                return
            }
        }
        saveConversations(immediately: true, changedConversationIDs: Set(), deletedConversationIDs: Set([id]))
    }

    /// Delete a single message from the current conversation
    func deleteMessage(id: UUID) {
        guard let currentConversationID,
              let convIndex = conversationIndexMap[currentConversationID],
              convIndex < conversations.count else { return }
        if let message = conversations[convIndex].messages.first(where: { $0.id == id }),
           let fileName = message.imageFileName {
            ImageAttachmentManager.shared.deleteImage(named: fileName)
        }
        conversations[convIndex].messages.removeAll { $0.id == id }
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

        let removed = conversations[convIndex].messages.suffix(from: msgIndex + 1)
        removed.forEach { message in
            if let fileName = message.imageFileName {
                ImageAttachmentManager.shared.deleteImage(named: fileName)
            }
        }
        conversations[convIndex].messages = Array(conversations[convIndex].messages.prefix(msgIndex + 1))
        conversations[convIndex].updatedAt = Date()
        saveConversations(immediately: true, changedConversationIDs: Set([conversationID]))
    }

    func branchConversation(from messageID: UUID) {
        guard let baseID = currentConversationID,
              let baseConversation = conversation(id: baseID),
              let idx = baseConversation.messages.firstIndex(where: { $0.id == messageID }) else { return }

        var branched = ChatConversation(
            title: baseConversation.title,
            messages: Array(baseConversation.messages.prefix(idx + 1)),
            createdAt: Date(),
            updatedAt: Date()
        )
        if branched.title == "New Chat" {
            branched.generateTitle()
        }

        conversations.insert(branched, at: 0)
        currentConversationID = branched.id
        saveConversations(immediately: true, changedConversationIDs: Set([branched.id]))
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
