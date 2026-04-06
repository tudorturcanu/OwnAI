//
//  AppleFoundationModelBridge.swift
//  LocalAI
//
//  Created by Codex on 16.03.2026.
//

import Foundation
import FoundationModels
import UIKit
import Vision

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
        sessionLock.lock()
        sessionStorage = session
        sessionLock.unlock()
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
            let description = await analyzeImage(image)
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

    /// Uses Vision framework to extract text (OCR) and scene labels from an image.
    nonisolated private func analyzeImage(_ image: UIImage) async -> String {
        guard let cgImage = image.cgImage else { return "[Image could not be analyzed]" }

        var parts: [String] = []

        // 1. OCR – extract any visible text
        let ocrRequest = VNRecognizeTextRequest()
        ocrRequest.recognitionLevel = .accurate
        ocrRequest.usesLanguageCorrection = true
        ocrRequest.automaticallyDetectsLanguage = true

        // 2. Classification – identify scene/object labels
        let classifyRequest = VNClassifyImageRequest()

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([ocrRequest, classifyRequest])

        // Collect recognized text
        if let textObservations = ocrRequest.results, !textObservations.isEmpty {
            let lines = textObservations.compactMap { $0.topCandidates(1).first?.string }
            if !lines.isEmpty {
                parts.append("Visible text: " + lines.joined(separator: " | "))
            }
        }

        // Collect top classification labels (confidence >= 0.3)
        if let classifications = classifyRequest.results {
            let confident = classifications
                .filter { $0.confidence >= 0.3 }
                .prefix(8)
                .map { "\($0.identifier) (\(Int($0.confidence * 100))%)" }
            if !confident.isEmpty {
                parts.append("Scene/objects: " + confident.joined(separator: ", "))
            }
        }

        // Image metadata
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        parts.append("Dimensions: \(width)×\(height)px")

        return parts.isEmpty ? "[No description generated]" : parts.joined(separator: "\n")
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
}
