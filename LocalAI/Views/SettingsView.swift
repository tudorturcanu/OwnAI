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
    @State private var documentManager = DocumentManager.shared
    @AppStorage("lowPowerMode") private var lowPowerMode = false
    @AppStorage("historyRetentionDays") private var historyRetentionDays = 0
    @AppStorage("autoRead") private var autoRead = false
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
                    
                    // Privacy Controls
                    privacyControlsSection

                    // Voice
                    voiceSection

                    // Performance
                    performanceSection

                    // Content Safety
                    contentSafetySection
                    
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
            Text("Privacy")
                .font(.headline)
                .foregroundStyle(Color(white: 0.2))

            settingsGroup {
                HStack(spacing: 16) {
                    Image(systemName: "internaldrive.fill")
                        .font(.body)
                        .foregroundStyle(.blue)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your Data Stays on This Device")
                            .font(.body)
                            .foregroundStyle(Color(white: 0.1))
                        Text("Chats and imported files stay on this device.")
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
                            Text("Clear Memory")
                                .font(.body)
                                .foregroundStyle(Color(white: 0.1))
                            Text("Free up \(cleanupSizeText) without deleting chats.")
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

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-Delete Chats")
                            .font(.body)
                            .foregroundStyle(Color(white: 0.1))
                        Text("Delete saved chats after")
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.5))
                    }

                    Spacer()

                    Picker("Auto-Delete Chats", selection: $historyRetentionDays) {
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

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Delete All Chats")
                                .font(.body)
                                .foregroundStyle(.red)
                            Text("Permanently removes every saved conversation from this device.")
                                .font(.caption)
                                .foregroundStyle(Color(white: 0.5))
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
            }
        }
        .alert("Delete all chats?", isPresented: $showClearHistoryConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                historyManager.clearAllConversations()
            }
        } message: {
            Text("This permanently removes every saved conversation from this device.")
        }
        .alert("Clear memory?", isPresented: $showClearDocumentsConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                documentManager.clearAllDocuments()
            }
        } message: {
            Text("This clears imported files to free up storage. Your chats will stay on this device.")
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
            }
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voice")
                .font(.headline)
                .foregroundStyle(Color(white: 0.2))

            settingsGroup {
                Toggle(isOn: $autoRead) {
                    settingsRow(title: "Speak Button", icon: "speaker.wave.2.fill", iconColor: .orange, trailingIcon: "")
                }
                .padding(.trailing, 16)
            }
        }
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
