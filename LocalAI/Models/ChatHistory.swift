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
    private static let controlMarkers = [
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

    static func sanitize(_ content: String) -> String {
        let truncated = truncateAtFirstControlMarker(in: content)
        let withoutPartialMarker = stripTrailingPartialMarker(from: truncated)

        if truncated != content {
            return withoutPartialMarker.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return withoutPartialMarker
    }

    static func containsControlMarker(_ content: String) -> Bool {
        firstControlMarkerIndex(in: content) != nil
    }

    private static func truncateAtFirstControlMarker(in content: String) -> String {
        guard let index = firstControlMarkerIndex(in: content) else {
            return content
        }
        return String(content[..<index])
    }

    private static func firstControlMarkerIndex(in content: String) -> String.Index? {
        controlMarkers.compactMap { marker in
            content.range(of: marker)?.lowerBound
        }
        .min()
    }

    private static func stripTrailingPartialMarker(from content: String) -> String {
        guard !content.isEmpty else { return content }

        let minimumPartialLength = 4
        var longestSuffixLength = 0

        for marker in controlMarkers {
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
            let content = firstUserMessage.content
            title = String(content.prefix(30)) + (content.count > 30 ? "..." : "")
        }
    }
}

/// Manages chat history and persistence
@MainActor
@Observable
final class ChatHistoryManager {
    
    var conversations: [ChatConversation] = []
    var currentConversationID: UUID?
    @ObservationIgnored private var pendingSaveWorkItem: DispatchWorkItem?
    @ObservationIgnored private let saveQueue = DispatchQueue(
        label: "alice.turcanu.LocalAI.chat-history-save",
        qos: .utility
    )
    @ObservationIgnored @AppStorage("historyRetentionDays") private var historyRetentionDays: Int = 0
    
    var currentConversation: ChatConversation? {
        get {
            guard let id = currentConversationID else { return nil }
            return conversations.first { $0.id == id }
        }
        set {
            if let newValue = newValue, let index = conversations.firstIndex(where: { $0.id == newValue.id }) {
                conversations[index] = newValue
            }
        }
    }
    
    init() {
        loadConversations()
        let removedDuplicateDrafts = deduplicateEmptyConversations()
        applyRetentionPolicy()
        
        // Start with a new conversation on app launch if the current one isn't already empty
        if conversations.isEmpty || !conversations[0].messages.isEmpty {
            newConversation()
        } else {
            currentConversationID = conversations.first?.id
            if removedDuplicateDrafts {
                saveConversations(immediately: true)
            }
        }
    }
    
    private var saveURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat_history.json")
    }
    
    /// Save conversations to disk
    func saveConversations(immediately: Bool = false) {
        let snapshot = conversations
        let url = saveURL
        let delay: TimeInterval = immediately ? 0 : 0.6
        
        pendingSaveWorkItem?.cancel()
        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem {
            guard let workItem, !workItem.isCancelled else { return }
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                print("Failed to save conversations: \(error)")
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
            let data = try Data(contentsOf: saveURL)
            let decoded = try JSONDecoder().decode([ChatConversation].self, from: data)
            
            // Sanitize: Fix stuck streaming state
            self.conversations = decoded.map { conversation in
                var updatedMessages = conversation.messages.compactMap { message -> ChatMessage? in
                    let sanitizedContent = message.role == .assistant
                        ? AssistantOutputSanitizer.sanitize(message.content)
                        : message.content

                    if message.isStreaming {
                        // If it was streaming but has content, keep it but stop streaming
                        if !sanitizedContent.isEmpty {
                            return ChatMessage(id: message.id, role: message.role, content: sanitizedContent, isStreaming: false)
                        } else {
                            // If it was streaming and empty (interrupted thinking), remove it
                            return nil
                        }
                    }
                    if message.role == .assistant && sanitizedContent.isEmpty {
                        return nil
                    }
                    return ChatMessage(id: message.id, role: message.role, content: sanitizedContent, isStreaming: false)
                }
                
                var updatedConversation = conversation
                updatedConversation.messages = updatedMessages
                return updatedConversation
            }
        } catch {
            print("No saved chat history found or failed to load: \(error)")
        }
    }

    func applyRetentionPolicy() {
        guard historyRetentionDays > 0 else { return }

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -historyRetentionDays, to: Date()) ?? .distantPast
        let originalCount = conversations.count
        conversations.removeAll { $0.updatedAt < cutoffDate }

        if conversations.isEmpty {
            currentConversationID = nil
            newConversation()
            return
        }

        if let currentConversationID, !conversations.contains(where: { $0.id == currentConversationID }) {
            self.currentConversationID = conversations.first?.id
        }

        if conversations.count != originalCount {
            saveConversations(immediately: true)
        }
    }

    func updateRetention(days: Int) {
        historyRetentionDays = max(0, days)
        applyRetentionPolicy()
    }

    func clearAllConversations() {
        conversations.removeAll()
        currentConversationID = nil
        newConversation()
    }
    
    
    /// Create a new conversation
    func newConversation() {
        _ = deduplicateEmptyConversations()

        if let existingEmptyIndex = conversations.firstIndex(where: \.messages.isEmpty) {
            let existingEmptyConversation = conversations.remove(at: existingEmptyIndex)
            conversations.insert(existingEmptyConversation, at: 0)
            currentConversationID = existingEmptyConversation.id
            saveConversations(immediately: true)
            return
        }

        let conversation = ChatConversation()
        conversations.insert(conversation, at: 0)
        currentConversationID = conversation.id
        saveConversations(immediately: true)
    }
    
    /// Select a conversation
    func selectConversation(_ id: UUID) {
        currentConversationID = id
        // No need to save on selection unless we want to track last selected
    }
    
    /// Delete a conversation
    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        
        // If we deleted the current conversation, select another or create new
        if currentConversationID == id {
            if let first = conversations.first {
                currentConversationID = first.id
            } else {
                newConversation()
            }
        }
        saveConversations(immediately: true)
    }
    
    /// Add a message to the current conversation
    func addMessage(_ message: ChatMessage) {
        guard let index = conversations.firstIndex(where: { $0.id == currentConversationID }) else { return }

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
        
        saveConversations()
    }
    
    /// Update a message in the current conversation
    func updateMessage(id: UUID, content: String, isStreaming: Bool) {
        guard let convIndex = conversations.firstIndex(where: { $0.id == currentConversationID }) else { return }
        guard let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == id }) else { return }

        let role = conversations[convIndex].messages[msgIndex].role
        let sanitizedContent = role == .assistant
            ? AssistantOutputSanitizer.sanitize(content)
            : content

        conversations[convIndex].messages[msgIndex] = ChatMessage(
            id: id,
            role: role,
            content: sanitizedContent,
            isStreaming: isStreaming
        )
        
        // Persist partial assistant output as it streams so app refreshes don't
        // discard the in-progress response. Streaming saves stay debounced.
        if isStreaming {
            saveConversations()
        } else {
            saveConversations(immediately: true)
        }
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
            isStreaming: message.isStreaming
        )
    }

    private func deduplicateEmptyConversations() -> Bool {
        var keptEmptyConversationID: UUID?
        var removedDuplicates = false
        conversations.removeAll { conversation in
            guard conversation.messages.isEmpty else { return false }
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
}
