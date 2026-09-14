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


    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    
                    // Intro
                    Text("This screen explains what data the app processes, who it is shared with, and how your privacy is protected.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    // Data the app processes
                    sectionCard(
                        icon: "doc.text.fill",
                        iconColor: .brandAccent,
                        title: "Data the App Processes"
                    ) {
                        bulletRow("Chat messages and prompts you type")
                        bulletRow("Text from documents you import into a chat")
                        bulletRow("Voice input (speech-to-text transcription, when enabled)")
                        bulletRow("Conversation history (stored on-device)")
                        bulletRow("Memory (optional, opt-in): facts you choose to remember across chats, stored on-device and editable in Settings > Memory")
                        bulletRow("App settings and preferences")
                    }

                    // On-device models
                    sectionCard(
                        icon: "lock.shield.fill",
                        iconColor: .green,
                        title: "On-Device Models"
                    ) {
                        Text("The local model you select (for example Qwen or Gemma) runs **100% on your device**. Your prompts, documents, and all personal data are **never sent** to the model's publisher or any third-party AI service for inference.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            privacyCheckRow("Prompts stay on-device")
                            privacyCheckRow("Documents stay on-device and remain only in the chat where you added them")
                            privacyCheckRow("Voice input stays on-device")
                            privacyCheckRow("No data sent to the model's publisher or any third party")
                        }
                        .padding(.top, 4)
                    }

                    sectionCard(
                        icon: "waveform",
                        iconColor: .brandAccent,
                        title: "Voice Conversation Mode"
                    ) {
                        Text("If you enable Conversation Mode, the app can keep listening between turns and speak replies aloud on-device.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text("You can turn this off at any time in Chat or Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if modelManager.isAppleIntelligenceDeviceSupported {
                        // Apple Intelligence
                        sectionCard(
                            icon: "apple.intelligence",
                            iconColor: .brandAccent,
                            title: "Apple Intelligence"
                        ) {
                            Text("If you select Apple Intelligence, prompts and document text may be sent to **Apple Inc.** (including Apple Private Cloud Compute) to generate AI responses.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Text("The app asks for your explicit permission before using Apple Intelligence for the first time.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    // Model downloads
                    sectionCard(
                        icon: "arrow.down.circle.fill",
                        iconColor: .brandAccent,
                        title: "Model Downloads"
                    ) {
                        Text("Downloading model files — including optional voice models for reading replies aloud — uses a network request to **Hugging Face Inc.** (model hosting provider). This request may include your IP address and device request headers.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text("No chat messages, prompts, documents, or personal content is sent during downloads.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // No tracking
                    sectionCard(
                        icon: "eye.slash.fill",
                        iconColor: .gray,
                        title: "No Tracking or Analytics"
                    ) {
                        Text("The app does not include third-party advertising, analytics, or tracking SDKs.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    // Links
                    VStack(alignment: .leading, spacing: 8) {
                        Link("Privacy Policy", destination: URL(string: "https://sudoswisshub.github.io/MetalMind-AI/privacy.html") ?? URL(string: "about:blank")!)
                        Link("Terms of Service", destination: URL(string: "https://sudoswisshub.github.io/MetalMind-AI/terms.html") ?? URL(string: "about:blank")!)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.brandAccent)
                    .padding(.top, 8)
                }
                .padding(20)
                .readableContentWidth()
            }
            .background(Color.adaptiveBackground)
            .navigationTitle("Data & Privacy")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton { dismiss() }
                        .fontWeight(.medium)
                }
            }
        }
    }
    
    // MARK: - Components
    
    // `LocalizedStringKey` (not `String`) so `Text` performs the table lookup
    // and the de/es/fr translations are actually shown.
    private func sectionCard<Content: View>(icon: String, iconColor: Color, title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.adaptive(white: 0.2))
                    .accessibilityAddTraits(.isHeader)
            }
            
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.adaptiveCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.brandHairline, lineWidth: AppDesign.hairlineWidth))
    }
    
    private func bulletRow(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.brandAccent.opacity(0.5))
                .frame(width: 5, height: 5)
                .padding(.top, 6)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func privacyCheckRow(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .frame(width: 18)
                .padding(.top, 3)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    DataPrivacySheet()
        .environment(ModelManager())
}
