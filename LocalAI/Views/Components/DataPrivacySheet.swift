//
//  DataPrivacySheet.swift
//  LocalAI
//
//  Created by Tudor on 25.02.2026.
//

import SwiftUI

/// A sheet accessible from Settings that shows the complete data & privacy disclosure.
struct DataPrivacySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ModelManager.self) private var modelManager

    /// Mirrors ChatView.isVoiceConversationEnabled — voice conversation mode is hidden app-wide.
    private static let isVoiceConversationEnabled = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    
                    // Intro
                    Text("This screen explains what data the app processes, who it is shared with, and how your privacy is protected.")
                        .font(.subheadline)
                        .foregroundStyle(Color.adaptive(white: 0.5))
                    
                    // Data the app processes
                    sectionCard(
                        icon: "doc.text.fill",
                        iconColor: .blue,
                        title: "Data the App Processes"
                    ) {
                        bulletRow("Chat messages and prompts you type")
                        bulletRow("Text from documents you import into a chat")
                        bulletRow("Voice input (speech-to-text transcription, when enabled)")
                        bulletRow("Conversation history (stored on-device)")
                        bulletRow("App settings and preferences")
                    }
                    
                    // On-device models
                    sectionCard(
                        icon: "lock.shield.fill",
                        iconColor: .green,
                        title: "On-Device Models (e.g. Gemma 2 2B)"
                    ) {
                        Text("MLX models like Gemma 2 2B by Google run **100% on your device**. Your prompts, documents, and all personal data are **never sent** to Google LLC or any third-party AI service for inference.")
                            .font(.subheadline)
                            .foregroundStyle(Color.adaptive(white: 0.45))
                        
                        VStack(alignment: .leading, spacing: 6) {
                            privacyCheckRow("Prompts stay on-device")
                            privacyCheckRow("Documents stay on-device and remain only in the chat where you added them")
                            privacyCheckRow("Voice input stays on-device")
                            privacyCheckRow("No data sent to Google LLC")
                        }
                        .padding(.top, 4)
                    }

                    if Self.isVoiceConversationEnabled {
                        sectionCard(
                            icon: "waveform",
                            iconColor: .orange,
                            title: "Voice Conversation Mode"
                        ) {
                            Text("If you enable Conversation Mode, the app can keep listening between turns and speak replies aloud on-device.")
                                .font(.subheadline)
                                .foregroundStyle(Color.adaptive(white: 0.45))

                            Text("You can turn this off at any time in Chat or Settings.")
                                .font(.caption)
                                .foregroundStyle(Color.adaptive(white: 0.5))
                        }
                    }

                    if modelManager.isAppleIntelligenceDeviceSupported {
                        // Apple Intelligence
                        sectionCard(
                            icon: "apple.intelligence",
                            iconColor: .orange,
                            title: "Apple Intelligence"
                        ) {
                            Text("If you select Apple Intelligence, prompts and document text may be sent to **Apple Inc.** (including Apple Private Cloud Compute) to generate AI responses.")
                                .font(.subheadline)
                                .foregroundStyle(Color.adaptive(white: 0.45))
                            
                            Text("The app asks for your explicit permission before using Apple Intelligence for the first time.")
                                .font(.caption)
                                .foregroundStyle(Color.adaptive(white: 0.5))
                        }
                    }
                    
                    // Model downloads
                    sectionCard(
                        icon: "arrow.down.circle.fill",
                        iconColor: .blue,
                        title: "Model Downloads"
                    ) {
                        Text("Downloading model files uses a network request to **Hugging Face Inc.** (model hosting provider). This request may include your IP address and device request headers.")
                            .font(.subheadline)
                            .foregroundStyle(Color.adaptive(white: 0.45))
                        
                        Text("No chat messages, prompts, documents, or personal content is sent during downloads.")
                            .font(.caption)
                            .foregroundStyle(Color.adaptive(white: 0.5))
                    }
                    
                    // No tracking
                    sectionCard(
                        icon: "eye.slash.fill",
                        iconColor: .gray,
                        title: "No Tracking or Analytics"
                    ) {
                        Text("The app does not include third-party advertising, analytics, or tracking SDKs.")
                            .font(.subheadline)
                            .foregroundStyle(Color.adaptive(white: 0.45))
                    }
                    
                    // Links
                    VStack(alignment: .leading, spacing: 8) {
                        Link("Privacy Policy", destination: URL(string: "https://sudoswisshub.github.io/MetalMind-AI/privacy.html") ?? URL(string: "about:blank")!)
                        Link("Terms of Service", destination: URL(string: "https://sudoswisshub.github.io/MetalMind-AI/terms.html") ?? URL(string: "about:blank")!)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.blue)
                    .padding(.top, 8)
                }
                .padding(20)
            }
            .background(Color.adaptive(white: 0.98))
            .navigationTitle("Data & Privacy")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.medium)
                }
            }
        }
    }
    
    // MARK: - Components
    
    private func sectionCard<Content: View>(icon: String, iconColor: Color, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.adaptive(white: 0.2))
            }
            
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.adaptiveCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
    }
    
    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.blue.opacity(0.5))
                .frame(width: 5, height: 5)
                .padding(.top, 6)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.adaptive(white: 0.45))
        }
    }
    
    private func privacyCheckRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .frame(width: 18)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.adaptive(white: 0.4))
        }
    }
}

#Preview {
    DataPrivacySheet()
        .environment(ModelManager())
}
