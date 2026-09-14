//
//  SettingsView.swift
//  Own Ai
//
//  Created by Tudor on 29.01.2026.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(LLMEngine.self) private var llmEngine
    @Environment(ChatHistoryManager.self) private var historyManager
    @Environment(ModelManager.self) private var modelManager
    @Environment(MonetizationManager.self) private var monetizationManager
    @AppStorage("historyRetentionDays") private var historyRetentionDays = 0
    @AppStorage("downloads.allowCellular") private var allowCellularDownloads = false
    @AppStorage(ConversationSpotlightIndexer.enabledKey) private var showChatsInSearch = false
    @State private var showClearHistoryConfirmation = false
    @State private var showResetSettingsConfirmation = false
    @State private var showDataPrivacySheet = false
    @State private var isUpgradeSheetPresented = false
    @State private var upgradeFeature: PremiumFeature?
    @State private var isExportingAllChats = false
    @State private var exportShareItems: [Any] = []
    @State private var isExportShareSheetPresented = false
    @State private var exportError: String?
    @State private var supportFallbackMessage: String?

    /// Observed so the appearance section shows or hides the theme rows the
    /// moment the colour style changes.
    private let appTheme = AppTheme.shared

    private static let supportAddress = "alice.turcanu91@gmail.com"

    private let retentionOptions = [0, 7, 30, 90]

    private var selectedModelName: String {
        modelManager.selectedModel?.name ?? String(localized: "No model selected")
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
            ? String(localized: "Kept until you delete them")
            : String(
                format: String(
                    localized: "Removed after %@",
                    defaultValue: "Removed after %@"
                ),
                retentionLabel(for: historyRetentionDays).lowercased()
            )
    }

    private var exportAllSubtitle: String {
        let count = historyManager.conversations.count
        guard count > 0 else {
            return String(localized: "Nothing to export yet")
        }
        // A single chat read as "Save 1 chats as Markdown".
        guard count > 1 else {
            return String(localized: "Save 1 chat as Markdown")
        }
        return String(
            format: String(
                localized: "Save %lld chats as Markdown",
                defaultValue: "Save %lld chats as Markdown"
            ),
            Int64(count)
        )
    }

    /// Writes the whole history to a single Markdown file and hands it to the
    /// share sheet. Formatting runs off the main actor so a large history does
    /// not freeze Settings.
    private func exportAllChats() {
        guard monetizationManager.canUse(.conversationExport) else {
            upgradeFeature = .conversationExport
            return
        }
        guard !isExportingAllChats else { return }

        let conversations = historyManager.conversations
        guard !conversations.isEmpty else { return }

        isExportingAllChats = true
        Task {
            let fileName = ConversationExporter.archiveFileName(format: .markdown)
            let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

            let writeResult = await Task.detached(priority: .userInitiated) { () -> String? in
                let archive = ConversationExporter.exportAll(conversations: conversations, format: .markdown)
                do {
                    try archive.write(to: destinationURL, atomically: true, encoding: .utf8)
                    // The archive is every conversation in plain text. The chat
                    // store itself is encrypted at rest, so the hand-off copy is
                    // protected too and deleted once sharing ends.
                    try? FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.complete],
                        ofItemAtPath: destinationURL.path
                    )
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value

            isExportingAllChats = false

            if let writeResult {
                exportError = writeResult
            } else {
                exportShareItems = [destinationURL]
                isExportShareSheetPresented = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                UIAccessibility.post(
                    notification: .announcement,
                    argument: String(localized: "Chat export ready")
                )
            }
        }
    }

    /// Removes the temporary archive once the share sheet closes. Without this
    /// a plain-text copy of every conversation stays in the temporary directory
    /// until the system happens to reclaim it.
    private func discardExportArchive() {
        for case let url as URL in exportShareItems {
            try? FileManager.default.removeItem(at: url)
        }
        exportShareItems = []
    }

    private var freePlanLimitMessage: String? {
        guard monetizationManager.hasReachedFreeDailyMessageLimit else { return nil }
        return String(localized: "Daily free limit reached. More messages tomorrow.")
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    headerSection
                    aiSection
                    preferencesSection
                    appearanceSection
                    #if DEBUG
                    debugSection
                    #endif

                    privacySection
                    aboutSection

                    footerBranding
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 40)
                .readableContentWidth()
            }
            .background(Color.adaptiveGroupedBackground.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton(action: dismiss.callAsFunction)
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $isUpgradeSheetPresented) {
            UpgradeView(feature: .allModels)
                .environment(monetizationManager)
        }
        .sheet(item: $upgradeFeature) { feature in
            UpgradeView(feature: feature) {
                guard feature == .conversationExport else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    exportAllChats()
                }
            }
                .environment(monetizationManager)
        }
        .sheet(isPresented: $isExportShareSheetPresented, onDismiss: { discardExportArchive() }) {
            ShareSheet(items: exportShareItems)
        }
        .alert(
            "Export Failed",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .alert(
            "Support",
            isPresented: Binding(
                get: { supportFallbackMessage != nil },
                set: { if !$0 { supportFallbackMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { supportFallbackMessage = nil }
        } message: {
            Text(supportFallbackMessage ?? "")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient.brandAccent
                    )
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: "brain.head.profile.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.92))
                            .accessibilityHidden(true)
                    }
                    .shadow(color: Color.brandAccent.opacity(0.22), radius: 10, y: 5)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Own AI")
                        .font(.display(.title3, weight: .bold))
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
                .foregroundStyle(monetizationManager.hasPro ? .green : .brandAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    (monetizationManager.hasPro ? Color.green : Color.brandAccent).opacity(0.12),
                    in: Capsule()
                )
            }

            if let freePlanLimitMessage {
                Label(LocalizedStringKey(freePlanLimitMessage), systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.brandAccent)
            } else if !monetizationManager.hasPro {
                Text("\(monetizationManager.freeMessagesRemainingToday) of \(MonetizationManager.freeDailyMessageLimit) free messages left today")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    // MARK: - AI Section

    /// Only offered when there is something to look at: a permanently visible
    /// "Downloads" row that is empty nine times out of ten is just noise.
    private var hasDownloadsToShow: Bool {
        modelManager.hasDownloadActivity || !modelManager.failedDownloadModels.isEmpty
    }

    private var downloadsSubtitle: String {
        if let progress = modelManager.aggregateDownloadProgress {
            let active = modelManager.activeDownloadModels.count + modelManager.queuedDownloadModels.count
            let percent = DownloadProgressFormat.percent(progress)
            if active > 1 {
                return String(
                    format: String(
                        localized: "%@ · %lld models in progress",
                        defaultValue: "%@ · %lld models in progress"
                    ),
                    percent,
                    Int64(active)
                )
            }
            return String(
                format: String(localized: "%@ downloaded", defaultValue: "%@ downloaded"),
                percent
            )
        }
        if modelManager.hasDownloadActivity {
            return String(localized: "Starting…")
        }
        return String(localized: "A download needs your attention")
    }

    private var aiSection: some View {
        settingsSection("AI") {
            if hasDownloadsToShow {
                NavigationLink {
                    DownloadsView()
                        .environment(modelManager)
                } label: {
                    settingsRow(
                        icon: "arrow.down.to.line",
                        tint: .teal,
                        modernTint: modelManager.hasDownloadActivity ? .brandAccent : .brandAccentDeep,
                        title: "Downloads",
                        subtitle: downloadsSubtitle
                    )
                }
                .buttonStyle(SettingsRowButtonStyle())

                sectionDivider
            }

            NavigationLink {
                ModelDownloadView()
                    .environment(llmEngine)
                    .environment(modelManager)
                    .environment(monetizationManager)
            } label: {
                settingsRow(
                    icon: "square.stack.3d.up.fill",
                    tint: .blue,
                    title: "Models",
                    subtitle: selectedModelName
                )
            }
            .buttonStyle(SettingsRowButtonStyle())

            sectionDivider

            NavigationLink {
                ModelStorageView()
            } label: {
                settingsRow(
                    icon: "externaldrive.fill",
                    tint: .gray,
                    title: "Model Storage",
                    subtitle: downloadedStorageText
                )
            }
            .buttonStyle(SettingsRowButtonStyle())

            sectionDivider

            // Lives next to Models and Personality because this is where people
            // look for "why does it remember / forget things". It used to be
            // listed under Privacy as well, which read as two different features.
            NavigationLink {
                MemorySettingsView()
            } label: {
                settingsRow(
                    icon: "brain.head.profile",
                    tint: .pink,
                    modernTint: .brandAccentDeep,
                    title: "Memory",
                    subtitle: "What Own AI remembers across chats"
                )
            }
            .buttonStyle(SettingsRowButtonStyle())

            sectionDivider

            // Guarded at the entrance rather than inside: nearly every section
            // of AIPersonalityView is Pro, so a free user who walked in met the
            // same "Own AI Pro" card stacked three times down one screen.
            if monetizationManager.canUse(.advancedPersonality) {
                NavigationLink {
                    AIPersonalityView()
                        .environment(monetizationManager)
                } label: {
                    settingsRow(
                        icon: "theatermasks.fill",
                        tint: .purple,
                        modernTint: .brandAccentDeep,
                        title: "AI Personality",
                        subtitle: "Tone, style, and response tuning"
                    )
                }
                .buttonStyle(SettingsRowButtonStyle())
            } else {
                Button {
                    upgradeFeature = .advancedPersonality
                } label: {
                    settingsRow(
                        icon: "theatermasks.fill",
                        tint: .purple,
                        modernTint: .brandAccentDeep,
                        title: "AI Personality",
                        subtitle: "Tone, style, and response tuning",
                        trailingIcon: "crown.fill",
                        trailingTint: .brandAccent
                    )
                }
                .buttonStyle(SettingsRowButtonStyle())
                .accessibilityHint(String(localized: "Own AI Pro feature. Opens upgrade options."))
            }
        }
    }

    // MARK: - Preferences Section

    private var preferencesSection: some View {
        settingsSection("Preferences") {
            settingsToggleRow(
                icon: "antenna.radiowaves.left.and.right",
                tint: .green,
                title: "Cellular Downloads",
                subtitle: "Download over mobile data",
                isOn: $allowCellularDownloads
            )
            .onChange(of: allowCellularDownloads) {
                modelManager.handleCellularDownloadsAllowedChanged()
            }

            sectionDivider

            NavigationLink {
                SiriSettingsView()
            } label: {
                settingsRow(
                    icon: "mic.fill",
                    tint: .indigo,
                    modernTint: .brandAccentDeep,
                    title: "Siri & Shortcuts",
                    subtitle: "Ask Own AI from Siri and Shortcuts"
                )
            }
            .buttonStyle(SettingsRowButtonStyle())

            sectionDivider

            NavigationLink {
                AdvancedSettingsView()
            } label: {
                settingsRow(
                    icon: "slider.horizontal.3",
                    tint: .gray,
                    modernTint: .brandAccentDeep,
                    title: "Advanced",
                    subtitle: "Documents, OCR, and low power mode"
                )
            }
            .buttonStyle(SettingsRowButtonStyle())
        }
    }

    private var appearanceSection: some View {
        settingsSection("Appearance") {
            ThemePreviewCard()
            ColorStylePickerRow()
            // The accent, paper and icon choices only shape the Modern look, so
            // they stay hidden while the app wears the Original appearance.
            if appTheme.style == .modern {
                sectionDivider
                AccentThemePickerRow()
                sectionDivider
                PaperTonePickerRow()
                sectionDivider
                AppIconMatchRow()
            }
        }
    }

    #if DEBUG
    private var debugSection: some View {
        settingsSection("Debug") {
            // The metrics store records every reply; this is the only screen
            // that shows what it collected.
            NavigationLink {
                PerformanceDashboardView()
            } label: {
                settingsRow(
                    icon: "chart.xyaxis.line",
                    tint: .green,
                    modernTint: .green,
                    title: "Performance Dashboard",
                    subtitle: "Reply timings and memory recorded on this device"
                )
            }
            .buttonStyle(SettingsRowButtonStyle())

            sectionDivider

            settingsToggleRow(
                icon: "crown.fill",
                tint: .yellow,
                modernTint: .yellow,
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

            settingsToggleRow(
                icon: "magnifyingglass",
                tint: .gray,
                modernTint: .brandAccentDeep,
                title: "Show Chats in Search",
                subtitle: "Find chats from iPhone Search",
                isOn: $showChatsInSearch
            )
            .onChange(of: showChatsInSearch) {
                if showChatsInSearch {
                    ConversationSpotlightIndexer.reindexAll(historyManager.conversations)
                } else {
                    ConversationSpotlightIndexer.removeAll()
                }
            }

            sectionDivider

            // Back up every chat before anything can remove them
            Button(action: exportAllChats) {
                HStack(spacing: 14) {
                    rowIcon(systemImage: "square.and.arrow.up.fill", tint: .blue)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Export All Chats")
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)

                        Text(exportAllSubtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    if isExportingAllChats {
                        ProgressView()
                            .controlSize(.small)
                    } else if !monetizationManager.canUse(.conversationExport) {
                        Image(systemName: "crown.fill")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.brandAccent)
                            .accessibilityLabel(String(localized: "Pro"))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .buttonStyle(SettingsRowButtonStyle())
            .disabled(isExportingAllChats || historyManager.conversations.isEmpty)
            .opacity(historyManager.conversations.isEmpty ? 0.5 : 1)

            sectionDivider

            // Delete all chats
            Button {
                showClearHistoryConfirmation = true
            } label: {
                HStack(spacing: 14) {
                    rowIcon(systemImage: "trash.fill", tint: .red, modernTint: .red)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Delete All Chats")
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundStyle(.red)

                        Text("Permanently remove every saved chat")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .buttonStyle(SettingsRowButtonStyle())
            .disabled(historyManager.conversations.isEmpty)
            .opacity(historyManager.conversations.isEmpty ? 0.5 : 1)
        }
        .alert("Delete all chats?", isPresented: $showClearHistoryConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                historyManager.clearAllConversations()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                UIAccessibility.post(
                    notification: .announcement,
                    argument: String(localized: "All chats deleted")
                )
            }
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
                    tint: .blue,
                    modernTint: .brandAccentDeep,
                    title: "Data & Privacy",
                    subtitle: "What stays on your device"
                )
            }
            .buttonStyle(SettingsRowButtonStyle())

            sectionDivider

            Link(destination: URL(string: "https://sudoswisshub.github.io/MetalMind-AI/privacy.html") ?? URL(string: "about:blank")!) {
                settingsRow(
                    icon: "lock.doc.fill",
                    tint: .gray,
                    title: "Privacy Policy",
                    trailingIcon: "arrow.up.right"
                )
            }
            .buttonStyle(SettingsRowButtonStyle())

            sectionDivider

            Link(destination: URL(string: "https://sudoswisshub.github.io/MetalMind-AI/terms.html") ?? URL(string: "about:blank")!) {
                settingsRow(
                    icon: "doc.text.fill",
                    tint: .gray,
                    title: "Terms of Service",
                    trailingIcon: "arrow.up.right"
                )
            }
            .buttonStyle(SettingsRowButtonStyle())

            sectionDivider

            Button(action: { openMail(subject: String(localized: "Support Request")) }) {
                settingsRow(
                    icon: "envelope.fill",
                    tint: .green,
                    title: "Support",
                    subtitle: "Get help by email"
                )
            }
            .buttonStyle(SettingsRowButtonStyle())

            sectionDivider

            Button {
                showResetSettingsConfirmation = true
            } label: {
                settingsRow(
                    icon: "arrow.counterclockwise",
                    tint: .gray,
                    modernTint: .brandAccentDeep,
                    title: "Reset All Settings",
                    subtitle: "Chats, models, and prompts are kept",
                    trailingIcon: nil
                )
            }
            .buttonStyle(SettingsRowButtonStyle())
        }
        .sheet(isPresented: $showDataPrivacySheet) {
            DataPrivacySheet()
                .environment(modelManager)
        }
        .confirmationDialog(
            String(localized: "Reset all settings?"),
            isPresented: $showResetSettingsConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Reset Settings"), role: .destructive) {
                AppSettingsReset.resetToDefaults()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                UIAccessibility.post(
                    notification: .announcement,
                    argument: String(localized: "Settings restored to defaults")
                )
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Response tuning, personality prompt, voice, document, and download preferences go back to their defaults. Your chats, downloaded models, saved prompts, and model choice are not touched."))
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

    /// Starts under the row titles, past the icon tile, like grouped lists.
    private var sectionDivider: some View {
        CardDivider(leadingInset: 16 + SettingsRowIcon.size + 14)
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
        // Clipped so the pressed highlight on the first and last rows follows
        // the card's rounded corners instead of poking out square.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .paperCard(radius: 16)
    }

    /// - Parameters:
    ///   - tint: Tile colour in the Original look.
    ///   - modernTint: Glyph colour in the Modern look, which stays on the
    ///     brand accent so its palette remains two-tone.
    ///   - subtitle: Keep it to one line; nil for rows whose title says it all.
    ///   - trailingIcon: nil for rows that run an action in place.
    private func settingsRow(
        icon: String,
        tint: Color,
        modernTint: Color = .brandAccent,
        title: LocalizedStringKey,
        subtitle: String? = nil,
        trailingIcon: String? = "chevron.right",
        /// nil keeps the default tertiary disclosure grey; a Pro crown needs
        /// the same orange it carries everywhere else.
        trailingTint: Color? = nil
    ) -> some View {
        HStack(spacing: 14) {
            rowIcon(systemImage: icon, tint: tint, modernTint: modernTint)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                if let subtitle {
                    Text(LocalizedStringKey(subtitle))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        // Live subtitles (download %, storage used) roll their
                        // digits instead of snapping when they update.
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .default, value: subtitle)
                }
            }

            Spacer(minLength: 8)

            if let trailingIcon {
                Image(systemName: trailingIcon)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(trailingTint ?? Color(uiColor: .tertiaryLabel))
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: SettingsRowIcon.size + 4)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func settingsToggleRow(
        icon: String,
        tint: Color,
        modernTint: Color = .brandAccent,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 14) {
            rowIcon(systemImage: icon, tint: tint, modernTint: modernTint)

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
            .accessibilityHidden(true)

            Spacer(minLength: 8)

            Toggle(title, isOn: isOn)
                .labelsHidden()
                // The Original look keeps the system green switch; the tile
                // colour on a switch would read as a different state.
                .tint(appTheme.style == .original ? nil : modernTint)
                .accessibilityHint(Text(subtitle))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func rowIcon(systemImage: String, tint: Color, modernTint: Color = .brandAccent) -> some View {
        SettingsRowIcon(systemImage: systemImage, systemTint: tint, modernTint: modernTint)
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
        let mailto = "mailto:\(Self.supportAddress)?subject=\(subject)"
        guard let url = URL(string: mailto.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""),
              UIApplication.shared.canOpenURL(url) else {
            // No mail client to hand the request to: leave the user with the
            // address instead of an unexplained dead tap.
            UIPasteboard.general.string = Self.supportAddress
            supportFallbackMessage = String(
                format: String(
                    localized: "No mail app is set up on this device. The support address %@ was copied to your clipboard.",
                    defaultValue: "No mail app is set up on this device. The support address %@ was copied to your clipboard."
                ),
                Self.supportAddress
            )
            return
        }
        UIApplication.shared.open(url)
    }

    private func presentUpgradeSheet() {
        showDataPrivacySheet = false
        isUpgradeSheetPresented = true
    }
}

/// Leading glyph tile for a settings row. The Original look uses a solid
/// colour tile with a white glyph, as iOS Settings does, so rows can be told
/// apart at a glance. The Modern look keeps its soft accent-tinted well.
private struct SettingsRowIcon: View {
    static let size: CGFloat = 32

    let systemImage: String
    /// Tile colour in the Original look.
    let systemTint: Color
    /// Glyph colour in the Modern look.
    var modernTint: Color = .brandAccent
    /// Well behind the glyph in the Modern look; defaults to a faint tint.
    var modernWell: Color?

    private let theme = AppTheme.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Group {
            if theme.style == .original {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.size, height: Self.size)
                    .background(systemTint.gradient, in: shape)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(modernTint)
                    .frame(width: Self.size, height: Self.size)
                    .background(modernWell ?? modernTint.opacity(0.1), in: shape)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Press feedback for settings rows: a quiet fill under the row while a finger
/// is down, the way grouped lists highlight. `.plain` gave no feedback at all,
/// and only the text and icon were tappable rather than the whole row.
private struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : Color.clear)
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.25), value: configuration.isPressed)
    }
}

/// Swatch row for picking the app's accent theme. Reads and writes the shared
/// `AppTheme`, so the whole app recolours as soon as a swatch is tapped.
private struct AccentThemePickerRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let theme = AppTheme.shared
    private static let selectionHaptic = UISelectionFeedbackGenerator()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                SettingsRowIcon(systemImage: "paintpalette.fill", systemTint: .blue, modernWell: .brandAccentSoft)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Accent Color")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("Used for buttons, highlights, and the sparkle.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Text(theme.accent.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.brandAccent)
                    .contentTransition(.numericText())
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(AppAccentTheme.allCases) { option in
                        swatch(for: option)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }

    private func swatch(for option: AppAccentTheme) -> some View {
        let isSelected = theme.accent == option
        return Button {
            guard !isSelected else { return }
            Self.selectionHaptic.selectionChanged()
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                theme.accent = option
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(isSelected ? option.accentColor : Color.clear, lineWidth: 2)
                    .frame(width: 44, height: 44)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [option.lightColor, option.accentColor, option.deepColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: isSelected ? 32 : 34, height: isSelected ? 32 : 34)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A miniature of the chat drawn in the current theme, so a choice can be
/// judged without leaving Settings.
private struct ThemePreviewCard: View {
    private let theme = AppTheme.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 40)
                Text("Plan my week")
                    .font(.footnote)
                    .foregroundStyle(Color.brandInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(LinearGradient.userBubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(alignment: .top, spacing: 8) {
                SparkleView(size: 22)
                Text("Sure. Let’s start with what matters most.")
                    .font(.footnote)
                    .foregroundStyle(Color.brandInk)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text("Ask anything")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 30)
                    .background(Color.adaptiveCard, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.brandHairline, lineWidth: 1))
                Image(systemName: "arrow.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(LinearGradient.brandAccent, in: Circle())
            }
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [Color.brandAccentLight.opacity(0.28), Color.adaptiveBackground],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.brandHairline, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Theme preview"))
        .accessibilityValue(
            theme.style == .original
                ? theme.style.title
                : theme.style.title + ", " + theme.accent.title + ", " + theme.paper.title
        )
    }
}

/// Opt-in: swap the Home Screen icon to the accent-tinted variant.
private struct AppIconMatchRow: View {
    private let theme = AppTheme.shared

    var body: some View {
        HStack(spacing: 14) {
            SettingsRowIcon(systemImage: "app.badge.checkmark.fill", systemTint: .blue, modernWell: .brandAccentSoft)

            VStack(alignment: .leading, spacing: 3) {
                Text("Match App Icon")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text("Tint the Home Screen icon in the accent color.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("Match App Icon", isOn: Binding(
                get: { theme.matchesAppIcon },
                set: { theme.matchesAppIcon = $0 }
            ))
            .labelsHidden()
            .tint(.brandAccent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

/// Top-level choice between the Original system look and the Modern themed
/// look. The app ships on Original; picking Modern reveals the accent, paper
/// and icon controls below and recolours the whole app live.
private struct ColorStylePickerRow: View {
    private let theme = AppTheme.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                SettingsRowIcon(systemImage: "circle.lefthalf.filled", systemTint: .blue, modernWell: .brandAccentSoft)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Appearance")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(theme.style.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            Picker("Appearance", selection: Binding(
                get: { theme.style },
                set: { newValue in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        theme.style = newValue
                    }
                }
            )) {
                ForEach(AppColorStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

/// Segmented choice of the page tone. Shares `AppTheme` with the accent row.
private struct PaperTonePickerRow: View {
    private let theme = AppTheme.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                SettingsRowIcon(systemImage: "doc.plaintext.fill", systemTint: .brown, modernWell: .brandAccentSoft)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Paper")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("The tone of the page behind everything.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            Picker("Paper", selection: Binding(
                get: { theme.paper },
                set: { newValue in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        theme.paper = newValue
                    }
                }
            )) {
                ForEach(AppPaperTone.allCases) { tone in
                    Text(tone.title).tag(tone)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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
