//
//  ModelInfo.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import Foundation
import UIKit
import Darwin

enum ModelFamily: String, CaseIterable, Identifiable, Equatable {
    case appleIntelligence
    case gemma
    case qwen
    case tinyLlama
    case llama
    case phi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleIntelligence:
            return "Apple Intelligence"
        case .gemma:
            return "Gemma"
        case .qwen:
            return "Qwen"
        case .tinyLlama:
            return "TinyLlama"
        case .llama:
            return "Llama"
        case .phi:
            return "Phi"
        }
    }

    var subtitle: String {
        switch self {
        case .appleIntelligence:
            return "Built-in Apple model"
        case .gemma:
            return "Google's compact local models"
        case .qwen:
            return "Alibaba's multilingual family"
        case .tinyLlama:
            return "Ultra-small chat models"
        case .llama:
            return "Meta's local instruction models"
        case .phi:
            return "Microsoft's efficient reasoning models"
        }
    }

    var symbolName: String {
        switch self {
        case .appleIntelligence:
            return "apple.intelligence"
        case .gemma:
            return "sparkles"
        case .qwen:
            return "globe"
        case .tinyLlama:
            return "hare.fill"
        case .llama:
            return "bubble.left.and.bubble.right.fill"
        case .phi:
            return "function"
        }
    }
}

enum ModelDeviceFit: Equatable {
    case recommended
    case supported
    case unsupported

    var title: String {
        switch self {
        case .recommended:
            return "Recommended"
        case .supported:
            return "OK"
        case .unsupported:
            return "Heavy"
        }
    }

    var iconName: String {
        switch self {
        case .recommended:
            return "sparkles"
        case .supported:
            return "checkmark.circle"
        case .unsupported:
            return "exclamationmark.triangle"
        }
    }

    var isHighlighted: Bool {
        self == .recommended
    }
}

private struct CurrentDeviceProfile {
    let idiom: UIUserInterfaceIdiom
    let hardwareIdentifier: String

    var phoneMajorVersion: Int? {
        guard hardwareIdentifier.hasPrefix("iPhone") else { return nil }
        let suffix = hardwareIdentifier.dropFirst("iPhone".count)
        guard let majorText = suffix.split(separator: ",").first else { return nil }
        return Int(majorText)
    }

    static let current = CurrentDeviceProfile(
        idiom: UIDevice.current.userInterfaceIdiom,
        hardwareIdentifier: Self.resolveHardwareIdentifier()
    )

    private static func resolveHardwareIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { charPointer in
                String(cString: charPointer)
            }
        }
    }
}

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
    let family: ModelFamily // Model family for catalog grouping
    let sizeGB: Double      // Approximate size in GB (0 for built-in)
    let engine: ModelEngine // Which engine to use
    let termsURL: URL?
    let privacyURL: URL?
    var downloadState: DownloadState
    
    static func == (lhs: ModelInfo, rhs: ModelInfo) -> Bool {
        lhs.id == rhs.id && lhs.downloadState == rhs.downloadState
    }
    
    var isAppleFoundation: Bool {
        engine == .appleFoundation
    }

    var requiresLargeDeviceOnPhone: Bool {
        engine == .mlx && sizeGB > 4.5
    }

    var currentDeviceFit: ModelDeviceFit {
        guard engine == .mlx else { return .recommended }
        let device = CurrentDeviceProfile.current

        switch device.idiom {
        case .phone:
            if sizeGB > 4.5 { return .unsupported }
            let major = device.phoneMajorVersion ?? 0
            if sizeGB <= 1.6 { return major >= 14 ? .recommended : .supported }
            if sizeGB <= 2.6 { return major >= 15 ? .recommended : .supported }
            return major >= 17 ? .recommended : .supported

        case .pad:
            if sizeGB <= 2.6 { return .recommended }
            if sizeGB <= 4.6 { return .supported }
            return .unsupported

        default:
            return .recommended
        }
    }

    var recommendationTagText: String? {
        switch currentDeviceFit {
        case .recommended:
            return "Recommended"
        case .supported:
            return nil
        case .unsupported:
            return "Heavy"
        }
    }

    var providerName: String {
        if isAppleFoundation {
            return "Apple Inc."
        }
        let lowercasedID = id.lowercased()
        if lowercasedID.contains("gemma") {
            return "Google LLC (Gemma)"
        }
        if lowercasedID.contains("qwen") {
            return "Alibaba Cloud (Qwen)"
        }
        if lowercasedID.contains("llama") {
            return "Meta Platforms, Inc. (Llama)"
        }
        if lowercasedID.contains("phi") {
            return "Microsoft (Phi)"
        }
        if lowercasedID.contains("tinyllama") {
            return "TinyLlama Project"
        }
        return "Model publisher"
    }
}

