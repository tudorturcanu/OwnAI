//
//  SettingsView.swift
//  Own Ai
//
//  Created by Tudor on 29.01.2026.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ChatHistoryManager.self) private var historyManager
    @AppStorage("lowPowerMode") private var lowPowerMode = false
    @AppStorage("historyRetentionDays") private var historyRetentionDays = 0
    @AppStorage("autoRead") private var autoRead = false
    @State private var showClearHistoryConfirmation = false
    @State private var showDataPrivacySheet = false

    private let retentionOptions = [0, 7, 30, 90]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Models & Personality
                    settingsGroup(header: "AI") {
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

                    // Voice & Performance
                    settingsGroup(header: "Preferences") {
                        Toggle(isOn: $autoRead) {
                            settingsRow(title: "Speak Button", icon: "speaker.wave.2.fill", iconColor: .orange, trailingIcon: "")
                        }
                        .padding(.trailing, 16)

                        Divider().padding(.leading, 56)

                        Toggle(isOn: $lowPowerMode) {
                            settingsRow(title: "Low Power Mode", icon: "battery.25", iconColor: .green, trailingIcon: "")
                        }
                        .padding(.trailing, 16)
                    }

                    // Footer: Legal + About
                    footerSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
            .background(Color(white: 0.98))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.medium)
                }
            }
        }
    }

    // MARK: - Privacy Controls Section

    private var privacyControlsSection: some View {
        settingsGroup(header: "Privacy") {
            // Auto-Delete picker
            HStack(spacing: 16) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.body).foregroundStyle(.orange).frame(width: 24)
                Text("Auto-Delete Chats")
                    .font(.body).foregroundStyle(Color(white: 0.1))
                Spacer()
                Picker("Auto-Delete Chats", selection: $historyRetentionDays) {
                    ForEach(retentionOptions, id: \.self) { days in
                        Text(retentionLabel(for: days)).tag(days)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .padding(.horizontal, 16).padding(.vertical, 16)
            .onChange(of: historyRetentionDays) {
                historyManager.updateRetention(days: historyRetentionDays)
            }

            Divider().padding(.leading, 56)

            // Delete All Chats
            Button {
                showClearHistoryConfirmation = true
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: "trash.fill")
                        .font(.body).foregroundStyle(.red).frame(width: 24)
                    Text("Delete All Chats")
                        .font(.body).foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 16)
            }
        }
        .alert("Delete all chats?", isPresented: $showClearHistoryConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { historyManager.clearAllConversations() }
        } message: {
            Text("This permanently removes every saved conversation from this device.")
        }
    }

    // MARK: - Footer (Legal + About)

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("More")
                .font(.headline)
                .foregroundStyle(Color(white: 0.2))

            VStack(spacing: 0) {
                // Data & Privacy
                Button { showDataPrivacySheet = true } label: {
                    settingsRow(title: "Data & Privacy", icon: "hand.raised.fill", iconColor: .purple, trailingIcon: "chevron.right")
                }

                Divider().padding(.leading, 56)

                Link(destination: URL(string: "https://sudoswisshub.github.io/MetalMind-AI/privacy.html")!) {
                    settingsRow(title: "Privacy Policy", icon: "lock.doc.fill", iconColor: .blue, trailingIcon: "arrow.up.right")
                }

                Divider().padding(.leading, 56)

                Link(destination: URL(string: "https://sudoswisshub.github.io/MetalMind-AI/terms.html")!) {
                    settingsRow(title: "Terms of Service", icon: "doc.text.fill", iconColor: .gray, trailingIcon: "arrow.up.right")
                }

                Divider().padding(.leading, 56)

                Button { openMail(subject: "Support Request") } label: {
                    settingsRow(title: "Support", icon: "questionmark.circle.fill", iconColor: .orange, trailingIcon: "chevron.right")
                }

                Divider().padding(.leading, 56)

                // Version info inline
                HStack {
                    Text("Version")
                        .font(.body).foregroundStyle(Color(white: 0.3))
                    Spacer()
                    Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                        .font(.body).foregroundStyle(Color(white: 0.6))
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
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
        .sheet(isPresented: $showDataPrivacySheet) {
            DataPrivacySheet()
        }
    }

    // MARK: - Helpers

    private func settingsGroup<Content: View>(header: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let header {
                Text(header)
                    .font(.headline)
                    .foregroundStyle(Color(white: 0.2))
            }
            VStack(spacing: 0) {
                content()
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
        }
    }

    private func settingsRow(title: String, icon: String, iconColor: Color, trailingIcon: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.body).foregroundStyle(iconColor).frame(width: 24)
            Text(title)
                .font(.body).foregroundStyle(Color(white: 0.1))
            Spacer()
            if !trailingIcon.isEmpty {
                Image(systemName: trailingIcon)
                    .font(.caption.weight(.bold)).foregroundStyle(Color(white: 0.7))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 16)
    }

    private func retentionLabel(for days: Int) -> String {
        switch days {
        case 0: return "Never"
        case 1: return "1 day"
        default: return "\(days) days"
        }
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
        .environment(ChatHistoryManager())
        .environment(SpeechManager())
}
