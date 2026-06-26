//
//  ModelDownloadView.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import SwiftUI
import UIKit

struct ModelDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ModelManager.self) private var modelManager
    @Environment(LLMEngine.self) private var llmEngine
    @Environment(MonetizationManager.self) private var monetizationManager

    private var appleModels: [ModelInfo] {
        modelManager.models.filter { modelManager.shouldShowModelInCatalog($0) && $0.engine == .appleFoundation }
    }

    private var downloadedModels: [ModelInfo] {
        modelManager.models
            .filter { $0.engine == .mlx && $0.downloadState.isDownloaded }
            .sorted { lhs, rhs in
                if lhs.name != rhs.name {
                    return lhs.name < rhs.name
                }
                return lhs.sizeGB < rhs.sizeGB
            }
    }

    private var familyGroups: [ModelFamilyGroup] {
        let familyOrder = ModelFamily.allCases.filter { $0 != .appleIntelligence }
        return familyOrder.compactMap { family in
            let models = modelManager.models
                .filter { modelManager.shouldShowModelInCatalog($0) && $0.family == family && $0.engine == .mlx }
                .sorted { $0.sizeGB < $1.sizeGB }
            guard !models.isEmpty else { return nil }
            return ModelFamilyGroup(family: family, models: models)
        }
    }

    private var useCaseRecommendations: [ModelManager.UseCaseRecommendation] {
        modelManager.useCaseRecommendations()
    }

    private var shouldShowHeaderTips: Bool {
        NotificationManager.shared.launchCount <= 2
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if shouldShowHeaderTips {
                    headerView
                }

                DownloadedModelsSection(models: downloadedModels)

                ForEach(appleModels) { model in
                    ModelCard(model: model)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        ))
                }

                if !useCaseRecommendations.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(localized: "Choose by Use"))
                            .font(.headline)
                            .foregroundStyle(Color(white: 0.2))

                        LazyVGrid(
                            columns: [
                                GridItem(.adaptive(minimum: 156), spacing: 12)
                            ],
                            spacing: 12
                        ) {
                            ForEach(useCaseRecommendations) { recommendation in
                                ModelUseCaseCard(recommendation: recommendation)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "Advanced Model Families"))
                        .font(.headline)
                        .foregroundStyle(Color(white: 0.2))

                    ForEach(familyGroups) { group in
                        NavigationLink {
                            ModelFamilyDetailView(family: group.family, models: group.models)
                        } label: {
                            FamilyCard(group: group)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .background(Color(white: 0.96))
        .navigationTitle(String(localized: "Manage Models"))
        .navigationBarTitleDisplayMode(.large)
    }
    
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let recommendation = modelManager.onboardingRecommendation(),
               let model = modelManager.models.first(where: { $0.id == recommendation.modelID }) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "iphone.gen3")
                        .foregroundStyle(.green.opacity(0.9))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: String(localized: "Recommended Now: %@", defaultValue: "Recommended Now: %@"), model.name))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(white: 0.18))
                        Text(recommendation.summary)
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.45))
                    }
                }
                .padding(12)
                .background(Color.green.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.green.opacity(0.16), lineWidth: 1)
                )
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue.opacity(0.8))

                Text(modelManager.isAppleIntelligenceDeviceSupported ?
                     String(localized: "Choose a model family first. Apple Intelligence is built-in, while other families open into downloadable variants.") :
                     String(localized: "Choose a model family first, then pick a variant to download and run on your device."))
                    .font(.subheadline)
                    .foregroundStyle(Color(white: 0.4))
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .foregroundStyle(.orange.opacity(0.85))

                Text(String(localized: "Using Apple Watch too? Smaller models usually reply faster because requests still run on your iPhone."))
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.45))
            }
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.03), radius: 6, y: 3)
    }
}

struct DownloadedModelsSection: View {
    let models: [ModelInfo]

    private var storageText: String {
        let totalGB = models.reduce(0.0) { $0 + $1.sizeGB }
        guard totalGB > 0 else {
            return String(localized: "No local downloads")
        }
        return String(format: String(localized: "%.1f GB on device", defaultValue: "%.1f GB on device"), totalGB)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "Downloaded Models"))
                    .font(.headline)
                    .foregroundStyle(Color(white: 0.2))

                Spacer()

                Text(storageText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color(white: 0.5))
            }

            if models.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "externaldrive.badge.plus")
                        .font(.headline)
                        .foregroundStyle(.blue)
                        .frame(width: 34, height: 34)
                        .background(Color.blue.opacity(0.09))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "No models downloaded yet"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(white: 0.18))

                        Text(String(localized: "Download a model below and it will appear here for quick selection or removal."))
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.03), radius: 6, y: 3)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                        DownloadedModelRow(model: model)

                        if index < models.count - 1 {
                            Divider()
                                .padding(.leading, 72)
                        }
                    }
                }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.03), radius: 6, y: 3)
            }
        }
    }
}

struct DownloadedModelRow: View {
    let model: ModelInfo

    @Environment(ModelManager.self) private var modelManager
    @Environment(MonetizationManager.self) private var monetizationManager
    @State private var showConsentSheet = false
    @State private var showDeleteConfirmation = false
    @State private var pendingAction: (() -> Void)?
    @State private var upgradeFeature: PremiumFeature?

