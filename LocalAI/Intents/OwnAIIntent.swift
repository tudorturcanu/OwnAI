//
//  OwnAIIntent.swift
//  LocalAI
//
//  Created by Tudor on 26.06.2026.
//

import AppIntents
import Foundation

/// App Intent that lets users ask Own AI a question via Siri.
///
/// Usage: "Hey Siri, Ask Own AI [question]"
/// The app will open with the question pre-filled and auto-sent in the chat view.
struct AskOwnAIIntent: AppIntent {

    static let title: LocalizedStringResource = "Ask Own AI"
    static let description = IntentDescription(
        "Talk to Own AI models directly using Shortcuts. Ask a question and Own AI will respond in the app.",
        categoryName: "Chat"
    )

    /// Opens the app when the intent runs so the user sees the streamed response.
    static let openAppWhenRun: Bool = true

    @Parameter(
        title: "Question",
        description: "The question or message you want to send to Own AI.",
        requestValueDialog: IntentDialog("What would you like to ask Own AI?")
    )
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Own AI \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Post a notification so ContentView can pick up the query and auto-send it.
        // This works whether the app was backgrounded or freshly launched, because
        // `openAppWhenRun = true` ensures the app is foregrounded before perform() returns.
        NotificationCenter.default.post(
            name: .ownAISiriQuery,
            object: nil,
            userInfo: [OwnAISiriQueryKey.query: query]
        )
        return .result()
    }
}

/// App Intent that answers a question in the background and returns the text
/// to Shortcuts, so Own AI can be chained into workflows (summarize the
/// clipboard, process shared text, feed another action) without opening the
/// app. Uses Apple Intelligence on-device; unavailable devices get a clear
/// error instead of a silent failure.
struct GetOwnAIAnswerIntent: AppIntent {

    static let title: LocalizedStringResource = "Get Answer from Own AI"
    static let description = IntentDescription(
        "Ask Own AI a question and get the answer back as text, without opening the app. Runs on-device with Apple Intelligence.",
        categoryName: "Chat"
    )

    @Parameter(
        title: "Prompt",
        description: "The question or text you want Own AI to respond to.",
        requestValueDialog: IntentDialog("What should Own AI answer?")
    )
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Get Own AI answer for \(\.$prompt)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OwnAIIntentError.emptyPrompt
        }

        let monetization = MonetizationManager()
        guard monetization.hasPro || !monetization.hasReachedFreeDailyMessageLimit else {
            throw OwnAIIntentError.freeLimitReached
        }

        let bridge = AppleFoundationModelBridge()
        do {
            let answer = try await bridge.respondOnce(
                to: trimmed,
                systemPrompt: AssistantMemoryStore.augmentedSystemPrompt(
                    UserDefaults.standard.string(forKey: "systemPrompt") ?? AIResponseDefaults.defaultSystemPrompt
                )
            )
            monetization.registerFreeMessageIfNeeded(for: trimmed)
            return .result(value: answer)
        } catch let error as LLMError {
            throw OwnAIIntentError.generationFailed(message: error.localizedDescription)
        }
    }
}

enum OwnAIIntentError: Error, CustomLocalizedStringResourceConvertible {
    case emptyPrompt
    case freeLimitReached
    case generationFailed(message: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyPrompt:
            return "The prompt is empty. Provide some text for Own AI to answer."
        case .freeLimitReached:
            return "The free plan limit has been reached. Upgrade to Pro in Own AI to keep using Shortcuts."
        case .generationFailed(let message):
            return "Own AI could not answer: \(message)"
        }
    }
}

// MARK: - Notification Name

extension Notification.Name {
    /// Posted by `AskOwnAIIntent` when Siri delivers a query to the app.
    static let ownAISiriQuery = Notification.Name("com.ownai.siriQuery")
}

/// Keys used in the `ownAISiriQuery` notification's `userInfo` dictionary.
enum OwnAISiriQueryKey {
    static let query = "query"
}
