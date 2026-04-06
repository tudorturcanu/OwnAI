//
//  LLMEngine.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import Foundation
import SwiftUI
import LocalAIKit
import UIKit

#if !targetEnvironment(simulator)
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
    @ObservationIgnored @AppStorage("lowPowerMode") var lowPowerMode: Bool = false
    
    private typealias LocalSession = LanguageModelSession
    
    // Apple Foundation
    private let appleFoundationBridge = AppleFoundationModelBridge()
    
    #if !targetEnvironment(simulator)
    // MLX
    private var mlxSession: LocalSession?
    private var mlxModelID: String?
    #endif
    
    private var generationTask: Task<Void, Never>?
    private var isolatedGenerationTask: Task<String, Error>?
    private var loadTask: Task<Void, Error>?
    private var loadingModelID: String?
    private var loadTaskID: UUID?
    private var currentModel: ModelInfo?
    private var isSceneActive = true
    var streamingTokensPerSecond: Double = 0
    private var streamingStartTime: Date?
    
    private var idleTimerTask: Task<Void, Never>?
    private let idleTimeout: TimeInterval = 600 // 10 minutes
    
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

    private struct RepetitionLoop {
        let range: Range<String.Index>
        let repeatedUnit: String
        let repetitions: Int
    }
    
    // MARK: - Public Methods
    
    /// Load a specific model
    func loadModel(_ model: ModelInfo) async throws {
        try ensureGPUWorkAllowed(for: model)

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
            try await MemoryProfiler.measure("LLMEngine.loadModel(\(model.id))") {
                try await task.value
            }
            resetIdleTimer()
        } catch is CancellationError {
            // Canceled loads shouldn't surface as errors.
            return
        }
    }
    
    private func resetIdleTimer() {
        idleTimerTask?.cancel()
        idleTimerTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(idleTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.unloadModelIfIdle()
                }
            } catch {
                // Task cancelled
            }
        }
    }

    private func unloadModelIfIdle() {
        guard state == .ready || state == .idle else { return }
        // We unload even if active if no generation has happened for idleTimeout
        MemoryProfiler.log("LLMEngine", message: "Auto-unloading model due to 10m inactivity.")
        unloadModel()
    }
    
    func unloadModel() {
        MemoryProfiler.log("LLMEngine.unloadModel", message: "BEFORE - state: \(state), model: \(currentModel?.id ?? "none")")
        appleFoundationBridge.resetSession()
        #if !targetEnvironment(simulator)
        mlxSession = nil
        mlxModelID = nil
        #endif
        loadTask?.cancel()
        loadTask = nil
        isolatedGenerationTask?.cancel()
        isolatedGenerationTask = nil
        loadingModelID = nil
        loadTaskID = nil
        currentModel = nil
        state = .idle
        idleTimerTask?.cancel()
        idleTimerTask = nil
        MemoryProfiler.log("LLMEngine.unloadModel", message: "AFTER")
    }
    
    /// Reset conversation session (keeps model loaded).
    /// Call this before generating with a new document so the model
    /// doesn't answer from old conversation context.
    func resetSession() {
        appleFoundationBridge.resetSession()
        #if !targetEnvironment(simulator)
        guard isSceneActive else { return }
        // Recreate MLX session with same model to clear conversation history
        if let session = mlxSession, let modelID = mlxModelID {
            let persistentPath = MLXStorage.modelDirectory(for: modelID)
            let mlxModel: MLXLanguageModel
            if FileManager.default.fileExists(atPath: persistentPath.path) {
                mlxModel = MLXLanguageModel(modelId: modelID, directory: persistentPath)
            } else {
                mlxModel = MLXLanguageModel(modelId: modelID)
            }
            let instructions: Instructions? = mlxSessionInstructions(for: modelID).map {
                Instructions($0)
            }
            mlxSession = LocalSession(model: mlxModel, instructions: instructions)
            mlxSession?.prewarm()
        }
        #endif
    }
    
    /// Generate a response for the given prompt with streaming and throttling
    func generate(
        prompt: String,
        systemPrompt: String = "You are a helpful AI assistant.",
        overrides: GenerationOverrides? = nil,
        image: UIImage? = nil
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

        try ensureGPUWorkAllowed(for: model)
        
        state = .generating
        IdleTimerCoordinator.shared.setReason("llmGenerating", enabled: true)
        currentResponse = ""
        streamingMessageID = UUID() // New unique ID for this generation session
        lastUpdate = .distantPast
        streamingStartTime = Date()
        streamingTokensPerSecond = 0
        print("[LLMEngine] generate start id=\(model.id) engine=\(model.engine.rawValue)")
        
        let usesEphemeralMlxSession = model.engine == .mlx && (
            !mlxModelSupportsSystemRole(modelID: model.id) ||
            (model.supportsVision && image != nil)  // VLM: always fresh context per image turn
        )
        let effectiveSystemPrompt = systemPrompt == "You are a helpful AI assistant."
            ? (UserDefaults.standard.string(forKey: "systemPrompt") ?? systemPrompt)
            : systemPrompt
        let effectiveMlxPrompt = mlxPrompt(
            from: prompt,
            systemPrompt: effectiveSystemPrompt,
            modelID: model.id
        )
        let currentTopP = overrides?.topP ?? self.topP
        let currentTemperature = overrides?.temperature ?? self.temperature
        let currentMaxTokens = overrides?.maxTokens ?? self.maxTokens
        let effectiveTopP = lowPowerMode ? min(currentTopP, 0.9) : currentTopP
        let effectiveTemperature = lowPowerMode ? min(currentTemperature, 0.6) : currentTemperature
        let effectiveMaxTokens = lowPowerMode ? min(currentMaxTokens, 256) : currentMaxTokens
        // Capture state on MainActor
        #if !targetEnvironment(simulator)
        let currentMlxSession = self.mlxSession
        let freshMlxSession = usesEphemeralMlxSession
            ? self.makeFreshMlxSession(modelID: model.id, systemPrompt: effectiveSystemPrompt)
            : nil
        #endif
        
        // Run on detached task to avoid blocking UI
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            do {
                if model.engine == .appleFoundation {
                    // Apple Foundation Path

                    try await self.appleFoundationBridge.streamResponse(
                        to: prompt,
                        systemPrompt: effectiveSystemPrompt,
                        topP: effectiveTopP,
                        temperature: effectiveTemperature,
                        maxTokens: effectiveMaxTokens,
                        image: image
                    ) { [weak self] content in
                        guard let self else { return true }
                        await self.updateResponseIfNeeded(content, force: false)
                        return AssistantOutputSanitizer.containsControlMarker(content)
                    }
                } else if model.engine == .mlx {
                    #if targetEnvironment(simulator)
                    throw LLMError.generationFailed("MLX is not available on the simulator.")
                    #else
                    let session: LocalSession
                    if usesEphemeralMlxSession {
                        guard let freshMlxSession else {
                            throw LLMError.modelNotLoaded
                        }
                        session = freshMlxSession
                    } else if let currentMlxSession {
                        session = currentMlxSession
                    } else {
                        print("[LLMEngine] MLX session missing id=\(model.id)")
                        throw LLMError.modelNotLoaded
                    }
                    
                    let options = GenerationOptions(
                        sampling: GenerationOptions.SamplingMode.random(probabilityThreshold: effectiveTopP),
                        temperature: effectiveTemperature,
                        maximumResponseTokens: effectiveMaxTokens
                    )
                    // Stream MLX output so users see first tokens sooner and keep MLX errors throwable.
                    var lastContent = ""
                    let stream: LocalSession.ResponseStream<String>
                    
                    // For VLM models (e.g. Qwen2-VL), pass the image directly via Transcript.ImageSegment
                    if model.supportsVision, let image {
                        let imageSegment = try Transcript.ImageSegment(image: image, format: .jpeg())
                        stream = session.streamResponse(to: effectiveMlxPrompt, image: imageSegment, options: options)
                    } else {
                        stream = session.streamResponse(to: effectiveMlxPrompt, options: options)
                    }
                    
                    for try await snapshot in stream {
                        if Task.isCancelled { break }
                        lastContent = Self.trimRepeatedLoopIfNeeded(in: snapshot.content)
                        await self.updateResponseIfNeeded(lastContent, force: false)
                        if Self.shouldStopStreaming(content: snapshot.content) {
                            break
                        }
                    }
                    await self.updateResponseIfNeeded(lastContent, force: true)
                    #endif
                }
                
                // Finalize state
                await MainActor.run {
                    self.state = .ready
                    IdleTimerCoordinator.shared.setReason("llmGenerating", enabled: false)
                    self.generationTask = nil
                    self.streamingStartTime = nil
                    self.streamingTokensPerSecond = 0
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.state = .ready
                    IdleTimerCoordinator.shared.setReason("llmGenerating", enabled: false)
                    self.generationTask = nil
                    self.streamingStartTime = nil
                    self.streamingTokensPerSecond = 0
                }
            } catch {
                print("[LLMEngine] generate failed id=\(model.id) error=\(error.localizedDescription)")
                await MainActor.run {
                    self.state = .error(message: error.localizedDescription)
                    IdleTimerCoordinator.shared.setReason("llmGenerating", enabled: false)
                    self.generationTask = nil
                    self.streamingStartTime = nil
                    self.streamingTokensPerSecond = 0
                }
            }
        }
        
        generationTask = task
        await MemoryProfiler.measure("LLMEngine.generate(\(model.id))") {
            await task.value
        }
        resetIdleTimer()
    }

    func generateIsolatedReply(
        prompt: String,
        systemPrompt: String = "You are a helpful AI assistant.",
        model: ModelInfo,
        overrides: GenerationOverrides? = nil
    ) async throws -> String {
        try ensureGPUWorkAllowed(for: model)

        if state == .loading, let task = loadTask {
            _ = try? await task.value
        }

        switch state {
        case .loading, .generating:
            throw LLMError.engineBusy
        default:
            break
        }

        switch model.engine {
        case .appleFoundation:
            let availability = appleFoundationBridge.availability
            guard availability == .available else {
                throw LLMError.modelNotAvailable(availability.engineErrorMessage)
            }
        case .mlx:
            #if targetEnvironment(simulator)
            throw LLMError.modelNotAvailable("MLX is not available on the simulator.")
            #else
            if UIDevice.current.userInterfaceIdiom == .phone && model.requiresLargeDeviceOnPhone {
                throw LLMError.modelNotAvailable("This model requires an iPad Pro or Mac. It exceeds the practical memory budget for iPhone.")
            }
            guard model.downloadState.isDownloaded else {
                throw LLMError.modelNotAvailable("This model isn't downloaded yet. Open Settings > Models to download it.")
            }
            #endif
        }

        let previousState = state
        let previousResponse = currentResponse
        let previousTokensPerSecond = streamingTokensPerSecond
        let previousStreamingStartTime = streamingStartTime

        state = .generating
        IdleTimerCoordinator.shared.setReason("llmGenerating", enabled: true)
        currentResponse = ""
        streamingStartTime = nil
        streamingTokensPerSecond = 0

        defer {
            currentResponse = previousResponse
            streamingStartTime = previousStreamingStartTime
            streamingTokensPerSecond = previousTokensPerSecond
            if state == .generating {
                state = previousState == .loading ? .ready : previousState
            }
            IdleTimerCoordinator.shared.setReason("llmGenerating", enabled: false)
            isolatedGenerationTask = nil
            resetIdleTimer()
        }

        let effectiveSystemPrompt = systemPrompt == "You are a helpful AI assistant."
            ? (UserDefaults.standard.string(forKey: "systemPrompt") ?? systemPrompt)
            : systemPrompt
        let effectiveMlxPrompt = mlxPrompt(
            from: prompt,
            systemPrompt: effectiveSystemPrompt,
            modelID: model.id
        )
        let currentTopP = overrides?.topP ?? self.topP
        let currentTemperature = overrides?.temperature ?? self.temperature
        let currentMaxTokens = overrides?.maxTokens ?? self.maxTokens
        let effectiveTopP = lowPowerMode ? min(currentTopP, 0.9) : currentTopP
        let effectiveTemperature = lowPowerMode ? min(currentTemperature, 0.6) : currentTemperature
        let effectiveMaxTokens = lowPowerMode ? min(currentMaxTokens, 256) : currentMaxTokens
        #if !targetEnvironment(simulator)
        let freshMlxSession = self.makeFreshMlxSession(
            modelID: model.id,
            systemPrompt: effectiveSystemPrompt
        )
        #endif

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return "" }
            var response = ""

            if model.engine == .appleFoundation {
                try await self.appleFoundationBridge.streamResponse(
                    to: prompt,
                    systemPrompt: effectiveSystemPrompt,
                    topP: effectiveTopP,
                    temperature: effectiveTemperature,
                    maxTokens: effectiveMaxTokens,
                    isolated: true
                ) { content in
                    response = content
                    return AssistantOutputSanitizer.containsControlMarker(content)
                }
                return response
            }

            #if targetEnvironment(simulator)
            throw LLMError.generationFailed("MLX is not available on the simulator.")
            #else
            let session = freshMlxSession
            let options = GenerationOptions(
                sampling: GenerationOptions.SamplingMode.random(probabilityThreshold: effectiveTopP),
                temperature: effectiveTemperature,
                maximumResponseTokens: effectiveMaxTokens
            )

            let stream = session.streamResponse(to: effectiveMlxPrompt, options: options)
            for try await snapshot in stream {
                if Task.isCancelled { break }
                response = Self.trimRepeatedLoopIfNeeded(in: snapshot.content)
                if Self.shouldStopStreaming(content: snapshot.content) {
                    break
                }
            }
            return response
            #endif
        }

        isolatedGenerationTask = task

        do {
            let isolatedResponse = try await MemoryProfiler.measure("LLMEngine.generateIsolatedReply(\(model.id))") {
                try await task.value
            }
            state = .ready
            return isolatedResponse
        } catch is CancellationError {
            state = .ready
            throw LLMError.engineBusy
        } catch {
            state = .error(message: error.localizedDescription)
            throw error
        }
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
                    let tokens = Double(self.approximateTokenCount(AssistantOutputSanitizer.sanitize(content)))
                    self.streamingTokensPerSecond = tokens / elapsed
                }
            }
        }
    }
    
    /// Stop the current generation
    func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
        isolatedGenerationTask?.cancel()
        isolatedGenerationTask = nil
        state = .ready
        IdleTimerCoordinator.shared.setReason("llmGenerating", enabled: false)
        streamingStartTime = nil
        streamingTokensPerSecond = 0
        // Note: The UI layer (ChatView) will handle cleaning up the history message 
        // when currentResponse is cleared or via its own observation.
        currentResponse = "" 
        resetIdleTimer()
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        let isActive = phase == .active
        isSceneActive = isActive

        guard !isActive else { return }

        generationTask?.cancel()
        generationTask = nil
        isolatedGenerationTask?.cancel()
        isolatedGenerationTask = nil
        loadTask?.cancel()
        loadTask = nil
        loadingModelID = nil
        loadTaskID = nil
        streamingStartTime = nil
        streamingTokensPerSecond = 0
        currentResponse = ""

        if state == .generating || state == .loading {
            state = hasLoadedSession(for: currentModel) ? .ready : .idle
            IdleTimerCoordinator.shared.setReason("llmGenerating", enabled: false)
        }
    }

    func hasConversationContext(for model: ModelInfo?) -> Bool {
        guard let model, currentModel?.id == model.id else { return false }

        switch model.engine {
        case .appleFoundation:
            return appleFoundationBridge.hasConversationContext
        case .mlx:
            #if targetEnvironment(simulator)
            return false
            #else
            return mlxSession != nil
            #endif
        }
    }
    
    /// Check if selected model is available
    var isAvailable: Bool {
        guard let model = currentModel else {
            // If no model selected, check if Apple Intelligence is available as fallback
            return appleFoundationBridge.isAvailable
        }
        if model.engine == .appleFoundation {
            return appleFoundationBridge.isAvailable
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
            let response = AssistantOutputSanitizer.sanitize(currentResponse)
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard isSceneActive else { return }

        if currentModel?.id == model.id {
            #if !targetEnvironment(simulator)
            if let session = mlxSession {
                guard model.engine != .mlx || isSceneActive else { return }
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

        try ensureGPUWorkAllowed(for: model)
        
        print("[LLMEngine] loadModel start id=\(model.id) engine=\(model.engine.rawValue) state=\(state)")
        state = .loading
        currentModel = model
        
        switch model.engine {
        case .appleFoundation:
            let availability = appleFoundationBridge.availability
            if availability == .available {
                let instructions = UserDefaults.standard.string(forKey: "systemPrompt") ?? "You are a helpful AI assistant."
                try appleFoundationBridge.loadSession(instructions: instructions)
                #if !targetEnvironment(simulator)
                mlxSession = nil
                mlxModelID = nil
                #endif
                state = .ready
            } else {
                let message = availability.engineErrorMessage
                state = .error(message: message)
                throw LLMError.modelNotAvailable(message)
            }
            
        case .mlx:
            #if targetEnvironment(simulator)
            state = .error(message: "MLX is not available on the simulator.")
            throw LLMError.modelNotAvailable("MLX is not available on the simulator.")
            #else
            if UIDevice.current.userInterfaceIdiom == .phone && model.requiresLargeDeviceOnPhone {
                let message = "This model requires an iPad Pro or Mac. It exceeds the practical memory budget for iPhone."
                state = .error(message: message)
                throw LLMError.modelNotAvailable(message)
            }
            guard model.downloadState.isDownloaded else {
                let message = "This model isn't downloaded yet. Open Settings > Models to download it."
                state = .error(message: message)
                throw LLMError.modelNotAvailable(message)
            }
            print("[LLMEngine] MLX load requested id=\(model.id)")
            do {
                if mlxModelID != model.id || mlxSession == nil {
                    try Task.checkCancellation()
                    try ensureGPUWorkAllowed(for: model)
                    print("[LLMEngine] MLX loading model id=\(model.id)")
                    let persistentPath = MLXStorage.modelDirectory(for: model.id)
                    let mlxModel: MLXLanguageModel
                    if FileManager.default.fileExists(atPath: persistentPath.path) {
                        mlxModel = MLXLanguageModel(modelId: model.id, directory: persistentPath)
                    } else {
                        mlxModel = MLXLanguageModel(modelId: model.id)
                    }
                    let instructions: Instructions? = mlxSessionInstructions(for: model.id).map {
                        Instructions($0)
                    }
                    mlxSession = LocalSession(model: mlxModel, instructions: instructions)
                    try ensureGPUWorkAllowed(for: model)
                    mlxSession?.prewarm()
                    mlxModelID = model.id
                    print("[LLMEngine] MLX session ready id=\(model.id)")
                }
                appleFoundationBridge.resetSession()
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

    func ensureGPUWorkAllowed(for model: ModelInfo) throws {
        guard model.engine == .mlx else { return }
        guard isSceneActive else {
            throw LLMError.backgroundGPUWorkNotAllowed
        }
    }

    func hasLoadedSession(for model: ModelInfo?) -> Bool {
        guard let model else { return false }

        switch model.engine {
        case .appleFoundation:
            return appleFoundationBridge.hasConversationContext
        case .mlx:
            #if targetEnvironment(simulator)
            return false
            #else
            return mlxSession != nil
            #endif
        }
    }

    func mlxSessionInstructions(for modelID: String) -> String? {
        guard mlxModelSupportsSystemRole(modelID: modelID) else {
            return nil
        }

        return UserDefaults.standard.string(forKey: "systemPrompt") ?? "You are a helpful AI assistant."
    }

    func mlxPrompt(from prompt: String, systemPrompt: String, modelID: String) -> String {
        guard !mlxModelSupportsSystemRole(modelID: modelID) else {
            return prompt
        }

        let trimmedSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSystemPrompt.isEmpty else {
            return prompt
        }

        return """
        System instructions:
        \(trimmedSystemPrompt)

        User request:
        \(prompt)
        """
    }

    func mlxModelSupportsSystemRole(modelID: String) -> Bool {
        true
    }

    private func makeFreshMlxSession(modelID: String, systemPrompt: String) -> LocalSession {
        let persistentPath = MLXStorage.modelDirectory(for: modelID)
        let mlxModel: MLXLanguageModel
        if FileManager.default.fileExists(atPath: persistentPath.path) {
            mlxModel = MLXLanguageModel(modelId: modelID, directory: persistentPath)
        } else {
            mlxModel = MLXLanguageModel(modelId: modelID)
        }

        let instructions: Instructions? = {
            guard mlxModelSupportsSystemRole(modelID: modelID) else { return nil }
            let trimmed = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : Instructions(trimmed)
        }()

        return LocalSession(model: mlxModel, instructions: instructions)
    }

    private nonisolated static func shouldStopStreaming(content: String) -> Bool {
        if AssistantOutputSanitizer.containsControlMarker(content) {
            return true
        }

        return detectRepeatedLoop(in: content) != nil
    }

    private nonisolated static func trimRepeatedLoopIfNeeded(in content: String) -> String {
        let sanitized = AssistantOutputSanitizer.sanitize(content)
        guard let loop = detectRepeatedLoop(in: sanitized) else {
            return sanitized
        }

        let visiblePrefix = sanitized[..<loop.range.lowerBound]
        let separator = visiblePrefix.last.map(\.isWhitespace) == true ? "" : " "
        return String(visiblePrefix) + separator + loop.repeatedUnit
    }

    private nonisolated static func detectRepeatedLoop(in rawContent: String) -> RepetitionLoop? {
        let trimmed = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 48 else { return nil }

        let candidateLengths = [24, 32, 40, 48, 64, 80, 96, 128]
        for candidateLength in candidateLengths where trimmed.count >= candidateLength * 3 {
            let unitStart = trimmed.index(trimmed.endIndex, offsetBy: -candidateLength)
            let unit = String(trimmed[unitStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard unit.count >= 12 else { continue }

            var scanIndex = trimmed.endIndex
            var repetitions = 0

            while scanIndex > trimmed.startIndex {
                let prefixIndex = trimmed.index(scanIndex, offsetBy: -candidateLength, limitedBy: trimmed.startIndex)
                guard let prefixIndex else { break }

                let candidate = String(trimmed[prefixIndex..<scanIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard candidate == unit else { break }

                repetitions += 1
                scanIndex = prefixIndex
            }

            if repetitions >= 3 {
                return RepetitionLoop(
                    range: scanIndex..<trimmed.endIndex,
                    repeatedUnit: unit,
                    repetitions: repetitions
                )
            }
        }

        let paragraphs = trimmed
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let lastParagraph = paragraphs.last,
           lastParagraph.count >= 12 {
            let repeatedParagraphs = paragraphs.reversed().prefix { $0 == lastParagraph }.count
            if repeatedParagraphs >= 3,
               let paragraphRange = trimmed.range(of: lastParagraph, options: .backwards) {
                let loopStart = trimmed.index(
                    paragraphRange.lowerBound,
                    offsetBy: -((lastParagraph.count + 1) * (repeatedParagraphs - 1)),
                    limitedBy: trimmed.startIndex
                ) ?? trimmed.startIndex
                return RepetitionLoop(
                    range: loopStart..<trimmed.endIndex,
                    repeatedUnit: lastParagraph,
                    repetitions: repeatedParagraphs
                )
            }
        }

        return nil
    }
}


// MARK: - Errors

enum LLMError: LocalizedError {
    case modelNotLoaded
    case modelNotAvailable(String)
    case engineBusy
    case generationFailed(String)
    case backgroundGPUWorkNotAllowed
    
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
        case .backgroundGPUWorkNotAllowed:
            return "Bring the app to the foreground before using a local MLX model."
        }
    }
}
