//
//  LLMEngine.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import Foundation
import SwiftUI
import FoundationModels

#if !targetEnvironment(simulator)
// import MLXLMCommon
// import MLXLLM
#endif

/// Engine state for LLM operations
enum LLMEngineState: Equatable {
    case idle
    case loading
    case ready
    case generating
    case error(message: String)
}

/// Wrapper around Apple Foundation Models and MLX
@MainActor
@Observable
final class LLMEngine {
    
    // MARK: - Properties
    
    var state: LLMEngineState = .idle
    var currentResponse: String = ""
    var streamingMessageID = UUID()
    
    // Settings
    @ObservationIgnored @AppStorage("temperature") var temperature: Double = 0.7
    @ObservationIgnored @AppStorage("topP") var topP: Double = 1.0
    @ObservationIgnored @AppStorage("maxTokens") var maxTokens: Int = 512
    
    // Apple Foundation
    private var appleSession: LanguageModelSession?
    
    #if !targetEnvironment(simulator)
    // MLX
    // private var mlxContainer: LLMContainer?
    #endif
    
    private var generationTask: Task<Void, Never>?
    private var currentModel: ModelInfo?
    
    // Throttling
    private var lastUpdate: Date = .distantPast
    private let throttleInterval: TimeInterval = 0.04 // Fast updates (~25fps) for continuous feel
    
    // MARK: - Public Methods
    
    /// Load a specific model
    func loadModel(_ model: ModelInfo) async throws {
        // If already loading or same model is ready, skip
        if state == .loading || (state == .ready && currentModel?.id == model.id) {
            return
        }
        
        state = .loading
        currentModel = model
        
        switch model.engine {
        case .appleFoundation:
            // Check availability using SystemLanguageModel
            let availability = SystemLanguageModel.default.availability
            switch availability {
            case .available:
                appleSession = LanguageModelSession()
                #if !targetEnvironment(simulator)
                // mlxContainer = nil
                #endif
                state = .ready
            case .unavailable(let reason):
                let message: String
                switch reason {
                case .deviceNotEligible:
                    message = "This device doesn't support Apple Intelligence."
                case .modelNotReady:
                    message = "Apple Intelligence model is not ready. Please check Settings."
                case .appleIntelligenceNotEnabled:
                    message = "Apple Intelligence is not enabled. Enable it in Settings > Apple Intelligence."
                @unknown default:
                    message = "Apple Intelligence is unavailable."
                }
                state = .error(message: message)
                throw LLMError.modelNotAvailable(message)
            }
            
        case .mlx:
            state = .error(message: "MLX is temporarily disabled")
            throw LLMError.generationFailed("MLX is temporarily disabled")
        }
    }
    
    /// Unload the current model
    func unloadModel() {
        appleSession = nil
        #if !targetEnvironment(simulator)
        // mlxContainer = nil
        #endif
        currentModel = nil
        state = .idle
    }
    
    /// Generate a response for the given prompt with streaming and throttling
    func generate(prompt: String, systemPrompt: String = "You are a helpful AI assistant.") async throws {
        guard state == .ready else {
            throw LLMError.engineBusy
        }
        
        guard let model = currentModel else {
            throw LLMError.modelNotLoaded
        }
        
        state = .generating
        currentResponse = ""
        streamingMessageID = UUID() // New unique ID for this generation session
        lastUpdate = .distantPast
        
        // Run on detached task to avoid blocking UI
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            do {
                if model.engine == .appleFoundation {
                    // Apple Foundation Path
                    
                    // Retrieve system prompt from settings if using default
                    let effectiveSystemPrompt = systemPrompt == "You are a helpful AI assistant." 
                        ? (UserDefaults.standard.string(forKey: "systemPrompt") ?? systemPrompt)
                        : systemPrompt
                        
                    let session: LanguageModelSession
                    if let existingSession = await self.appleSession {
                        session = existingSession
                    } else {
                        session = LanguageModelSession(instructions: effectiveSystemPrompt)
                    }
                    
                    // Note: Apple Foundation models currently have limited configuration 
                    // for temperature/topP via LanguageModelSession in the current API version.
                    // We'll apply them if the API supports it in a future update or via different session params.
                    
                    let stream = session.streamResponse(to: prompt)
                    
                    for try await partialResponse in stream {
                        if Task.isCancelled { break }
                        await self.updateResponseIfNeeded(partialResponse.content, force: false)
                    }
                    
                    await MainActor.run {
                        self.appleSession = session
                    }
                } else if model.engine == .mlx {
                    // MLX disabled
                }
                
                // Finalize state
                await MainActor.run {
                    self.state = .ready
                    self.generationTask = nil
                }
            } catch {
                await MainActor.run {
                    self.state = .error(message: error.localizedDescription)
                    self.generationTask = nil
                }
            }
        }
        
        generationTask = task
        await task.value
    }
    
    /// Throttled UI update
    private func updateResponseIfNeeded(_ content: String, force: Bool) async {
        let now = Date()
        if force || now.timeIntervalSince(lastUpdate) >= throttleInterval {
            await MainActor.run {
                self.currentResponse = content
                self.lastUpdate = now
            }
        }
    }
    
    /// Stop the current generation
    func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
        state = .ready
        // Note: The UI layer (ChatView) will handle cleaning up the history message 
        // when currentResponse is cleared or via its own observation.
        currentResponse = "" 
    }
    
    /// Check if selected model is available
    var isAvailable: Bool {
        guard let model = currentModel else {
            // If no model selected, check if Apple Intelligence is available as fallback
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
            return false
        }
        
        return model.downloadState.isDownloaded
    }
}

// MARK: - Errors

enum LLMError: LocalizedError {
    case modelNotLoaded
    case modelNotAvailable(String)
    case engineBusy
    case generationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No model is loaded. Please select a model first."
        case .modelNotAvailable(let message):
            return message
        case .engineBusy:
            return "The engine is busy. Please wait for the current operation to complete."
        case .generationFailed(let message):
            return "Generation failed: \(message)"
        }
    }
}
