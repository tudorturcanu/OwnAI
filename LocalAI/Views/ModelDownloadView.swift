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

    private var shouldShowHeaderTips: Bool {
        NotificationManager.shared.launchCount <= 2
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if shouldShowHeaderTips {
                    headerView
                }

                ForEach(appleModels) { model in
                    ModelCard(model: model)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        ))
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Model Families")
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
        .navigationTitle("Manage Models")
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

                Text("Using Apple Watch too? Smaller models usually reply faster because requests still run on your iPhone.")
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
                        Text(family.title)
                            .font(.title3.bold())
                            .foregroundStyle(Color(white: 0.1))
                    }

                    Text(family.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Color(white: 0.45))

                    Text(familyGuidance)
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
        .navigationTitle(family.title)
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
                        Text(group.family.title)
                            .font(.title3.bold())
                            .foregroundStyle(Color(white: 0.1))

                        if selectedModel != nil {
                            Text("ACTIVE")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue)
                                .clipShape(Capsule())
                        }
                    }

                    Text(group.family.subtitle)
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
                    InfoTag(icon: "square.stack.3d.up", text: modelCountText)
                    InfoTag(icon: "externaldrive", text: group.sizeRangeText)
                    if group.downloadedCount > 0 {
                        InfoTag(icon: "checkmark.circle.fill", text: readyText, isHighlighted: true)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        InfoTag(icon: "square.stack.3d.up", text: modelCountText)
                        InfoTag(icon: "externaldrive", text: group.sizeRangeText)
                    }

                    if group.downloadedCount > 0 {
                        InfoTag(icon: "checkmark.circle.fill", text: readyText, isHighlighted: true)
                    }
                }
            }

            if let recommendedModel {
                InfoTag(icon: "sparkles", text: String(format: String(localized: "Recommended: %@", defaultValue: "Recommended: %@"), recommendedModel.name), isHighlighted: true)
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
                            Text("DEFAULT")
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
                            Text(model.shortDescription)
                                .font(.subheadline)
                                .foregroundStyle(Color(white: 0.5))
                                .lineLimit(4)
                                .fixedSize(horizontal: false, vertical: true)

                            if isPremiumModel && !monetizationManager.hasPro {
                                InfoTag(icon: "crown.fill", text: String(localized: "Pro"), isHighlighted: true)
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
                let freeGB = DiskSpace.availableGB()
                let hasSpace = freeGB >= model.sizeGB * 1.05
                HStack(spacing: 6) {
                    Image(systemName: hasSpace ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(hasSpace ? .green : .orange)
                    Text(String(format: String(localized: "Free space: %.1f GB", defaultValue: "Free space: %.1f GB"), freeGB))
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.5))
                }
                if !hasSpace {
                    Text("Low storage may prevent downloads or slow performance.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text("Inference privacy: Prompts and document text stay on-device and are not sent to third-party AI services.")
                    .font(.caption2)
                    .foregroundStyle(Color(white: 0.45))
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
            Text(modelManager.isOnboardingRecommended(model) ? modelManager.deviceFitSummary(for: model) : model.recommendedFor)
                .font(.caption)
                .foregroundStyle(modelManager.isOnboardingRecommended(model) ? Color.green.opacity(0.95) : Color(white: 0.42))
                .fixedSize(horizontal: false, vertical: true)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if modelManager.isOnboardingRecommended(model) {
                        InfoTag(icon: "sparkles", text: String(localized: "Recommended"), isHighlighted: true)
                    }

                    if model.isAppleFoundation {
                        InfoTag(icon: "apple.logo", text: String(localized: "Built-in"), isHighlighted: true)
                    } else {
                        InfoTag(icon: "externaldrive", text: String(format: String(localized: "%.1f GB", defaultValue: "%.1f GB"), model.sizeGB))
                    }

                    InfoTag(
                        icon: model.isAppleFoundation ? "hand.raised.fill" : "lock.shield",
                        text: model.privacyLabel,
                        isHighlighted: !model.isAppleFoundation
                    )

                    ForEach(Array(model.badges.prefix(3)), id: \.self) { badge in
                        InfoTag(
                            icon: badge.iconName,
                            text: badge.title,
                            isHighlighted: badge.isHighlighted
                        )
                    }

                    if model.downloadState.isDownloaded {
                        InfoTag(icon: "checkmark.circle.fill", text: String(localized: "Ready"), isHighlighted: true)
                    }

                    InfoTag(
                        icon: model.currentDeviceFit.iconName,
                        text: model.currentDeviceFit.title,
                        isHighlighted: model.currentDeviceFit.isHighlighted
                    )

                    if model.supportsThinkingToggle {
                        thinkingPill
                    }
                }
            }
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
            InfoTag(icon: "brain.head.profile", text: String(localized: "Thinking"))
        }
    }

    private func syncThinkingPreference() {
        guard model.supportsThinkingToggle else { return }
        isThinkingEnabled = modelManager.isThinkingEnabled(for: model)
    }

    @ViewBuilder
    private var actionButton: some View {
        if let compatibilityMessage = modelManager.compatibilityMessage(for: model), !model.isAppleFoundation {
            let title = ModelInfo.runtimeUnsupportedModelIDs.contains(model.id)
                ? String(localized: "Unavailable in this build")
                : String(localized: "Requires iPad Pro or Mac")
            switch model.downloadState {
            case .downloaded:
                HStack(spacing: 12) {
                    UnsupportedModelButton(title: title, subtitle: compatibilityMessage)
                    DeleteButton(action: {
                        modelManager.deleteModel(model.id)
                    })
                }
            case .downloading(let progress):
                DownloadingButton(progress: progress, sizeGB: model.sizeGB, action: {
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
                            modelManager.downloadModel(model.id)
                        }
                    })
                }
                
            case .downloading(let progress):
                DownloadingButton(progress: progress, sizeGB: model.sizeGB, action: {
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
            modelManager.downloadModel(model.id)
        case .freeSpace:
            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                openURL(settingsURL)
            }
        case .repair:
            modelManager.repairModel(model.id)
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
            .navigationTitle("Data & Privacy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
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
                    
                    Text("You can change models anytime in Settings.")
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
                Text("Data Sent to Apple Inc.")
                    .font(.headline)
                    .foregroundStyle(Color(white: 0.2))
            }
            
            Text("When you use Apple Intelligence, the following personal data may be sent to **Apple Inc.** (including Apple Private Cloud Compute) to generate AI responses:")
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.5))
            
            VStack(alignment: .leading, spacing: 8) {
                dataRow(icon: "text.bubble", text: String(localized: "Your chat messages and prompts"))
                dataRow(icon: "doc.text", text: String(localized: "Text from attached documents"))
                dataRow(icon: "text.quote", text: String(localized: "Conversation context and history"))
            }
            
            Text("By tapping \"Allow Data Sharing & Continue\", you authorize this data transfer to Apple Inc. for AI processing.")
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
                Text("Data NOT Sent to Any Third Party")
                    .font(.headline)
                    .foregroundStyle(Color(white: 0.2))
            }
            
            Text("This model runs **100% on your device**. The following data is processed locally and is **never sent** to \(model.providerName) or any third-party AI service:")
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
                Text("All AI inference happens on your device. No personal data leaves your device for AI processing.")
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
                Text("Model Download Data")
                    .font(.headline)
                    .foregroundStyle(Color(white: 0.2))
            }
            
            Text("To download the model files, a network request is made to **Hugging Face Inc.** (model hosting provider). This request may include:")
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.5))
            
            VStack(alignment: .leading, spacing: 8) {
                dataRow(icon: "network", text: String(localized: "Your IP address"))
                dataRow(icon: "gear", text: String(localized: "Device request headers (e.g. OS version)"))
            }
            
            Text("No chat messages, prompts, documents, or any personal content is sent during downloads.")
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
                Text("Terms & Conditions")
                    .font(.headline)
                    .foregroundStyle(Color(white: 0.2))
            }
            
            Text("By continuing, you agree to the terms and conditions for this model, as well as the app's Terms of Service and Privacy Policy.")
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.5))
            
            VStack(alignment: .leading, spacing: 8) {
                if let termsURL = model.termsURL {
                    Link("Model Terms", destination: termsURL)
                }
                if let privacyURL = model.privacyURL {
                    Link("Model Privacy", destination: privacyURL)
                }
                Link("App Terms of Service", destination: URL(string: "https://sudoswisshub.github.io/MetalMind-AI/terms.html")!)
                Link("App Privacy Policy", destination: URL(string: "https://sudoswisshub.github.io/MetalMind-AI/privacy.html")!)
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
    let text: String
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
                    Text("Selected")
                        .fontWeight(.semibold)
                } else {
                    Image(systemName: "circle")
                        .font(.body)
                    Text("Use This Model")
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
                    Text("Selected")
                        .fontWeight(.semibold)
                } else {
                    Image(systemName: "circle")
                        .font(.body)
                    Text("Select")
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
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.body.bold())
                    Text("Download")
                        .fontWeight(.semibold)
                }

                Text("\(sizeLabel) • Select it after the download finishes")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
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
                Text("Unlock Pro")
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
    let progress: Double
    let sizeGB: Double
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @ScaledMetric(relativeTo: .body) private var progressBarHeight = 8.0
    @ScaledMetric(relativeTo: .body) private var closeButtonSize = 34.0
    @State private var estimate = DownloadEstimate()

    private var clampedProgress: Double {
        max(0.0, min(progress, 0.99))
    }

    private var downloadedBytes: Double {
        sizeGB * 1_000_000_000 * clampedProgress
    }

    private var statusLine: String {
        let downloadedLabel = Self.byteCountFormatter.string(fromByteCount: Int64(downloadedBytes))
        guard let speedBytesPerSecond = estimate.speedBytesPerSecond,
              speedBytesPerSecond > 50_000 else {
            return "\(downloadedLabel) downloaded, estimating speed..."
        }

        let speedLabel = Self.speedFormatter.string(fromByteCount: Int64(speedBytesPerSecond)) + "/s"
        let remainingLabel = estimate.remainingLabel(progress: clampedProgress, totalBytes: sizeGB * 1_000_000_000)
        return "\(downloadedLabel) (\(speedLabel)) - \(remainingLabel) remaining"
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                progressBar

                Button(role: .cancel, action: action) {
                    Label("Cancel download", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.footnote.bold())
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: closeButtonSize, height: closeButtonSize)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.12))
                        )
                }
                .accessibilityInputLabels(["Cancel", "Stop download"])
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if differentiateWithoutColor {
                    Text("\(Int(clampedProgress * 100))%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .monospacedDigit()
                }

                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.92))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .allowsTightening(true)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            panelShape
                .fill(
                    LinearGradient(
                        colors: [
                            Color(white: 0.20),
                            Color(white: 0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            panelShape
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
        .onChange(of: progress, initial: true) { _, newValue in
            estimate.ingest(progress: newValue, totalBytes: sizeGB * 1_000_000_000)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Download in progress")
        .accessibilityValue("\(Int(clampedProgress * 100)) percent complete. \(statusLine)")
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            let availableWidth = max(0, proxy.size.width)
            let fillWidth = max(progressBarHeight * 1.4, availableWidth * clampedProgress)
            let handleOffset = min(max(progressBarHeight * 0.8, fillWidth), availableWidth)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                .white,
                                Color.white.opacity(0.92)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth)
                    .overlay(alignment: .trailing) {
                        Circle()
                            .fill(.white)
                            .frame(width: progressBarHeight + 2, height: progressBarHeight + 2)
                            .shadow(color: .white.opacity(0.35), radius: 3)
                            .opacity(clampedProgress > 0.015 ? 1 : 0)
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: clampedProgress)

                if !reduceMotion {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0),
                                    .white.opacity(0.24),
                                    .white.opacity(0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: min(availableWidth * 0.22, 90), height: progressBarHeight)
                        .offset(x: max(0, handleOffset - min(availableWidth * 0.18, 72)))
                        .blendMode(.plusLighter)
                        .animation(.easeInOut(duration: 0.25), value: clampedProgress)
                }
            }
        }
        .frame(height: max(progressBarHeight, 30))
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        formatter.zeroPadsFractionDigits = true
        return formatter
    }()

    private static let speedFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        formatter.zeroPadsFractionDigits = true
        return formatter
    }()
}

