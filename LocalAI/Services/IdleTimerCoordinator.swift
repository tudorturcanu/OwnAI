import UIKit

/// Coordinates `UIApplication.shared.isIdleTimerDisabled` across multiple async tasks
/// (downloads, LLM generation, and Kokoro speech) without clobbering each other.
@MainActor
final class IdleTimerCoordinator {
    static let shared = IdleTimerCoordinator()
    
    private var reasonEnabled: [String: Bool] = [:]
    
    private init() {}
    
    func setReason(_ reason: String, enabled: Bool) {
        reasonEnabled[reason] = enabled
        apply()
    }
    
    private func apply() {
        let shouldKeepAwake = reasonEnabled.values.contains(true)
        UIApplication.shared.isIdleTimerDisabled = shouldKeepAwake
    }
}

