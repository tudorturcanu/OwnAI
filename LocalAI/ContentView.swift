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
    @State private var exportShareItems: [Any] = []
    @State private var isExportShareSheetPresented = false
    @State private var exportUpgradeFeature: PremiumFeature?

    var body: some View {
        NavigationStack {
            ChatView()
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
                        HStack(spacing: 12) {
                            Button {
                                speechManager.stopSpeaking()
                                showSettings = true
                            } label: {
                                HStack(spacing: 4) {
                                    Text(modelManager.selectedModel?.name ?? String(localized: "Select Model"))
                                        .font(.subheadline.weight(.semibold))
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.bold))
                                }
                                .foregroundStyle(Color(white: 0.2))
                            }
                            .buttonStyle(.plain)


                        }
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
        .sheet(isPresented: $isExportShareSheetPresented, onDismiss: { exportShareItems = [] }) {
            ShareSheet(items: exportShareItems)
        }
        .sheet(item: $exportUpgradeFeature) { feature in
            UpgradeView(feature: feature)
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
                    .padding(8)
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
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
        .background(Color(white: 0.95))
        .clipShape(Capsule())
    }

    private var trailingToolbarButtons: some View {
        HStack(spacing: 8) {
            if !historyManager.currentMessages.isEmpty {
                Button {
                    handleExportCurrentConversation()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .accessibilityLabel(String(localized: "Export Chat"))
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color(white: 0.3))
                        .frame(width: 32, height: 32)
                        .background(Color(white: 0.95))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

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
            }
            .buttonStyle(.plain)
        }
    }

    private func handleExportCurrentConversation() {
        guard monetizationManager.canUse(.conversationExport) else {
            exportUpgradeFeature = .conversationExport
            return
        }
        guard let conversation = historyManager.conversations.first(where: {
            $0.id == historyManager.currentConversationID
        }) else { return }

        let markdown = ConversationExporter.export(
            messages: conversation.messages,
            title: conversation.title,
            format: .markdown
        )
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                ConversationExporter.fileName(title: conversation.title, format: .markdown)
            )
        do {
            try markdown.write(to: tempURL, atomically: true, encoding: .utf8)
            exportShareItems = [tempURL]
            isExportShareSheetPresented = true
        } catch {
            print("Export failed: \(error)")
        }
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
