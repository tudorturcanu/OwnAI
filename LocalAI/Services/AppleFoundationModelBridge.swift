//
//  AppleFoundationModelBridge.swift
//  LocalAI
//
//  Created by Codex on 16.03.2026.
//

import Foundation
import FoundationModels

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

final class AppleFoundationModelBridge {
    private let sessionLock = NSLock()
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
        if #available(iOS 26.0, *) {
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

        return .unsupportedOS
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

        if #available(iOS 26.0, *) {
            let session = FoundationModels.LanguageModelSession(
                model: FoundationModels.SystemLanguageModel.default,
                instructions: instructions
            )
            sessionLock.lock()
            sessionStorage = session
            sessionLock.unlock()
        }
    }

    func streamResponse(
        to prompt: String,
        systemPrompt: String,
        topP: Double,
        temperature: Double,
        maxTokens: Int,
        onPartialResponse: @escaping @Sendable (String) async -> Bool
    ) async throws {
        let availability = availability
        guard availability == .available else {
            throw LLMError.modelNotAvailable(availability.engineErrorMessage)
        }

        guard #available(iOS 26.0, *) else {
            throw LLMError.modelNotAvailable(AppleFoundationModelAvailability.unsupportedOS.engineErrorMessage)
        }

        let session: FoundationModels.LanguageModelSession
        sessionLock.lock()
        let existingSession = sessionStorage as? FoundationModels.LanguageModelSession
        sessionLock.unlock()
        if let existingSession {
            session = existingSession
        } else {
            session = FoundationModels.LanguageModelSession(
                model: FoundationModels.SystemLanguageModel.default,
                instructions: systemPrompt
            )
        }

        let options = FoundationModels.GenerationOptions(
            sampling: .random(probabilityThreshold: topP),
            temperature: temperature,
            maximumResponseTokens: maxTokens
        )

        let stream = session.streamResponse(to: prompt, options: options)
        var lastContent = ""

        for try await partialResponse in stream {
            if Task.isCancelled { break }
            lastContent = partialResponse.content
            let shouldStop = await onPartialResponse(lastContent)
            if shouldStop { break }
        }

        _ = await onPartialResponse(lastContent)
        sessionLock.lock()
        sessionStorage = session
        sessionLock.unlock()
    }
}
