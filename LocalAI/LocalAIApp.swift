//
//  LocalAIApp.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import AppIntents
import SwiftUI
import UIKit

@main
struct LocalAIApp: App {
    @State private var llmEngine = LLMEngine()
    @State private var historyManager = ChatHistoryManager()
    @State private var modelManager = ModelManager()
    @State private var speechManager = SpeechManager()
    @State private var monetizationManager = MonetizationManager()
    @State private var watchSessionManager = WatchConnectivitySessionManager()
    @Environment(\.scenePhase) private var scenePhase
    
    init() {
        NotificationManager.shared.incrementLaunchCount()
        // Donate App Shortcuts to Siri so phrases like "Ask Own AI" are
        // available immediately after install, without requiring user setup.
        OwnAIShortcuts.updateAppShortcutParameters()
        CrashReportingManager.shared.start()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(llmEngine)
                .environment(historyManager)
                .environment(modelManager)
                .environment(speechManager)
                .environment(monetizationManager)
                .environment(watchSessionManager)
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
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    llmEngine.handleMemoryWarning()
                }
                .preferredColorScheme(.light)
        }
    }
}
