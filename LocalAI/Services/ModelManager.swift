//
//  ModelManager.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import Foundation
import FoundationModels

// MLX is disabled for simulator - only available on real devices
#if !targetEnvironment(simulator)
// import MLXLMCommon
// import MLXLLM
#endif

/// Manages model downloads and lifecycle
@MainActor
@Observable
final class ModelManager {
    
    // MARK: - Properties
    
    var models: [ModelInfo] = ModelInfo.allModels
    var selectedModelID: String?
    
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    
    // MARK: - Computed Properties
    
    var hasAvailableModels: Bool {
        models.contains { $0.downloadState.isDownloaded }
    }
    
    var availableModels: [ModelInfo] {
        models.filter { $0.downloadState.isDownloaded }
    }
    
    var selectedModel: ModelInfo? {
        if let id = selectedModelID {
            return models.first { $0.id == id }
        }
        // Default to first available model (Apple Foundation is first)
        return availableModels.first
    }
    
    var isAppleIntelligenceAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }
    
    // MARK: - Initialization
    
    init() {
        Task {
            await checkAvailability()
        }
    }
    
    // MARK: - Public Methods
    
    /// Select a specific model to use
    func selectModel(_ modelID: String) {
        selectedModelID = modelID
    }
    
    /// Start downloading a model
    func downloadModel(_ modelID: String) {
        // MLX temporarily disabled
    }
    
    /// Cancel an ongoing download
    func cancelDownload(_ modelID: String) {
        downloadTasks[modelID]?.cancel()
        downloadTasks.removeValue(forKey: modelID)
        
        if let index = models.firstIndex(where: { $0.id == modelID }) {
            models[index].downloadState = .notDownloaded
        }
    }
    
    /// Delete a downloaded model
    func deleteModel(_ modelID: String) {
        guard let model = models.first(where: { $0.id == modelID }) else { return }
        guard model.engine == .mlx else { return } // Can't delete built-in models
        
        #if !targetEnvironment(simulator)
        // Clear the MLX Hub cache for this model
        // let hubPath = getModelCachePath(for: modelID)
        // try? FileManager.default.removeItem(at: hubPath)
        #endif
        
        if let index = models.firstIndex(where: { $0.id == modelID }) {
            models[index].downloadState = .notDownloaded
        }
        
        // Clear selection if it was deleted
        if selectedModelID == modelID {
            selectedModelID = nil
        }
    }
    
    // MARK: - Private Methods
    
    private func checkAvailability() async {
        // Check Apple Foundation availability
        if let index = models.firstIndex(where: { $0.engine == .appleFoundation }) {
            let availability = SystemLanguageModel.default.availability
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
        
        // Check MLX model availability temporarily disabled
        /*
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
                let hubPath = getModelCachePath(for: model.id)
                if FileManager.default.fileExists(atPath: hubPath.path) {
                    models[index].downloadState = .downloaded
                }
            }
        }
        #endif
        */
    }
    
    #if !targetEnvironment(simulator)
    /*
    private func performDownload(modelID: String) async throws {
        // Use the registry configuration for gemma
        let configuration = LLMRegistry.gemma_2_2b_it_4bit
        
        // Load the model which handles downloading
        _ = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration
        ) { progress in
            Task { @MainActor in
                if let index = self.models.firstIndex(where: { $0.id == modelID }) {
                    self.models[index].downloadState = .downloading(progress: progress.fractionCompleted)
                }
            }
        }
        
        // Mark as downloaded
        if let index = models.firstIndex(where: { $0.id == modelID }) {
            models[index].downloadState = .downloaded
        }
        
        downloadTasks.removeValue(forKey: modelID)
    }
    
    private func getModelCachePath(for modelID: String) -> URL {
        // MLX stores models in the hub cache directory
        let libraryPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let hubCachePath = libraryPath.appendingPathComponent("Caches/huggingface/hub")
        let modelDirName = "models--\(modelID.replacingOccurrences(of: "/", with: "--"))"
        return hubCachePath.appendingPathComponent(modelDirName)
    }
    */
    #endif
}
