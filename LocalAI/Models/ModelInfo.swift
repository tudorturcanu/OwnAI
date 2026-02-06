//
//  ModelInfo.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import Foundation

/// Represents the type of model engine
enum ModelEngine: String, Equatable {
    case appleFoundation = "apple"
    case mlx = "mlx"
}

/// Represents the download state of a model
enum DownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case builtin  // For Apple Foundation Model
    case error(message: String)
    
    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
    
    var isDownloaded: Bool {
        if case .downloaded = self { return true }
        if case .builtin = self { return true }
        return false
    }
    
    var isBuiltin: Bool {
        if case .builtin = self { return true }
        return false
    }
}

/// Information about an available AI model
struct ModelInfo: Identifiable, Equatable {
    let id: String          // Unique identifier
    let name: String        // Display name
    let description: String // Short description
    let sizeGB: Double      // Approximate size in GB (0 for built-in)
    let engine: ModelEngine // Which engine to use
    var downloadState: DownloadState
    
    static func == (lhs: ModelInfo, rhs: ModelInfo) -> Bool {
        lhs.id == rhs.id && lhs.downloadState == rhs.downloadState
    }
    
    var isAppleFoundation: Bool {
        engine == .appleFoundation
    }
}

// MARK: - Available Models
extension ModelInfo {
    /// Apple's on-device Foundation Model (built into iOS 26+)
    static let appleFoundation = ModelInfo(
        id: "apple-foundation",
        name: "Apple Intelligence",
        description: "Apple's on-device model. Fast, private, and built right into your device. No download required.",
        sizeGB: 0,
        engine: .appleFoundation,
        downloadState: .builtin
    )

    /// Gemma 2 2B Instruct (4-bit MLX)
    static let gemma2_2b_4bit = ModelInfo(
        id: "mlx-community/gemma-2-2b-it-4bit",
        name: "Gemma 2 2B (MLX)",
        description: "Gemma 2 2B Instruct, 4-bit MLX quantized weights. Runs fully on-device.",
        sizeGB: 1.47,
        engine: .mlx,
        downloadState: .notDownloaded
    )
    
    static let allModels: [ModelInfo] = [
        .appleFoundation,  // Default - first in list
        .gemma2_2b_4bit
    ]
}
