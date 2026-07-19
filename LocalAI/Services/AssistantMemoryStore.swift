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

    private nonisolated static let factsKey = "assistantMemory.facts"
    private nonisolated static let enabledKey = "assistantMemory.enabled"
    private static let disabledByDefaultResetKey = "assistantMemory.disabledByDefaultReset.v4"

    private(set) var facts: [Fact] = []

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        // The next version starts Memory from a clean, opt-in state for every
        // installation. Once this migration runs, later launches respect the
        // user's toggle choice and do not clear newly approved memories.
        if !defaults.bool(forKey: Self.disabledByDefaultResetKey) {
            defaults.removeObject(forKey: Self.factsKey)
            defaults.set(false, forKey: Self.enabledKey)
            defaults.set(true, forKey: Self.disabledByDefaultResetKey)
        }
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        let storedFacts = defaults.stringArray(forKey: Self.factsKey) ?? []
        facts = storedFacts.map { Fact(id: $0, text: $0) }
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

    // First-person markers across the app's supported languages (en/de/es/fr).
    private nonisolated static let selfReferenceWords: Set<String> = [
        // English
        "i", "i'm", "i've", "i'll", "i'd", "my", "me", "mine", "myself",
        // German
        "ich", "mein", "meine", "meiner", "meinem", "meinen", "mir", "mich",
        // Spanish
        "yo", "mi", "mis", "soy", "estoy", "tengo", "me",
        // French
        "je", "moi", "mon", "ma", "mes", "suis"
    ]

    private nonisolated static let explicitMemoryPrefixes = [
        // English
        "please remember", "remember that", "remember this",
        "can you remember", "could you remember", "don't forget that",
        "do not forget that", "keep in mind that",
        // German
        "bitte merk dir", "merk dir, dass", "erinnere dich daran", "nicht vergessen, dass",
        // Spanish
        "por favor recuerda", "recuerda que", "no olvides que", "acuerdate de que",
        // French
        "souviens-toi que", "souviens toi que", "memorise que", "n'oublie pas que",
        "retiens que"
    ]

    private nonisolated static let coreIdentityPhrases = [
        // English
        "my name is", "i am called", "i'm called",
        // German
        "mein name ist", "ich heisse",
        // Spanish
        "me llamo", "mi nombre es",
        // French
        "je m'appelle", "mon nom est"
    ]

    /// Whether the user is talking about themselves at all.
    nonisolated static func containsSelfReference(_ message: String) -> Bool {
        let words = message.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
        return words.contains { selfReferenceWords.contains($0) || $0.hasPrefix("j'") }
    }

    /// Memory is intentionally opt-in except for a user's name. This keeps
    /// casual preferences and temporary projects from becoming global hidden
    /// context merely because the extractor considers them plausible.
    private nonisolated static func isHighPriorityMemory(_ fact: String) -> Bool {
        let normalized = fact
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return coreIdentityPhrases.contains(where: normalized.contains)
            || explicitMemoryPrefixes.contains(where: trimmed.hasPrefix)
    }

    /// Keeps only exact excerpts from the source message. The extractor is a
    /// generative model and can invent plausible-sounding facts even at low
    /// temperature; requiring verbatim evidence makes that failure safe.
    nonisolated static func verifiedExtractedFacts(
        _ candidates: [String],
        from message: String
    ) -> [String] {
        candidates.compactMap { candidate in
            let fact = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard fact.count >= 6,
                  fact.count <= 160,
                  containsSelfReference(fact),
                  isHighPriorityMemory(fact),
                  message.range(
                    of: fact,
                    options: [.caseInsensitive, .diacriticInsensitive]
                  ) != nil else {
                return nil
            }
            return fact
        }
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
