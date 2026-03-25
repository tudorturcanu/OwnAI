import Foundation

struct ChatHistoryStore {
    struct Snapshot {
        let conversations: [ChatConversation]
        let currentConversationID: UUID?
    }

    private struct ConversationIndex: Codable {
        let version: Int
        let currentConversationID: UUID?
        let orderedConversationIDs: [UUID]
    }

    private let fileManager: FileManager
    private let baseDirectoryURL: URL
    private let legacyFileURL: URL
    private let indexURL: URL

    init(
        fileManager: FileManager = .default,
        baseDirectoryURL: URL? = nil,
        legacyFileURL: URL? = nil
    ) {
        self.fileManager = fileManager

        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let resolvedBaseDirectoryURL = baseDirectoryURL
            ?? documentsURL.appendingPathComponent("chat_history", isDirectory: true)

        self.baseDirectoryURL = resolvedBaseDirectoryURL
        self.legacyFileURL = legacyFileURL
            ?? documentsURL.appendingPathComponent("chat_history.json")
        self.indexURL = resolvedBaseDirectoryURL.appendingPathComponent("index.json")
    }

    func loadSnapshot() throws -> Snapshot {
        if fileManager.fileExists(atPath: indexURL.path) {
            return try loadIndexedSnapshot()
        }

        if fileManager.fileExists(atPath: legacyFileURL.path) {
            let conversations = try SecureFileStore.load([ChatConversation].self, from: legacyFileURL)
            let snapshot = Snapshot(
                conversations: conversations,
                currentConversationID: conversations.first?.id
            )
            try persist(
                conversations: snapshot.conversations,
                currentConversationID: snapshot.currentConversationID,
                changedConversationIDs: nil,
                deletedConversationIDs: []
            )
            try? SecureFileStore.removeFileIfPresent(at: legacyFileURL)
            return snapshot
        }

        return Snapshot(conversations: [], currentConversationID: nil)
    }

    func persist(
        conversations: [ChatConversation],
        currentConversationID: UUID?,
        changedConversationIDs: Set<UUID>?,
        deletedConversationIDs: Set<UUID>
    ) throws {
        try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)

        let conversationsByID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        var conversationIDsToDelete = deletedConversationIDs

        if let changedConversationIDs {
            for conversationID in changedConversationIDs {
                guard let conversation = conversationsByID[conversationID] else { continue }
                try SecureFileStore.save(conversation, to: conversationFileURL(for: conversationID))
            }
        } else {
            let activeIDs = Set(conversationsByID.keys)
            if let existingConversationURLs = try? fileManager.contentsOfDirectory(
                at: baseDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for url in existingConversationURLs where url.pathExtension == "json" && url.lastPathComponent != indexURL.lastPathComponent {
                    let fileName = url.deletingPathExtension().lastPathComponent
                    guard let conversationID = UUID(uuidString: fileName), !activeIDs.contains(conversationID) else {
                        continue
                    }
                    conversationIDsToDelete.insert(conversationID)
                }
            }

            for conversation in conversations {
                try SecureFileStore.save(conversation, to: conversationFileURL(for: conversation.id))
            }
        }

        let index = ConversationIndex(
            version: 1,
            currentConversationID: currentConversationID,
            orderedConversationIDs: conversations.map(\.id)
        )
        try SecureFileStore.save(index, to: indexURL)

        for conversationID in conversationIDsToDelete {
            try removeConversationFileIfPresent(id: conversationID)
        }
    }

    private func loadIndexedSnapshot() throws -> Snapshot {
        let index = try SecureFileStore.load(ConversationIndex.self, from: indexURL)
        var conversations: [ChatConversation] = []
        conversations.reserveCapacity(index.orderedConversationIDs.count)

        for conversationID in index.orderedConversationIDs {
            let fileURL = conversationFileURL(for: conversationID)
            guard fileManager.fileExists(atPath: fileURL.path) else { continue }
            let conversation = try SecureFileStore.load(ChatConversation.self, from: fileURL)
            conversations.append(conversation)
        }

        let selectedConversationID = index.currentConversationID.flatMap { candidate in
            conversations.contains(where: { $0.id == candidate }) ? candidate : conversations.first?.id
        }

        return Snapshot(
            conversations: conversations,
            currentConversationID: selectedConversationID
        )
    }

    private func conversationFileURL(for conversationID: UUID) -> URL {
        baseDirectoryURL.appendingPathComponent("\(conversationID.uuidString).json")
    }

    private func removeConversationFileIfPresent(id conversationID: UUID) throws {
        try SecureFileStore.removeFileIfPresent(at: conversationFileURL(for: conversationID))
    }
}
