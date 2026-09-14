@preconcurrency import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Mirrors chat titles into the on-device Spotlight index so a conversation can
/// be reopened from Home Screen search. Only the title and a short opening
/// snippet are indexed; the index is private to this app and never leaves the
/// device. Settings > Privacy can switch it off, which drops the index.
enum ConversationSpotlightIndexer {
    nonisolated static let enabledKey = "spotlight.indexConversations"
    private nonisolated static let domainIdentifier = "alice.turcanu.LocalAI.conversations"
    private nonisolated static let indexVersionKey = "spotlight.conversationsIndexVersion"
    private nonisolated static let indexVersion = 1
    private nonisolated static let snippetLimit = 160

    /// Off until the user opts in. Chat titles and opening lines are the most
    /// sensitive thing the app holds, so an upgrade must not start mirroring
    /// them into the system index before the user has seen the toggle.
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Incremental sync, called from the history save path with exactly the
    /// conversations that changed or disappeared.
    nonisolated static func update(changed: [ChatConversation], deletedIDs: Set<UUID>) {
        guard isEnabled, CSSearchableIndex.isIndexingAvailable() else { return }
        let index = CSSearchableIndex.default()

        // Empty drafts are not worth surfacing; make sure no stale entry
        // lingers for a chat whose messages were all deleted either.
        let emptyIDs = changed.filter(\.messages.isEmpty).map(\.id)
        let identifiersToDelete = deletedIDs.union(emptyIDs).map(\.uuidString)
        if !identifiersToDelete.isEmpty {
            index.deleteSearchableItems(withIdentifiers: identifiersToDelete)
        }

        let items = changed.compactMap(searchableItem(for:))
        if !items.isEmpty {
            index.indexSearchableItems(items)
        }
    }

    /// `completion` reports whether the index now reflects `conversations`
    /// (also true when there was nothing to index).
    nonisolated static func reindexAll(
        _ conversations: [ChatConversation],
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        guard CSSearchableIndex.isIndexingAvailable() else {
            completion?(false)
            return
        }
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { deleteError in
            guard isEnabled else {
                completion?(deleteError == nil)
                return
            }
            let items = conversations.compactMap(searchableItem(for:))
            guard !items.isEmpty else {
                completion?(deleteError == nil)
                return
            }
            CSSearchableIndex.default().indexSearchableItems(items) { indexError in
                completion?(deleteError == nil && indexError == nil)
            }
        }
    }

    nonisolated static func removeAll() {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainIdentifier])
    }

    /// One-time catch-up so chats saved before indexing existed show up too.
    nonisolated static func reindexIfOutdated(_ conversations: [ChatConversation]) {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: indexVersionKey) < indexVersion else { return }
        // Nothing to catch up on while indexing is off; the toggle in
        // Settings reindexes from scratch when it is switched on.
        guard isEnabled else {
            defaults.set(indexVersion, forKey: indexVersionKey)
            return
        }
        // The marker is written only once the backfill actually landed, so
        // a failed first attempt is retried on the next launch.
        reindexAll(conversations) { succeeded in
            guard succeeded else { return }
            UserDefaults.standard.set(indexVersion, forKey: indexVersionKey)
        }
    }

    /// The conversation a Spotlight result points at, when the activity is one.
    nonisolated static func conversationID(from activity: NSUserActivity) -> UUID? {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else {
            return nil
        }
        return UUID(uuidString: identifier)
    }

    private nonisolated static func searchableItem(for conversation: ChatConversation) -> CSSearchableItem? {
        guard !conversation.messages.isEmpty else { return nil }

        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = conversation.title
        if let firstUserMessage = conversation.messages.first(where: { $0.role == .user }) {
            let snippet = AssistantOutputSanitizer.sanitize(firstUserMessage.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            attributes.contentDescription = String(snippet.prefix(snippetLimit))
        }
        attributes.contentCreationDate = conversation.createdAt
        attributes.contentModificationDate = conversation.updatedAt

        let item = CSSearchableItem(
            uniqueIdentifier: conversation.id.uuidString,
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
        // Spotlight expires items after a month by default; chats stay until
        // the user deletes them.
        item.expirationDate = .distantFuture
        return item
    }
}
