//
//  ModelManager.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import Foundation
import Hub
import SwiftUI
import UIKit
import Darwin
import Combine

// MLX is disabled for simulator - only available on real devices
#if !targetEnvironment(simulator)
import MLXLMCommon
#endif

private final class DownloadProgressLimiter {
    private struct State {
        var progress: Double
        var timestamp: CFTimeInterval
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]
    private let minimumInterval: CFTimeInterval = 0.12
    private let minimumDelta: Double = 0.01

    func shouldEmit(modelID: String, progress: Double, now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if progress >= 0.99 {
            states[modelID] = State(progress: progress, timestamp: now)
            return true
        }

        guard let previous = states[modelID] else {
            states[modelID] = State(progress: progress, timestamp: now)
            return true
        }

        let progressDelta = progress - previous.progress
        let timeDelta = now - previous.timestamp

        guard progressDelta >= minimumDelta || timeDelta >= minimumInterval else {
            return false
        }

        states[modelID] = State(progress: progress, timestamp: now)
        return true
    }

    func reset(modelID: String) {
        lock.lock()
        defer { lock.unlock() }
        states.removeValue(forKey: modelID)
    }
}

private final class DownloadDiagnostics {
    private struct State {
        let modelName: String
        let expectedBytes: Double
        let startedAt: CFTimeInterval
        var rawCallbacks = 0
        var suppressedCallbacks = 0
        var emittedCallbacks = 0
        var mainActorUpdates = 0
        var lastProgress: Double = 0
        var lastProgressTimestamp: CFTimeInterval
        var lastLoggedProgress: Double = 0
        var lastLoggedTimestamp: CFTimeInterval
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]
    private let minimumLogInterval: CFTimeInterval = 2.0
    private let minimumLogProgressDelta: Double = 0.05

    func start(modelID: String, modelName: String, expectedBytes: Double, now: CFTimeInterval = CACurrentMediaTime()) {
        lock.lock()
        defer { lock.unlock() }
        states[modelID] = State(
            modelName: modelName,
            expectedBytes: expectedBytes,
            startedAt: now,
            lastProgressTimestamp: now,
            lastLoggedTimestamp: now
        )
        print("[ModelManager] download diagnostics start id=\(modelID) name=\(modelName) expected=\(Self.byteString(expectedBytes))")
    }

    func recordSnapshotCallback(
        modelID: String,
        progress: Double,
        emitted: Bool,
        now: CFTimeInterval = CACurrentMediaTime()
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard var state = states[modelID] else { return }
        state.rawCallbacks += 1
        if emitted {
            state.emittedCallbacks += 1
        } else {
            state.suppressedCallbacks += 1
        }

        let previousProgress = state.lastProgress
        let previousTimestamp = state.lastProgressTimestamp
        if progress > previousProgress {
            state.lastProgress = progress
            state.lastProgressTimestamp = now
        }

        let elapsedSinceLastLog = now - state.lastLoggedTimestamp
        let progressSinceLastLog = progress - state.lastLoggedProgress
        let shouldLog = emitted && (
            elapsedSinceLastLog >= minimumLogInterval ||
            progressSinceLastLog >= minimumLogProgressDelta ||
            progress >= 0.99
        )

        if shouldLog {
            let deltaProgress = max(0, progress - previousProgress)
            let deltaTime = max(0.001, now - previousTimestamp)
            let instantaneousSpeed = state.expectedBytes > 0
                ? (state.expectedBytes * deltaProgress) / deltaTime
                : 0
            let downloadedBytes = state.expectedBytes * progress
            print(
                "[ModelManager] download progress id=\(modelID) progress=\(Int(progress * 100))% downloaded=\(Self.byteString(downloadedBytes)) speed=\(Self.byteString(instantaneousSpeed))/s raw=\(state.rawCallbacks) emitted=\(state.emittedCallbacks) suppressed=\(state.suppressedCallbacks)"
            )
            state.lastLoggedTimestamp = now
            state.lastLoggedProgress = progress
        }

        states[modelID] = state
    }

    func recordMainActorUpdate(
        modelID: String,
        progress: Double,
        enqueuedAt: CFTimeInterval,
        now: CFTimeInterval = CACurrentMediaTime()
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard var state = states[modelID] else { return }
        state.mainActorUpdates += 1

        let queueDelay = now - enqueuedAt
        if queueDelay >= 0.08 {
            print(
                "[ModelManager] download main-thread lag id=\(modelID) progress=\(Int(progress * 100))% delay=\(String(format: "%.0f", queueDelay * 1000))ms updates=\(state.mainActorUpdates)"
            )
        }

        states[modelID] = state
    }

    func finish(modelID: String, finalProgress: Double, now: CFTimeInterval = CACurrentMediaTime()) {
        lock.lock()
        defer { lock.unlock() }

        guard let state = states.removeValue(forKey: modelID) else { return }
        let duration = max(0.001, now - state.startedAt)
        let downloadedBytes = state.expectedBytes * finalProgress
        let averageSpeed = downloadedBytes / duration
        print(
            "[ModelManager] download diagnostics finish id=\(modelID) name=\(state.modelName) duration=\(String(format: "%.1f", duration))s downloaded=\(Self.byteString(downloadedBytes)) avg=\(Self.byteString(averageSpeed))/s raw=\(state.rawCallbacks) emitted=\(state.emittedCallbacks) suppressed=\(state.suppressedCallbacks) mainActor=\(state.mainActorUpdates)"
        )
    }