    private var isSelected: Bool {
        modelManager.selectedModel?.id == model.id
    }

    private var isLockedPremiumModel: Bool {
        monetizationManager.isPremiumModel(model) && !monetizationManager.hasPro
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "externaldrive.fill")
                .font(.headline)
                .foregroundStyle(isSelected ? .green : .blue)
                .frame(width: 38, height: 38)
                .background((isSelected ? Color.green : Color.blue).opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(white: 0.14))
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    Text("\(model.family.title) • \(model.sizeLabel)")
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.45))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if isSelected {
                        Text(String(localized: "ACTIVE"))
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue)
                            .clipShape(Capsule())
                            .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Button {
                if isLockedPremiumModel {
                    upgradeFeature = .allModels
                } else {
                    requireConsentAndPerform {
                        modelManager.selectModel(model.id)
                    }
                }
            } label: {
                Image(systemName: isLockedPremiumModel ? "crown.fill" : (isSelected ? "checkmark" : "circle"))
                    .font(.body.weight(.bold))
                .foregroundStyle(isSelected ? .white : .blue)
                .frame(width: 40, height: 40)
                .background(isSelected ? Color.blue : Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(ActionButtonStyle())
            .disabled(isSelected && !isLockedPremiumModel)
            .accessibilityLabel(isLockedPremiumModel ? String(localized: "Unlock model") : (isSelected ? String(localized: "Selected model") : String(localized: "Select model")))

            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 40, height: 40)
                    .background(Color.red.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(ActionButtonStyle())
            .accessibilityLabel(String(localized: "Delete model"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .confirmationDialog(String(localized: "Delete Model?"), isPresented: $showDeleteConfirmation) {
            Button(String(localized: "Delete"), role: .destructive) {
                modelManager.deleteModel(model.id)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This will remove the downloaded model from your device. You can download it again anytime."))
        }
        .sheet(isPresented: $showConsentSheet) {
            ModelConsentSheet(model: model) {
                UserDefaults.standard.set(true, forKey: consentKey)
                showConsentSheet = false
                let action = pendingAction
                pendingAction = nil
                action?()
            } onCancel: {
                showConsentSheet = false
                pendingAction = nil
            }
        }
        .sheet(item: $upgradeFeature) { feature in
            UpgradeView(feature: feature)
                .environment(monetizationManager)
        }
    }

    private var consentKey: String {
        "modelConsent.\(model.id)"
    }

    private func requireConsentAndPerform(_ action: @escaping () -> Void) {
        if UserDefaults.standard.bool(forKey: consentKey) {
            action()
            return
        }

        pendingAction = action
        showConsentSheet = true
    }
}

struct ModelUseCaseCard: View {
    let recommendation: ModelManager.UseCaseRecommendation

    @Environment(ModelManager.self) private var modelManager
    @Environment(MonetizationManager.self) private var monetizationManager
    @Environment(\.openURL) private var openURL
    @State private var showConsentSheet = false
    @State private var pendingAction: (() -> Void)?
    @State private var upgradeFeature: PremiumFeature?

    private var model: ModelInfo? {
        modelManager.models.first { $0.id == recommendation.modelID }
    }

    private var isSelected: Bool {
        modelManager.selectedModel?.id == recommendation.modelID
    }

    private var isPremiumModel: Bool {
        guard let model else { return false }
        return monetizationManager.isPremiumModel(model)
    }

    private var actionTitle: String {
        guard let model else { return String(localized: "Unavailable") }
        if isPremiumModel && !monetizationManager.hasPro {
            return String(localized: "Unlock Pro")
        }
        if isSelected {
            return String(localized: "Selected")
        }
        switch model.downloadState {
        case .builtin, .downloaded:
            return String(localized: "Use")
        case .notDownloaded:
            return String(format: String(localized: "Download %@", defaultValue: "Download %@"), model.sizeLabel)
        case .downloading, .validating:
            return String(localized: "Cancel")
        case .error:
            return modelManager.downloadErrorAction(for: model.id).title
        }
    }

    private var actionIcon: String {
        guard let model else { return "exclamationmark.circle" }
        if isPremiumModel && !monetizationManager.hasPro {
            return "crown.fill"
        }
        if isSelected {
            return "checkmark.circle.fill"
        }
        switch model.downloadState {
        case .builtin, .downloaded:
            return "checkmark.circle"
        case .notDownloaded:
            return "arrow.down.circle.fill"
        case .downloading, .validating:
            return "xmark"
        case .error:
            return modelManager.downloadErrorAction(for: model.id).iconName
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: recommendation.symbolName)
                    .font(.headline)
                    .foregroundStyle(.blue)
                    .frame(width: 34, height: 34)
                    .background(Color.blue.opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(recommendation.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color(white: 0.12))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Text(recommendation.summary)
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.45))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(recommendation.detail)
                .font(.caption2)
                .foregroundStyle(Color(white: 0.48))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let model {
                VStack(alignment: .leading, spacing: 8) {
                    InfoTag(icon: model.isAppleFoundation ? "apple.logo" : "cpu", text: LocalizedStringKey(model.name), isHighlighted: isSelected)

                    if model.isAppleFoundation {
                        InfoTag(icon: "bolt.shield", text: LocalizedStringKey(String(localized: "No download")))
                    } else {
                        InfoTag(icon: "externaldrive", text: LocalizedStringKey(model.sizeLabel))
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                performPrimaryAction()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: actionIcon)
                        .font(.caption.weight(.bold))
                    Text(actionTitle)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                .foregroundStyle(isSelected ? .white : .blue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isSelected ? Color.blue : Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(ActionButtonStyle())
            .disabled(model == nil)
        }
        .frame(maxWidth: .infinity, minHeight: 218, alignment: .topLeading)
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? Color.blue.opacity(0.25) : Color.clear, lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.035), radius: 7, y: 3)
        .sheet(isPresented: $showConsentSheet) {
            if let model {
                ModelConsentSheet(model: model) {
                    UserDefaults.standard.set(true, forKey: consentKey(for: model))
                    showConsentSheet = false
                    let action = pendingAction
                    pendingAction = nil
                    action?()
                } onCancel: {
                    showConsentSheet = false
                    pendingAction = nil
                }
            }
        }
        .sheet(item: $upgradeFeature) { feature in
            UpgradeView(feature: feature)
                .environment(monetizationManager)
        }
    }

    private func performPrimaryAction() {
        guard let model else { return }

        if isPremiumModel && !monetizationManager.hasPro {
            upgradeFeature = .allModels
            return
        }

        switch model.downloadState {
        case .builtin, .downloaded:
            requireConsent(for: model) {
                modelManager.selectModel(model.id)
            }
        case .notDownloaded:
            requireConsent(for: model) {
                modelManager.downloadModel(model.id, selectWhenFinished: true)
            }
        case .downloading, .validating:
            modelManager.cancelDownload(model.id)
        case .error:
            handleDownloadErrorAction(modelManager.downloadErrorAction(for: model.id), model: model)
        }
    }

    private func requireConsent(for model: ModelInfo, action: @escaping () -> Void) {
        if UserDefaults.standard.bool(forKey: consentKey(for: model)) {
            action()
            return
        }
        pendingAction = action
        showConsentSheet = true
    }

    private func consentKey(for model: ModelInfo) -> String {
        "modelConsent.\(model.id)"
    }

    private func handleDownloadErrorAction(_ action: DownloadErrorAction, model: ModelInfo) {
        switch action {
        case .retry:
            modelManager.downloadModel(model.id, selectWhenFinished: true)
        case .freeSpace:
            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                openURL(settingsURL)
            }
        case .repair:
            modelManager.repairModel(model.id, selectWhenFinished: true)
        case .cellularRestricted:
            break
        }
    }
}

struct ModelFamilyGroup: Identifiable {
    let family: ModelFamily
    let models: [ModelInfo]

    var id: String { family.id }

    var downloadedCount: Int {
        models.filter { $0.downloadState.isDownloaded }.count
    }

    var sizeRangeText: String {
        guard let smallest = models.min(by: { $0.sizeGB < $1.sizeGB }),
              let largest = models.max(by: { $0.sizeGB < $1.sizeGB }) else {
            return ""
        }
        if abs(smallest.sizeGB - largest.sizeGB) < 0.05 {
            return String(format: String(localized: "%.1f GB", defaultValue: "%.1f GB"), smallest.sizeGB)
        }
        return String(format: String(localized: "%.1f-%.1f GB", defaultValue: "%.1f-%.1f GB"), smallest.sizeGB, largest.sizeGB)
    }
}

struct ModelFamilyDetailView: View {
    let family: ModelFamily
    let models: [ModelInfo]
    @Environment(ModelManager.self) private var modelManager

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: family.symbolName)
                            .foregroundStyle(.blue)
                        Text(LocalizedStringKey(family.title))
                            .font(.title3.bold())
                            .foregroundStyle(Color(white: 0.1))
                    }

                    Text(LocalizedStringKey(family.subtitle))
                        .font(.subheadline)
                        .foregroundStyle(Color(white: 0.45))

                    Text(LocalizedStringKey(familyGuidance))
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.5))

                    if let recommendedModel = models.first(where: modelManager.isOnboardingRecommended) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.green)
                            Text(String(format: String(localized: "%@ is the best match here for this device.", defaultValue: "%@ is the best match here for this device."), recommendedModel.name))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color(white: 0.34))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.03), radius: 6, y: 3)

                ForEach(models) { model in
                    ModelCard(model: model)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .background(Color(white: 0.96))
        .navigationTitle(LocalizedStringKey(family.title))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var familyGuidance: String {
        if let recommendedModel = models.first(where: { $0.badges.contains(.recommended) }) {
            return String(format: String(localized: "Start with %@ if you want the easiest pick.", defaultValue: "Start with %@ if you want the easiest pick."), recommendedModel.name)
        }
        if let codingModel = models.first(where: { $0.badges.contains(.bestForCoding) }) {
            return String(format: String(localized: "%@ is the strongest option here for technical tasks.", defaultValue: "%@ is the strongest option here for technical tasks."), codingModel.name)
        }
        return String(format: String(localized: "Choose a specific %@ variant to download or use.", defaultValue: "Choose a specific %@ variant to download or use."), family.title)
    }
}

