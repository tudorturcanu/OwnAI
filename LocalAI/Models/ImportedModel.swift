//
//  ImportedModel.swift
//  LocalAI
//

import Foundation

/// A model the user brought in themselves from Files rather than one of the
/// curated checkpoints Own AI downloads.
///
/// The weights land in exactly the same place as a downloaded model
/// (`MLXStorage.modelDirectory(for:)`), so validation, loading, storage
/// accounting and deletion all work unchanged. Only the catalog entry is
/// synthesized at runtime instead of being hard-coded in `ModelInfo`.
nonisolated struct ImportedModelRecord: Codable, Equatable, Identifiable {
    /// Namespaced so the on-disk folder nests under `models/imported/`, and so
    /// no imported model can ever collide with a Hugging Face repo ID.
    static let idPrefix = "imported/"

    let id: String
    var displayName: String
    var sizeBytes: UInt64
    var supportsVision: Bool
    /// The checkpoint's chat template takes an `enable_thinking` flag, so the
    /// user should get the reasoning toggle for it.
    var supportsThinking: Bool
    var importedAt: Date

    init(
        id: String = ImportedModelRecord.idPrefix + UUID().uuidString,
        displayName: String,
        sizeBytes: UInt64,
        supportsVision: Bool,
        supportsThinking: Bool = false,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.supportsVision = supportsVision
        self.supportsThinking = supportsThinking
        self.importedAt = importedAt
    }

    // Written by hand rather than synthesized: the synthesized decoder throws on
    // a missing key even when the property has a default, so adding a field
    // would fail to decode every record saved by an earlier build — and since
    // `load()` swallows the error, every imported model would silently vanish
    // from the user's list. New fields must decode as optional.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        sizeBytes = try container.decode(UInt64.self, forKey: .sizeBytes)
        supportsVision = try container.decode(Bool.self, forKey: .supportsVision)
        supportsThinking = try container.decodeIfPresent(Bool.self, forKey: .supportsThinking) ?? false
        importedAt = try container.decode(Date.self, forKey: .importedAt)
    }

    var sizeGB: Double {
        Double(sizeBytes) / 1_073_741_824.0
    }

    /// The directory name under `models/imported/`.
    var folderName: String {
        String(id.dropFirst(ImportedModelRecord.idPrefix.count))
    }
}

/// Persistent registry of imported models.
///
/// Deliberately lock-guarded rather than `@MainActor`: artifact validation and
/// the MLX load path both need to know whether a model is a VLM, and both run
/// off the main actor.
nonisolated final class ImportedModelStore: @unchecked Sendable {
    static let shared = ImportedModelStore()

    private static let defaultsKey = "models.imported"

    private let lock = NSLock()
    private var records: [ImportedModelRecord]
    /// Folders belonging to an import that is still copying. They have no record
    /// yet, so without this the orphan sweep would delete a live import.
    private var reservedFolderNames: Set<String> = []

    private init() {
        records = Self.load()
    }

    private static func load() -> [ImportedModelRecord] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([ImportedModelRecord].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Called with the lock held.
    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    var all: [ImportedModelRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records.sorted { $0.importedAt < $1.importedAt }
    }

    func isVisionModel(_ modelID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return records.contains { $0.id == modelID && $0.supportsVision }
    }

    func supportsThinking(_ modelID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return records.contains { $0.id == modelID && $0.supportsThinking }
    }

    func contains(_ modelID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return records.contains { $0.id == modelID }
    }

    func record(for modelID: String) -> ImportedModelRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records.first { $0.id == modelID }
    }

    func reserve(_ folderName: String) {
        lock.lock()
        defer { lock.unlock() }
        reservedFolderNames.insert(folderName)
    }

    func release(_ folderName: String) {
        lock.lock()
        defer { lock.unlock() }
        reservedFolderNames.remove(folderName)
    }

    /// Folders that must survive an orphan sweep: everything registered, plus
    /// anything currently being copied.
    var retainedFolderNames: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(records.map(\.folderName)).union(reservedFolderNames)
    }

    func add(_ record: ImportedModelRecord) {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll { $0.id == record.id }
        records.append(record)
        persistLocked()
    }

    func rename(_ modelID: String, to displayName: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.id == modelID }) else { return }
        records[index].displayName = displayName
        persistLocked()
    }

    func remove(_ modelID: String) {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll { $0.id == modelID }
        persistLocked()
    }

    /// A display name that does not collide with an existing import. Two
    /// folders named "model" are otherwise indistinguishable in the picker.
    func uniqueDisplayName(basedOn candidate: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let existing = Set(records.map(\.displayName))
        guard existing.contains(candidate) else { return candidate }
        var suffix = 2
        while existing.contains("\(candidate) \(suffix)") {
            suffix += 1
        }
        return "\(candidate) \(suffix)"
    }
}
