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
final class ModelManager {
    private static let requiredMLXDownloadGlobs = MLXStorage.modelArtifactGlobs

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
    
    var models: [ModelInfo] = ModelInfo.allModels + ImportedModelStore.shared.all.map(ModelInfo.imported)
    /// Non-nil while a file import is copying. Drives the progress row in the
    /// model views; imports are foreground work, not background downloads.
    private(set) var importProgress: Double?
    private(set) var lastImportErrorMessage: String?
    /// Identifies the running import so a progress callback that lands after the
    /// import finished cannot leave `importProgress` stuck non-nil — which would
    /// then block every later import.
    private var activeImportID: UUID?
    @ObservationIgnored @AppStorage("selectedModelID") private var persistedSelectedModelID: String?
    /// The last model the user picked by hand. `selectedModelID` tracks whatever
    /// is currently in use, including models the automatic router chooses, so it
    /// cannot answer "what did the user actually ask for" once Auto Mode has run.
    @ObservationIgnored @AppStorage("manualSelectedModelID") private var manualSelectedModelID: String?
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
    var autoModelPreference = AutoModelPreference(
        rawValue: UserDefaults.standard.string(forKey: "autoModelPreference") ?? ""
    ) ?? .balanced {
        didSet {
            UserDefaults.standard.set(autoModelPreference.rawValue, forKey: "autoModelPreference")
        }
    }
    private(set) var autoSelectionRevision = 0
    private(set) var lastAutoSelectionNotice: AutoModelSelectionNotice?
    @ObservationIgnored private var autoSelectionDismissTask: Task<Void, Never>?
    /// How long the auto-selection toast stays on screen before it self-dismisses.
    /// Shared with the view so its progress indicator stays in sync.
    static let autoSelectionNoticeDuration: TimeInterval = 3.5
    @ObservationIgnored @AppStorage("downloadNotifications") var downloadNotifications: Bool = true
    private var allowCellularDownloads: Bool {
        UserDefaults.standard.bool(forKey: "downloads.allowCellular")
    }
    
    
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var downloadTaskIDs: [String: UUID] = [:]
    private var downloadSelectionIntent: [String: Bool] = [:]
    private var chatPausedDownloads: [String: Bool] = [:]
    private var backgroundTaskIDs: [String: UIBackgroundTaskIdentifier] = [:]
    private var downloadFailures: [String: DownloadFailure] = [:]
    private var downloadsWithRollback: Set<String> = []
    var onModelReadyForBenchmark: ((ModelInfo) async -> Void)?
    @ObservationIgnored private weak var monetizationManager: MonetizationManager?
    /// Thread-safe helpers; only accessed from Hub callbacks / download work (off MainActor).
    @ObservationIgnored private let downloadProgressLimiter = DownloadProgressLimiter()
    @ObservationIgnored private let downloadDiagnostics = DownloadDiagnostics()
    private var thinkingPreferencesVersion = 0
    private(set) var modelHealthRevision = 0
    /// Bundled models the user deleted. Their weights stay inside the app, so this
    /// flag is what keeps them out of the catalog until the user adds them back.
    private var removedBundledModelIDs: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: ModelManager.removedBundledModelsKey) ?? []
    )
    private static let removedBundledModelsKey = "models.removedBundled"

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
            if isModelUsable(model), canSelect(model) {
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
        // Reclaim bytes from an import that was killed mid-copy and never
        // registered. Detached because the recovery case deletes a whole model
        // directory, and doing that on the main actor at launch is how you earn
        // a watchdog termination. Safe to race with a fresh import: the store
        // reserves an in-flight folder before any bytes are written.
        Task.detached(priority: .utility) {
            ModelImportService.pruneOrphanedImports()
        }
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

    /// Installs the shared entitlement source used by every model-selection path.
    /// The manager still initializes before the app environment is available, so
    /// selection is revalidated as soon as this dependency is configured.
    func configure(monetizationManager: MonetizationManager) {
        self.monetizationManager = monetizationManager
        ensureSelection()
    }

    func canSelect(_ model: ModelInfo) -> Bool {
        guard let monetizationManager else { return true }
        return !monetizationManager.isPremiumModel(model) || monetizationManager.hasPro
    }
    
    /// Select a specific model to use
    @discardableResult
    func selectModel(_ modelID: String) -> Bool {
        guard let model = models.first(where: { $0.id == modelID }), canSelect(model) else {
            ensureSelection()
            return false
        }
        guard compatibilityMessage(for: model) == nil else {
            ensureSelection()
            return false
        }
        // A deliberate pick overrides automatic selection until re-enabled.
        autoSelectBestModel = false
        autoSelectionRevision += 1
        lastAutoSelectionNotice = nil
        manualSelectedModelID = modelID
        selectedModelID = modelID
        return true
    }

    var isAutomaticSelectionEnabled: Bool {
        _ = autoSelectionRevision
        return autoSelectBestModel
    }

    func setAutoModelPreference(_ preference: AutoModelPreference) {
        autoModelPreference = preference
        autoSelectionRevision += 1
    }

    func isThinkingEnabled(for model: ModelInfo) -> Bool {
        _ = thinkingPreferencesVersion
        return ModelInfo.resolvedThinkingEnabled(modelID: model.id)
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
                ModelInfo.qwen3VL_2b_4bit.id,
                ModelInfo.lfm25_vl_3b_4bit.id,
                ModelInfo.qwen3VL_4b_4bit.id,
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
                ModelInfo.qwen38_27b_4bit.id,
                ModelInfo.devstralSmall2_24b_4bit.id,
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
        // An imported model has no remote source to re-fetch from; repairing it
        // would delete the only copy. The user re-imports instead.
        guard !models[index].isImported else { return }

        cancelDownload(modelID)
        #if targetEnvironment(simulator)
        applyDownloadFailure(simulatorUnsupportedFailure(), for: modelID)
        #else
        if MLXStorage.prepareRollback(for: modelID) {
            downloadsWithRollback.insert(modelID)
        }
        MLXStorage.removeCurrentArtifactsPreservingRollback(for: modelID)
        models[index].downloadState = .notDownloaded
        downloadFailures.removeValue(forKey: modelID)
        ModelHealthStore.shared.removeResult(for: modelID)
        modelHealthRevision += 1
        downloadModel(modelID, selectWhenFinished: selectWhenFinished)
        #endif
    }
    
    /// Start downloading a model
    func downloadModel(_ modelID: String, selectWhenFinished: Bool = false) {
        guard let index = models.firstIndex(where: { $0.id == modelID }) else { return }
        let model = models[index]
        guard model.engine == .mlx else { return }
        guard !model.isImported else { return }
        // A bundled model is never fetched from the network: adding it back just
        // clears the removal flag.
        guard !model.isBundled else {
            restoreBundledModel(modelID, selectWhenFinished: selectWhenFinished)
            return
        }
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
        let taskID = UUID()

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.performDownloadWork(
                modelID: modelID,
                model: model,
                modelName: modelName,
                downloadNotifications: notifyDownloads,
                selectWhenFinished: selectWhenFinished,
                taskID: taskID,
                progressCoalescer: progressCoalescer
            )
        }

        downloadTasks[modelID] = task
        downloadTaskIDs[modelID] = taskID
        downloadSelectionIntent[modelID] = selectWhenFinished
        updateIdleTimer()
        beginBackgroundTask(for: modelID)
    }
    
    /// Cancel an ongoing download
    func cancelDownload(_ modelID: String) {
        downloadTasks[modelID]?.cancel()
        downloadTasks.removeValue(forKey: modelID)
        downloadTaskIDs.removeValue(forKey: modelID)
        downloadSelectionIntent.removeValue(forKey: modelID)
        chatPausedDownloads.removeValue(forKey: modelID)
        downloadFailures.removeValue(forKey: modelID)
        downloadProgressLimiter.reset(modelID: modelID)
        
        if let index = models.firstIndex(where: { $0.id == modelID }) {
            if downloadsWithRollback.contains(modelID), MLXStorage.restoreRollback(for: modelID) {
                downloadsWithRollback.remove(modelID)
                models[index].downloadState = .downloaded
            } else {
                models[index].downloadState = .notDownloaded
            }
        }
        updateIdleTimer()
        endBackgroundTask(for: modelID)
    }

    /// Cancels resumable network work while an answer is being produced. Hub
    /// snapshots retain partial files, so resuming does not discard progress.
    func suspendBackgroundDownloadsForChat() {
        let activeIDs = Array(downloadTasks.keys)
        guard !activeIDs.isEmpty else { return }

        for modelID in activeIDs {
            chatPausedDownloads[modelID] = downloadSelectionIntent[modelID] ?? false
            downloadTasks[modelID]?.cancel()
            downloadTasks.removeValue(forKey: modelID)
            downloadTaskIDs.removeValue(forKey: modelID)
            downloadSelectionIntent.removeValue(forKey: modelID)
            downloadProgressLimiter.reset(modelID: modelID)
            if let index = models.firstIndex(where: { $0.id == modelID }) {
                models[index].downloadState = .notDownloaded
            }
            endBackgroundTask(for: modelID)
        }
        updateIdleTimer()
    }

    func resumeBackgroundDownloadsAfterChat() {
        let paused = chatPausedDownloads
        chatPausedDownloads.removeAll()
        for (modelID, selectWhenFinished) in paused {
            downloadModel(modelID, selectWhenFinished: selectWhenFinished)
        }
    }
    
    /// Delete a downloaded model
    func deleteModel(_ modelID: String) {
        guard let model = models.first(where: { $0.id == modelID }) else { return }
        guard model.engine == .mlx else { return } // Can't delete built-in models

        // The bundled starter's weights ship inside the app, so deleting it only
        // clears a duplicate on-disk copy (left behind by upgrades). Remembering the
        // removal is what actually takes it out of the user's model list.
        if model.isBundled {
            setBundledModel(modelID, removed: true)
        }

        #if !targetEnvironment(simulator)
        MLXStorage.removeModelArtifacts(for: modelID)
        #endif

        if model.isImported {
            // Nothing survives a delete here: unlike a catalog model there is
            // no entry to fall back to, so the row goes away with the files.
            ImportedModelStore.shared.remove(modelID)
            models.removeAll { $0.id == modelID }
            UserDefaults.standard.removeObject(forKey: "modelConsent.\(modelID)")
            UserDefaults.standard.removeObject(forKey: "model.lastUsed.\(modelID)")
        } else if let index = models.firstIndex(where: { $0.id == modelID }) {
            models[index].downloadState = .notDownloaded
        }
        downloadFailures.removeValue(forKey: modelID)
        ModelHealthStore.shared.removeResult(for: modelID)
        modelHealthRevision += 1
        
        // Clear selection if it was deleted
        if selectedModelID == modelID {
            selectedModelID = nil
        }

        ensureSelection()
    }

    // MARK: - Imported Models

    /// Copies a user-supplied MLX checkpoint into model storage and adds it to
    /// the catalog. Returns the new model, or nil when the import failed —
    /// `lastImportErrorMessage` then carries the reason.
    @discardableResult
    func importModel(from urls: [URL], selectWhenFinished: Bool = true) async -> ModelInfo? {
        guard importProgress == nil else { return nil }
        let importID = UUID()
        activeImportID = importID
        lastImportErrorMessage = nil
        importProgress = 0
        defer {
            if activeImportID == importID {
                activeImportID = nil
                importProgress = nil
            }
        }

        do {
            let record = try await ModelImportService.importModel(from: urls) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.activeImportID == importID else { return }
                    self.importProgress = progress
                }
            }
            var model = ModelInfo.imported(record)
            model.downloadState = .downloaded
            models.append(model)
            // The consent sheet exists to surface a model publisher's terms.
            // There is no publisher here — the user supplied the file — so
            // there is nothing to consent to.
            UserDefaults.standard.set(true, forKey: "modelConsent.\(record.id)")
            ensureModelPreferences(for: model)
            if selectWhenFinished {
                selectModel(record.id)
            }
            ensureSelection()
            return model
        } catch {
            lastImportErrorMessage = error.localizedDescription
            return nil
        }
    }

    func clearImportError() {
        lastImportErrorMessage = nil
    }

    /// Imported folders are often named `snapshot` or `models--org--name`, so
    /// the user gets to fix the label without re-importing gigabytes.
    func renameImportedModel(_ modelID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = models.firstIndex(where: { $0.id == modelID }),
              models[index].isImported else { return }
        ImportedModelStore.shared.rename(modelID, to: trimmed)
        guard let record = ImportedModelStore.shared.record(for: modelID) else { return }
        let state = models[index].downloadState
        var renamed = ModelInfo.imported(record)
        renamed.downloadState = state
        models[index] = renamed
    }

    var importedModels: [ModelInfo] {
        models.filter(\.isImported)
    }

    // MARK: - Bundled Models

    /// Whether the user removed a bundled model from their catalog.
    func isBundledModelRemoved(_ modelID: String) -> Bool {
        removedBundledModelIDs.contains(modelID)
    }

    /// Brings a removed bundled model back. Nothing is downloaded: the weights
    /// never left the app, so this is instant.
    func restoreBundledModel(_ modelID: String, selectWhenFinished: Bool = false) {
        guard let index = models.firstIndex(where: { $0.id == modelID }),
              models[index].isBundled else { return }
        setBundledModel(modelID, removed: false)

        #if targetEnvironment(simulator)
        let failure = simulatorUnsupportedFailure()
        downloadFailures[modelID] = failure
        models[index].downloadState = .error(message: failure.message)
        #else
        if MLXStorage.hasValidModelArtifacts(for: modelID) {
            models[index].downloadState = .downloaded
            downloadFailures.removeValue(forKey: modelID)
        } else {
            models[index].downloadState = .notDownloaded
        }
        if selectWhenFinished {
            selectModel(modelID)
        }
        #endif

        ensureSelection()
    }

    private func setBundledModel(_ modelID: String, removed: Bool) {
        if removed {
            removedBundledModelIDs.insert(modelID)
        } else {
            removedBundledModelIDs.remove(modelID)
        }
        UserDefaults.standard.set(Array(removedBundledModelIDs), forKey: ModelManager.removedBundledModelsKey)
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
        taskID: UUID,
        progressCoalescer: MainActorProgressCoalescer
    ) async {
        defer {
            progressCoalescer.cancel()
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.downloadTaskIDs[modelID] == taskID else { return }
                self.downloadTasks.removeValue(forKey: modelID)
                self.downloadTaskIDs.removeValue(forKey: modelID)
                self.downloadSelectionIntent.removeValue(forKey: modelID)
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
                MLXStorage.discardRollback(for: modelID)
                if let idx = self.models.firstIndex(where: { $0.id == modelID }) {
                    self.models[idx].downloadState = .downloaded
                }
                self.downloadFailures.removeValue(forKey: modelID)
                self.downloadsWithRollback.remove(modelID)
            }
            if downloadNotifications {
                await MainActor.run {
                    NotificationManager.shared.postDownloadCompleted(modelName: modelName)
                }
            }
            downloadDiagnostics.finish(modelID: modelID, finalProgress: 1.0)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if (selectWhenFinished || self.selectedModelID == nil), self.canSelect(model) {
                    self.selectedModelID = modelID
                }
                let automaticBenchmarkEnabled =
                    UserDefaults.standard.object(forKey: "models.autoBenchmarkAfterDownload") == nil ||
                    UserDefaults.standard.bool(forKey: "models.autoBenchmarkAfterDownload")
                if DeviceResourcePolicy.current.shouldRunAutomaticModelBenchmarks,
                   automaticBenchmarkEnabled {
                    Task { await self.onModelReadyForBenchmark?(model) }
                }
            }
        } catch is CancellationError {
            downloadDiagnostics.cancel(modelID: modelID)
        } catch let failureError as DownloadFailureError {
            downloadDiagnostics.fail(modelID: modelID, message: failureError.failure.message)
            let hasRollback = await MainActor.run { [weak self] in
                self?.downloadsWithRollback.contains(modelID) == true
            }
            if !hasRollback {
                cleanupArtifactsIfNeeded(after: failureError.failure, modelID: modelID)
            }
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
            let hasRollback = await MainActor.run { [weak self] in
                self?.downloadsWithRollback.contains(modelID) == true
            }
            if !hasRollback {
                cleanupArtifactsIfNeeded(after: failure, modelID: modelID)
            }
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
        if downloadsWithRollback.contains(modelID), MLXStorage.restoreRollback(for: modelID) {
            downloadsWithRollback.remove(modelID)
            downloadFailures.removeValue(forKey: modelID)
            if let index = models.firstIndex(where: { $0.id == modelID }) {
                models[index].downloadState = .downloaded
            }
            return
        }
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
            || lower.contains("integrity")
            || lower.contains("size mismatch")
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
                    let snapshotURL = try await hub.snapshot(from: modelID, matching: [file.filename]) { progress, speed in
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
                    if file.size > 0 {
                        let downloadedURL = snapshotURL.appendingPathComponent(file.filename)
                        let actualSize = (try? downloadedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        guard actualSize == Int(file.size) else {
                            throw NSError(
                                domain: "OwnAI.DownloadIntegrity",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Integrity check failed: file size mismatch for \(file.filename)."]
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
                // A removed bundled model still validates against the app bundle, so
                // honour the user's removal instead of reviving it here.
                if model.isBundled, isBundledModelRemoved(model.id) {
                    models[index].downloadState = .notDownloaded
                    downloadFailures.removeValue(forKey: model.id)
                    continue
                }
                if model.isImported {
                    let validation = MLXStorage.validationReport(for: model.id)
                    if validation.isValid {
                        models[index].downloadState = .downloaded
                        downloadFailures.removeValue(forKey: model.id)
                    } else {
                        // There is no re-download for this one, so say what the
                        // user actually has to do instead of "incomplete".
                        models[index].downloadState = .error(
                            message: "The files for this imported model are missing. Import it again from Files."
                        )
                    }
                    continue
                }
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
            if canSelect(selected) {
                if isModelUsable(selected) { return }
                #if !targetEnvironment(simulator)
                // During startup, the model state can still be stale (.notDownloaded) until
                // async availability checks complete. Preserve the persisted selection when
                // valid model artifacts already exist on disk.
                if selected.engine == .mlx,
                   !isBundledModelRemoved(selected.id),
                   compatibilityMessage(for: selected) == nil,
                   MLXStorage.hasValidModelArtifacts(for: selected.id) {
                    models[selectedIndex].downloadState = .downloaded
                    downloadFailures.removeValue(forKey: selected.id)
                    return
                }
                #endif
            }
        }
        
        if autoSelectBestModel {
            selectedModelID = bestAvailableModel()?.id
        } else {
            selectedModelID = availableModels.first(where: canSelect)?.id
        }
    }

    func isModelUsable(_ model: ModelInfo) -> Bool {
        guard ModelReleaseGate.isReleased(model) else { return false }
        if model.engine == .appleFoundation {
            return isAppleIntelligenceAvailable
        }
        if compatibilityMessage(for: model) != nil {
            return false
        }
        return model.downloadState.isDownloaded
    }

    func bestAvailableModel() -> ModelInfo? {
        if let apple = models.first(where: { $0.engine == .appleFoundation && isModelUsable($0) && canSelect($0) }) {
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
            .filter { $0.engine == .mlx && isModelUsable($0) && canSelect($0) }
            .sorted {
                // Imported models sort last: automatic picks should land on a
                // checkpoint Own AI has actually validated. They stay in the
                // list so a user whose only model is imported still gets one.
                if $0.isImported != $1.isImported { return !$0.isImported }
                if fitRank($0) != fitRank($1) { return fitRank($0) < fitRank($1) }
                return $0.sizeGB > $1.sizeGB
            }
            .first
    }

    func recoveryModel(excluding failedModelID: String, requiresVision: Bool) -> ModelInfo? {
        models
            .filter { $0.id != failedModelID }
            .filter { !$0.isImported }
            .filter { isModelUsable($0) && canSelect($0) }
            .filter { !requiresVision || $0.supportsVision }
            .filter { UserDefaults.standard.bool(forKey: "modelConsent.\($0.id)") }
            .filter { quickTestResult(for: $0.id)?.success != false }
            .sorted { lhs, rhs in
                let lhsWarm = lhs.id == LLMEngine.shared?.readyModelID
                let rhsWarm = rhs.id == LLMEngine.shared?.readyModelID
                if lhsWarm != rhsWarm { return lhsWarm }
                if lhs.currentDeviceFit != rhs.currentDeviceFit {
                    return lhs.currentDeviceFit == .recommended
                }
                return lhs.sizeGB < rhs.sizeGB
            }
            .first
    }

    func slowRecoveryModel(for model: ModelInfo, requiresVision: Bool) async -> ModelInfo? {
        let summary = await PerformanceMetricsStore.shared.dashboardData().modelSummaries
            .first(where: { $0.modelID == model.id })
        guard let summary, summary.generationCount >= 3 else { return nil }
        let isPersistentlySlow = (summary.p95FirstTokenMilliseconds ?? 0) > 12_000 ||
            (summary.medianEffectiveTokensPerSecond ?? .greatestFiniteMagnitude) < 1.5
        guard isPersistentlySlow else { return nil }
        return recoveryModel(excluding: model.id, requiresVision: requiresVision)
    }

    func activateRecoveryModel(_ model: ModelInfo) {
        selectedModelID = model.id
    }

    func markModelUsed(_ modelID: String, at date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: "model.lastUsed.\(modelID)")
    }

    func lastUsedDate(for modelID: String) -> Date? {
        UserDefaults.standard.object(forKey: "model.lastUsed.\(modelID)") as? Date
    }

    func storedBytes(for model: ModelInfo) -> UInt64 {
        guard model.engine == .mlx else { return 0 }
        return MLXStorage.storedBytes(for: model.id)
    }

    func partialDownloadBytes(for model: ModelInfo) -> UInt64 {
        guard model.engine == .mlx else { return 0 }
        return MLXStorage.partialDownloadBytes(for: model.id)
    }

    /// Turns automatic selection on and immediately applies the best pick.
    /// Distinct from `selectModel`, which records a deliberate manual choice.
    func enableAutomaticSelection() {
        autoSelectBestModel = true
        autoSelectionRevision += 1
        if let best = bestAvailableModel() {
            selectedModelID = best.id
        }
    }

    func disableAutomaticSelection() {
        autoSelectBestModel = false
        autoSelectionRevision += 1
        lastAutoSelectionNotice = nil
        // Auto Mode has been steering `selectedModelID` per request. Hand the
        // user back the model they last chose rather than whichever one the
        // router happened to land on last.
        if let manualSelectedModelID,
           let model = models.first(where: { $0.id == manualSelectedModelID }),
           isModelUsable(model),
           canSelect(model) {
            selectedModelID = manualSelectedModelID
        }
    }

    /// Resolves the best installed model for one request. The classifier and
    /// scoring are deterministic and local; measured performance never leaves
    /// the device.
    func modelForRequest(
        prompt: String,
        hasImage: Bool,
        hasDocuments: Bool,
        warmModelID: String?,
        lowPowerMode: Bool
    ) async -> ModelInfo? {
        guard autoSelectBestModel else { return selectedModel }

        let task = AutoModelTaskClassifier.classify(
            prompt: prompt,
            hasImage: hasImage,
            hasDocuments: hasDocuments
        )
        let summaries = await PerformanceMetricsStore.shared.dashboardData().modelSummaries
        let performanceByModel = Dictionary(uniqueKeysWithValues: summaries.map { ($0.modelID, $0) })
        let thermallyConstrained: Bool
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            thermallyConstrained = true
        default:
            thermallyConstrained = false
        }

        // Imported models are deliberately absent from routing: they have no
        // badges, no health record and no measured memory profile, so Auto Mode
        // has nothing to route on. The user picks them by hand.
        var candidates = models.filter {
            !$0.isImported &&
            isModelUsable($0) &&
            canSelect($0) &&
            $0.currentDeviceFit != .unsupported &&
            UserDefaults.standard.bool(forKey: "modelConsent.\($0.id)") &&
            quickTestResult(for: $0.id)?.success != false
        }
        if task == .images {
            candidates = candidates.filter(\.supportsVision)
        }
        guard !candidates.isEmpty else { return selectedModel }

        let selected = candidates.max { lhs, rhs in
            autoSelectionScore(
                for: lhs,
                task: task,
                performance: performanceByModel[lhs.id],
                warmModelID: warmModelID,
                constrained: lowPowerMode || thermallyConstrained
            ) < autoSelectionScore(
                for: rhs,
                task: task,
                performance: performanceByModel[rhs.id],
                warmModelID: warmModelID,
                constrained: lowPowerMode || thermallyConstrained
            )
        }
        guard let selected else { return selectedModel }

        // Routing runs on every send; only publish when the pick actually
        // changes, so an unchanged decision does not rewrite user defaults and
        // re-notify observers mid-conversation.
        let previousSelectionID = selectedModelID
        if selectedModelID != selected.id {
            selectedModelID = selected.id
        }
        // Surface the toast only on an actual switch — an unchanged pick should
        // not pop a notice on every message.
        if previousSelectionID != selected.id {
            let message = autoSelectionMessage(
                for: selected,
                task: task,
                performance: performanceByModel[selected.id],
                isWarm: warmModelID == selected.id,
                constrained: lowPowerMode || thermallyConstrained
            )
            publishAutoSelectionNotice(AutoModelSelectionNotice(modelID: selected.id, message: message))
        }
        PerformanceLogger.event(
            "Auto model selection",
            label: "Auto model selection",
            metadata: "model=\(selected.id) task=\(task.rawValue) preference=\(autoModelPreference.rawValue) warm=\(warmModelID == selected.id) constrained=\(lowPowerMode || thermallyConstrained)"
        )
        return selected
    }

    func dismissAutoSelectionNotice(_ id: UUID) {
        guard lastAutoSelectionNotice?.id == id else { return }
        autoSelectionDismissTask?.cancel()
        autoSelectionDismissTask = nil
        lastAutoSelectionNotice = nil
    }

    /// Publishes an auto-selection notice and schedules its own dismissal, so the
    /// toast disappears on a timer regardless of the view's lifecycle. Replacing a
    /// notice cancels any pending dismissal and restarts the countdown.
    private func publishAutoSelectionNotice(_ notice: AutoModelSelectionNotice) {
        autoSelectionDismissTask?.cancel()
        lastAutoSelectionNotice = notice
        autoSelectionDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoSelectionNoticeDuration))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.lastAutoSelectionNotice?.id == notice.id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    self.lastAutoSelectionNotice = nil
                }
                self.autoSelectionDismissTask = nil
            }
        }
    }

    private func autoSelectionScore(
        for model: ModelInfo,
        task: AutoModelTask,
        performance: ModelPerformanceSummary?,
        warmModelID: String?,
        constrained: Bool
    ) -> Double {
        var score = 0.0

        switch model.currentDeviceFit {
        case .recommended: score += 16
        case .supported: score += 2
        case .unsupported: score -= 100
        }

        switch task {
        case .images:
            score += model.supportsVision ? 55 : -100
            if model.badges.contains(.vision) { score += 12 }
        case .documents:
            if model.badges.contains(.higherQuality) { score += 22 }
            if model.badges.contains(.bestForWriting) { score += 18 }
            if model.badges.contains(.reasoning) { score += 10 }
        case .coding:
            if model.badges.contains(.bestForCoding) { score += 48 }
            if model.badges.contains(.reasoning) { score += 14 }
        case .reasoning:
            if model.badges.contains(.reasoning) { score += 42 }
            if model.badges.contains(.higherQuality) { score += 18 }
        case .chat:
            if model.badges.contains(.everydayChat) { score += 24 }
            if model.badges.contains(.chat) { score += 20 }
            if model.badges.contains(.recommended) { score += 16 }
        }

        switch autoModelPreference {
        case .faster:
            if model.badges.contains(.fastest) { score += 32 }
            if model.badges.contains(.smallDownload) { score += 12 }
            score -= model.sizeGB * 7
        case .balanced:
            if model.badges.contains(.recommended) { score += 14 }
            if model.badges.contains(.higherQuality) { score += 12 }
            if model.badges.contains(.fastest) { score += 8 }
            score -= model.sizeGB * 2
        case .bestQuality:
            if model.badges.contains(.higherQuality) { score += 30 }
            if model.badges.contains(.reasoning) { score += 12 }
            score += min(model.sizeGB, 4.5) * 3
        }

        if let latency = performance?.medianFirstTokenMilliseconds, latency > 0 {
            let latencyPoints = min(28, 28_000 / max(500, latency))
            score += latencyPoints * (autoModelPreference == .faster ? 1.35 : 0.75)
        }
        if let tokensPerSecond = performance?.medianEffectiveTokensPerSecond {
            let throughputPoints = min(25, tokensPerSecond * 1.5)
            score += throughputPoints * (autoModelPreference == .bestQuality ? 0.35 : 1.0)
        }
        if warmModelID == model.id {
            score += autoModelPreference == .faster ? 30 : 18
        }
        if constrained {
            score -= model.sizeGB * 14
            if model.badges.contains(.smallDownload) { score += 12 }
        }
        if model.engine == .mlx {
            let policy = DeviceResourcePolicy.current
            if let peak = applicableMeasuredPeak(for: model, policy: policy) {
                let utilization = Double(peak) / Double(max(policy.safePeakResidentMemoryBytes, 1))
                let headroomPoints = max(-40, min(20, (1 - utilization) * 30))
                score += constrained ? headroomPoints * 1.6 : headroomPoints
            } else {
                // Known-safe measurements beat an unknown runtime footprint
                // when otherwise equivalent.
                score -= constrained ? 8 : 2
            }
        }

        return score
    }

    private func autoSelectionMessage(
        for model: ModelInfo,
        task: AutoModelTask,
        performance: ModelPerformanceSummary?,
        isWarm: Bool,
        constrained: Bool
    ) -> String {
        if constrained {
            return String(format: String(
                localized: "Switched to %@ to keep things smooth while your device is busy.",
                defaultValue: "Switched to %@ to keep things smooth while your device is busy."
            ), model.name)
        }
        if isWarm {
            return String(format: String(
                localized: "Switched to %@ — already loaded and a good fit for %@.",
                defaultValue: "Switched to %@ — already loaded and a good fit for %@."
            ), model.name, task.title)
        }
        if autoModelPreference == .faster,
           performance?.medianFirstTokenMilliseconds != nil {
            return String(format: String(
                localized: "Switched to %@ — fastest measured fit for this request.",
                defaultValue: "Switched to %@ — fastest measured fit for this request."
            ), model.name)
        }
        return String(format: String(
            localized: "Switched to %@ — the best fit for %@.",
            defaultValue: "Switched to %@ — the best fit for %@."
        ), model.name, task.title)
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
        modelHealthRevision += 1
    }

    func shouldShowModelInCatalog(_ model: ModelInfo) -> Bool {
        guard ModelReleaseGate.isReleased(model) else { return false }
        if model.engine == .appleFoundation {
            return isAppleIntelligenceDeviceSupported
        }
        // Large workstation checkpoints are never offered on iPhone/iPad.
        // They still pass through the normal memory gate on Mac below.
        if model.isMacOnly {
            #if !targetEnvironment(macCatalyst)
            guard UIDevice.current.userInterfaceIdiom == .mac else { return false }
            #endif
        }
        return compatibilityMessage(for: model) == nil
    }

    func compatibilityMessage(for model: ModelInfo) -> String? {
        guard model.engine == .mlx else { return nil }
        if !DeviceResourcePolicy.supportsMLXCompute {
            return "This device's chip can't run downloadable models. They need an A14 chip or newer — iPhone 12, iPhone SE (3rd generation), or later."
        }
        if model.requiresUnsupportedMLXQuantization {
            return "This model uses 1-bit MLX quantization, which is not supported by the current MLX runtime."
        }
        if model.exceedsDeviceMemoryBudget {
            return "This model needs more memory than this device has. Choose a smaller model."
        }
        let policy = DeviceResourcePolicy.current
        if let peak = applicableMeasuredPeak(for: model, policy: policy),
           !policy.allowsMeasuredPeakResidentMemory(peak) {
            return "A measured run of this model left too little memory headroom on this device. Choose a smaller model."
        }
        let idiom = UIDevice.current.userInterfaceIdiom
        if idiom == .phone && model.requiresLargeDeviceOnPhone {
            return "Requires an iPad Pro or Mac. This model exceeds the practical memory budget for iPhone."
        }
        return nil
    }

    private func applicableMeasuredPeak(
        for model: ModelInfo,
        policy: DeviceResourcePolicy
    ) -> UInt64? {
        var peaks: [UInt64] = []
        if let runtime = ModelHealthStore.shared.runtimeMemoryMeasurement(for: model.id),
           runtime.applies(to: policy) {
            peaks.append(runtime.peakResidentMemoryBytes)
        }
        if let quickTest = quickTestResult(for: model.id),
           quickTest.applies(to: policy),
           let peak = quickTest.peakResidentMemoryBytes {
            peaks.append(peak)
        }
        return peaks.max()
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
