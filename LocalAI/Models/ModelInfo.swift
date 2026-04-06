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
    case deepSeek
    case tinyLlama
    case llama
    case phi
    case smolLM

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleIntelligence:
            return "Apple Intelligence"
        case .gemma:
            return "Gemma"
        case .qwen:
            return "Qwen"
        case .deepSeek:
            return "DeepSeek"
        case .tinyLlama:
            return "TinyLlama"
        case .llama:
            return "Llama"
        case .phi:
            return "Phi"
        case .smolLM:
            return "SmolLM"
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
        case .deepSeek:
            return "Compact reasoning-style models"
        case .tinyLlama:
            return "Ultra-small chat models"
        case .llama:
            return "Meta's local instruction models"
        case .phi:
            return "Microsoft's efficient reasoning models"
        case .smolLM:
            return "HuggingFace's ultra-compact models"
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
        case .deepSeek:
            return "brain.head.profile"
        case .tinyLlama:
            return "hare.fill"
        case .llama:
            return "bubble.left.and.bubble.right.fill"
        case .phi:
            return "function"
        case .smolLM:
            return "smallcircle.filled.circle"
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

enum ModelBadge: Equatable, Hashable {
    case recommended
    case chat
    case images
    case fastest
    case bestForCoding
    case bestForWriting
    case everydayChat
    case multilingual
    case reasoning
    case fullyOnDevice
    case mayUseAppleProcessing
    case smallDownload
    case higherQuality
    case newerDevices
    case vision

    var title: String {
        switch self {
        case .recommended:
            return "Recommended"
        case .chat:
            return "Chat"
        case .images:
            return "Images"
        case .fastest:
            return "Fastest"
        case .bestForCoding:
            return "Coding"
        case .bestForWriting:
            return "Writing"
        case .everydayChat:
            return "Everyday"
        case .multilingual:
            return "Multilingual"
        case .reasoning:
            return "Reasoning"
        case .fullyOnDevice:
            return "On-Device"
        case .mayUseAppleProcessing:
            return "Apple Processing"
        case .smallDownload:
            return "Small Download"
        case .higherQuality:
            return "Higher Quality"
        case .newerDevices:
            return "Newer Devices"
        case .vision:
            return "Vision"
        }
    }

    var iconName: String {
        switch self {
        case .recommended:
            return "star.fill"
        case .chat:
            return "bubble.left.and.bubble.right.fill"
        case .images:
            return "photo"
        case .fastest:
            return "bolt.fill"
        case .bestForCoding:
            return "terminal"
        case .bestForWriting:
            return "text.book.closed"
        case .everydayChat:
            return "bubble.left.and.bubble.right.fill"
        case .multilingual:
            return "globe"
        case .reasoning:
            return "brain.head.profile"
        case .fullyOnDevice:
            return "lock.shield"
        case .mayUseAppleProcessing:
            return "apple.logo"
        case .smallDownload:
            return "arrow.down.circle"
        case .higherQuality:
            return "sparkles"
        case .newerDevices:
            return "iphone.gen3"
        case .vision:
            return "eye"
        }
    }

