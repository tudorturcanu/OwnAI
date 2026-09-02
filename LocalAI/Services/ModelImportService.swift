//
//  ModelImportService.swift
//  LocalAI
//

import Foundation

nonisolated enum ModelImportError: LocalizedError, Equatable {
    case nothingSelected
    case unreadableSource
    case archiveNotSupported
    case noModelFound
    case missingChatTemplate
    case missingArtifacts([String])
    case notEnoughSpace(requiredGB: Double, availableGB: Double)
    case exceedsDeviceMemory(sizeGB: Double, budgetGB: Double)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .nothingSelected:
            return String(localized: "No files were selected.")
        case .unreadableSource:
            return String(localized: "Own AI could not read the selected files. Try copying them into the Files app first, then import from there.")
        case .archiveNotSupported:
            return String(localized: "Compressed archives can't be imported directly. In the Files app, tap and hold the archive, choose Uncompress, then import the folder it creates.")
        case .noModelFound:
            return String(localized: "That folder doesn't contain a model. Pick the folder that holds config.json and the .safetensors weights.")
        case .missingChatTemplate:
            return String(localized: "This model has no chat template, so Own AI can't turn a conversation into a prompt for it — that usually means it's a base model. Import the Instruct or Chat version instead.")
        case .missingArtifacts(let missing):
            return String(
                format: String(localized: "The model is incomplete. Missing: %@.", defaultValue: "The model is incomplete. Missing: %@."),
                missing.joined(separator: ", ")
            )
        case .notEnoughSpace(let requiredGB, let availableGB):
            return String(
                format: String(localized: "Not enough free space (need %.1f GB, available %.1f GB).", defaultValue: "Not enough free space (need %.1f GB, available %.1f GB)."),
                requiredGB,
                availableGB
            )
        case .exceedsDeviceMemory(let sizeGB, let budgetGB):
            return String(
                format: String(localized: "This model is %.1f GB, more than this device can load (about %.1f GB). Importing it would use storage for a model that can't run.", defaultValue: "This model is %.1f GB, more than this device can load (about %.1f GB). Importing it would use storage for a model that can't run."),
                sizeGB,
                budgetGB
            )
        case .copyFailed(let message):
            return String(
                format: String(localized: "The model could not be copied: %@", defaultValue: "The model could not be copied: %@"),
                message
            )
        }
    }
}

