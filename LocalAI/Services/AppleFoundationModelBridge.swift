//
//  AppleFoundationModelBridge.swift
//  LocalAI
//
//  Created by Codex on 16.03.2026.
//

import Foundation
import FoundationModels
import UIKit

enum AppleFoundationModelAvailability: Equatable {
    case available
    case unsupportedOS
    case deviceNotEligible
    case modelNotReady
    case appleIntelligenceNotEnabled
    // The system model is ready but does not support the device's current
    // language. Generating anyway yields degraded, often English, output, so
    // callers should route to a downloaded MLX model instead.
    case unsupportedLocale
    case unavailable

    var engineErrorMessage: String {
        switch self {
        case .available:
            return ""
        case .unsupportedOS, .deviceNotEligible:
            return "This device doesn't support Apple Intelligence."
        case .modelNotReady:
            return "Apple Intelligence model is not ready. Please check Settings."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled. Enable it in Settings > Apple Intelligence."
        case .unsupportedLocale:
            return "Apple Intelligence doesn't support this language yet. Choose a downloaded model in Settings > Models."
        case .unavailable:
            return "Apple Intelligence is unavailable."
        }
    }

    var modelStateMessage: String {
        switch self {
        case .available:
            return ""
        case .unsupportedOS, .deviceNotEligible:
            return "Device not supported"
        case .modelNotReady:
            return "Model not ready"
        case .appleIntelligenceNotEnabled:
            return "Not enabled"
        case .unsupportedLocale:
            return "Language not supported"
        case .unavailable:
            return "Unavailable"
        }
    }
}

struct AppleFoundationConversationInsights: Equatable {
    let title: String
    let summary: String
    let suggestedFollowUps: [String]
}

/// What the system model the OS is serving right now can do. iOS 27's
/// third-generation Apple Foundation Models report which variant is running
/// (AFM 3 Core, or the larger Core Advanced on capable hardware), a context
/// window far beyond iOS 26's 4,096 tokens, and capability flags. Apps cannot
/// request a variant; they can only read it and adapt.
struct AppleFoundationModelProfile: Equatable, Sendable {
    /// The system's display name for the variant, nil before iOS 27.
    let variantName: String?
    let contextSize: Int
    /// Accepts images natively instead of a Vision-derived text description.
    let supportsVision: Bool
    /// Honors a reasoning level and emits reasoning before the answer.
    let supportsReasoning: Bool

    nonisolated static let legacyContextSize = 4_096

    nonisolated static let legacy = AppleFoundationModelProfile(
        variantName: nil,
        contextSize: legacyContextSize,
        supportsVision: false,
        supportsReasoning: false
    )
}

/// The app's thinking toggle mapped onto the framework's reasoning levels.
/// Kept as a plain enum so iOS 26 code paths can carry it without touching
/// iOS 27-only types.
enum AppleFoundationReasoningEffort: Sendable {
    /// The model does not support reasoning; send no context options.
    case unsupported
    /// Thinking off. `.light` is the framework's floor: no level turns
    /// reasoning off entirely, and leaving it nil hands the choice to the
    /// system default, which may reason longer than a phone chat should.
    case minimal
    /// Thinking on.
    case standard

    nonisolated static func resolve(
        profile: AppleFoundationModelProfile,
        thinkingEnabled: Bool
    ) -> AppleFoundationReasoningEffort {
        guard profile.supportsReasoning else { return .unsupported }
        return thinkingEnabled ? .standard : .minimal
    }

    @available(iOS 27.0, *)
    nonisolated var contextOptions: FoundationModels.ContextOptions? {
        switch self {
        case .unsupported: return nil
        case .minimal: return FoundationModels.ContextOptions(reasoningLevel: .light)
        case .standard: return FoundationModels.ContextOptions(reasoningLevel: .moderate)
        }
    }
}

