//
//  ModelManager.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import Foundation
import LocalAIKit
import FoundationModels
import SwiftUI
import UIKit
import Darwin

// MLX is disabled for simulator - only available on real devices
#if !targetEnvironment(simulator)
import MLXLMCommon
#endif

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
final class ModelManager {
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
        }
    }
    @ObservationIgnored @AppStorage("autoSelectBestModel") var autoSelectBestModel: Bool = true
    @ObservationIgnored @AppStorage("downloadNotifications") var downloadNotifications: Bool = true
    
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var backgroundTaskIDs: [String: UIBackgroundTaskIdentifier] = [:]
    private var downloadFailures: [String: DownloadFailure] = [:]
    
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
        if case .available = FoundationModels.SystemLanguageModel.default.availability {
            return true
        }
        return false
    }
    
    /// Returns true if the device hardware supports Apple Intelligence, even if disabled
    var isAppleIntelligenceDeviceSupported: Bool {
        if case .unavailable(.deviceNotEligible) = FoundationModels.SystemLanguageModel.default.availability {
            return false
        }
        return true
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
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard self.downloadNotifications else { return }
            guard let activeModelID = self.downloadTasks.keys.first,
                  let model = self.models.first(where: { $0.id == activeModelID }) else { return }
            NotificationManager.shared.postDownloadBackgroundWarning(modelName: model.name)
        }
    }
    
    // MARK: - Public Methods
    
    /// Select a specific model to use
    func selectModel(_ modelID: String) {
        print("[ModelManager] selectModel id=\(modelID)")
        selectedModelID = modelID
    }

    func refreshSelection() {
        ensureSelection()
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

    func repairModel(_ modelID: String) {
        guard let index = models.firstIndex(where: { $0.id == modelID }) else { return }
        guard models[index].engine == .mlx else { return }

        cancelDownload(modelID)
        #if targetEnvironment(simulator)
        applyDownloadFailure(simulatorUnsupportedFailure(), for: modelID)
        #else
        MLXStorage.removeModelArtifacts(for: modelID)
        models[index].downloadState = .notDownloaded
        downloadFailures.removeValue(forKey: modelID)
        downloadModel(modelID)
        #endif
    }
    
    /// Start downloading a model
    func downloadModel(_ modelID: String) {
        guard let index = models.firstIndex(where: { $0.id == modelID }) else { return }
        let model = models[index]
        guard model.engine == .mlx else { return }
        guard downloadTasks[modelID] == nil else { return }

        if let failure = preflightFailure(for: model) {
            applyDownloadFailure(failure, for: modelID)
            return
        }
        
        print("[ModelManager] download start id=\(modelID)")
        downloadFailures.removeValue(forKey: modelID)
        models[index].downloadState = .downloading(progress: 0.02)
        updateIdleTimer()
        beginBackgroundTask(for: modelID)

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
                print("[ModelManager] download complete id=\(modelID)")
                await MainActor.run {
                    if self.selectedModelID == nil {
                        self.selectedModelID = modelID
                    }
                }
            } catch is CancellationError {
                print("[ModelManager] download cancelled id=\(modelID)")
            } catch let failureError as DownloadFailureError {
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
                self.updateIdleTimer()
                self.endBackgroundTask(for: modelID)
            }
        }
        
        downloadTasks[modelID] = task
    }
    
    /// Cancel an ongoing download
    func cancelDownload(_ modelID: String) {
        downloadTasks[modelID]?.cancel()
        downloadTasks.removeValue(forKey: modelID)
        downloadFailures.removeValue(forKey: modelID)
        
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
        UIApplication.shared.isIdleTimerDisabled = hasActiveDownloads
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
        for attempt in 1...maxAttempts {
            do {
                try Task.checkCancellation()
                _ = try await MLXLMCommon.loadModelContainer(
                    id: modelID,
                    progressHandler: { progress in
                        let fraction = max(0.0, min(progress.fractionCompleted, 0.99))
                        Task { @MainActor in
                            if let idx = self.models.firstIndex(where: { $0.id == modelID }) {
                                self.models[idx].downloadState = .downloading(progress: fraction)
                            }
                        }
                    }
                )
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
                throw DownloadFailureError(failure: failure)
            }
        }
    }
    #endif
    
    private func checkAvailability() async {
        // Check Apple Foundation availability
        if let index = models.firstIndex(where: { $0.engine == .appleFoundation }) {
            let availability = FoundationModels.SystemLanguageModel.default.availability
            switch availability {
            case .available:
                models[index].downloadState = .builtin
            case .unavailable(let reason):
                let message: String
                switch reason {
                case .deviceNotEligible:
                    message = "Device not supported"
                case .modelNotReady:
                    message = "Model not ready"
                case .appleIntelligenceNotEnabled:
                    message = "Not enabled"
                @unknown default:
                    message = "Unavailable"
                }
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
    func ensureSelection() {
        if let selectedID = selectedModelID,
           let selectedIndex = models.firstIndex(where: { $0.id == selectedID }) {
            let selected = models[selectedIndex]
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

    func quickTestResult(for modelID: String) -> ModelQuickTestResult? {
        ModelHealthStore.shared.loadResults()[modelID]
    }

    func saveQuickTestResult(_ result: ModelQuickTestResult) {
        ModelHealthStore.shared.saveResult(result)
    }
}
