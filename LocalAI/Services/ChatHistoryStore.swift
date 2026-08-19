import Foundation

struct ChatHistoryStore {
    struct RecoverySummary {
        let unavailableConversationCount: Int
        let rebuiltIndex: Bool
        let indexRepairWasSaved: Bool
    }

    struct Snapshot {
        let conversations: [ChatConversation]
        let currentConversationID: UUID?
        let recoverySummary: RecoverySummary?
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
                currentConversationID: conversations.first?.id,
                recoverySummary: nil
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

        return Snapshot(conversations: [], currentConversationID: nil, recoverySummary: nil)
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

        // Conversation files form the data referenced by the index, so publish
        // them first. If this process is interrupted, the previous index remains
        // a complete snapshot; newly written files are merely unreferenced.
        try saveIndex(
            conversations: conversations,
            currentConversationID: currentConversationID
        )

        // Delete only after the new index no longer references these files.
        for conversationID in conversationIDsToDelete {
            // A failed cleanup leaves only an unreferenced encrypted file. It
            // must not turn an already committed history update into a false
            // save failure; the next full persistence pass will retry cleanup.
            try? removeConversationFileIfPresent(id: conversationID)
        }
    }

    /// Hot-path persistence for an in-progress assistant reply. Only the one
    /// changed conversation and the tiny ordering index are encoded; callers
    /// do not need to retain/copy the complete history snapshot.
    func persistConversation(
        _ conversation: ChatConversation,
        currentConversationID: UUID?,
        orderedConversationIDs: [UUID]
    ) throws {
        try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
        try SecureFileStore.save(conversation, to: conversationFileURL(for: conversation.id))
        try saveIndex(
            orderedConversationIDs: orderedConversationIDs,
            currentConversationID: currentConversationID
        )
    }

    func persistChanges(
        changedConversations: [ChatConversation],
        currentConversationID: UUID?,
        orderedConversationIDs: [UUID],
        deletedConversationIDs: Set<UUID>
    ) throws {
        try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
        for conversation in changedConversations {
            try SecureFileStore.save(conversation, to: conversationFileURL(for: conversation.id))
        }
        try saveIndex(
            orderedConversationIDs: orderedConversationIDs,
            currentConversationID: currentConversationID
        )
        for conversationID in deletedConversationIDs {
            try? removeConversationFileIfPresent(id: conversationID)
        }
    }

    private func loadIndexedSnapshot() throws -> Snapshot {
        let index: ConversationIndex
        do {
            index = try SecureFileStore.load(ConversationIndex.self, from: indexURL)
        } catch {
            return try rebuildSnapshotFromConversationFiles(after: error)
        }

        var conversations: [ChatConversation] = []
        conversations.reserveCapacity(index.orderedConversationIDs.count)
        var unavailableConversationCount = 0
        var seenConversationIDs: Set<UUID> = []

        for conversationID in index.orderedConversationIDs {
            guard seenConversationIDs.insert(conversationID).inserted else {
                unavailableConversationCount += 1
                continue
            }
            let fileURL = conversationFileURL(for: conversationID)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                unavailableConversationCount += 1
                continue
            }
            do {
                let conversation = try SecureFileStore.load(ChatConversation.self, from: fileURL)
                guard conversation.id == conversationID else {
                    unavailableConversationCount += 1
                    try? quarantineConversationFile(at: fileURL)
                    continue
                }
                conversations.append(conversation)
            } catch {
                unavailableConversationCount += 1
                try? quarantineConversationFile(at: fileURL)
            }
        }

        let selectedConversationID = index.currentConversationID.flatMap { candidate in
            conversations.contains(where: { $0.id == candidate }) ? candidate : conversations.first?.id
        }

        if unavailableConversationCount > 0 {
            let indexRepairWasSaved = (try? saveIndex(
                conversations: conversations,
                currentConversationID: selectedConversationID
            )) != nil

            return Snapshot(
                conversations: conversations,
                currentConversationID: selectedConversationID,
                recoverySummary: RecoverySummary(
                    unavailableConversationCount: unavailableConversationCount,
                    rebuiltIndex: false,
                    indexRepairWasSaved: indexRepairWasSaved
                )
            )
        }