    func cancel(modelID: String, now: CFTimeInterval = CACurrentMediaTime()) {
        lock.lock()
        defer { lock.unlock() }

        guard let state = states.removeValue(forKey: modelID) else { return }
        let duration = max(0.001, now - state.startedAt)
        print(
            "[ModelManager] download diagnostics cancel id=\(modelID) name=\(state.modelName) duration=\(String(format: "%.1f", duration))s raw=\(state.rawCallbacks) emitted=\(state.emittedCallbacks) suppressed=\(state.suppressedCallbacks) mainActor=\(state.mainActorUpdates)"
        )
    }

    func fail(modelID: String, message: String, now: CFTimeInterval = CACurrentMediaTime()) {
        lock.lock()
        defer { lock.unlock() }

        guard let state = states.removeValue(forKey: modelID) else { return }
        let duration = max(0.001, now - state.startedAt)
        print(
            "[ModelManager] download diagnostics fail id=\(modelID) name=\(state.modelName) duration=\(String(format: "%.1f", duration))s progress=\(Int(state.lastProgress * 100))% raw=\(state.rawCallbacks) emitted=\(state.emittedCallbacks) suppressed=\(state.suppressedCallbacks) mainActor=\(state.mainActorUpdates) error=\(message)"
        )
    }

    private static func byteString(_ bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes.rounded()), countStyle: .file)
    }
}

enum DownloadErrorAction {
    case retry
    case freeSpace
    case repair

    var iconName: String {
        switch self {
        case .retry:
            return "arrow.clockwise"
        case .freeSpace:
            return "externaldrive.badge.exclamationmark"
        case .repair:
            return "wrench.and.screwdriver"
        }
    }

    var title: String {
        switch self {
        case .retry:
            return "Retry"
        case .freeSpace:
            return "Free Space"
        case .repair:
            return "Repair"
        }
    }
}

/// Manages model downloads and lifecycle
@MainActor
@Observable
final class ModelManager: ObservableObject {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    private static let requiredMLXDownloadGlobs = [
        "config.json",
        "params.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "tokenizer.model",
        "sentencepiece.bpe.model",
        "vocab.json",
        "merges.txt",
        "special_tokens_map.json",
        "generation_config.json",
        "chat_template.json",
        "chat_template.jinja",
        "*.safetensors",
        "*.safetensors.index.json",
        "*.bin"
    ]

    struct OnboardingRecommendation: Equatable {
        let modelID: String
        let title: String
        let summary: String
        let detail: String
        let actionTitle: String
        let prefersImmediateUse: Bool
        let usesFallback: Bool
    }

    private enum DownloadFailureReason: Equatable {
        case lowStorage(requiredGB: Double, availableGB: Double)
        case network
        case corrupted
        case simulatorUnsupported
        case unknown
    }

    private struct DownloadFailure: Equatable {
        let reason: DownloadFailureReason
        let message: String
    }
    
    // MARK: - Properties
    
    var models: [ModelInfo] = ModelInfo.allModels
    @ObservationIgnored @AppStorage("selectedModelID") private var persistedSelectedModelID: String?
    var selectedModelID: String? {
        didSet {
            persistedSelectedModelID = selectedModelID
            if let selectedModelID,
               let model = models.first(where: { $0.id == selectedModelID }) {
                ensureModelPreferences(for: model)
            }
        }
    }
    @ObservationIgnored @AppStorage("autoSelectBestModel") var autoSelectBestModel: Bool = true
    @ObservationIgnored @AppStorage("downloadNotifications") var downloadNotifications: Bool = true
    
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var backgroundTaskIDs: [String: UIBackgroundTaskIdentifier] = [:]
    private var downloadFailures: [String: DownloadFailure] = [:]
    @ObservationIgnored private let downloadProgressLimiter = DownloadProgressLimiter()
    @ObservationIgnored private let downloadDiagnostics = DownloadDiagnostics()
    private var thinkingPreferencesVersion = 0
    
    // MARK: - Computed Properties
    
    var hasAvailableModels: Bool {
        !availableModels.isEmpty
    }
    
    var availableModels: [ModelInfo] {
        models.filter { model in
            isModelUsable(model)
        }
    }
    
    var selectedModel: ModelInfo? {
        if let id = selectedModelID, let model = models.first(where: { $0.id == id }) {
            if isModelUsable(model) {
                return model
            }
        }
        // Prefer Apple Intelligence if available, otherwise best downloaded MLX model.
        if let best = bestAvailableModel() {
            return best
        }
        return nil
    }
    
    var isAppleIntelligenceAvailable: Bool {
        AppleFoundationModelBridge().isAvailable
    }
    
    /// Returns true if the device hardware supports Apple Intelligence, even if disabled
    var isAppleIntelligenceDeviceSupported: Bool {
        AppleFoundationModelBridge().isDeviceSupported
    }
    
