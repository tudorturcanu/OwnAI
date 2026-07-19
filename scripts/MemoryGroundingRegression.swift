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

        let ordinaryPreference = "I prefer concise answers."
        precondition(
            AssistantMemoryStore.verifiedExtractedFacts(
                [ordinaryPreference],
                from: ordinaryPreference
            ).isEmpty,
            "Ordinary preferences should not be retained automatically"
        )

        let statedIdentity = "My name is Tudor."
        precondition(
            AssistantMemoryStore.verifiedExtractedFacts(
                [statedIdentity],
                from: statedIdentity
            ) == [statedIdentity],
            "A core identity fact should remain eligible"
        )

        let explicitMemory = "Please remember that I prefer concise answers."
        precondition(
            AssistantMemoryStore.verifiedExtractedFacts(
                [explicitMemory],
                from: explicitMemory
            ) == [explicitMemory],
            "An explicit request to remember a fact should remain eligible"
        )

        let mentionsRemembering = "I don't remember my password."
        precondition(
            AssistantMemoryStore.verifiedExtractedFacts(
                [mentionsRemembering],
                from: mentionsRemembering
            ).isEmpty,
            "Mentioning memory is not the same as asking the assistant to remember"
        )

        let recallsSomething = "I remember that I prefer concise answers."
        precondition(
            AssistantMemoryStore.verifiedExtractedFacts(
                [recallsSomething],
                from: recallsSomething
            ).isEmpty,
            "Recalling something is not an instruction to store it"
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
        let purgeKey = "assistantMemory.priorityPolicyPurge.v3"
        defaults.removeObject(forKey: purgeKey)
        defaults.set(["The user prefers Apple Intelligence."], forKey: factsKey)

        let migratedStore = AssistantMemoryStore()
        precondition(
            migratedStore.facts.isEmpty,
            "Memories learned under the broader policy must be purged on upgrade"
        )
        migratedStore.add([statedIdentity])
        precondition(
            AssistantMemoryStore().facts.map(\.text) == [statedIdentity],
            "Facts learned by the verified pipeline must survive later launches"
        )
        defaults.removeObject(forKey: factsKey)
        defaults.removeObject(forKey: purgeKey)
        print("PASS: fabricated memory facts were rejected")
    }
}
