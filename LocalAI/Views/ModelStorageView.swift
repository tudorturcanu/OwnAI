import SwiftUI

struct ModelStorageView: View {
    @Environment(ModelManager.self) private var modelManager
    @State private var entries: [Entry] = []
    @State private var pendingDeletion: ModelInfo?

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

            if let recommendation = reclaimRecommendation {
                Section(String(localized: "Suggestion")) {
                    Label {
                        Text(String(format: String(
                            localized: "%@ has not been used recently. Removing it would reclaim %@.",
                            defaultValue: "%@ has not been used recently. Removing it would reclaim %@."
                        ), recommendation.model.name, byteText(recommendation.bytes)))
                    } icon: {
                        Image(systemName: "externaldrive.badge.minus")
                            .foregroundStyle(.orange)
                    }
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
                            Button(role: .destructive) {
                                pendingDeletion = entry.model
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(format: String(localized: "Remove %@", defaultValue: "Remove %@"), entry.model.name))
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
        .confirmationDialog(
            String(localized: "Remove Model Files?"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Remove"), role: .destructive) {
                if let model = pendingDeletion {
                    modelManager.deleteModel(model.id)
                    pendingDeletion = nil
                    reload()
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) { pendingDeletion = nil }
        }
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
