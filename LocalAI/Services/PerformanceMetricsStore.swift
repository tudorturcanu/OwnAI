import Foundation

enum PerformanceSampleKind: String, Codable, Sendable {
    case interval
    case event
    case memory
}

struct PerformanceSample: Identifiable, Codable, Sendable {
    let id: UUID
    let sessionID: UUID
    let timestamp: Date
    let name: String
    let kind: PerformanceSampleKind
    let durationMilliseconds: Double?
    let residentMemoryBytes: UInt64?
    let status: String
    let metadata: String

    nonisolated init(
        id: UUID = UUID(),
        sessionID: UUID,
        timestamp: Date = Date(),
        name: String,
        kind: PerformanceSampleKind,
        durationMilliseconds: Double? = nil,
        residentMemoryBytes: UInt64? = nil,
        status: String = "success",
        metadata: String = ""
    ) {
        self.id = id
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.name = name
        self.kind = kind
        self.durationMilliseconds = durationMilliseconds
        self.residentMemoryBytes = residentMemoryBytes
        self.status = status
        self.metadata = metadata
    }
}

enum PerformanceRating: String, Codable, Sendable {
    case good
    case warning
    case slow
    case unscored
}

struct PerformanceMetricSummary: Identifiable, Codable, Sendable {
    var id: String { name }

    let name: String
    let sampleCount: Int
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let latestMilliseconds: Double
    let targetMilliseconds: Double?
    let rating: PerformanceRating
    /// Change in the median of the newest half versus the preceding half.
    /// Negative is faster; positive is slower.
    let recentTrendPercent: Double?
}

struct ModelPerformanceSummary: Identifiable, Codable, Sendable {
    var id: String { modelID }

    let modelID: String
    let generationCount: Int
    let medianFirstTokenMilliseconds: Double?
    let p95FirstTokenMilliseconds: Double?
    let medianGenerationMilliseconds: Double?
    let medianEffectiveTokensPerSecond: Double?
}

struct PerformanceHealthSummary: Codable, Sendable {
    let totalSamples: Int
    let failedOperations: Int
    let peakResidentMemoryBytes: UInt64?
}

struct PerformanceDashboardData: Sendable {
    let samples: [PerformanceSample]
    let summaries: [PerformanceMetricSummary]
    let modelSummaries: [ModelPerformanceSummary]
    let health: PerformanceHealthSummary
}

private struct PerformanceExportReport: nonisolated Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let operatingSystem: String
    let sampleCount: Int
    let summaries: [PerformanceMetricSummary]
    let modelSummaries: [ModelPerformanceSummary]
    let health: PerformanceHealthSummary
    let samples: [PerformanceSample]

    nonisolated init(
        schemaVersion: Int,
        generatedAt: Date,
        operatingSystem: String,
        sampleCount: Int,
        summaries: [PerformanceMetricSummary],
        modelSummaries: [ModelPerformanceSummary],
        health: PerformanceHealthSummary,
        samples: [PerformanceSample]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.operatingSystem = operatingSystem
        self.sampleCount = sampleCount
        self.summaries = summaries
        self.modelSummaries = modelSummaries
        self.health = health
        self.samples = samples
    }
}

