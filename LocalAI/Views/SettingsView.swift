//
//  SettingsView.swift
//  Own Ai
//
//  Created by Tudor on 29.01.2026.
//

import SwiftUI
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LLMEngine.self) private var llmEngine
    @Environment(ChatHistoryManager.self) private var historyManager
    @Environment(ModelManager.self) private var modelManager
    @Environment(SpeechManager.self) private var speechManager
    @State private var documentManager = DocumentManager.shared
    @AppStorage("lowPowerMode") private var lowPowerMode = false
    @AppStorage("historyRetentionDays") private var historyRetentionDays = 0
    @AppStorage("autoRead") private var autoRead = false
    @AppStorage("voiceConversationMode") private var voiceConversationMode = false
    @State private var showClearHistoryConfirmation = false
    @State private var showClearDocumentsConfirmation = false
    
    private let retentionOptions = [0, 7, 30, 90]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    headerSection
                    
                    // AI Status
                    aiStatusSection

                    // AI Personality
                    settingsGroup {
                        NavigationLink {
                            ModelDownloadView()
                        } label: {
                            settingsRow(title: "Models", icon: "square.stack.3d.up.fill", iconColor: .blue, trailingIcon: "chevron.right")
                        }
                        
                        Divider().padding(.leading, 56)
                        
                        NavigationLink {
                            AIPersonalityView()
                        } label: {
                            settingsRow(title: "AI Personality", icon: "brain.head.profile", iconColor: .purple, trailingIcon: "chevron.right")
                        }
                    }
                    
                    // Content Safety
                    contentSafetySection

                    // Privacy Controls
                    privacyControlsSection

                    // Voice
                    voiceSection

                    // Performance
                    performanceSection
                    
                    // Legal Section
                    legalSection
                    
                    // About Section
                    aboutSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
            .background(Color(white: 0.98))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.medium)
                }
            }
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange, .pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            Text("Own Ai")
                .font(.title.bold())
                .foregroundStyle(Color(white: 0.1))
            
            Text("Local & Private Chat")
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.5))
        }
        .padding(.vertical, 20)
    }
    
    // MARK: - AI Status Section
    
    private var aiStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI Engine")
                .font(.headline)
                .foregroundStyle(Color(white: 0.2))
            
            VStack(spacing: 0) {
                if modelManager.isAppleIntelligenceDeviceSupported {
                    statusRow(
                        title: "Apple Intelligence",
                        status: modelManager.isAppleIntelligenceAvailable ? "Available" : "Unavailable",
                        isAvailable: modelManager.isAppleIntelligenceAvailable
                    )
                    
                    Divider().padding(.leading, 16)
                }
                
                statusRow(
                    title: "Engine Status",
                    status: engineStatusText,
                    isAvailable: llmEngine.state == .ready
                )
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
            
            if !modelManager.isAppleIntelligenceAvailable && modelManager.isAppleIntelligenceDeviceSupported {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.orange)
                    Text(modelManager.appleIntelligenceUnavailableHint)
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.5))
                }
                .padding(.top, 4)
            }
        }
    }
    
    private var engineStatusText: String {
        switch llmEngine.state {
        case .idle: return "Idle"
        case .loading: return "Loading..."
        case .ready: return "Ready"
        case .generating: return "Generating..."
        case .error(let message): return message
        }
    }
    
    private func statusRow(title: String, status: String, isAvailable: Bool) -> some View {
        HStack {
            Text(title)
                .font(.body)
                .foregroundStyle(Color(white: 0.3))
            
            Spacer()
            
            HStack(spacing: 6) {
                Circle()
                    .fill(isAvailable ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                
                Text(status)
                    .font(.body)
                    .foregroundStyle(isAvailable ? .green : .red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
    
    // MARK: - AI Personality Section
    

    
    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
    }

    // MARK: - Content Safety Section
    
    private var contentSafetySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Content Safety")
                .font(.headline)
                .foregroundStyle(Color(white: 0.2))
            
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                        .font(.title3)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI Disclaimer")
                            .font(.subheadline.bold())
                        Text("Own Ai uses generative AI provided by Apple Inc. (Apple Intelligence) or local models which may occasionally produce inaccurate, biased, or inappropriate content. Please verify important information.")
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.5))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        Button {
                            openMail(subject: "Reporting AI Content Issue")
                        } label: {
                            Text("Report an issue")
                                .font(.caption.bold())
                                .foregroundStyle(.blue)
                        }
                        .padding(.top, 2)
                    }
                }
                
                Divider()
                
                Button {
                    openMail(subject: "Reporting AI Content Issue")
                } label: {
                    HStack {
                        Image(systemName: "flag.fill")
                        Text("Report Inappropriate Content")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.red)
                }
            }
            .padding(16)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
        }
    }

    // MARK: - Privacy Controls Section

    private var privacyControlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Privacy Controls")
                .font(.headline)
                .foregroundStyle(Color(white: 0.2))

            settingsGroup {
                HStack(spacing: 16) {
                    Image(systemName: "internaldrive.fill")
                        .font(.body)
                        .foregroundStyle(.blue)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Storage")
                            .font(.body)
                            .foregroundStyle(Color(white: 0.1))
                        Text("Chats stay on this device.")
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.5))
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)

                Divider().padding(.leading, 56)

                Button {
                    showClearDocumentsConfirmation = true
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.body)
                            .foregroundStyle(.orange)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cleanup")
                                .font(.body)
                                .foregroundStyle(Color(white: 0.1))
                            Text(cleanupSizeText)
                                .font(.caption)
                                .foregroundStyle(Color(white: 0.5))
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }

                Divider().padding(.leading, 56)

                HStack(spacing: 16) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.body)
                        .foregroundStyle(.orange)
                        .frame(width: 24)

                    Text("Auto-Delete History")
                        .font(.body)
                        .foregroundStyle(Color(white: 0.1))

                    Spacer()

                    Picker("Auto-Delete History", selection: $historyRetentionDays) {
                        ForEach(retentionOptions, id: \.self) { days in
                            Text(retentionLabel(for: days)).tag(days)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .onChange(of: historyRetentionDays) {
                    historyManager.updateRetention(days: historyRetentionDays)
                }

                Divider().padding(.leading, 56)

                Button {
                    showClearHistoryConfirmation = true
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "trash.fill")
                            .font(.body)
                            .foregroundStyle(.red)
                            .frame(width: 24)

                        Text("Clear All History")
                            .font(.body)
                            .foregroundStyle(.red)

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
            }

            Text("Auto-delete removes conversations after their last activity date.")
                .font(.caption)
                .foregroundStyle(Color(white: 0.5))
        }
        .alert("Clear all chat history?", isPresented: $showClearHistoryConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                historyManager.clearAllConversations()
            }
        } message: {
            Text("This permanently deletes every saved conversation on this device.")
        }
        .alert("Cleanup", isPresented: $showClearDocumentsConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clean Up", role: .destructive) {
                documentManager.clearAllDocuments()
            }
        } message: {
            Text("This won’t delete your chats.")
        }
    }

    // MARK: - Performance Section

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Performance")
                .font(.headline)
                .foregroundStyle(Color(white: 0.2))

            settingsGroup {
                Toggle(isOn: $lowPowerMode) {
                    settingsRow(title: "Low Power Mode", icon: "battery.25", iconColor: .green, trailingIcon: "")
                }
                .padding(.trailing, 16)
                
                Divider().padding(.leading, 56)
                
                Button {
                    llmEngine.unloadModel()
                    speechManager.unloadKokoro()
                } label: {
                    settingsRow(title: "Release Memory", icon: "leaf.fill", iconColor: .green, trailingIcon: "")
                }
            }
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voice")
                .font(.headline)
                .foregroundStyle(Color(white: 0.2))

            if autoRead {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Voice models are separate from chat models.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(white: 0.15))

                    Text("Your chat model writes the answer. The voice model only reads that answer aloud and does not change reply quality.")
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.5))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
            }

            settingsGroup {
//                Toggle(isOn: $voiceConversationMode) {
//                    settingsRow(title: "Conversation Mode", icon: "waveform", iconColor: .blue, trailingIcon: "")
//                }
//                .padding(.trailing, 16)

//                Divider().padding(.leading, 56)

                Toggle(isOn: $autoRead) {
                    settingsRow(title: "Show Speak Reply Button", icon: "speaker.wave.2.fill", iconColor: .orange, trailingIcon: "")
                }
                .padding(.trailing, 16)

                if autoRead {
                    Divider().padding(.leading, 56)

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: "person.wave.2.fill")
                                .font(.body)
                                .foregroundStyle(.pink)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Voice Model")
                                    .font(.body)
                                    .foregroundStyle(Color(white: 0.1))
                                Text("Choose how replies should sound when you tap the Speak Reply button.")
                                    .font(.caption)
                                    .foregroundStyle(Color(white: 0.5))
                            }

                            Spacer(minLength: 0)

                            Text("System Voice")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(voiceAccentColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(voiceAccentColor.opacity(0.12))
                                .clipShape(Capsule())
                        }

                        voiceBackendButton(for: .system)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
            }

            if autoRead {
                Text(voiceFooterText)
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.5))
            }
        }
    }

    private var speechOutputBackendBinding: Binding<SpeechOutputBackend> {
        Binding(
            get: { speechManager.speechOutputBackend },
            set: { speechManager.speechOutputBackend = $0 }
        )
    }

    private var voiceAccentColor: Color {
        .orange
    }

    private var voiceFooterText: String {
        "Show Speak Reply Button adds a Speak Reply button after each finished answer and uses the built-in system voice for speed and reliability."
    }

    private func voiceBackendButton(for backend: SpeechOutputBackend) -> some View {
        Button {
            speechOutputBackendBinding.wrappedValue = backend
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(backend.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(white: 0.1))
                    Text(backend.subtitle)
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.5))
                }

                Spacer()

                Image(systemName: speechManager.speechOutputBackend == backend ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(speechManager.speechOutputBackend == backend ? voiceAccentColor : Color(white: 0.8))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(voiceButtonBackground(for: backend))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(voiceButtonBorder(for: backend), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(backend.title), \(backend.subtitle)")
        .accessibilityAddTraits(speechManager.speechOutputBackend == backend ? .isSelected : [])
    }

    private func voiceButtonBackground(for backend: SpeechOutputBackend) -> Color {
        speechManager.speechOutputBackend == backend ? voiceButtonTint(for: backend).opacity(0.08) : Color(white: 0.98)
    }

    private func voiceButtonBorder(for backend: SpeechOutputBackend) -> Color {
        speechManager.speechOutputBackend == backend ? voiceButtonTint(for: backend).opacity(0.35) : Color.black.opacity(0.05)
    }

    private func voiceButtonTint(for backend: SpeechOutputBackend) -> Color {
        .orange
    }

    // MARK: - Legal Section
    
    @State private var showDataPrivacySheet = false
    
    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Legal")
                .font(.headline)
                .foregroundStyle(Color(white: 0.2))
            
            VStack(spacing: 0) {
                Button {
                    showDataPrivacySheet = true
                } label: {
                    settingsRow(title: "Data & Privacy", icon: "hand.raised.fill", iconColor: .purple, trailingIcon: "chevron.right")
                }
                
                Divider().padding(.leading, 56)
                
                Link(destination: URL(string: "https://sudoswisshub.github.io/MetalMind-AI/privacy.html")!) {
                    settingsRow(title: "Privacy Policy", icon: "hand.raised.fill", iconColor: .blue, trailingIcon: "arrow.up.right")
                }
                
                Divider().padding(.leading, 56)
                
                Link(destination: URL(string: "https://sudoswisshub.github.io/MetalMind-AI/terms.html")!) {
                    settingsRow(title: "Terms of Service", icon: "doc.text.fill", iconColor: .gray, trailingIcon: "arrow.up.right")
                }

                Divider().padding(.leading, 56)

                Button {
                    openMail(subject: "Support Request")
                } label: {
                    settingsRow(title: "Support", icon: "questionmark.circle.fill", iconColor: .orange, trailingIcon: "chevron.right")
                }
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
        }
        .sheet(isPresented: $showDataPrivacySheet) {
            DataPrivacySheet()
        }
    }
    
    private func settingsRow(title: String, icon: String, iconColor: Color, trailingIcon: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(iconColor)
                .frame(width: 24)
            
            Text(title)
                .font(.body)
                .foregroundStyle(Color(white: 0.1))
            
            Spacer()
            
            Image(systemName: trailingIcon)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color(white: 0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private func retentionLabel(for days: Int) -> String {
        switch days {
        case 0:
            return "Never"
        case 1:
            return "1 day"
        default:
            return "\(days) days"
        }
    }

    private var cleanupSizeText: String {
        ByteCountFormatter.string(
            fromByteCount: documentManager.totalStoredDocumentBytes,
            countStyle: .file
        )
    }

    // MARK: - About Section
    
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About")
                .font(.headline)
                .foregroundStyle(Color(white: 0.2))
            
            VStack(spacing: 0) {
                aboutRow(title: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                Divider().padding(.leading, 16)
                aboutRow(title: "Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                Divider().padding(.leading, 16)
                aboutRow(title: "Privacy", value: modelManager.selectedModel?.engine == .appleFoundation ? "Hybrid (Local + PCC)" : "100% On-Device")
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)

            Text("Made in Switzerland")
                .font(.footnote)
                .foregroundStyle(Color(white: 0.5))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
        }
    }
    
    private func aboutRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.body)
                .foregroundStyle(Color(white: 0.3))
            
            Spacer()
            
            Text(value)
                .font(.body)
                .foregroundStyle(Color(white: 0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func openMail(subject: String) {
        let mailto = "mailto:alice.turcanu91@gmail.com?subject=\(subject)"
        if let url = URL(string: mailto.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") {
            UIApplication.shared.open(url)
        }
    }
}

#Preview {
    SettingsView()
        .environment(LLMEngine())
        .environment(ChatHistoryManager())
        .environment(ModelManager())
        .environment(SpeechManager())
}
