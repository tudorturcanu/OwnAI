import Foundation
import SwiftUI

/// Durable facts about the user, remembered across conversations. Everything
/// stays in UserDefaults on this device — extraction runs on-device and the
/// user can view, delete, or disable it all in Settings.
@MainActor
@Observable
final class AssistantMemoryStore {
    struct Fact: Identifiable, Equatable {
        let id: String
        let text: String
    }

    static let maxFacts = 20

    private static let factsKey = "assistantMemory.facts"
    private static let enabledKey = "assistantMemory.enabled"

    private(set) var facts: [Fact] = []

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Self.enabledKey) == nil
            ? true
            : defaults.bool(forKey: Self.enabledKey)
        facts = (defaults.stringArray(forKey: Self.factsKey) ?? []).map { Fact(id: $0, text: $0) }
    }

    func add(_ newFacts: [String]) {
        let cleaned = newFacts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 6 && $0.count <= 160 }
        guard !cleaned.isEmpty else { return }

        var texts = facts.map(\.text)
        for fact in cleaned where !texts.contains(where: { $0.caseInsensitiveCompare(fact) == .orderedSame }) {
            texts.append(fact)
        }
        // Oldest facts fall off first once the cap is reached.
        if texts.count > Self.maxFacts {
            texts.removeFirst(texts.count - Self.maxFacts)
        }
        persist(texts)
    }

    func remove(_ fact: Fact) {
        persist(facts.map(\.text).filter { $0 != fact.text })
    }

    func clear() {
        persist([])
    }

    private func persist(_ texts: [String]) {
        UserDefaults.standard.set(texts, forKey: Self.factsKey)
        facts = texts.map { Fact(id: $0, text: $0) }
    }

    /// Appends the remembered facts to a system prompt. Reads UserDefaults
    /// directly so engine code can call it from any context without holding
    /// a reference to the store.
    nonisolated static func augmentedSystemPrompt(_ base: String) -> String {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
        guard enabled,
              let texts = defaults.stringArray(forKey: factsKey),
              !texts.isEmpty else {
            return base
        }
        let block = texts.suffix(maxFacts).map { "- \($0)" }.joined(separator: "\n")
        return base + "\n\nThings to remember about the user (from earlier conversations):\n" + block
    }
}
