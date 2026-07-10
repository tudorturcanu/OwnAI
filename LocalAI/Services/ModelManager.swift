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

private final class DownloadProgressLimiter: @unchecked Sendable {
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

private final class DownloadDiagnostics: @unchecked Sendable {
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
        states[modelID] = state
    }

    func finish(modelID: String, finalProgress: Double, now: CFTimeInterval = CACurrentMediaTime()) {
        lock.lock()
        defer { lock.unlock() }

        _ = states.removeValue(forKey: modelID)
    }

    func cancel(modelID: String, now: CFTimeInterval = CACurrentMediaTime()) {
        lock.lock()
        defer { lock.unlock() }

        _ = states.removeValue(forKey: modelID)
    }

    func fail(modelID: String, message: String, now: CFTimeInterval = CACurrentMediaTime()) {
        lock.lock()
        defer { lock.unlock() }

        _ = states.removeValue(forKey: modelID)
    }

    private static func byteString(_ bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes.rounded()), countStyle: .file)
    }
}

/// Coalesces Hub snapshot progress callbacks into batched MainActor updates (yield + drain loop),
/// avoiding a `Task { @MainActor }` per progress tick (which can schedule hundreds of tasks/sec).
private final class MainActorProgressCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (progress: Double, speed: Double?, enqueuedAt: CFTimeInterval)?
    private var scheduled = false

    private let modelID: String
    private weak var manager: ModelManager?

    init(modelID: String, manager: ModelManager) {
        self.modelID = modelID
        self.manager = manager
    }

    nonisolated func enqueue(progress: Double, speed: Double?, enqueuedAt: CFTimeInterval) {
        lock.lock()
        latest = (progress, speed, enqueuedAt)
        if scheduled {
            lock.unlock()
            return
        }
        scheduled = true
        lock.unlock()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            while true {
                self.lock.lock()
                guard let snap = self.latest else {
                    self.scheduled = false
                    self.lock.unlock()
                    return
                }
                self.latest = nil
                self.lock.unlock()

                guard let manager = self.manager else {
                    self.lock.lock()
                    self.scheduled = false
                    self.lock.unlock()
                    return
                }
                manager.applyCoalescedDownloadProgress(
                    modelID: self.modelID,
                    progress: snap.0,
                    speed: snap.1,
                    enqueuedAt: snap.2
                )
                await Task.yield()
            }
        }
    }

    nonisolated func cancel() {
        lock.lock()
        latest = nil
        scheduled = false
        lock.unlock()
    }
}

enum DownloadErrorAction {
    case retry
    case freeSpace
    case repair
    case cellularRestricted

    var iconName: String {
        switch self {
        case .retry:
            return "arrow.clockwise"
        case .freeSpace:
            return "externaldrive.badge.exclamationmark"
        case .repair:
            return "wrench.and.screwdriver"
        case .cellularRestricted:
            return "wifi.slash"
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
        case .cellularRestricted:
            return "Back"
        }
    }
}

enum ModelUseCase: String, CaseIterable, Identifiable {
    case fast
    case quality
    case documents
    case images
    case coding
    case offlinePrivacy

    var id: String { rawValue }
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
        "added_tokens.json",
        "tokenizer.model",
        "tekken.json",
        "sentencepiece.bpe.model",
        "vocab.json",
        "merges.txt",
        "special_tokens_map.json",
        "generation_config.json",
        "chat_template.json",
        "chat_template.jinja",
        "processor_config.json",
        "preprocessor_config.json",
        "image_processor_config.json",
        "optiq_metadata.json",
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

    struct UseCaseRecommendation: Identifiable, Equatable {
        let useCase: ModelUseCase
        let modelID: String
        let title: String
        let summary: String
        let detail: String
        let symbolName: String

        var id: String { useCase.id }
    }

    struct DownloadReadiness: Equatable {
        let modelSizeText: String
        let requiredSpaceText: String
        let availableSpaceText: String
        let hasEnoughSpace: Bool
        let networkText: String
        let networkIconName: String
        let isNetworkWarning: Bool
        let offlineText: String
    }

