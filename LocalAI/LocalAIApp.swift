//
//  LocalAIApp.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import AppIntents
import SwiftUI
import UIKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@main
struct LocalAIApp: App {
    @AppStorage("appAppearance") private var appAppearanceRaw = AppAppearance.system.rawValue
    @State private var llmEngine = LLMEngine()
    @State private var historyManager = ChatHistoryManager()
    @State private var modelManager = ModelManager()
    @State private var speechManager = SpeechManager()
    @State private var monetizationManager = MonetizationManager()
    @State private var watchSessionManager = WatchConnectivitySessionManager()
    @State private var memoryStore = AssistantMemoryStore()
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
                .environment(memoryStore)
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
                .preferredColorScheme((AppAppearance(rawValue: appAppearanceRaw) ?? .system).colorScheme)
        }
    }
}
