import SwiftUI

struct ModelStorageView: View {
    @Environment(ModelManager.self) private var modelManager
    @Environment(MonetizationManager.self) private var monetizationManager
    @State private var entries: [Entry] = []
    @State private var pendingDeletion: ModelInfo?
    /// Only imported models can be renamed — a catalog model's name is its
    /// identity in the catalog.
    @State private var renamingModel: ModelInfo?
    @State private var renameText = ""

    private struct Entry: Identifiable {
        let model: ModelInfo
        let bytes: UInt64
        let isPartial: Bool
        let lastUsed: Date?
        var id: String { model.id }
    }

    var body: some View {
        List {
            Section {
                LabeledContent(String(localized: "Model storage"), value: byteText(totalBytes))
                LabeledContent(
                    String(localized: "Device space available"),
                    value: String(format: String(localized: "%.1f GB", defaultValue: "%.1f GB"), DiskSpace.availableGB())
                )
            }

            Section {
                ModelImportControl { start, progress in
                    VStack(alignment: .leading, spacing: 10) {
                        Button(action: start) {
                            HStack(spacing: 8) {
                                Label(
                                    String(localized: "Import Model from Files"),
                                    systemImage: "square.and.arrow.down.on.square"
                                )

                                if !monetizationManager.canUse(.importedModels) {
                                    Spacer(minLength: 8)
                                    Image(systemName: "crown.fill")
                                        .foregroundStyle(.orange)
                                        .accessibilityLabel(String(localized: "Pro"))
                                }
                            }
                        }
                        .disabled(progress != nil)

                        if !monetizationManager.canUse(.importedModels) {
                            Text(ModelImportCopy.lockedHint)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let progress {
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressView(value: progress)
                                Text(String(
                                    format: String(localized: "Copying model… %d%%", defaultValue: "Copying model… %d%%"),
                                    Int(progress * 100)
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text(String(localized: "Your Models"))
            } footer: {
                Text(ModelImportCopy.requirements)
            }

            if let recommendation = reclaimRecommendation {
                Section(String(localized: "Suggestion")) {
                    Button {
                        pendingDeletion = recommendation.model
                    } label: {
                        Label {
                            Text(String(format: String(
                                localized: "%@ has not been used recently. Removing it would reclaim %@.",
                                defaultValue: "%@ has not been used recently. Removing it would reclaim %@."
                            ), recommendation.model.name, byteText(recommendation.bytes)))
                            .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "externaldrive.badge.minus")
                                .foregroundStyle(.orange)
                        }
                    }
                    .accessibilityHint(String(localized: "Asks before removing the model files."))
                }
            }

            Section(String(localized: "On This Device")) {
                if entries.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No Model Files"),
                        systemImage: "externaldrive",
                        description: Text(String(localized: "Downloaded and resumable model files appear here."))
                    )
                } else {
                    ForEach(entries) { entry in
                        HStack(spacing: 12) {
                            Image(systemName: entry.isPartial ? "arrow.down.circle.dotted" : "cube.fill")
                                .foregroundStyle(entry.isPartial ? .orange : .blue)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.model.name)
                                    .font(.body.weight(.medium))
                                Text(entrySubtitle(entry))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            // Imported models are named after the source folder,
                            // so renaming is a routine follow-up to importing —
                            // too routine to hide behind a swipe alone.
                            if entry.model.isImported {
                                Button {
                                    beginRename(entry.model)
                                } label: {
                                    Image(systemName: "pencil")
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                // .borderless, not .plain: a List row with more
                                // than one plain-styled button routes every tap
                                // to the row rather than to the button hit.
                                .buttonStyle(.borderless)
                                .accessibilityLabel(String(format: String(localized: "Rename %@", defaultValue: "Rename %@"), entry.model.name))
                            }
                            Button(role: .destructive) {
                                pendingDeletion = entry.model
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(String(format: String(localized: "Remove %@", defaultValue: "Remove %@"), entry.model.name))
                        }
                        .swipeActions(edge: .leading) {
                            if entry.model.isImported {
                                Button {
                                    beginRename(entry.model)
                                } label: {
                                    Label(String(localized: "Rename"), systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                        .contextMenu {
                            if entry.model.isImported {
                                Button {
                                    beginRename(entry.model)
                                } label: {
                                    Label(String(localized: "Rename"), systemImage: "pencil")
                                }
                            }
                        }
                    }
                }
            }

            Section {
                Text(String(localized: "Own AI never removes models automatically. Partial downloads are kept so a later download can resume."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "Model Storage"))
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .onChange(of: modelManager.models.count) { reload() }
        .onChange(of: modelManager.importProgress) { _, progress in
            if progress == nil { reload() }
        }
        .confirmationDialog(
            String(localized: "Remove Model Files?"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { model in
            Button(String(localized: "Remove"), role: .destructive) {
                modelManager.deleteModel(model.id)
                pendingDeletion = nil
                reload()
            }
            Button(String(localized: "Cancel"), role: .cancel) { pendingDeletion = nil }
        } message: { model in
            Text(String(
                format: String(localized: "%@ will be removed. %@", defaultValue: "%@ will be removed. %@"),
                model.name,
                ModelDeletionCopy.message(for: model)
            ))
        }
        .alert(
            String(localized: "Rename Model"),
            isPresented: Binding(
                get: { renamingModel != nil },
                set: { if !$0 { renamingModel = nil } }
            ),
            presenting: renamingModel
        ) { model in
            TextField(String(localized: "Name"), text: $renameText)
            Button(String(localized: "Save")) {
                modelManager.renameImportedModel(model.id, to: renameText)
                renamingModel = nil
                reload()
            }
            Button(String(localized: "Cancel"), role: .cancel) { renamingModel = nil }
        } message: { _ in
            Text(String(localized: "Only the name shown in Own AI changes. The model files stay exactly as they are."))
        }
    }

    private func beginRename(_ model: ModelInfo) {
        renameText = model.name
        renamingModel = model
    }

    private var totalBytes: UInt64 {
        entries.reduce(0) { $0 + $1.bytes }
    }

    private var reclaimRecommendation: Entry? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        return entries
            .filter { !$0.isPartial && $0.model.id != modelManager.selectedModel?.id }
            .filter { $0.lastUsed == nil || $0.lastUsed! < cutoff }
            .max { $0.bytes < $1.bytes }
    }

    private func reload() {
        entries = modelManager.models.compactMap { model in
            guard model.engine == .mlx else { return nil }
            let completeBytes = modelManager.storedBytes(for: model)
            let partialBytes = modelManager.partialDownloadBytes(for: model)
            let bytes = max(completeBytes, partialBytes)
            guard bytes > 0 else { return nil }
            return Entry(
                model: model,
                bytes: bytes,
                isPartial: !model.downloadState.isDownloaded,
                lastUsed: modelManager.lastUsedDate(for: model.id)
            )
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private func entrySubtitle(_ entry: Entry) -> String {
        if entry.model.isImported {
            let imported = String(format: String(localized: "%@ • imported", defaultValue: "%@ • imported"), byteText(entry.bytes))
            guard let lastUsed = entry.lastUsed else { return imported }
            return String(format: String(localized: "%@ • used %@", defaultValue: "%@ • used %@"), imported, lastUsed.formatted(.relative(presentation: .named)))
        }
        if entry.isPartial {
            return String(format: String(localized: "%@ • resumable download", defaultValue: "%@ • resumable download"), byteText(entry.bytes))
        }
        if let lastUsed = entry.lastUsed {
            return String(format: String(localized: "%@ • used %@", defaultValue: "%@ • used %@"), byteText(entry.bytes), lastUsed.formatted(.relative(presentation: .named)))
        }
        return String(format: String(localized: "%@ • not used yet", defaultValue: "%@ • not used yet"), byteText(entry.bytes))
    }

    private func byteText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