/// Copies a user-supplied MLX checkpoint into Own AI's model storage.
///
/// Accepts either a folder (the usual shape of a Hugging Face snapshot) or a
/// multi-file selection of the loose artifacts. Archives are refused with an
/// instruction rather than unzipped: iOS has no public zip API, and the Files
/// app already uncompresses in one tap.
nonisolated enum ModelImportService {
    /// Copies the model and registers it. Returns the record on success.
    /// `onProgress` receives 0...1 and is called from a background thread.
    static func importModel(
        from urls: [URL],
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ImportedModelRecord {
        guard !urls.isEmpty else { throw ModelImportError.nothingSelected }

        return try await Task.detached(priority: .userInitiated) {
            try performImport(from: urls, onProgress: onProgress)
        }.value
    }

    // MARK: - Work

    private static func performImport(
        from urls: [URL],
        onProgress: @Sendable (Double) -> Void
    ) throws -> ImportedModelRecord {
        var scopedURLs: [URL] = []
        defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        for url in urls {
            if url.startAccessingSecurityScopedResource() {
                scopedURLs.append(url)
            }
        }

        let plan = try makeCopyPlan(from: urls)

        // Checked before a single byte is copied: a base model passes artifact
        // validation (config + tokenizer + weights are all there) and only fails
        // at the first message, by which point the user has spent minutes and
        // gigabytes on something that can never answer.
        guard hasChatTemplate(in: plan.files) else {
            throw ModelImportError.missingChatTemplate
        }

        let sizeGB = Double(plan.totalBytes) / 1_073_741_824.0
        let budgetGB = DeviceResourcePolicy.current.usableModelBudgetGB
        guard sizeGB <= budgetGB else {
            throw ModelImportError.exceedsDeviceMemory(sizeGB: sizeGB, budgetGB: budgetGB)
        }

        // Same headroom rule the downloader uses: the copy needs the weights
        // plus working room, not just the exact byte count.
        let requiredGB = max(sizeGB * 1.15, sizeGB + 0.35)
        let availableGB = DiskSpace.availableGB()
        guard availableGB + 0.001 >= requiredGB else {
            throw ModelImportError.notEnoughSpace(requiredGB: requiredGB, availableGB: availableGB)
        }

        let record = ImportedModelRecord(
            displayName: ImportedModelStore.shared.uniqueDisplayName(basedOn: plan.suggestedName),
            sizeBytes: plan.totalBytes,
            supportsVision: plan.supportsVision,
            supportsThinking: plan.supportsThinking
        )
        let destination = MLXStorage.modelDirectory(for: record.id)

        // Claim the folder for the duration of the copy so a concurrent orphan
        // sweep cannot delete an import that is still in flight.
        ImportedModelStore.shared.reserve(record.folderName)
        defer { ImportedModelStore.shared.release(record.folderName) }

        do {
            try copy(plan: plan, to: destination, onProgress: onProgress)
        } catch let error as ModelImportError {
            try? FileManager.default.removeItem(at: destination)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw ModelImportError.copyFailed(error.localizedDescription)
        }

        // Registered before validation on purpose: the vision-processor
        // requirement is keyed off `ModelInfo.isVisionModel`, so a VLM has to be
        // known as one for the check to actually run. Rolled back with the files
        // if it turns out to be incomplete.
        ImportedModelStore.shared.add(record)
        let validation = MLXStorage.validationReport(for: record.id)
        guard validation.isValid else {
            ImportedModelStore.shared.remove(record.id)
            try? FileManager.default.removeItem(at: destination)
            throw ModelImportError.missingArtifacts(validation.missingRequirements)
        }

        MLXStorage.normalizeConfigIfNeeded(in: destination)
        onProgress(1.0)
        return record
    }

    /// Deletes imported-model folders that no record points at.
    ///
    /// An import killed mid-copy (app terminated, device rebooted) leaves its
    /// bytes on disk but never registers them, so they show up in no list and
    /// no delete button can reach them — potentially gigabytes the user cannot
    /// reclaim without deleting the app.
    static func pruneOrphanedImports() {
        let base = MLXStorage.persistentBaseURL()
            .appendingPathComponent("imported", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let retained = ImportedModelStore.shared.retainedFolderNames
        for url in contents where !retained.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Planning

    private struct CopyPlan {
        /// Source file and its path relative to the destination root.
        let files: [(source: URL, relativePath: String)]
        let totalBytes: UInt64
        let suggestedName: String
        let supportsVision: Bool
        let supportsThinking: Bool
    }

    private static func makeCopyPlan(from urls: [URL]) throws -> CopyPlan {
        if urls.count == 1, isDirectory(urls[0]) {
            guard let root = resolveModelRoot(urls[0]) else { throw ModelImportError.noModelFound }
            return try plan(forDirectory: root, name: root.lastPathComponent)
        }

        if urls.contains(where: { isArchive($0) }) {
            throw ModelImportError.archiveNotSupported
        }

        // A loose multi-file selection: flatten it into one folder.
        var files: [(URL, String)] = []
        var totalBytes: UInt64 = 0
        for url in urls where MLXStorage.isModelArtifact(url.lastPathComponent) {
            guard let size = fileSize(url) else { continue }
            files.append((url, url.lastPathComponent))
            totalBytes += size
        }
        guard !files.isEmpty else { throw ModelImportError.noModelFound }

        let name = urls.first?.deletingLastPathComponent().lastPathComponent
        return CopyPlan(
            files: files.map { (source: $0.0, relativePath: $0.1) },
            totalBytes: totalBytes,
            suggestedName: displayName(from: name),
            supportsVision: files.contains { isProcessorConfig($0.1) }
                || urls.contains { $0.lastPathComponent.lowercased() == "config.json" && configDeclaresVision($0) },
            supportsThinking: declaresThinkingSupport(in: files)
        )
    }

    private static func plan(forDirectory root: URL, name: String) throws -> CopyPlan {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ModelImportError.unreadableSource
        }

        var files: [(URL, String)] = []
        var totalBytes: UInt64 = 0
        var hasProcessorConfig = false
        let rootPath = root.standardizedFileURL.path

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let filename = fileURL.lastPathComponent
            guard MLXStorage.isModelArtifact(filename) else { continue }

            let path = fileURL.standardizedFileURL.path
            let relative = path.hasPrefix(rootPath + "/")
                ? String(path.dropFirst(rootPath.count + 1))
                : filename
            files.append((fileURL, relative))
            totalBytes += UInt64(max(0, values?.fileSize ?? 0))
            if isProcessorConfig(filename) { hasProcessorConfig = true }
        }

        guard !files.isEmpty else { throw ModelImportError.noModelFound }

        let configURL = files.first { $0.1.lowercased() == "config.json" }?.0
        let supportsVision = hasProcessorConfig || (configURL.map(configDeclaresVision) ?? false)

        return CopyPlan(
            files: files.map { (source: $0.0, relativePath: $0.1) },
            totalBytes: totalBytes,
            suggestedName: displayName(from: name),
            supportsVision: supportsVision,
            supportsThinking: declaresThinkingSupport(in: files)
        )
    }

    /// Whether the checkpoint carries a chat template at all.
    ///
    /// Reads the same places swift-transformers does, plus `chat_template.json`
    /// — deliberately a superset, so this can accept a checkpoint that later
    /// turns out to fail, but never refuses one that would have worked.
    private static func hasChatTemplate(in files: [(source: URL, relativePath: String)]) -> Bool {
        for file in files {
            let name = file.relativePath.lowercased()
            if name == "chat_template.jinja" {
                if let text = try? String(contentsOf: file.source, encoding: .utf8),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
                continue
            }
            guard name == "tokenizer_config.json" || name == "chat_template.json" else { continue }
            guard let data = try? Data(contentsOf: file.source),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let template = json["chat_template"] as? String, !template.isEmpty { return true }
            // Newer checkpoints ship a list of named templates rather than one string.
            if let templates = json["chat_template"] as? [[String: Any]], !templates.isEmpty { return true }
        }
        return false
    }

    /// True when the checkpoint's chat template branches on `enable_thinking`.
    ///
    /// That flag is exactly what `LLMEngine.mlxTemplateContext` feeds the
    /// template, so its presence is the honest test for "this model has a
    /// reasoning mode the user can turn on" — far better than matching the model
    /// name, which for an import is a random UUID.
    private static func declaresThinkingSupport(in files: [(URL, String)]) -> Bool {
        let templateSources = ["tokenizer_config.json", "chat_template.jinja", "chat_template.json"]
        for file in files where templateSources.contains(file.1.lowercased()) {
            guard let text = try? String(contentsOf: file.0, encoding: .utf8) else { continue }
            if text.contains("enable_thinking") { return true }
        }
        return false
    }

    /// The folder that actually holds the checkpoint. Users often pick the
    /// wrapper folder a download or unzip produced, with the real snapshot one
    /// level down.
    private static func resolveModelRoot(_ directory: URL) -> URL? {
        if containsConfig(directory) { return directory }

        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let candidates = children.filter { isDirectory($0) && containsConfig($0) }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func containsConfig(_ directory: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.contains { name in
            let lower = name.lowercased()
            return lower == "config.json" || lower == "params.json"
        }
    }

    // MARK: - Copying

    private static func copy(
        plan: CopyPlan,
        to destination: URL,
        onProgress: @Sendable (Double) -> Void
    ) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        var copiedBytes: UInt64 = 0
        let total = max(plan.totalBytes, 1)

        for file in plan.files {
            let target = destination.appendingPathComponent(file.relativePath)
            let parent = target.deletingLastPathComponent()
            if parent.path != destination.path {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try fileManager.copyItem(at: file.source, to: target)
            copiedBytes += fileSize(file.source) ?? 0
            onProgress(min(0.99, Double(copiedBytes) / Double(total)))
        }

    }

    // MARK: - Helpers

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    private static func isArchive(_ url: URL) -> Bool {
        ["zip", "gz", "tar", "tgz", "7z", "rar", "bz2", "xz", "zst"].contains(url.pathExtension.lowercased())
    }

    private static func isProcessorConfig(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower == "processor_config.json"
            || lower == "preprocessor_config.json"
            || lower == "image_processor_config.json"
    }

    private static func fileSize(_ url: URL) -> UInt64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize else { return nil }
        return UInt64(max(0, size))
    }

    /// A vision checkpoint that ships no processor config still declares its
    /// image tower in config.json.
    private static func configDeclaresVision(_ configURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: configURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        // Deliberately conservative: a false positive routes a text model
        // through VLMModelFactory, which then fails to load it at all.
        if json["vision_config"] != nil || json["image_token_index"] != nil { return true }
        if let modelType = (json["model_type"] as? String)?.lowercased() {
            return modelType.hasSuffix("_vl") || modelType.hasSuffix("-vl") || modelType.contains("vision")
        }
        return false
    }

    private static func displayName(from folderName: String?) -> String {
        // Hugging Face cache folders are named `models--org--name`, so replacing
        // separators one-for-one leaves runs of spaces behind. Collapse them.
        let raw = (folderName ?? "")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return String(localized: "Imported Model") }
        return String(raw.prefix(60))
    }
}