    /// Returns a user-friendly hint explaining why Apple Intelligence is unavailable
    var appleIntelligenceUnavailableHint: String {
        guard let appleModel = models.first(where: { $0.engine == .appleFoundation }) else {
            return "Apple Intelligence is not available."
        }
        if case .error(let message) = appleModel.downloadState {
            switch message {
            case "Device not supported":
                return "Apple Intelligence is not supported on this device. You can use a downloadable model instead."
            case "Not enabled":
                return "Enable Apple Intelligence in Settings > Apple Intelligence."
            case "Model not ready":
                return "Apple Intelligence is still preparing. Please try again later."
            default:
                return "Apple Intelligence is currently unavailable."
            }
        }
        return "Apple Intelligence is currently unavailable."
    }
    
    // MARK: - Initialization
    
    init() {
        selectedModelID = persistedSelectedModelID
        ensureSelection()
        Task {
            await checkAvailability()
        }
        
        // Warn user when app goes to background during an active download
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
    }
    
    // MARK: - Public Methods
    
    /// Select a specific model to use
    func selectModel(_ modelID: String) {
        print("[ModelManager] selectModel id=\(modelID)")
        selectedModelID = modelID
    }

    func isThinkingEnabled(for model: ModelInfo) -> Bool {
        guard model.supportsThinkingToggle else { return false }
        _ = thinkingPreferencesVersion
        let defaults = UserDefaults.standard
        if defaults.object(forKey: model.thinkingPreferenceKey) == nil {
            return model.defaultThinkingEnabled
        }
        return defaults.bool(forKey: model.thinkingPreferenceKey)
    }

    func setThinkingEnabled(_ enabled: Bool, for model: ModelInfo) {
        guard model.supportsThinkingToggle else { return }
        UserDefaults.standard.set(enabled, forKey: model.thinkingPreferenceKey)
        thinkingPreferencesVersion += 1
    }

    func refreshSelection() {
        ensureSelection()
    }

    func onboardingRecommendation() -> OnboardingRecommendation? {
        if let downloadedBest = bestDownloadedFreeModel() {
            return recommendation(
                for: downloadedBest,
                title: "Recommended",
                summary: "Already ready on this device.",
                detail: downloadedBest.engine == .appleFoundation
                    ? "Apple Intelligence is available now, so you can start chatting without downloading anything."
                    : "\(downloadedBest.name) is already available locally, so it will get you to the first reply fastest.",
                actionTitle: "Use \(downloadedBest.name)",
                prefersImmediateUse: true,
                usesFallback: false
            )
        }

        if isAppleIntelligenceAvailable {
            return recommendation(
                for: .appleFoundation,
                title: "Recommended",
                summary: "Fastest start with no download.",
                detail: "Apple Intelligence is available now, so you can begin immediately. For fully local processing, you can still download an on-device model later.",
                actionTitle: "Use Apple Intelligence",
                prefersImmediateUse: true,
                usesFallback: false
            )
        }

        let availableStorage = DiskSpace.availableGB()
        let freeMLXModels = models
            .filter { $0.engine == .mlx }
            .filter { MonetizationManager.freeModelIDs.contains($0.id) }
            .filter { shouldShowModelInCatalog($0) }

        let preferredLocalModel: ModelInfo?

        if UIDevice.current.userInterfaceIdiom != .phone {
            preferredLocalModel = freeMLXModels.first(where: { $0.id == ModelInfo.gemma2_2b_4bit.id })
                ?? freeMLXModels.sorted { $0.sizeGB > $1.sizeGB }.first
        } else if availableStorage >= requiredSpaceGB(for: .gemma2_2b_4bit)
                    && ModelInfo.gemma2_2b_4bit.currentDeviceFit != .unsupported {
            preferredLocalModel = freeMLXModels.first(where: { $0.id == ModelInfo.gemma2_2b_4bit.id })
        } else if availableStorage >= requiredSpaceGB(for: .gemma3_1b_qat_4bit) {
            preferredLocalModel = freeMLXModels.first(where: { $0.id == ModelInfo.gemma3_1b_qat_4bit.id })
        } else {
            preferredLocalModel = freeMLXModels.first(where: { $0.id == ModelInfo.gemma3_270m_qat_4bit.id })
                ?? freeMLXModels.sorted { $0.sizeGB < $1.sizeGB }.first
        }

        if let preferredLocalModel {
            let detail: String
            if preferredLocalModel.id == ModelInfo.gemma2_2b_4bit.id {
                detail = "This device should handle \(preferredLocalModel.name) well, and it gives a better quality baseline than the ultra-small models."
            } else if preferredLocalModel.id == ModelInfo.gemma3_1b_qat_4bit.id {
                detail = "\(preferredLocalModel.name) keeps the download light while still fitting comfortably on this device."
            } else {
                detail = "\(preferredLocalModel.name) is the safest local starting point when storage or device headroom is tighter."
            }

            return recommendation(
                for: preferredLocalModel,
                title: "Recommended",
                summary: "\(preferredLocalModel.sizeLabel) download, fully on-device.",
                detail: detail,
                actionTitle: preferredLocalModel.downloadState.isDownloaded
                    ? "Use \(preferredLocalModel.name)"
                    : "Download \(preferredLocalModel.name)",
                prefersImmediateUse: preferredLocalModel.downloadState.isDownloaded,
                usesFallback: false
            )
        }

        guard let fallback = bestAvailableModel() ?? models.first(where: { $0.engine == .appleFoundation }) else {
            return nil
        }

        return recommendation(
            for: fallback,
            title: "Recommended",
            summary: "Using the best available fallback.",
            detail: "A first-choice starter model is not available right now, so this fallback keeps onboarding moving instead of leaving you without a usable model.",
            actionTitle: "Continue",
            prefersImmediateUse: fallback.downloadState.isDownloaded || fallback.engine == .appleFoundation,
            usesFallback: true
        )
    }

