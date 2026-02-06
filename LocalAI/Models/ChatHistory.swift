//
//  ChatHistory.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import Foundation

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
        
        // Start with a new conversation on app launch if the current one isn't already empty
        if conversations.isEmpty || !conversations[0].messages.isEmpty {
            newConversation()
        } else {
            currentConversationID = conversations.first?.id
        }
    }
    
    private var saveURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat_history.json")
    }
    
    /// Save conversations to disk
    func saveConversations() {
        do {
            let data = try JSONEncoder().encode(conversations)
            try data.write(to: saveURL)
        } catch {
            print("Failed to save conversations: \(error)")
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
                    if message.isStreaming {
                        // If it was streaming but has content, keep it but stop streaming
                        if !message.content.isEmpty {
                            return ChatMessage(id: message.id, role: message.role, content: message.content, isStreaming: false)
                        } else {
                            // If it was streaming and empty (interrupted thinking), remove it
                            return nil
                        }
                    }
                    return message
                }
                
                var updatedConversation = conversation
                updatedConversation.messages = updatedMessages
                return updatedConversation
            }
        } catch {
            print("No saved chat history found or failed to load: \(error)")
        }
    }
    
    
    /// Create a new conversation
    func newConversation() {
        let conversation = ChatConversation()
        conversations.insert(conversation, at: 0)
        currentConversationID = conversation.id
        saveConversations()
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
        saveConversations()
    }
    
    /// Add a message to the current conversation
    func addMessage(_ message: ChatMessage) {
        guard let index = conversations.firstIndex(where: { $0.id == currentConversationID }) else { return }
        
        conversations[index].messages.append(message)
        conversations[index].updatedAt = Date()
        
        // Generate title from first user message
        if conversations[index].messages.count == 1 && message.role == .user {
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

        conversations[convIndex].messages[msgIndex] = ChatMessage(
            id: id,
            role: conversations[convIndex].messages[msgIndex].role,
            content: content,
            isStreaming: isStreaming
        )
        
        // Save history intermittently (or eventually, but for now every update might be heavy)
        // Let's only save when streaming finishes or every N updates
        if !isStreaming {
            saveConversations()
        }
    }
    
    /// Get messages for current conversation
    var currentMessages: [ChatMessage] {
        currentConversation?.messages ?? []
    }
}
