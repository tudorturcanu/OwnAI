//
//  ContentView.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import SwiftUI

struct ContentView: View {
    @Environment(LLMEngine.self) private var llmEngine
    @Environment(ChatHistoryManager.self) private var historyManager
    @Environment(ModelManager.self) private var modelManager
    @Environment(SpeechManager.self) private var speechManager
    @Environment(MonetizationManager.self) private var monetizationManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showHistory = false
    @State private var showSettings = false
    @AppStorage("hasShownOnboarding") private var hasShownOnboarding = false
    @State private var showOnboarding = false
    @State private var upgradeFeature: PremiumFeature?
    @State private var modelAwaitingUpgradeSelection: ModelInfo?
    @State private var modelAwaitingConsent: ModelInfo?
    /// Populated by the Siri App Intent; ChatView observes this to auto-send.
    @State private var siriPendingQuery: String?
    /// Siri requests received before onboarding completes wait here so setup is
    /// never silently marked finished just to reveal the chat underneath it.
    @State private var postOnboardingSiriQuery: String?
    @State private var showCellularRestrictionAlert = false

    /// True on iPad-width layouts, where chat history lives in a persistent
    /// sidebar instead of a sheet. Restricted to iPad: large iPhones also
    /// report a regular width in landscape, and swapping the view structure
    /// on rotation would throw away in-progress chat state.
    private var usesSplitLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }

    var body: some View {
        Group {
            if usesSplitLayout {
                NavigationSplitView {
                    ChatHistoryView(isEmbedded: true)
                        .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
                } detail: {
                    NavigationStack {
                        chatContent
                    }
                }
            } else {
                NavigationStack {
                    chatContent
                }
            }
        }
    }

    private var chatContent: some View {
        ChatView(siriPendingQuery: $siriPendingQuery)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                    // Left: History & Settings Grouped
                    if #available(iOS 26.0, *) {
                        ToolbarItemGroup(placement: .topBarLeading) {
                            leadingToolbarButtons
                        }
                        .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItemGroup(placement: .topBarLeading) {
                            leadingToolbarButtons
                        }
                    }

                    // Center: Model Selection & Export
                    ToolbarItem(placement: .principal) {
                        Menu {
                            Button {
                                speechManager.stopSpeaking()
                                modelManager.enableAutomaticSelection()
                            } label: {
                                if modelManager.isAutomaticSelectionEnabled {
                                    Label(String(localized: "Auto Mode"), systemImage: "checkmark")
                                } else {
                                    Label(String(localized: "Auto Mode"), systemImage: "wand.and.stars")
                                }
                            }

                            Menu {
                                ForEach(AutoModelPreference.allCases) { preference in
                                    Button {
                                        modelManager.setAutoModelPreference(preference)
                                        modelManager.enableAutomaticSelection()
                                    } label: {
                                        if modelManager.autoModelPreference == preference {
                                            Label(preference.title, systemImage: "checkmark")
                                        } else {
                                            Label(preference.title, systemImage: preference.symbolName)
                                        }
                                    }
                                }
                            } label: {
                                Label(
                                    String(format: String(
                                        localized: "Preference: %@",
                                        defaultValue: "Preference: %@"
                                    ), modelManager.autoModelPreference.title),
                                    systemImage: "slider.horizontal.3"
                                )
                            }

                            Divider()

                            ForEach(downloadedModels) { model in
                                Button {
                                    speechManager.stopSpeaking()
                                    if monetizationManager.isPremiumModel(model) && !monetizationManager.hasPro {
                                        modelAwaitingUpgradeSelection = model
                                        upgradeFeature = .allModels
                                    } else {
                                        selectModelWithConsent(model)
                                    }
                                } label: {
                                    if !modelManager.isAutomaticSelectionEnabled && modelManager.selectedModel?.id == model.id {
                                        Label(model.name, systemImage: "checkmark")
                                    } else {
                                        Text(model.name)
                                    }
                                }
                            }

                            Divider()

                            Button {
                                speechManager.stopSpeaking()
                                showSettings = true
                            } label: {
                                Label(String(localized: "Manage Models"), systemImage: "gearshape")
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if modelManager.isAutomaticSelectionEnabled {
                                    Image(systemName: "wand.and.stars")
                                        .font(.caption.weight(.semibold))
                                }
                                VStack(spacing: 0) {
                                    Text(modelManager.isAutomaticSelectionEnabled ? String(localized: "Auto") : (modelManager.selectedModel?.name ?? String(localized: "Own AI")))
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    if modelManager.isAutomaticSelectionEnabled, let model = modelManager.selectedModel {
                                        Text(model.name)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.bold))
                            }
                            .foregroundStyle(Color.adaptive(white: 0.2))
                        }
                        .accessibilityLabel(modelSelectorAccessibilityLabel)
                        .accessibilityHint(String(localized: "Opens automatic and manual model choices."))
                    }

                    // Right: Export + New Chat
                    if #available(iOS 26.0, *) {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            trailingToolbarButtons
                        }
                        .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            trailingToolbarButtons
                        }
                    }
                }
        .sheet(isPresented: $showHistory) {
            ChatHistoryView()
                .environment(historyManager)
                .environment(monetizationManager)
                .environment(modelManager)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(llmEngine)
                .environment(historyManager)
                .environment(modelManager)
                .environment(monetizationManager)
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding, onComplete: completeOnboarding)
                .environment(llmEngine)
                .environment(modelManager)
                .environment(monetizationManager)
                .interactiveDismissDisabled()
        }
        .sheet(item: $modelAwaitingConsent) { model in
            ModelConsentSheet(model: model) {
                UserDefaults.standard.set(true, forKey: consentKey(for: model))
                modelAwaitingConsent = nil
                modelManager.selectModel(model.id)
            } onCancel: {
                modelAwaitingConsent = nil
            }
        }
        .sheet(item: $upgradeFeature) { feature in
            UpgradeView(feature: feature) {
                guard feature == .allModels, let model = modelAwaitingUpgradeSelection else { return }
                modelAwaitingUpgradeSelection = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    selectModelWithConsent(model)
                }
            }
                .environment(monetizationManager)
        }
        .onAppear {
            if !hasShownOnboarding {
                showOnboarding = true
            }
        }
        .onOpenURL { url in
            handleIncomingURL(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ownAISiriQuery)) { notification in
            guard let query = notification.userInfo?[OwnAISiriQueryKey.query] as? String,
                  !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }

            guard hasShownOnboarding else {
                postOnboardingSiriQuery = query
                showOnboarding = true
                return
            }

            // Dismiss any open sheets so the chat is visible.
            showHistory = false
            showSettings = false
            // Small delay to let sheet dismissal animate before auto-sending.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                siriPendingQuery = query
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cellularDownloadRestricted)) { _ in
            showCellularRestrictionAlert = true
        }
        .alert(String(localized: "Cellular Downloads Off"), isPresented: $showCellularRestrictionAlert) {
            Button(String(localized: "OK"), role: .cancel) { }
        } message: {
            Text(String(localized: "Connect to Wi-Fi, or enable Cellular Downloads in Settings."))
        }
        .alert(
            String(localized: "Chat History Notice"),
            isPresented: Binding(
                get: { historyManager.persistenceNotice != nil },
                set: { isPresented in
                    if !isPresented {
                        historyManager.dismissPersistenceNotice()
                    }
                }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {
                historyManager.dismissPersistenceNotice()
            }
        } message: {
            Text(historyManager.persistenceNotice ?? "")
        }
    }

    private var downloadedModels: [ModelInfo] {
        modelManager.models.filter { $0.downloadState.isDownloaded }
    }

    private func consentKey(for model: ModelInfo) -> String {
        "modelConsent.\(model.id)"
    }

    private func selectModelWithConsent(_ model: ModelInfo) {
        guard UserDefaults.standard.bool(forKey: consentKey(for: model)) else {
            modelAwaitingConsent = model
            return
        }
        modelManager.selectModel(model.id)
    }

    private var modelSelectorAccessibilityLabel: String {
        let modelName = modelManager.selectedModel?.name ?? String(localized: "No model")
        if modelManager.isAutomaticSelectionEnabled {
            return String(format: String(
                localized: "Auto Mode, %@ preference, currently %@",
                defaultValue: "Auto Mode, %@ preference, currently %@"
            ), modelManager.autoModelPreference.title, modelName)
        }
        return String(format: String(localized: "Selected model %@", defaultValue: "Selected model %@"), modelName)
    }

    private var leadingToolbarButtons: some View {
        HStack(spacing: 0) {
            Button {
                speechManager.stopSpeaking()
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .accessibilityLabel(String(localized: "Settings"))
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.adaptive(white: 0.3))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)

            // In the split layout the sidebar already shows history.
            if !usesSplitLayout {
                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 4)

                Button {
                    speechManager.stopSpeaking()
                    showHistory = true
                } label: {
                    Image(systemName: "bubble.left")
                        .accessibilityLabel(String(localized: "Chat History"))
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.adaptive(white: 0.3))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }
        .fixedSize()
        .background(Color.adaptive(white: 0.95))
        .clipShape(Capsule())
    }

    private var trailingToolbarButtons: some View {
        HStack(spacing: 8) {
            Button {
                speechManager.stopSpeaking()
                withAnimation {
                    historyManager.newConversation()
                }
            } label: {
                Image(systemName: "square.and.pencil")
                    .accessibilityLabel(String(localized: "New Chat"))
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.adaptive(white: 0.3))
                    .frame(width: 32, height: 32)
                    .background(Color.adaptive(white: 0.95))
                    .clipShape(Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
        }
        .fixedSize()
    }

    private func handleIncomingURL(_ url: URL) {
        showHistory = false
        showSettings = false

        if let conversationID = conversationID(from: url),
           historyManager.conversations.contains(where: { $0.id == conversationID }) {
            historyManager.selectConversation(conversationID)
        }
    }

    private func completeOnboarding() {
        hasShownOnboarding = true

        guard let query = postOnboardingSiriQuery else { return }
        postOnboardingSiriQuery = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            siriPendingQuery = query
        }
    }

    private func conversationID(from url: URL) -> UUID? {
        guard url.scheme?.localizedCaseInsensitiveCompare("ownai") == .orderedSame else {
            return nil
        }

        guard url.host?.localizedCaseInsensitiveCompare("conversation") == .orderedSame else {
            return nil
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let idValue = components.queryItems?.first(where: { $0.name == "id" })?.value else {
            return nil
        }

        return UUID(uuidString: idValue)
    }

}

#Preview {
    ContentView()
        .environment(LLMEngine())
        .environment(ChatHistoryManager())
        .environment(ModelManager())
        .environment(SpeechManager())
        .environment(MonetizationManager())
}
