//
//  SettingsView.swift
//  Own Ai
//
//  Created by Tudor on 29.01.2026.
//

import SwiftUI
import FoundationModels

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LLMEngine.self) private var llmEngine
    @AppStorage("autoRead") private var autoRead = false
    
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
                            AIPersonalityView()
                        } label: {
                            settingsRow(title: "AI Personality", icon: "brain.head.profile", iconColor: .purple, trailingIcon: "chevron.right")
                        }
                        
                        Divider().padding(.leading, 56)
                        
                        Toggle(isOn: $autoRead) {
                            settingsRow(title: "Auto-Read Responses", icon: "speaker.wave.2.fill", iconColor: .green, trailingIcon: "")
                        }
                        .padding(.trailing, 16)
                    }
                    
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
                statusRow(
                    title: "Apple Intelligence",
                    status: llmEngine.isAvailable ? "Available" : "Unavailable",
                    isAvailable: llmEngine.isAvailable
                )
                
                Divider().padding(.leading, 16)
                
                statusRow(
                    title: "Engine Status",
                    status: engineStatusText,
                    isAvailable: llmEngine.state == .ready
                )
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
            
            if !llmEngine.isAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Enable Apple Intelligence in Settings > Apple Intelligence")
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
                        Text("Own Ai uses generative AI which may occasionally produce inaccurate, biased, or inappropriate content. Please verify important information.")
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.5))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - Legal Section
    
    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Legal")
                .font(.headline)
                .foregroundStyle(Color(white: 0.2))
            
            VStack(spacing: 0) {
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
                aboutRow(title: "Privacy", value: "100% On-Device")
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
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
}
