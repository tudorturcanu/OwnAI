//
//  LLMEngine.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import Foundation
import SwiftUI
import LocalAIKit
import FoundationModels

#if !targetEnvironment(simulator)
import MLXLLM
import MLX
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
    @ObservationIgnored @AppStorage("maxTokens") var maxTokens: Int = 2048
    @ObservationIgnored @AppStorage("lowPowerMode") var lowPowerMode: Bool = false
    @ObservationIgnored @AppStorage("warmStartEnabled") var warmStartEnabled: Bool = true
    
    private typealias AppleSession = FoundationModels.LanguageModelSession
    private typealias LocalSession = AnyLanguageModel.LanguageModelSession
    
    // Apple Foundation
    private var appleSession: AppleSession?
    
    #if !targetEnvironment(simulator)
    // MLX
    private var mlxSession: LocalSession?
    private var mlxModelID: String?
    #endif
    
    private var generationTask: Task<Void, Never>?
    private var loadTask: Task<Void, Error>?
    private var loadingModelID: String?
    private var loadTaskID: UUID?
    private var currentModel: ModelInfo?
    var streamingTokensPerSecond: Double = 0
    private var streamingStartTime: Date?
    
    // Throttling
    private var lastUpdate: Date = .distantPast
    private var throttleInterval: TimeInterval {
        lowPowerMode ? 0.16 : 0.08
    } // Balance smooth streaming with UI responsiveness

    struct GenerationOverrides {
        var temperature: Double?
        var topP: Double?
        var maxTokens: Int?
    }
    
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
        #endif
        loadTask?.cancel()
        loadTask = nil
        loadingModelID = nil
        loadTaskID = nil
        currentModel = nil
        state = .idle
    }
    
    /// Reset conversation session (keeps model loaded).
    /// Call this before generating with a new document so the model
    /// doesn't answer from old conversation context.
    func resetSession() {
        appleSession = nil
        #if !targetEnvironment(simulator)
        // Recreate MLX session with same model to clear conversation history
        if let session = mlxSession, let modelID = mlxModelID {
            let persistentPath = MLXStorage.modelDirectory(for: modelID)
            let mlxModel: MLXLanguageModel
            if FileManager.default.fileExists(atPath: persistentPath.path) {
                mlxModel = MLXLanguageModel(modelId: modelID, directory: persistentPath)
            } else {
                mlxModel = MLXLanguageModel(modelId: modelID)
            }
            mlxSession = LocalSession(
                model: mlxModel,
                instructions: UserDefaults.standard.string(forKey: "systemPrompt") ?? "You are a helpful AI assistant."
            )
            mlxSession?.prewarm()
        }
        #endif
    }
    
    /// Generate a response for the given prompt with streaming and throttling
    func generate(
        prompt: String,
        systemPrompt: String = "You are a helpful AI assistant.",
        overrides: GenerationOverrides? = nil
    ) async throws {
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
        streamingStartTime = Date()
        streamingTokensPerSecond = 0
        print("[LLMEngine] generate start id=\(model.id) engine=\(model.engine.rawValue)")
        
        // Capture state on MainActor
        let currentAppleSession = self.appleSession
        #if !targetEnvironment(simulator)
        let currentMlxSession = self.mlxSession
        #endif
        let currentTopP = overrides?.topP ?? self.topP
        let currentTemperature = overrides?.temperature ?? self.temperature
        let currentMaxTokens = overrides?.maxTokens ?? self.maxTokens
        let effectiveTopP = lowPowerMode ? min(currentTopP, 0.9) : currentTopP
        let effectiveTemperature = lowPowerMode ? min(currentTemperature, 0.6) : currentTemperature
        let effectiveMaxTokens = lowPowerMode ? min(currentMaxTokens, 256) : currentMaxTokens
        
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
                        
                    let session: FoundationModels.LanguageModelSession
                    if let existingSession = currentAppleSession {
                        session = existingSession
                    } else {
                        session = FoundationModels.LanguageModelSession(
                            model: FoundationModels.SystemLanguageModel.default,
                            instructions: effectiveSystemPrompt
                        )
                    }
                    
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
                    guard let session = currentMlxSession else {
                        print("[LLMEngine] MLX session missing id=\(model.id)")
                        throw LLMError.modelNotLoaded
                    }
                    
                    let options = AnyLanguageModel.GenerationOptions(
                        sampling: AnyLanguageModel.GenerationOptions.SamplingMode.random(probabilityThreshold: effectiveTopP),
                        temperature: effectiveTemperature,
                        maximumResponseTokens: effectiveMaxTokens
                    )
                    
                    // Stream MLX output so users see first tokens sooner and keep MLX errors throwable.
                    var lastContent = ""
                    try await withError {
                        let stream = session.streamResponse(to: prompt, options: options)
                        for try await snapshot in stream {
                            if Task.isCancelled { break }
                            lastContent = snapshot.content
                            await self.updateResponseIfNeeded(lastContent, force: false)
                        }
                    }
                    await self.updateResponseIfNeeded(lastContent, force: true)
                    #endif
                }
                
                // Finalize state
                await MainActor.run {
                    self.state = .ready
                    self.generationTask = nil
                    self.streamingStartTime = nil
                    self.streamingTokensPerSecond = 0
                }
            } catch {
                print("[LLMEngine] generate failed id=\(model.id) error=\(error.localizedDescription)")
                await MainActor.run {
                    self.state = .error(message: error.localizedDescription)
                    self.generationTask = nil
                    self.streamingStartTime = nil
                    self.streamingTokensPerSecond = 0
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
                if let start = self.streamingStartTime {
                    let elapsed = max(0.001, now.timeIntervalSince(start))
                    let tokens = Double(self.approximateTokenCount(content))
                    self.streamingTokensPerSecond = tokens / elapsed
                }
            }
        }
    }
    
    /// Stop the current generation
    func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
        state = .ready
        streamingStartTime = nil
        streamingTokensPerSecond = 0
        // Note: The UI layer (ChatView) will handle cleaning up the history message 
        // when currentResponse is cleared or via its own observation.
        currentResponse = "" 
    }
    
    /// Check if selected model is available
    var isAvailable: Bool {
        guard let model = currentModel else {
            // If no model selected, check if Apple Intelligence is available as fallback
            if case .available = FoundationModels.SystemLanguageModel.default.availability {
                return true
            }
            return false
        }
        if model.engine == .appleFoundation {
            if case .available = FoundationModels.SystemLanguageModel.default.availability {
                return true
            }
            return false
        }
        return true
    }
}

