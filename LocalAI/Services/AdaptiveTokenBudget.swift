import Foundation

/// Learns, per model, whether recent replies are running into the output
/// token ceiling and nudges the generation budget up when they are.
///
/// A reply that hits its token limit gets cut mid-sentence (see the MLX
/// streaming stop-marker bug this was built alongside). Auto-continue papers
/// over that, but it's better for a chatty model to just get a bigger budget
/// up front. The boost decays back down once a model stops needing it, so it
/// doesn't permanently inflate generation cost for models that rarely do.
enum AdaptiveTokenBudget {
    private static let storageKey = "adaptiveTokenBudgetBoostByModel"
    private static let boostStep = 512
    private static let decayStep = 256
    private static let maxBoost = 2048

    private static func boosts(defaults: UserDefaults) -> [String: Int] {
        defaults.dictionary(forKey: storageKey) as? [String: Int] ?? [:]
    }

    /// Extra output tokens to add on top of the configured/heuristic budget
    /// for this model, learned from how often it has recently run out of room.
    static func boost(for modelID: String, defaults: UserDefaults = .standard) -> Int {
        boosts(defaults: defaults)[modelID] ?? 0
    }

    /// Call once per finished generation pass with whether that pass's raw
    /// output looked like it was cut off by the token ceiling.
    static func recordOutcome(modelID: String, hitLimit: Bool, defaults: UserDefaults = .standard) {
        var current = boosts(defaults: defaults)
        let existing = current[modelID] ?? 0
        let updated = hitLimit
            ? min(maxBoost, existing + boostStep)
            : max(0, existing - decayStep)

        if updated == 0 {
            current.removeValue(forKey: modelID)
        } else {
            current[modelID] = updated
        }
        defaults.set(current, forKey: storageKey)
    }
}
