//
//  LLMEngine.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import CryptoKit
import Foundation
import SwiftUI
import UIKit
#if !targetEnvironment(simulator)
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers
#endif

/// Engine state for LLM operations
enum LLMEngineState: Equatable {
    case idle
    case loading
    case ready
    case generating
    case error(message: String)
}

#if !targetEnvironment(simulator)
private struct LocalAITokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return LocalAITokenizer(upstream: upstream)
    }
}

private struct LocalAITokenizer: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
#endif

/// Wrapper around Apple Foundation Models and MLX
@MainActor
@Observable
final class LLMEngine {
    
    // MARK: - Properties
    
    var state: LLMEngineState = .idle
    var currentResponse: String = ""
    var streamingMessageID = UUID()
    var isPrewarming = false
    
    // Settings
    @ObservationIgnored @AppStorage("temperature") var temperature: Double = 0.7
    @ObservationIgnored @AppStorage("topP") var topP: Double = 1.0
    @ObservationIgnored @AppStorage("maxTokens") var maxTokens: Int = AIResponseDefaults.maxTokens
    @ObservationIgnored @AppStorage("lowPowerMode") var lowPowerMode: Bool = false
    
    // Apple Foundation
    private let appleFoundationBridge = AppleFoundationModelBridge()
    
    #if !targetEnvironment(simulator)
    // MLX
    private var mlxSession: ChatSession?
    private var mlxModelContainer: ModelContainer?
    private var mlxModelID: String?
    #endif
    
    private var generationTask: Task<Void, Never>?
    private var isolatedGenerationTask: Task<String, Error>?
    private var loadTask: Task<Void, Error>?
    private var loadingModelID: String?
    private var loadTaskID: UUID?
    private var prewarmTaskID: UUID?
    private var currentModel: ModelInfo?
    private var lastLoadedAppleFoundationInstructions: String?
    private var isSceneActive = true
    var streamingTokensPerSecond: Double = 0
    private var streamingStartTime: Date?
    private var lastMlxRequestFingerprint: MlxRequestFingerprint?
    private var lastMlxGenerationMetrics: MlxGenerationMetrics?
    
    private var idleTimerTask: Task<Void, Never>?
    private let idleTimeout: TimeInterval = 600 // 10 minutes
    