    var isHighlighted: Bool {
        switch self {
        case .recommended, .chat, .images, .fastest, .bestForCoding, .bestForWriting:
            return true
        default:
            return false
        }
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
    let shortDescription: String
    let recommendedFor: String
    let badges: [ModelBadge]
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
            return nil
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
        if lowercasedID.contains("deepseek") {
            return "DeepSeek"
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
        if lowercasedID.contains("smollm") {
            return "HuggingFace (SmolLM)"
        }
        return "Model publisher"
    }

    var supportsThinkingToggle: Bool {
        let lowercasedID = id.lowercased()
        return lowercasedID.contains("qwen3") || lowercasedID.contains("gemma-4")
    }

    var thinkingPreferenceKey: String {
        "modelThinkingEnabled.\(id)"
    }

    var defaultThinkingEnabled: Bool {
        false
    }

    var privacyLabel: String {
        isAppleFoundation ? "May use Apple processing" : "Fully on-device"
    }

    /// Set of MLX model IDs that support vision (VLM models).
    static let vlmMLXModelIDs: Set<String> = [
        "mlx-community/Qwen2-VL-2B-Instruct-4bit",
        "mlx-community/Qwen2.5-VL-3B-Instruct-3bit",
        "mlx-community/gemma-4-e2b-it-4bit",
        "mlx-community/gemma-4-e4b-it-4bit",
        "mlx-community/gemma-4-26b-a4b-it-4bit"
    ]

    var supportsVision: Bool {
        engine == .appleFoundation || ModelInfo.vlmMLXModelIDs.contains(id)
    }

    /// Some catalog entries may be ahead of the bundled MLX runtime support.
    static let runtimeUnsupportedModelIDs: Set<String> = [
        "mlx-community/gemma-4-e2b-it-4bit",
        "mlx-community/gemma-4-e4b-it-4bit",
        "mlx-community/gemma-4-26b-a4b-it-4bit"
    ]

    var sizeLabel: String {
        if engine == .appleFoundation {
            return "No download"
        }
        return String(format: "%.1f GB", sizeGB)
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
        shortDescription: "Built in, quick to start, and best for everyday use.",
        recommendedFor: "Best for everyday questions when Apple Intelligence is available.",
        badges: [.recommended, .images, .mayUseAppleProcessing],
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
        shortDescription: "Balanced local model for reliable everyday chats.",
        recommendedFor: "Good default for private everyday chat on most devices.",
        badges: [.chat, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Gemma 3 1B Instruct QAT (4-bit MLX)
    static let gemma3_1b_qat_4bit = ModelInfo(
        id: "mlx-community/gemma-3-1b-it-qat-4bit",
        name: "Gemma 3 1B",
        description: "A newer Gemma tuned for strong small-model quality on Apple devices, with a very light download and responsive local chat.",
        family: .gemma,
        sizeGB: 0.73,
        engine: .mlx,
        termsURL: URL(string: "https://ai.google.dev/gemma/terms"),
        privacyURL: nil,
        shortDescription: "Very light, responsive, and easy on storage.",
        recommendedFor: "Best when you want a quick local model with a tiny download.",
        badges: [.fastest, .smallDownload, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Gemma 3 270M Instruct QAT (4-bit MLX)
    static let gemma3_270m_qat_4bit = ModelInfo(
        id: "mlx-community/gemma-3-270m-it-qat-4bit",
        name: "Gemma 3 270M",
        description: "An extremely small Gemma variant tuned for very fast startup and minimal storage on iPhone.",
        family: .gemma,
        sizeGB: 0.28,
        engine: .mlx,
        termsURL: URL(string: "https://ai.google.dev/gemma/terms"),
        privacyURL: nil,
        shortDescription: "Ultra-light Gemma option for the smallest local install.",
        recommendedFor: "Best when you want a tiny iPhone-friendly model for short everyday prompts.",
        badges: [.fastest, .smallDownload, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Qwen3 0.6B MLX (4-bit)
    static let qwen3_0_6b_4bit = ModelInfo(
        id: "Qwen/Qwen3-0.6B-MLX-4bit",
        name: "Qwen3 0.6B",
        description: "Qwen's smallest current-generation chat model, optimized for very light local use while keeping broad multilingual support.",
        family: .qwen,
        sizeGB: 0.32,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/Qwen/Qwen3-0.6B-MLX-4bit"),
        privacyURL: nil,
        shortDescription: "Extremely small and fast with multilingual support.",
        recommendedFor: "Best for the smallest possible download and basic multilingual chat.",
        badges: [.smallDownload, .multilingual, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Qwen2.5 0.5B Instruct (4-bit MLX)
    static let qwen25_0_5b_instruct_4bit = ModelInfo(
        id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
        name: "Qwen2.5 0.5B",
        description: "An ultra-light Qwen2.5 variant for the smallest downloads and fastest local startup on older or storage-constrained devices.",
        family: .qwen,
        sizeGB: 0.28,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct"),
        privacyURL: nil,
        shortDescription: "Tiny multilingual model with a very small local footprint.",
        recommendedFor: "Best when you want the lightest possible install for simple chats.",
        badges: [.fastest, .smallDownload, .multilingual, .fullyOnDevice],
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
        shortDescription: "Fast to install, but output quality is more limited.",
        recommendedFor: "Useful when storage matters more than answer quality.",
        badges: [.smallDownload, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Qwen3 1.7B MLX (4-bit)
    static let qwen3_1_7b_4bit = ModelInfo(
        id: "Qwen/Qwen3-1.7B-MLX-4bit",
        name: "Qwen3 1.7B",
        description: "A stronger small Qwen3 option for everyday chat, multilingual use, and better instruction following on-device.",
        family: .qwen,
        sizeGB: 0.98,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/Qwen/Qwen3-1.7B-MLX-4bit"),
        privacyURL: nil,
        shortDescription: "Strong compact model for chat, writing, and languages.",
        recommendedFor: "Great all-around local option for multilingual everyday use.",
        badges: [.recommended, .multilingual, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Qwen2.5 1.5B Instruct (4-bit MLX)
    static let qwen25_1_5b_instruct_4bit = ModelInfo(
        id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
        name: "Qwen2.5 1.5B",
        description: "A compact multilingual model that balances speed and answer quality well for everyday iPhone and iPad use.",
        family: .qwen,
        sizeGB: 0.87,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct"),
        privacyURL: nil,
        shortDescription: "Balanced multilingual model that stays light on storage.",
        recommendedFor: "Good for mixed everyday tasks with a smaller local footprint.",
        badges: [.multilingual, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// DeepSeek R1 Distill Qwen 1.5B (4-bit MLX)
    static let deepseek_r1_distill_qwen_1_5b_4bit = ModelInfo(
        id: "mlx-community/DeepSeek-R1-Distill-Qwen-1.5B-4bit",
        name: "DeepSeek R1 Distill 1.5B",
        description: "A compact reasoning-style model distilled onto Qwen for stronger step-by-step responses at small size.",
        family: .deepSeek,
        sizeGB: 1.01,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B"),
        privacyURL: nil,
        shortDescription: "Compact reasoning-focused model for step-by-step answers.",
        recommendedFor: "Best for explanations and more deliberate reasoning at a small size.",
        badges: [.reasoning, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Gemma 3n E2B Text Only (4-bit MLX)
    static let gemma3n_e2b_it_lm_4bit = ModelInfo(
        id: "mlx-community/gemma-3n-E2B-it-lm-4bit",
        name: "Gemma 3n E2B",
        description: "Google's newer Gemma 3n text-only model, tuned for stronger everyday chat quality while staying efficient enough for newer iPhones and iPads.",
        family: .gemma,
        sizeGB: 1.7,
        engine: .mlx,
        termsURL: URL(string: "https://ai.google.dev/gemma/terms"),
        privacyURL: nil,
        shortDescription: "A sharper text-only Gemma with strong quality for its size.",
        recommendedFor: "Great for richer local chat and writing without jumping to a very large model.",
        badges: [.higherQuality, .everydayChat, .newerDevices, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Gemma 4 E2B Instruct (4-bit MLX)
    static let gemma4_e2b_it_4bit = ModelInfo(
        id: "mlx-community/gemma-4-e2b-it-4bit",
        name: "Gemma 4 (E2B)",
        description: "Google's multimodal Gemma 4 E2B model supports text and image input, with stronger reasoning and richer responses on newer Apple devices.",
        family: .gemma,
        sizeGB: 3.61,
        engine: .mlx,
        termsURL: URL(string: "https://ai.google.dev/gemma/terms"),
        privacyURL: nil,
        shortDescription: "Multimodal Gemma 4 with vision and stronger local reasoning.",
        recommendedFor: "Best when you want higher-quality local chat, image analysis, and reasoning on newer devices.",
        badges: [.images, .reasoning, .higherQuality, .newerDevices, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Qwen2.5 3B Instruct (4-bit MLX)
    static let qwen25_3b_instruct_4bit = ModelInfo(
        id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
        name: "Qwen2.5 3B",
        description: "One of the best quality-per-GB options for local chat on newer iPhones and iPads, with stronger reasoning and multilingual output.",
        family: .qwen,
        sizeGB: 1.74,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct"),
        privacyURL: nil,
        shortDescription: "High quality per GB with stronger reasoning and writing.",
        recommendedFor: "Best balance of quality and size for newer iPhones and iPads.",
        badges: [.bestForWriting, .higherQuality, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Qwen2.5 7B Instruct (4-bit MLX)
    static let qwen25_7b_instruct_4bit = ModelInfo(
        id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
        name: "Qwen2.5 7B",
        description: "A larger Qwen2.5 tier with much stronger writing, reasoning, and multilingual performance for iPad Pro and Mac-class devices.",
        family: .qwen,
        sizeGB: 4.2,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct"),
        privacyURL: nil,
        shortDescription: "A strong larger Qwen model for writing, coding, and multilingual tasks.",
        recommendedFor: "Best for higher-quality local output when you have enough memory headroom.",
        badges: [.reasoning, .multilingual, .higherQuality, .newerDevices, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Qwen3 4B MLX (4-bit)
    static let qwen3_4b_4bit = ModelInfo(
        id: "Qwen/Qwen3-4B-MLX-4bit",
        name: "Qwen3 4B",
        description: "A more capable Qwen3 tier for higher-quality local chat, reasoning, and multilingual responses on larger devices.",
        family: .qwen,
        sizeGB: 2.6,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/Qwen/Qwen3-4B-MLX-4bit"),
        privacyURL: nil,
        shortDescription: "More capable Qwen tier for better reasoning and output quality.",
        recommendedFor: "Best when you want stronger local quality and have a newer device.",
        badges: [.multilingual, .higherQuality, .newerDevices, .fullyOnDevice],
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
        shortDescription: "A higher-quality local chat model with solid writing ability.",
        recommendedFor: "Good for polished general responses on devices with a bit more headroom.",
        badges: [.bestForWriting, .higherQuality, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Llama 3.2 1B Instruct (4-bit MLX)
    static let llama32_1b_4bit = ModelInfo(
        id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
        name: "Llama 3.2 1B",
        description: "A very small Llama option that keeps downloads light while still feeling like a modern chat model.",
        family: .llama,
        sizeGB: 0.71,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct"),
        privacyURL: nil,
        shortDescription: "Lightweight modern chat model with a small local footprint.",
        recommendedFor: "Good if you want a small but modern-feeling local assistant.",
        badges: [.smallDownload, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Phi 4 Mini Instruct (4-bit MLX)
    static let phi4_mini_4bit = ModelInfo(
        id: "mlx-community/Phi-4-mini-instruct-4bit",
        name: "Phi 4 Mini",
        description: "Microsoft's newer compact Phi model, offering stronger general reasoning and coding ability while still fitting modern iOS devices.",
        family: .phi,
        sizeGB: 2.16,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/microsoft/Phi-4-mini-instruct"),
        privacyURL: nil,
        shortDescription: "One of the stronger compact options for coding and reasoning.",
        recommendedFor: "Best for technical tasks and coding on newer devices.",
        badges: [.bestForCoding, .reasoning, .newerDevices, .fullyOnDevice],
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
        shortDescription: "Efficient reasoning-focused Phi model with solid technical output.",
        recommendedFor: "Good for problem-solving and technical prompts fully on-device.",
        badges: [.reasoning, .bestForCoding, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Phi 3 Mini 4K Instruct (4-bit MLX)
    static let phi3_mini_4k_4bit = ModelInfo(
        id: "mlx-community/Phi-3-mini-4k-instruct-4bit",
        name: "Phi 3 Mini 4K",
        description: "Microsoft's smaller Phi model with strong compact reasoning and instruction-following.",
        family: .phi,
        sizeGB: 2.15,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/microsoft/Phi-3-mini-4k-instruct"),
        privacyURL: nil,
        shortDescription: "Compact Phi model with structured answers and good instruction following.",
        recommendedFor: "Good for concise technical help on-device.",
        badges: [.bestForCoding, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Gemma 3 4B Instruct QAT (4-bit MLX)
    static let gemma3_4b_qat_4bit = ModelInfo(
        id: "mlx-community/gemma-3-4b-it-qat-4bit",
        name: "Gemma 3 4B",
        description: "Google's mid-tier Gemma 3 model with strong instruction following and reasoning, running fully on-device.",
        family: .gemma,
        sizeGB: 2.6,
        engine: .mlx,
        termsURL: URL(string: "https://ai.google.dev/gemma/terms"),
        privacyURL: nil,
        shortDescription: "Solid mid-tier Gemma for richer on-device conversations.",
        recommendedFor: "Great step up in quality from Gemma 3 1B for devices with more headroom.",
        badges: [.everydayChat, .higherQuality, .newerDevices, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// SmolLM2 1.7B Instruct (4-bit MLX)
    static let smolLM2_1_7b_4bit = ModelInfo(
        id: "mlx-community/SmolLM2-1.7B-Instruct-4bit",
        name: "SmolLM2 1.7B",
        description: "HuggingFace's compact SmolLM2, designed for fast on-device chat with surprisingly strong performance for its tiny footprint.",
        family: .smolLM,
        sizeGB: 1.04,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/HuggingFaceTB/SmolLM2-1.7B-Instruct"),
        privacyURL: nil,
        shortDescription: "Fast and surprisingly capable for its small size.",
        recommendedFor: "Best for quick on-device replies with a minimal download.",
        badges: [.fastest, .smallDownload, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Llama 3.1 8B Instruct (4-bit MLX)
    static let llama31_8b_4bit = ModelInfo(
        id: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
        name: "Llama 3.1 8B",
        description: "Meta's larger Llama instruction model with excellent instruction following, coding, and reasoning for iPad Pro and Mac.",
        family: .llama,
        sizeGB: 4.5,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/meta-llama/Meta-Llama-3.1-8B-Instruct"),
        privacyURL: nil,
        shortDescription: "High-quality Llama model for powerful on-device conversations.",
        recommendedFor: "Best for high-quality, nuanced conversations on iPad Pro or Mac.",
        badges: [.higherQuality, .bestForWriting, .reasoning, .newerDevices, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Qwen3 8B MLX (4-bit)
    static let qwen3_8b_4bit = ModelInfo(
        id: "Qwen/Qwen3-8B-MLX-4bit",
        name: "Qwen3 8B",
        description: "Qwen's larger local model with top-tier multilingual reasoning, coding, and instruction following for high-end Apple devices.",
        family: .qwen,
        sizeGB: 4.8,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/Qwen/Qwen3-8B-MLX-4bit"),
        privacyURL: nil,
        shortDescription: "Top-tier local Qwen model for demanding tasks on Mac or iPad Pro.",
        recommendedFor: "Best for multilingual, coding, and reasoning tasks on high-end devices.",
        badges: [.higherQuality, .bestForCoding, .multilingual, .reasoning, .newerDevices, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// DeepSeek R1 Distill Qwen 7B (4-bit MLX)
    static let deepseek_r1_distill_qwen_7b_4bit = ModelInfo(
        id: "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit",
        name: "DeepSeek R1 Distill 7B",
        description: "A stronger DeepSeek reasoning model distilled onto Qwen, offering better step-by-step problem solving and coding quality on larger Apple devices.",
        family: .deepSeek,
        sizeGB: 4.1,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/deepseek-ai/DeepSeek-R1-Distill-Qwen-7B"),
        privacyURL: nil,
        shortDescription: "A larger reasoning-focused local model for technical work.",
        recommendedFor: "Best for longer reasoning chains, coding help, and more deliberate answers on iPad Pro or Mac.",
        badges: [.reasoning, .bestForCoding, .newerDevices, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// SmolLM3 3B (4-bit MLX)
    static let smolLM3_3b_4bit = ModelInfo(
        id: "mlx-community/SmolLM3-3B-4bit",
        name: "SmolLM3 3B",
        description: "A newer SmolLM option that gives you better local quality than the tiny models while staying lighter than the bigger 7B and 8B choices.",
        family: .smolLM,
        sizeGB: 1.8,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/HuggingFaceTB/SmolLM3-3B"),
        privacyURL: nil,
        shortDescription: "A compact modern SmolLM with a nice quality-to-size tradeoff.",
        recommendedFor: "Good when you want a lightweight but more capable everyday local assistant.",
        badges: [.smallDownload, .everydayChat, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Qwen2-VL 2B Instruct — multimodal vision-language model (4-bit MLX)
    static let qwen2VL_2b_4bit = ModelInfo(
        id: "mlx-community/Qwen2-VL-2B-Instruct-4bit",
        name: "Qwen2-VL 2B",
        description: "Alibaba's compact vision-language model. Understands images and text together — running fully on-device. Great for photo Q&A, document scanning, and visual reasoning.",
        family: .qwen,
        sizeGB: 1.6,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/Qwen/Qwen2-VL-2B-Instruct"),
        privacyURL: nil,
        shortDescription: "See and understand images — fully on-device.",
        recommendedFor: "Best for attaching photos and asking the AI about them.",
        badges: [.images, .multilingual, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Qwen2.5-VL 3B Instruct — multimodal vision-language model (3-bit MLX)
    static let qwen25VL_3b_3bit = ModelInfo(
        id: "mlx-community/Qwen2.5-VL-3B-Instruct-3bit",
        name: "Qwen2.5-VL 3B",
        description: "Alibaba's newer compact vision-language model with stronger image understanding, document parsing, and visual reasoning, running fully on-device.",
        family: .qwen,
        sizeGB: 2.69,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-VL-3B-Instruct"),
        privacyURL: nil,
        shortDescription: "A stronger on-device vision model for images, screenshots, and documents.",
        recommendedFor: "Best for richer photo Q&A, OCR-heavy tasks, and visual reasoning on newer devices.",
        badges: [.images, .higherQuality, .multilingual, .newerDevices, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    static let allModels: [ModelInfo] = [
        .appleFoundation,  // Default - first in list
        // Small / ultra-light
        .gemma3_270m_qat_4bit,
        .qwen3_0_6b_4bit,
        .qwen25_0_5b_instruct_4bit,
        .tinyllama11b_chat_4bit,
        // Compact (0.7–1.1 GB)
        .llama32_1b_4bit,
        .gemma3_1b_qat_4bit,
        .smolLM2_1_7b_4bit,
        .qwen25_1_5b_instruct_4bit,
        .qwen3_1_7b_4bit,
        .deepseek_r1_distill_qwen_1_5b_4bit,
        // Vision  (VLM - image input capable)
        .qwen2VL_2b_4bit,
        .qwen25VL_3b_3bit,
        // Mid-range (1.7–4 GB)
        .gemma3n_e2b_it_lm_4bit,
        .gemma4_e2b_it_4bit,
        .gemma2_2b_4bit,
        .smolLM3_3b_4bit,
        .qwen25_3b_instruct_4bit,
        .llama32_3b_4bit,
        .phi3_mini_4k_4bit,
        .phi4_mini_4bit,
        .phi35_mini_4bit,
        .gemma3_4b_qat_4bit,
        .qwen3_4b_4bit,
        // Large (4+ GB) — iPad Pro / Mac
        .deepseek_r1_distill_qwen_7b_4bit,
        .qwen25_7b_instruct_4bit,
        .llama31_8b_4bit,
        .qwen3_8b_4bit
    ]
}
