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
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header description
                headerView
                
                // Model cards
                ForEach(modelManager.models.filter { $0.engine != .appleFoundation || modelManager.isAppleIntelligenceDeviceSupported }) { model in
                    ModelCard(model: model)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        ))
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
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue.opacity(0.8))
                
                Text(modelManager.isAppleIntelligenceDeviceSupported ?
                     "Choose your AI model. Apple Intelligence is built-in, while other models can be downloaded." :
                     "Choose your AI model. Models can be downloaded to run entirely on your device.")
                    .font(.subheadline)
                    .foregroundStyle(Color(white: 0.4))
                
                Spacer()
            }
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.03), radius: 6, y: 3)
    }
}

// MARK: - Model Card

struct ModelCard: View {
    let model: ModelInfo
    @Environment(ModelManager.self) private var modelManager
    @Environment(LLMEngine.self) private var llmEngine
    @Environment(\.openURL) private var openURL
    @State private var isHovered = false
    @State private var testResult: ModelQuickTestResult?
    @State private var showConsentSheet = false
    @State private var pendingAction: (() -> Void)?
    
    private var isSelected: Bool {
        modelManager.selectedModel?.id == model.id
    }
    
    /// Whether this Apple model is unsupported on the current device
    private var isAppleUnavailable: Bool {
        model.isAppleFoundation && !modelManager.isAppleIntelligenceAvailable
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
                        Text(model.description)
                            .font(.subheadline)
                            .foregroundStyle(Color(white: 0.5))
                            .lineLimit(3)
                    }
                }
                
                Spacer(minLength: 0)
            }
            
            if !isAppleUnavailable {
                // Info tags
                HStack(spacing: 10) {
                    if model.isAppleFoundation {
                        InfoTag(icon: "apple.logo", text: "Built-in", isHighlighted: true)
                        InfoTag(icon: "lock.shield", text: "Private")
                    } else {
                        InfoTag(icon: "externaldrive", text: String(format: "%.1f GB", model.sizeGB))
                        InfoTag(icon: "cpu", text: "On-Device")
                    }
                    
                    if model.downloadState.isDownloaded && !model.isAppleFoundation {
                        InfoTag(icon: "checkmark.circle.fill", text: "Ready", isHighlighted: true)
                    }
                    
                    Spacer()
                }

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
            if testResult == nil {
                testResult = modelManager.quickTestResult(for: model.id)
            }
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
                    Text(modelManager.isAppleIntelligenceAvailable ? "No download required." : modelManager.appleIntelligenceUnavailableHint)
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.5))
                }
            } else {
                let freeGB = DiskSpace.availableGB()
                let hasSpace = freeGB >= model.sizeGB * 1.05
                HStack(spacing: 6) {
                    Image(systemName: hasSpace ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(hasSpace ? .green : .orange)
                    Text(String(format: "Free space: %.1f GB", freeGB))
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
                        Text(result.success ? "Passed" : "Failed")
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.5))
                    }

                    Text("Last test: \(result.durationMs)ms • \(result.responseSnippet)")
                        .font(.caption2)
                        .foregroundStyle(Color(white: 0.5))
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch model.downloadState {
        case .builtin:
            BuiltInButton(isSelected: isSelected) {
                requireConsentAndPerform {
                    modelManager.selectModel(model.id)
                }
            }
            
        case .notDownloaded:
            DownloadButton(action: {
                requireConsentAndPerform {
                    modelManager.downloadModel(model.id)
                    modelManager.selectModel(model.id)
                }
            })
            
        case .downloading(let progress):
            DownloadingButton(progress: progress, action: {
                modelManager.cancelDownload(model.id)
            })
            
        case .downloaded:
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
            
        case .error(let message):
            let action = modelManager.downloadErrorAction(for: model.id)
            ErrorButton(message: message, actionTitle: action.title, actionIcon: action.iconName, action: {
                handleDownloadErrorAction(action)
            })
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
                        Text(model.isAppleFoundation ? "Allow Data Sharing & Continue" : "I Understand — No Data Shared")
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
            Text("Provider: \(model.providerName)")
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
                dataRow(icon: "text.bubble", text: "Your chat messages and prompts")
                dataRow(icon: "doc.text", text: "Text from attached documents")
                dataRow(icon: "text.quote", text: "Conversation context and history")
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
            
            Text("This model runs **100% on your device**. The following data is processed locally and is **never sent** to Google LLC, Gemma, or any third-party AI service:")
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.5))
            
            VStack(alignment: .leading, spacing: 8) {
                privacyRow(text: "Your chat messages and prompts")
                privacyRow(text: "Text from attached documents")
                privacyRow(text: "Conversation context and history")
                privacyRow(text: "Voice input and transcriptions")
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
                dataRow(icon: "network", text: "Your IP address")
                dataRow(icon: "gear", text: "Device request headers (e.g. OS version)")
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
        }
        .foregroundStyle(isHighlighted ? .green : Color(white: 0.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isHighlighted ? Color.green.opacity(0.1) : Color(white: 0.95))
        .clipShape(Capsule())
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
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.body.bold())
                Text("Download")
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
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

struct DownloadingButton: View {
    let progress: Double
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Animated progress ring
                ZStack {
                    Circle()
                        .stroke(Color.blue.opacity(0.2), lineWidth: 3)
                    
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: progress)
                }
                .frame(width: 22, height: 22)
                
                Text("Downloading \(Int(progress * 100))%")
                    .fontWeight(.semibold)
                
                Spacer()
                
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color(white: 0.6))
            }
            .foregroundStyle(.blue)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(ActionButtonStyle())
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
}