/// Serializes access to the system language model, which accepts one request
/// at a time. Modeled as an actor (the coordinator pattern) so the shared
/// state is protected by actor isolation instead of a hand-rolled lock; the
/// FIFO waiter queue preserves request ordering across suspensions.
private actor AsyncRequestGate {
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Best-effort busy check for callers (e.g. prewarm) that want to bow out
    /// rather than queue behind an in-flight request.
    var isBusy: Bool { isRunning }

    /// Runs `body` with exclusive access to the model, releasing the gate — and
    /// waking the next waiter — even if `body` throws.
    func withExclusiveAccess<T>(_ body: () async throws -> T) async rethrows -> T {
        await enter()
        defer { leave() }
        return try await body()
    }

    private func enter() async {
        if !isRunning {
            isRunning = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func leave() {
        if waiters.isEmpty {
            isRunning = false
        } else {
            // Hand the gate directly to the next waiter: isRunning stays true.
            waiters.removeFirst().resume()
        }
    }
}

@available(iOS 26.0, *)
@Generable(description: "Concise metadata for a chat conversation.")
private struct FoundationConversationInsights {
    @Guide(description: "A natural chat title, 2 to 6 words, without quotation marks or ending punctuation.")
    var title: String

    @Guide(description: "A one-sentence summary of what the user and assistant discussed.")
    var summary: String

    @Guide(description: "Three short follow-up prompts the user may want to ask next.", .count(3))
    var suggestedFollowUps: [String]
}

@available(iOS 26.0, *)
@Generable(description: "A concise title for a chat conversation.")
private struct FoundationConversationTitle {
    @Guide(description: "A natural chat title, 2 to 6 words, without quotation marks or ending punctuation.")
    var title: String
}

@available(iOS 26.0, *)
@Generable(description: "Durable facts about the user worth remembering across conversations.")
private struct FoundationUserFacts {
    @Guide(description: "Exact, verbatim excerpts containing either the user's name or an explicit request such as 'remember this'. Never retain ordinary preferences, projects, relatives, or temporary details. Never paraphrase or add words. Empty when neither condition exists.", .maximumCount(3))
    var facts: [String]
}

final class AppleFoundationModelBridge {
    /// Called with each rolling-condensation summary and the conversation ID
    /// the triggering request was generating for, so the app can persist the
    /// summary on the right conversation (continuity across restarts and chat
    /// switches). The ID rides through the request rather than being captured
    /// in this closure, so overlapping generations cannot cross-attribute a
    /// summary.
    var onRollingSummaryUpdate: (@Sendable (String, UUID?) -> Void)?

    private let sessionLock = NSLock()
    private let requestGate = AsyncRequestGate()
    private var sessionStorage: Any?
    // Token count of the persistent session's transcript (instructions +
    // every prompt/response so far). Guarded by sessionLock. Used to size each
    // request's response budget against the model's context window. An
    // estimate on iOS 26; on iOS 27 it is replaced by the framework's exact
    // usage after every response.
    private var transcriptTokenEstimate = 0
    // The profile of the model the last session was built against. Refreshed
    // at every session build and generation so budgets track the variant the
    // OS actually serves. Guarded by sessionLock.
    private var cachedProfile = AppleFoundationModelProfile.legacy

    private static let responseBudgetCushion = 256
    private static let reasoningTokenAllowance = 1_024
    private static let minimumResponseTokens = 256
    private static let maxContinuationRounds = 2
    private static let transcriptTurnOverheadTokens = 16

    // Rolling memory: once the transcript passes this share of the window,
    // older turns are folded into an on-device summary so long chats keep
    // their context instead of silently dropping it. The shares reproduce the
    // tuned iOS 26 values (2,800 / 2,400 of 4,096) and scale with larger
    // windows.
    private static let rollingCondenseShare = 0.684
    private static let rollingSummaryInputShare = 0.586
    private static let rollingSummaryInputCeilingTokens = 8_000
    private static let rollingSummaryResponseTokens = 220

    static func rollingCondenseThreshold(contextWindow: Int) -> Int {
        Int(Double(contextWindow) * rollingCondenseShare)
    }

    static func rollingSummaryInputBudget(contextWindow: Int) -> Int {
        min(rollingSummaryInputCeilingTokens, Int(Double(contextWindow) * rollingSummaryInputShare))
    }

    /// Transcript entries kept verbatim when condensing. Four on the 4,096
    /// window; a larger window keeps more recent turns word for word. Always
    /// even, so the tail holds whole user/assistant exchanges.
    static func rollingRecentEntriesToKeep(contextWindow: Int) -> Int {
        let scaled = (contextWindow / 1_024) & ~1
        return min(16, max(4, scaled))
    }

    static func adaptiveResponseTokenBudget(
        requested: Int,
        promptTokens: Int,
        historyTokens: Int,
        contextWindow: Int = AppleFoundationModelProfile.legacyContextSize
    ) -> Int {
        let available = contextWindow - promptTokens - historyTokens - responseBudgetCushion
        return max(minimumResponseTokens, min(requested, available))
    }

    /// Reads the running system model's profile. Returns the iOS 26 legacy
    /// profile when the model is unavailable, so budgets never scale up on a
    /// model that is not there.
    nonisolated static func currentProfile() -> AppleFoundationModelProfile {
        guard #available(iOS 26.0, *) else { return .legacy }
        let profile = systemModelProfile()
        logProfileIfChanged(profile)
        return profile
    }

    nonisolated private static let profileLogLock = NSLock()
    nonisolated(unsafe) private static var lastLoggedProfile: AppleFoundationModelProfile?

    /// Records which variant the OS is serving, once per change, so a device
    /// log answers "Core or Core Advanced?" without opening the Models screen.
    nonisolated private static func logProfileIfChanged(_ profile: AppleFoundationModelProfile) {
        profileLogLock.lock()
        let changed = lastLoggedProfile != profile
        if changed { lastLoggedProfile = profile }
        profileLogLock.unlock()
        guard changed else { return }
        PerformanceLogger.safeDiagnostic(
            "Apple model profile: variant=\(profile.variantName ?? "unreported") "
                + "context=\(profile.contextSize) vision=\(profile.supportsVision) "
                + "reasoning=\(profile.supportsReasoning)"
        )
    }

    @available(iOS 26.0, *)
    nonisolated private static func systemModelProfile() -> AppleFoundationModelProfile {
        let model = FoundationModels.SystemLanguageModel.default
        guard model.isAvailable else { return .legacy }
        let reportedContextSize = model.contextSize
        let contextSize = reportedContextSize > 0
            ? reportedContextSize
            : AppleFoundationModelProfile.legacyContextSize
        if #available(iOS 27.0, *) {
            let capabilities = model.capabilities
            return AppleFoundationModelProfile(
                variantName: model.variant.displayName,
                contextSize: contextSize,
                supportsVision: capabilities.contains(.vision),
                supportsReasoning: capabilities.contains(.reasoning)
            )
        }
        return AppleFoundationModelProfile(
            variantName: nil,
            contextSize: contextSize,
            supportsVision: false,
            supportsReasoning: false
        )
    }

    var profile: AppleFoundationModelProfile {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return cachedProfile
    }

    @discardableResult
    private func refreshProfile() -> AppleFoundationModelProfile {
        let profile = Self.currentProfile()
        sessionLock.lock()
        cachedProfile = profile
        sessionLock.unlock()
        return profile
    }

    // A response that landed near the token cap and doesn't end a sentence (or
    // leaves a code fence open) was almost certainly cut by the cap, not
    // finished by the model.
    static func looksCutOffAtTokenCap(_ content: String, budget: Int) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard PromptBudgeter.estimatedTokenCount(trimmed) >= Int(Double(budget) * 0.9) else {
            return false
        }

        let fenceCount = trimmed.components(separatedBy: "```").count - 1
        if fenceCount % 2 != 0 { return true }

        let closingCharacters = CharacterSet(charactersIn: "\"'”’)»]}*_`")
        let core = trimmed.trimmingCharacters(in: closingCharacters)
        guard let last = core.last else { return true }
        if last.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { return false }
        return !".!?…。！？".contains(last)
    }

    var hasConversationContext: Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return sessionStorage != nil
    }

    /// Fraction of the model's fixed context window occupied by the
    /// persistent session's transcript, in 0...1.
    var contextUsageFraction: Double {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard sessionStorage != nil else { return 0 }
        return min(1, Double(transcriptTokenEstimate) / Double(cachedProfile.contextSize))
    }

    var isAvailable: Bool {
        availability == .available
    }

    var isDeviceSupported: Bool {
        switch availability {
        case .deviceNotEligible, .unsupportedOS:
            return false
        case .available, .modelNotReady, .appleIntelligenceNotEnabled, .unsupportedLocale, .unavailable:
            return true
        }
    }

    var availability: AppleFoundationModelAvailability {
        guard #available(iOS 26.0, *) else {
            return .unsupportedOS
        }

        return foundationModelAvailability()
    }

    func resetSession() {
        sessionLock.lock()
        sessionStorage = nil
        transcriptTokenEstimate = 0
        sessionLock.unlock()
    }

    func loadSession(instructions: String) throws {
        let availability = availability
        guard availability == .available else {
            throw LLMError.modelNotAvailable(availability.engineErrorMessage)
        }

        guard #available(iOS 26.0, *) else {
            throw LLMError.modelNotAvailable(AppleFoundationModelAvailability.unsupportedOS.engineErrorMessage)
        }

        storeSession(instructions: instructions)
    }

    func prewarm(promptPrefix: String? = nil) async {
        guard !(await requestGate.isBusy) else {
            return
        }

        let availability = availability
        guard availability == .available else {
            return
        }
        guard #available(iOS 26.0, *) else {
            return
        }

        resolvedSession(systemPrompt: AIResponseDefaults.defaultSystemPrompt)
            .prewarm(promptPrefix: promptPrefix.map(FoundationModels.Prompt.init))
    }

    func generateConversationTitle(
        userMessage: String,
        assistantResponse: String
    ) async throws -> String {
        let availability = availability
        guard availability == .available else {
            throw LLMError.modelNotAvailable(availability.engineErrorMessage)
        }

        guard #available(iOS 26.0, *) else {
            throw LLMError.modelNotAvailable(AppleFoundationModelAvailability.unsupportedOS.engineErrorMessage)
        }

        return try await requestGate.withExclusiveAccess {
            try await self.generateConversationTitleAvailable(
                userMessage: userMessage,
                assistantResponse: assistantResponse
            )
        }
    }

    func generateConversationInsights(
        userMessage: String,
        assistantResponse: String
    ) async throws -> AppleFoundationConversationInsights {
        let availability = availability
        guard availability == .available else {
            throw LLMError.modelNotAvailable(availability.engineErrorMessage)
        }

        guard #available(iOS 26.0, *) else {
            throw LLMError.modelNotAvailable(AppleFoundationModelAvailability.unsupportedOS.engineErrorMessage)
        }

        return try await requestGate.withExclusiveAccess {
            try await self.generateConversationInsightsAvailable(
                userMessage: userMessage,
                assistantResponse: assistantResponse
            )
        }
    }

    /// One-shot answer on an isolated session, for App Intents that return
    /// the response directly to Shortcuts without opening the app.
    func respondOnce(to prompt: String, systemPrompt: String) async throws -> String {
        let availability = availability
        guard availability == .available else {
            throw LLMError.modelNotAvailable(availability.engineErrorMessage)
        }
        guard #available(iOS 26.0, *) else {
            throw LLMError.modelNotAvailable(AppleFoundationModelAvailability.unsupportedOS.engineErrorMessage)
        }

        return try await requestGate.withExclusiveAccess {
            try Task.checkCancellation()

            let session = FoundationModels.LanguageModelSession(
                model: FoundationModels.SystemLanguageModel.default,
                instructions: systemPrompt
            )
            let responseBudget = Self.adaptiveResponseTokenBudget(
                requested: 1_024,
                promptTokens: PromptBudgeter.estimatedTokenCount(prompt),
                historyTokens: PromptBudgeter.estimatedTokenCount(systemPrompt),
                contextWindow: self.refreshProfile().contextSize
            )
            let content = try await Self.respondText(
                session,
                to: prompt,
                // Greedy decoding is deterministic argmax, so a temperature value
                // here is silently ignored by the framework. Kept explicitly greedy
                // for a stable one-shot Shortcuts answer.
                options: FoundationModels.GenerationOptions(
                    sampling: .greedy,
                    maximumResponseTokens: responseBudget
                )
            )
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Extracts durable user facts from a message for cross-chat memory.
    /// Returns an empty array when the message contains nothing worth keeping.
    func extractUserFacts(from userMessage: String) async throws -> [String] {
        guard availability == .available else { return [] }
        guard #available(iOS 26.0, *) else { return [] }

        return try await requestGate.withExclusiveAccess {
            try Task.checkCancellation()

            let session = FoundationModels.LanguageModelSession(
                model: FoundationModels.SystemLanguageModel.default,
                instructions: """
                You extract facts about the user for a personal assistant's long-term memory.
                Memory is deliberately minimal. Keep only the user's explicitly stated name,
                or a fact the user directly asks the assistant to remember. Do not retain
                ordinary preferences, roles, projects, constraints, requests, relatives,
                or temporary details unless the user explicitly says to remember them.
                Copy each fact exactly from the user's message. Never paraphrase, infer, or
                add words that are not present in the message. Return no fact when an exact
                supporting excerpt does not exist.
                """
            )

            let facts = try await Self.respondStructured(
                session,
                to: userMessage,
                generating: FoundationUserFacts.self,
                // Greedy is deterministic argmax; a temperature would be ignored.
                // Fact extraction must be as reproducible as possible.
                options: FoundationModels.GenerationOptions(
                    sampling: .greedy,
                    maximumResponseTokens: 96
                )
            )
            return facts.facts
        }
    }

    func streamResponse(
        to prompt: String,
        systemPrompt: String,
        topP: Double,
        temperature: Double,
        maxTokens: Int,
        isolated: Bool = false,
        image: UIImage? = nil,
        conversationID: UUID? = nil,
        thinkingEnabled: Bool = false,
        onPartialResponse: @escaping @Sendable (String) async -> Bool
    ) async throws -> String {
        let availability = availability
        guard availability == .available else {
            throw LLMError.modelNotAvailable(availability.engineErrorMessage)
        }

        guard #available(iOS 26.0, *) else {
            throw LLMError.modelNotAvailable(AppleFoundationModelAvailability.unsupportedOS.engineErrorMessage)
        }

        return try await requestGate.withExclusiveAccess {
            try await self.streamResponseAvailable(
                to: prompt,
                systemPrompt: systemPrompt,
                topP: topP,
                temperature: temperature,
                maxTokens: maxTokens,
                isolated: isolated,
                image: image,
                conversationID: conversationID,
                thinkingEnabled: thinkingEnabled,
                onPartialResponse: onPartialResponse
            )
        }
    }

    @available(iOS 26.0, *)
    private func foundationModelAvailability() -> AppleFoundationModelAvailability {
        switch FoundationModels.SystemLanguageModel.default.availability {
        case .available:
            // The model can be ready yet not support the device's language.
            // Resolve via supportsLocale rather than raw-matching a language
            // list, so an unsupported locale routes to a fallback model instead
            // of generating degraded output.
            guard FoundationModels.SystemLanguageModel.default.supportsLocale(Locale.current) else {
                return .unsupportedLocale
            }
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .deviceNotEligible
            case .modelNotReady:
                return .modelNotReady
            case .appleIntelligenceNotEnabled:
                return .appleIntelligenceNotEnabled
            @unknown default:
                return .unavailable
            }
        }
    }

    @available(iOS 26.0, *)
    private func storeSession(instructions: String) {
        let session = FoundationModels.LanguageModelSession(
            model: FoundationModels.SystemLanguageModel.default,
            instructions: instructions
        )
        session.prewarm()
        let profile = Self.currentProfile()
        sessionLock.lock()
        sessionStorage = session
        cachedProfile = profile
        transcriptTokenEstimate = PromptBudgeter.estimatedTokenCount(instructions)
        sessionLock.unlock()
    }

    @available(iOS 26.0, *)
    private func generateConversationTitleAvailable(
        userMessage: String,
        assistantResponse: String
    ) async throws -> String {
        try Task.checkCancellation()

        let session = FoundationModels.LanguageModelSession(
            model: FoundationModels.SystemLanguageModel.default,
            instructions: """
            Create a short, useful chat title.
            Return only the requested structured field.
            Avoid generic labels like Question, Chat, Help, or Summary.
            """
        )
        session.prewarm()

        let generated = try await Self.respondStructured(
            session,
            to: """
            User:
            \(userMessage)

            Assistant:
            \(assistantResponse)
            """,
            generating: FoundationConversationTitle.self,
            // Greedy decoding ignores temperature; kept greedy for stable titles.
            options: FoundationModels.GenerationOptions(
                sampling: .greedy,
                maximumResponseTokens: 32
            )
        )

        return sanitizedTitle(generated.title)
    }

    @available(iOS 26.0, *)
    private func generateConversationInsightsAvailable(
        userMessage: String,
        assistantResponse: String
    ) async throws -> AppleFoundationConversationInsights {
        try Task.checkCancellation()

        let session = FoundationModels.LanguageModelSession(
            model: FoundationModels.SystemLanguageModel.default,
            instructions: """
            Create short, useful chat metadata.
            Return only the requested structured fields.
            Avoid generic labels like Question, Chat, Help, or Summary.
            Follow-up prompts should be direct user messages, each under 9 words.
            """
        )
        session.prewarm()

        let generated = try await Self.respondStructured(
            session,
            to: """
            User:
            \(userMessage)

            Assistant:
            \(assistantResponse)
            """,
            generating: FoundationConversationInsights.self,
            // Greedy decoding ignores temperature; kept greedy for stable metadata.
            options: FoundationModels.GenerationOptions(
                sampling: .greedy,
                maximumResponseTokens: 96
            )
        )

        return AppleFoundationConversationInsights(
            title: sanitizedTitle(generated.title),
            summary: sanitizedSummary(generated.summary),
            suggestedFollowUps: sanitizedFollowUps(generated.suggestedFollowUps)
        )
    }

    // Background work (titles, insights, memory, summaries, Shortcuts) runs on
    // every chat. On a reasoning model (AFM 3 Core Advanced) the system default
    // may reason at length first, so these calls pin the lightest level to stay
    // fast. Models without reasoning get no context options: passing a level
    // to them throws.
    @available(iOS 26.0, *)
    private static func respondText(
        _ session: FoundationModels.LanguageModelSession,
        to prompt: String,
        options: FoundationModels.GenerationOptions
    ) async throws -> String {
        if #available(iOS 27.0, *), currentProfile().supportsReasoning {
            do {
                return try await session.respond(
                    to: prompt,
                    options: options,
                    contextOptions: FoundationModels.ContextOptions(reasoningLevel: .light)
                ).content
            } catch let error where isUnsupportedContent(error) {
                // Reasoning was advertised but refused; the transcript was
                // rolled back, so the plain request below is safe.
            }
        }
        return try await session.respond(to: prompt, options: options).content
    }

    @available(iOS 26.0, *)
    private static func respondStructured<Content: FoundationModels.Generable>(
        _ session: FoundationModels.LanguageModelSession,
        to prompt: String,
        generating type: Content.Type,
        options: FoundationModels.GenerationOptions
    ) async throws -> Content {
        if #available(iOS 27.0, *), currentProfile().supportsReasoning {
            // Keep the schema in the prompt: that is the framework's default
            // for structured output, and a custom ContextOptions replaces it.
            do {
                return try await session.respond(
                    to: prompt,
                    generating: type,
                    options: options,
                    contextOptions: FoundationModels.ContextOptions(
                        includeSchemaInPrompt: true,
                        reasoningLevel: .light
                    )
                ).content
            } catch let error where isUnsupportedContent(error) {
                // Reasoning was advertised but refused; retry without it.
            }
        }
        return try await session.respond(to: prompt, generating: type, options: options).content
    }

    @available(iOS 26.0, *)
    private func streamResponseAvailable(
        to prompt: String,
        systemPrompt: String,
        topP: Double,
        temperature: Double,
        maxTokens: Int,
        isolated: Bool,
        image: UIImage?,
        conversationID: UUID?,
        thinkingEnabled: Bool,
        onPartialResponse: @escaping @Sendable (String) async -> Bool
    ) async throws -> String {
        try Task.checkCancellation()

        let profile = refreshProfile()
        let contextWindow = profile.contextSize
        var reasoningEffort = AppleFoundationReasoningEffort.resolve(
            profile: profile,
            thinkingEnabled: thinkingEnabled
        )
        // Reasoning text reaches the chat only when the user asked to see the
        // model think. With thinking off (or on isolated Watch and Shortcuts
        // replies) any light reasoning stays hidden, so no caller ever
        // receives a <think> block it doesn't expect.
        var surfacesReasoning = reasoningEffort == .standard

        var session = isolated
            ? FoundationModels.LanguageModelSession(
                model: FoundationModels.SystemLanguageModel.default,
                instructions: systemPrompt
            )
            : resolvedSession(systemPrompt: systemPrompt)

        // Rolling memory: fold older turns into a summary before the window
        // fills, so long chats keep their context instead of dropping it. On
        // any failure the context-overflow retry below still applies.
        if !isolated {
            sessionLock.lock()
            let needsCondense = transcriptTokenEstimate >= Self.rollingCondenseThreshold(contextWindow: contextWindow)
            sessionLock.unlock()
            if needsCondense,
               let rolled = try? await rollingCondensedSession(
                   from: session,
                   systemPrompt: systemPrompt,
                   conversationID: conversationID,
                   contextWindow: contextWindow
               ) {
                session = rolled.session
                sessionLock.lock()
                sessionStorage = rolled.session
                transcriptTokenEstimate = rolled.transcriptTokens
                sessionLock.unlock()
            }
        }

        // A vision-capable model (AFM 3) sees the image itself. Older models
        // get a Vision-framework text description prepended instead.
        var request: GenerationRequest
        if let image, profile.supportsVision, let native = await Self.nativeImageRequest(prompt: prompt, image: image) {
            request = native
        } else {
            request = await Self.textRequest(prompt: prompt, image: image)
        }

        // Size the response cap to what the context window can actually hold
        // once the prompt and accumulated transcript are accounted for,
        // instead of letting a fixed cap collide with the window mid-response.
        let instructionTokens = PromptBudgeter.estimatedTokenCount(systemPrompt)
        sessionLock.lock()
        let historyTokens = isolated
            ? instructionTokens
            : max(transcriptTokenEstimate, instructionTokens)
        sessionLock.unlock()
        // Reasoning tokens are generated output too, so a thinking request
        // gets an allowance on top of the answer budget; otherwise a long
        // reasoning pass could spend the whole cap before the answer starts.
        // The adaptive budget still clamps it to what the window can hold.
        let responseBudget = Self.adaptiveResponseTokenBudget(
            requested: reasoningEffort == .standard ? maxTokens + Self.reasoningTokenAllowance : maxTokens,
            promptTokens: request.estimatedTokens,
            historyTokens: historyTokens,
            contextWindow: contextWindow
        )

        let options = FoundationModels.GenerationOptions(
            sampling: .random(probabilityThreshold: topP),
            temperature: temperature,
            maximumResponseTokens: responseBudget
        )

        var activeSession = session
        var result: StreamResult
        do {
            result = try await streamFromSession(
                activeSession,
                prompt: request.prompt,
                options: options,
                reasoningEffort: reasoningEffort,
                surfacesReasoning: surfacesReasoning,
                prefix: "",
                reasoningPrefix: "",
                onPartialResponse: onPartialResponse
            )
        } catch let error where Self.isUnsupportedContent(error)
            && (reasoningEffort != .unsupported || request.usesNativeImage) {
            // The model advertised a capability but refused it for this
            // request. The framework rolls the transcript back on this error,
            // so degrade to the plain path and retry instead of failing the
            // chat (which would also switch the user to a fallback model).
            // Reasoning is dropped first; the raw image is swapped for its text
            // description when the image is what was refused.
            activeSession = Self.session(droppingTrailingPromptFrom: activeSession)
            let droppedReasoning = reasoningEffort != .unsupported
            reasoningEffort = .unsupported
            surfacesReasoning = false
            if request.usesNativeImage, !droppedReasoning || Self.isUnsupportedTranscriptContent(error) {
                request = await Self.textRequest(prompt: prompt, image: image)
            }
            do {
                result = try await streamFromSession(
                    activeSession,
                    prompt: request.prompt,
                    options: options,
                    reasoningEffort: reasoningEffort,
                    surfacesReasoning: surfacesReasoning,
                    prefix: "",
                    reasoningPrefix: "",
                    onPartialResponse: onPartialResponse
                )
            } catch let retryError where request.usesNativeImage && Self.isUnsupportedContent(retryError) {
                activeSession = Self.session(droppingTrailingPromptFrom: activeSession)
                request = await Self.textRequest(prompt: prompt, image: image)
                result = try await streamFromSession(
                    activeSession,
                    prompt: request.prompt,
                    options: options,
                    reasoningEffort: reasoningEffort,
                    surfacesReasoning: surfacesReasoning,
                    prefix: "",
                    reasoningPrefix: "",
                    onPartialResponse: onPartialResponse
                )
            }
        } catch let error where Self.isContextOverflow(error) {
            // The accumulated transcript no longer fits the model's context
            // window, which aborts generation mid-response. Retry once on a
            // fresh session that keeps only the instructions and the most
            // recent completed exchange.
            activeSession = Self.condensedSession(from: activeSession)
            if !isolated {
                sessionLock.lock()
                transcriptTokenEstimate = instructionTokens
                sessionLock.unlock()
            }
            result = try await streamFromSession(
                activeSession,
                prompt: request.prompt,
                options: options,
                reasoningEffort: reasoningEffort,
                surfacesReasoning: surfacesReasoning,
                prefix: "",
                reasoningPrefix: "",
                onPartialResponse: onPartialResponse
            )
        }

        // If generation stopped because it ran into the response cap rather
        // than finishing naturally, ask the same session to pick up where it
        // left off so the visible answer never ends mid-sentence.
        let reasoning = result.reasoning
        var combined = result.content
        var latestChunk = result.content
        var exactTranscriptTokens = result.transcriptTokens
        var continuationRounds = 0
        while continuationRounds < Self.maxContinuationRounds,
              !Task.isCancelled,
              Self.looksCutOffAtTokenCap(latestChunk, budget: responseBudget) {
            continuationRounds += 1
            let needsSeparator = !(combined.last?.isWhitespace ?? true)
            let prefix = combined + (needsSeparator ? " " : "")
            guard let continuation = try? await streamFromSession(
                activeSession,
                prompt: FoundationModels.Prompt("Continue your previous answer from exactly where it stopped. Do not repeat text you already wrote."),
                options: options,
                // The reasoning already happened; a continuation only has
                // to finish the text.
                reasoningEffort: reasoningEffort == .unsupported ? .unsupported : .minimal,
                surfacesReasoning: surfacesReasoning,
                prefix: prefix,
                reasoningPrefix: reasoning,
                onPartialResponse: onPartialResponse
            ), !continuation.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                break
            }
            combined = prefix + continuation.content
            latestChunk = continuation.content
            exactTranscriptTokens = continuation.transcriptTokens ?? exactTranscriptTokens
        }

        sessionLock.lock()
        if !isolated {
            sessionStorage = activeSession
            if let exactTranscriptTokens {
                transcriptTokenEstimate = exactTranscriptTokens
            } else {
                transcriptTokenEstimate += request.estimatedTokens
                    + PromptBudgeter.estimatedTokenCount(combined)
                    + Self.transcriptTurnOverheadTokens
            }
        }
        sessionLock.unlock()

        // Return the full final answer so the caller can force-commit it past
        // its throttled streaming updates; the last streamed chunk would
        // otherwise be dropped, freezing the visible answer mid-sentence.
        return Self.displayText(answer: combined, reasoning: surfacesReasoning ? reasoning : "")
    }

    /// A prompt ready to send, with the token estimate used for budgeting.
    @available(iOS 26.0, *)
    private struct GenerationRequest {
        let prompt: FoundationModels.Prompt
        let estimatedTokens: Int
        let usesNativeImage: Bool
    }

    private struct StreamResult {
        let content: String
        let reasoning: String
        /// The session's exact transcript size after this response, from the
        /// framework's usage report. Nil before iOS 27.
        let transcriptTokens: Int?
    }

    @available(iOS 26.0, *)
    private static func textRequest(prompt: String, image: UIImage?) async -> GenerationRequest {
        var text = prompt
        if let image {
            let description = await ImageAnalysisContextBuilder.context(
                for: image,
                mode: ImageProcessingMode.current
            ) ?? "[Image context unavailable]"
            text = "[Image context]\n\(description)\n\n[User message]\n" + prompt
        }
        return GenerationRequest(
            prompt: FoundationModels.Prompt(text),
            estimatedTokens: PromptBudgeter.estimatedTokenCount(text),
            usesNativeImage: false
        )
    }

    @available(iOS 26.0, *)
    private static func nativeImageRequest(prompt: String, image: UIImage) async -> GenerationRequest? {
        guard #available(iOS 27.0, *) else { return nil }
        guard let cgImage = preparedCGImage(from: image, mode: ImageProcessingMode.current) else { return nil }
        let nativePrompt = FoundationModels.Prompt {
            FoundationModels.Attachment<FoundationModels.ImageAttachmentContent>(cgImage)
            prompt
        }
        // Image tokens can't be estimated from text length, so ask the model.
        // On iOS 27.0 tokenCount throws for image prompts; the fallback matches
        // the ~180 tokens AFM 3 Core reports for an 800-pixel image, with
        // headroom for larger ones. The exact usage replaces it after the turn.
        let counted = try? await FoundationModels.SystemLanguageModel.default.tokenCount(for: nativePrompt)
        return GenerationRequest(
            prompt: nativePrompt,
            estimatedTokens: counted ?? PromptBudgeter.estimatedTokenCount(prompt) + 384,
            usesNativeImage: true
        )
    }

    /// Renders the image upright and no larger than the analysis size for the
    /// current processing mode, so a 48 MP photo doesn't ride into the model.
    nonisolated private static func preparedCGImage(from image: UIImage, mode: ImageProcessingMode) -> CGImage? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longestEdge = max(pixelWidth, pixelHeight)
        guard longestEdge > 0 else { return nil }
        let scale = min(1, mode.analysisMaxDimension / longestEdge)
        let targetSize = CGSize(
            width: max(1, floor(pixelWidth * scale)),
            height: max(1, floor(pixelHeight * scale))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }.cgImage
    }

    /// Wraps reasoning in the `<think>` block the chat UI already renders as
    /// a thinking bubble. The block stays open until answer text arrives, so
    /// the bubble shows as still thinking.
    nonisolated private static func displayText(answer: String, reasoning: String) -> String {
        let trimmedReasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReasoning.isEmpty else { return answer }
        guard !answer.isEmpty else { return "<think>\n\(trimmedReasoning)" }
        return "<think>\n\(trimmedReasoning)\n</think>\n\n\(answer)"
    }

    @available(iOS 26.0, *)
    private static func isContextOverflow(_ error: any Error) -> Bool {
        if let generationError = error as? FoundationModels.LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = generationError {
            return true
        }
        if #available(iOS 27.0, *),
           let languageModelError = error as? FoundationModels.LanguageModelError,
           case .contextSizeExceeded = languageModelError {
            return true
        }
        return false
    }

    @available(iOS 26.0, *)
    private static func isUnsupportedContent(_ error: any Error) -> Bool {
        guard #available(iOS 27.0, *),
              let languageModelError = error as? FoundationModels.LanguageModelError else {
            return false
        }
        switch languageModelError {
        case .unsupportedCapability, .unsupportedTranscriptContent:
            return true
        default:
            return false
        }
    }

    @available(iOS 26.0, *)
    private static func isUnsupportedTranscriptContent(_ error: any Error) -> Bool {
        guard #available(iOS 27.0, *),
              let languageModelError = error as? FoundationModels.LanguageModelError,
              case .unsupportedTranscriptContent = languageModelError else {
            return false
        }
        return true
    }

    @available(iOS 26.0, *)
    private static func session(
        droppingTrailingPromptFrom session: FoundationModels.LanguageModelSession
    ) -> FoundationModels.LanguageModelSession {
        var entries = Array(session.transcript)
        if let last = entries.last, case .prompt = last {
            entries.removeLast()
        }
        return FoundationModels.LanguageModelSession(
            model: FoundationModels.SystemLanguageModel.default,
            transcript: FoundationModels.Transcript(entries: entries)
        )
    }

    @available(iOS 26.0, *)
    private func streamFromSession(
        _ session: FoundationModels.LanguageModelSession,
        prompt: FoundationModels.Prompt,
        options: FoundationModels.GenerationOptions,
        reasoningEffort: AppleFoundationReasoningEffort,
        surfacesReasoning: Bool,
        prefix: String,
        reasoningPrefix: String,
        onPartialResponse: @escaping @Sendable (String) async -> Bool
    ) async throws -> StreamResult {
        let stream: FoundationModels.LanguageModelSession.ResponseStream<String>
        if #available(iOS 27.0, *), let contextOptions = reasoningEffort.contextOptions {
            stream = session.streamResponse(to: prompt, options: options, contextOptions: contextOptions)
        } else {
            stream = session.streamResponse(to: prompt, options: options)
        }

        var lastContent = ""
        var lastReasoning = ""
        var transcriptTokens: Int?

        for try await snapshot in stream {
            if Task.isCancelled { break }
            lastContent = snapshot.content
            if #available(iOS 27.0, *) {
                let reasoning = Self.reasoningText(in: snapshot.transcriptEntries)
                if !reasoning.isEmpty { lastReasoning = reasoning }
                let usage = snapshot.usage
                let total = usage.input.totalTokenCount + usage.output.totalTokenCount
                if total > 0 { transcriptTokens = total }
            }
            let visibleReasoning = !surfacesReasoning ? "" : (reasoningPrefix.isEmpty ? lastReasoning : reasoningPrefix)
            let shouldStop = await onPartialResponse(
                Self.displayText(answer: prefix + lastContent, reasoning: visibleReasoning)
            )
            if shouldStop { break }
        }

        let visibleReasoning = !surfacesReasoning ? "" : (reasoningPrefix.isEmpty ? lastReasoning : reasoningPrefix)
        _ = await onPartialResponse(Self.displayText(answer: prefix + lastContent, reasoning: visibleReasoning))
        return StreamResult(content: lastContent, reasoning: lastReasoning, transcriptTokens: transcriptTokens)
    }

    @available(iOS 26.0, *)
    nonisolated private static func joinedText(_ segments: [FoundationModels.Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            if case .text(let textSegment) = segment { return textSegment.content }
            return nil
        }.joined(separator: "\n")
    }

    @available(iOS 27.0, *)
    nonisolated private static func reasoningText(
        in entries: some Sequence<FoundationModels.Transcript.Entry>
    ) -> String {
        entries.compactMap { entry -> String? in
            guard case .reasoning(let reasoning) = entry else { return nil }
            let text = joinedText(reasoning.segments)
            return text.isEmpty ? nil : text
        }.joined(separator: "\n\n")
    }

    @available(iOS 26.0, *)
    private static func plainText(of entry: FoundationModels.Transcript.Entry) -> (role: String, text: String)? {
        switch entry {
        case .prompt(let prompt):
            return ("User", joinedText(prompt.segments))
        case .response(let response):
            return ("Assistant", joinedText(response.segments))
        default:
            return nil
        }
    }

    // Folds turns older than the last `rollingRecentEntriesToKeep` entries
    // into a model-written summary, and rebuilds the session as
    // instructions-plus-summary followed by the recent turns verbatim.
    // Returns nil when there is nothing old enough to fold.
    @available(iOS 26.0, *)
    private func rollingCondensedSession(
        from session: FoundationModels.LanguageModelSession,
        systemPrompt: String,
        conversationID: UUID?,
        contextWindow: Int
    ) async throws -> (session: FoundationModels.LanguageModelSession, transcriptTokens: Int)? {
        let recentEntriesToKeep = Self.rollingRecentEntriesToKeep(contextWindow: contextWindow)
        let conversational = session.transcript.filter { entry in
            switch entry {
            case .prompt, .response: return true
            default: return false
            }
        }
        guard conversational.count > recentEntriesToKeep + 1 else { return nil }

        // Keep whole exchanges: the retained tail must start with a user turn.
        var recent = Array(conversational.suffix(recentEntriesToKeep))
        while let first = recent.first, Self.plainText(of: first)?.role != "User" {
            recent.removeFirst()
        }
        let older = conversational.dropLast(recent.count)
        guard !older.isEmpty else { return nil }

        let log = older
            .compactMap { Self.plainText(of: $0) }
            .map { "\($0.role): \($0.text)" }
            .joined(separator: "\n\n")
        let clippedLog = PromptBudgeter.snippetSizedText(
            log,
            maxTokens: Self.rollingSummaryInputBudget(contextWindow: contextWindow)
        )

        let summarizer = FoundationModels.LanguageModelSession(
            model: FoundationModels.SystemLanguageModel.default,
            instructions: """
            You summarize conversations so an assistant can continue them later.
            Capture key facts, names, decisions, preferences, and open questions.
            Write plain prose under 150 words. No preamble, no headings.
            """
        )
        let rawSummary = try await Self.respondText(
            summarizer,
            to: clippedLog,
            // Greedy decoding ignores temperature; kept greedy so continuity
            // summaries are deterministic for the same transcript.
            options: FoundationModels.GenerationOptions(
                sampling: .greedy,
                maximumResponseTokens: Self.rollingSummaryResponseTokens
            )
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // The summary is derived from conversation content and is about to be
        // promoted into the privileged instructions channel, so strip any
        // sentence that reads as a directive to the assistant before merging.
        let summary = PromptBudgeter.sanitizedContinuitySummary(rawSummary)
        guard !summary.isEmpty else { return nil }
        onRollingSummaryUpdate?(summary, conversationID)

        // Same framing rule as the memory block: presented as silent
        // background, because the small model otherwise recites whatever
        // sits in its instructions back at the user every turn instead of
        // answering the latest message.
        let mergedInstructions = """
        \(systemPrompt)

        Earlier parts of this conversation, summarized for continuity. Use \
        them silently when relevant; never recite or recap this summary. \
        Always respond to the user's latest message:
        \(summary)
        """
        var entries: [FoundationModels.Transcript.Entry] = [
            .instructions(FoundationModels.Transcript.Instructions(
                segments: [.text(FoundationModels.Transcript.TextSegment(content: mergedInstructions))],
                toolDefinitions: []
            ))
        ]
        entries.append(contentsOf: recent)

        let recentTokens = recent
            .compactMap { Self.plainText(of: $0)?.text }
            .reduce(0) { $0 + PromptBudgeter.estimatedTokenCount($1) + Self.transcriptTurnOverheadTokens }
        let transcriptTokens = PromptBudgeter.estimatedTokenCount(mergedInstructions) + recentTokens

        let condensed = FoundationModels.LanguageModelSession(
            model: FoundationModels.SystemLanguageModel.default,
            transcript: FoundationModels.Transcript(entries: entries)
        )
        return (condensed, transcriptTokens)
    }

    @available(iOS 26.0, *)
    private static func condensedSession(
        from session: FoundationModels.LanguageModelSession
    ) -> FoundationModels.LanguageModelSession {
        let entries = session.transcript
        var condensed: [FoundationModels.Transcript.Entry] = []
        if let first = entries.first {
            condensed.append(first)
        }
        // Keep the last completed response rather than the last entry: after a
        // mid-generation failure the trailing entry can be the very prompt that
        // is about to be retried.
        if let lastResponse = entries.last(where: { entry in
            if case .response = entry { return true }
            return false
        }) {
            condensed.append(lastResponse)
        }
        return FoundationModels.LanguageModelSession(
            model: FoundationModels.SystemLanguageModel.default,
            transcript: FoundationModels.Transcript(entries: condensed)
        )
    }

    @available(iOS 26.0, *)
    private func resolvedSession(systemPrompt: String) -> FoundationModels.LanguageModelSession {
        sessionLock.lock()
        let existingSession = sessionStorage as? FoundationModels.LanguageModelSession
        sessionLock.unlock()
        if let existingSession {
            return existingSession
        }
        return FoundationModels.LanguageModelSession(
            model: FoundationModels.SystemLanguageModel.default,
            instructions: systemPrompt
        )
    }

    private nonisolated func sanitizedTitle(_ title: String) -> String {
        let trimmed = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,:;!?"))
        guard !trimmed.isEmpty else { return "" }

        let words = trimmed.split(separator: " ")
        let clipped = words.prefix(6).joined(separator: " ")
        return String(clipped.prefix(60))
    }

    private nonisolated func sanitizedSummary(_ summary: String) -> String {
        String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
    }

    private nonisolated func sanitizedFollowUps(_ suggestions: [String]) -> [String] {
        var seen = Set<String>()
        let cleaned: [String] = suggestions.compactMap { suggestion in
            let trimmed = suggestion
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            guard !trimmed.isEmpty else { return nil }
            let clipped = String(trimmed.prefix(72))
            guard seen.insert(clipped.lowercased()).inserted else { return nil }
            return clipped
        }
        return Array(cleaned.prefix(3))
    }
}
