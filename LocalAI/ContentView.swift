//
//  ContentView.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import CoreSpotlight
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
    @State private var showDownloads = false
    @AppStorage("hasShownOnboarding") private var hasShownOnboarding = false
    @State private var showOnboarding = false
    @State private var upgradeFeature: PremiumFeature?
    @State private var modelAwaitingUpgradeSelection: ModelInfo?
    @State private var modelAwaitingConsent: ModelInfo?
    /// Populated by the Siri App Intent; ChatView observes this to auto-send.
    @State private var siriPendingQuery: String?
    /// A document handed over from the share sheet or Files ("Copy to Own AI"),
    /// waiting for the chat to attach it.
    @State private var pendingImportFileURL: URL?
    /// Siri requests received before onboarding completes wait here so setup is
    /// never silently marked finished just to reveal the chat underneath it.
    @State private var postOnboardingSiriQuery: String?

    /// Which column a collapsed split view shows. Pinned to the chat: on
    /// compact widths history keeps opening as a sheet.
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail

    /// True whenever there is room for history as a persistent sidebar: iPad,
    /// large iPhones in landscape, and iPhone Duo's inner display. Driven by
    /// size class, never device idiom, because iPhone Duo is a phone that
    /// switches between compact (outer) and regular (inner) displays.
    private var usesSplitLayout: Bool {
        horizontalSizeClass == .regular
    }

    var body: some View {
        // One NavigationSplitView for every width. It collapses to the chat
        // on compact widths and expands to sidebar + chat on regular ones.
        // Keeping a single view structure means unfolding or folding an
        // iPhone Duo, or rotating a Pro Max, keeps the draft, scroll position,
        // and in-chat search. Swapping between a split view and a plain stack
        // would rebuild ChatView and lose all of that.
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            ChatHistoryView(isEmbedded: true)
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            NavigationStack {
                chatContent
            }
        }
        .onChange(of: horizontalSizeClass) { _, sizeClass in
            // Unfolding to the inner display shows history in the sidebar, so
            // a history sheet left open on the outer display is redundant.
            if sizeClass == .regular {
                showHistory = false
            }
            preferredCompactColumn = .detail
        }
        .onChange(of: historyManager.currentConversationID) {
            preferredCompactColumn = .detail
        }
    }

    private var chatContent: some View {
        ChatView(siriPendingQuery: $siriPendingQuery, pendingImportFileURL: $pendingImportFileURL)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            // A collapsed split view adds a back button to the sidebar. On
            // compact widths history opens from the History button instead.
            .navigationBarBackButtonHidden(true)
            .toolbar {
                    // Left: Settings & History as one system group. Separate
                    // items (not a hand-drawn capsule) let iPhone Duo stack
                    // them in its side bar and overflow them one at a time.
                    // TODO(iPhone Duo): give this group a lower
                    // ToolbarItemVisibilityPriority than New Chat once the
                    // modifier is public. SDK 26.5 has the symbol but doesn't
                    // declare it in the SwiftUI interface.
                    ToolbarItemGroup(placement: .topBarLeading) {
                        leadingToolbarButtons
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

                    // Right: download activity ring
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
        .sheet(isPresented: $showDownloads) {
            NavigationStack {
                DownloadsView(isPresentedAsSheet: true)
                    .environment(modelManager)
            }
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
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let conversationID = ConversationSpotlightIndexer.conversationID(from: activity),
                  let url = URL(string: "ownai://conversation?id=\(conversationID.uuidString)") else {
                return
            }
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
            showDownloads = false
            // Small delay to let sheet dismissal animate before auto-sending.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                siriPendingQuery = query
            }
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

    /// Title + symbol on every item: the symbol shows in the bar, and the
    /// title shows when iPhone Duo's side bar moves the item into overflow.
    @ViewBuilder
    private var leadingToolbarButtons: some View {
        Button {
            speechManager.stopSpeaking()
            showSettings = true
        } label: {
            Label(String(localized: "Settings"), systemImage: "gearshape")
        }
        .tint(Color.adaptive(white: 0.3))
        .keyboardShortcut(",", modifiers: .command)

        // In the split layout the sidebar already shows history.
        if !usesSplitLayout {
            Button {
                speechManager.stopSpeaking()
                showHistory = true
            } label: {
                Label(String(localized: "Chat History"), systemImage: "bubble.left")
            }
            .tint(Color.adaptive(white: 0.3))
            .keyboardShortcut("h", modifiers: [.command, .shift])
        }
    }

    /// New Chat and in-chat Search live in `ChatView`'s own trailing group,
    /// next to the chat they act on.
    private var trailingToolbarButtons: some View {
        // Renders nothing when no download is running, so it costs no
        // toolbar width in the common case.
        DownloadActivityToolbarButton {
            speechManager.stopSpeaking()
            showDownloads = true
        }
        .fixedSize()
    }

    private func handleIncomingURL(_ url: URL) {
        showHistory = false
        showSettings = false
        showDownloads = false

        if url.isFileURL {
            pendingImportFileURL = url
            return
        }

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