struct FamilyCard: View {
    let group: ModelFamilyGroup
    @Environment(ModelManager.self) private var modelManager

    private var selectedModel: ModelInfo? {
        guard let selected = modelManager.selectedModel else { return nil }
        return group.models.first(where: { $0.id == selected.id })
    }

    private var modelCountText: String {
        group.models.count == 1
            ? String(localized: "1 model")
            : String(format: String(localized: "%lld models", defaultValue: "%lld models"), Int64(group.models.count))
    }

    private var readyText: String {
        String(format: String(localized: "%lld ready", defaultValue: "%lld ready"), Int64(group.downloadedCount))
    }

    private var recommendedModel: ModelInfo? {
        group.models.first(where: modelManager.isOnboardingRecommended)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                colors: [.blue.opacity(0.12), .cyan.opacity(0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 58, height: 58)

                    Image(systemName: group.family.symbolName)
                        .font(.title3)
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(LocalizedStringKey(group.family.title))
                            .font(.title3.bold())
                            .foregroundStyle(Color(white: 0.1))

                        if selectedModel != nil {
                             Text(String(localized: "ACTIVE"))
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue)
                                .clipShape(Capsule())
                        }
                    }

                    Text(LocalizedStringKey(group.family.subtitle))
                        .font(.subheadline)
                        .foregroundStyle(Color(white: 0.5))
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(white: 0.6))
                    .padding(.top, 4)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    InfoTag(icon: "square.stack.3d.up", text: LocalizedStringKey(modelCountText))
                    InfoTag(icon: "externaldrive", text: LocalizedStringKey(group.sizeRangeText))
                    if group.downloadedCount > 0 {
                        InfoTag(icon: "checkmark.circle.fill", text: LocalizedStringKey(readyText), isHighlighted: true)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        InfoTag(icon: "square.stack.3d.up", text: LocalizedStringKey(modelCountText))
                        InfoTag(icon: "externaldrive", text: LocalizedStringKey(group.sizeRangeText))
                    }

                    if group.downloadedCount > 0 {
                        InfoTag(icon: "checkmark.circle.fill", text: LocalizedStringKey(readyText), isHighlighted: true)
                    }
                }
            }

            if let recommendedModel {
                InfoTag(icon: "sparkles", text: LocalizedStringKey(String(format: String(localized: "Recommended: %@", defaultValue: "Recommended: %@"), recommendedModel.name)), isHighlighted: true)
            }

            if let selectedModel {
                Text(String(format: String(localized: "Selected: %@", defaultValue: "Selected: %@"), selectedModel.name))
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.45))
            } else {
                Text(String(format: String(localized: "Tap to view all %@ models.", defaultValue: "Tap to view all %@ models."), group.family.title))
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.45))
            }
        }
        .padding(20)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
    }
}

