//
//  LocalAIApp.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import SwiftUI

@main
struct LocalAIApp: App {
    @State private var llmEngine = LLMEngine()
    @State private var historyManager = ChatHistoryManager()
    @State private var modelManager = ModelManager()
    @State private var speechManager = SpeechManager()
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(llmEngine)
                .environment(historyManager)
                .environment(modelManager)
                .environment(speechManager)
                .preferredColorScheme(.light)
                .onAppear {
                    llmEngine.handleScenePhaseChange(scenePhase)
                }
                .onChange(of: scenePhase) {
                    llmEngine.handleScenePhaseChange(scenePhase)
                    if scenePhase == .active {
                        historyManager.applyRetentionPolicy()
                    }
                }
        }
    }
}
