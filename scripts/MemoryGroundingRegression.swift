import Foundation

@main
struct MemoryGroundingRegression {
    @MainActor
    static func main() {
        let source = "My daughter naturally was teeth at 5 years old."
        let candidates = [
            "The user prefers working in the morning.",
            "The user is interested in experimental artistic mediums.",
            "The user prefers Apple Intelligence."
        ]

        let verified = AssistantMemoryStore.verifiedExtractedFacts(
            candidates,
            from: source
        )

        precondition(
            verified.isEmpty,
            "Fabricated facts must not enter memory; got: \(verified)"
        )

        let statedPreference = "I prefer concise answers."
        precondition(
            AssistantMemoryStore.verifiedExtractedFacts(
                [statedPreference],
                from: statedPreference
            ) == [statedPreference],
            "An explicitly stated, verbatim fact should remain eligible"
        )

        let negatedPreference = "I do not want Apple Intelligence."
        precondition(
            AssistantMemoryStore.verifiedExtractedFacts(
                ["Apple Intelligence"],
                from: negatedPreference
            ).isEmpty,
            "A context-free fragment must not be stored as a user fact"
        )

        let defaults = UserDefaults.standard
        let factsKey = "assistantMemory.facts"
        let purgeKey = "assistantMemory.unverifiedFactPurge.v2"
        defaults.removeObject(forKey: purgeKey)
        defaults.set(["The user prefers Apple Intelligence."], forKey: factsKey)

        let migratedStore = AssistantMemoryStore()
        precondition(
            migratedStore.facts.isEmpty,
            "Memories created without source evidence must be purged on upgrade"
        )
        migratedStore.add([statedPreference])
        precondition(
            AssistantMemoryStore().facts.map(\.text) == [statedPreference],
            "Facts learned by the verified pipeline must survive later launches"
        )
        defaults.removeObject(forKey: factsKey)
        defaults.removeObject(forKey: purgeKey)
        print("PASS: fabricated memory facts were rejected")
    }
}
