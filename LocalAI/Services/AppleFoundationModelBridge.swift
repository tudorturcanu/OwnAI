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

private final class AsyncRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    func enter() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isRunning {
                waiters.append(continuation)
                lock.unlock()
            } else {
                isRunning = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func leave() {
        lock.lock()
        if waiters.isEmpty {
            isRunning = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
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
        case .available, .modelNotReady, .appleIntelligenceNotEnabled, .unavailable:
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

    func prewarm(promptPrefix: String? = nil) {
        guard !requestGate.isBusy else {
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

        return try await generateConversationTitleAvailable(
            userMessage: userMessage,
            assistantResponse: assistantResponse
        )
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

        return try await generateConversationInsightsAvailable(
            userMessage: userMessage,
            assistantResponse: assistantResponse
        )
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

        await requestGate.enter()
        defer { requestGate.leave() }
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
            options: FoundationModels.GenerationOptions(
                sampling: .greedy,
                temperature: 0.4,
                maximumResponseTokens: responseBudget
            )
        )
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts durable user facts from a message for cross-chat memory.
    /// Returns an empty array when the message contains nothing worth keeping.
    func extractUserFacts(from userMessage: String) async throws -> [String] {
        guard availability == .available else { return [] }
        guard #available(iOS 26.0, *) else { return [] }

        await requestGate.enter()
        defer { requestGate.leave() }
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
            options: FoundationModels.GenerationOptions(
                sampling: .greedy,
                temperature: 0.1,
                maximumResponseTokens: 96
            )
        )
        return response.content.facts
    }

    func streamResponse(
        to prompt: String,
        systemPrompt: String,
        topP: Double,
        temperature: Double,
        maxTokens: Int,
        isolated: Bool = false,
        image: UIImage? = nil,
        onPartialResponse: @escaping @Sendable (String) async -> Bool
    ) async throws {
        let availability = availability
        guard availability == .available else {
            throw LLMError.modelNotAvailable(availability.engineErrorMessage)
        }

        guard #available(iOS 26.0, *) else {
            throw LLMError.modelNotAvailable(AppleFoundationModelAvailability.unsupportedOS.engineErrorMessage)
        }

        try await streamResponseAvailable(
            to: prompt,
            systemPrompt: systemPrompt,
            topP: topP,
            temperature: temperature,
            maxTokens: maxTokens,
            isolated: isolated,
            image: image,
            onPartialResponse: onPartialResponse
        )
    }

    @available(iOS 26.0, *)
    private func foundationModelAvailability() -> AppleFoundationModelAvailability {
        switch FoundationModels.SystemLanguageModel.default.availability {
        case .available:
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
        await requestGate.enter()
        defer { requestGate.leave() }
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
            options: FoundationModels.GenerationOptions(
                sampling: .greedy,
                temperature: 0.2,
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
        await requestGate.enter()
        defer { requestGate.leave() }
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
            options: FoundationModels.GenerationOptions(
                sampling: .greedy,
                temperature: 0.2,
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
        onPartialResponse: @escaping @Sendable (String) async -> Bool
    ) async throws {
        await requestGate.enter()
        defer { requestGate.leave() }
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
               let rolled = try? await rollingCondensedSession(from: session, systemPrompt: systemPrompt) {
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
        systemPrompt: String
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
        let summary = try await summarizer.respond(
            to: clippedLog,
            options: FoundationModels.GenerationOptions(
                sampling: .greedy,
                temperature: 0.2,
                maximumResponseTokens: Self.rollingSummaryResponseTokens
            )
        ).content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }

        let mergedInstructions = """
        \(systemPrompt)

        Summary of the conversation so far:
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