    @discardableResult
    func applyOnboardingRecommendation() -> OnboardingRecommendation? {
        applyOnboardingChoice(preferredModelID: nil)
    }

    @discardableResult
    func applyOnboardingChoice(preferredModelID: String?) -> OnboardingRecommendation? {
        if let preferredModelID,
           let preferredModel = models.first(where: { $0.id == preferredModelID }) {
            let recommendation = recommendation(
                for: preferredModel,
                title: "Selected for onboarding",
                summary: preferredModel.downloadState.isDownloaded || preferredModel.engine == .appleFoundation
                    ? "Using your selected model."
                    : "\(preferredModel.sizeLabel) download selected.",
                detail: deviceFitSummary(for: preferredModel),
                actionTitle: preferredModel.downloadState.isDownloaded || preferredModel.engine == .appleFoundation
                    ? "Use \(preferredModel.name)"
                    : "Download \(preferredModel.name)",
                prefersImmediateUse: preferredModel.downloadState.isDownloaded || preferredModel.engine == .appleFoundation,
                usesFallback: false
            )
            return applyOnboardingChoice(using: recommendation)
        }

        guard let recommendation = onboardingRecommendation() else {
            print("[ModelManager] onboarding recommendation unavailable")
            ensureSelection()
            return nil
        }

        return applyOnboardingChoice(using: recommendation)
    }

    @discardableResult
    private func applyOnboardingChoice(using recommendation: OnboardingRecommendation) -> OnboardingRecommendation? {
        guard let model = models.first(where: { $0.id == recommendation.modelID }) else {
            print("[ModelManager] onboarding recommendation unavailable")
            ensureSelection()
            return nil
        }

        print("[ModelManager] onboarding recommendation accepted model=\(model.id) fallback=\(recommendation.usesFallback)")

        if model.engine == .appleFoundation || model.downloadState.isDownloaded {
            selectModel(model.id)
            return recommendation
        }

        if preflightFailure(for: model) == nil {
            selectedModelID = model.id
            downloadModel(model.id)
            return recommendation
        }

        if let fallback = bestAvailableModel() {
            print("[ModelManager] onboarding recommendation fallback model=\(fallback.id)")
            selectModel(fallback.id)
        } else {
            ensureSelection()
        }
        return recommendation
    }

    func downloadErrorAction(for modelID: String) -> DownloadErrorAction {
        guard let failure = downloadFailures[modelID] else { return .retry }
        switch failure.reason {
        case .lowStorage:
            return .freeSpace
        case .corrupted:
            return .repair
        case .network, .simulatorUnsupported, .unknown:
            return .retry
        }
    }

    @objc
    private func handleWillResignActive() {
        guard downloadNotifications else { return }
        guard let activeModelID = downloadTasks.keys.first,
              let model = models.first(where: { $0.id == activeModelID }) else { return }
        NotificationManager.shared.postDownloadBackgroundWarning(modelName: model.name)
    }

    func repairModel(_ modelID: String, selectWhenFinished: Bool = false) {
        guard let index = models.firstIndex(where: { $0.id == modelID }) else { return }
        guard models[index].engine == .mlx else { return }

        cancelDownload(modelID)
        #if targetEnvironment(simulator)
        applyDownloadFailure(simulatorUnsupportedFailure(), for: modelID)
        #else
        MLXStorage.removeModelArtifacts(for: modelID)
        models[index].downloadState = .notDownloaded
        downloadFailures.removeValue(forKey: modelID)
        downloadModel(modelID, selectWhenFinished: selectWhenFinished)
        #endif
    }
    
