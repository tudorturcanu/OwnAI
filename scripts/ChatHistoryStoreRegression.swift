import Foundation

struct ChatConversation: Codable, Equatable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
}

@main
enum ChatHistoryStoreRegression {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-history-regression-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = ChatConversation(
            id: UUID(),
            title: "First",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let second = ChatConversation(
            id: UUID(),
            title: "Second",
            createdAt: Date(timeIntervalSince1970: 3),
            updatedAt: Date(timeIntervalSince1970: 4)
        )
        let store = ChatHistoryStore(
            baseDirectoryURL: root,
            legacyFileURL: root.appendingPathComponent("legacy.json")
        )

        try store.persist(
            conversations: [first, second],
            currentConversationID: first.id,
            changedConversationIDs: nil,
            deletedConversationIDs: []
        )

        var updatedFirst = first
        updatedFirst.title = "First streamed"
        updatedFirst.updatedAt = Date(timeIntervalSince1970: 5)
        try store.persistConversation(
            updatedFirst,
            currentConversationID: second.id,
            orderedConversationIDs: [second.id, first.id]
        )

        var updatedSecond = second
        updatedSecond.title = "Second changed"
        try store.persistChanges(
            changedConversations: [updatedSecond],
            currentConversationID: first.id,
            orderedConversationIDs: [first.id, second.id],
            deletedConversationIDs: []
        )

        let snapshot = try store.loadSnapshot()
        precondition(snapshot.currentConversationID == first.id)
        precondition(snapshot.conversations.map(\.id) == [first.id, second.id])
        precondition(snapshot.conversations.first?.title == "First streamed")
        precondition(snapshot.conversations.last?.title == "Second changed")
        print("Incremental chat-history regression passed")
    }
}