// MARK: - Model Card

struct ModelCard: View {
    let model: ModelInfo
    @Environment(ModelManager.self) private var modelManager
    @Environment(LLMEngine.self) private var llmEngine
    @Environment(MonetizationManager.self) private var monetizationManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isHovered = false
    @State private var testResult: ModelQuickTestResult?
    @State private var isThinkingEnabled = false
    @State private var showConsentSheet = false
    @State private var pendingAction: (() -> Void)?
    @State private var upgradeFeature: PremiumFeature?
    
    private var isSelected: Bool {
        modelManager.selectedModel?.id == model.id
    }
    
    /// Whether this Apple model is unsupported on the current device
    private var isAppleUnavailable: Bool {
        model.isAppleFoundation && !modelManager.isAppleIntelligenceAvailable
    }

    private var isPremiumModel: Bool {
        monetizationManager.isPremiumModel(model)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: isAppleUnavailable ? 12 : 16) {
            // Header row
            HStack(alignment: .top, spacing: 14) {
                // Icon
                modelIcon
                
                // Title and description
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.name)
                            .font(.title3.bold())
                            .foregroundStyle(isAppleUnavailable ? Color(white: 0.4) : Color(white: 0.1))
                        
                        if model.isAppleFoundation && !isAppleUnavailable {
                            Text(String(localized: "DEFAULT"))
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    LinearGradient(
                                        colors: [.orange, .pink],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .clipShape(Capsule())
                        }
                    }
                    
                    if isAppleUnavailable {
                        Text(modelManager.appleIntelligenceUnavailableHint)
                            .font(.subheadline)
                            .foregroundStyle(Color(white: 0.5))
                            .lineLimit(3)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(LocalizedStringKey(model.shortDescription))
                                .font(.subheadline)
                                .foregroundStyle(Color(white: 0.5))
                                .lineLimit(4)
                                .fixedSize(horizontal: false, vertical: true)

                            if isPremiumModel && !monetizationManager.hasPro {
                                InfoTag(icon: "crown.fill", text: LocalizedStringKey(String(localized: "Pro")), isHighlighted: true)
                            }
                        }
                    }
                }
                
                Spacer(minLength: 0)
            }
            
            if !isAppleUnavailable {
                modelInfoTags

                healthSection

                // Action button
                actionButton
            }
        }
        .padding(isAppleUnavailable ? 16 : 20)
        .background(
            model.isAppleFoundation ?
            AnyShapeStyle(
                LinearGradient(
                    colors: isAppleUnavailable ? 
                        [Color(white: 0.97), Color(white: 0.96)] :
                        [Color.white, Color(white: 0.99)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            ) :
            AnyShapeStyle(Color.white)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    model.isAppleFoundation ?
                    LinearGradient(
                        colors: [.orange.opacity(0.3), .pink.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ) :
                    LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom),
                    lineWidth: model.isAppleFoundation ? 1.5 : 0
                )
        )
        .shadow(color: .black.opacity(isHovered ? 0.08 : 0.04), radius: isHovered ? 12 : 8, y: isHovered ? 6 : 4)
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            syncThinkingPreference()
            if testResult == nil {
                testResult = modelManager.quickTestResult(for: model.id)
            }
        }
        .onChange(of: modelManager.selectedModelID) { _, _ in
            syncThinkingPreference()
        }
        .sheet(isPresented: $showConsentSheet) {
            ModelConsentSheet(model: model) {
                UserDefaults.standard.set(true, forKey: consentKey)
                showConsentSheet = false
                let action = pendingAction
                pendingAction = nil
                action?()
            } onCancel: {
                showConsentSheet = false
                pendingAction = nil
            }
        }
        .sheet(item: $upgradeFeature) { feature in
            UpgradeView(feature: feature)
                .environment(monetizationManager)
        }
    }
    
    // MARK: - Components
    
    private var modelIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    model.isAppleFoundation ?
                    LinearGradient(
                        colors: [.orange.opacity(0.15), .pink.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ) :
                    LinearGradient(
                        colors: [.blue.opacity(0.12), .purple.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 56, height: 56)
            
            Image(systemName: model.isAppleFoundation ? "apple.intelligence" : "sparkles")
                .font(.title2)
                .foregroundStyle(
                    model.isAppleFoundation ?
                    LinearGradient(
                        colors: [.orange, .pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ) :
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isAppleFoundation {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.shield")
                        .foregroundStyle(.orange)
                    Text(modelManager.isAppleIntelligenceAvailable ? String(localized: "No download required.") : modelManager.appleIntelligenceUnavailableHint)
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.5))
                }
            } else {
                if let compatibilityMessage = modelManager.compatibilityMessage(for: model) {
                    HStack(spacing: 6) {
                        Image(systemName: "ipad.and.arrow.forward")
                            .foregroundStyle(.orange)
                        Text(compatibilityMessage)
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.5))
                    }
                }
                if let readiness = modelManager.downloadReadiness(for: model) {
                    DownloadReadinessView(
                        readiness: readiness,
                        isDownloaded: model.downloadState.isDownloaded
                    )
                }
            }

            if (model.downloadState.isDownloaded || model.isAppleFoundation) && (model.engine != .appleFoundation || modelManager.isAppleIntelligenceAvailable) {
                if let result = testResult {
                    HStack(spacing: 6) {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(result.success ? .green : .red)
                        Text(result.success ? String(localized: "Passed") : String(localized: "Failed"))
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.5))
                    }

                    Text(String(format: String(localized: "Last test: %lldms • %@", defaultValue: "Last test: %lldms • %@"), Int64(result.durationMs), result.responseSnippet))
                        .font(.caption2)
                        .foregroundStyle(Color(white: 0.5))
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var modelInfoTags: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(modelManager.isOnboardingRecommended(model) ? modelManager.deviceFitSummary(for: model) : model.recommendedFor))
                .font(.caption)
                .foregroundStyle(modelManager.isOnboardingRecommended(model) ? Color.green.opacity(0.95) : Color(white: 0.42))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if modelManager.isOnboardingRecommended(model) {
                        InfoTag(icon: "sparkles", text: LocalizedStringKey(String(localized: "Recommended")), isHighlighted: true)
                    }

                    if model.isAppleFoundation {
                        InfoTag(icon: "apple.logo", text: LocalizedStringKey(String(localized: "Built-in")), isHighlighted: true)
                    } else {
                        InfoTag(icon: "externaldrive", text: LocalizedStringKey(String(format: String(localized: "%.1f GB", defaultValue: "%.1f GB"), model.sizeGB)))
                    }

                    if model.downloadState.isDownloaded {
                        InfoTag(icon: "checkmark.circle.fill", text: LocalizedStringKey(String(localized: "Ready")), isHighlighted: true)
                    }
                }

                HStack(spacing: 8) {
                    InfoTag(
                        icon: model.isAppleFoundation ? "hand.raised.fill" : "lock.shield",
                        text: LocalizedStringKey(model.privacyLabel),
                        isHighlighted: !model.isAppleFoundation
                    )

                    if model.currentDeviceFit != .supported {
                        InfoTag(
                            icon: model.currentDeviceFit.iconName,
                            text: LocalizedStringKey(model.currentDeviceFit.title),
                            isHighlighted: model.currentDeviceFit.isHighlighted
                        )
                    }
                }

                if !model.badges.isEmpty || model.supportsThinkingToggle {
                    HStack(spacing: 8) {
                        ForEach(Array(model.badges.prefix(3)), id: \.self) { badge in
                            InfoTag(
                                icon: badge.iconName,
                                text: LocalizedStringKey(badge.title),
                                isHighlighted: badge.isHighlighted
                            )
                        }

                        if model.supportsThinkingToggle {
                            thinkingPill
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
    }

    @ViewBuilder
    private var thinkingPill: some View {
        if isSelected {
            Button {
                let nextValue = !isThinkingEnabled
                isThinkingEnabled = nextValue
                modelManager.setThinkingEnabled(nextValue, for: model)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isThinkingEnabled ? "brain.head.profile.fill" : "brain.head.profile")
                        .font(.caption2)
                    Text(isThinkingEnabled ? String(localized: "Thinking On") : String(localized: "Thinking Off"))
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(isThinkingEnabled ? .blue : Color(white: 0.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isThinkingEnabled ? Color.blue.opacity(0.1) : Color(white: 0.95))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        } else {
            InfoTag(icon: "brain.head.profile", text: LocalizedStringKey(String(localized: "Thinking")))
        }
    }

    private func syncThinkingPreference() {
        guard model.supportsThinkingToggle else { return }
        isThinkingEnabled = modelManager.isThinkingEnabled(for: model)
    }

    @ViewBuilder
    private var actionButton: some View {
        if let compatibilityMessage = modelManager.compatibilityMessage(for: model), !model.isAppleFoundation {
            let title = String(localized: "Requires iPad Pro or Mac")
            switch model.downloadState {
            case .downloaded:
                HStack(spacing: 12) {
                    UnsupportedModelButton(title: title, subtitle: compatibilityMessage)
                    DeleteButton(action: {
                        modelManager.deleteModel(model.id)
                    })
                }
            case .downloading:
                DownloadingButton(action: {
                    modelManager.cancelDownload(model.id)
                })
            case .validating:
                DownloadingButton(action: {
                    modelManager.cancelDownload(model.id)
                })
            default:
                UnsupportedModelButton(title: title, subtitle: compatibilityMessage)
            }
        } else {
            switch model.downloadState {
            case .builtin:
                BuiltInButton(isSelected: isSelected) {
                    requireConsentAndPerform {
                        modelManager.selectModel(model.id)
                    }
                }

            case .notDownloaded:
                if isPremiumModel && !monetizationManager.hasPro {
                    UpgradeActionButton {
                        upgradeFeature = .allModels
                    }
                } else {
                    DownloadButton(sizeLabel: model.sizeLabel, action: {
                        requireConsentAndPerform {
                            modelManager.downloadModel(model.id, selectWhenFinished: true)
                        }
                    })
                }
                
            case .downloading:
                DownloadingButton(action: {
                    modelManager.cancelDownload(model.id)
                })
            case .validating:
                DownloadingButton(action: {
                    modelManager.cancelDownload(model.id)
                })
                
            case .downloaded:
                if isPremiumModel && !monetizationManager.hasPro {
                    HStack(spacing: 12) {
                        UpgradeActionButton {
                            upgradeFeature = .allModels
                        }
                        DeleteButton(action: {
                            modelManager.deleteModel(model.id)
                        })
                    }
                } else {
                    HStack(spacing: 12) {
                        SelectButton(isSelected: isSelected) {
                            requireConsentAndPerform {
                                modelManager.selectModel(model.id)
                            }
                        }
                        DeleteButton(action: {
                            modelManager.deleteModel(model.id)
                        })
                    }
                }
                
            case .error(let message):
                let action = modelManager.downloadErrorAction(for: model.id)
                ErrorButton(message: message, actionTitle: action.title, actionIcon: action.iconName, action: {
                    handleDownloadErrorAction(action)
                })
            }
        }
    }

    private var consentKey: String {
        "modelConsent.\(model.id)"
    }

    private var hasConsented: Bool {
        UserDefaults.standard.bool(forKey: consentKey)
    }

    private func requireConsentAndPerform(_ action: @escaping () -> Void) {
        if hasConsented {
            action()
            return
        }
        pendingAction = action
        showConsentSheet = true
    }

    private func handleDownloadErrorAction(_ action: DownloadErrorAction) {
        switch action {
        case .retry:
            modelManager.downloadModel(model.id, selectWhenFinished: true)
        case .freeSpace:
            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                openURL(settingsURL)
            }
        case .repair:
            modelManager.repairModel(model.id, selectWhenFinished: true)
        case .cellularRestricted:
            dismiss()
        }
    }
}

// MARK: - Model Consent Sheet

struct ModelConsentSheet: View {
    let model: ModelInfo
    let onAccept: () -> Void
    let onCancel: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    
                    if model.isAppleFoundation {
                        appleDataSharingCard
                    } else {
                        localProcessingCard
                        downloadDataCard
                    }
                    
                    termsCard
                }
                .padding(20)
            }
            .navigationTitle(String(localized: "Data & Privacy"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        dismiss()
                        onCancel()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Button {
                        dismiss()
                        onAccept()
                    } label: {
                        Text(model.isAppleFoundation ? String(localized: "Allow Data Sharing & Continue") : String(localized: "I Understand — No Data Shared"))
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(
                                LinearGradient(
                                    colors: model.isAppleFoundation ? [.orange, .pink] : [.blue, .blue.opacity(0.85)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    
                    Text(String(localized: "You can change models anytime in Settings."))
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.5))
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .background(Color(white: 0.98))
            }
        }
    }
    
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.name)
                .font(.title2.bold())
                .foregroundStyle(Color(white: 0.1))
            Text(String(format: String(localized: "Provider: %@", defaultValue: "Provider: %@"), model.providerName))
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.5))
        }
    }
    
    // MARK: - Apple Intelligence Data Sharing Card
    
    private var appleDataSharingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text(String(localized: "Data Sent to Apple Inc."))
                    .font(.headline)
                    .foregroundStyle(Color(white: 0.2))
            }
            
            Text(String(localized: "When you use Apple Intelligence, the following personal data may be sent to Apple Inc. (including Apple Private Cloud Compute) to generate AI responses:"))
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.5))
            
            VStack(alignment: .leading, spacing: 8) {
                dataRow(icon: "text.bubble", text: String(localized: "Your chat messages and prompts"))
                dataRow(icon: "doc.text", text: String(localized: "Text from attached documents"))
                dataRow(icon: "text.quote", text: String(localized: "Conversation context and history"))
            }
            
            Text(String(localized: "By tapping \"Allow Data Sharing & Continue\", you authorize this data transfer to Apple Inc. for AI processing."))
                .font(.caption)
                .foregroundStyle(Color(white: 0.45))
                .padding(.top, 4)
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
    }
    
    // MARK: - Local Model: No Data Shared Card
    
    private var localProcessingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                Text(String(localized: "Data NOT Sent to Any Third Party"))
                    .font(.headline)
                    .foregroundStyle(Color(white: 0.2))
            }
            
            Text(String(format: String(localized: "This model runs 100%% on your device. The following data is processed locally and is never sent to %@ or any third-party AI service:", defaultValue: "This model runs 100%% on your device. The following data is processed locally and is never sent to %@ or any third-party AI service:"), model.providerName))
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.5))
            
            VStack(alignment: .leading, spacing: 8) {
                privacyRow(text: String(localized: "Your chat messages and prompts"))
                privacyRow(text: String(localized: "Text from attached documents"))
                privacyRow(text: String(localized: "Conversation context and history"))
                privacyRow(text: String(localized: "Voice input and transcriptions"))
            }
            
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                Text(String(localized: "All AI inference happens on your device. No personal data leaves your device for AI processing."))
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.45))
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(Color.green.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.green.opacity(0.15), lineWidth: 1)
        )
    }
    
    // MARK: - Download Data Card
    
    private var downloadDataCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Text(String(localized: "Model Download Data"))
                    .font(.headline)
                    .foregroundStyle(Color(white: 0.2))
            }
            
            Text(String(localized: "To download the model files, a network request is made to Hugging Face Inc. (model hosting provider). This request may include:"))
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.5))
            
            VStack(alignment: .leading, spacing: 8) {
                dataRow(icon: "network", text: String(localized: "Your IP address"))
                dataRow(icon: "gear", text: String(localized: "Device request headers (e.g. OS version)"))
            }
            
            Text(String(localized: "No chat messages, prompts, documents, or any personal content is sent during downloads."))
                .font(.caption)
                .foregroundStyle(Color(white: 0.45))
                .padding(.top, 4)
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
    }
    
    // MARK: - Terms Card
    
    private var termsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.blue)
                Text(String(localized: "Terms & Conditions"))
                    .font(.headline)
                    .foregroundStyle(Color(white: 0.2))
            }
            
            Text(String(localized: "By continuing, you agree to the terms and conditions for this model, as well as the app's Terms of Service and Privacy Policy."))
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.5))
            
            VStack(alignment: .leading, spacing: 8) {
                if let termsURL = model.termsURL {
                    Link(String(localized: "Model Terms"), destination: termsURL)
                }
                if let privacyURL = model.privacyURL {
                    Link(String(localized: "Model Privacy"), destination: privacyURL)
                }
                Link(String(localized: "App Terms of Service"), destination: URL(string: "https://sudoswisshub.github.io/MetalMind-AI/terms.html") ?? URL(string: "about:blank")!)
                Link(String(localized: "App Privacy Policy"), destination: URL(string: "https://sudoswisshub.github.io/MetalMind-AI/privacy.html") ?? URL(string: "about:blank")!)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.blue)
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
    }
    
    // MARK: - Helper Views
    
    private func dataRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.4))
        }
    }
    
    private func privacyRow(text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.4))
        }
    }
}