    // Throttling
    private var lastUpdate: Date = .distantPast
    private var adaptiveThrottleInterval: TimeInterval = 0.08
    private var estimatedTokenCount: Int = 0
    private var lastTokenCountTextLength: Int = 0
    private var lastStreamingUpdateLength: Int = 0
    private var throttleInterval: TimeInterval {
        max(lowPowerMode ? 0.16 : 0.08, adaptiveThrottleInterval)
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

    private struct MlxRequestFingerprint: Equatable, Sendable {
        let requestKey: String
        let reusablePrefixKey: String
        let imageKey: String?
        let estimatedPromptTokens: Int
    }

    private struct MlxGenerationMetrics: Sendable {
        let requestKey: String
        let reusablePrefixKey: String
        let imageKey: String?
        let cacheHit: Bool
        let cachedPromptTokens: Int
        let sessionKind: String
        let estimatedInputTokens: Int
        let estimatedOutputTokens: Int
        let firstTokenLatency: TimeInterval?
        let wallTime: TimeInterval
        let residentMemoryDelta: Int64
    }

    var latestMlxPerformanceSummary: String? {
        guard let metrics = lastMlxGenerationMetrics else { return nil }
        let firstToken = metrics.firstTokenLatency.map { String(format: "%.2fs", $0) } ?? "none"
        return "cache=\(metrics.cacheHit ? "hit" : "miss") input≈\(metrics.estimatedInputTokens) first=\(firstToken) wall=\(String(format: "%.2fs", metrics.wallTime))"
    }
    
    // MARK: - Public Methods
    
    /// Load a specific model
    func loadModel(_ model: ModelInfo) async throws {
        try ensureGPUWorkAllowed(for: model)

        // If same model is already ready, skip -- unless it's Apple Foundation and the
        // system prompt changed since the session was built, since that session's
        // instructions are otherwise stuck until the model is reloaded.
        if state == .ready && currentModel?.id == model.id {
            if model.engine != .appleFoundation {
                return
            }
            let instructions = UserDefaults.standard.string(forKey: "systemPrompt") ?? AIResponseDefaults.defaultSystemPrompt
            if instructions == lastLoadedAppleFoundationInstructions {
                return
            }
        }
        
        let previousTask = loadTask
        
        // If a load is in progress, wait for it if it's the same model,
        // otherwise cancel and wait for it to finish before starting the new model.
        if let inFlight = previousTask {
            if loadingModelID == model.id {
                try await inFlight.value
                return
            }
            inFlight.cancel()
        }
        
        loadingModelID = model.id
        let taskID = UUID()
        loadTaskID = taskID
        let task = Task { [weak self] in
            // Wait for any previous load to finish/cancel before starting to prevent overlapping memory allocations
            let _ = try? await previousTask?.value
            try Task.checkCancellation()
            
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
                await MainActor.run { [weak self] in
                    self?.unloadModelIfIdle()
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
        mlxModelContainer = nil
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
        if let container = mlxModelContainer, let modelID = mlxModelID {
            mlxSession = nil
            MLX.GPU.clearCache()
            mlxSession = ChatSession(container, instructions: mlxSessionInstructions(for: modelID))
        }
        #endif
    }
    
    /// Generate a response for the given prompt with streaming and throttling
    func generate(
        prompt: String,
        systemPrompt: String = AIResponseDefaults.defaultSystemPrompt,
        overrides: GenerationOverrides? = nil,
        image: UIImage? = nil
    ) async throws {
        if state == .loading, let task = loadTask {
            _ = try? await task.value
        }

        guard let model = currentModel else {
            throw LLMError.modelNotLoaded
        }

        try ensureGPUWorkAllowed(for: model)
        await LocalInferenceScheduler.shared.acquire(label: "generate:\(model.id)")
        defer {
            Task {
                await LocalInferenceScheduler.shared.release(label: "generate:\(model.id)")
            }
        }
        
        switch state {
        case .ready:
            break
        case .error(let message):
            throw LLMError.generationFailed(message)
        default:
            throw LLMError.engineBusy
        }
        
        state = .generating
        IdleTimerCoordinator.shared.setReason("llmGenerating", enabled: true)
        currentResponse = ""
        streamingMessageID = UUID() // New unique ID for this generation session
        lastUpdate = .distantPast
        adaptiveThrottleInterval = lowPowerMode ? 0.16 : 0.08
        estimatedTokenCount = 0
        lastTokenCountTextLength = 0
        lastStreamingUpdateLength = 0
        streamingStartTime = Date()
        streamingTokensPerSecond = 0
        print("[LLMEngine] generate start id=\(model.id) engine=\(model.engine.rawValue)")
        
        let usesEphemeralMlxSession = model.engine == .mlx && (
            !mlxModelSupportsSystemRole(modelID: model.id)
        )
        var effectiveSystemPrompt = storedSystemPrompt(fallback: systemPrompt)
        if image != nil {
            effectiveSystemPrompt += "\n\nImportant: You are analyzing an image. Keep your answer very short and concise."
        }
        let effectiveMlxPrompt = mlxPrompt(
            from: prompt,
            systemPrompt: effectiveSystemPrompt,
            modelID: model.id
        )
        let mlxFingerprint = model.engine == .mlx
            ? makeMlxRequestFingerprint(
                modelID: model.id,
                prompt: effectiveMlxPrompt,
                systemPrompt: effectiveSystemPrompt,
                image: image
            )
            : nil
        if let mlxFingerprint {
            lastMlxRequestFingerprint = mlxFingerprint
            print(
                "[LLMEngine] MLX fingerprint request=\(mlxFingerprint.requestKey) prefix=\(mlxFingerprint.reusablePrefixKey) image=\(mlxFingerprint.imageKey ?? "none") estimatedPromptTokens=\(mlxFingerprint.estimatedPromptTokens)"
            )
        }
        let mlxCacheLookup: MlxPromptReuseStore.LookupResult?
        if let mlxFingerprint {
            mlxCacheLookup = await MlxPromptReuseStore.shared.lookup(
                reusablePrefixKey: mlxFingerprint.reusablePrefixKey,
                imageKey: mlxFingerprint.imageKey,
                estimatedPromptTokens: mlxFingerprint.estimatedPromptTokens
            )
            if let mlxCacheLookup {
                print(
                    "[LLMEngine] MLX prompt cache \(mlxCacheLookup.isHit ? "hit" : "miss") prefix=\(mlxFingerprint.reusablePrefixKey) cachedTokens≈\(mlxCacheLookup.cachedPromptTokens)"
                )
            }
        } else {
            mlxCacheLookup = nil
        }
        let currentTopP = overrides?.topP ?? self.topP
        let currentTemperature = overrides?.temperature ?? self.temperature
        let currentMaxTokens = overrides?.maxTokens ?? self.maxTokens
        let effectiveTopP = lowPowerMode ? min(currentTopP, 0.9) : currentTopP
        let effectiveTemperature = lowPowerMode ? min(currentTemperature, 0.6) : currentTemperature
        let effectiveMaxTokens = overrides?.maxTokens ?? (lowPowerMode ? min(currentMaxTokens, 768) : currentMaxTokens)
        #if !targetEnvironment(simulator)
        let mlxGenerateParameters = makeMlxGenerateParameters(
            topP: effectiveTopP,
            temperature: effectiveTemperature,
            maxTokens: effectiveMaxTokens,
            modelID: model.id
        )
        #endif
        // Capture state on MainActor
        #if !targetEnvironment(simulator)
        let currentMlxSession = self.mlxSession
        let freshMlxSession = usesEphemeralMlxSession
            ? try await self.makeFreshMlxSession(
                modelID: model.id,
                systemPrompt: effectiveSystemPrompt,
                generateParameters: mlxGenerateParameters
            )
            : nil
        #endif
        
        // Run on detached task to avoid blocking UI
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let generationStartedAt = Date()
            let residentMemoryBefore = MemoryProfiler.currentResidentMemory
            var firstTokenAt: Date?
            var finalMlxContent = ""
            
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
                        self.postStreamingUpdate(content)
                        return AssistantOutputSanitizer.containsControlMarker(content)
                    }
                } else if model.engine == .mlx {
                    #if targetEnvironment(simulator)
                    throw LLMError.generationFailed("MLX is not available on the simulator.")
                    #else
                    let session: ChatSession
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
                    
                    // Stream MLX output so users see first tokens sooner and keep MLX errors throwable.
                    var rawContent = ""
                    var lastContent = ""
                    let stream: AsyncThrowingStream<String, Error>
                    
                    // For VLM models (e.g. Qwen2-VL), pass the image directly via Transcript.ImageSegment
                    if model.supportsVision, let image {
                        stream = session.streamResponse(
                            to: effectiveMlxPrompt,
                            image: try Self.makeMlxInputImage(from: image)
                        )
                    } else {
                        stream = session.streamResponse(to: effectiveMlxPrompt)
                    }
                    
                    for try await chunk in stream {
                        if Task.isCancelled { break }
                        if firstTokenAt == nil, !chunk.isEmpty {
                            firstTokenAt = Date()
                        }
                        // Accumulate the raw model output and sanitize only a copy
                        // for display. Sanitizing into the buffer would strip any
                        // control marker the model emits as literal text, so the
                        // stop check below could never see it — freezing the visible
                        // answer mid-sentence while generation keeps running.
                        rawContent += chunk
                        lastContent = Self.trimRepeatedLoopIfNeeded(in: rawContent)
                        // Fire-and-forget so draining the model stream never blocks
                        // on a per-token main-actor hop (which batched updates).
                        self.postStreamingUpdate(lastContent)
                        if Self.shouldStopStreaming(content: rawContent) {
                            break
                        }
                        // Let the consumer interleave with the synchronous MLX
                        // producer so tokens surface as they are generated.
                        await Task.yield()
                    }
                    finalMlxContent = lastContent
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
                // Note: no GPU.clearCache() here. On the successful path the user
                // typically continues the conversation, so we keep the bounded
                // buffer cache warm (see configureMlxGPUMemoryIfNeeded) for faster
                // first tokens on the next turn. Teardown paths below still clear.
                if model.engine == .mlx, let mlxFingerprint {
                    let metrics = MlxGenerationMetrics(
                        requestKey: mlxFingerprint.requestKey,
                        reusablePrefixKey: mlxFingerprint.reusablePrefixKey,
                        imageKey: mlxFingerprint.imageKey,
                        cacheHit: mlxCacheLookup?.isHit ?? false,
                        cachedPromptTokens: mlxCacheLookup?.cachedPromptTokens ?? 0,
                        sessionKind: usesEphemeralMlxSession ? "ephemeral" : "reused",
                        estimatedInputTokens: mlxFingerprint.estimatedPromptTokens,
                        estimatedOutputTokens: PromptBudgeter.estimatedTokenCount(finalMlxContent),
                        firstTokenLatency: firstTokenAt.map { $0.timeIntervalSince(generationStartedAt) },
                        wallTime: Date().timeIntervalSince(generationStartedAt),
                        residentMemoryDelta: Int64(MemoryProfiler.currentResidentMemory) - Int64(residentMemoryBefore)
                    )
                    await self.recordMlxGenerationMetrics(metrics)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.state = .ready
                    IdleTimerCoordinator.shared.setReason("llmGenerating", enabled: false)
                    self.generationTask = nil
                    self.streamingStartTime = nil
                    self.streamingTokensPerSecond = 0
                }
                #if !targetEnvironment(simulator)
                if model.engine == .mlx {
                    MLX.GPU.clearCache()
                }
                #endif
                if model.engine == .mlx, let mlxFingerprint {
                    print("[LLMEngine] MLX generation cancelled request=\(mlxFingerprint.requestKey)")
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
                #if !targetEnvironment(simulator)
                if model.engine == .mlx {
                    MLX.GPU.clearCache()
                }
                #endif
                if model.engine == .mlx, let mlxFingerprint {
                    print("[LLMEngine] MLX generation failed request=\(mlxFingerprint.requestKey) error=\(error.localizedDescription)")
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
        systemPrompt: String = AIResponseDefaults.defaultSystemPrompt,
        model: ModelInfo,
        overrides: GenerationOverrides? = nil
    ) async throws -> String {
        try ensureGPUWorkAllowed(for: model)

        if state == .loading, let task = loadTask {
            _ = try? await task.value
        }

        await LocalInferenceScheduler.shared.acquire(label: "isolated:\(model.id)")
        defer {
            Task {
                await LocalInferenceScheduler.shared.release(label: "isolated:\(model.id)")
            }
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
        adaptiveThrottleInterval = lowPowerMode ? 0.16 : 0.08
        estimatedTokenCount = 0
        lastTokenCountTextLength = 0
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
            #if !targetEnvironment(simulator)
            MLX.GPU.clearCache()
            #endif
            resetIdleTimer()
        }

        let effectiveSystemPrompt = storedSystemPrompt(fallback: systemPrompt)
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
        let effectiveMaxTokens = lowPowerMode ? min(currentMaxTokens, 768) : currentMaxTokens
        #if !targetEnvironment(simulator)
        let mlxGenerateParameters = makeMlxGenerateParameters(
            topP: effectiveTopP,
            temperature: effectiveTemperature,
            maxTokens: effectiveMaxTokens,
            modelID: model.id
        )
        let freshMlxSession = model.engine == .mlx
            ? try await self.makeFreshMlxSession(
                modelID: model.id,
                systemPrompt: effectiveSystemPrompt,
                generateParameters: mlxGenerateParameters
            )
            : nil
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
            guard let session = freshMlxSession else {
                throw LLMError.modelNotLoaded
            }

            let stream = session.streamResponse(to: effectiveMlxPrompt)
            var rawResponse = ""
            for try await chunk in stream {
                if Task.isCancelled { break }
                // Keep the raw output for the stop check; sanitize only the copy we
                // return. Sanitizing into the buffer strips control markers before
                // shouldStopStreaming can see them, defeating the early stop.
                rawResponse += chunk
                response = Self.trimRepeatedLoopIfNeeded(in: rawResponse)
                if Self.shouldStopStreaming(content: rawResponse) {
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

    func generateConversationTitle(
        userMessage: String,
        assistantResponse: String,
        model: ModelInfo
    ) async throws -> String {
        guard model.engine == .appleFoundation else {
            throw LLMError.modelNotAvailable("Structured titles require Apple Intelligence.")
        }

        return try await appleFoundationBridge.generateConversationTitle(
            userMessage: userMessage,
            assistantResponse: assistantResponse
        )
    }

    func generateConversationInsights(
        userMessage: String,
        assistantResponse: String,
        model: ModelInfo
    ) async throws -> AppleFoundationConversationInsights {
        guard model.engine == .appleFoundation else {
            throw LLMError.modelNotAvailable("Structured insights require Apple Intelligence.")
        }

        return try await appleFoundationBridge.generateConversationInsights(
            userMessage: userMessage,
            assistantResponse: assistantResponse
        )
    }
    
    /// Posts a streaming update to the main actor WITHOUT the caller awaiting it.
    /// The token-draining loop must never suspend on a main-actor hop per token:
    /// doing so serialized every token against the `@MainActor generate()` frame
    /// that is awaiting the generation task, which batched all updates to the end
    /// of the run. Fire-and-forget keeps the consumer draining the model stream as
    /// fast as tokens arrive while the UI catches up independently (throttled).
    nonisolated private func postStreamingUpdate(_ content: String) {
        Task { @MainActor [weak self] in
            await self?.updateResponseIfNeeded(content, force: false)
        }
    }

    /// Throttled UI update
    private func updateResponseIfNeeded(_ content: String, force: Bool) async {
        // Drop stale out-of-order updates: fire-and-forget posts can land in any
        // order, so never let a shorter (older) snapshot overwrite a longer one.
        // `force` (the final snapshot) always wins.
        if !force {
            guard content.count >= lastStreamingUpdateLength else { return }
        }
        lastStreamingUpdateLength = content.count

        let now = Date()
        if force || now.timeIntervalSince(lastUpdate) >= throttleInterval {
            let uiStart = Date()
            self.currentResponse = content
            self.lastUpdate = now
            if let start = self.streamingStartTime {
                let elapsed = max(0.001, now.timeIntervalSince(start))
                let newTextLength = content.count
                if newTextLength > self.lastTokenCountTextLength {
                    let newText = String(content.suffix(newTextLength - self.lastTokenCountTextLength))
                    self.estimatedTokenCount += newText.split { $0.isWhitespace || $0.isNewline }.count
                    self.lastTokenCountTextLength = newTextLength
                } else if newTextLength < self.lastTokenCountTextLength {
                    self.estimatedTokenCount = content.split { $0.isWhitespace || $0.isNewline }.count
                    self.lastTokenCountTextLength = newTextLength
                }
                self.streamingTokensPerSecond = Double(self.estimatedTokenCount) / elapsed
            }
            
            let uiDuration = Date().timeIntervalSince(uiStart)
            if uiDuration > 0.03 {
                self.adaptiveThrottleInterval = min(0.5, self.adaptiveThrottleInterval + 0.05)
            } else if self.adaptiveThrottleInterval > (lowPowerMode ? 0.16 : 0.08) {
                self.adaptiveThrottleInterval = max(lowPowerMode ? 0.16 : 0.08, self.adaptiveThrottleInterval - 0.02)
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
        adaptiveThrottleInterval = lowPowerMode ? 0.16 : 0.08
        estimatedTokenCount = 0
        lastTokenCountTextLength = 0
        streamingStartTime = nil
        streamingTokensPerSecond = 0
        // Note: The UI layer (ChatView) will handle cleaning up the history message 
        // when currentResponse is cleared or via its own observation.
        currentResponse = "" 
        #if !targetEnvironment(simulator)
        MLX.GPU.clearCache()
        #endif
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

    /// Responds to `UIApplication.didReceiveMemoryWarningNotification`. The
    /// loaded model container is by far the largest allocation in the app
    /// (multi-GB weights), so freeing it is the highest-leverage thing we can
    /// do under memory pressure. We avoid unloading mid-generation so we
    /// don't cut off a response the user is actively waiting on; the GPU
    /// scratch-buffer cache is always safe to drop regardless of state.
    func handleMemoryWarning() {
        MemoryProfiler.log("LLMEngine", message: "Memory warning received (state: \(state))")
        #if !targetEnvironment(simulator)
        MLX.GPU.clearCache()
        #endif
        guard state != .generating, state != .loading else { return }
        unloadModel()
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

    func mlxImageFingerprint(for image: UIImage?) -> String? {
        image.flatMap(Self.imageFingerprint)
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
        print("[LLMEngine] prewarm requested id=\(model.id) engine=\(model.engine.rawValue) current=\(currentModel?.id ?? "none") state=\(state)")

        if model.engine == .appleFoundation {
            let taskID = UUID()
            prewarmTaskID = taskID
            isPrewarming = true
            let startedAt = Date()
            print("[LLMEngine] prewarm indicator on task=\(taskID) id=\(model.id)")

            if currentModel?.id == model.id {
                print("[LLMEngine] prewarm using existing Apple session id=\(model.id)")
                appleFoundationBridge.prewarm()
            } else {
                print("[LLMEngine] prewarm loading Apple session id=\(model.id)")
                try? await loadModel(model)
            }

            let minimumDisplayDuration: TimeInterval = 0.7
            let remainingDuration = minimumDisplayDuration - Date().timeIntervalSince(startedAt)
            if remainingDuration > 0 {
                print("[LLMEngine] prewarm holding indicator remaining=\(String(format: "%.2f", remainingDuration))s")
                try? await Task.sleep(nanoseconds: UInt64(remainingDuration * 1_000_000_000))
            }

            if prewarmTaskID == taskID {
                isPrewarming = false
                prewarmTaskID = nil
                print("[LLMEngine] prewarm indicator off task=\(taskID) id=\(model.id)")
            } else {
                print("[LLMEngine] prewarm task superseded task=\(taskID) id=\(model.id)")
            }
            return
        }

        guard isSceneActive else {
            print("[LLMEngine] prewarm skipped scene inactive id=\(model.id) engine=\(model.engine.rawValue)")
            return
        }

        if currentModel?.id == model.id {
            #if !targetEnvironment(simulator)
            if let session = mlxSession {
                guard model.engine != .mlx || isSceneActive else { return }
                _ = session
                print("[LLMEngine] prewarm skipped MLX already has session id=\(model.id)")
                return
            }
            #endif
        }
        print("[LLMEngine] prewarm loading non-Apple model id=\(model.id)")
        try? await loadModel(model)
    }

    private func approximateTokenCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        return trimmed.split { $0.isWhitespace || $0.isNewline }.count
    }

    private func makeMlxRequestFingerprint(
        modelID: String,
        prompt: String,
        systemPrompt: String,
        image: UIImage?
    ) -> MlxRequestFingerprint {
        let normalizedSystemPrompt = normalizedFingerprintText(systemPrompt)
        let normalizedPrompt = normalizedFingerprintText(prompt)
        let imageKey = image.flatMap(Self.imageFingerprint)
        let reusablePrefix = String(normalizedPrompt.prefix(8_192))
        let reusablePrefixKey = Self.sha256Hex([
            "mlx-prefix-v1",
            modelID,
            normalizedSystemPrompt,
            reusablePrefix,
            imageKey ?? "no-image"
        ])
        let requestKey = Self.sha256Hex([
            "mlx-request-v1",
            modelID,
            normalizedSystemPrompt,
            normalizedPrompt,
            imageKey ?? "no-image"
        ])

        return MlxRequestFingerprint(
            requestKey: requestKey,
            reusablePrefixKey: reusablePrefixKey,
            imageKey: imageKey,
            estimatedPromptTokens: PromptBudgeter.estimatedTokenCount(prompt)
        )
    }

    private func normalizedFingerprintText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func recordMlxGenerationMetrics(_ metrics: MlxGenerationMetrics) {
        lastMlxGenerationMetrics = metrics
        let firstToken = metrics.firstTokenLatency.map { String(format: "%.2fs", $0) } ?? "none"
        let memoryDelta = Self.formatSignedBytes(metrics.residentMemoryDelta)
        print(
            "[LLMEngine] MLX metrics request=\(metrics.requestKey) prefix=\(metrics.reusablePrefixKey) image=\(metrics.imageKey ?? "none") cache=\(metrics.cacheHit ? "hit" : "miss") cachedTokens≈\(metrics.cachedPromptTokens) session=\(metrics.sessionKind) inputTokens≈\(metrics.estimatedInputTokens) outputTokens≈\(metrics.estimatedOutputTokens) firstToken=\(firstToken) wall=\(String(format: "%.2fs", metrics.wallTime)) memoryDelta=\(memoryDelta)"
        )
        updateAdaptivePromptBudget(using: metrics)
        Task {
            await MlxPromptReuseStore.shared.record(
                reusablePrefixKey: metrics.reusablePrefixKey,
                imageKey: metrics.imageKey,
                estimatedPromptTokens: metrics.estimatedInputTokens,
                firstTokenLatency: metrics.firstTokenLatency,
                wallTime: metrics.wallTime,
                residentMemoryDelta: metrics.residentMemoryDelta
            )
        }
    }

    private func updateAdaptivePromptBudget(using metrics: MlxGenerationMetrics) {
        guard currentModel?.engine == .mlx, !lowPowerMode else { return }

        let key = "mlxAdaptiveInputBudgetBonus"
        let previousBonus = UserDefaults.standard.integer(forKey: key)
        let highMemoryGrowth = Int64(1_500_000_000)
        let newBonus: Int

        if metrics.residentMemoryDelta > highMemoryGrowth {
            newBonus = max(0, previousBonus - 500)
        } else if metrics.cacheHit, metrics.cachedPromptTokens >= 1_500 {
            newBonus = min(2_000, previousBonus + 250)
        } else {
            return
        }

        guard newBonus != previousBonus else { return }
        UserDefaults.standard.set(newBonus, forKey: key)
        print("[LLMEngine] MLX adaptive prompt budget bonus=\(newBonus) previous=\(previousBonus)")
    }
}

extension LLMEngine {
    func mlxModelSupportsSystemRole(modelID: String) -> Bool {
        true
    }
}

// MARK: - Private Load

private extension LLMEngine {
    nonisolated static func sha256Hex(_ parts: [String]) -> String {
        var hasher = SHA256()
        for part in parts {
            if let data = part.data(using: .utf8) {
                hasher.update(data: data)
            }
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func imageFingerprint(_ image: UIImage) -> String? {
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        guard let imageData = image.jpegData(compressionQuality: 0.35) else {
            return sha256Hex(["image-v1", "\(width)x\(height)"])
        }

        var hasher = SHA256()
        hasher.update(data: Data("image-v1|\(width)x\(height)|".utf8))
        hasher.update(data: imageData)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func formatSignedBytes(_ bytes: Int64) -> String {
        let prefix = bytes >= 0 ? "+" : "-"
        let magnitude = UInt64(bytes.magnitude)
        return prefix + MemoryProfiler.formatBytes(magnitude)
    }

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
                let instructions = UserDefaults.standard.string(forKey: "systemPrompt") ?? AIResponseDefaults.defaultSystemPrompt
                try appleFoundationBridge.loadSession(instructions: instructions)
                lastLoadedAppleFoundationInstructions = instructions
                #if !targetEnvironment(simulator)
                mlxSession = nil
                mlxModelContainer = nil
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
            if model.requiresUnsupportedMLXQuantization {
                let message = "This model uses 1-bit MLX quantization, which is not supported by the current MLX runtime."
                state = .error(message: message)
                throw LLMError.modelNotAvailable(message)
            }
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
                    let container = try await loadMlxContainer(modelID: model.id)
                    mlxModelContainer = container
                    mlxSession = ChatSession(container, instructions: mlxSessionInstructions(for: model.id))
                    try ensureGPUWorkAllowed(for: model)
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

        return UserDefaults.standard.string(forKey: "systemPrompt") ?? AIResponseDefaults.defaultSystemPrompt
    }

    private func storedSystemPrompt(fallback: String) -> String {
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDefaultFallback = trimmedFallback == AIResponseDefaults.defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            || trimmedFallback == "You are a helpful AI assistant."

        guard isDefaultFallback else { return fallback }
        return UserDefaults.standard.string(forKey: "systemPrompt") ?? AIResponseDefaults.defaultSystemPrompt
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

#if !targetEnvironment(simulator)
    private func makeFreshMlxSession(
        modelID: String,
        systemPrompt: String,
        generateParameters: GenerateParameters
    ) async throws -> ChatSession {
        let container: ModelContainer
        if let loadedContainer = mlxModelContainer, mlxModelID == modelID {
            container = loadedContainer
        } else {
            container = try await loadMlxContainer(modelID: modelID)
        }

        let instructions: String? = {
            guard mlxModelSupportsSystemRole(modelID: modelID) else { return nil }
            let trimmed = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        return ChatSession(container, instructions: instructions, generateParameters: generateParameters)
    }

    /// Bound the MLX Metal buffer cache once per process. The cache lets scratch
    /// and KV buffers be reused across turns; without a limit it grows unbounded,
    /// which is why the engine previously cleared it after every generation. A
    /// bounded cache reuses buffers between back-to-back turns (lower first-token
    /// latency) while keeping idle GPU memory in check on device.
    private static var didConfigureGPUMemory = false
    private static func configureMlxGPUMemoryIfNeeded() {
        guard !didConfigureGPUMemory else { return }
        didConfigureGPUMemory = true
        let physical = ProcessInfo.processInfo.physicalMemory
        // ~5% of RAM, clamped to a sane window for on-device inference.
        let floorBytes: UInt64 = 64 * 1024 * 1024
        let capBytes: UInt64 = 384 * 1024 * 1024
        let fivePercent: UInt64 = physical / 20
        let clamped: UInt64 = min(max(fivePercent, floorBytes), capBytes)
        let cacheLimit = Int(clamped)
        MLX.Memory.cacheLimit = cacheLimit
        print("[LLMEngine] MLX GPU cache limit set to \(cacheLimit / (1024 * 1024))MB (physical=\(physical / (1024 * 1024))MB)")
    }

    private func loadMlxContainer(modelID: String) async throws -> ModelContainer {
        Self.configureMlxGPUMemoryIfNeeded()
        let persistentPath = MLXStorage.modelDirectory(for: modelID)
        if FileManager.default.fileExists(atPath: persistentPath.path) {
            if ModelInfo.vlmMLXModelIDs.contains(modelID) {
                return try await VLMModelFactory.shared.loadContainer(
                    from: persistentPath,
                    using: LocalAITokenizerLoader()
                )
            }

            return try await loadModelContainer(from: persistentPath, using: LocalAITokenizerLoader())
        }

        // The model isn't downloaded locally — surface a clear error rather than
        // attempting a remote download (downloads are managed by ModelManager).
        throw LLMError.modelNotAvailable("Download this model from Settings > Models before loading it.")
    }

    private func makeMlxGenerateParameters(
        topP: Double,
        temperature: Double,
        maxTokens: Int,
        modelID: String
    ) -> GenerateParameters {
        let isVisionModel = ModelInfo.vlmMLXModelIDs.contains(modelID)
        return GenerateParameters(
            maxTokens: isVisionModel && UIDevice.current.userInterfaceIdiom == .phone ? min(maxTokens, 192) : maxTokens,
            maxKVSize: isVisionModel ? 512 : nil,
            kvBits: isVisionModel ? 4 : nil,
            temperature: Float(temperature),
            topP: Float(topP),
            prefillStepSize: isVisionModel ? 128 : 512
        )
    }
#endif

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

#if !targetEnvironment(simulator)
private extension LLMEngine {
    nonisolated static func makeMlxInputImage(from image: UIImage) throws -> UserInput.Image {
        let preparedImage = downsampleMlxVisionImageIfNeeded(image, mode: ImageProcessingMode.current)
        guard let ciImage = CIImage(image: preparedImage) else {
            throw LLMError.generationFailed("Unable to prepare image for MLX.")
        }
        return .ciImage(ciImage)
    }

    nonisolated static func downsampleMlxVisionImageIfNeeded(
        _ image: UIImage,
        mode: ImageProcessingMode
    ) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longestEdge = max(pixelWidth, pixelHeight)
        guard longestEdge > mode.visionMaxDimension else { return image }

        let scale = mode.visionMaxDimension / longestEdge
        let targetSize = CGSize(
            width: max(1, floor(pixelWidth * scale)),
            height: max(1, floor(pixelHeight * scale))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
#endif


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

private actor MlxPromptReuseStore {
    struct LookupResult: Sendable {
        let isHit: Bool
        let cachedPromptTokens: Int
    }

    private struct PersistedState: Codable {
        var records: [Record]
    }

    private struct Record: Codable {
        let reusablePrefixKey: String
        let imageKey: String?
        var estimatedPromptTokens: Int
        var hitCount: Int
        var lastFirstTokenLatency: TimeInterval?
        var bestFirstTokenLatency: TimeInterval?
        var lastWallTime: TimeInterval
        var lastResidentMemoryDelta: Int64
        let createdAt: Date
        var lastAccessedAt: Date
    }

    static let shared = MlxPromptReuseStore()

    private var records: [String: Record] = [:]
    private var hasLoaded = false
    private let maxRecords = 128

    private var storeURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalAI", isDirectory: true)
            .appendingPathComponent("mlx_prompt_reuse_store.json")
    }

    func lookup(
        reusablePrefixKey: String,
        imageKey: String?,
        estimatedPromptTokens: Int
    ) -> LookupResult {
        loadIfNeeded()

        guard var record = records[reusablePrefixKey], record.imageKey == imageKey else {
            return LookupResult(isHit: false, cachedPromptTokens: 0)
        }

        record.hitCount += 1
        record.estimatedPromptTokens = max(record.estimatedPromptTokens, estimatedPromptTokens)
        record.lastAccessedAt = Date()
        records[reusablePrefixKey] = record
        persist()

        return LookupResult(isHit: true, cachedPromptTokens: record.estimatedPromptTokens)
    }

    func record(
        reusablePrefixKey: String,
        imageKey: String?,
        estimatedPromptTokens: Int,
        firstTokenLatency: TimeInterval?,
        wallTime: TimeInterval,
        residentMemoryDelta: Int64
    ) {
        loadIfNeeded()

        let now = Date()
        var record = records[reusablePrefixKey] ?? Record(
            reusablePrefixKey: reusablePrefixKey,
            imageKey: imageKey,
            estimatedPromptTokens: estimatedPromptTokens,
            hitCount: 0,
            lastFirstTokenLatency: nil,
            bestFirstTokenLatency: nil,
            lastWallTime: wallTime,
            lastResidentMemoryDelta: residentMemoryDelta,
            createdAt: now,
            lastAccessedAt: now
        )

        record.estimatedPromptTokens = max(record.estimatedPromptTokens, estimatedPromptTokens)
        record.lastFirstTokenLatency = firstTokenLatency
        if let firstTokenLatency {
            record.bestFirstTokenLatency = min(record.bestFirstTokenLatency ?? firstTokenLatency, firstTokenLatency)
        }
        record.lastWallTime = wallTime
        record.lastResidentMemoryDelta = residentMemoryDelta
        record.lastAccessedAt = now
        records[reusablePrefixKey] = record

        evictIfNeeded()
        persist()
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true

        guard let data = try? Data(contentsOf: storeURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return
        }

        records = Dictionary(uniqueKeysWithValues: state.records.map { ($0.reusablePrefixKey, $0) })
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        guard records.count > maxRecords else { return }
        let staleKeys = records.values
            .sorted { lhs, rhs in
                if lhs.hitCount == rhs.hitCount {
                    return lhs.lastAccessedAt < rhs.lastAccessedAt
                }
                return lhs.hitCount < rhs.hitCount
            }
            .prefix(records.count - maxRecords)
            .map(\.reusablePrefixKey)

        for key in staleKeys {
            records.removeValue(forKey: key)
        }
    }

    private func persist() {
        let directory = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let state = PersistedState(records: Array(records.values))
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: storeURL, options: [.atomic])
    }
}

private actor LocalInferenceScheduler {
    static let shared = LocalInferenceScheduler()

    private struct Waiter {
        let label: String
        let continuation: CheckedContinuation<Void, Never>
    }

    private var isRunning = false
    private var waiters: [Waiter] = []

    func acquire(label: String) async {
        if !isRunning {
            isRunning = true
            print("[LocalInferenceScheduler] acquired label=\(label) queueDepth=0")
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(Waiter(label: label, continuation: continuation))
            print("[LocalInferenceScheduler] queued label=\(label) queueDepth=\(waiters.count)")
        }
        print("[LocalInferenceScheduler] resumed label=\(label) queueDepth=\(waiters.count)")
    }

    func release(label: String) {
        guard isRunning else { return }

        if waiters.isEmpty {
            isRunning = false
            print("[LocalInferenceScheduler] released label=\(label) queueDepth=0")
            return
        }

        let next = waiters.removeFirst()
        print("[LocalInferenceScheduler] handoff from=\(label) to=\(next.label) queueDepth=\(waiters.count)")
        next.continuation.resume()
    }
}
