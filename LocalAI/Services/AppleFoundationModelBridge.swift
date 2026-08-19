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
    // Rough token count of the persistent session's transcript (instructions +
    // every prompt/response so far). Guarded by sessionLock. Used to size each
    // request's response budget against the model's fixed context window.
    private var transcriptTokenEstimate = 0

    private static let contextWindowTokens = 4_096
    private static let responseBudgetCushion = 256
    private static let minimumResponseTokens = 256
    private static let maxContinuationRounds = 2
    private static let transcriptTurnOverheadTokens = 16

    // Rolling memory: once the transcript passes this share of the window,
    // older turns are folded into an on-device summary so long chats keep
    // their context instead of silently dropping it.
    private static let rollingCondenseThresholdTokens = 2_800
    private static let rollingRecentEntriesToKeep = 4
    private static let rollingSummaryResponseTokens = 220
    private static let rollingSummaryInputBudgetTokens = 2_400

    static func adaptiveResponseTokenBudget(
        requested: Int,
        promptTokens: Int,
        historyTokens: Int
    ) -> Int {
        let available = contextWindowTokens - promptTokens - historyTokens - responseBudgetCushion
        return max(minimumResponseTokens, min(requested, available))
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
        return min(1, Double(transcriptTokenEstimate) / Double(Self.contextWindowTokens))
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
                historyTokens: PromptBudgeter.estimatedTokenCount(systemPrompt)
            )
            let response = try await session.respond(
                to: prompt,
                // Greedy decoding is deterministic argmax, so a temperature value
                // here is silently ignored by the framework. Kept explicitly greedy
                // for a stable one-shot Shortcuts answer.
                options: FoundationModels.GenerationOptions(
                    sampling: .greedy,
                    maximumResponseTokens: responseBudget
                )
            )
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
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

            let response = try await session.respond(
                to: userMessage,
                generating: FoundationUserFacts.self,
                // Greedy is deterministic argmax; a temperature would be ignored.
                // Fact extraction must be as reproducible as possible.
                options: FoundationModels.GenerationOptions(
                    sampling: .greedy,
                    maximumResponseTokens: 96
                )
            )
            return response.content.facts
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
        sessionLock.lock()
        sessionStorage = session
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

        let response = try await session.respond(
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

        return sanitizedTitle(response.content.title)
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

        let response = try await session.respond(
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
            title: sanitizedTitle(response.content.title),
            summary: sanitizedSummary(response.content.summary),
            suggestedFollowUps: sanitizedFollowUps(response.content.suggestedFollowUps)
        )
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
        onPartialResponse: @escaping @Sendable (String) async -> Bool
    ) async throws -> String {
        try Task.checkCancellation()

        var session = isolated
            ? FoundationModels.LanguageModelSession(
                model: FoundationModels.SystemLanguageModel.default,
                instructions: systemPrompt
            )
            : resolvedSession(systemPrompt: systemPrompt)

        // Rolling memory: fold older turns into a summary before the window
        // fills, so long chats keep their context instead of dropping it. On
        // any failure the exceededContextWindowSize retry below still applies.
        if !isolated {
            sessionLock.lock()
            let needsCondense = transcriptTokenEstimate >= Self.rollingCondenseThresholdTokens
            sessionLock.unlock()
            if needsCondense,
               let rolled = try? await rollingCondensedSession(
                   from: session,
                   systemPrompt: systemPrompt,
                   conversationID: conversationID
               ) {
                session = rolled.session
                sessionLock.lock()
                sessionStorage = rolled.session
                transcriptTokenEstimate = rolled.transcriptTokens
                sessionLock.unlock()
            }
        }

        // Build prompt: prepend image description if an image is attached
        var enrichedPrompt = prompt
        if let image {
            let description = await ImageAnalysisContextBuilder.context(
                for: image,
                mode: ImageProcessingMode.current
            ) ?? "[Image context unavailable]"
            enrichedPrompt = "[Image context]\n\(description)\n\n[User message]\n" + prompt
        }

        // Size the response cap to what the 4,096-token window can actually
        // hold once the prompt and accumulated transcript are accounted for,
        // instead of letting a fixed cap collide with the window mid-response.
        let promptTokens = PromptBudgeter.estimatedTokenCount(enrichedPrompt)
        let instructionTokens = PromptBudgeter.estimatedTokenCount(systemPrompt)
        sessionLock.lock()
        let historyTokens = isolated
            ? instructionTokens
            : max(transcriptTokenEstimate, instructionTokens)
        sessionLock.unlock()
        let responseBudget = Self.adaptiveResponseTokenBudget(
            requested: maxTokens,
            promptTokens: promptTokens,
            historyTokens: historyTokens
        )

        let options = FoundationModels.GenerationOptions(
            sampling: .random(probabilityThreshold: topP),
            temperature: temperature,
            maximumResponseTokens: responseBudget
        )

        var activeSession = session
        let content: String
        do {
            content = try await streamFromSession(
                activeSession,
                prompt: enrichedPrompt,
                options: options,
                prefix: "",
                onPartialResponse: onPartialResponse
            )
        } catch let error as FoundationModels.LanguageModelSession.GenerationError {
            guard case .exceededContextWindowSize = error else { throw error }
            // The accumulated transcript no longer fits the model's 4,096-token
            // context window, which aborts generation mid-response. Retry once on
            // a fresh session that keeps only the instructions and the most
            // recent completed exchange.
            activeSession = Self.condensedSession(from: activeSession)
            if !isolated {
                sessionLock.lock()
                transcriptTokenEstimate = instructionTokens
                sessionLock.unlock()
            }
            content = try await streamFromSession(
                activeSession,
                prompt: enrichedPrompt,
                options: options,
                prefix: "",
                onPartialResponse: onPartialResponse
            )
        }

        // If generation stopped because it ran into the response cap rather
        // than finishing naturally, ask the same session to pick up where it
        // left off so the visible answer never ends mid-sentence.
        var combined = content
        var latestChunk = content
        var continuationRounds = 0
        while continuationRounds < Self.maxContinuationRounds,
              !Task.isCancelled,
              Self.looksCutOffAtTokenCap(latestChunk, budget: responseBudget) {
            continuationRounds += 1
            let needsSeparator = !(combined.last?.isWhitespace ?? true)
            let prefix = combined + (needsSeparator ? " " : "")
            guard let continuation = try? await streamFromSession(
                activeSession,
                prompt: "Continue your previous answer from exactly where it stopped. Do not repeat text you already wrote.",
                options: options,
                prefix: prefix,
                onPartialResponse: onPartialResponse
            ), !continuation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                break
            }
            combined = prefix + continuation
            latestChunk = continuation
        }

        sessionLock.lock()
        if !isolated {
            sessionStorage = activeSession
            transcriptTokenEstimate += promptTokens
                + PromptBudgeter.estimatedTokenCount(combined)
                + Self.transcriptTurnOverheadTokens
        }
        sessionLock.unlock()

        // Return the full final answer so the caller can force-commit it past
        // its throttled streaming updates; the last streamed chunk would
        // otherwise be dropped, freezing the visible answer mid-sentence.
        return combined
    }

    @available(iOS 26.0, *)
    private func streamFromSession(
        _ session: FoundationModels.LanguageModelSession,
        prompt: String,
        options: FoundationModels.GenerationOptions,
        prefix: String,
        onPartialResponse: @escaping @Sendable (String) async -> Bool
    ) async throws -> String {
        let stream = session.streamResponse(to: prompt, options: options)
        var lastContent = ""

        for try await partialResponse in stream {
            if Task.isCancelled { break }
            lastContent = partialResponse.content
            let shouldStop = await onPartialResponse(prefix + lastContent)
            if shouldStop { break }
        }

        _ = await onPartialResponse(prefix + lastContent)
        return lastContent
    }

    @available(iOS 26.0, *)
    private static func plainText(of entry: FoundationModels.Transcript.Entry) -> (role: String, text: String)? {
        func joinedText(_ segments: [FoundationModels.Transcript.Segment]) -> String {
            segments.compactMap { segment -> String? in
                if case .text(let textSegment) = segment { return textSegment.content }
                return nil
            }.joined(separator: "\n")
        }

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
        conversationID: UUID?
    ) async throws -> (session: FoundationModels.LanguageModelSession, transcriptTokens: Int)? {
        let conversational = session.transcript.filter { entry in
            switch entry {
            case .prompt, .response: return true
            default: return false
            }
        }
        guard conversational.count > Self.rollingRecentEntriesToKeep + 1 else { return nil }

        // Keep whole exchanges: the retained tail must start with a user turn.
        var recent = Array(conversational.suffix(Self.rollingRecentEntriesToKeep))
        while let first = recent.first, Self.plainText(of: first)?.role != "User" {
            recent.removeFirst()
        }
        let older = conversational.dropLast(recent.count)
        guard !older.isEmpty else { return nil }

        let log = older
            .compactMap { Self.plainText(of: $0) }
            .map { "\($0.role): \($0.text)" }
            .joined(separator: "\n\n")
        let clippedLog = PromptBudgeter.snippetSizedText(log, maxTokens: Self.rollingSummaryInputBudgetTokens)

        let summarizer = FoundationModels.LanguageModelSession(
            model: FoundationModels.SystemLanguageModel.default,
            instructions: """
            You summarize conversations so an assistant can continue them later.
            Capture key facts, names, decisions, preferences, and open questions.
            Write plain prose under 150 words. No preamble, no headings.
            """
        )
        let rawSummary = try await summarizer.respond(
            to: clippedLog,
            // Greedy decoding ignores temperature; kept greedy so continuity
            // summaries are deterministic for the same transcript.
            options: FoundationModels.GenerationOptions(
                sampling: .greedy,
                maximumResponseTokens: Self.rollingSummaryResponseTokens
            )
        ).content.trimmingCharacters(in: .whitespacesAndNewlines)
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
