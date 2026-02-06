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
import MLXLMCommon
import MLXLLM
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
    private var mlxSession: ChatSession?
    private var mlxModelID: String?
    private var mlxContainer: ModelContainer?
    #endif
    
    private var generationTask: Task<Void, Never>?
    private var loadTask: Task<Void, Error>?
    private var loadingModelID: String?
    private var loadTaskID: UUID?
    private var currentModel: ModelInfo?
    
    // Throttling
    private var lastUpdate: Date = .distantPast
    private let throttleInterval: TimeInterval = 0.04 // Fast updates (~25fps) for continuous feel
    
    // MARK: - Public Methods
    
    /// Load a specific model
    func loadModel(_ model: ModelInfo) async throws {
        // If same model is already ready, skip
        if state == .ready && currentModel?.id == model.id {
            return
        }
        
        // If a load is in progress, wait for it if it's the same model,
        // otherwise cancel and replace with the new model.
        if let inFlight = loadTask {
            if loadingModelID == model.id {
                try await inFlight.value
                return
            }
            inFlight.cancel()
            loadTask = nil
            loadingModelID = nil
        }
        
        loadingModelID = model.id
        let taskID = UUID()
        loadTaskID = taskID
        let task = Task { [weak self] in
            guard let self = self else { return }
            try await self.performLoad(model)
        }
        loadTask = task
        defer {
            if loadTaskID == taskID {
                loadTask = nil
                loadingModelID = nil
                loadTaskID = nil
            }
        }
        do {
            try await task.value
        } catch is CancellationError {
            // Canceled loads shouldn't surface as errors.
            return
        }
    }
    
    /// Unload the current model
    func unloadModel() {
        appleSession = nil
        #if !targetEnvironment(simulator)
        mlxSession = nil
        mlxModelID = nil
        mlxContainer = nil
        #endif
        loadTask?.cancel()
        loadTask = nil
        loadingModelID = nil
        loadTaskID = nil
        currentModel = nil
        state = .idle
    }
    
    /// Generate a response for the given prompt with streaming and throttling
    func generate(prompt: String, systemPrompt: String = "You are a helpful AI assistant.") async throws {
        if state == .loading, let task = loadTask {
            _ = try? await task.value
        }
        
        switch state {
        case .ready:
            break
        case .error(let message):
            throw LLMError.generationFailed(message)
        default:
            throw LLMError.engineBusy
        }
        
        guard let model = currentModel else {
            throw LLMError.modelNotLoaded
        }
        
        state = .generating
        currentResponse = ""
        streamingMessageID = UUID() // New unique ID for this generation session
        lastUpdate = .distantPast
        print("[LLMEngine] generate start id=\(model.id) engine=\(model.engine.rawValue)")
        
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
                    #if targetEnvironment(simulator)
                    throw LLMError.generationFailed("MLX is not available on the simulator.")
                    #else
                    let effectiveSystemPrompt = systemPrompt == "You are a helpful AI assistant."
                        ? (UserDefaults.standard.string(forKey: "systemPrompt") ?? systemPrompt)
                        : systemPrompt
                    
                    guard let session = await self.mlxSession else {
                        print("[LLMEngine] MLX session missing id=\(model.id)")
                        throw LLMError.modelNotLoaded
                    }
                    
                    let combinedPrompt = """
                    System: \(effectiveSystemPrompt)
                    
                    User: \(prompt)
                    
                    Assistant:
                    """
                    
                    let response = try await session.respond(to: combinedPrompt)
                    await self.updateResponseIfNeeded(response, force: true)
                    #endif
                }
                
                // Finalize state
                await MainActor.run {
                    self.state = .ready
                    self.generationTask = nil
                }
            } catch {
                print("[LLMEngine] generate failed id=\(model.id) error=\(error.localizedDescription)")
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

// MARK: - Private Load

private extension LLMEngine {
    func performLoad(_ model: ModelInfo) async throws {
        if Task.isCancelled {
            state = .idle
            throw CancellationError()
        }
        
        print("[LLMEngine] loadModel start id=\(model.id) engine=\(model.engine.rawValue) state=\(state)")
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
                mlxSession = nil
                mlxModelID = nil
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
            #if targetEnvironment(simulator)
            state = .error(message: "MLX is not available on the simulator.")
            throw LLMError.modelNotAvailable("MLX is not available on the simulator.")
            #else
            print("[LLMEngine] MLX load requested id=\(model.id) downloaded=\(model.downloadState.isDownloaded)")
            guard model.downloadState.isDownloaded else {
                state = .error(message: "Model not downloaded. Go to Settings > Models to download it.")
                throw LLMError.modelNotAvailable("Model not downloaded. Go to Settings > Models to download it.")
            }
            do {
                if mlxModelID != model.id || mlxSession == nil {
                    try Task.checkCancellation()
                    print("[LLMEngine] MLX loading model id=\(model.id)")
                    let container = try await MLXLMCommon.loadModelContainer(
                        id: model.id,
                        progressHandler: { _ in }
                    )
                    try Task.checkCancellation()
                    mlxContainer = container
                    mlxSession = ChatSession(container)
                    mlxModelID = model.id
                    print("[LLMEngine] MLX session ready id=\(model.id)")
                }
                appleSession = nil
                state = .ready
            } catch {
                if error is CancellationError {
                    state = .idle
                    throw error
                }
                print("[LLMEngine] MLX load failed id=\(model.id) error=\(error.localizedDescription)")
                state = .error(message: error.localizedDescription)
                throw LLMError.modelNotAvailable(error.localizedDescription)
            }
            #endif
        }
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
