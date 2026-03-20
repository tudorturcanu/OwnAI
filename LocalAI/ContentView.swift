//
//  ContentView.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import SwiftUI

struct ContentView: View {
    @Environment(ChatHistoryManager.self) private var historyManager
    @Environment(ModelManager.self) private var modelManager
    @Environment(SpeechManager.self) private var speechManager
    @State private var showHistory = false
    @State private var showSettings = false
    @AppStorage("hasShownOnboarding") private var hasShownOnboarding = false
    @State private var showOnboarding = false
    
    var body: some View {
        NavigationStack {
            ChatView()
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Left: History & Settings Grouped
                    ToolbarItemGroup(placement: .topBarLeading) {
                        HStack(spacing: 0) {
                            Button {
                                speechManager.stopSpeaking()
                                showSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Color(white: 0.3))
                                    .padding(8)
                            }
                            
                            Divider()
                                .frame(height: 16)
                                .padding(.horizontal, 4)
                            
                            Button {
                                speechManager.stopSpeaking()
                                showHistory = true
                            } label: {
                                Image(systemName: "bubble.left")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Color(white: 0.3))
                                    .padding(8)
                            }
                        }
                        .background(Color(white: 0.95))
                        .clipShape(Capsule())
                    }
                    
                    // Center: Model Selection & Export
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 12) {
                            Button {
                                speechManager.stopSpeaking()
                                showSettings = true
                            } label: {
                                VStack(spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(modelManager.selectedModel?.name ?? "Select Model")
                                            .font(.subheadline.weight(.semibold))
                                        Image(systemName: "chevron.right")
                                            .font(.caption2.weight(.bold))
                                    }

                                    if let selectedModel = modelManager.selectedModel {
                                        Text(selectedModel.badges.first?.title ?? selectedModel.privacyLabel)
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(Color(white: 0.45))
                                    }
                                }
                                .foregroundStyle(Color(white: 0.2))
                            }
                            

                        }
                    }
                    
                    // Right: New Chat
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            speechManager.stopSpeaking()
                            withAnimation {
                                historyManager.newConversation()
                            }
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.body.weight(.medium))
                                .foregroundStyle(Color(white: 0.3))
                                .frame(width: 32, height: 32)
                                .background(Color(white: 0.95))
                                .clipShape(Circle())
                        }
                    }
                }
        }
        .sheet(isPresented: $showHistory) {
            ChatHistoryView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showOnboarding, onDismiss: { hasShownOnboarding = true }) {
            OnboardingView(isPresented: $showOnboarding)
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
}