    /// Start downloading a model
    func downloadModel(_ modelID: String, selectWhenFinished: Bool = false) {
        guard let index = models.firstIndex(where: { $0.id == modelID }) else { return }
        let model = models[index]
        guard model.engine == .mlx else { return }
        guard downloadTasks[modelID] == nil else { return }
        guard compatibilityMessage(for: model) == nil else { return }

        if let failure = preflightFailure(for: model) {
            applyDownloadFailure(failure, for: modelID)
            return
        }
        
        print("[ModelManager] download start id=\(modelID)")
        downloadFailures.removeValue(forKey: modelID)
        downloadProgressLimiter.reset(modelID: modelID)
        downloadDiagnostics.start(
            modelID: modelID,
            modelName: model.name,
            expectedBytes: model.sizeGB * 1_000_000_000
        )
        models[index].downloadState = .downloading(progress: 0.02, speedBytesPerSecond: nil)

        if downloadNotifications {
            Task { @MainActor in
                _ = await NotificationManager.shared.requestAuthorizationIfNeeded()
            }
        }
        
        let task = Task { [weak self] in
            guard let self = self else { return }
            #if targetEnvironment(simulator)
            await MainActor.run {
                self.applyDownloadFailure(self.simulatorUnsupportedFailure(), for: modelID)
            }
            #else
            do {
                try await self.downloadModelContainerWithRetry(modelID: modelID, model: model)
                await MainActor.run {
                    if let idx = self.models.firstIndex(where: { $0.id == modelID }) {
                        self.models[idx].downloadState = .downloaded
                    }
                    self.downloadFailures.removeValue(forKey: modelID)
                }
                self.persistModelIfNeeded(modelID: modelID)
                guard MLXStorage.hasValidModelArtifacts(for: modelID) else {
                    throw DownloadFailureError(failure: self.corruptedFailure())
                }
                if self.downloadNotifications {
                    await MainActor.run {
                        NotificationManager.shared.postDownloadCompleted(modelName: model.name)
                    }
                }
                self.downloadDiagnostics.finish(modelID: modelID, finalProgress: 1.0)
                print("[ModelManager] download complete id=\(modelID)")
                await MainActor.run {
                    if selectWhenFinished || self.selectedModelID == nil {
                        self.selectedModelID = modelID
                    }
                }
            } catch is CancellationError {
                self.downloadDiagnostics.cancel(modelID: modelID)
                print("[ModelManager] download cancelled id=\(modelID)")
            } catch let failureError as DownloadFailureError {
                self.downloadDiagnostics.fail(modelID: modelID, message: failureError.failure.message)
                await MainActor.run {
                    self.applyDownloadFailure(failureError.failure, for: modelID)
                }
                if self.downloadNotifications {
                    await MainActor.run {
                        NotificationManager.shared.postDownloadFailed(modelName: model.name, errorMessage: failureError.failure.message)
                    }
                }
                print("[ModelManager] download failed id=\(modelID) error=\(failureError.failure.message)")
            } catch {
                let failure = self.classifyDownloadError(error, for: model)
                self.downloadDiagnostics.fail(modelID: modelID, message: failure.message)
                await MainActor.run {
                    self.applyDownloadFailure(failure, for: modelID)
                }
                if self.downloadNotifications {
                    await MainActor.run {
                        NotificationManager.shared.postDownloadFailed(modelName: model.name, errorMessage: failure.message)
                    }
                }
                print("[ModelManager] download failed id=\(modelID) error=\(failure.message)")
            }
            #endif
            await MainActor.run {
                self.downloadTasks.removeValue(forKey: modelID)
                self.downloadProgressLimiter.reset(modelID: modelID)
                self.updateIdleTimer()
                self.endBackgroundTask(for: modelID)
            }
        }

        downloadTasks[modelID] = task
        updateIdleTimer()
        beginBackgroundTask(for: modelID)
    }
    
    /// Cancel an ongoing download
    func cancelDownload(_ modelID: String) {
        downloadTasks[modelID]?.cancel()
        downloadTasks.removeValue(forKey: modelID)
        downloadFailures.removeValue(forKey: modelID)
        downloadProgressLimiter.reset(modelID: modelID)
        
        if let index = models.firstIndex(where: { $0.id == modelID }) {
            models[index].downloadState = .notDownloaded
        }
        updateIdleTimer()
        endBackgroundTask(for: modelID)
    }
    
    /// Delete a downloaded model
    func deleteModel(_ modelID: String) {
        guard let model = models.first(where: { $0.id == modelID }) else { return }
        guard model.engine == .mlx else { return } // Can't delete built-in models
        
        #if !targetEnvironment(simulator)
        MLXStorage.removeModelArtifacts(for: modelID)
        #endif
        
        if let index = models.firstIndex(where: { $0.id == modelID }) {
            models[index].downloadState = .notDownloaded
        }
        downloadFailures.removeValue(forKey: modelID)
        
        // Clear selection if it was deleted
        if selectedModelID == modelID {
            selectedModelID = nil
        }

        ensureSelection()
    }
    
    // MARK: - Idle Timer
    
    /// Keeps the screen awake while any download is in progress
    private func updateIdleTimer() {
        let hasActiveDownloads = !downloadTasks.isEmpty
        IdleTimerCoordinator.shared.setReason("downloads", enabled: hasActiveDownloads)
    }
    
    // MARK: - Background Task
    