/// Stores privacy-safe performance measurements locally without involving the
/// main actor. The file is intentionally bounded so instrumentation cannot
/// become its own storage or launch-time problem.
actor PerformanceMetricsStore {
    nonisolated static let shared = PerformanceMetricsStore()
    nonisolated static let collectionEnabledKey = "performanceMetrics.collectionEnabled"

    private static let schemaVersion = 1
    private static let maximumSampleCount = 1_000
    private static let retentionDays = 30
    private static let persistenceDebounceNanoseconds: UInt64 = 500_000_000

    private var samples: [PerformanceSample]?
    private var pendingPersistTask: Task<Void, Never>?
    /// Aggregating the whole sample set costs several full passes, and the
    /// send path asks for it more than once per message. The snapshot is held
    /// until a new sample invalidates it.
    private var cachedDashboard: PerformanceDashboardData?

    private var persistenceURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PerformanceMetrics", isDirectory: true)
        return base.appendingPathComponent("samples-v\(Self.schemaVersion).json")
    }

    func record(_ sample: PerformanceSample) {
        var current = loadIfNeeded()
        current.append(sample)
        samples = pruned(current)
        cachedDashboard = nil
        schedulePersistence()
    }

    func dashboardData() -> PerformanceDashboardData {
        if let cachedDashboard { return cachedDashboard }
        let current = pruned(loadIfNeeded())
        samples = current
        let data = PerformanceDashboardData(
            samples: current.sorted { $0.timestamp > $1.timestamp },
            summaries: Self.makeSummaries(from: current),
            modelSummaries: Self.makeModelSummaries(from: current),
            health: Self.makeHealthSummary(from: current)
        )
        cachedDashboard = data
        return data
    }

    func clear() {
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        samples = []
        cachedDashboard = nil
        try? FileManager.default.removeItem(at: persistenceURL)
    }

    func exportReport() throws -> URL {
        let current = pruned(loadIfNeeded())
        let report = PerformanceExportReport(
            schemaVersion: Self.schemaVersion,
            generatedAt: Date(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            sampleCount: current.count,
            summaries: Self.makeSummaries(from: current),
            modelSummaries: Self.makeModelSummaries(from: current),
            health: Self.makeHealthSummary(from: current),
            samples: current.sorted { $0.timestamp < $1.timestamp }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Own-AI-Performance-\(formatter.string(from: Date())).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func loadIfNeeded() -> [PerformanceSample] {
        if let samples { return samples }
        guard let data = try? Data(contentsOf: persistenceURL) else {
            samples = []
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = (try? decoder.decode([PerformanceSample].self, from: data)) ?? []
        let retained = pruned(decoded)
        samples = retained
        return retained
    }

    private func pruned(_ input: [PerformanceSample]) -> [PerformanceSample] {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -Self.retentionDays,
            to: Date()
        ) ?? .distantPast
        return Array(
            input
                .filter { $0.timestamp >= cutoff }
                .sorted { $0.timestamp < $1.timestamp }
                .suffix(Self.maximumSampleCount)
        )
    }

    private func schedulePersistence() {
        pendingPersistTask?.cancel()
        pendingPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.persistenceDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.persistNow()
        }
    }

    private func persistNow() {
        guard let samples else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(samples) else { return }
        let directory = persistenceURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try? data.write(to: persistenceURL, options: .atomic)
    }

    nonisolated private static func makeSummaries(
        from samples: [PerformanceSample]
    ) -> [PerformanceMetricSummary] {
        let targetOrder = [
            "App launch",
            "Model load",
            "First token",
            "Chat response",
            "Generation",
            "Document extraction",
            "Document indexing"
        ]
        let targets: [String: Double] = [
            "App launch": 1_000,
            "Model load": 3_000,
            "First token": 1_000,
            "Document extraction": 3_000,
            "Document indexing": 3_000
        ]

        let grouped = Dictionary(grouping: samples.filter {
            $0.durationMilliseconds != nil && $0.status == "success"
        }, by: \.name)

        return targetOrder.compactMap { name in
            guard let metricSamples = grouped[name], !metricSamples.isEmpty else { return nil }
            let chronological = metricSamples.sorted { $0.timestamp < $1.timestamp }
            let values = chronological.compactMap(\.durationMilliseconds)
            guard let latest = values.last else { return nil }
            let median = percentile(values, percentile: 0.5)
            let p95 = percentile(values, percentile: 0.95)
            let target = targets[name]
            let rating: PerformanceRating
            if let target {
                if p95 <= target {
                    rating = .good
                } else if p95 <= target * 1.5 {
                    rating = .warning
                } else {
                    rating = .slow
                }
            } else {
                rating = .unscored
            }

            return PerformanceMetricSummary(
                name: name,
                sampleCount: values.count,
                medianMilliseconds: median,
                p95Milliseconds: p95,
                latestMilliseconds: latest,
                targetMilliseconds: target,
                rating: rating,
                recentTrendPercent: trendPercent(values)
            )
        }
    }

    nonisolated private static func percentile(
        _ values: [Double],
        percentile: Double
    ) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let index = Int(ceil(Double(sorted.count) * percentile)) - 1
        return sorted[max(0, min(index, sorted.count - 1))]
    }

    nonisolated private static func makeModelSummaries(
        from samples: [PerformanceSample]
    ) -> [ModelPerformanceSummary] {
        let generations = samples.filter { $0.name == "Generation" && $0.status == "success" }
        let firstTokens = samples.filter { $0.name == "First token" && $0.status == "success" }
        let modelIDs = Set((generations + firstTokens).compactMap {
            metadataValue(named: "model", in: $0.metadata)
        })

        return modelIDs.map { modelID in
            let modelGenerations = generations.filter {
                metadataValue(named: "model", in: $0.metadata) == modelID
            }
            let modelFirstTokens = firstTokens.filter {
                metadataValue(named: "model", in: $0.metadata) == modelID
            }
            let generationDurations = modelGenerations.compactMap(\.durationMilliseconds)
            let firstTokenDurations = modelFirstTokens.compactMap(\.durationMilliseconds)
            let throughput = modelGenerations.compactMap {
                metadataValue(named: "effective_tps", in: $0.metadata).flatMap(Double.init)
            }

            return ModelPerformanceSummary(
                modelID: modelID,
                generationCount: modelGenerations.count,
                medianFirstTokenMilliseconds: firstTokenDurations.isEmpty
                    ? nil
                    : percentile(firstTokenDurations, percentile: 0.5),
                p95FirstTokenMilliseconds: firstTokenDurations.isEmpty
                    ? nil
                    : percentile(firstTokenDurations, percentile: 0.95),
                medianGenerationMilliseconds: generationDurations.isEmpty
                    ? nil
                    : percentile(generationDurations, percentile: 0.5),
                medianEffectiveTokensPerSecond: throughput.isEmpty
                    ? nil
                    : percentile(throughput, percentile: 0.5)
            )
        }
        .sorted { $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending }
    }

    nonisolated private static func makeHealthSummary(
        from samples: [PerformanceSample]
    ) -> PerformanceHealthSummary {
        PerformanceHealthSummary(
            totalSamples: samples.count,
            failedOperations: samples.filter { $0.status == "failed" }.count,
            peakResidentMemoryBytes: samples.compactMap(\.residentMemoryBytes).max()
        )
    }

    nonisolated private static func metadataValue(
        named key: String,
        in metadata: String
    ) -> String? {
        metadata
            .split(whereSeparator: { $0.isWhitespace })
            .first(where: { $0.hasPrefix("\(key)=") })
            .map { String($0.dropFirst(key.count + 1)) }
    }

    nonisolated private static func trendPercent(_ chronologicalValues: [Double]) -> Double? {
        guard chronologicalValues.count >= 4 else { return nil }
        let comparisonCount = min(10, chronologicalValues.count / 2)
        let recent = Array(chronologicalValues.suffix(comparisonCount))
        let previousEnd = chronologicalValues.count - comparisonCount
        let previousStart = max(0, previousEnd - comparisonCount)
        let previous = Array(chronologicalValues[previousStart..<previousEnd])
        let recentMedian = percentile(recent, percentile: 0.5)
        let previousMedian = percentile(previous, percentile: 0.5)
        guard previousMedian > 0 else { return nil }
        return ((recentMedian - previousMedian) / previousMedian) * 100
    }
}
