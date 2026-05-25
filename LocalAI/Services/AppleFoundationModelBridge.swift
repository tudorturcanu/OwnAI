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

final class AppleFoundationModelBridge {
    private let sessionLock = NSLock()
    private let requestGate = AsyncRequestGate()
    private var sessionStorage: Any?

    var hasConversationContext: Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return sessionStorage != nil
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
            print("[AppleFoundationModelBridge] prewarm skipped; model request in flight")
            return
        }

        let availability = availability
        guard availability == .available else {
            print("[AppleFoundationModelBridge] prewarm skipped availability=\(availability)")
            return
        }
        guard #available(iOS 26.0, *) else {
            print("[AppleFoundationModelBridge] prewarm skipped unsupported OS")
            return
        }

        print("[AppleFoundationModelBridge] prewarm start hasPromptPrefix=\(promptPrefix != nil)")
        resolvedSession(systemPrompt: AIResponseDefaults.defaultSystemPrompt)
            .prewarm(promptPrefix: promptPrefix.map(FoundationModels.Prompt.init))
        print("[AppleFoundationModelBridge] prewarm requested")
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
        print("[AppleFoundationModelBridge] storeSession prewarm start")
        session.prewarm()
        print("[AppleFoundationModelBridge] storeSession prewarm requested")
        sessionLock.lock()
        sessionStorage = session
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

        let session = isolated
            ? FoundationModels.LanguageModelSession(
                model: FoundationModels.SystemLanguageModel.default,
                instructions: systemPrompt
            )
            : resolvedSession(systemPrompt: systemPrompt)

        let options = FoundationModels.GenerationOptions(
            sampling: .random(probabilityThreshold: topP),
            temperature: temperature,
            maximumResponseTokens: maxTokens
        )

        // Build prompt: prepend image description if an image is attached
        var enrichedPrompt = prompt
        if let image {
            let description = await ImageAnalysisContextBuilder.context(
                for: image,
                mode: ImageProcessingMode.current
            ) ?? "[Image context unavailable]"
            enrichedPrompt = "[Image context]\n\(description)\n\n[User message]\n" + prompt
        }

        let stream = session.streamResponse(to: enrichedPrompt, options: options)
        var lastContent = ""

        for try await partialResponse in stream {
            if Task.isCancelled { break }
            lastContent = partialResponse.content
            let shouldStop = await onPartialResponse(lastContent)
            if shouldStop { break }
        }

        _ = await onPartialResponse(lastContent)
        if !isolated {
            sessionLock.lock()
            sessionStorage = session
            sessionLock.unlock()
        }
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