    /// Request extra background execution time so downloads continue when the app is backgrounded
    private func beginBackgroundTask(for modelID: String) {
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "ModelDownload.\(modelID)") { [weak self] in
            // iOS is about to expire the background time — clean up
            self?.endBackgroundTask(for: modelID)
        }
        backgroundTaskIDs[modelID] = taskID
    }
    
    private func endBackgroundTask(for modelID: String) {
        guard let taskID = backgroundTaskIDs.removeValue(forKey: modelID),
              taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
    }
    
    // MARK: - Private Methods

    private struct DownloadFailureError: Error {
        let failure: DownloadFailure
    }

    private func applyDownloadFailure(_ failure: DownloadFailure, for modelID: String) {
        downloadFailures[modelID] = failure
        if let index = models.firstIndex(where: { $0.id == modelID }) {
            models[index].downloadState = .error(message: failure.message)
        }
    }

    private func requiredSpaceGB(for model: ModelInfo) -> Double {
        max(model.sizeGB * 1.15, model.sizeGB + 0.35)
    }

    private func preflightFailure(for model: ModelInfo) -> DownloadFailure? {
        let available = DiskSpace.availableGB()
        let required = requiredSpaceGB(for: model)
        if available + 0.001 < required {
            return DownloadFailure(
                reason: .lowStorage(requiredGB: required, availableGB: available),
                message: String(
                    format: "Not enough free space (need %.1f GB, available %.1f GB).",
                    required,
                    available
                )
            )
        }
        return nil
    }

    private func simulatorUnsupportedFailure() -> DownloadFailure {
        DownloadFailure(reason: .simulatorUnsupported, message: "Simulator not supported")
    }

    private func corruptedFailure() -> DownloadFailure {
        DownloadFailure(
            reason: .corrupted,
            message: "Model files are incomplete or corrupted. Tap Repair to re-download."
        )
    }

    private func classifyDownloadError(_ error: Error, for model: ModelInfo) -> DownloadFailure {
        let nsError = error as NSError

        if nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return preflightFailure(for: model) ?? DownloadFailure(
                reason: .lowStorage(requiredGB: requiredSpaceGB(for: model), availableGB: DiskSpace.availableGB()),
                message: "Not enough free space to finish the download."
            )
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOSPC {
            return preflightFailure(for: model) ?? DownloadFailure(
                reason: .lowStorage(requiredGB: requiredSpaceGB(for: model), availableGB: DiskSpace.availableGB()),
                message: "Not enough free space to finish the download."
            )
        }

        if nsError.domain == NSURLErrorDomain || isLikelyNetworkError(message: nsError.localizedDescription) {
            return DownloadFailure(
                reason: .network,
                message: "Network issue while downloading. Check your connection and retry."
            )
        }

        if isLikelyCorruptionError(message: nsError.localizedDescription) {
            return corruptedFailure()
        }

        let fallback = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if fallback.isEmpty {
            return DownloadFailure(reason: .unknown, message: "Download failed. Please try again.")
        }
        return DownloadFailure(reason: .unknown, message: fallback)
    }

    private func isLikelyNetworkError(message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("network")
            || lower.contains("internet")
            || lower.contains("offline")
            || lower.contains("timed out")
            || lower.contains("could not connect")
            || lower.contains("connection")
    }

    private func isLikelyCorruptionError(message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("checksum")
            || lower.contains("corrupt")
            || lower.contains("invalid")
            || lower.contains("unexpected eof")
            || lower.contains("tokenizer")
            || lower.contains("safetensors")
    }

    #if !targetEnvironment(simulator)
    private func downloadModelContainerWithRetry(modelID: String, model: ModelInfo) async throws {
        let maxAttempts = 3
        let hub = HubApi(downloadBase: MLXStorage.persistentBaseURL().deletingLastPathComponent())
        var shouldTryFullRepoFallback = true

        do {
            print("[ModelManager] download filter id=\(modelID) globs=\(Self.requiredMLXDownloadGlobs.joined(separator: ","))")
            try await runSnapshotDownload(
                hub: hub,
                modelID: modelID,
                matching: Self.requiredMLXDownloadGlobs,
                maxAttempts: maxAttempts,
                model: model
            )
            return
        } catch {
            if error is CancellationError { throw error }
            let failure = classifyDownloadError(error, for: model)
            shouldTryFullRepoFallback = failure.reason == .corrupted || failure.reason == .unknown
            if !shouldTryFullRepoFallback {
                throw DownloadFailureError(failure: failure)
            }
            print("[ModelManager] download fallback id=\(modelID) reason=\(failure.message)")
        }

        do {
            try await runSnapshotDownload(
                hub: hub,
                modelID: modelID,
                matching: [],
                maxAttempts: maxAttempts,
                model: model
            )
            return
        } catch {
            if error is CancellationError { throw error }
            let failure = classifyDownloadError(error, for: model)
            throw DownloadFailureError(failure: failure)
        }
    }

    private func runSnapshotDownload(
        hub: HubApi,
        modelID: String,
        matching globs: [String],
        maxAttempts: Int,
        model: ModelInfo
    ) async throws {
        let filenames = try await hub.getFilenames(from: modelID, matching: globs)
        let metadata = try await hub.getFileMetadata(from: modelID, matching: globs)
        let files = zip(filenames, metadata).map { (filename: $0.0, size: Double($0.1.size ?? 0)) }
        let totalBytes = max(1.0, files.reduce(0.0) { $0 + max(0.0, $1.size) })
        var completedBytes = 0.0

        for attempt in 1...maxAttempts {
            do {
                try Task.checkCancellation()
                completedBytes = 0.0
                for file in files {
                    try Task.checkCancellation()
                    let bytesBeforeFile = completedBytes
                    let effectiveFileBytes = max(1.0, file.size)
                    _ = try await hub.snapshot(from: modelID, matching: [file.filename]) { progress, speed in
                        let fileFraction = max(0.0, min(progress.fractionCompleted, 1.0))
                        let aggregateProgress = min(
                            0.99,
                            max(0.0, (bytesBeforeFile + (effectiveFileBytes * fileFraction)) / totalBytes)
                        )
                        let callbackTime = CACurrentMediaTime()
                        let shouldEmit = self.downloadProgressLimiter.shouldEmit(
                            modelID: modelID,
                            progress: aggregateProgress,
                            now: callbackTime
                        )
                        self.downloadDiagnostics.recordSnapshotCallback(
                            modelID: modelID,
                            progress: aggregateProgress,
                            emitted: shouldEmit,
                            now: callbackTime
                        )
                        guard shouldEmit else {
                            return
                        }
                        Task { @MainActor in
                            self.downloadDiagnostics.recordMainActorUpdate(
                                modelID: modelID,
                                progress: aggregateProgress,
                                enqueuedAt: callbackTime
                            )
                            self.setDownloadProgress(
                                aggregateProgress,
                                speedBytesPerSecond: speed,
                                for: modelID
                            )
                        }
                    }
                    completedBytes += effectiveFileBytes
                }
                return
            } catch {
                if error is CancellationError { throw error }
                let failure = classifyDownloadError(error, for: model)
                if failure.reason == .network && attempt < maxAttempts {
                    let delaySeconds = pow(2.0, Double(attempt - 1)) * 0.8
                    let delay = UInt64(delaySeconds * 1_000_000_000)
                    try await Task.sleep(nanoseconds: delay)
                    continue
                }
                throw error
            }
        }
    }
    #endif

    private func setDownloadProgress(_ progress: Double, speedBytesPerSecond: Double?, for modelID: String) {
        guard let idx = models.firstIndex(where: { $0.id == modelID }) else { return }
        let clampedProgress = max(0.0, min(progress, 0.99))

        if case .downloading(let currentProgress, let currentSpeed) = models[idx].downloadState,
           clampedProgress <= currentProgress {
            if speedBytesPerSecond != currentSpeed {
                models[idx].downloadState = .downloading(
                    progress: currentProgress,
                    speedBytesPerSecond: speedBytesPerSecond
                )
            }
            return
        }

        models[idx].downloadState = .downloading(
            progress: clampedProgress,
            speedBytesPerSecond: speedBytesPerSecond
        )
    }
    
    private func checkAvailability() async {
        // Check Apple Foundation availability
        if let index = models.firstIndex(where: { $0.engine == .appleFoundation }) {
            let availability = AppleFoundationModelBridge().availability
            if availability == .available {
                models[index].downloadState = .builtin
            } else {
                let message = availability.modelStateMessage
                models[index].downloadState = .error(message: message)
            }
        }
        
        #if targetEnvironment(simulator)
        // Mark MLX models as unavailable on simulator
        for (index, model) in models.enumerated() {
            if model.engine == .mlx {
                let failure = simulatorUnsupportedFailure()
                downloadFailures[model.id] = failure
                models[index].downloadState = .error(message: failure.message)
            }
        }
        #else
        // Check MLX model downloads on real device
        for (index, model) in models.enumerated() {
            if model.engine == .mlx {
                let migrated = migrateLegacyModelIfNeeded(modelID: model.id)
                if migrated || MLXStorage.hasValidModelArtifacts(for: model.id) {
                    if MLXStorage.hasValidModelArtifacts(for: model.id) {
                        models[index].downloadState = .downloaded
                        downloadFailures.removeValue(forKey: model.id)
                    } else {
                        let failure = corruptedFailure()
                        downloadFailures[model.id] = failure
                        models[index].downloadState = .error(message: failure.message)
                    }
                } else {
                    models[index].downloadState = .notDownloaded
                    downloadFailures.removeValue(forKey: model.id)
                }
            }
        }
        #endif
        
        ensureSelection()
    }
    
    #if !targetEnvironment(simulator)
    private func persistModelIfNeeded(modelID: String) {
        let persistentPath = MLXStorage.modelDirectory(for: modelID)
        if FileManager.default.fileExists(atPath: persistentPath.path) { return }

        let legacyCandidates = [
            MLXStorage.legacyModelDirectory(for: modelID),
            MLXStorage.legacyHubModelDirectory(for: modelID),
            MLXStorage.legacyDocumentsModelDirectory(for: modelID)
        ]

        for legacyPath in legacyCandidates {
            if FileManager.default.fileExists(atPath: legacyPath.path) {
                MLXStorage.ensurePersistentDirectories()
                let parent = persistentPath.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                do {
                    try FileManager.default.moveItem(at: legacyPath, to: persistentPath)
                    return
                } catch {
                    try? FileManager.default.copyItem(at: legacyPath, to: persistentPath)
                    if FileManager.default.fileExists(atPath: persistentPath.path) {
                        return
                    }
                }
            }
        }
    }

    private func migrateLegacyModelIfNeeded(modelID: String) -> Bool {
        let persistentPath = MLXStorage.modelDirectory(for: modelID)
        if FileManager.default.fileExists(atPath: persistentPath.path) { return true }
        let legacyCandidates = [
            MLXStorage.legacyModelDirectory(for: modelID),
            MLXStorage.legacyHubModelDirectory(for: modelID),
            MLXStorage.legacyDocumentsModelDirectory(for: modelID)
        ]

        for legacyPath in legacyCandidates {
            if FileManager.default.fileExists(atPath: legacyPath.path) {
                MLXStorage.ensurePersistentDirectories()
                let parent = persistentPath.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                do {
                    try FileManager.default.moveItem(at: legacyPath, to: persistentPath)
                    return true
                } catch {
                    try? FileManager.default.copyItem(at: legacyPath, to: persistentPath)
                    if FileManager.default.fileExists(atPath: persistentPath.path) {
                        return true
                    }
                }
            }
        }

        return false
    }
    #endif
}

 extension ModelManager {
    private func ensureModelPreferences(for model: ModelInfo) {
        guard model.supportsThinkingToggle else { return }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: model.thinkingPreferenceKey) == nil {
            defaults.set(model.defaultThinkingEnabled, forKey: model.thinkingPreferenceKey)
        }
    }

    func ensureSelection() {
        if let selectedID = selectedModelID,
           let selectedIndex = models.firstIndex(where: { $0.id == selectedID }) {
            let selected = models[selectedIndex]
            ensureModelPreferences(for: selected)
            if isModelUsable(selected) { return }
            #if !targetEnvironment(simulator)
            // During startup, the model state can still be stale (.notDownloaded) until
            // async availability checks complete. Preserve the persisted selection when
            // valid model artifacts already exist on disk.
            if selected.engine == .mlx && MLXStorage.hasValidModelArtifacts(for: selected.id) {
                models[selectedIndex].downloadState = .downloaded
                downloadFailures.removeValue(forKey: selected.id)
                return
            }
            #endif
        }
        
        if autoSelectBestModel {
            selectedModelID = bestAvailableModel()?.id
        } else {
            selectedModelID = availableModels.first?.id
        }
    }

    func isModelUsable(_ model: ModelInfo) -> Bool {
        if model.engine == .appleFoundation {
            return isAppleIntelligenceAvailable
        }
        if compatibilityMessage(for: model) != nil {
            return false
        }
        return model.downloadState.isDownloaded
    }

    func bestAvailableModel() -> ModelInfo? {
        if let apple = models.first(where: { $0.engine == .appleFoundation && isModelUsable($0) }) {
            return apple
        }
        let downloadedMLX = models
            .filter { $0.engine == .mlx && isModelUsable($0) }
            .sorted { $0.sizeGB > $1.sizeGB }
        return downloadedMLX.first
    }

    func bestDownloadedFreeModel() -> ModelInfo? {
        if let apple = models.first(where: { $0.id == ModelInfo.appleFoundation.id && isModelUsable($0) }) {
            return apple
        }

        return models
            .filter { MonetizationManager.freeModelIDs.contains($0.id) }
            .filter(isModelUsable)
            .sorted { lhs, rhs in
                if lhs.sizeGB != rhs.sizeGB {
                    return lhs.sizeGB > rhs.sizeGB
                }
                return lhs.name < rhs.name
            }
            .first
    }

    func isOnboardingRecommended(_ model: ModelInfo) -> Bool {
        onboardingRecommendation()?.modelID == model.id
    }

    func deviceFitSummary(for model: ModelInfo) -> String {
        switch model.currentDeviceFit {
        case .recommended:
            return model.isAppleFoundation ? "Best" : "Recommended"
        case .supported:
            return "Should run well on this device"
        case .unsupported:
            return "Too heavy for this device"
        }
    }

    func quickTestResult(for modelID: String) -> ModelQuickTestResult? {
        ModelHealthStore.shared.loadResults()[modelID]
    }

    func saveQuickTestResult(_ result: ModelQuickTestResult) {
        ModelHealthStore.shared.saveResult(result)
    }

    func shouldShowModelInCatalog(_ model: ModelInfo) -> Bool {
        if model.engine == .appleFoundation {
            return isAppleIntelligenceDeviceSupported
        }
        // Mac-experimental models (e.g. GLM 5.1) are only shown on macOS
        if model.isMacExperimental {
            #if targetEnvironment(macCatalyst)
            return true
            #else
            return UIDevice.current.userInterfaceIdiom == .mac
            #endif
        }
        return compatibilityMessage(for: model) == nil
    }

    func compatibilityMessage(for model: ModelInfo) -> String? {
        guard model.engine == .mlx else { return nil }
        let idiom = UIDevice.current.userInterfaceIdiom
        if idiom == .phone && model.requiresLargeDeviceOnPhone {
            return "Requires an iPad Pro or Mac. This model exceeds the practical memory budget for iPhone."
        }
        return nil
    }

    private func recommendation(
        for model: ModelInfo,
        title: String,
        summary: String,
        detail: String,
        actionTitle: String,
        prefersImmediateUse: Bool,
        usesFallback: Bool
    ) -> OnboardingRecommendation {
        OnboardingRecommendation(
            modelID: model.id,
            title: title,
            summary: summary,
            detail: detail,
            actionTitle: actionTitle,
            prefersImmediateUse: prefersImmediateUse,
            usesFallback: usesFallback
        )
    }
}
