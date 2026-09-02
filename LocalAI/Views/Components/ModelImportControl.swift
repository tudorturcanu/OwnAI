//
//  ModelImportControl.swift
//  LocalAI
//

import SwiftUI
import UniformTypeIdentifiers

/// Owns everything a "bring your own model" affordance needs — the Pro gate,
/// the document picker, the copy progress and the failure alert — and hands its
/// caller only a `start` action plus the current progress, so the model catalog
/// and the storage screen can present it in their own idioms without repeating
/// any of it.
struct ModelImportControl<Content: View>: View {
    var selectWhenFinished: Bool = true
    @ViewBuilder var content: (_ start: @escaping () -> Void, _ progress: Double?) -> Content

    @Environment(ModelManager.self) private var modelManager
    @Environment(MonetizationManager.self) private var monetizationManager

    @State private var isPickerPresented = false
    @State private var upgradeFeature: PremiumFeature?
    @State private var errorMessage: String?

    var body: some View {
        content(start, modelManager.importProgress)
            .fileImporter(
                isPresented: $isPickerPresented,
                // `.folder` is the normal case (a Hugging Face snapshot);
                // `.data` lets someone pick the loose files instead, since
                // .safetensors has no registered content type of its own.
                allowedContentTypes: [.folder, .data],
                allowsMultipleSelection: true
            ) { result in
                handle(result)
            }
            .alert(
                String(localized: "Import Failed"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button(String(localized: "OK"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(item: $upgradeFeature) { feature in
                UpgradeView(feature: feature) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        start()
                    }
                }
                .environment(monetizationManager)
            }
    }

    private func start() {
        guard modelManager.importProgress == nil else { return }
        guard monetizationManager.canUse(.importedModels) else {
            upgradeFeature = .importedModels
            return
        }
        // Copying gigabytes onto a device that can never load an MLX model is
        // pure waste, so this is refused before the picker opens rather than
        // after the files land.
        guard DeviceResourcePolicy.supportsMLXCompute else {
            errorMessage = String(localized: "This device's chip can't run downloadable models. They need an A14 chip or newer — iPhone 12, iPhone SE (3rd generation), or later.")
            return
        }
        isPickerPresented = true
    }

    private func handle(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            Task {
                if await modelManager.importModel(from: urls, selectWhenFinished: selectWhenFinished) == nil {
                    errorMessage = modelManager.lastImportErrorMessage
                    modelManager.clearImportError()
                }
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}

/// Shared explanation of what a valid import looks like. Users reach this
/// feature from two screens and should not get two different stories.
enum ModelImportCopy {
    static let requirements = String(localized: "Pick a folder containing an MLX model — config.json, a tokenizer, and the .safetensors weights. Compressed archives need to be uncompressed in the Files app first.")

    static let lockedHint = String(localized: "Importing your own models is part of Own AI Pro.")
}
