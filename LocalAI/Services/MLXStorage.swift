//
//  MLXStorage.swift
//  LocalAI
//
//  Created by Codex on 06.02.2026.
//

import Foundation

/// Pure file-system work with no shared state, so it stays off the main actor
/// and can be called from the download, import and model-load paths alike.
nonisolated enum MLXStorage {
    /// Files that make up an MLX checkpoint. Doubles as the Hub download
    /// allowlist and as the copy allowlist for user-imported folders, so a
    /// snapshot from either path contains the same set of artifacts (and no
    /// README, sample images or `.git` directory riding along).
    static let modelArtifactGlobs = [
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

    /// True when `filename` matches one of `modelArtifactGlobs`.
    static func isModelArtifact(_ filename: String) -> Bool {
        let name = filename.lowercased()
        return modelArtifactGlobs.contains { glob in
            let pattern = glob.lowercased()
            if pattern.hasPrefix("*") {
                return name.hasSuffix(String(pattern.dropFirst()))
            }
            return name == pattern
        }
    }

    struct ArtifactValidationReport: Equatable {
        let isValid: Bool
        let checkedDirectory: URL?
        let missingRequirements: [String]

        var message: String {
            guard !isValid else { return "Model artifacts are valid." }
            guard !missingRequirements.isEmpty else { return "Model artifacts were not found." }
            return "Missing model artifacts: \(missingRequirements.joined(separator: ", "))."
        }
    }

    static func persistentBaseURL() -> URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("models", isDirectory: true)
    }

    static func legacyModelsBaseURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("models", isDirectory: true)
    }

    static func legacyHubCacheURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("huggingface/hub", isDirectory: true)
    }

    static func legacyDocumentsModelsBaseURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("huggingface/models", isDirectory: true)
    }

    static func modelDirectory(for modelID: String) -> URL {
        persistentBaseURL().appendingPathComponent(modelID, isDirectory: true)
    }

    static func rollbackDirectory(for modelID: String) -> URL {
        modelDirectory(for: modelID).appendingPathExtension("rollback")
    }

    static func storedBytes(for modelID: String) -> UInt64 {
        directoryBytes(at: modelDirectory(for: modelID))
    }

    static func partialDownloadBytes(for modelID: String) -> UInt64 {
        guard !hasValidModelArtifacts(for: modelID) else { return 0 }
        return directoryBytes(at: modelDirectory(for: modelID))
    }

    static func prepareRollback(for modelID: String) -> Bool {
        let source = modelDirectory(for: modelID)
        guard validationReport(for: modelID).isValid,
              FileManager.default.fileExists(atPath: source.path) else { return false }
        let backup = rollbackDirectory(for: modelID)
        try? FileManager.default.removeItem(at: backup)
        do {
            try FileManager.default.moveItem(at: source, to: backup)
            return true
        } catch {
            return false
        }
    }

    static func restoreRollback(for modelID: String) -> Bool {
        let backup = rollbackDirectory(for: modelID)
        guard FileManager.default.fileExists(atPath: backup.path) else { return false }
        let destination = modelDirectory(for: modelID)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: backup, to: destination)
            return validationReport(for: modelID).isValid
        } catch {
            return false
        }
    }

    static func discardRollback(for modelID: String) {
        try? FileManager.default.removeItem(at: rollbackDirectory(for: modelID))
    }

    /// Directory of a model that ships inside the app bundle (read-only),
    /// or nil when this model is not bundled.
    static func bundledModelDirectory(for modelID: String) -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let directory = resourceURL
            .appendingPathComponent("BundledModels", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return directory
    }

    static func legacyModelDirectory(for modelID: String) -> URL {
        legacyModelsBaseURL().appendingPathComponent(modelID, isDirectory: true)
    }

    static func legacyHubModelDirectory(for modelID: String) -> URL {
        let modelDirName = "models--\(modelID.replacingOccurrences(of: "/", with: "--"))"
        return legacyHubCacheURL().appendingPathComponent(modelDirName, isDirectory: true)
    }

    static func legacyDocumentsModelDirectory(for modelID: String) -> URL {
        legacyDocumentsModelsBaseURL().appendingPathComponent(modelID, isDirectory: true)
    }

    static func ensurePersistentDirectories() {
        try? FileManager.default.createDirectory(at: persistentBaseURL(), withIntermediateDirectories: true)
    }

    /// Some published checkpoints omit config.json fields that the Swift model
    /// ports decode as required even though the architecture never uses them.
    /// Dense Nemotron-H models (no "E" layers in hybrid_override_pattern) ship
    /// without the MoE fields, but NemotronHConfiguration requires them, so
    /// loading fails with "Missing field 'moe_intermediate_size'". Fill the
    /// gaps with inert defaults so decoding succeeds.
    static func normalizeConfigIfNeeded(in directory: URL) {
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              var config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let modelType = config["model_type"] as? String else { return }

        var didChange = false
        if modelType == "nemotron_h" {
            let requiredMoEKeys = [
                "moe_intermediate_size",
                "moe_shared_expert_intermediate_size",
                "n_routed_experts",
                "num_experts_per_tok"
            ]
            for key in requiredMoEKeys where config[key] == nil {
                config[key] = 0
                didChange = true
            }
        }

        guard didChange,
              let updated = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? updated.write(to: configURL, options: .atomic)
    }

    static func removeModelArtifacts(for modelID: String) {
        let candidates = [
            modelDirectory(for: modelID),
            legacyModelDirectory(for: modelID),
            legacyHubModelDirectory(for: modelID),
            legacyDocumentsModelDirectory(for: modelID)
        ]
        for candidate in candidates {
            try? FileManager.default.removeItem(at: candidate)
        }
        discardRollback(for: modelID)
    }

    static func removeCurrentArtifactsPreservingRollback(for modelID: String) {
        let candidates = [
            modelDirectory(for: modelID),
            legacyModelDirectory(for: modelID),
            legacyHubModelDirectory(for: modelID),
            legacyDocumentsModelDirectory(for: modelID)
        ]
        for candidate in candidates {
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    static func removeIncompleteModelArtifacts(for modelID: String) {
        guard !hasValidModelArtifacts(for: modelID) else { return }
        removeModelArtifacts(for: modelID)
    }

    static func hasValidModelArtifacts(for modelID: String) -> Bool {
        validationReport(for: modelID).isValid
    }

    static func validationReport(for modelID: String) -> ArtifactValidationReport {
        // The bundled copy comes first: it is always complete, and it must win
        // even after deleteModel removed the writable candidates.
        let candidates = [
            bundledModelDirectory(for: modelID),
            modelDirectory(for: modelID),
            legacyModelDirectory(for: modelID),
            legacyHubModelDirectory(for: modelID),
            legacyDocumentsModelDirectory(for: modelID)
        ].compactMap { $0 }

        var bestReport = ArtifactValidationReport(
            isValid: false,
            checkedDirectory: nil,
            missingRequirements: []
        )

        for candidate in candidates {
            let report = validateArtifacts(at: candidate, modelID: modelID)
            if report.isValid {
                return report
            }
            if report.checkedDirectory != nil {
                bestReport = report
            }
        }
        return bestReport
    }

    private static func validateArtifacts(at directory: URL, modelID: String) -> ArtifactValidationReport {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return ArtifactValidationReport(isValid: false, checkedDirectory: nil, missingRequirements: [])
        }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return ArtifactValidationReport(
                isValid: false,
                checkedDirectory: directory,
                missingRequirements: ["readable model directory"]
            )
        }

        // Hoisted: this used to be a static-set lookup, but imported models make
        // it a potential lock + allocation, and the loop below runs per file.
        let requiresProcessorConfig = ModelInfo.isVisionModel(modelID)

        var hasConfig = false
        var hasTokenizer = false
        var hasWeights = false
        var hasVocab = false
        var hasMerges = false
        var hasProcessorConfig = false

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 else {
                continue
            }
            let filename = fileURL.lastPathComponent.lowercased()
            if filename == "config.json" || filename == "params.json" {
                hasConfig = true
            }
            if filename == "tokenizer.json" || filename == "tokenizer.model" || filename == "sentencepiece.bpe.model" {
                hasTokenizer = true
            }
            if filename == "vocab.json" {
                hasVocab = true
            }
            if filename == "processor_config.json" || filename == "preprocessor_config.json" || filename == "image_processor_config.json" {
                hasProcessorConfig = true
            }
            if filename == "merges.txt" {
                hasMerges = true
            }
            if filename.hasSuffix(".safetensors") || filename.hasSuffix(".bin") {
                hasWeights = true
            }
            let hasRequiredProcessorConfig = !requiresProcessorConfig || hasProcessorConfig
            if hasConfig && hasWeights && (hasTokenizer || (hasVocab && hasMerges)) && hasRequiredProcessorConfig {
                return ArtifactValidationReport(isValid: true, checkedDirectory: directory, missingRequirements: [])
            }
        }

        let hasRequiredProcessorConfig = !requiresProcessorConfig || hasProcessorConfig
        var missingRequirements: [String] = []
        if !hasConfig {
            missingRequirements.append("config.json or params.json")
        }
        if !hasWeights {
            missingRequirements.append("model weights")
        }
        if !(hasTokenizer || (hasVocab && hasMerges)) {
            missingRequirements.append("tokenizer")
        }
        if !hasRequiredProcessorConfig {
            missingRequirements.append("vision processor config")
        }

        return ArtifactValidationReport(
            isValid: false,
            checkedDirectory: directory,
            missingRequirements: missingRequirements
        )
    }

    private static func directoryBytes(at directory: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += UInt64(max(0, values?.fileSize ?? 0))
            }
        }
        return total
    }
}