    private enum DownloadFailureReason: Equatable {
        case lowStorage(requiredGB: Double, availableGB: Double)
        case cellularRestricted
        case network
        case corrupted
        case incomplete(missingRequirements: [String])
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
    private var allowCellularDownloads: Bool {
        UserDefaults.standard.bool(forKey: "downloads.allowCellular")
    }
    
    
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var backgroundTaskIDs: [String: UIBackgroundTaskIdentifier] = [:]
    private var downloadFailures: [String: DownloadFailure] = [:]
    /// Thread-safe helpers; only accessed from Hub callbacks / download work (off MainActor).
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
            return String(localized: "Apple Intelligence is not available.")
        }
        if case .error(let message) = appleModel.downloadState {
            switch message {
            case "Device not supported":
                return String(localized: "Apple Intelligence is not supported on this device. You can use a downloadable model instead.")
            case "Not enabled":
                return String(localized: "Enable Apple Intelligence in Settings > Apple Intelligence.")
            case "Model not ready":
                return String(localized: "Apple Intelligence is still preparing. Please try again later.")
            default:
                return String(localized: "Apple Intelligence is currently unavailable.")
            }
        }
        return String(localized: "Apple Intelligence is currently unavailable.")
    }
    
    // MARK: - Initialization
    
    init() {
        selectedModelID = persistedSelectedModelID
        ensureSelection()
        Task {
            await checkAvailability()
        }
        
        // Initialize network monitor early so path is more likely to be resolved before user taps download
        _ = DownloadNetworkMonitor.shared
        
        // Warn user when app goes to background during an active download
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNetworkRestrictionChange),
            name: .downloadNetworkRestrictionDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Public Methods
    
    /// Select a specific model to use
    func selectModel(_ modelID: String) {
        if let model = models.first(where: { $0.id == modelID }),
           compatibilityMessage(for: model) != nil {
            ensureSelection()
            return
        }
        // A deliberate pick overrides automatic selection until re-enabled.
        autoSelectBestModel = false
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
                title: String(localized: "Recommended"),
                summary: String(localized: "Already ready on this device."),
                detail: downloadedBest.engine == .appleFoundation
                    ? String(localized: "Apple Intelligence is available now, so you can start chatting without downloading anything.")
                    : String(format: String(localized: "%@ is already available locally, so it will get you to the first reply fastest.", defaultValue: "%@ is already available locally, so it will get you to the first reply fastest."), downloadedBest.name),
                actionTitle: String(format: String(localized: "Use %@", defaultValue: "Use %@"), downloadedBest.name),
                prefersImmediateUse: true,
                usesFallback: false
            )
        }

        if isAppleIntelligenceAvailable {
            return recommendation(
                for: .appleFoundation,
                title: String(localized: "Recommended"),
                summary: String(localized: "Fastest start with no download."),
                detail: String(localized: "Apple Intelligence is available now, so you can begin immediately. For fully local processing, you can still download an on-device model later."),
                actionTitle: String(localized: "Use Apple Intelligence"),
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
        let smallestFreeLocalModel = freeMLXModels.sorted { lhs, rhs in
            if lhs.sizeGB != rhs.sizeGB {
                return lhs.sizeGB < rhs.sizeGB
            }
            return lhs.name < rhs.name
        }.first

        func freeLocalModel(_ model: ModelInfo) -> ModelInfo? {
            freeMLXModels.first { $0.id == model.id }
        }

        if UIDevice.current.userInterfaceIdiom != .phone {
            preferredLocalModel = freeLocalModel(.gemma2_2b_4bit)
                ?? freeMLXModels.sorted { $0.sizeGB > $1.sizeGB }.first
        } else if availableStorage >= requiredSpaceGB(for: .qwen25_3b_instruct_4bit)
                    && ModelInfo.qwen25_3b_instruct_4bit.currentDeviceFit != .unsupported,
                  let qwen25_3b = freeLocalModel(.qwen25_3b_instruct_4bit) {
            preferredLocalModel = qwen25_3b
        } else if availableStorage >= requiredSpaceGB(for: .gemma2_2b_4bit)
                    && ModelInfo.gemma2_2b_4bit.currentDeviceFit != .unsupported,
                  let gemma2 = freeLocalModel(.gemma2_2b_4bit) {
            preferredLocalModel = gemma2
        } else if availableStorage >= requiredSpaceGB(for: .gemma3_1b_qat_4bit),
                  let gemma3_1b = freeLocalModel(.gemma3_1b_qat_4bit) {
            preferredLocalModel = gemma3_1b
        } else {
            preferredLocalModel = smallestFreeLocalModel
        }

        if let preferredLocalModel {
            let detail: String
            if preferredLocalModel.id == ModelInfo.qwen25_3b_instruct_4bit.id {
                detail = "This device should handle \(preferredLocalModel.name) well, and it gives you a noticeably better quality baseline while staying a reasonable download size."
            } else if preferredLocalModel.id == ModelInfo.gemma2_2b_4bit.id {
                detail = "This device should handle \(preferredLocalModel.name) well, and it gives a better quality baseline than the ultra-small models."
            } else if preferredLocalModel.id == ModelInfo.gemma3_1b_qat_4bit.id {
                detail = "\(preferredLocalModel.name) keeps the download light while still fitting comfortably on this device."
            } else {
                detail = "\(preferredLocalModel.name) is the safest local starting point when storage or device headroom is tighter."
            }

            return recommendation(
                for: preferredLocalModel,
                title: String(localized: "Recommended"),
                summary: String(format: String(localized: "%@ download, fully on-device.", defaultValue: "%@ download, fully on-device."), preferredLocalModel.sizeLabel),
                detail: detail,
                actionTitle: preferredLocalModel.downloadState.isDownloaded
                    ? String(format: String(localized: "Use %@", defaultValue: "Use %@"), preferredLocalModel.name)
                    : String(format: String(localized: "Download %@", defaultValue: "Download %@"), preferredLocalModel.name),
                prefersImmediateUse: preferredLocalModel.downloadState.isDownloaded,
                usesFallback: false
            )
        }

        guard let fallback = bestAvailableModel() ?? smallestFreeLocalModel else {
            return nil
        }

        return recommendation(
            for: fallback,
            title: String(localized: "Recommended"),
            summary: String(localized: "Using the best available fallback."),
            detail: String(localized: "A first-choice starter model is not available right now, so this fallback keeps onboarding moving instead of leaving you without a usable model."),
            actionTitle: String(localized: "Continue"),
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
                title: String(localized: "Selected for onboarding"),
                summary: preferredModel.downloadState.isDownloaded || preferredModel.engine == .appleFoundation
                    ? String(localized: "Using your selected model.")
                    : String(format: String(localized: "%@ download selected.", defaultValue: "%@ download selected."), preferredModel.sizeLabel),
                detail: deviceFitSummary(for: preferredModel),
                actionTitle: preferredModel.downloadState.isDownloaded || preferredModel.engine == .appleFoundation
                    ? String(format: String(localized: "Use %@", defaultValue: "Use %@"), preferredModel.name)
                    : String(format: String(localized: "Download %@", defaultValue: "Download %@"), preferredModel.name),
                prefersImmediateUse: preferredModel.downloadState.isDownloaded || preferredModel.engine == .appleFoundation,
                usesFallback: false
            )
            return applyOnboardingChoice(using: recommendation)
        }

        guard let recommendation = onboardingRecommendation() else {
            ensureSelection()
            return nil
        }

        return applyOnboardingChoice(using: recommendation)
    }

    @discardableResult
    private func applyOnboardingChoice(using recommendation: OnboardingRecommendation) -> OnboardingRecommendation? {
        guard let model = models.first(where: { $0.id == recommendation.modelID }) else {
            ensureSelection()
            return nil
        }

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
        case .cellularRestricted:
            return allowCellularDownloads ? .retry : .cellularRestricted
        case .corrupted:
            return .repair
        case .incomplete:
            return .repair
        case .network, .simulatorUnsupported, .unknown:
            return .retry
        }
    }

    func downloadReadiness(for model: ModelInfo) -> DownloadReadiness? {
        guard model.engine == .mlx else { return nil }

        let availableGB = DiskSpace.availableGB()
        let requiredGB = requiredSpaceGB(for: model)
        let hasEnoughSpace = availableGB + 0.001 >= requiredGB
        let isCellularRestricted = DownloadNetworkMonitor.shared.isCellularRestricted

        let networkText: String
        let networkIconName: String
        let isNetworkWarning: Bool
        if allowCellularDownloads {
            networkText = String(localized: "Wi-Fi or cellular download allowed.")
            networkIconName = "antenna.radiowaves.left.and.right"
            isNetworkWarning = false
        } else if isCellularRestricted {
            networkText = String(localized: "Connect to Wi-Fi, or enable Cellular Downloads in Settings.")
            networkIconName = "wifi.exclamationmark"
            isNetworkWarning = true
        } else {
            networkText = String(localized: "Cellular downloads are off; use Wi-Fi if this network changes.")
            networkIconName = "wifi"
            isNetworkWarning = false
        }

        return DownloadReadiness(
            modelSizeText: model.sizeLabel,
            requiredSpaceText: String(format: String(localized: "%.1f GB needed", defaultValue: "%.1f GB needed"), requiredGB),
            availableSpaceText: String(format: String(localized: "%.1f GB free", defaultValue: "%.1f GB free"), availableGB),
            hasEnoughSpace: hasEnoughSpace,
            networkText: networkText,
            networkIconName: networkIconName,
            isNetworkWarning: isNetworkWarning,
            offlineText: String(localized: "Works offline after download. Prompts stay on-device for inference.")
        )
    }

    func useCaseRecommendations() -> [UseCaseRecommendation] {
        ModelUseCase.allCases.compactMap { recommendation(for: $0) }
    }

    func recommendation(for useCase: ModelUseCase) -> UseCaseRecommendation? {
        let candidateIDs: [String]
        let title: String
        let summary: String
        let detail: String
        let symbolName: String

        switch useCase {
        case .fast:
            candidateIDs = [
                ModelInfo.appleFoundation.id,
                ModelInfo.gemma3_1b_qat_4bit.id,
                ModelInfo.gemma2_2b_4bit.id
            ]
            title = String(localized: "Fast")
            summary = String(localized: "Shortest wait, lightest model.")
            detail = String(localized: "Good for quick questions, short drafts, and Watch requests.")
            symbolName = "bolt.fill"

        case .quality:
            candidateIDs = [
                ModelInfo.qwen35_4b_optiq_4bit.id,
                ModelInfo.qwen25_3b_instruct_4bit.id,
                ModelInfo.gemma2_2b_4bit.id,
                ModelInfo.gemma3_1b_qat_4bit.id,
                ModelInfo.appleFoundation.id
            ]
            title = String(localized: "Best Quality")
            summary = String(localized: "Stronger answers when you can wait.")
            detail = String(localized: "Best for writing, reasoning, and longer responses.")
            symbolName = "sparkles"

        case .documents:
            candidateIDs = [
                ModelInfo.qwen25_3b_instruct_4bit.id,
                ModelInfo.gemma2_2b_4bit.id,
                ModelInfo.qwen35_2b_optiq_4bit.id,
                ModelInfo.gemma3_1b_qat_4bit.id,
                ModelInfo.appleFoundation.id
            ]
            title = String(localized: "Documents")
            summary = String(localized: "Better for PDFs and source-backed answers.")
            detail = String(localized: "Prioritizes models that handle longer context and summaries well.")
            symbolName = "doc.text.magnifyingglass"

        case .images:
            candidateIDs = [
                ModelInfo.lfm25_vl_450m_6bit.id,
                ModelInfo.qwen2VL_2b_4bit.id,
                ModelInfo.qwen25VL_3b_3bit.id,
                ModelInfo.smolVLM2_500m_4bit.id,
                ModelInfo.appleFoundation.id
            ]
            title = String(localized: "Images")
            summary = String(localized: "Inspect photos and screenshots.")
            detail = String(localized: "Picks a vision-capable model when this device can run one.")
            symbolName = "photo.on.rectangle.angled"

        case .coding:
            candidateIDs = [
                ModelInfo.qwen3_coder_next_4bit.id,
                ModelInfo.qwen25_7b_instruct_4bit.id,
                ModelInfo.qwen25_3b_instruct_4bit.id,
                ModelInfo.gemma2_2b_4bit.id,
                ModelInfo.appleFoundation.id
            ]
            title = String(localized: "Coding")
            summary = String(localized: "Better for code explanations and fixes.")
            detail = String(localized: "Chooses a stronger technical model when available.")
            symbolName = "terminal"

        case .offlinePrivacy:
            candidateIDs = [
                ModelInfo.gemma2_2b_4bit.id,
                ModelInfo.gemma3_1b_qat_4bit.id
            ]
            title = String(localized: "Offline Privacy")
            summary = String(localized: "Fully local after download.")
            detail = String(localized: "Keeps prompts, documents, and replies on this device for inference.")
            symbolName = "lock.shield.fill"
        }

        guard let model = bestUseCaseModel(from: candidateIDs) else { return nil }
        return UseCaseRecommendation(
            useCase: useCase,
            modelID: model.id,
            title: title,
            summary: summary,
            detail: detail,
            symbolName: symbolName
        )
    }

    @objc
    private func handleWillResignActive() {
        guard downloadNotifications else { return }
        guard let activeModelID = downloadTasks.keys.first,
              let model = models.first(where: { $0.id == activeModelID }) else { return }
        NotificationManager.shared.postDownloadBackgroundWarning(modelName: model.name)
    }

    @objc
    private func handleNetworkRestrictionChange() {
        if !allowCellularDownloads, DownloadNetworkMonitor.shared.isCellularRestricted {
            let activeIDs = Array(downloadTasks.keys)
            for modelID in activeIDs {
                cancelDownload(modelID)
                applyDownloadFailure(cellularRestrictedFailure(), for: modelID)
            }
        }
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

        if let _ = cellularRestrictionFailureIfNeeded(allowCellular: allowCellularDownloads) {
            NotificationCenter.default.post(name: .cellularDownloadRestricted, object: nil)
            return
        }
        
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

        let progressCoalescer = MainActorProgressCoalescer(modelID: modelID, manager: self)
        let notifyDownloads = downloadNotifications
        let modelName = model.name

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.performDownloadWork(
                modelID: modelID,
                model: model,
                modelName: modelName,
                downloadNotifications: notifyDownloads,
                selectWhenFinished: selectWhenFinished,
                progressCoalescer: progressCoalescer
            )
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

    /// Runs Hub/URL work off the main actor; UI/state updates hop to `MainActor` explicitly.
    nonisolated private func performDownloadWork(
        modelID: String,
        model: ModelInfo,
        modelName: String,
        downloadNotifications: Bool,
        selectWhenFinished: Bool,
        progressCoalescer: MainActorProgressCoalescer
    ) async {
        defer {
            progressCoalescer.cancel()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadTasks.removeValue(forKey: modelID)
                self.downloadProgressLimiter.reset(modelID: modelID)
                self.updateIdleTimer()
                self.endBackgroundTask(for: modelID)
            }
        }

        #if targetEnvironment(simulator)
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.applyDownloadFailure(self.simulatorUnsupportedFailure(), for: modelID)
        }
        #else
        do {
            try await downloadModelContainerWithRetry(
                modelID: modelID,
                model: model,
                progressCoalescer: progressCoalescer
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let idx = self.models.firstIndex(where: { $0.id == modelID }) {
                    self.models[idx].downloadState = .validating(progress: 0.99)
                }
            }
            persistModelIfNeeded(modelID: modelID)
            let validation = MLXStorage.validationReport(for: modelID)
            guard validation.isValid else {
                throw DownloadFailureError(failure: incompleteArtifactsFailure(validation))
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let idx = self.models.firstIndex(where: { $0.id == modelID }) {
                    self.models[idx].downloadState = .downloaded
                }
                self.downloadFailures.removeValue(forKey: modelID)
            }
            if downloadNotifications {
                await MainActor.run {
                    NotificationManager.shared.postDownloadCompleted(modelName: modelName)
                }
            }
            downloadDiagnostics.finish(modelID: modelID, finalProgress: 1.0)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if selectWhenFinished || self.selectedModelID == nil {
                    self.selectedModelID = modelID
                }
            }
        } catch is CancellationError {
            downloadDiagnostics.cancel(modelID: modelID)
            cleanupIncompleteArtifactsIfNeeded(modelID: modelID)
        } catch let failureError as DownloadFailureError {
            downloadDiagnostics.fail(modelID: modelID, message: failureError.failure.message)
            cleanupArtifactsIfNeeded(after: failureError.failure, modelID: modelID)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applyDownloadFailure(failureError.failure, for: modelID)
            }
            if downloadNotifications {
                await MainActor.run {
                    NotificationManager.shared.postDownloadFailed(modelName: modelName, errorMessage: failureError.failure.message)
                }
            }
        } catch {
            let failure = classifyDownloadError(error, for: model)
            downloadDiagnostics.fail(modelID: modelID, message: failure.message)
            cleanupArtifactsIfNeeded(after: failure, modelID: modelID)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applyDownloadFailure(failure, for: modelID)
            }
            if downloadNotifications {
                await MainActor.run {
                    NotificationManager.shared.postDownloadFailed(modelName: modelName, errorMessage: failure.message)
                }
            }
        }
        #endif
    }

    private func applyDownloadFailure(_ failure: DownloadFailure, for modelID: String) {
        downloadFailures[modelID] = failure
        if let index = models.firstIndex(where: { $0.id == modelID }) {
            models[index].downloadState = .error(message: failure.message)
        }
    }

    nonisolated private func cellularRestrictionFailureIfNeeded(allowCellular: Bool) -> DownloadFailure? {
        guard !allowCellular else { return nil }
        guard DownloadNetworkMonitor.shared.isCellularRestricted else { return nil }
        return cellularRestrictedFailure()
    }

    nonisolated private func requiredSpaceGB(for model: ModelInfo) -> Double {
        max(model.sizeGB * 1.15, model.sizeGB + 0.35)
    }

    nonisolated private func preflightFailure(for model: ModelInfo) -> DownloadFailure? {
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

    nonisolated private func simulatorUnsupportedFailure() -> DownloadFailure {
        DownloadFailure(reason: .simulatorUnsupported, message: "Simulator not supported")
    }

    nonisolated private func cellularRestrictedFailure() -> DownloadFailure {
        DownloadFailure(
            reason: .cellularRestricted,
            message: "Cellular Downloads is off. Connect to Wi-Fi or turn it on in Settings."
        )
    }

    nonisolated private func corruptedFailure() -> DownloadFailure {
        DownloadFailure(
            reason: .corrupted,
            message: "Model files are incomplete or corrupted. Tap Repair to re-download."
        )
    }

    nonisolated private func incompleteArtifactsFailure(_ report: MLXStorage.ArtifactValidationReport) -> DownloadFailure {
        DownloadFailure(
            reason: .incomplete(missingRequirements: report.missingRequirements),
            message: report.missingRequirements.isEmpty
                ? "Model files were not found after download. Tap Repair to re-download."
                : "\(report.message) Tap Repair to re-download."
        )
    }

    nonisolated private func classifyDownloadError(_ error: Error, for model: ModelInfo) -> DownloadFailure {
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

    nonisolated private func isLikelyNetworkError(message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("network")
            || lower.contains("internet")
            || lower.contains("offline")
            || lower.contains("timed out")
            || lower.contains("could not connect")
            || lower.contains("connection")
    }

    nonisolated private func isLikelyCorruptionError(message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("checksum")
            || lower.contains("corrupt")
            || lower.contains("invalid")
            || lower.contains("unexpected eof")
            || lower.contains("tokenizer")
            || lower.contains("safetensors")
    }

    nonisolated private func cleanupArtifactsIfNeeded(after failure: DownloadFailure, modelID: String) {
        switch failure.reason {
        case .network, .cellularRestricted, .simulatorUnsupported:
            return
        case .lowStorage, .corrupted, .incomplete, .unknown:
            cleanupIncompleteArtifactsIfNeeded(modelID: modelID)
        }
    }

    nonisolated private func cleanupIncompleteArtifactsIfNeeded(modelID: String) {
        #if !targetEnvironment(simulator)
        MLXStorage.removeIncompleteModelArtifacts(for: modelID)
        #endif
    }

    #if !targetEnvironment(simulator)
    nonisolated private func downloadModelContainerWithRetry(
        modelID: String,
        model: ModelInfo,
        progressCoalescer: MainActorProgressCoalescer
    ) async throws {
        let maxAttempts = 3
        let hub = makeHubApi()

        do {
            try await runSnapshotDownload(
                hub: hub,
                modelID: modelID,
                matching: Self.requiredMLXDownloadGlobs,
                maxAttempts: maxAttempts,
                model: model,
                progressCoalescer: progressCoalescer
            )
            return
        } catch {
            if error is CancellationError { throw error }
            let failure = classifyDownloadError(error, for: model)
            let shouldTryFullRepoFallback = failure.reason == .corrupted || failure.reason == .unknown
            if !shouldTryFullRepoFallback {
                throw DownloadFailureError(failure: failure)
            }
        }

        do {
            try await runSnapshotDownload(
                hub: hub,
                modelID: modelID,
                matching: [],
                maxAttempts: maxAttempts,
                model: model,
                progressCoalescer: progressCoalescer
            )
            return
        } catch {
            if error is CancellationError { throw error }
            let failure = classifyDownloadError(error, for: model)
            throw DownloadFailureError(failure: failure)
        }
    }

    nonisolated private func makeHubApi() -> HubApi {
        return HubApi(downloadBase: MLXStorage.persistentBaseURL().deletingLastPathComponent())
    }

    nonisolated private func runSnapshotDownload(
        hub: HubApi,
        modelID: String,
        matching globs: [String],
        maxAttempts: Int,
        model: ModelInfo,
        progressCoalescer: MainActorProgressCoalescer
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
                        progressCoalescer.enqueue(
                            progress: aggregateProgress,
                            speed: speed,
                            enqueuedAt: callbackTime
                        )
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

    /// Called from `MainActorProgressCoalescer` on the main actor (single entry point for coalesced UI updates).
    fileprivate func applyCoalescedDownloadProgress(
        modelID: String,
        progress: Double,
        speed: Double?,
        enqueuedAt: CFTimeInterval
    ) {
        downloadDiagnostics.recordMainActorUpdate(
            modelID: modelID,
            progress: progress,
            enqueuedAt: enqueuedAt
        )
        setDownloadProgress(progress, speedBytesPerSecond: speed, for: modelID)
    }

    private func setDownloadProgress(_ progress: Double, speedBytesPerSecond: Double?, for modelID: String) {
        guard let idx = models.firstIndex(where: { $0.id == modelID }) else { return }
        let clampedProgress = max(0.0, min(progress, 0.99))

        guard case .downloading(let currentProgress, let currentSpeed) = models[idx].downloadState else {
            return
        }

        if clampedProgress <= currentProgress {
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
                    let validation = MLXStorage.validationReport(for: model.id)
                    if validation.isValid {
                        models[index].downloadState = .downloaded
                        downloadFailures.removeValue(forKey: model.id)
                    } else {
                        let failure = incompleteArtifactsFailure(validation)
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
    nonisolated private func persistModelIfNeeded(modelID: String) {
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
            if selected.engine == .mlx,
               compatibilityMessage(for: selected) == nil,
               MLXStorage.hasValidModelArtifacts(for: selected.id) {
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
        // Prefer models that actually fit this device before rewarding size:
        // the largest downloaded model is the slowest choice on older hardware.
        func fitRank(_ model: ModelInfo) -> Int {
            switch model.currentDeviceFit {
            case .recommended: return 0
            case .supported: return 1
            case .unsupported: return 2
            }
        }
        return models
            .filter { $0.engine == .mlx && isModelUsable($0) }
            .sorted {
                if fitRank($0) != fitRank($1) { return fitRank($0) < fitRank($1) }
                return $0.sizeGB > $1.sizeGB
            }
            .first
    }

    /// Turns automatic selection on and immediately applies the best pick.
    /// Distinct from `selectModel`, which records a deliberate manual choice.
    func enableAutomaticSelection() {
        autoSelectBestModel = true
        if let best = bestAvailableModel() {
            selectedModelID = best.id
        }
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

    private func bestUseCaseModel(from candidateIDs: [String]) -> ModelInfo? {
        let candidates = candidateIDs.compactMap { id in
            models.first { $0.id == id }
        }
        let visibleCandidates = candidates.filter(shouldShowModelInCatalog)

        if let usable = visibleCandidates.first(where: isModelUsable) {
            return usable
        }

        if let downloadable = visibleCandidates.first(where: { model in
            model.engine == .mlx &&
            model.downloadState == .notDownloaded &&
            compatibilityMessage(for: model) == nil
        }) {
            return downloadable
        }

        return visibleCandidates.first
    }

    func isOnboardingRecommended(_ model: ModelInfo) -> Bool {
        onboardingRecommendation()?.modelID == model.id
    }

    func deviceFitSummary(for model: ModelInfo) -> String {
        switch model.currentDeviceFit {
        case .recommended:
            return model.isAppleFoundation ? "Best" : "Recommended"
        case .supported:
            return "Runs on this device, but may be slower"
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
        if model.requiresUnsupportedMLXQuantization {
            return "This model uses 1-bit MLX quantization, which is not supported by the current MLX runtime."
        }
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

extension Notification.Name {
    static let cellularDownloadRestricted = Notification.Name("cellularDownloadRestricted")
}
