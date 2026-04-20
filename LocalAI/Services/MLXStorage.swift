//
//  MLXStorage.swift
//  LocalAI
//
//  Created by Codex on 06.02.2026.
//

import Foundation

enum MLXStorage {
    static func persistentBaseURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("models", isDirectory: true)
    }

    static func legacyModelsBaseURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("models", isDirectory: true)
    }

    static func legacyHubCacheURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("huggingface/hub", isDirectory: true)
    }

    static func legacyDocumentsModelsBaseURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
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

    static func hasValidModelArtifacts(for modelID: String) -> Bool {
        let candidates = [
            modelDirectory(for: modelID),
            legacyModelDirectory(for: modelID),
            legacyHubModelDirectory(for: modelID),
            legacyDocumentsModelDirectory(for: modelID)
        ]

        for candidate in candidates {
            if containsValidArtifacts(at: candidate, modelID: modelID) {
                return true
            }
        }
        return false
    }

    private static func containsValidArtifacts(at directory: URL, modelID: String) -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return false
        }

        var hasConfig = false
        var hasTokenizer = false
        var hasWeights = false
        var hasVocab = false
        var hasMerges = false
        var hasProcessorConfig = false

        for case let fileURL as URL in enumerator {
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
                return true
            }
        }

        let hasRequiredProcessorConfig = !ModelInfo.vlmMLXModelIDs.contains(modelID) || hasProcessorConfig
        return hasConfig && hasWeights && (hasTokenizer || (hasVocab && hasMerges)) && hasRequiredProcessorConfig
    }
}
