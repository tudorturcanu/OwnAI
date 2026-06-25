//
//  MLXStorage.swift
//  LocalAI
//
//  Created by Codex on 06.02.2026.
//

import Foundation

enum MLXStorage {
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
    }

    static func removeIncompleteModelArtifacts(for modelID: String) {
        guard !hasValidModelArtifacts(for: modelID) else { return }
        removeModelArtifacts(for: modelID)
    }

    static func hasValidModelArtifacts(for modelID: String) -> Bool {
        validationReport(for: modelID).isValid
    }

    static func validationReport(for modelID: String) -> ArtifactValidationReport {
        let candidates = [
            modelDirectory(for: modelID),
            legacyModelDirectory(for: modelID),
            legacyHubModelDirectory(for: modelID),
            legacyDocumentsModelDirectory(for: modelID)
        ]

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
            let hasRequiredProcessorConfig = !ModelInfo.vlmMLXModelIDs.contains(modelID) || hasProcessorConfig
            if hasConfig && hasWeights && (hasTokenizer || (hasVocab && hasMerges)) && hasRequiredProcessorConfig {
                return ArtifactValidationReport(isValid: true, checkedDirectory: directory, missingRequirements: [])
            }
        }

        let hasRequiredProcessorConfig = !ModelInfo.vlmMLXModelIDs.contains(modelID) || hasProcessorConfig
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
}
