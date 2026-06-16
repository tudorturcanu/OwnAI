//
//  EmbeddingService.swift
//  LocalAI
//
//  On-device neural text embeddings for RAG, backed by a multilingual
//  sentence-transformer (intfloat/multilingual-e5-small) run via swift-embeddings
//  on Apple's MLTensor. Replaces NLEmbedding when enabled; RAGEngine falls back
//  to NLEmbedding whenever this service is unavailable.
//

import CoreML
import Embeddings
import Foundation

actor EmbeddingService {
    static let shared = EmbeddingService()

    /// e5-small is a BERT/MiniLM model: 384-dim, mean-pooled, multilingual.
    /// It expects task prefixes ("query: " / "passage: ") on every input.
    static let modelRepoID = "intfloat/multilingual-e5-small"
    /// Stable tag persisted alongside each vector so we never cosine-compare
    /// embeddings produced by different models.
    static let embedderIdentifier = "e5-small-v1"
    static let dimension = 384

    /// Caps how many chunks are encoded in a single MLTensor pass to keep peak
    /// memory bounded on phones.
    private static let maxBatchSize = 16

    enum EmbeddingKind {
        case document
        case query

        var prefix: String {
            switch self {
            case .document: return "passage: "
            case .query: return "query: "
            }
        }
    }

    private var bundle: Bert.ModelBundle?
    private var loadTask: Task<Bert.ModelBundle, Error>?

    private init() {}

    // MARK: - Storage

    /// swift-transformers' HubApi lays snapshots out under <downloadBase>/models/<repo>.
    private static var downloadBaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("embeddings", isDirectory: true)
    }

    static var snapshotURL: URL {
        downloadBaseURL.appendingPathComponent("models/\(modelRepoID)", isDirectory: true)
    }

    /// Whether the model has already been downloaded to local storage.
    nonisolated var isModelDownloaded: Bool {
        FileManager.default.fileExists(
            atPath: Self.snapshotURL.appendingPathComponent("config.json").path
        )
    }

    /// Removes the downloaded model from disk and unloads it from memory.
    func deleteModel() {
        unload()
        try? FileManager.default.removeItem(at: Self.snapshotURL)
    }

    // MARK: - Loading

    /// Ensures the model is loaded, optionally downloading it first.
    /// Returns false (rather than throwing) so callers can fall back gracefully.
    @discardableResult
    func ensureLoaded(downloadIfNeeded: Bool) async -> Bool {
        if bundle != nil { return true }
        if !downloadIfNeeded && !isModelDownloaded { return false }
        do {
            bundle = try await loadBundle()
            return true
        } catch {
            print("[EmbeddingService] load failed: \(error)")
            return false
        }
    }

    private func loadBundle() async throws -> Bert.ModelBundle {
        if let loadTask { return try await loadTask.value }

        let repo = Self.modelRepoID
        let base = Self.downloadBaseURL
        let task = Task {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            return try await Bert.loadModelBundle(from: repo, downloadBase: base)
        }
        loadTask = task
        defer { loadTask = nil }
        return try await task.value
    }

    func unload() {
        bundle = nil
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: - Embedding

    /// Embeds `texts` into L2-normalized vectors. Returns nil if the model is
    /// not available or encoding fails, so RAGEngine can fall back to NLEmbedding.
    func embed(_ texts: [String], kind: EmbeddingKind) async -> [[Float]]? {
        guard !texts.isEmpty else { return [] }
        guard await ensureLoaded(downloadIfNeeded: false), let bundle else { return nil }

        var options = bundle.defaultEncodeOptions
        options.postProcess = .meanPool(normalize: true)

        let prefixed = texts.map { kind.prefix + $0 }
        var result: [[Float]] = []
        result.reserveCapacity(texts.count)

        do {
            for start in stride(from: 0, to: prefixed.count, by: Self.maxBatchSize) {
                let slice = Array(prefixed[start..<min(start + Self.maxBatchSize, prefixed.count)])
                let encoded = try bundle.batchEncode(slice, options: options)
                let scalars = await encoded.cast(to: Float.self).shapedArray(of: Float.self).scalars

                guard scalars.count == slice.count * Self.dimension else {
                    print("[EmbeddingService] unexpected output shape: \(scalars.count) for \(slice.count) inputs")
                    return nil
                }
                for row in 0..<slice.count {
                    let lower = row * Self.dimension
                    result.append(Array(scalars[lower..<(lower + Self.dimension)]))
                }
            }
        } catch {
            print("[EmbeddingService] encode failed: \(error)")
            return nil
        }

        return result
    }
}