// MARK: - Available Models
extension ModelInfo {
    /// Apple's on-device Foundation Model (built into iOS 26+)
    static let appleFoundation = ModelInfo(
        id: "apple-foundation",
        name: "Apple Intelligence",
        description: "Apple's on-device model. Fast, private, and built right into your device. No download required.",
        family: .appleIntelligence,
        sizeGB: 0,
        engine: .appleFoundation,
        termsURL: URL(string: "https://www.apple.com/legal/privacy/data/en/intelligence-engine/"),
        privacyURL: URL(string: "https://www.apple.com/legal/privacy/data/en/intelligence-engine/"),
        downloadState: .builtin
    )

    /// Gemma 2 2B Instruct (4-bit MLX)
    static let gemma2_2b_4bit = ModelInfo(
        id: "mlx-community/gemma-2-2b-it-4bit",
        name: "Gemma 2 2B",
        description: "Google's compact AI model. Runs fully on-device — your data never leaves your device for AI processing.",
        family: .gemma,
        sizeGB: 1.47,
        engine: .mlx,
        termsURL: URL(string: "https://ai.google.dev/gemma/terms"),
        privacyURL: nil,
        downloadState: .notDownloaded
    )

    /// Qwen 2.5 0.5B Instruct (4-bit MLX)
    static let qwen25_0_5b_4bit = ModelInfo(
        id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
        name: "Qwen 2.5 0.5B",
        description: "An ultra-lightweight multilingual model for fast local replies on lower-memory devices.",
        family: .qwen,
        sizeGB: 0.29,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct"),
        privacyURL: nil,
        downloadState: .notDownloaded
    )

    /// TinyLlama 1.1B Chat v1.0 (4-bit MLX)
    static let tinyllama11b_chat_4bit = ModelInfo(
        id: "mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit",
        name: "TinyLlama 1.1B",
        description: "A very small chat model that prioritizes low storage and quick downloads over output quality.",
        family: .tinyLlama,
        sizeGB: 0.72,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/TinyLlama/TinyLlama-1.1B-Chat-v1.0"),
        privacyURL: nil,
        downloadState: .notDownloaded
    )

    /// Qwen 2.5 1.5B Instruct (4-bit MLX)
    static let qwen25_1_5b_4bit = ModelInfo(
        id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
        name: "Qwen 2.5 1.5B",
        description: "Alibaba's lightweight multilingual model. Fast on-device responses with fully local inference.",
        family: .qwen,
        sizeGB: 1.1,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct"),
        privacyURL: nil,
        downloadState: .notDownloaded
    )

    /// Qwen 2.5 3B Instruct (4-bit MLX)
    static let qwen25_3b_4bit = ModelInfo(
        id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
        name: "Qwen 2.5 3B",
        description: "A stronger multilingual on-device model with a good balance of speed and quality.",
        family: .qwen,
        sizeGB: 1.8,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct"),
        privacyURL: nil,
        downloadState: .notDownloaded
    )

    /// Llama 3.2 3B Instruct (4-bit MLX)
    static let llama32_3b_4bit = ModelInfo(
        id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
        name: "Llama 3.2 3B",
        description: "Meta's compact instruction-tuned model, optimized for higher quality local conversations.",
        family: .llama,
        sizeGB: 2.0,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct"),
        privacyURL: nil,
        downloadState: .notDownloaded
    )

    /// Phi 3.5 Mini Instruct (4-bit MLX)
    static let phi35_mini_4bit = ModelInfo(
        id: "mlx-community/Phi-3.5-mini-instruct-4bit",
        name: "Phi 3.5 Mini",
        description: "Microsoft's efficient small model with strong reasoning for its size, running entirely on-device.",
        family: .phi,
        sizeGB: 2.2,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/microsoft/Phi-3.5-mini-instruct"),
        privacyURL: nil,
        downloadState: .notDownloaded
    )

    static let allModels: [ModelInfo] = [
        .appleFoundation,  // Default - first in list
        .qwen25_0_5b_4bit,
        .tinyllama11b_chat_4bit,
        .gemma2_2b_4bit,
        .qwen25_1_5b_4bit,
        .qwen25_3b_4bit,
        .llama32_3b_4bit,
        .phi35_mini_4bit
    ]
}
