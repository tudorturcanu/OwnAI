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

    /// The app's single engine instance, for App Intents that run in-process
    /// and must reuse the already-loaded model instead of instantiating a
    /// second engine (and a second copy of the weights) in the same process.
    private(set) static weak var shared: LLMEngine?

    init() {
        LLMEngine.shared = self
    }

    /// Whether MLX (Metal) work is currently allowed. App Intents that continue
    /// in the foreground poll this until the scene-activation event lands.
    var isForegroundActive: Bool { isSceneActive }

    /// The loaded, ready MLX model, if any — lets App Intents answer with the
    /// model that's already in memory rather than loading another one.
    var readyMLXModel: ModelInfo? {
        guard state == .ready,
              let model = currentModel,
              model.engine == .mlx,
              model.downloadState.isDownloaded else { return nil }
        return model
    }

    /// The model already resident in the engine, regardless of backend. Auto
    /// Mode uses this to avoid paying an unnecessary model-switch cost.
    var readyModelID: String? {
        guard state == .ready || state == .generating else { return nil }
        return currentModel?.id
    }

    var state: LLMEngineState = .idle
    var currentResponse: String = ""
    var streamingMessageID = UUID()
    var isPrewarming = false
    
    // Settings
    // NVIDIA's recommended sampling for Nemotron 3 Nano (0.6 / 0.95), and a
    // safer default for every small model here: topP 1.0 lets a 4B sample the
    // far tail of its distribution, which surfaces as non-sequitur replies in
    // otherwise coherent chats. Users who set their own values keep them.
    @ObservationIgnored @AppStorage("temperature") var temperature: Double = 0.6
    @ObservationIgnored @AppStorage("topP") var topP: Double = 0.95
    @ObservationIgnored @AppStorage("maxTokens") var maxTokens: Int = AIResponseDefaults.maxTokens
    @ObservationIgnored @AppStorage("lowPowerMode") var lowPowerMode: Bool = false
    
    // Apple Foundation
    private let appleFoundationBridge = AppleFoundationModelBridge()

    /// Called on the main actor with each rolling-condensation summary (from
    /// either engine) and the conversation ID the triggering generation was
    /// started for, so the UI layer can persist the summary on that
    /// conversation. The ID travels through the generate call rather than
    /// being captured in this closure, so a generation that outlives a
    /// conversation switch still attributes its summary correctly.
    var onRollingSummaryUpdate: ((String, UUID?) -> Void)?
    /// Narrow sink for the active message bubble. The parent chat view does
    /// not need to observe the full engine for every streamed snapshot.
    var onStreamingUpdate: ((String) -> Void)?
    
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
    // Set when resetSession() is called while backgrounded (no GPU access):
    // the MLX session recreation is deferred to the next scene activation.
    private var pendingMlxSessionReset = false
    private var pendingMlxMemoryPressureTrim = false

    #if !targetEnvironment(simulator)
    // Rolling memory for the persistent MLX session, mirroring the Apple
    // Foundation bridge: the ChatSession's KV cache grows every turn with no
    // window management of its own, so long chats would silently overflow the
    // model's context and lose their beginning. We track each completed
    // exchange and, past a threshold, fold the older turns into a
    // model-written summary and re-hydrate the session as
    // instructions-plus-summary followed by the recent turns verbatim.
    private struct MlxSessionTurn {
        let role: String
        let text: String
    }
    private var mlxSessionTurns: [MlxSessionTurn] = []
    private var mlxTranscriptTokenEstimate = 0
    private var mlxRollingSummary: String?

    private static let mlxRollingRecentTurnsToKeep = 4
    private static let mlxRollingSummaryResponseTokens = 200
    private static let mlxRollingSummaryInputBudgetTokens = 2_000
    #endif
    var streamingTokensPerSecond: Double = 0
    private var streamingStartTime: Date?
    private var activeGenerationPerformanceInterval: PerformanceLogger.Interval?
    private var didLogFirstToken = false
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
                PerformanceLogger.event(
                    "ModelWarmHit",
                    label: "Model warm hit",
                    metadata: "model=\(model.id) engine=\(model.engine.rawValue)"
                )
                return
            }
            // Compare the BASE prompt only: memory facts learned mid-chat must
            // not force a session rebuild here, or the conversation's context
            // would be wiped every time something new is remembered. Fresh
            // facts apply when the next session is created.
            let instructions = UserDefaults.standard.string(forKey: "systemPrompt") ?? AIResponseDefaults.defaultSystemPrompt
            if instructions == lastLoadedAppleFoundationInstructions {
                PerformanceLogger.event(
                    "ModelWarmHit",
                    label: "Model warm hit",
                    metadata: "model=\(model.id) engine=\(model.engine.rawValue)"
                )
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
        let performanceInterval = PerformanceLogger.begin(
            "ModelLoad",
            label: "Model load",
            metadata: "model=\(model.id) engine=\(model.engine.rawValue) size_gb=\(model.sizeGB)"
        )
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
            PerformanceLogger.end(
                performanceInterval,
                metadata: "resident_mb=\(MemoryProfiler.currentResidentMemory / 1_048_576)"
            )
            resetIdleTimer()
        } catch is CancellationError {
            PerformanceLogger.end(performanceInterval, status: "cancelled")
            // Canceled loads shouldn't surface as errors.
            return
        } catch {
            PerformanceLogger.end(
                performanceInterval,
                status: "failed",
                metadata: "error_type=\(String(describing: type(of: error)))"
            )
            throw error
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
        pendingMlxSessionReset = false
        pendingMlxMemoryPressureTrim = false
        resetMlxSessionTracking(instructions: nil)
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
        guard isSceneActive else {
            // GPU work is off-limits in the background, but silently keeping
            // the old MLX session would resurface its stale history later —
            // e.g. a watch exchange appended to the conversation while the
            // phone is locked would stay invisible to the model. Do the
            // recreation on the next scene activation instead.
            pendingMlxSessionReset = mlxModelContainer != nil
            return
        }
        pendingMlxSessionReset = false
        // Recreate MLX session with same model to clear conversation history
        if let container = mlxModelContainer, let modelID = mlxModelID {
            mlxSession = nil
            MLX.GPU.clearCache()
            let instructions = mlxSessionInstructions(for: modelID)
            mlxSession = ChatSession(
                container,
                instructions: instructions,
                additionalContext: Self.mlxTemplateContext(
                    thinkingEnabled: ModelInfo.resolvedThinkingEnabled(modelID: modelID)
                )
            )
            resetMlxSessionTracking(instructions: instructions)
        }
        #endif
    }

    #if !targetEnvironment(simulator)
    /// Rough context window for an MLX model, aligned with the input budgets
    /// PromptBudgeter assumes for the same model classes. The estimate lives
    /// there so the two cannot drift apart.
    private func mlxContextWindowEstimate(for model: ModelInfo) -> Int {
        PromptBudgeter.mlxContextWindow(for: model)
    }

    private func resetMlxSessionTracking(instructions: String?) {
        mlxSessionTurns = []
        mlxRollingSummary = nil
        mlxTranscriptTokenEstimate = PromptBudgeter.estimatedTokenCount(instructions ?? "")
    }

    /// Records one completed exchange on the persistent MLX session so the
    /// rolling condensation knows what the session's KV cache contains.
    func recordMlxSessionTurn(userPrompt: String, assistantResponse: String) {
        let response = AssistantOutputSanitizer.sanitize(assistantResponse)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        mlxSessionTurns.append(MlxSessionTurn(role: "User", text: userPrompt))
        if !response.isEmpty {
            mlxSessionTurns.append(MlxSessionTurn(role: "Assistant", text: response))
        }
        mlxTranscriptTokenEstimate += PromptBudgeter.estimatedTokenCount(userPrompt)
            + PromptBudgeter.estimatedTokenCount(response)
            + 32
    }

    /// Folds older turns of the persistent MLX session into a model-written
    /// summary once the transcript nears the context window, and re-hydrates
    /// the session as instructions-plus-summary followed by the recent turns.
    /// On any failure the old session stays as-is — worse than condensed, but
    /// never worse than before this existed.
    func condenseMlxSessionIfNeeded(
        model: ModelInfo,
        conversationID: UUID? = nil,
        additionalPromptTokens: Int = 0
    ) async {
        guard isSceneActive,
              let container = mlxModelContainer,
              let modelID = mlxModelID,
              mlxSession != nil else { return }
        let window = mlxContextWindowEstimate(for: model)
        let policy = DeviceResourcePolicy.current
        let condensationFraction = policy.isLowMemoryPhone ? 0.50 : 0.68
        guard mlxTranscriptTokenEstimate + additionalPromptTokens >= Int(Double(window) * condensationFraction) else { return }
        let recentTurnsToKeep = policy.isLowMemoryPhone ? 2 : Self.mlxRollingRecentTurnsToKeep
        guard mlxSessionTurns.count > recentTurnsToKeep + 1 else { return }

        // Keep whole exchanges: the retained tail must start with a user turn.
        var recent = Array(mlxSessionTurns.suffix(recentTurnsToKeep))
        while let first = recent.first, first.role != "User" {
            recent.removeFirst()
        }
        let older = mlxSessionTurns.dropLast(recent.count)
        guard !older.isEmpty else { return }

        var log = older
            .map { "\($0.role): \($0.text)" }
            .joined(separator: "\n\n")
        if let mlxRollingSummary {
            log = "Summary of even earlier conversation:\n\(mlxRollingSummary)\n\n" + log
        }
        let clippedLog = PromptBudgeter.snippetSizedText(
            log,
            maxTokens: Self.mlxRollingSummaryInputBudgetTokens
        )

        let summary: String
        if policy.isLowMemoryPhone {
            // Avoid allocating a second generation cache just to summarize.
            // A clipped, sanitized continuity excerpt is deterministic and
            // preserves enough older context for a constrained device.
            summary = PromptBudgeter.sanitizedContinuitySummary(
                PromptBudgeter.boundedChatText(clippedLog, maxTokens: 360)
            )
        } else {
            let summarizer = ChatSession(
                container,
                instructions: """
                You summarize conversations so an assistant can continue them later.
                Capture key facts, names, decisions, preferences, and open questions.
                Write plain prose under 120 words. No preamble, no headings.
                """,
                generateParameters: makeMlxGenerateParameters(
                    topP: 0.8,
                    temperature: 0.2,
                    maxTokens: Self.mlxRollingSummaryResponseTokens,
                    modelID: modelID
                ),
                additionalContext: Self.mlxTemplateContext(thinkingEnabled: false)
            )
            do {
            // Reasoning models answer with their chain of thought attached, so
            // drop it here too — otherwise the "summary" promoted into the
            // instructions channel below is mostly the model thinking aloud.
            let rawSummary = AssistantOutputSanitizer
                .sanitize(
                    Self.rawOutputSeed(modelID: modelID, thinkingEnabled: false)
                        + (try await summarizer.respond(to: clippedLog))
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // The summary is derived from conversation content and is about to
            // be promoted into the privileged instructions channel, so strip
            // any sentence that reads as a directive to the assistant. This
            // also covers rebuildMlxSessionAfterFailure, which reuses the
            // stored mlxRollingSummary set below.
                summary = PromptBudgeter.sanitizedContinuitySummary(rawSummary)
            } catch {
                MemoryProfiler.log("LLMEngine", message: "MLX rolling condense failed: \(error.localizedDescription)")
                return
            }
        }
        guard !summary.isEmpty else { return }

        let baseInstructions = mlxSessionInstructions(for: modelID) ?? ""
        // Same framing rule as the memory block and the Apple bridge summary:
        // silent background, or small models recite it back every turn.
        let mergedInstructions = """
        \(baseInstructions)

        Earlier parts of this conversation, summarized for continuity. Use \
        them silently when relevant; never recite or recap this summary. \
        Always respond to the user's latest message:
        \(summary)
        """

        let history = recent.map { turn in
            turn.role == "User" ? Chat.Message.user(turn.text) : Chat.Message.assistant(turn.text)
        }
        mlxSession = nil
        MLX.GPU.clearCache()
        mlxSession = ChatSession(
            container,
            instructions: mergedInstructions,
            history: history,
            additionalContext: Self.mlxTemplateContext(
                thinkingEnabled: ModelInfo.resolvedThinkingEnabled(modelID: modelID)
            )
        )
        mlxRollingSummary = summary
        mlxSessionTurns = recent
        mlxTranscriptTokenEstimate = PromptBudgeter.estimatedTokenCount(mergedInstructions)
            + recent.reduce(0) { $0 + PromptBudgeter.estimatedTokenCount($1.text) + 16 }
        onRollingSummaryUpdate?(summary, conversationID)
        MemoryProfiler.log("LLMEngine", message: "MLX rolling condense: folded \(older.count) turns, kept \(recent.count).")
    }

    /// Emergency context recovery after a failed generation on the persistent
    /// MLX session — most often the accumulated transcript colliding with the
    /// model's real context limit when the token estimate undershot it.
    /// Deterministic on purpose (no model call, so it cannot fail the same
    /// way): keeps the rolling summary already in hand plus the most recent
    /// exchange, drops the rest. Returns nil when the session held no context
    /// worth shedding, so unrelated failures still surface as errors.
    func rebuildMlxSessionAfterFailure() -> ChatSession? {
        guard let container = mlxModelContainer,
              let modelID = mlxModelID,
              mlxSession != nil,
              !mlxSessionTurns.isEmpty || mlxRollingSummary != nil else { return nil }

        var recent = Array(mlxSessionTurns.suffix(2))
        while let first = recent.first, first.role != "User" {
            recent.removeFirst()
        }

        let baseInstructions = mlxSessionInstructions(for: modelID) ?? ""
        let mergedInstructions: String
        if let mlxRollingSummary {
            mergedInstructions = """
            \(baseInstructions)

            Earlier parts of this conversation, summarized for continuity. Use \
            them silently when relevant; never recite or recap this summary. \
            Always respond to the user's latest message:
            \(mlxRollingSummary)
            """
        } else {
            mergedInstructions = baseInstructions
        }

        let history = recent.map { turn in
            turn.role == "User" ? Chat.Message.user(turn.text) : Chat.Message.assistant(turn.text)
        }
        mlxSession = nil
        MLX.GPU.clearCache()
        let rebuilt = ChatSession(
            container,
            instructions: mergedInstructions,
            history: history,
            additionalContext: Self.mlxTemplateContext(
                thinkingEnabled: ModelInfo.resolvedThinkingEnabled(modelID: modelID)
            )
        )
        mlxSession = rebuilt
        mlxSessionTurns = recent
        mlxTranscriptTokenEstimate = PromptBudgeter.estimatedTokenCount(mergedInstructions)
            + recent.reduce(0) { $0 + PromptBudgeter.estimatedTokenCount($1.text) + 16 }
        return rebuilt
    }
    #endif
    
    /// Generate a response for the given prompt with streaming and throttling
    func generate(
        prompt: String,
        systemPrompt: String = AIResponseDefaults.defaultSystemPrompt,
        overrides: GenerationOverrides? = nil,
        image: UIImage? = nil,
        conversationID: UUID? = nil
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
        adaptiveThrottleInterval = lowPowerMode
            ? 0.16
            : DeviceResourcePolicy.current.streamingUpdateInterval
        estimatedTokenCount = 0
        lastTokenCountTextLength = 0
        lastStreamingUpdateLength = 0
        streamingStartTime = Date()
        streamingTokensPerSecond = 0
        didLogFirstToken = false
        let generationPerformanceInterval = PerformanceLogger.begin(
            "Generation",
            label: "Generation",
            metadata: "model=\(model.id) engine=\(model.engine.rawValue) prompt_characters=\(prompt.count) image=\(image != nil)"
        )
        activeGenerationPerformanceInterval = generationPerformanceInterval

        
        let usesEphemeralMlxSession = model.engine == .mlx && (
            !mlxModelSupportsSystemRole(modelID: model.id)
        )
        var effectiveSystemPrompt = systemPromptWithRuntimeIdentity(
            storedSystemPrompt(fallback: systemPrompt),
            model: model
        )
        if image != nil {
            effectiveSystemPrompt += "\n\nImportant: You are analyzing an image. Keep your answer very short and concise."
        }
        // Forward Apple-bridge condensation summaries to the engine-level
        // callback on the main actor. (The MLX path calls it directly.)
        appleFoundationBridge.onRollingSummaryUpdate = { [weak self] summary, summaryConversationID in
            guard let self else { return }
            Task { @MainActor in
                self.onRollingSummaryUpdate?(summary, summaryConversationID)
            }
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
        }
        let mlxCacheLookup: MlxPromptReuseStore.LookupResult?
        if let mlxFingerprint {
            mlxCacheLookup = await MlxPromptReuseStore.shared.lookup(
                reusablePrefixKey: mlxFingerprint.reusablePrefixKey,
                imageKey: mlxFingerprint.imageKey,
                estimatedPromptTokens: mlxFingerprint.estimatedPromptTokens
            )
        } else {
            mlxCacheLookup = nil
        }
        let currentTopP = overrides?.topP ?? self.topP
        let currentTemperature = overrides?.temperature ?? self.temperature
        let currentMaxTokens = overrides?.maxTokens ?? self.maxTokens
        let effectiveTopP = lowPowerMode ? min(currentTopP, 0.9) : currentTopP
        let effectiveTemperature = lowPowerMode ? min(currentTemperature, 0.6) : currentTemperature
        let devicePolicy = DeviceResourcePolicy.current
        let effectiveMaxTokens = min(
            overrides?.maxTokens ?? currentMaxTokens,
            devicePolicy.generationTokenLimit(
                lowPowerMode: lowPowerMode || ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalState: ProcessInfo.processInfo.thermalState
            )
        )
        #if !targetEnvironment(simulator)
        // Rolling memory: fold older turns into a summary before the window
        // fills, so long MLX chats keep their context instead of silently
        // overflowing it. Runs rarely (past ~70% of the window estimate),
        // and before the response budget below so the freed window counts.
        if model.engine == .mlx, !usesEphemeralMlxSession {
            await condenseMlxSessionIfNeeded(
                model: model,
                conversationID: conversationID,
                additionalPromptTokens: PromptBudgeter.estimatedTokenCount(effectiveMlxPrompt)
            )
        }
        // Size the response cap to what the window can still hold once the
        // session transcript and this prompt are accounted for, mirroring
        // the Apple bridge's adaptive budget. A fixed cap on a long chat
        // collides with the window mid-response and truncates the answer.
        var mlxResponseTokenBudget = effectiveMaxTokens
        if model.engine == .mlx, !usesEphemeralMlxSession {
            let window = mlxContextWindowEstimate(for: model)
            let promptTokens = PromptBudgeter.estimatedTokenCount(effectiveMlxPrompt)
            let available = window - mlxTranscriptTokenEstimate - promptTokens - 256
            mlxResponseTokenBudget = max(256, min(effectiveMaxTokens, available))
        }
        let mlxGenerateParameters = makeMlxGenerateParameters(
            topP: effectiveTopP,
            temperature: effectiveTemperature,
            maxTokens: mlxResponseTokenBudget,
            modelID: model.id
        )
        #endif
        // Capture state on MainActor
        #if !targetEnvironment(simulator)
        let currentMlxSession = self.mlxSession
        // The reused session streams with whatever parameters it holds, and it
        // was created with library defaults — so temperature, topP, and the
        // response token budget only ever applied to ephemeral sessions.
        // Apply this request's parameters before generation starts (safe: the
        // session is idle here; generation hasn't been kicked off yet).
        if model.engine == .mlx, !usesEphemeralMlxSession {
            currentMlxSession?.generateParameters = mlxGenerateParameters
        }
        let freshMlxSession = usesEphemeralMlxSession
            ? try await self.makeFreshMlxSession(
                modelID: model.id,
                systemPrompt: effectiveSystemPrompt,
                generateParameters: mlxGenerateParameters
            )
            : nil
        #endif
        
        // Run on detached task to avoid blocking UI
        let generationPeakSampling = model.engine == .mlx
            ? MemoryProfiler.startPeakSampling()
            : nil
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let generationStartedAt = Date()
            let residentMemoryBefore = MemoryProfiler.currentResidentMemory
            var firstTokenAt: Date?
            var finalMlxContent = ""
            
            do {
                if model.engine == .appleFoundation {
                    // Apple Foundation Path

                    let finalAppleContent = try await self.appleFoundationBridge.streamResponse(
                        to: prompt,
                        systemPrompt: effectiveSystemPrompt,
                        topP: effectiveTopP,
                        temperature: effectiveTemperature,
                        maxTokens: effectiveMaxTokens,
                        image: image,
                        conversationID: conversationID
                    ) { [weak self] content in
                        guard let self else { return true }
                        self.postStreamingUpdate(content)
                        // Apple's model never emits MLX-style control markers as
                        // stop tokens; matching them here only aborts answers that
                        // mention markers like </s> literally.
                        return false
                    }
                    // Streaming updates above are throttled and fire-and-forget,
                    // so the final chunk can be dropped — freezing the visible
                    // answer mid-sentence. Force-commit the complete answer, the
                    // same way the MLX path does below.
                    await self.updateResponseIfNeeded(finalAppleContent, force: true)
                } else if model.engine == .mlx {
                    #if targetEnvironment(simulator)
                    throw LLMError.generationFailed("MLX is not available on the simulator.")
                    #else
                    var session: ChatSession
                    if usesEphemeralMlxSession {
                        guard let freshMlxSession else {
                            throw LLMError.modelNotLoaded
                        }
                        session = freshMlxSession
                    } else if let currentMlxSession {
                        session = currentMlxSession
                    } else {
                        throw LLMError.modelNotLoaded
                    }

                    // Stream MLX output so users see first tokens sooner and keep MLX errors throwable.
                    var attemptedContextRecovery = false
                    while true {
                        do {
                            var rawContent = Self.rawOutputSeed(modelID: model.id, session: session)
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
                            break
                        } catch {
                            // A failed turn on the long-running session is most often
                            // the transcript colliding with the model's real context
                            // limit (the token estimate is heuristic and can
                            // undershoot). Retry once on a rebuilt session that keeps
                            // the rolling summary and the latest exchange; anything
                            // else — or a second failure — surfaces as the error it is.
                            guard !attemptedContextRecovery,
                                  !usesEphemeralMlxSession,
                                  !(error is CancellationError),
                                  !Task.isCancelled,
                                  let rebuilt = await self.rebuildMlxSessionAfterFailure() else {
                                throw error
                            }
                            attemptedContextRecovery = true
                            rebuilt.generateParameters = mlxGenerateParameters
                            session = rebuilt
                            MemoryProfiler.log(
                                "LLMEngine",
                                message: "MLX generation failed (\(error.localizedDescription)); retrying on condensed session."
                            )
                        }
                    }
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
                #if !targetEnvironment(simulator)
                if model.engine == .mlx, !usesEphemeralMlxSession {
                    // The reused session's KV cache now contains this exchange;
                    // mirror it in the rolling-memory turn log.
                    await self.recordMlxSessionTurn(
                        userPrompt: prompt,
                        assistantResponse: finalMlxContent
                    )
                }
                #endif
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
                }
            } catch {
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
                }
            }
        }
        
        generationTask = task
        await MemoryProfiler.measure("LLMEngine.generate(\(model.id))") {
            await task.value
        }
        #if !targetEnvironment(simulator)
        if pendingMlxMemoryPressureTrim, model.engine == .mlx {
            pendingMlxMemoryPressureTrim = false
            _ = rebuildMlxSessionAfterFailure()
            MLX.GPU.clearCache()
        }
        #endif
        let generationStatus: String
        if case .error = state {
            generationStatus = "failed"
        } else if Task.isCancelled {
            generationStatus = "cancelled"
        } else {
            generationStatus = "success"
        }
        if let generationPeakSampling {
            let peak = generationPeakSampling.stop()
            if generationStatus == "success" {
                ModelHealthStore.shared.recordRuntimeMemoryPeak(
                    modelID: model.id,
                    peakResidentMemoryBytes: peak
                )
            }
        }
        let generationDurationSeconds = max(
            0.001,
            PerformanceLogger.elapsedMilliseconds(since: generationPerformanceInterval) / 1_000
        )
        let completedTokensPerSecond = Double(estimatedTokenCount) / generationDurationSeconds
        PerformanceLogger.end(
            generationPerformanceInterval,
            status: generationStatus,
            metadata: "output_characters=\(currentResponse.count) estimated_tokens=\(estimatedTokenCount) effective_tps=\(String(format: "%.1f", completedTokensPerSecond))"
        )
        activeGenerationPerformanceInterval = nil
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
            if model.exceedsDeviceMemoryBudget {
                throw LLMError.modelNotAvailable("This model needs more memory than this device has. Choose a smaller model in Settings > Models.")
            }
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
        adaptiveThrottleInterval = lowPowerMode
            ? 0.16
            : DeviceResourcePolicy.current.streamingUpdateInterval
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
        let effectiveMaxTokens = min(
            lowPowerMode ? min(currentMaxTokens, 768) : currentMaxTokens,
            DeviceResourcePolicy.current.maximumGenerationTokens
        )
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
                    return false
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
            var rawResponse = Self.rawOutputSeed(modelID: model.id, session: session)
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
            if !didLogFirstToken,
               !content.isEmpty,
               let interval = activeGenerationPerformanceInterval {
                didLogFirstToken = true
                let latency = PerformanceLogger.elapsedMilliseconds(since: interval)
                PerformanceLogger.event(
                    "FirstToken",
                    label: "First token",
                    metadata: "latency_ms=\(String(format: "%.1f", latency)) \(interval.metadata)"
                )
            }
            let uiStart = Date()
            self.currentResponse = content
            self.onStreamingUpdate?(content)
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
            } else {
                let baseline = lowPowerMode
                    ? 0.16
                    : DeviceResourcePolicy.current.streamingUpdateInterval
                if self.adaptiveThrottleInterval > baseline {
                    self.adaptiveThrottleInterval = max(baseline, self.adaptiveThrottleInterval - 0.02)
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
        adaptiveThrottleInterval = lowPowerMode ? 0.16 : 0.08
        estimatedTokenCount = 0
        lastTokenCountTextLength = 0
        streamingStartTime = nil
        streamingTokensPerSecond = 0
        // Note: The UI layer (ChatView) will handle cleaning up the history message 
        // when currentResponse is cleared or via its own observation.
        currentResponse = ""
        onStreamingUpdate?("")
        #if !targetEnvironment(simulator)
        MLX.GPU.clearCache()
        #endif
        resetIdleTimer()
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        let isActive = phase == .active
        isSceneActive = isActive

        guard !isActive else {
            if pendingMlxSessionReset {
                pendingMlxSessionReset = false
                resetSession()
            }
            return
        }

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
        onStreamingUpdate?("")

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
        if state == .generating, currentModel?.engine == .mlx {
            pendingMlxMemoryPressureTrim = true
        }
        #endif
        guard state != .generating, state != .loading else { return }
        unloadModel()
    }

    /// Extracts durable user facts for cross-chat memory. Only available on
    /// Apple Intelligence devices; returns [] elsewhere.
    func extractUserFacts(from userMessage: String) async throws -> [String] {
        try await appleFoundationBridge.extractUserFacts(from: userMessage)
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
            // A live session is not enough: loadModel and resetSession both
            // create sessions with an empty KV cache (e.g. after a memory
            // warning unloaded the model between turns). Only a session that
            // has recorded exchanges can answer follow-ups without the caller
            // re-injecting the conversation transcript.
            return mlxSession != nil && !mlxSessionTurns.isEmpty
            #endif
        }
    }

    /// How full the current model's context window is (0...1), for models
    /// with a fixed window the UI should warn about. Returns 0 when the
    /// model has no such limit or no session is active.
    func contextUsageFraction(for model: ModelInfo?) -> Double {
        guard let model, currentModel?.id == model.id else { return 0 }
        guard model.engine == .appleFoundation else { return 0 }
        return appleFoundationBridge.contextUsageFraction
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
    /// Full real-device release test. Evaluation models remain outside the
    /// shipping catalog even after passing; a developer must review this report
    /// and explicitly move the definition into `releasedModels`.
    func runMobileReadinessSuite(model: ModelInfo) async -> ModelMobileReadinessReport {
        var checks = Dictionary(uniqueKeysWithValues: ModelReleaseGate.requiredChecks.map { ($0, false) })
        var notes: [String] = []
        let memoryBefore = MemoryProfiler.currentResidentMemory
        checks["artifacts"] = model.isAppleFoundation || MLXStorage.validationReport(for: model.id).isValid

        do {
            let start = Date()
            try await loadModel(model)
            checks["load"] = state == .ready

            try await generate(
                prompt: "Remember the code 739 and reply only: OK.",
                overrides: GenerationOverrides(temperature: 0, topP: 1, maxTokens: 24)
            )
            let firstOutput = AssistantOutputSanitizer.sanitize(currentResponse)
            checks["firstResponse"] = Date().timeIntervalSince(start) < 30
            checks["output"] = !firstOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            currentResponse = ""
            try await generate(
                prompt: "What code did I ask you to remember? Reply only with the digits.",
                overrides: GenerationOverrides(temperature: 0, topP: 1, maxTokens: 24)
            )
            checks["multiTurn"] = AssistantOutputSanitizer.sanitize(currentResponse).contains("739")

            let cancellationTask = Task {
                try? await self.generate(
                    prompt: "Write a long detailed essay about local computing.",
                    overrides: GenerationOverrides(temperature: 0.2, topP: 1, maxTokens: 256)
                )
            }
            try? await Task.sleep(for: .milliseconds(150))
            stopGeneration()
            await cancellationTask.value
            checks["cancellation"] = state != .generating && state != .loading

            handleScenePhaseChange(.background)
            resetSession()
            handleScenePhaseChange(.active)
            checks["backgroundRecovery"] = isForegroundActive

            let peakMemory = max(memoryBefore, MemoryProfiler.currentResidentMemory)
            checks["memory"] = peakMemory < UInt64(Double(ProcessInfo.processInfo.physicalMemory) * 0.8)
        } catch {
            notes.append(error.localizedDescription)
        }

        let report = ModelMobileReadinessReport(
            modelID: model.id,
            timestamp: Date(),
            checks: checks,
            notes: notes,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
        )
        ModelHealthStore.shared.saveReadinessReport(report)
        return report
    }

    func runQuickTest(model: ModelInfo) async -> ModelQuickTestResult {
        let start = Date()
        let memoryBefore = MemoryProfiler.currentResidentMemory
        let peakSampling = MemoryProfiler.startPeakSampling()
        let policy = DeviceResourcePolicy.current
        defer { peakSampling.task.cancel() }

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
            let loadStart = Date()
            try await loadModel(model)
            let loadDurationMs = Int(Date().timeIntervalSince(loadStart) * 1000.0)
            let generationStart = Date()
            try await generate(
                prompt: "Reply with a single word: OK.",
                overrides: GenerationOverrides(temperature: 0.2, topP: 1.0, maxTokens: 16)
            )
            let response = AssistantOutputSanitizer.sanitize(currentResponse)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let durationMs = Int(Date().timeIntervalSince(start) * 1000.0)
            let generationDurationMs = Int(Date().timeIntervalSince(generationStart) * 1000.0)
            let success = response.lowercased().contains("ok")
            let summary = await PerformanceMetricsStore.shared.dashboardData().modelSummaries
                .first(where: { $0.modelID == model.id })
            currentResponse = previousResponse
            return ModelQuickTestResult(
                modelID: model.id,
                success: success,
                responseSnippet: String(response.prefix(60)),
                durationMs: durationMs,
                timestamp: Date(),
                loadDurationMs: loadDurationMs,
                generationDurationMs: generationDurationMs,
                medianFirstTokenMs: summary?.medianFirstTokenMilliseconds.map { Int($0) },
                peakResidentMemoryBytes: max(memoryBefore, peakSampling.stop()),
                physicalMemoryBytes: policy.physicalMemoryBytes,
                hardwareIdentifier: policy.hardwareIdentifier,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
            )
        } catch {
            currentResponse = previousResponse
            return ModelQuickTestResult(
                modelID: model.id,
                success: false,
                responseSnippet: error.localizedDescription,
                durationMs: Int(Date().timeIntervalSince(start) * 1000.0),
                timestamp: Date(),
                peakResidentMemoryBytes: max(memoryBefore, peakSampling.stop()),
                physicalMemoryBytes: policy.physicalMemoryBytes,
                hardwareIdentifier: policy.hardwareIdentifier,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
            )
        }
    }

    func prewarmIfNeeded(model: ModelInfo) async {
        if model.engine == .appleFoundation {
            let taskID = UUID()
            prewarmTaskID = taskID
            isPrewarming = true
            let startedAt = Date()

            if currentModel?.id == model.id {
                await appleFoundationBridge.prewarm()
            } else {
                try? await loadModel(model)
            }

            let minimumDisplayDuration: TimeInterval = 0.7
            let remainingDuration = minimumDisplayDuration - Date().timeIntervalSince(startedAt)
            if remainingDuration > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remainingDuration * 1_000_000_000))
            }

            if prewarmTaskID == taskID {
                isPrewarming = false
                prewarmTaskID = nil
            }
            return
        }

        guard isSceneActive else {
            return
        }

        if currentModel?.id == model.id {
            #if !targetEnvironment(simulator)
            if let session = mlxSession {
                guard model.engine != .mlx || isSceneActive else { return }
                _ = session
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
        
        state = .loading
        currentModel = model
        
        switch model.engine {
        case .appleFoundation:
            let availability = appleFoundationBridge.availability
            if availability == .available {
                let baseInstructions = UserDefaults.standard.string(forKey: "systemPrompt") ?? AIResponseDefaults.defaultSystemPrompt
                try appleFoundationBridge.loadSession(
                    instructions: systemPromptWithRuntimeIdentity(
                        AssistantMemoryStore.augmentedSystemPrompt(baseInstructions),
                        model: model
                    )
                )
                lastLoadedAppleFoundationInstructions = baseInstructions
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
            if model.exceedsDeviceMemoryBudget {
                let message = "This model needs more memory than this device has. Choose a smaller model in Settings > Models."
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
            do {
                if mlxModelID != model.id || mlxSession == nil {
                    try Task.checkCancellation()
                    try ensureGPUWorkAllowed(for: model)
                    let container = try await loadMlxContainer(modelID: model.id)
                    mlxModelContainer = container
                    let instructions = mlxSessionInstructions(for: model)
                    mlxSession = ChatSession(
                        container,
                        instructions: instructions,
                        additionalContext: Self.mlxTemplateContext(
                            thinkingEnabled: ModelInfo.resolvedThinkingEnabled(modelID: model.id)
                        )
                    )
                    resetMlxSessionTracking(instructions: instructions)
                    try ensureGPUWorkAllowed(for: model)
                    mlxModelID = model.id
                }
                appleFoundationBridge.resetSession()
                state = .ready
            } catch {
                if error is CancellationError {
                    state = .idle
                    throw error
                }
                state = .error(message: error.localizedDescription)
                throw LLMError.modelNotAvailable(error.localizedDescription)
            }
            #endif
        }
    }

    func ensureGPUWorkAllowed(for model: ModelInfo) throws {
        guard model.engine == .mlx else { return }
        // Last line of defense on A13-class GPUs: MLX's kernels fail to compile
        // there and the runtime aborts the process with an uncatchable fatal
        // error, so the device gate must run before any MLX GPU work starts.
        guard DeviceResourcePolicy.supportsMLXCompute else {
            throw LLMError.deviceCannotRunMLX
        }
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

    func mlxSessionInstructions(for model: ModelInfo) -> String? {
        guard mlxModelSupportsSystemRole(modelID: model.id) else {
            return nil
        }

        return systemPromptWithRuntimeIdentity(
            AssistantMemoryStore.augmentedSystemPrompt(
                UserDefaults.standard.string(forKey: "systemPrompt") ?? AIResponseDefaults.defaultSystemPrompt
            ),
            model: model
        )
    }

    /// Session maintenance only retains the model ID. Resolve it back to the
    /// catalog entry so rebuilt sessions keep the same runtime identity.
    func mlxSessionInstructions(for modelID: String) -> String? {
        guard let model = ModelInfo.allModels.first(where: { $0.id == modelID }) else {
            return nil
        }
        return mlxSessionInstructions(for: model)
    }

    /// Local models do not reliably know the name of the checkpoint currently
    /// loaded by the app. Ground that answer in runtime state instead of their
    /// pretraining, which can otherwise make one model claim to be another.
    private func systemPromptWithRuntimeIdentity(_ prompt: String, model: ModelInfo) -> String {
        """
        \(prompt)

        Runtime identity, for background only: you are responding locally through \(model.name) (model ID: \(model.id)). Keep this silent — never mention your model name, that you are an AI model, or that you run locally, unless the user directly asks what model is responding. If asked, identify yourself as \(model.name); do not claim to be a different model, provider, or organization based on your training data.
        """
    }

    private func storedSystemPrompt(fallback: String) -> String {
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDefaultFallback = trimmedFallback == AIResponseDefaults.defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            || trimmedFallback == "You are a helpful AI assistant."

        guard isDefaultFallback else { return AssistantMemoryStore.augmentedSystemPrompt(fallback) }
        return AssistantMemoryStore.augmentedSystemPrompt(
            UserDefaults.standard.string(forKey: "systemPrompt") ?? AIResponseDefaults.defaultSystemPrompt
        )
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

        return ChatSession(
            container,
            instructions: instructions,
            generateParameters: generateParameters,
            additionalContext: Self.mlxTemplateContext(
                thinkingEnabled: ModelInfo.resolvedThinkingEnabled(modelID: modelID)
            )
        )
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
        let cacheLimit = Int(DeviceResourcePolicy.current.mlxCacheLimitBytes)
        MLX.Memory.cacheLimit = cacheLimit
    }

    private func loadMlxContainer(modelID: String) async throws -> ModelContainer {
        Self.configureMlxGPUMemoryIfNeeded()

        var modelPath: URL?
        let persistentPath = MLXStorage.modelDirectory(for: modelID)
        if FileManager.default.fileExists(atPath: persistentPath.path) {
            MLXStorage.normalizeConfigIfNeeded(in: persistentPath)
            modelPath = persistentPath
        } else if let bundledPath = MLXStorage.bundledModelDirectory(for: modelID) {
            // Starter model shipped inside the app bundle — load in place,
            // no copy to writable storage needed.
            modelPath = bundledPath
        }

        if let modelPath {
            if ModelInfo.vlmMLXModelIDs.contains(modelID) {
                return try await VLMModelFactory.shared.loadContainer(
                    from: modelPath,
                    using: LocalAITokenizerLoader()
                )
            }

            return try await loadModelContainer(from: modelPath, using: LocalAITokenizerLoader())
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
        let lowMemoryPhone = DeviceResourcePolicy.current.isLowMemoryPhone
        return GenerateParameters(
            maxTokens: isVisionModel && UIDevice.current.userInterfaceIdiom == .phone ? min(maxTokens, 192) : maxTokens,
            maxKVSize: isVisionModel ? 512 : (lowMemoryPhone ? 2_048 : nil),
            kvBits: isVisionModel ? 4 : nil,
            temperature: Float(temperature),
            topP: Float(topP),
            prefillStepSize: isVisionModel ? 128 : (lowMemoryPhone ? 256 : 512)
        )
    }
#endif

    /// Chat-template variables for an MLX session. Reasoning models otherwise
    /// default to thinking *on* and spend the whole response budget on hidden
    /// chain of thought before the first word of the answer appears — minutes
    /// of a blank bubble on a phone. `enable_thinking` makes the stored
    /// per-model preference (off unless the user turns it on) actually reach
    /// the template, which nothing did before.
    nonisolated static func mlxTemplateContext(thinkingEnabled: Bool) -> [String: any Sendable] {
        ["enable_thinking": thinkingEnabled]
    }

    /// Opening tag to seed the raw output buffer with for models whose chat
    /// template left a `<think>` block open at the end of the generation prompt
    /// (see `ModelInfo.opensResponseInsideReasoningBlock`). Those models emit
    /// only the closing tag, so without the seed the sanitizer cannot tell
    /// reasoning from the answer until `</think>` finally arrives — and the
    /// whole chain of thought streams into the bubble in the meantime. Seeding
    /// makes the buffer self-describing from the first token.
    private nonisolated static func rawOutputSeed(modelID: String, thinkingEnabled: Bool) -> String {
        ModelInfo.opensResponseInsideReasoningBlock(
            modelID: modelID,
            thinkingEnabled: thinkingEnabled
        ) ? "<think>" : ""
    }

#if !targetEnvironment(simulator)
    /// Seed read back from the session's own template context, so it always
    /// describes the prompt that was actually rendered — including a long-lived
    /// session built before the user last flipped the thinking toggle.
    private nonisolated static func rawOutputSeed(modelID: String, session: ChatSession) -> String {
        rawOutputSeed(
            modelID: modelID,
            thinkingEnabled: (session.additionalContext?["enable_thinking"] as? Bool) ?? false
        )
    }
#endif

    private nonisolated static func shouldStopStreaming(content: String) -> Bool {
        if AssistantOutputSanitizer.containsControlMarker(content) {
            return true
        }

        return detectRepeatedLoop(in: content) != nil
    }

    /// Trims a runaway repetition from the visible answer while keeping the
    /// reasoning block attached. The chain of thought has to survive: the UI
    /// streams it into the "Thinking…" card, and a response that ends while
    /// still reasoning is only recognizable as one if the block is still there.
    private nonisolated static func trimRepeatedLoopIfNeeded(in content: String) -> String {
        let parts = AssistantOutputSanitizer.parts(from: content)
        guard let loop = detectRepeatedLoop(in: parts.content) else {
            return AssistantOutputSanitizer.canonicalized(parts)
        }

        let visiblePrefix = parts.content[..<loop.range.lowerBound]
        let separator = visiblePrefix.last.map(\.isWhitespace) == true ? "" : " "
        return AssistantOutputSanitizer.canonicalized(
            AssistantOutputSanitizer.Parts(
                content: String(visiblePrefix) + separator + loop.repeatedUnit,
                thinkingContent: parts.thinkingContent
            )
        )
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
    case deviceCannotRunMLX

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
        case .deviceCannotRunMLX:
            return "This device's chip can't run downloadable models. They need an A14 chip or newer — iPhone 12, iPhone SE (3rd generation), or later."
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
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(Waiter(label: label, continuation: continuation))
        }
    }

    func release(label: String) {
        guard isRunning else { return }

        if waiters.isEmpty {
            isRunning = false
            return
        }

        let next = waiters.removeFirst()
        next.continuation.resume()
    }
}
