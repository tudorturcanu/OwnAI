//
//  OnboardingView.swift
//  Own Ai
//
//  Created by Tudor on 29.01.2026.
//

import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    let onComplete: () -> Void
    @Environment(LLMEngine.self) private var llmEngine
    @Environment(ModelManager.self) private var modelManager
    @Environment(MonetizationManager.self) private var monetizationManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentPage = 0
    @State private var isApplyingRecommendation = false
    @State private var showModelPicker = false
    @State private var pickerInitialModelID: String?
    @State private var customModelID: String?
    @State private var modelAwaitingConsent: ModelInfo?
    @AccessibilityFocusState private var focusedPage: Int?

    private var hasRecommendationPage: Bool {
        onboardingRecommendationData != nil
    }

    private var privacyPageIndex: Int {
        1
    }

    private var recommendationPageIndex: Int {
        2
    }

    private var pageCount: Int {
        hasRecommendationPage ? 3 : 2
    }


    private var onboardingRecommendationData: (model: ModelInfo, recommendation: ModelManager.OnboardingRecommendation)? {
        guard let recommendation = modelManager.onboardingRecommendation(),
              let model = modelManager.models.first(where: { $0.id == recommendation.modelID }) else {
            return nil
        }
        return (model, recommendation)
    }

    private var recommendationPageContent: (model: ModelInfo, recommendation: ModelManager.OnboardingRecommendation)? {
        guard let recommendationData = onboardingRecommendationData else {
            return nil
        }

        guard let customModel = effectiveOnboardingModel, customModelID != nil else {
            return recommendationData
        }

        let summary: String
        if customModel.downloadState.isDownloaded || customModel.engine == .appleFoundation {
            summary = String(localized: "Using your selected model.")
        } else {
            summary = String(
                format: String(
                    localized: "%@ download selected.",
                    defaultValue: "%@ download selected."
                ),
                customModel.sizeLabel
            )
        }

        let detail: String
        switch customModel.currentDeviceFit {
        case .recommended:
            detail = String(
                format: String(
                    localized: "%@ is a strong fit for this device.",
                    defaultValue: "%@ is a strong fit for this device."
                ),
                customModel.name
            )
        case .supported:
            detail = String(
                format: String(
                    localized: "%@ works on this device, but may run slower.",
                    defaultValue: "%@ works on this device, but may run slower."
                ),
                customModel.name
            )
        case .unsupported:
            detail = DeviceResourcePolicy.supportsMLXCompute
                ? String(
                    format: String(
                        localized: "%@ is likely too heavy for this device.",
                        defaultValue: "%@ is likely too heavy for this device."
                    ),
                    customModel.name
                )
                : String(
                    format: String(
                        localized: "%@ can't run on this device. Downloadable models need an A14 chip or newer.",
                        defaultValue: "%@ can't run on this device. Downloadable models need an A14 chip or newer."
                    ),
                    customModel.name
                )
        }

        return (
            customModel,
            ModelManager.OnboardingRecommendation(
                modelID: customModel.id,
                title: String(localized: "Selected for onboarding"),
                summary: summary,
                detail: detail,
                actionTitle: primaryActionTitle,
                prefersImmediateUse: customModel.downloadState.isDownloaded || customModel.engine == .appleFoundation,
                usesFallback: false
            )
        )
    }
    
    var body: some View {
        ZStack {
            Color.adaptiveCard.ignoresSafeArea()

            Group {
                switch currentPage {
                case privacyPageIndex:
                    privacyPage
                case recommendationPageIndex where hasRecommendationPage:
                    recommendationPage
                default:
                    welcomePage
                }
            }
            .id(currentPage)
            .transition(.opacity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            progressHeader
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: currentPage)
        .onAppear {
            DispatchQueue.main.async {
                focusedPage = currentPage
            }
        }
        .onChange(of: currentPage) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusedPage = currentPage
            }
        }
        .onChange(of: modelManager.selectedModelID) {
            guard showModelPicker else { return }
            guard modelManager.selectedModelID != pickerInitialModelID else { return }
            customModelID = modelManager.selectedModelID
        }
        .sheet(isPresented: $showModelPicker, onDismiss: {
            pickerInitialModelID = nil
        }) {
            NavigationStack {
                ModelDownloadView()
            }
            .environment(modelManager)
            .environment(llmEngine)
            .environment(monetizationManager)
        }
        .sheet(item: $modelAwaitingConsent) { model in
            ModelConsentSheet(model: model) {
                UserDefaults.standard.set(true, forKey: consentKey(for: model))
                modelAwaitingConsent = nil
                finishOnboarding(with: model)
            } onCancel: {
                modelAwaitingConsent = nil
                isApplyingRecommendation = false
            }
        }
    }

    private var progressHeader: some View {
        HStack {
            Group {
                if currentPage > 0 {
                    Button {
                        withAnimation(reduceMotion ? nil : .default) {
                            currentPage = max(0, currentPage - 1)
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(String(localized: "Previous step"))
                } else {
                    Color.clear
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                }
            }

            Spacer()

            Text(
                String(
                    format: String(localized: "Step %lld of %lld", defaultValue: "Step %lld of %lld"),
                    Int64(currentPage + 1),
                    Int64(pageCount)
                )
            )
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)

            Spacer()

            Color.clear
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Page 1: Welcome
    
    private var welcomePage: some View {
        ScrollView {
            VStack(spacing: 28) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.orange.opacity(0.1), .pink.opacity(0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 150, height: 150)

                    SparkleView(size: 130)
                }

                VStack(spacing: 12) {
                    Text(String(localized: "Welcome to Own AI"))
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.adaptive(white: 0.1))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($focusedPage, equals: 0)

                    Text(modelManager.isAppleIntelligenceDeviceSupported ?
                         LocalizedStringKey("Private AI on your device, with Apple Intelligence available when you choose it.") :
                         LocalizedStringKey("Private AI that runs entirely on your device."))
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 20) {
                    featureRow(
                        icon: "lock.shield.fill",
                        color: .green,
                        title: String(localized: "Private by Choice"),
                        subtitle: modelManager.isAppleIntelligenceDeviceSupported ?
                            String(localized: "Use a fully local model, or explicitly choose Apple Intelligence when you want it.") :
                            String(localized: "Your prompts and documents stay on this device with local models.")
                    )

                    featureRow(
                        icon: "wifi.slash",
                        color: .orange,
                        title: String(localized: "Works Offline"),
                        subtitle: String(localized: "Downloaded local models keep working without an internet connection.")
                    )

                    if SpeechManager.isVoiceConversationEnabled {
                        featureRow(
                            icon: "waveform",
                            color: .blue,
                            title: String(localized: "Voice Conversations"),
                            subtitle: String(localized: "Talk hands-free, hear replies aloud, and interrupt naturally.")
                        )
                    }
                }

                Button {
                    withAnimation(reduceMotion ? nil : .default) {
                        currentPage = privacyPageIndex
                    }
                } label: {
                    Text(String(localized: "Continue"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 56)
                        .background(
                            LinearGradient(
                                colors: [.orange, .pink],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .pink.opacity(0.3), radius: 10, y: 5)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Page 2: Recommendation

    private var recommendationPage: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 14) {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 48, weight: .light))
                        .accessibilityHidden(true)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.orange, .pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Text(recommendationPageTitle)
                        .font(.title.bold())
                        .foregroundStyle(Color.adaptive(white: 0.1))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($focusedPage, equals: recommendationPageIndex)

                    Text(recommendationPageSubtitle)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.adaptive(white: 0.5))
                        .padding(.horizontal, 32)
                }
                .padding(.top, 40)
                .padding(.bottom, 28)

                VStack(spacing: 16) {
                    if let recommendationData = recommendationPageContent {
                        recommendationCard(
                            model: recommendationData.model,
                            recommendation: recommendationData.recommendation
                        )
                    }

                    if let statusText = primaryStatusText {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(Color.adaptive(white: 0.5))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.horizontal, 24)

                VStack(spacing: 12) {
                    Button {
                        applyRecommendedModel()
                    } label: {
                        HStack(spacing: 10) {
                            if isApplyingRecommendation {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }

                            Text(LocalizedStringKey(primaryActionTitle))
                                .font(.headline.weight(.bold))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 56)
                        .padding(.horizontal, 16)
                        .background(
                            LinearGradient(
                                colors: [.orange, .pink],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .pink.opacity(0.25), radius: 10, y: 5)
                    }
                    .disabled(isApplyingRecommendation)
                    .opacity(isApplyingRecommendation ? 0.85 : 1)

                    Button {
                        pickerInitialModelID = modelManager.selectedModelID
                        showModelPicker = true
                    } label: {
                        Text(LocalizedStringKey(secondaryActionTitle))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.adaptiveCard)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.orange.opacity(0.18), lineWidth: 1)
                            )
                    }
                    .disabled(isApplyingRecommendation)
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }
        }
    }
    
    // MARK: - Page 3: Data & Privacy
    
    private var privacyPage: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 50, weight: .light))
                        .accessibilityHidden(true)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    Text(String(localized: "Data & Privacy"))
                        .font(.title.bold())
                        .foregroundStyle(Color.adaptive(white: 0.1))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($focusedPage, equals: privacyPageIndex)
                    
                    Text(String(localized: "Before you begin, here's how the app handles your data."))
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.adaptive(white: 0.5))
                        .padding(.horizontal, 32)
                }
                .padding(.top, 40)
                .padding(.bottom, 28)
                
                VStack(spacing: 16) {
                    // Data the app processes
                    privacyCard(
                        icon: "doc.text.fill",
                        iconColor: .blue,
                        title: String(localized: "Data the App Processes"),
                        items: [
                            String(localized: "Chat messages and prompts you type"),
                            String(localized: "Text from documents you import"),
                            String(localized: "Voice input (speech-to-text)"),
                            String(localized: "Conversation history stored on your device")
                        ]
                    )
                    
                    // On-device models
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(.green)
                                .accessibilityHidden(true)
                            Text(String(localized: "On-Device Models (e.g. Gemma 2 2B)"))
                                .font(.subheadline.bold())
                                .foregroundStyle(Color.adaptive(white: 0.2))
                        }
                        
                        Text("MLX models like Gemma 2 2B run **100% on your device**. Your prompts, documents, and personal data are **never sent** to Google LLC or any third-party AI service.")
                            .font(.caption)
                            .foregroundStyle(Color.adaptive(white: 0.5))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.green.opacity(0.15), lineWidth: 1)
                    )
                    
                    
                    if modelManager.isAppleIntelligenceDeviceSupported {
                        // Apple Intelligence
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "apple.intelligence")
                                    .foregroundStyle(.orange)
                                    .accessibilityHidden(true)
                                Text(String(localized: "Apple Intelligence"))
                                    .font(.subheadline.bold())
                                    .foregroundStyle(Color.adaptive(white: 0.2))
                            }
                            
                            Text("If you choose Apple Intelligence, prompts and document text may be sent to **Apple Inc.** (including Private Cloud Compute) for AI processing. You will be asked for permission before this model is used.")
                                .font(.caption)
                                .foregroundStyle(Color.adaptive(white: 0.5))
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.orange.opacity(0.15), lineWidth: 1)
                        )
                    }
                    
                    // Model downloads
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.blue)
                                .accessibilityHidden(true)
                            Text("Model Downloads")
                                .font(.subheadline.bold())
                                .foregroundStyle(Color.adaptive(white: 0.2))
                        }
                        
                        Text("Downloading model files uses a network request to **Hugging Face Inc.** This may share your IP address and device headers. No personal content is sent.")
                            .font(.caption)
                            .foregroundStyle(Color.adaptive(white: 0.5))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.adaptive(white: 0.96))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 24)
                
                // Accept button
                VStack(spacing: 12) {
                    Button {
                        withAnimation(reduceMotion ? nil : .default) {
                            if hasRecommendationPage {
                                currentPage = recommendationPageIndex
                            } else {
                                applyRecommendedModel()
                            }
                        }
                    } label: {
                        Text(LocalizedStringKey(privacyPrimaryActionTitle))
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: .purple.opacity(0.3), radius: 10, y: 5)
                    }
                    .disabled(isApplyingRecommendation)
                    .opacity(isApplyingRecommendation ? 0.7 : 1)

                    Text("By tapping above, you agree to our [Terms of Service](https://sudoswisshub.github.io/MetalMind-AI/terms.html) and [Privacy Policy](https://sudoswisshub.github.io/MetalMind-AI/privacy.html).")
                        .font(.caption)
                        .tint(.blue)
                        .foregroundStyle(Color.adaptive(white: 0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 24)
            }
        }
    }

    private var primaryActionTitle: String {
        if isApplyingRecommendation {
            return String(localized: "Preparing...")
        }
        if let activeModel = effectiveOnboardingModel {
            switch activeModel.downloadState {
            case .downloading(let progress, _), .validating(let progress):
                return String(
                    format: String(
                        localized: "Continue While %@ Downloads (%lld%%)",
                        defaultValue: "Continue While %@ Downloads (%lld%%)"
                    ),
                    activeModel.name,
                    Int64(Int(progress * 100))
                )
            case .downloaded, .builtin:
                return String(
                    format: String(
                        localized: "Use %@",
                        defaultValue: "Use %@"
                    ),
                    activeModel.name
                )
            case .notDownloaded, .error:
                return String(
                    format: String(
                        localized: "Download %@",
                        defaultValue: "Download %@"
                    ),
                    activeModel.name
                )
            }
        }
        return modelManager.onboardingRecommendation()?.actionTitle ?? String(localized: "I Understand & Accept")
    }

    private var secondaryActionTitle: String {
        String(localized: "Choose Another Model")
    }

    private var privacyPrimaryActionTitle: String {
        hasRecommendationPage ? String(localized: "Agree & Continue") : String(localized: "Agree & Get Started")
    }

    private var recommendationPageTitle: String {
        modelManager.isAppleIntelligenceAvailable
            ? String(localized: "Ready to Start")
            : String(localized: "Best Model For This Device")
    }

    private var recommendationPageSubtitle: String {
        if modelManager.isAppleIntelligenceAvailable {
            return String(localized: "Apple Intelligence is available now, so you can start right away or switch to a local model if you prefer.")
        }
        return String(localized: "We picked a strong starting point so setup feels simple, fast, and fully matched to your device.")
    }

    private var primaryStatusText: String? {
        guard let activeModel = effectiveOnboardingModel else { return nil }
        switch activeModel.downloadState {
        case .downloading:
            return String(
                format: String(
                    localized: "%@ is downloading now. You can continue and let the download finish in the app.",
                    defaultValue: "%@ is downloading now. You can continue and let the download finish in the app."
                ),
                activeModel.name
            )
        case .validating:
            return String(
                format: String(
                    localized: "%@ is validating the local files.",
                    defaultValue: "%@ is validating the local files."
                ),
                activeModel.name
            )
        case .downloaded, .builtin:
            return String(
                format: String(
                    localized: "%@ is ready for your first message.",
                    defaultValue: "%@ is ready for your first message."
                ),
                activeModel.name
            )
        case .notDownloaded:
            return String(
                format: String(
                    localized: "%@ will be downloaded before you use it.",
                    defaultValue: "%@ will be downloaded before you use it."
                ),
                activeModel.sizeLabel
            )
        case .error(let message):
            return message
        }
    }

    private var effectiveOnboardingModel: ModelInfo? {
        if let customModelID,
           let customModel = modelManager.models.first(where: { $0.id == customModelID }) {
            return customModel
        }

        guard let recommendation = modelManager.onboardingRecommendation() else {
            return nil
        }
        return modelManager.models.first(where: { $0.id == recommendation.modelID })
    }
    
    // MARK: - Helpers
    
    private func featureRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)
                .accessibilityHidden(true)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.headline)
                    .foregroundStyle(Color.adaptive(white: 0.2))
                
                Text(LocalizedStringKey(subtitle))
                    .font(.subheadline)
                    .foregroundStyle(Color.adaptive(white: 0.6))
            }
            
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
    
    private func privacyCard(icon: String, iconColor: Color, title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(title))
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.adaptive(white: 0.2))
            }
            
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(iconColor.opacity(0.5))
                            .frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                        Text(LocalizedStringKey(item))
                            .font(.caption)
                            .foregroundStyle(Color.adaptive(white: 0.5))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.adaptive(white: 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func recommendationCard(
        model: ModelInfo,
        recommendation: ModelManager.OnboardingRecommendation
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.engine == .appleFoundation ? "sparkles.rectangle.stack.fill" : "iphone.gen3")
                    .font(.title3)
                    .foregroundStyle(model.engine == .appleFoundation ? .orange : .blue)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(recommendation.title))
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.adaptive(white: 0.15))
                    Text(model.name)
                        .font(.headline)
                        .foregroundStyle(Color.adaptive(white: 0.1))
                }

                Spacer()

                Text(model.sizeLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.engine == .appleFoundation ? .orange : .blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background((model.engine == .appleFoundation ? Color.orange : Color.blue).opacity(0.1))
                    .clipShape(Capsule())
            }

            Text(LocalizedStringKey(recommendation.summary))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.adaptive(white: 0.25))

            Text(LocalizedStringKey(recommendation.detail))
                .font(.caption)
                .foregroundStyle(Color.adaptive(white: 0.5))

            HStack(spacing: 8) {
                recommendationChip(
                    icon: model.engine == .appleFoundation ? "bolt.fill" : "lock.shield.fill",
                    title: model.engine == .appleFoundation ? String(localized: "Fastest start") : model.privacyLabel
                )
                if model.engine == .appleFoundation {
                    recommendationChip(
                        icon: "hand.raised.fill",
                        title: String(localized: "May use Apple processing")
                    )
                } else {
                    recommendationChip(
                        icon: model.currentDeviceFit.iconName,
                        title: model.currentDeviceFit.title
                    )
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.adaptive(white: 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.adaptiveBorder(opacity: 0.25), lineWidth: 1)
        )
    }

    private func recommendationChip(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
            Text(LocalizedStringKey(title))
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(Color.adaptive(white: 0.38))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.adaptiveCard)
        .clipShape(Capsule())
    }

    private func applyRecommendedModel() {
        isApplyingRecommendation = true
        guard let model = effectiveOnboardingModel else {
            _ = modelManager.applyOnboardingChoice(preferredModelID: customModelID)
            completeOnboarding()
            return
        }

        if UserDefaults.standard.bool(forKey: consentKey(for: model)) {
            finishOnboarding(with: model)
        } else {
            modelAwaitingConsent = model
        }
    }

    private func consentKey(for model: ModelInfo) -> String {
        "modelConsent.\(model.id)"
    }

    private func finishOnboarding(with model: ModelInfo) {
        _ = modelManager.applyOnboardingChoice(preferredModelID: model.id)
        completeOnboarding()
    }

    private func completeOnboarding() {
        onComplete()
        isPresented = false
    }
}

#Preview {
    OnboardingView(isPresented: .constant(true), onComplete: {})
        .environment(LLMEngine())
        .environment(ModelManager())
        .environment(MonetizationManager())
}
