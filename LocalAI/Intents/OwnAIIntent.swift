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

/// App Intent that answers a question and returns the text to Shortcuts, so
/// Own AI can be chained into workflows (summarize the clipboard, process
/// shared text, feed another action). Prefers Apple Intelligence, which runs
/// fully in the background; devices without it fall back to a local MLX model
/// (the bundled one is always present), which needs a brief foreground hop
/// because iOS forbids background GPU work.
struct GetOwnAIAnswerIntent: AppIntent, ForegroundContinuableIntent {

    static let title: LocalizedStringResource = "Get Answer from Own AI"
    static let description = IntentDescription(
        "Ask Own AI a question and get the answer back as text. Runs on-device — in the background with the built-in system model, or by briefly opening the app to use a local model.",
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

        let chatLease = await ChatWorkloadCoordinator.shared.beginChat()
        defer {
            Task {
                _ = await ChatWorkloadCoordinator.shared.endChat(chatLease)
            }
        }

        let bridge = AppleFoundationModelBridge()
        if bridge.availability == .available {
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

        // No Apple Intelligence on this device: answer with a local MLX model.
        // Metal work is forbidden while backgrounded, so ask to hop into the
        // app first, then generate with whatever is already in memory — or the
        // bundled starter model, which ships in every install.
        guard let model = Self.fallbackMLXModel() else {
            throw OwnAIIntentError.noLocalModelAvailable
        }

        try await requestToContinueInForeground(
            IntentDialog("Own AI needs to open briefly to answer with the on-device model.")
        )

        guard let engine = LLMEngine.shared else {
            throw OwnAIIntentError.generationFailed(message: String(localized: "The app is still starting up. Try again."))
        }

        // The continuation can resume before SwiftUI delivers the
        // scene-activation event that re-enables GPU work; give it a moment.
        for _ in 0..<40 where !engine.isForegroundActive {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        do {
            let answer = try await engine.generateIsolatedReply(prompt: trimmed, model: model)
            monetization.registerFreeMessageIfNeeded(for: trimmed)
            return .result(value: answer.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let error as LLMError {
            throw OwnAIIntentError.generationFailed(message: error.localizedDescription)
        }
    }

    /// The model the fallback path answers with: the MLX model that is already
    /// loaded and ready, or the bundled starter model when its weights are
    /// present in the app bundle (they always are; deleting the model in the
    /// catalog only hides it).
    @MainActor
    private static func fallbackMLXModel() -> ModelInfo? {
        if let ready = LLMEngine.shared?.readyMLXModel {
            return ready
        }
        var bundled = ModelInfo.qwen3_0_6b_4bit
        guard MLXStorage.hasValidModelArtifacts(for: bundled.id) else { return nil }
        bundled.downloadState = .downloaded
        return bundled
    }
}

enum OwnAIIntentError: Error, CustomLocalizedStringResourceConvertible {
    case emptyPrompt
    case freeLimitReached
    case noLocalModelAvailable
    case generationFailed(message: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyPrompt:
            return "The prompt is empty. Provide some text for Own AI to answer."
        case .freeLimitReached:
            return "Today's free messages are used up. They reset tomorrow, or upgrade to Pro in Own AI for unlimited use."
        case .noLocalModelAvailable:
            return "No on-device model is available. Open Own AI once to finish setup, then try again."
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