// MARK: - Info Tag

struct InfoTag: View {
    let icon: String
    let text: LocalizedStringKey
    var isHighlighted: Bool = false
    
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(isHighlighted ? .green : Color(white: 0.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isHighlighted ? Color.green.opacity(0.1) : Color(white: 0.95))
        .clipShape(Capsule())
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct DownloadReadinessView: View {
    let readiness: ModelManager.DownloadReadiness
    let isDownloaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(isDownloaded ? .green : .blue)
                Text(isDownloaded ? String(localized: "Ready offline") : String(localized: "Download plan"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(white: 0.24))
            }

            if isDownloaded {
                readinessRow(
                    icon: "lock.shield.fill",
                    text: readiness.offlineText,
                    color: .green
                )
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        readinessPill(icon: "externaldrive", text: readiness.modelSizeText)
                        readinessPill(icon: "internaldrive", text: readiness.requiredSpaceText)
                        readinessPill(
                            icon: readiness.hasEnoughSpace ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                            text: readiness.availableSpaceText,
                            isWarning: !readiness.hasEnoughSpace
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            readinessPill(icon: "externaldrive", text: readiness.modelSizeText)
                            readinessPill(icon: "internaldrive", text: readiness.requiredSpaceText)
                        }
                        readinessPill(
                            icon: readiness.hasEnoughSpace ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                            text: readiness.availableSpaceText,
                            isWarning: !readiness.hasEnoughSpace
                        )
                    }
                }

                readinessRow(
                    icon: readiness.networkIconName,
                    text: readiness.networkText,
                    color: readiness.isNetworkWarning ? .orange : .blue
                )
                readinessRow(
                    icon: "lock.shield.fill",
                    text: readiness.offlineText,
                    color: .green
                )
            }
        }
        .padding(12)
        .background(Color(white: 0.975))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.black.opacity(0.04), lineWidth: 1)
        )
    }

    private func readinessPill(icon: String, text: String, isWarning: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .foregroundStyle(isWarning ? .orange : Color(white: 0.45))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isWarning ? Color.orange.opacity(0.08) : Color.white)
        .clipShape(Capsule())
    }

    private func readinessRow(icon: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 16)
            Text(text)
                .font(.caption2)
                .foregroundStyle(Color(white: 0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Action Buttons

struct BuiltInButton: View {
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body.bold())
                    Text(String(localized: "Selected"))
                        .fontWeight(.semibold)
                } else {
                    Image(systemName: "circle")
                        .font(.body)
                    Text(String(localized: "Use This Model"))
                        .fontWeight(.medium)
                }
            }
            .foregroundStyle(isSelected ? .white : .orange)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                isSelected ?
                LinearGradient(
                    colors: [.orange, .pink],
                    startPoint: .leading,
                    endPoint: .trailing
                ) :
                LinearGradient(
                    colors: [.orange.opacity(0.1), .pink.opacity(0.1)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(ActionButtonStyle())
    }
}

