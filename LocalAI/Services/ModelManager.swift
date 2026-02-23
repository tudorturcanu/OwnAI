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

// MLX is disabled for simulator - only available on real devices
#if !targetEnvironment(simulator)
import MLXLMCommon
#endif

/// Manages model downloads and lifecycle
@MainActor
@Observable
final class ModelManager {
    
    // MARK: - Properties
    
    var models: [ModelInfo] = ModelInfo.allModels
    @ObservationIgnored @AppStorage("selectedModelID") var selectedModelID: String?
    @ObservationIgnored @AppStorage("autoSelectBestModel") var autoSelectBestModel: Bool = true
    @ObservationIgnored @AppStorage("downloadNotifications") var downloadNotifications: Bool = true
    
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var backgroundTaskIDs: [String: UIBackgroundTaskIdentifier] = [:]
    
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
    
    /// Start downloading a model
    func downloadModel(_ modelID: String) {
        guard let index = models.firstIndex(where: { $0.id == modelID }) else { return }
        let model = models[index]
        guard model.engine == .mlx else { return }
        guard downloadTasks[modelID] == nil else { return }
        
        print("[ModelManager] download start id=\(modelID)")
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
                if let idx = self.models.firstIndex(where: { $0.id == modelID }) {
                    self.models[idx].downloadState = .error(message: "Simulator not supported")
                }
            }
            #else
            do {
                _ = try await MLXLMCommon.loadModelContainer(
                    id: modelID,
                    progressHandler: { progress in
                    let fraction = max(0.0, min(progress.fractionCompleted, 0.99))
                    Task { @MainActor in
                        if let idx = self.models.firstIndex(where: { $0.id == modelID }) {
                            self.models[idx].downloadState = .downloading(progress: fraction)
                        }
                    }
                })
                await MainActor.run {
                    if let idx = self.models.firstIndex(where: { $0.id == modelID }) {
                        self.models[idx].downloadState = .downloaded
                    }
                }
                self.persistModelIfNeeded(modelID: modelID)
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
            } catch {
                await MainActor.run {
                    if let idx = self.models.firstIndex(where: { $0.id == modelID }) {
                        self.models[idx].downloadState = .error(message: error.localizedDescription)
                    }
                }
                if self.downloadNotifications {
                    await MainActor.run {
                        NotificationManager.shared.postDownloadFailed(modelName: model.name, errorMessage: error.localizedDescription)
                    }
                }
                print("[ModelManager] download failed id=\(modelID) error=\(error.localizedDescription)")
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
        // Clear the MLX Hub cache for this model
        let persistentPath = MLXStorage.modelDirectory(for: modelID)
        try? FileManager.default.removeItem(at: persistentPath)
        let legacyPath = MLXStorage.legacyModelDirectory(for: modelID)
        try? FileManager.default.removeItem(at: legacyPath)
        let legacyHubPath = MLXStorage.legacyHubModelDirectory(for: modelID)
        try? FileManager.default.removeItem(at: legacyHubPath)
        let legacyDocsPath = MLXStorage.legacyDocumentsModelDirectory(for: modelID)
        try? FileManager.default.removeItem(at: legacyDocsPath)
        #endif
        
        if let index = models.firstIndex(where: { $0.id == modelID }) {
            models[index].downloadState = .notDownloaded
        }
        
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
                models[index].downloadState = .error(message: "Simulator not supported")
            }
        }
        #else
        // Check MLX model downloads on real device
        for (index, model) in models.enumerated() {
            if model.engine == .mlx {
                let hubPath = MLXStorage.modelDirectory(for: model.id)
                if FileManager.default.fileExists(atPath: hubPath.path) || migrateLegacyModelIfNeeded(modelID: model.id) {
                    models[index].downloadState = .downloaded
                } else {
                    models[index].downloadState = .notDownloaded
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
           let selected = models.first(where: { $0.id == selectedID }) {
            if isModelUsable(selected) { return }
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
