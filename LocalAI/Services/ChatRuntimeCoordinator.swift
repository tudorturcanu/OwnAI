import Foundation
import Observation

/// Serializes the user's foreground chat against optional/background work.
/// A lease is reference-counted so retries and automatic recovery can nest
/// without briefly reopening the background-work gate between attempts.
actor ChatWorkloadCoordinator {
    static let shared = ChatWorkloadCoordinator()

    struct Lease: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private var activeLeases: Set<UUID> = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    @discardableResult
    func beginChat() -> Lease {
        let lease = Lease(id: UUID())
        activeLeases.insert(lease.id)
        return lease
    }

    /// Returns true only for the transition back to fully idle.
    @discardableResult
    func endChat(_ lease: Lease) -> Bool {
        guard activeLeases.remove(lease.id) != nil else { return activeLeases.isEmpty }
        guard activeLeases.isEmpty else { return false }
        let waiters = idleWaiters
        idleWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
        return true
    }

    func waitUntilChatIsIdle() async {
        guard !activeLeases.isEmpty else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    var isChatActive: Bool {
        !activeLeases.isEmpty
    }
}

/// The only observable object that changes for each streamed snapshot. It is
/// passed solely to the active assistant bubble, keeping the parent chat view
/// and every completed row outside the token-update invalidation graph.
@MainActor
@Observable
final class ChatStreamingState {
    private(set) var content = ""
    private(set) var assistantID: UUID?

    func begin(assistantID: UUID, initialContent: String) {
        self.assistantID = assistantID
        content = initialContent
    }

    func update(_ content: String, assistantID: UUID) {
        guard self.assistantID == assistantID else { return }
        self.content = content
    }

    func reset(assistantID: UUID? = nil) {
        guard assistantID == nil || self.assistantID == assistantID else { return }
        self.assistantID = nil
        content = ""
    }
}
