//
//  ReviewPromptManager.swift
//  LocalAI
//
//  Created by Tudor.
//

import StoreKit
import UIKit

/// Times the App Store review prompt to a moment the user is actually
/// getting value out of the app — after a handful of successful assistant
/// replies — rather than on first launch or after a random delay.
///
/// StoreKit itself throttles `requestReview` to at most a few prompts per
/// year regardless of how often we call it, but we still gate on our own
/// counter so we're not calling it on every single message once the
/// threshold is passed.
enum ReviewPromptManager {
    private static let successfulResponseCountKey = "reviewPrompt.successfulResponseCount"
    private static let lastPromptedVersionKey = "reviewPrompt.lastPromptedVersion"
    private static let responseThreshold = 6

    private static var successfulResponseCount: Int {
        get { UserDefaults.standard.integer(forKey: successfulResponseCountKey) }
        set { UserDefaults.standard.set(newValue, forKey: successfulResponseCountKey) }
    }

    private static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// Call after an assistant reply finishes successfully.
    ///
    /// `isAtUsageLimit` skips the prompt when this reply was the one that used
    /// up the free daily allowance: the next thing the user sees is the
    /// paywall, and asking for a rating at that exact moment invites a bad one.
    /// The counter keeps accruing so the prompt shows on a later, happier reply.
    @MainActor
    static func noteSuccessfulResponse(isAtUsageLimit: Bool = false) {
        successfulResponseCount += 1

        guard successfulResponseCount >= responseThreshold else { return }
        guard !isAtUsageLimit else { return }
        guard UserDefaults.standard.string(forKey: lastPromptedVersionKey) != currentAppVersion else { return }

        guard let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }

        UserDefaults.standard.set(currentAppVersion, forKey: lastPromptedVersionKey)
        successfulResponseCount = 0
        SKStoreReviewController.requestReview(in: windowScene)
    }
}