        return Snapshot(
            conversations: conversations,
            currentConversationID: selectedConversationID,
            recoverySummary: nil
        )
    }

    private func rebuildSnapshotFromConversationFiles(after indexError: Error) throws -> Snapshot {
        let conversationURLs = try conversationFileURLs()
        var conversations: [ChatConversation] = []
        var unavailableConversationCount = 0
        var seenConversationIDs: Set<UUID> = []
        var conversationURLsToQuarantine: [URL] = []

        for fileURL in conversationURLs {
            do {
                let conversation = try SecureFileStore.load(ChatConversation.self, from: fileURL)
                let expectedID = UUID(uuidString: fileURL.deletingPathExtension().lastPathComponent)
                guard expectedID == conversation.id, seenConversationIDs.insert(conversation.id).inserted else {
                    unavailableConversationCount += 1
                    conversationURLsToQuarantine.append(fileURL)
                    continue
                }
                conversations.append(conversation)
            } catch {
                unavailableConversationCount += 1
                conversationURLsToQuarantine.append(fileURL)
            }
        }

        // An unreadable index plus no readable conversation files may indicate a
        // keychain/file-protection problem rather than empty history. Propagate the
        // original error so the manager can avoid overwriting anything this launch.
        guard !conversations.isEmpty else {
            throw indexError
        }

        // At least one successful decrypt confirms this is not a systemic
        // keychain/file-protection failure. It is now safe to quarantine only
        // the individual files that could not be decoded.
        conversationURLsToQuarantine.forEach { fileURL in
            try? quarantineConversationFile(at: fileURL)
        }

        conversations.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.createdAt > rhs.createdAt
        }
        let currentConversationID = conversations.first?.id
        let indexRepairWasSaved = (try? saveIndex(
            conversations: conversations,
            currentConversationID: currentConversationID
        )) != nil

        return Snapshot(
            conversations: conversations,
            currentConversationID: currentConversationID,
            recoverySummary: RecoverySummary(
                unavailableConversationCount: unavailableConversationCount,
                rebuiltIndex: true,
                indexRepairWasSaved: indexRepairWasSaved
            )
        )
    }

    private func saveIndex(
        conversations: [ChatConversation],
        currentConversationID: UUID?
    ) throws {
        try saveIndex(
            orderedConversationIDs: conversations.map(\.id),
            currentConversationID: currentConversationID
        )
    }

    private func saveIndex(
        orderedConversationIDs: [UUID],
        currentConversationID: UUID?
    ) throws {
        let activeIDs = Set(orderedConversationIDs)
        let index = ConversationIndex(
            version: 1,
            currentConversationID: currentConversationID.flatMap { activeIDs.contains($0) ? $0 : nil },
            orderedConversationIDs: orderedConversationIDs
        )
        try SecureFileStore.save(index, to: indexURL)
    }

    private func conversationFileURLs() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: baseDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { url in
            url.pathExtension == "json"
                && url.lastPathComponent != indexURL.lastPathComponent
                && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
        }
    }

    private func quarantineConversationFile(at fileURL: URL) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let quarantineDirectoryURL = baseDirectoryURL.appendingPathComponent("quarantine", isDirectory: true)
        try fileManager.createDirectory(at: quarantineDirectoryURL, withIntermediateDirectories: true)
        let destinationURL = quarantineDirectoryURL.appendingPathComponent(
            "\(fileURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).json"
        )
        try fileManager.moveItem(at: fileURL, to: destinationURL)
    }

    private func conversationFileURL(for conversationID: UUID) -> URL {
        baseDirectoryURL.appendingPathComponent("\(conversationID.uuidString).json")
    }

    private func removeConversationFileIfPresent(id conversationID: UUID) throws {
        try SecureFileStore.removeFileIfPresent(at: conversationFileURL(for: conversationID))
    }
}
