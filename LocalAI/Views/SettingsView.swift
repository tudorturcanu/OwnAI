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
    @Environment(ModelManager.self) private var modelManager
    @Environment(MonetizationManager.self) private var monetizationManager
    @AppStorage("lowPowerMode") private var lowPowerMode = false
    @AppStorage("historyRetentionDays") private var historyRetentionDays = 0
    @AppStorage("autoRead") private var autoRead = false
    @State private var showClearHistoryConfirmation = false
    @State private var showDataPrivacySheet = false
    @State private var isUpgradeSheetPresented = false
    #if DEBUG
    @State private var debugProModeEnabled = false
    #endif

    private let retentionOptions = [0, 7, 30, 90]

    private var selectedModelName: String {
        modelManager.selectedModel?.name ?? String(localized: "No model selected")
    }

    private var downloadedModelCount: Int {
        modelManager.models.filter { $0.downloadState.isDownloaded && $0.engine == .mlx }.count
    }

    private var downloadedStorageText: String {
        let totalGB = modelManager.models
            .filter { $0.downloadState.isDownloaded && $0.engine == .mlx }
            .reduce(0.0) { $0 + $1.sizeGB }
        return totalGB > 0
            ? String(format: String(localized: "%.1f GB on device", defaultValue: "%.1f GB on device"), totalGB)
            : String(localized: "No local downloads")
    }

    private var primaryStatusTitle: String {
        if modelManager.selectedModel == nil {
            return String(localized: "Choose a model")
        }
        if !monetizationManager.hasPro && monetizationManager.freeMessagesRemainingToday <= 3 {
            return String(localized: "Free messages running low")
        }
        if historyRetentionDays != 0 {
            return String(localized: "Auto-delete is on")
        }
        if lowPowerMode {
            return String(localized: "Low Power Mode is on")
        }
        return String(localized: "Everything looks ready")
    }

    private var primaryStatusDetail: String {
        if modelManager.selectedModel == nil {
            return String(localized: "Pick a model to start chatting locally.")
        }
        if !monetizationManager.hasPro && monetizationManager.freeMessagesRemainingToday <= 3 {
            return String(
                format: String(
                    localized: "%lld free messages left today.",
                    defaultValue: "%lld free messages left today."
                ),
                Int64(monetizationManager.freeMessagesRemainingToday)
            )
        }
        if historyRetentionDays != 0 {
            return String(
                format: String(
                    localized: "Chats will be removed after %@.",
                    defaultValue: "Chats will be removed after %@."
                ),
                retentionLabel(for: historyRetentionDays).lowercased()
            )
        }
        if lowPowerMode {
            return String(localized: "Performance is tuned for lower battery impact.")
        }
        return String(localized: "Your current setup is ready for fast on-device use.")
    }

    private var primaryStatusTint: Color {
        if modelManager.selectedModel == nil {
            return .orange
        }
        if !monetizationManager.hasPro && monetizationManager.freeMessagesRemainingToday <= 3 {
            return .orange
        }
        if historyRetentionDays != 0 || lowPowerMode {
            return .blue
        }
        return .green
    }

    private var primaryStatusIcon: String {
        if modelManager.selectedModel == nil {
            return "exclamationmark.circle.fill"
        }
        if !monetizationManager.hasPro && monetizationManager.freeMessagesRemainingToday <= 3 {
            return "exclamationmark.circle.fill"
        }
        if historyRetentionDays != 0 || lowPowerMode {
            return "slider.horizontal.3"
        }
        return "checkmark.circle.fill"
    }

    private var privacySummary: String {
        historyRetentionDays == 0
            ? String(localized: "Chats stay on device until you delete them.")
            : String(
                format: String(
                    localized: "Chats are removed automatically after %@.",
                    defaultValue: "Chats are removed automatically after %@."
                ),
                retentionLabel(for: historyRetentionDays).lowercased()
            )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    overviewSection
                    aiSection
                    preferencesSection
                    privacyControlsSection
                    #if DEBUG
                    debugSection
                    #endif
                    moreSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
            .background(settingsBackground.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $isUpgradeSheetPresented) {
            UpgradeView(feature: .allModels)
        }
        #if DEBUG
        .onAppear {
            debugProModeEnabled = monetizationManager.debugProOverrideEnabled
        }
        .onChange(of: debugProModeEnabled) {
            monetizationManager.setDebugProOverrideEnabled(debugProModeEnabled)
        }
        #endif
    }

    private var settingsBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.96, blue: 0.93),
                Color(red: 0.95, green: 0.96, blue: 0.99),
                Color(red: 0.97, green: 0.97, blue: 0.97)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Own AI")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)

                        Text("Control your model, privacy, and performance in one place.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 16)

                    Button {
                        presentUpgradeSheet()
                    } label: {
                        Text(monetizationManager.hasPro ? "Pro" : "Upgrade")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(monetizationManager.hasPro ? Color(red: 0.12, green: 0.38, blue: 0.24) : Color(red: 0.33, green: 0.18, blue: 0.03))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.92), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                HStack(alignment: .top, spacing: 12) {
                    rowIcon(systemImage: primaryStatusIcon, tint: primaryStatusTint)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(primaryStatusTitle)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)

                        Text(primaryStatusDetail)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.80))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.18, green: 0.23, blue: 0.36),
                        Color(red: 0.48, green: 0.31, blue: 0.22)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.10), radius: 22, y: 12)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    summaryTile(
                        title: String(localized: "Current model"),
                        detail: selectedModelName,
                        systemImage: "cpu",
                        tint: .blue
                    )

                    summaryTile(
                        title: downloadedModelCount == 1
                            ? String(localized: "1 local model")
                            : String(format: String(localized: "%lld local models", defaultValue: "%lld local models"), Int64(downloadedModelCount)),
                        detail: downloadedStorageText,
                        systemImage: "internaldrive.fill",
                        tint: .teal
                    )

                    summaryTile(
                        title: monetizationManager.hasPro ? String(localized: "Pro is active") : String(localized: "Free plan"),
                        detail: monetizationManager.hasPro
                            ? String(localized: "Premium tools are available.")
                            : String(format: String(localized: "%lld free messages left today.", defaultValue: "%lld free messages left today."), Int64(monetizationManager.freeMessagesRemainingToday)),
                        systemImage: monetizationManager.hasPro ? "checkmark.seal.fill" : "crown.fill",
                        tint: monetizationManager.hasPro ? .green : .orange
                    )
                }

                VStack(spacing: 12) {
                    summaryTile(
                        title: String(localized: "Current model"),
                        detail: selectedModelName,
                        systemImage: "cpu",
                        tint: .blue
                    )

                    summaryTile(
                        title: downloadedModelCount == 1
                            ? String(localized: "1 local model")
                            : String(format: String(localized: "%lld local models", defaultValue: "%lld local models"), Int64(downloadedModelCount)),
                        detail: downloadedStorageText,
                        systemImage: "internaldrive.fill",
                        tint: .teal
                    )

                    summaryTile(
                        title: monetizationManager.hasPro ? String(localized: "Pro is active") : String(localized: "Free plan"),
                        detail: monetizationManager.hasPro
                            ? String(localized: "Premium tools are available.")
                            : String(format: String(localized: "%lld free messages left today.", defaultValue: "%lld free messages left today."), Int64(monetizationManager.freeMessagesRemainingToday)),
                        systemImage: monetizationManager.hasPro ? "checkmark.seal.fill" : "crown.fill",
                        tint: monetizationManager.hasPro ? .green : .orange
                    )
                }
            }
        }
    }

    private var aiSection: some View {
        settingsSection(String(localized: "AI")) {
            NavigationLink {
                ModelDownloadView()
            } label: {
                settingsLinkRow(
                    title: String(localized: "Models"),
                    subtitle: selectedModelName,
                    icon: "square.stack.3d.up.fill",
                    tint: .blue
                )
            }

            sectionDivider

            NavigationLink {
                AIPersonalityView()
            } label: {
                settingsLinkRow(
                    title: String(localized: "AI Personality"),
                    subtitle: String(localized: "Tune tone, style, and how the assistant responds."),
                    icon: "brain.head.profile",
                    tint: .purple
                )
            }
        }
    }

    private var preferencesSection: some View {
        settingsSection(String(localized: "Preferences")) {
            settingsToggleRow(
                title: String(localized: "Read replies aloud"),
                subtitle: String(localized: "Shows a speak control on responses for hands-free playback."),
                icon: "speaker.wave.2.fill",
                tint: .orange,
                isOn: $autoRead
            )

            sectionDivider

            settingsToggleRow(
                title: String(localized: "Low Power Mode"),
                subtitle: String(localized: "Favor lighter local behavior to reduce battery and thermal load."),
                icon: "battery.25",
                tint: .green,
                isOn: $lowPowerMode
            )
        }
    }

    private var privacyControlsSection: some View {
        settingsSection("Privacy") {
            HStack(spacing: 14) {
                rowIcon(systemImage: "clock.arrow.circlepath", tint: .orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto-Delete Chats")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary.opacity(0.92))

                    Text(privacySummary)
                        .font(.footnote)
                        .foregroundStyle(Color.primary.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Picker("Auto-Delete Chats", selection: $historyRetentionDays) {
                    ForEach(retentionOptions, id: \.self) { days in
                        Text(retentionLabel(for: days)).tag(days)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(Color.primary.opacity(0.75))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .onChange(of: historyRetentionDays) {
                historyManager.updateRetention(days: historyRetentionDays)
            }

            sectionDivider

            Button {
                showClearHistoryConfirmation = true
            } label: {
                HStack(spacing: 14) {
                    rowIcon(systemImage: "trash.fill", tint: .red)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Delete All Chats")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.red)

                        Text("Remove every saved conversation from this device.")
                            .font(.footnote)
                            .foregroundStyle(Color.red.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .buttonStyle(.plain)
        }
        .alert("Delete all chats?", isPresented: $showClearHistoryConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { historyManager.clearAllConversations() }
        } message: {
            Text("This permanently removes every saved conversation from this device.")
        }
    }

    private var moreSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(String(localized: "More"))

            settingsCard {
                Button {
                    showDataPrivacySheet = true
                } label: {
                    settingsLinkRow(
                        title: String(localized: "Data & Privacy"),
                        subtitle: String(localized: "See what stays on-device and when Apple services may be involved."),
                        icon: "hand.raised.fill",
                        tint: .indigo
                    )
                }

                sectionDivider

                Link(destination: URL(string: "https://sudoswisshub.github.io/MetalMind-AI/privacy.html")!) {
                    settingsLinkRow(
                        title: String(localized: "Privacy Policy"),
                        subtitle: String(localized: "Open the latest policy in your browser."),
                        icon: "lock.doc.fill",
                        tint: .blue,
                        trailingIcon: "arrow.up.right"
                    )
                }

                sectionDivider

                Link(destination: URL(string: "https://sudoswisshub.github.io/MetalMind-AI/terms.html")!) {
                    settingsLinkRow(
                        title: String(localized: "Terms of Service"),
                        subtitle: String(localized: "Review the legal terms for using the app."),
                        icon: "doc.text.fill",
                        tint: .gray,
                        trailingIcon: "arrow.up.right"
                    )
                }

                sectionDivider

                Button {
                    openMail(subject: String(localized: "Support Request"))
                } label: {
                    settingsLinkRow(
                        title: String(localized: "Support"),
                        subtitle: String(localized: "Get help with billing, downloads, models, or account issues."),
                        icon: "questionmark.circle.fill",
                        tint: .orange
                    )
                }

                sectionDivider

                HStack(spacing: 14) {
                    rowIcon(systemImage: "app.badge", tint: .teal)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Version")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.primary.opacity(0.92))

                        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                        let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

                        Text("\(shortVersion) (\(buildVersion))")
                            .font(.footnote)
                            .foregroundStyle(Color.primary.opacity(0.58))
                    }

                    Spacer()

                    Text("Made in Switzerland")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
        }
        .sheet(isPresented: $showDataPrivacySheet) {
            DataPrivacySheet()
                .environment(modelManager)
                .environmentObject(modelManager)
        }
    }

    #if DEBUG
    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Debug")

            settingsCard {
                settingsToggleRow(
                    title: "Force Pro",
                    subtitle: "Debug-only entitlement override for testing premium flows on this device.",
                    icon: "hammer.fill",
                    tint: .pink,
                    isOn: $debugProModeEnabled
                )
            }
        }
    }
    #endif

    private var sectionDivider: some View {
        Divider()
            .padding(.leading, 70)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(Color.primary.opacity(0.48))
            .padding(.horizontal, 6)
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(title)
            settingsCard(content: content)
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.72), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 18, y: 10)
    }

    private func settingsLinkRow(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        trailingIcon: String = "chevron.right"
    ) -> some View {
        HStack(spacing: 14) {
            rowIcon(systemImage: icon, tint: tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.primary.opacity(0.92))

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.primary.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Image(systemName: trailingIcon)
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.primary.opacity(0.35))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }

    private func settingsToggleRow(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 14) {
            rowIcon(systemImage: icon, tint: tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.primary.opacity(0.92))

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.primary.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle(title, isOn: isOn)
                .labelsHidden()
                .tint(tint)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private func rowIcon(systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 38, height: 38)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func summaryTile(title: String, detail: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon(systemImage: systemImage, tint: tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary.opacity(0.9))

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.primary.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            Color.white.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.82), lineWidth: 1)
        )
    }

    private func retentionLabel(for days: Int) -> String {
        switch days {
        case 0:
            return String(localized: "Never")
        case 1:
            return String(localized: "1 day")
        default:
            return String(format: String(localized: "%lld days", defaultValue: "%lld days"), Int64(days))
        }
    }

    private func openMail(subject: String) {
        let mailto = "mailto:alice.turcanu91@gmail.com?subject=\(subject)"
        if let url = URL(string: mailto.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") {
            UIApplication.shared.open(url)
        }
    }

    private func presentUpgradeSheet() {
        showDataPrivacySheet = false
        isUpgradeSheetPresented = true
    }
}

#Preview {
    SettingsView()
        .environment(ChatHistoryManager())
        .environment(ModelManager())
        .environment(MonetizationManager())
        .environment(SpeechManager())
}