// MARK: - Quick Test

extension LLMEngine {
    func runQuickTest(model: ModelInfo) async -> ModelQuickTestResult {
        let start = Date()

        if state == .generating || state == .loading {
            return ModelQuickTestResult(
                modelID: model.id,
                success: false,
                responseSnippet: "Engine busy",
                durationMs: 0,
                timestamp: Date()
            )
        }

        let previousResponse = currentResponse
        do {
            try await loadModel(model)
            try await generate(
                prompt: "Reply with a single word: OK.",
                overrides: GenerationOverrides(temperature: 0.2, topP: 1.0, maxTokens: 16)
            )
            let response = currentResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            let durationMs = Int(Date().timeIntervalSince(start) * 1000.0)
            let success = response.lowercased().contains("ok")
            currentResponse = previousResponse
            return ModelQuickTestResult(
                modelID: model.id,
                success: success,
                responseSnippet: String(response.prefix(60)),
                durationMs: durationMs,
                timestamp: Date()
            )
        } catch {
            currentResponse = previousResponse
            return ModelQuickTestResult(
                modelID: model.id,
                success: false,
                responseSnippet: error.localizedDescription,
                durationMs: Int(Date().timeIntervalSince(start) * 1000.0),
                timestamp: Date()
            )
        }
    }

    func prewarmIfNeeded(model: ModelInfo) async {
        guard warmStartEnabled else { return }
        if currentModel?.id == model.id {
            #if !targetEnvironment(simulator)
            if let session = mlxSession {
                session.prewarm()
                return
            }
            #endif
        }
        try? await loadModel(model)
    }

    private func approximateTokenCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        return trimmed.split { $0.isWhitespace || $0.isNewline }.count
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
            let availability = FoundationModels.SystemLanguageModel.default.availability
            switch availability {
            case .available:
                let instructions = UserDefaults.standard.string(forKey: "systemPrompt") ?? "You are a helpful AI assistant."
                appleSession = AppleSession(
                    model: FoundationModels.SystemLanguageModel.default,
                    instructions: instructions
                )
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
            guard model.downloadState.isDownloaded else {
                let message = "This model isn't downloaded yet. Open Settings > Models to download it."
                state = .error(message: message)
                throw LLMError.modelNotAvailable(message)
            }
            print("[LLMEngine] MLX load requested id=\(model.id)")
            do {
                if mlxModelID != model.id || mlxSession == nil {
                    try Task.checkCancellation()
                    print("[LLMEngine] MLX loading model id=\(model.id)")
                    let persistentPath = MLXStorage.modelDirectory(for: model.id)
                    let mlxModel: MLXLanguageModel
                    if FileManager.default.fileExists(atPath: persistentPath.path) {
                        mlxModel = MLXLanguageModel(modelId: model.id, directory: persistentPath)
                    } else {
                        mlxModel = MLXLanguageModel(modelId: model.id)
                    }
                    mlxSession = LocalSession(
                        model: mlxModel,
                        instructions: UserDefaults.standard.string(forKey: "systemPrompt") ?? "You are a helpful AI assistant."
                    )
                    mlxSession?.prewarm()
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
