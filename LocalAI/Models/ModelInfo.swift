//
//  ModelInfo.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import Foundation
import UIKit

enum ModelFamily: String, CaseIterable, Identifiable, Equatable {
    case appleIntelligence
    case gemma
    case qwen
    case granite
    case lfm
    case exaone
    case glm
    case holo
    case deepSeek
    case llama
    case muse
    case nemotron
    case miniCPM
    case phi
    case smol

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleIntelligence:
            return String(localized: "Apple Intelligence")
        case .gemma:
            return String(localized: "Gemma")
        case .qwen:
            return String(localized: "Qwen")
        case .granite:
            return String(localized: "Granite")
        case .lfm:
            return String(localized: "LFM 2.5")
        case .exaone:
            return String(localized: "EXAONE")
        case .glm:
            return String(localized: "GLM")
        case .holo:
            return String(localized: "Holo")
        case .deepSeek:
            return String(localized: "DeepSeek")
        case .llama:
            return String(localized: "Llama")
        case .muse:
            return String(localized: "Muse")
        case .nemotron:
            return String(localized: "Nemotron")
        case .miniCPM:
            return String(localized: "MiniCPM")
        case .phi:
            return String(localized: "Phi")
        case .smol:
            return String(localized: "Smol")
        }
    }

    var subtitle: String {
        switch self {
        case .appleIntelligence:
            return String(localized: "Built-in Apple model")
        case .gemma:
            return String(localized: "Google's compact local models")
        case .qwen:
            return String(localized: "Alibaba's multilingual family")
        case .granite:
            return String(localized: "IBM's efficient hybrid edge models")
        case .lfm:
            return String(localized: "Liquid AI's on-device family")
        case .exaone:
            return String(localized: "LG AI Research's compact instruction models")
        case .glm:
            return String(localized: "Z.ai's large agentic models")
        case .holo:
            return String(localized: "H Company's computer-use models")
        case .deepSeek:
            return String(localized: "Compact reasoning-style models")
        case .llama:
            return String(localized: "Meta's local instruction models")
        case .muse:
            return String(localized: "Meta's local agentic models")
        case .nemotron:
            return String(localized: "NVIDIA's efficient hybrid models")
        case .miniCPM:
            return String(localized: "OpenBMB's compact on-device models")
        case .phi:
            return String(localized: "Microsoft's efficient reasoning models")
        case .smol:
            return String(localized: "Hugging Face's compact models")
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
        case .granite:
            return "cube.fill"
        case .lfm:
            return "drop.fill"
        case .exaone:
            return "sparkles"
        case .glm:
            return "cpu"
        case .holo:
            return "cursorarrow.motionlines"
        case .deepSeek:
            return "brain.head.profile"
        case .llama:
            return "bubble.left.and.bubble.right.fill"
        case .muse:
            return "sparkles.rectangle.stack.fill"
        case .nemotron:
            return "square.stack.3d.up.fill"
        case .miniCPM:
            return "cpu"
        case .phi:
            return "function"
        case .smol:
            return "smallcircle.filled.circle"
        }
    }

    var logoAssetName: String? {
        switch self {
        case .appleIntelligence:
            return nil
        case .gemma:
            return "ModelLogoGemma"
        case .qwen:
            return "ModelLogoQwen"
        case .granite:
            return "ModelLogoIBM"
        case .lfm:
            return "ModelLogoLiquid"
        case .exaone:
            return "ModelLogoLG"
        case .glm:
            return "ModelLogoZAI"
        case .holo:
            return "ModelLogoHCompany"
        case .deepSeek:
            return "ModelLogoDeepSeek"
        case .llama:
            return "ModelLogoMeta"
        case .muse:
            return "ModelLogoMeta"
        case .nemotron:
            return "ModelLogoNvidia"
        case .miniCPM:
            return nil
        case .phi:
            return "ModelLogoMicrosoft"
        case .smol:
            return "ModelLogoHuggingFace"
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
            return String(localized: "Recommended")
        case .supported:
            return String(localized: "May be slower")
        case .unsupported:
            // "Heavy" fits models that outgrow the device's memory; a GPU that
            // cannot compile MLX kernels at all is a different statement.
            return DeviceResourcePolicy.supportsMLXCompute
                ? String(localized: "Heavy")
                : String(localized: "Unsupported")
        }
    }

    var iconName: String {
        switch self {
        case .recommended:
            return "sparkles"
        case .supported:
            return "tortoise"
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
            return String(localized: "Recommended")
        case .chat:
            return String(localized: "Chat")
        case .images:
            return String(localized: "Images")
        case .fastest:
            return String(localized: "Fastest")
        case .bestForCoding:
            return String(localized: "Coding")
        case .bestForWriting:
            return String(localized: "Writing")
        case .everydayChat:
            return String(localized: "Everyday")
        case .multilingual:
            return String(localized: "Multilingual")
        case .reasoning:
            return String(localized: "Reasoning")
        case .fullyOnDevice:
            return String(localized: "On-Device")
        case .mayUseAppleProcessing:
            return String(localized: "Apple Processing")
        case .smallDownload:
            return String(localized: "Small Download")
        case .higherQuality:
            return String(localized: "Higher Quality")
        case .newerDevices:
            return String(localized: "Newer Devices")
        case .vision:
            return String(localized: "Vision")
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

/// Represents the type of model engine
enum ModelEngine: String, Equatable {
    case appleFoundation = "apple"
    case mlx = "mlx"
}

/// Represents the download state of a model
enum DownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double, speedBytesPerSecond: Double?)
    case validating(progress: Double)
    case downloaded
    case builtin  // For Apple Foundation Model
    case error(message: String)
    
    var isDownloading: Bool {
        if case .downloading = self { return true }
        if case .validating = self { return true }
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

    var requiresUnsupportedMLXQuantization: Bool {
        false
    }

    /// True when this model's weights are too large for the current device's
    /// RAM budget and would risk an out-of-memory (jetsam) termination at load
    /// or inference time. This is the real constraint on low-RAM devices such
    /// as the 4 GB iPhone 11, which chip-generation and disk-size gating miss.
    var exceedsDeviceMemoryBudget: Bool {
        guard engine == .mlx else { return false }
        return sizeGB > DeviceResourcePolicy.current.usableModelBudgetGB
    }

    var currentDeviceFit: ModelDeviceFit {
        guard engine == .mlx else { return .recommended }
        if requiresUnsupportedMLXQuantization { return .unsupported }

        // A13-class GPUs (iPhone 11, SE 2nd gen) cannot compile MLX's Metal
        // kernels; loading any MLX model there aborts the process.
        if !DeviceResourcePolicy.supportsMLXCompute { return .unsupported }

        let device = DeviceResourcePolicy.current

        // Physical-RAM ceiling first: a model that overruns the device memory
        // budget will be jetsam-killed regardless of chip or free disk, so it is
        // never selectable/auto-routable on this device.
        if sizeGB > device.usableModelBudgetGB { return .unsupported }

        if device.isPhone {
            if sizeGB > 4.5 { return .unsupported }
            let major: Int = {
                guard device.hardwareIdentifier.hasPrefix("iPhone"),
                      let text = device.hardwareIdentifier
                        .dropFirst("iPhone".count)
                        .split(separator: ",")
                        .first else { return 0 }
                return Int(text) ?? 0
            }()
            if sizeGB <= 1.6 { return major >= 14 ? .recommended : .supported }
            if sizeGB <= 2.6 { return major >= 15 ? .recommended : .supported }
            return major >= 17 ? .recommended : .supported
        }
        if device.isPad {
            if sizeGB <= 2.6 { return .recommended }
            if sizeGB <= 4.6 { return .supported }
            return .unsupported
        }
        return .recommended
    }

    var recommendationTagText: String? {
        switch currentDeviceFit {
        case .recommended:
            return nil
        case .supported:
            return nil
        case .unsupported:
            return DeviceResourcePolicy.supportsMLXCompute ? "Heavy" : "Unsupported"
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
        if lowercasedID.contains("glm") {
            return "Z.ai (GLM)"
        }
        if lowercasedID.contains("holo") || lowercasedID.contains("hcompany") {
            return "H Company (Holo)"
        }
        if lowercasedID.contains("muse-glimmer") {
            return "Meta Platforms, Inc. (Muse)"
        }
        if lowercasedID.contains("qwen") {
            return "Alibaba Cloud (Qwen)"
        }
        if lowercasedID.contains("granite") {
            return "IBM Granite"
        }
        if lowercasedID.contains("lfm") || lowercasedID.contains("liquidai") {
            return "Liquid AI (LFM 2.5)"
        }
        if lowercasedID.contains("bonsai") {
            return "Prism ML (Bonsai)"
        }
        if lowercasedID.contains("exaone") {
            return "LG AI Research (EXAONE)"
        }
        if lowercasedID.contains("nemotron") {
            return "NVIDIA (Nemotron)"
        }
        if lowercasedID.contains("minicpm") {
            return "OpenBMB (MiniCPM)"
        }
        if lowercasedID.contains("tinyllama") {
            return "TinyLlama Project"
        }
        if lowercasedID.contains("llama") {
            return "Meta Platforms, Inc. (Llama)"
        }
        if lowercasedID.contains("phi") {
            return "Microsoft (Phi)"
        }
        if lowercasedID.contains("smol") {
            return "HuggingFace (Smol)"
        }
        return "Model publisher"
    }

    /// Whether to offer the thinking pill. The toggle is only honest for
    /// models whose chat template reads `enable_thinking` — flipping it has to
    /// actually change the rendered prompt.
    static func supportsThinkingToggle(modelID: String) -> Bool {
        if optionalReasoningPrefixMLXModelIDs.contains(modelID) { return true }
        let lowercasedID = modelID.lowercased()
        return lowercasedID.contains("qwen3") || lowercasedID.contains("gemma-4") || lowercasedID.contains("bonsai")
    }

    var supportsThinkingToggle: Bool {
        ModelInfo.supportsThinkingToggle(modelID: id)
    }

    static func thinkingPreferenceKey(modelID: String) -> String {
        "modelThinkingEnabled.\(modelID)"
    }

    var thinkingPreferenceKey: String {
        ModelInfo.thinkingPreferenceKey(modelID: id)
    }

    static let defaultThinkingEnabled = false

    var defaultThinkingEnabled: Bool {
        ModelInfo.defaultThinkingEnabled
    }

    /// The thinking mode a generation should run in, resolved from the stored
    /// per-model preference. Keyed by model ID so the engine can resolve it
    /// without a `ModelInfo` in hand. Models without the toggle never reason:
    /// a phone-sized model burning its whole response budget on hidden
    /// reasoning reads as a hung app.
    static func resolvedThinkingEnabled(modelID: String) -> Bool {
        guard supportsThinkingToggle(modelID: modelID) else { return false }
        let defaults = UserDefaults.standard
        let key = thinkingPreferenceKey(modelID: modelID)
        guard defaults.object(forKey: key) != nil else { return defaultThinkingEnabled }
        return defaults.bool(forKey: key)
    }

    var privacyLabel: String {
        isAppleFoundation ? "May use Apple processing" : "Fully on-device"
    }

    /// Set of MLX model IDs that support vision (VLM models).
    static let vlmMLXModelIDs: Set<String> = [
        "mlx-community/Qwen2-VL-2B-Instruct-4bit",
        "mlx-community/Qwen2.5-VL-3B-Instruct-3bit",
        "LiquidAI/LFM2.5-VL-450M-MLX-6bit",
        "mlx-community/gemma-4-e2b-it-4bit",
        "mlx-community/gemma-4-e4b-it-4bit",
        "mlx-community/gemma-4-26b-a4b-it-4bit",
        "mlx-community/translategemma-4b-it-4bit",
        "mlx-community/SmolVLM2-256M-Video-Instruct-mlx",
        "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
        "mlx-community/SmolVLM2-2.2B-Instruct-mlx",
        "Hcompany/Holo-3.1-0.8B",
        "Hcompany/Holo-3.1-4B",
        "mlx-community/Muse-Glimmer-30B-4bit"
    ]

    var supportsVision: Bool {
        engine == .appleFoundation || ModelInfo.vlmMLXModelIDs.contains(id)
    }

    /// MLX models whose chat template pre-fills an opening `<think>` into the
    /// generation prompt when thinking is on, so the response begins *inside*
    /// the reasoning block and the model only ever emits the closing
    /// `</think>`. Their raw output has to be treated as reasoning from the
    /// very first token, or the chain of thought streams into the bubble as if
    /// it were the answer. With `enable_thinking: false` these same templates
    /// emit a closed `<think></think>` instead, so the response is the answer.
    static let optionalReasoningPrefixMLXModelIDs: Set<String> = [
        "mlx-community/MiniCPM5-1B-OptiQ-4bit",
        "mlx-community/NVIDIA-Nemotron-3-Nano-4B-OptiQ-4bit",
        "mlx-community/Qwen3.5-0.8B-OptiQ-4bit",
        "mlx-community/Qwen3.5-2B-OptiQ-4bit",
        "mlx-community/Qwen3.5-4B-OptiQ-4bit",
        "mlx-community/Qwen3.5-9B-OptiQ-4bit",
        "catalystsec/GLM-5.1-4bit",
        "Hcompany/Holo-3.1-0.8B",
        "Hcompany/Holo-3.1-4B"
    ]

    /// Same pre-filled `<think>`, except these templates have no thinking
    /// switch at all — they always open the block, so their responses are
    /// always reasoning-first no matter what the preference says.
    static let alwaysReasoningPrefixMLXModelIDs: Set<String> = [
        "mlx-community/DeepSeek-R1-Distill-Qwen-1.5B-4bit",
        "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit",
        "mlx-community/LFM2.5-2.6B-4bit"
    ]

    static func opensResponseInsideReasoningBlock(modelID: String, thinkingEnabled: Bool) -> Bool {
        if alwaysReasoningPrefixMLXModelIDs.contains(modelID) { return true }
        return thinkingEnabled && optionalReasoningPrefixMLXModelIDs.contains(modelID)
    }

    /// MLX models whose weights ship inside the app bundle (BundledModels/), so they
    /// work with no download. Deleting one hides it until the user adds it back; the
    /// weights themselves stay in the app, so no storage is freed.
    static let bundledMLXModelIDs: Set<String> = [
        qwen3_0_6b_4bit.id
    ]

    var isBundled: Bool {
        ModelInfo.bundledMLXModelIDs.contains(id)
    }

    /// Whether this model is experimental and should only be shown on macOS.
    var isMacExperimental: Bool {
        id == "catalystsec/GLM-5.1-4bit"
    }

    var isTranslateGemma: Bool {
        id == "mlx-community/translategemma-4b-it-4bit"
    }

    var sizeLabel: String {
        if engine == .appleFoundation {
            return String(localized: "No download")
        }
        if isBundled {
            return String(localized: "Included")
        }
        return String(format: "%.1f GB", sizeGB)
    }
}

// MARK: - Available Models
extension ModelInfo {
    /// Apple's on-device Foundation Model (built into iOS 26+)
    static let appleFoundation = ModelInfo(
        id: "apple-foundation",
        name: String(localized: "Apple Intelligence"),
        description: String(localized: "Apple's on-device model. Fast, private, and built right into your device. No download required."),
        family: .appleIntelligence,
        sizeGB: 0,
        engine: .appleFoundation,
        termsURL: URL(string: "https://www.apple.com/legal/privacy/data/en/intelligence-engine/"),
        privacyURL: URL(string: "https://www.apple.com/legal/privacy/data/en/intelligence-engine/"),
        shortDescription: String(localized: "Built in, quick to start, and best for everyday use."),
        recommendedFor: String(localized: "Best for everyday questions when Apple Intelligence is available."),
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
        badges: [.recommended, .chat, .fullyOnDevice],
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

    /// LFM2.5 VL 450M MLX (6-bit)
    static let lfm25_vl_450m_6bit = ModelInfo(
        id: "LiquidAI/LFM2.5-VL-450M-MLX-6bit",
        name: "LFM 2.5 VL 450M",
        description: "Liquid AI's tiny vision-language model for fast on-device image understanding, OCR, visual grounding, and multilingual visual Q&A.",
        family: .lfm,
        sizeGB: 0.47,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/LiquidAI/LFM2.5-VL-450M-MLX-6bit"),
        privacyURL: nil,
        shortDescription: "Tiny vision-language model for fast image understanding.",
        recommendedFor: "Best when you want the lightest image-capable local model for iPhone.",
        badges: [.images, .vision, .smallDownload, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Granite 4.0 H 1B (4-bit MLX)
    static let granite4_0_h_1b_4bit = ModelInfo(
        id: "mlx-community/granite-4.0-h-1b-4bit",
        name: "Granite 4.0 H 1B",
        description: "IBM's compact hybrid Granite model with a strong size-to-quality tradeoff for iPhone and iPad.",
        family: .granite,
        sizeGB: 1.2,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/ibm-granite/granite-4.0-h-1b"),
        privacyURL: nil,
        shortDescription: "Compact Granite model with good quality for its size.",
        recommendedFor: "Best when you want a light Granite 4.0 option for everyday chat.",
        badges: [.recommended, .everydayChat, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Granite 4.0 H Micro (4-bit MLX)
    static let granite4_0_h_micro_4bit = ModelInfo(
        id: "mlx-community/granite-4.0-h-micro-4bit",
        name: "Granite 4.0 H Micro",
        description: "IBM's 3B hybrid Granite model, optimized for strong efficiency on modern iPhones while keeping the footprint moderate.",
        family: .granite,
        sizeGB: 1.81,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/ibm-granite/granite-4.0-h-micro"),
        privacyURL: nil,
        shortDescription: "Efficient Granite model for balanced quality and speed.",
        recommendedFor: "Best when you want the strongest compact Granite 4.0 option.",
        badges: [.higherQuality, .everydayChat, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Granite 4.0 H Tiny (4-bit MLX)
    static let granite4_0_h_tiny_4bit = ModelInfo(
        id: "mlx-community/granite-4.0-h-tiny-4bit",
        name: "Granite 4.0 H Tiny",
        description: "IBM's larger hybrid Granite model with excellent efficiency for its class, aimed at newer iPhones with more thermal and memory headroom.",
        family: .granite,
        sizeGB: 3.92,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/ibm-granite/granite-4.0-h-tiny"),
        privacyURL: nil,
        shortDescription: "Larger Granite model for newer iPhone hardware.",
        recommendedFor: "Best when you want the most capable Granite 4.0 model in this family.",
        badges: [.higherQuality, .newerDevices, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Granite 4.1 3B (4-bit MLX)
    static let granite4_1_3b_4bit = ModelInfo(
        id: "mlx-community/granite-4.1-3b-4bit",
        name: "Granite 4.1 3B",
        description: "IBM's newer Granite 4.1 model with efficient instruction following and balanced local quality for modern iPhones and iPads.",
        family: .granite,
        sizeGB: 2.13,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/ibm-granite/granite-4.1-3b"),
        privacyURL: nil,
        shortDescription: "Newer Granite model with balanced local quality.",
        recommendedFor: "Best when you want a current Granite option that stays practical on newer iPhones.",
        badges: [.higherQuality, .everydayChat, .newerDevices, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// LFM2.5 230M MLX (4-bit)
    static let lfm25_230m_4bit = ModelInfo(
        id: "LiquidAI/LFM2.5-230M-MLX-4bit",
        name: "LFM 2.5 230M",
        description: "Liquid AI's smallest LFM 2.5 chat model, built for extremely fast fully local replies with a tiny download.",
        family: .lfm,
        sizeGB: 0.14,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/LiquidAI/LFM2.5-230M-MLX-4bit"),
        privacyURL: nil,
        shortDescription: "Tiny LFM model for the fastest local replies.",
        recommendedFor: "Best when storage, download size, and startup speed matter most.",
        badges: [.fastest, .smallDownload, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// LFM2.5 350M MLX (4-bit)
    static let lfm25_350m_4bit = ModelInfo(
        id: "LiquidAI/LFM2.5-350M-MLX-4bit",
        name: "LFM 2.5 350M",
        description: "Liquid AI's ultra-light LFM 2.5 model, offering a little more capability than the 230M tier while keeping the download very small.",
        family: .lfm,
        sizeGB: 0.21,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/LiquidAI/LFM2.5-350M-MLX-4bit"),
        privacyURL: nil,
        shortDescription: "Very small LFM model with a bit more headroom.",
        recommendedFor: "Best when you want a tiny on-device assistant with slightly richer answers.",
        badges: [.fastest, .smallDownload, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// LFM2.5 1.2B Instruct MLX (4-bit)
    static let lfm25_1_2b_instruct_4bit = ModelInfo(
        id: "LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit",
        name: "LFM 2.5 1.2B",
        description: "Liquid AI's everyday LFM 2.5 model, tuned for chat, extraction, writing, and longer conversations on iPhone.",
        family: .lfm,
        sizeGB: 0.63,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit"),
        privacyURL: nil,
        shortDescription: "Balanced compact model for everyday local use.",
        recommendedFor: "Best when you want the main everyday LFM 2.5 model on iPhone.",
        badges: [.recommended, .everydayChat, .higherQuality, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// LFM2.5 1.2B JP 202606 MLX (4-bit)
    static let lfm25_1_2b_jp_202606_4bit = ModelInfo(
        id: "LiquidAI/LFM2.5-1.2B-JP-202606-MLX-4bit",
        name: "LFM 2.5 JP 1.2B",
        description: "Liquid AI's Japanese-focused LFM 2.5 model with English support, tuned for compact multilingual chat on Apple devices.",
        family: .lfm,
        sizeGB: 0.65,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/LiquidAI/LFM2.5-1.2B-JP-202606-MLX-4bit"),
        privacyURL: nil,
        shortDescription: "Compact Japanese and English LFM model.",
        recommendedFor: "Best when you want stronger Japanese local chat in a small download.",
        badges: [.multilingual, .smallDownload, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// LFM2.5 1.2B Thinking MLX (4-bit)
    static let lfm25_1_2b_thinking_4bit = ModelInfo(
        id: "LiquidAI/LFM2.5-1.2B-Thinking-MLX-4bit",
        name: "LFM 2.5 Thinking",
        description: "Liquid AI's reasoning-focused LFM 2.5 model. It is optimized for structured reasoning, math, and programming with an iPhone-friendly footprint.",
        family: .lfm,
        sizeGB: 0.63,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/LiquidAI/LFM2.5-1.2B-Thinking-MLX-4bit"),
        privacyURL: nil,
        shortDescription: "Reasoning-first LFM 2.5 model with a compact download.",
        recommendedFor: "Best when you want the LFM 2.5 reasoning variant for technical prompts.",
        badges: [.bestForCoding, .reasoning, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// LFM2.5 2.6B MLX (4-bit)
    static let lfm25_2_6b_4bit = ModelInfo(
        id: "mlx-community/LFM2.5-2.6B-4bit",
        name: "LFM 2.5 2.6B",
        description: "Liquid AI's current mid-size LFM 2.5 model, offering stronger multilingual chat, reasoning, coding, and instruction following while remaining practical on newer iPhones and iPads.",
        family: .lfm,
        sizeGB: 1.54,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/mlx-community/LFM2.5-2.6B-4bit"),
        privacyURL: nil,
        shortDescription: "Stronger multilingual LFM model with an iPhone-friendly footprint.",
        recommendedFor: "Best when you want a noticeable quality step up from the smallest LFM models without moving to a large download.",
        badges: [.recommended, .everydayChat, .multilingual, .reasoning, .higherQuality, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// LFM2.5 8B-A1B MLX (4-bit)
    static let lfm25_8b_a1b_4bit = ModelInfo(
        id: "LiquidAI/LFM2.5-8B-A1B-MLX-4bit",
        name: "LFM 2.5 8B-A1B",
        description: "Liquid AI's mixture-of-experts LFM 2.5 model, aimed at stronger local quality on iPad Pro and Mac-class Apple Silicon.",
        family: .lfm,
        sizeGB: 4.52,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/LiquidAI/LFM2.5-8B-A1B-MLX-4bit"),
        privacyURL: nil,
        shortDescription: "High-end LFM 2.5 MoE model for larger devices.",
        recommendedFor: "Best when you want stronger LFM 2.5 output and have iPad Pro or Mac headroom.",
        badges: [.higherQuality, .reasoning, .newerDevices, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// LFM2.5 VL 1.6B MLX (4-bit)
    static let lfm25_vl_1_6b_4bit = ModelInfo(
        id: "mlx-community/LFM2.5-VL-1.6B-4bit",
        name: "LFM 2.5 VL 1.6B",
        description: "Liquid AI's vision-language LFM 2.5 variant, converted to MLX for image understanding, document reading, and visual Q&A on newer iPhones and iPads.",
        family: .lfm,
        sizeGB: 1.49,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/LiquidAI/LFM2.5-VL-1.6B"),
        privacyURL: nil,
        shortDescription: "Vision-language LFM 2.5 for images, screenshots, and documents.",
        recommendedFor: "Best when you want LFM 2.5 with image input on a newer device.",
        badges: [.images, .vision, .higherQuality, .newerDevices, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Holo 3.1 0.8B VLM
    static let holo31_0_8b = ModelInfo(
        id: "Hcompany/Holo-3.1-0.8B",
        name: "Holo 3.1 0.8B",
        description: "H Company's ultra-light computer-use vision-language model, tuned for GUI understanding, screenshots, mobile automation, and local agent workflows.",
        family: .holo,
        sizeGB: 2.08,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/Hcompany/Holo-3.1-0.8B"),
        privacyURL: nil,
        shortDescription: "Small Holo computer-use VLM for screenshots and UI tasks.",
        recommendedFor: "Best when you want the lightest Holo 3.1 model for visual UI understanding.",
        badges: [.images, .vision, .smallDownload, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Holo 3.1 4B VLM
    static let holo31_4b = ModelInfo(
        id: "Hcompany/Holo-3.1-4B",
        name: "Holo 3.1 4B",
        description: "H Company's cost-efficient computer-use vision-language model, based on Qwen3.5 and specialized for GUI understanding, screenshots, and computer-control agent workflows.",
        family: .holo,
        sizeGB: 9.66,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/Hcompany/Holo-3.1-4B"),
        privacyURL: nil,
        shortDescription: "Stronger Holo computer-use VLM for UI and screenshot tasks.",
        recommendedFor: "Best when you want stronger Holo 3.1 visual UI understanding and have Mac-class device headroom.",
        badges: [.images, .vision, .higherQuality, .newerDevices, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Qwen3 0.6B MLX (4-bit)
    static let qwen3_0_6b_4bit = ModelInfo(
        id: "Qwen/Qwen3-0.6B-MLX-4bit",
        name: "Qwen3 0.6B",
        description: "Qwen's smallest official MLX Qwen3 model, tuned for quick multilingual local chat with a very small footprint.",
        family: .qwen,
        sizeGB: 0.31,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/Qwen/Qwen3-0.6B-MLX-4bit"),
        privacyURL: nil,
        shortDescription: "Tiny official Qwen3 model for quick local chat.",
        recommendedFor: "Best when you want Qwen-style multilingual replies in a tiny download.",
        badges: [.fastest, .smallDownload, .multilingual, .fullyOnDevice],
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

    /// Qwen3.5 0.8B OptiQ (4-bit MLX)
    static let qwen35_0_8b_optiq_4bit = ModelInfo(
        id: "mlx-community/Qwen3.5-0.8B-OptiQ-4bit",
        name: "Qwen3.5 0.8B OptiQ",
        description: "A compact Qwen3.5 model using OptiQ mixed-precision MLX quantization for stronger quality than tiny models while staying iPhone-friendly.",
        family: .qwen,
        sizeGB: 0.83,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/mlx-community/Qwen3.5-0.8B-OptiQ-4bit"),
        privacyURL: nil,
        shortDescription: "Small Qwen3.5 model with modern OptiQ quantization.",
        recommendedFor: "Best when you want a newer small Qwen model with stronger everyday quality.",
        badges: [.recommended, .multilingual, .smallDownload, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Qwen3.5 2B OptiQ (4-bit MLX)
    static let qwen35_2b_optiq_4bit = ModelInfo(
        id: "mlx-community/Qwen3.5-2B-OptiQ-4bit",
        name: "Qwen3.5 2B OptiQ",
        description: "A newer Qwen3.5 model using OptiQ mixed-precision MLX quantization, giving stronger instruction following and multilingual output while staying practical for modern iPhones.",
        family: .qwen,
        sizeGB: 1.43,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/mlx-community/Qwen3.5-2B-OptiQ-4bit"),
        privacyURL: nil,
        shortDescription: "Newer Qwen3.5 model with stronger everyday quality.",
        recommendedFor: "Best when you want a stronger local Qwen model that still fits comfortably on newer iPhones.",
        badges: [.higherQuality, .multilingual, .newerDevices, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Qwen3.5 4B OptiQ (4-bit MLX)
    static let qwen35_4b_optiq_4bit = ModelInfo(
        id: "mlx-community/Qwen3.5-4B-OptiQ-4bit",
        name: "Qwen3.5 4B OptiQ",
        description: "A stronger Qwen3.5 text model with OptiQ mixed-precision MLX quantization, tuned for high-quality multilingual chat, coding, and reasoning on newer Apple devices.",
        family: .qwen,
        sizeGB: 3.27,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/mlx-community/Qwen3.5-4B-OptiQ-4bit"),
        privacyURL: nil,
        shortDescription: "Stronger Qwen3.5 model with high quality for its size.",
        recommendedFor: "Best when you want a richer Qwen3.5 assistant and have newer-device headroom.",
        badges: [.higherQuality, .bestForCoding, .multilingual, .reasoning, .newerDevices, .fullyOnDevice],
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
        sizeGB: 3.58,
        engine: .mlx,
        termsURL: URL(string: "https://ai.google.dev/gemma/terms"),
        privacyURL: nil,
        shortDescription: "Multimodal Gemma 4 with vision and stronger local reasoning.",
        recommendedFor: "Best when you want higher-quality local chat, image analysis, and reasoning on newer devices.",
        badges: [.images, .reasoning, .higherQuality, .newerDevices, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Gemma 4 E4B Instruct (4-bit MLX)
    static let gemma4_e4b_it_4bit = ModelInfo(
        id: "mlx-community/gemma-4-e4b-it-4bit",
        name: "Gemma 4 (E4B)",
        description: "Google's larger multimodal Gemma 4 model supports text and image input, with stronger reasoning for newer iPads and high-headroom iPhones.",
        family: .gemma,
        sizeGB: 5.22,
        engine: .mlx,
        termsURL: URL(string: "https://ai.google.dev/gemma/terms"),
        privacyURL: nil,
        shortDescription: "Higher-capacity Gemma 4 for richer multimodal reasoning.",
        recommendedFor: "Best when you want the stronger Gemma 4 model and have enough device headroom.",
        badges: [.images, .reasoning, .higherQuality, .newerDevices, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// TranslateGemma 4B Instruct (4-bit MLX)
    static let translategemma4b_it_4bit = ModelInfo(
        id: "mlx-community/translategemma-4b-it-4bit",
        name: "TranslateGemma 4B",
        description: "Google's compact translation model built on Gemma 3, tuned for multilingual translation and image text translation on device.",
        family: .gemma,
        sizeGB: 2.18,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/mlx-community/translategemma-4b-it-4bit"),
        privacyURL: nil,
        shortDescription: "Compact translation model with image text support.",
        recommendedFor: "Best when translation quality matters more than general chat.",
        badges: [.images, .multilingual, .higherQuality, .newerDevices, .fullyOnDevice],
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
        badges: [.recommended, .bestForWriting, .multilingual, .higherQuality, .fullyOnDevice],
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

    /// NVIDIA Nemotron 3 Nano 4B (4-bit MLX, OptiQ mixed precision)
    static let nemotron3_nano_4b_optiq_4bit = ModelInfo(
        id: "mlx-community/NVIDIA-Nemotron-3-Nano-4B-OptiQ-4bit",
        name: "Nemotron 3 Nano 4B",
        description: "NVIDIA's hybrid Mamba-Transformer model, built for efficient long-context work on-device. Runs fully on-device — your data never leaves your device for AI processing.",
        family: .nemotron,
        sizeGB: 3.08,
        engine: .mlx,
        termsURL: URL(string: "https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-nemotron-open-model-license/"),
        privacyURL: nil,
        shortDescription: "Efficient hybrid model that stays fast over long chats.",
        recommendedFor: "Best when you want strong quality on longer conversations on a newer iPhone or iPad.",
        badges: [.higherQuality, .reasoning, .fullyOnDevice],
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

    /// Phi 3 Mini 128K Instruct (4-bit MLX)
    static let phi3_mini_128k_4bit = ModelInfo(
        id: "mlx-community/Phi-3-mini-128k-instruct-4bit",
        name: "Phi 3 Mini 128K",
        description: "Microsoft's compact Phi model with a long context window for bigger prompts, documents, and structured reasoning on iPhone.",
        family: .phi,
        sizeGB: 2.15,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/microsoft/Phi-3-mini-128k-instruct"),
        privacyURL: nil,
        shortDescription: "Compact Phi with a long context window.",
        recommendedFor: "Best when you need a small model that can hold more context.",
        badges: [.bestForCoding, .reasoning, .fullyOnDevice],
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

    /// EXAONE 3.5 2.4B Instruct (4-bit MLX)
    static let exaone35_2_4b_instruct_4bit = ModelInfo(
        id: "mlx-community/EXAONE-3.5-2.4B-Instruct-4bit",
        name: "EXAONE 3.5 2.4B",
        description: "LG AI Research's compact instruction model with a strong size-to-quality tradeoff for modern iPhones and iPads.",
        family: .exaone,
        sizeGB: 1.35,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/LGAI-EXAONE/EXAONE-3.5-2.4B-Instruct"),
        privacyURL: nil,
        shortDescription: "Compact general model with strong quality for its size.",
        recommendedFor: "Good when you want a capable small model that still feels iPhone-friendly.",
        badges: [.higherQuality, .everydayChat, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// SmolLM2 1.7B Instruct (4-bit MLX)
    static let smolLM2_1_7b_4bit = ModelInfo(
        id: "Irfanuruchi/SmolLM2-1.7B-Instruct-MLX-4bit",
        name: "SmolLM2 1.7B",
        description: "HuggingFace's compact SmolLM2, designed for fast on-device chat with surprisingly strong performance for its tiny footprint.",
        family: .smol,
        sizeGB: 1.04,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/HuggingFaceTB/SmolLM2-1.7B-Instruct"),
        privacyURL: nil,
        shortDescription: "Fast and surprisingly capable for its small size.",
        recommendedFor: "Best for quick on-device replies with a minimal download.",
        badges: [.fastest, .smallDownload, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// MiniCPM5 1B OptiQ (mixed 4/8-bit MLX)
    static let miniCPM5_1b_optiq_4bit = ModelInfo(
        id: "mlx-community/MiniCPM5-1B-OptiQ-4bit",
        name: "MiniCPM5 1B OptiQ",
        description: "OpenBMB's compact MiniCPM5 model with sensitivity-aware mixed-precision MLX quantization, hybrid reasoning, and strong coding performance for its size.",
        family: .miniCPM,
        sizeGB: 0.92,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/mlx-community/MiniCPM5-1B-OptiQ-4bit"),
        privacyURL: nil,
        shortDescription: "Tiny modern model with optional reasoning and strong compact coding ability.",
        recommendedFor: "Best when you want a very small English and Chinese model that can switch between quick replies and deeper reasoning.",
        badges: [.smallDownload, .bestForCoding, .multilingual, .reasoning, .fullyOnDevice],
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

    /// Qwen3.5 9B OptiQ (4-bit MLX)
    static let qwen35_9b_optiq_4bit = ModelInfo(
        id: "mlx-community/Qwen3.5-9B-OptiQ-4bit",
        name: "Qwen3.5 9B OptiQ",
        description: "A high-end Qwen3.5 text model with OptiQ mixed-precision MLX quantization for stronger reasoning, coding, and multilingual responses on iPad Pro and Mac-class devices.",
        family: .qwen,
        sizeGB: 6.04,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/mlx-community/Qwen3.5-9B-OptiQ-4bit"),
        privacyURL: nil,
        shortDescription: "High-end Qwen3.5 model for demanding local tasks.",
        recommendedFor: "Best for stronger local coding, reasoning, and multilingual work on high-memory Apple devices.",
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
        family: .smol,
        sizeGB: 1.8,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/HuggingFaceTB/SmolLM3-3B"),
        privacyURL: nil,
        shortDescription: "A compact modern SmolLM with a nice quality-to-size tradeoff.",
        recommendedFor: "Good when you want a lightweight but more capable everyday local assistant.",
        badges: [.smallDownload, .everydayChat, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// SmolVLM2 256M Video Instruct (MLX)
    static let smolVLM2_256m_4bit = ModelInfo(
        id: "mlx-community/SmolVLM2-256M-Video-Instruct-mlx",
        name: "SmolVLM2 256M",
        description: "Hugging Face's tiniest SmolVLM2 vision-language model for very light image and video understanding on device.",
        family: .smol,
        sizeGB: 0.52,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/mlx-community/SmolVLM2-256M-Video-Instruct-mlx"),
        privacyURL: nil,
        shortDescription: "Ultra-small vision model for image and video tasks.",
        recommendedFor: "Best when you want the smallest possible vision-language model.",
        badges: [.images, .vision, .smallDownload, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// SmolVLM2 500M Video Instruct (MLX)
    static let smolVLM2_500m_4bit = ModelInfo(
        id: "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
        name: "SmolVLM2 500M",
        description: "A compact SmolVLM2 model for fast image and video understanding, with a light enough footprint for iPhone-friendly local use.",
        family: .smol,
        sizeGB: 1.02,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/mlx-community/SmolVLM2-500M-Video-Instruct-mlx"),
        privacyURL: nil,
        shortDescription: "Light vision-language model with strong efficiency.",
        recommendedFor: "Best when you want a small but more capable media model.",
        badges: [.images, .vision, .smallDownload, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// SmolVLM2 2.2B Instruct (MLX)
    static let smolVLM2_2_2b_4bit = ModelInfo(
        id: "mlx-community/SmolVLM2-2.2B-Instruct-mlx",
        name: "SmolVLM2 2.2B",
        description: "The strongest SmolVLM2 option here, tuned for better image, multi-image, and video understanding on newer iPhones and iPads.",
        family: .smol,
        sizeGB: 4.49,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/mlx-community/SmolVLM2-2.2B-Instruct-mlx"),
        privacyURL: nil,
        shortDescription: "Higher-quality vision and video model for newer devices.",
        recommendedFor: "Best when you want the strongest SmolVLM2 experience on a newer device.",
        badges: [.images, .vision, .higherQuality, .newerDevices, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// GLM 5.1 (4-bit MLX)
    static let glm51_4bit = ModelInfo(
        id: "catalystsec/GLM-5.1-4bit",
        name: "GLM 5.1",
        description: "Z.ai's flagship agentic engineering model converted to MLX. This is an experimental, extremely large local model intended for very high-memory Apple Silicon systems.",
        family: .glm,
        sizeGB: 419,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/zai-org/GLM-5.1"),
        privacyURL: nil,
        shortDescription: "Experimental flagship GLM model for high-memory Macs.",
        recommendedFor: "Best for experimental coding and long-horizon agentic tasks on machines with hundreds of GB of memory.",
        badges: [.bestForCoding, .reasoning, .higherQuality, .fullyOnDevice],
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

    /// Qwen3-Coder-Next (4-bit MLX)
    static let qwen3_coder_next_4bit = ModelInfo(
        id: "mlx-community/Qwen3-Coder-Next-4bit",
        name: "Qwen3 Coder Next",
        description: "Alibaba's specialized Mixture-of-Experts coding model. Runs fast while delivering high-quality programming assistance and technical logic.",
        family: .qwen,
        sizeGB: 2.30,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/Qwen/Qwen3-Coder-Next"),
        privacyURL: nil,
        shortDescription: "Dedicated high-performance coding assistant.",
        recommendedFor: "Best for developers wanting a very smart on-device copilot.",
        badges: [.bestForCoding, .fastest, .higherQuality, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    /// Muse Glimmer 30B (4-bit MLX)
    static let muse_glimmer_30b_4bit = ModelInfo(
        id: "mlx-community/Muse-Glimmer-30B-4bit",
        name: "Muse Glimmer 30B",
        description: "Meta's multimodal agentic model for long-horizon reasoning, coding, tool use, and image understanding on high-memory Apple Silicon Macs.",
        family: .muse,
        sizeGB: 21.38,
        engine: .mlx,
        termsURL: URL(string: "https://huggingface.co/meta-models/Muse-Glimmer-30B"),
        privacyURL: nil,
        shortDescription: "High-end multimodal agent for demanding local workflows.",
        recommendedFor: "Best for coding, complex reasoning, and image-aware agentic work on Macs with at least 32 GB of unified memory.",
        badges: [.images, .vision, .bestForCoding, .reasoning, .multilingual, .higherQuality, .fullyOnDevice],
        downloadState: .notDownloaded
    )

    static let releasedModels: [ModelInfo] = [
        .appleFoundation,  // Default - first in list
        // Ultra-light and compact (0.1–1.1 GB)
        .lfm25_230m_4bit,
        .lfm25_350m_4bit,
        .qwen3_0_6b_4bit,
        .lfm25_1_2b_jp_202606_4bit,
        .qwen35_0_8b_optiq_4bit,
        .llama32_1b_4bit,
        .gemma3_1b_qat_4bit,
        .granite4_0_h_1b_4bit,
        .miniCPM5_1b_optiq_4bit,
        .smolLM2_1_7b_4bit,
        .qwen25_1_5b_instruct_4bit,
        .qwen3_1_7b_4bit,
        .deepseek_r1_distill_qwen_1_5b_4bit,
        // Vision  (VLM - image input capable)
        .lfm25_vl_450m_6bit,
        .smolVLM2_256m_4bit,
        .smolVLM2_500m_4bit,
        .holo31_0_8b,
        .smolVLM2_2_2b_4bit,
        .qwen2VL_2b_4bit,
        .lfm25_vl_1_6b_4bit,
        .qwen25VL_3b_3bit,
        // Mid-range (1.7–4 GB)
        .gemma3n_e2b_it_lm_4bit,
        .gemma2_2b_4bit,
        .granite4_0_h_micro_4bit,
        .granite4_1_3b_4bit,
        .granite4_0_h_tiny_4bit,
        .smolLM3_3b_4bit,
        .lfm25_1_2b_instruct_4bit,
        .lfm25_1_2b_thinking_4bit,
        .lfm25_2_6b_4bit,
        .exaone35_2_4b_instruct_4bit,
        .qwen35_2b_optiq_4bit,
        .qwen35_4b_optiq_4bit,
        .qwen25_3b_instruct_4bit,
        .qwen3_coder_next_4bit,
        .llama32_3b_4bit,
        .nemotron3_nano_4b_optiq_4bit,
        .phi3_mini_128k_4bit,
        .phi3_mini_4k_4bit,
        .phi4_mini_4bit,
        .phi35_mini_4bit,
        .gemma3_4b_qat_4bit,
        .gemma4_e2b_it_4bit,
        .translategemma4b_it_4bit,
        .qwen3_4b_4bit,
        // Large (4+ GB) — iPad Pro / Mac
        .deepseek_r1_distill_qwen_7b_4bit,
        .lfm25_8b_a1b_4bit,
        .glm51_4bit,
        .qwen25_7b_instruct_4bit,
        .llama31_8b_4bit,
        .qwen3_8b_4bit,
        .qwen35_9b_optiq_4bit,
        .gemma4_e4b_it_4bit,
        .holo31_4b,
        .muse_glimmer_30b_4bit
    ]

    /// Definitions retained for compatibility and real-device readiness work.
    /// They are intentionally unavailable to the production catalog and router.
    static let evaluationModels: [ModelInfo] = []

    static let allModels: [ModelInfo] = releasedModels
}
