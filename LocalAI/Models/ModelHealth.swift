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
    var loadDurationMs: Int? = nil
    var generationDurationMs: Int? = nil
    var medianFirstTokenMs: Int? = nil
    var peakResidentMemoryBytes: UInt64? = nil
    var physicalMemoryBytes: UInt64? = nil
    var hardwareIdentifier: String? = nil
    var operatingSystem: String? = nil

    func applies(to policy: DeviceResourcePolicy) -> Bool {
        guard let physicalMemoryBytes,
              let hardwareIdentifier else { return false }
        let tolerance = max(policy.physicalMemoryBytes / 20, 1)
        let memoryMatches = physicalMemoryBytes >= policy.physicalMemoryBytes - tolerance &&
            physicalMemoryBytes <= policy.physicalMemoryBytes + tolerance
        return memoryMatches && hardwareIdentifier == policy.hardwareIdentifier && isCurrent
    }

    var isCurrent: Bool {
        Date().timeIntervalSince(timestamp) < 30 * 24 * 60 * 60
    }
}

struct ModelRuntimeMemoryMeasurement: Codable, Equatable {
    let modelID: String
    let peakResidentMemoryBytes: UInt64
    let physicalMemoryBytes: UInt64
    let hardwareIdentifier: String
    let timestamp: Date
    let operatingSystem: String

    func applies(to policy: DeviceResourcePolicy) -> Bool {
        let tolerance = max(policy.physicalMemoryBytes / 20, 1)
        let memoryMatches = physicalMemoryBytes >= policy.physicalMemoryBytes - tolerance &&
            physicalMemoryBytes <= policy.physicalMemoryBytes + tolerance
        return memoryMatches &&
            hardwareIdentifier == policy.hardwareIdentifier &&
            Date().timeIntervalSince(timestamp) < 30 * 24 * 60 * 60
    }
}

struct ModelMobileReadinessReport: Codable, Equatable {
    let modelID: String
    let timestamp: Date
    let checks: [String: Bool]
    let notes: [String]
    let operatingSystem: String

    var passed: Bool {
        ModelReleaseGate.requiredChecks.allSatisfy { checks[$0] == true }
    }
}

@MainActor
final class ModelHealthStore {
    static let shared = ModelHealthStore()

    private let storageKey = "modelQuickTestResults"
    private let readinessStorageKey = "modelMobileReadinessReports"
    private let runtimeMemoryStorageKey = "modelRuntimeMemoryMeasurements"
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

    func removeResult(for modelID: String) {
        var current = loadResults()
        current.removeValue(forKey: modelID)
        if let data = try? encoder.encode(current) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func runtimeMemoryMeasurement(for modelID: String) -> ModelRuntimeMemoryMeasurement? {
        loadRuntimeMemoryMeasurements()[modelID]
    }

    func recordRuntimeMemoryPeak(modelID: String, peakResidentMemoryBytes: UInt64) {
        let policy = DeviceResourcePolicy.current
        var measurements = loadRuntimeMemoryMeasurements()
        let existingPeak: UInt64
        if let existing = measurements[modelID], existing.applies(to: policy) {
            existingPeak = existing.peakResidentMemoryBytes
        } else {
            existingPeak = 0
        }
        measurements[modelID] = ModelRuntimeMemoryMeasurement(
            modelID: modelID,
            peakResidentMemoryBytes: max(existingPeak, peakResidentMemoryBytes),
            physicalMemoryBytes: policy.physicalMemoryBytes,
            hardwareIdentifier: policy.hardwareIdentifier,
            timestamp: Date(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
        )
        if let data = try? encoder.encode(measurements) {
            UserDefaults.standard.set(data, forKey: runtimeMemoryStorageKey)
        }
    }

    private func loadRuntimeMemoryMeasurements() -> [String: ModelRuntimeMemoryMeasurement] {
        guard let data = UserDefaults.standard.data(forKey: runtimeMemoryStorageKey) else { return [:] }
        return (try? decoder.decode([String: ModelRuntimeMemoryMeasurement].self, from: data)) ?? [:]
    }

    func saveReadinessReport(_ report: ModelMobileReadinessReport) {
        var reports = loadReadinessReports()
        reports[report.modelID] = report
        if let data = try? encoder.encode(reports) {
            UserDefaults.standard.set(data, forKey: readinessStorageKey)
        }
    }

    func loadReadinessReports() -> [String: ModelMobileReadinessReport] {
        guard let data = UserDefaults.standard.data(forKey: readinessStorageKey) else { return [:] }
        return (try? decoder.decode([String: ModelMobileReadinessReport].self, from: data)) ?? [:]
    }
}

/// The shipping catalog is the release gate. Evaluation models cannot leak
/// into production selection until they are explicitly promoted.
enum ModelReleaseGate {
    static let requiredChecks = [
        "artifacts", "load", "firstResponse", "output", "multiTurn",
        "cancellation", "backgroundRecovery", "memory"
    ]

    static func isReleased(_ model: ModelInfo) -> Bool {
        ModelInfo.releasedModels.contains(where: { $0.id == model.id })
    }

    static func canPromote(_ report: ModelMobileReadinessReport) -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return report.passed
        #endif
    }
}