private struct DownloadEstimate {
    private(set) var lastProgress: Double?
    private(set) var lastSampleDate: Date?
    private(set) var speedBytesPerSecond: Double?

    mutating func ingest(progress: Double, totalBytes: Double, now: Date = .now) {
        let clampedProgress = max(0.0, min(progress, 0.99))

        defer {
            lastProgress = clampedProgress
            lastSampleDate = now
        }

        guard let previousProgress = lastProgress,
              let previousDate = lastSampleDate else {
            return
        }

        let elapsed = now.timeIntervalSince(previousDate)
        guard elapsed >= 0.25 else { return }

        let deltaProgress = clampedProgress - previousProgress
        guard deltaProgress > 0 else { return }

        let instantaneousSpeed = (totalBytes * deltaProgress) / elapsed
        if let currentSpeed = speedBytesPerSecond {
            speedBytesPerSecond = (currentSpeed * 0.72) + (instantaneousSpeed * 0.28)
        } else {
            speedBytesPerSecond = instantaneousSpeed
        }
    }

    func remainingLabel(progress: Double, totalBytes: Double) -> String {
        guard let speedBytesPerSecond,
              speedBytesPerSecond > 50_000 else {
            return "calculating time"
        }

        let remainingBytes = max(0, 1.0 - progress) * totalBytes
        let seconds = remainingBytes / speedBytesPerSecond
        guard seconds.isFinite else { return "calculating time" }

        if seconds < 60 {
            return "\(max(1, Int(seconds.rounded()))) sec"
        }

        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 {
            return "\(minutes) min"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return "\(hours) hr"
        }
        return "\(hours) hr \(remainingMinutes) min"
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
        .confirmationDialog("Delete Model?", isPresented: $showConfirmation) {
            Button("Delete", role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the downloaded model from your device. You can download it again anytime.")
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
