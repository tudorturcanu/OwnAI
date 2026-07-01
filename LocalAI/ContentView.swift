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
    @State private var showHistory = false
    @State private var showSettings = false
    @AppStorage("hasShownOnboarding") private var hasShownOnboarding = false
    @State private var showOnboarding = false
    /// Populated by the Siri App Intent; ChatView observes this to auto-send.
    @State private var siriPendingQuery: String?
    @State private var showCellularRestrictionAlert = false

    var body: some View {
        NavigationStack {
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
                            ForEach(downloadedModels) { model in
                                Button {
                                    speechManager.stopSpeaking()
                                    modelManager.selectModel(model.id)
                                } label: {
                                    if modelManager.selectedModelID == model.id {
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
                            HStack(spacing: 4) {
                                Text(modelManager.selectedModel?.name ?? String(localized: "Own AI"))
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.bold))
                            }
                            .foregroundStyle(Color(white: 0.2))
                        }
                        .accessibilityLabel(String(localized: "Select Model"))
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
        }
        .sheet(isPresented: $showHistory) {
            ChatHistoryView()
                .environment(historyManager)
                .environment(monetizationManager)
                .environment(modelManager)
                .environmentObject(modelManager)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(llmEngine)
                .environment(historyManager)
                .environment(modelManager)
                .environment(monetizationManager)
                .environmentObject(modelManager)
        }
        .sheet(isPresented: $showOnboarding, onDismiss: { hasShownOnboarding = true }) {
            OnboardingView(isPresented: $showOnboarding)
                .environment(llmEngine)
                .environment(modelManager)
                .environment(monetizationManager)
                .environmentObject(modelManager)
                .interactiveDismissDisabled()
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
            // Dismiss any open sheets so the chat is visible.
            showHistory = false
            showSettings = false
            showOnboarding = false
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
    }

    private var downloadedModels: [ModelInfo] {
        modelManager.models.filter { $0.downloadState.isDownloaded }
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
                    .foregroundStyle(Color(white: 0.3))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
                    .foregroundStyle(Color(white: 0.3))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .fixedSize()
        .background(Color(white: 0.95))
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
                    .foregroundStyle(Color(white: 0.3))
                    .frame(width: 32, height: 32)
                    .background(Color(white: 0.95))
                    .clipShape(Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .fixedSize()
    }

    private func handleIncomingURL(_ url: URL) {
        showHistory = false
        showSettings = false
        showOnboarding = false

        if let conversationID = conversationID(from: url),
           historyManager.conversations.contains(where: { $0.id == conversationID }) {
            historyManager.selectConversation(conversationID)
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
