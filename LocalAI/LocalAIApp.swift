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
    @StateObject private var modelManager = ModelManager()
    @State private var speechManager = SpeechManager()
    @State private var monetizationManager = MonetizationManager()
    @State private var watchSessionManager = WatchConnectivitySessionManager()
    @Environment(\.scenePhase) private var scenePhase
    
    init() {
        NotificationManager.shared.incrementLaunchCount()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(llmEngine)
                .environment(historyManager)
                .environment(modelManager)
                .environmentObject(modelManager)
                .environment(speechManager)
                .environment(monetizationManager)
                .environment(watchSessionManager)
                .preferredColorScheme(.light)
                .onAppear {
                    watchSessionManager.configure(
                        llmEngine: llmEngine,
                        historyManager: historyManager,
                        modelManager: modelManager
                    )
                    watchSessionManager.handleScenePhaseChange(scenePhase)
                    llmEngine.handleScenePhaseChange(scenePhase)
                    speechManager.handleScenePhaseChange(scenePhase)
                }
                .onChange(of: scenePhase) {
                    watchSessionManager.handleScenePhaseChange(scenePhase)
                    llmEngine.handleScenePhaseChange(scenePhase)
                    speechManager.handleScenePhaseChange(scenePhase)
                    if scenePhase == .active {
                        historyManager.applyRetentionPolicy()
                    }
                }
        }
    }
}
