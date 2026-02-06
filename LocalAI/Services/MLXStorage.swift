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
}
