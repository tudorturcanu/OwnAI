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
    @Environment(MonetizationManager.self) private var monetizationManager
    @AppStorage(PDFOCRMode.storageKey) private var pdfOCRModeRaw = PDFOCRMode.preferNativeText.rawValue
    @AppStorage("lowPowerMode") private var lowPowerMode = false
    @AppStorage("historyRetentionDays") private var historyRetentionDays = 0
    @AppStorage("autoRead") private var autoRead = false
    @AppStorage("smartReplyStylesEnabled") private var smartReplyStylesEnabled = false
    @AppStorage("inChatSearchEnabled") private var inChatSearchEnabled = false
    @AppStorage("systemPrompt") private var systemPrompt = AIResponseDefaults.defaultSystemPrompt
    @AppStorage("downloads.allowCellular") private var allowCellularDownloads = false
    @State private var showClearHistoryConfirmation = false
    @State private var showDataPrivacySheet = false
    @State private var isUpgradeSheetPresented = false

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

    private var freePlanLimitMessage: String? {
        guard monetizationManager.hasReachedFreeDailyMessageLimit else { return nil }
        return String(localized: "Free install limit reached.")
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    headerSection
                    aiSection
                    preferencesSection
                    #if DEBUG
                    debugSection
                    #endif
                    documentSection

                    privacySection
                    aboutSection



                    footerBranding
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $isUpgradeSheetPresented) {
            UpgradeView(feature: .allModels)
                .environment(monetizationManager)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.22, green: 0.27, blue: 0.42),
                                Color(red: 0.36, green: 0.28, blue: 0.44)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: "brain.head.profile.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.92))
                            .accessibilityHidden(true)
                    }
                    .shadow(color: Color(red: 0.22, green: 0.27, blue: 0.42).opacity(0.18), radius: 10, y: 5)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Own AI")
                        .font(.title3)
                        .bold()
                        .foregroundStyle(.primary)

                    let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                    let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
                    Text("Version \(shortVersion) (\(buildVersion))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Group {
                    if monetizationManager.hasPro {
                        Text("Pro")
                    } else {
                        Button(action: presentUpgradeSheet) {
                            Text("Upgrade")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.subheadline)
                .bold()
                .foregroundStyle(monetizationManager.hasPro ? .green : .orange)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    (monetizationManager.hasPro ? Color.green : Color.orange).opacity(0.12),
                    in: Capsule()
                )
            }

            if let freePlanLimitMessage {
                Label(LocalizedStringKey(freePlanLimitMessage), systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if !monetizationManager.hasPro {
                Text("\(monetizationManager.freeMessagesRemainingToday) of \(MonetizationManager.freeInstallMessageLimit) free messages left")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    // MARK: - AI Section

    private var aiSection: some View {
        settingsSection("AI") {
            NavigationLink {
                ModelDownloadView()
                    .environment(llmEngine)
                    .environment(modelManager)
                    .environment(monetizationManager)
                    .environmentObject(modelManager)
            } label: {
                settingsRow(
                    icon: "square.stack.3d.up.fill",
                    tint: .blue,
                    title: "Models",
                    subtitle: selectedModelName
                )
            }
            .buttonStyle(.plain)

            sectionDivider

            NavigationLink {
                AIPersonalityView()
                    .environment(monetizationManager)
            } label: {
                settingsRow(
                    icon: "brain.head.profile",
                    tint: .purple,
                    title: "AI Personality",
                    subtitle: "Tone, style, and response tuning"
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Preferences Section

    private var preferencesSection: some View {
        settingsSection("Preferences") {
            settingsToggleRow(
                icon: "antenna.radiowaves.left.and.right",
                tint: .blue,
                title: "Cellular Downloads",
                subtitle: "Allow downloading models over mobile data",
                isOn: $allowCellularDownloads
            )

            sectionDivider

            settingsToggleRow(
                icon: "speaker.wave.2.fill",
                tint: .orange,
                title: "Read Replies Aloud",
                subtitle: "Speak control on responses for hands-free playback",
                isOn: $autoRead
            )

            sectionDivider


            settingsToggleRow(
                icon: "magnifyingglass",
                tint: .blue,
                title: "Search in Conversation",
                subtitle: "Show a search button inside active chats",
                isOn: $inChatSearchEnabled
            )

            sectionDivider

            settingsToggleRow(
                icon: "battery.25percent",
                tint: .green,
                title: "Low Power Mode",
                subtitle: "Lighter local behavior for lower battery impact",
                isOn: $lowPowerMode
            )
            sectionDivider

            settingsToggleRow(
                icon: "curlybraces",
                tint: .indigo,
                title: "Reply Style",
                subtitle: "Show quick options under replies",
                isOn: $smartReplyStylesEnabled
            )
            .onChange(of: smartReplyStylesEnabled) {
                systemPrompt = AIResponseDefaults.defaultSystemPrompt
            }
        }
    }

    #if DEBUG
    private var debugSection: some View {
        settingsSection("Debug") {
            settingsToggleRow(
                icon: "crown.fill",
                tint: .yellow,
                title: "Enable Pro",
                subtitle: "Overrides Pro entitlement in debug builds",
                isOn: Binding(
                    get: { monetizationManager.debugProEnabled },
                    set: { monetizationManager.debugProEnabled = $0 }
                )
            )
        }
    }
    #endif

    private var documentSection: some View {
        settingsSection("Documents") {
            HStack(spacing: 14) {
                rowIcon(systemImage: "doc.text.viewfinder", tint: .teal)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("PDF OCR Mode")
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)

                        Spacer()
                    }

                    Menu {
                        ForEach(PDFOCRMode.allCases) { mode in
                            Button {
                                pdfOCRModeRaw = mode.rawValue
                            } label: {
                                if mode == pdfOCRMode {
                                    Label(mode.title, systemImage: "checkmark")
                                } else {
                                    Text(mode.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(pdfOCRMode.title)
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 8)

                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(Color.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel("PDF OCR Mode")
                    .accessibilityValue(pdfOCRMode.title)

                    Text(pdfOCRMode.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Privacy Section

    private var privacySection: some View {
        settingsSection("Privacy") {
            // Auto-delete picker row
            HStack(spacing: 14) {
                rowIcon(systemImage: "clock.arrow.circlepath", tint: .orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Auto-Delete Chats")
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    Text(privacySummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Picker("Auto-Delete Chats", selection: $historyRetentionDays) {
                    ForEach(retentionOptions, id: \.self) { days in
                        Text(retentionLabel(for: days)).tag(days)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .onChange(of: historyRetentionDays) {
                historyManager.updateRetention(days: historyRetentionDays)
            }

            sectionDivider

            // Delete all chats
            Button {
                showClearHistoryConfirmation = true
            } label: {
                HStack(spacing: 14) {
                    rowIcon(systemImage: "trash.fill", tint: .red)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Delete All Chats")
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundStyle(.red)

                        Text("Remove every saved conversation from this device")
                            .font(.footnote)
                            .foregroundStyle(.red.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
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

    // MARK: - About Section

    private var aboutSection: some View {
        settingsSection("About") {
            Button {
                showDataPrivacySheet = true
            } label: {
                settingsRow(
                    icon: "hand.raised.fill",
                    tint: .indigo,
                    title: "Data & Privacy",
                    subtitle: "What stays on-device and when Apple services may be involved"
                )
            }
            .buttonStyle(.plain)

            sectionDivider

            Link(destination: URL(string: "https://sudoswisshub.github.io/MetalMind-AI/privacy.html")!) {
                settingsRow(
                    icon: "lock.doc.fill",
                    tint: .blue,
                    title: "Privacy Policy",
                    subtitle: "Open in your browser",
                    trailingIcon: "arrow.up.right"
                )
            }
            .buttonStyle(.plain)

            sectionDivider

            Link(destination: URL(string: "https://sudoswisshub.github.io/MetalMind-AI/terms.html")!) {
                settingsRow(
                    icon: "doc.text.fill",
                    tint: .gray,
                    title: "Terms of Service",
                    subtitle: "Review the legal terms",
                    trailingIcon: "arrow.up.right"
                )
            }
            .buttonStyle(.plain)

            sectionDivider

            Button(action: { openMail(subject: String(localized: "Support Request")) }) {
                settingsRow(
                    icon: "questionmark.circle.fill",
                    tint: .orange,
                    title: "Support",
                    subtitle: "Billing, downloads, models, or account help"
                )
            }
            .buttonStyle(.plain)

            sectionDivider

            // Storage info row
            HStack(spacing: 14) {
                rowIcon(systemImage: "internaldrive.fill", tint: .teal)

                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        downloadedModelCount == 1
                            ? String(localized: "1 local model")
                            : String(format: String(localized: "%lld local models", defaultValue: "%lld local models"), Int64(downloadedModelCount))
                    )
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                    Text(downloadedStorageText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .sheet(isPresented: $showDataPrivacySheet) {
            DataPrivacySheet()
                .environment(modelManager)
                .environmentObject(modelManager)
        }
    }



    // MARK: - Footer

    private var footerBranding: some View {
        Text("Made in Switzerland 🇨🇭")
            .font(.footnote)
            .foregroundStyle(.quaternary)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    // MARK: - Reusable Components

    private var sectionDivider: some View {
        Divider()
            .padding(.leading, 62)
    }

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.footnote)
            .fontWeight(.semibold)
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private func settingsSection<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(title)
            settingsCard(content: content)
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.04), radius: 10, y: 5)
    }

    private func settingsRow(
        icon: String,
        tint: Color,
        title: LocalizedStringKey,
        subtitle: String,
        trailingIcon: String = "chevron.right"
    ) -> some View {
        HStack(spacing: 14) {
            rowIcon(systemImage: icon, tint: tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Text(LocalizedStringKey(subtitle))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Image(systemName: trailingIcon)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func settingsToggleRow(
        icon: String,
        tint: Color,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 14) {
            rowIcon(systemImage: icon, tint: tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle(title, isOn: isOn)
                .labelsHidden()
                .tint(tint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var pdfOCRMode: PDFOCRMode {
        PDFOCRMode(rawValue: pdfOCRModeRaw) ?? .preferNativeText
    }

    private func rowIcon(systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: - Helpers

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
        .environment(LLMEngine())
        .environment(ChatHistoryManager())
        .environment(ModelManager())
        .environment(MonetizationManager())
        .environment(SpeechManager())
}
