//
//  ModelHealth.swift
//  LocalAI
//
//  Created by Codex on 06.02.2026.
//

import Foundation

struct ModelQuickTestResult: Codable, Equatable {
    let modelID: String
    let success: Bool
    let responseSnippet: String
    let durationMs: Int
    let timestamp: Date
}

@MainActor
final class ModelHealthStore {
    static let shared = ModelHealthStore()

    private let storageKey = "modelQuickTestResults"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    func loadResults() -> [String: ModelQuickTestResult] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return [:]
        }
        return (try? decoder.decode([String: ModelQuickTestResult].self, from: data)) ?? [:]
    }

    func saveResult(_ result: ModelQuickTestResult) {
        var current = loadResults()
        current[result.modelID] = result
        if let data = try? encoder.encode(current) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