struct SelectButton: View {
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body.bold())
                    Text(String(localized: "Selected"))
                        .fontWeight(.semibold)
                } else {
                    Image(systemName: "circle")
                        .font(.body)
                    Text(String(localized: "Select"))
                        .fontWeight(.medium)
                }
            }
            .foregroundStyle(isSelected ? .white : .blue)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                isSelected ?
                LinearGradient(
                    colors: [.blue, .blue.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                ) :
                LinearGradient(
                    colors: [.blue.opacity(0.08), .blue.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(ActionButtonStyle())
    }
}

struct DownloadButton: View {
    let sizeLabel: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.body.bold())

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Download & Select"))
                        .font(.subheadline.weight(.semibold))
                    Text(String(format: String(localized: "%@ • Works offline after download", defaultValue: "%@ • Works offline after download"), sizeLabel))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }

                Spacer(minLength: 8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [.blue, .blue.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(ActionButtonStyle())
    }
}

struct UpgradeActionButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "crown.fill")
                    .font(.body.bold())
                Text(String(localized: "Unlock Pro"))
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [.orange, .pink],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(ActionButtonStyle())
    }
}

struct UnsupportedModelButton: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(white: 0.35))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Color(white: 0.5))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(Color(white: 0.94))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct DownloadingButton: View {
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var closeButtonSize = 32.0

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12)
    }

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(.blue)

            Text(String(localized: "Loading"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.blue)

            Spacer(minLength: 8)

            Button(role: .cancel, action: action) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(Color(white: 0.45))
                    .frame(width: closeButtonSize, height: closeButtonSize)
                    .background(Color.black.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel("Cancel download")
            .accessibilityInputLabels(["Cancel", "Stop download"])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            panelShape
                .fill(Color.blue.opacity(0.05))
        )
        .overlay(
            panelShape
                .strokeBorder(Color.blue.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading")
    }
}

struct DeleteButton: View {
    let action: () -> Void
    @State private var showConfirmation = false
    
    var body: some View {
        Button {
            showConfirmation = true
        } label: {
            Image(systemName: "trash")
                .font(.body)
                .foregroundStyle(.red.opacity(0.8))
                .frame(width: 44, height: 44)
                .background(Color.red.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(ActionButtonStyle())
        .confirmationDialog(String(localized: "Delete Model?"), isPresented: $showConfirmation) {
            Button(String(localized: "Delete"), role: .destructive, action: action)
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This will remove the downloaded model from your device. You can download it again anytime."))
        }
    }
}

struct ErrorButton: View {
    let message: String
    let actionTitle: String
    let actionIcon: String
    let action: () -> Void
    
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.5))
                    .lineLimit(2)
            }
            
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: actionIcon)
                    Text(actionTitle)
                        .fontWeight(.medium)
                }
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(ActionButtonStyle())
        }
    }
}

struct ActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

#Preview {
    ModelDownloadView()
        .environment(ModelManager())
        .environment(LLMEngine())
        .environment(MonetizationManager())
}
