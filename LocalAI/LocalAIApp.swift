//
//  LocalAIApp.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import AppIntents
import SwiftUI
import UIKit

/// Receives the one UIKit callback SwiftUI's `App` doesn't surface: the system
/// relaunching us in the background to finish a background URLSession transfer
/// (the Kokoro weights download). Without handling it, iOS holds the transfer's
/// completion and eventually treats the relaunch as unresponsive.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == KokoroWeightsDownloader.sessionIdentifier else {
            completionHandler()
            return
        }
        KokoroWeightsDownloader.shared.handleBackgroundEvents(completionHandler: completionHandler)
    }
}

@main
struct LocalAIApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Declared first so the interval includes initialization of the app's
    // managers, history restoration, and model-catalog setup.
    @State private var launchPerformanceInterval: PerformanceLogger.Interval? = PerformanceLogger.begin(
        "AppLaunch",
        label: "App launch",
        metadata: "cold_start_marker=true"
    )
    @State private var llmEngine = LLMEngine()
    @State private var historyManager = ChatHistoryManager()
    @State private var modelManager = ModelManager()
    @State private var speechManager = SpeechManager()
    @State private var monetizationManager = MonetizationManager()
    @State private var watchSessionManager = WatchConnectivitySessionManager()
    @State private var memoryStore = AssistantMemoryStore()
    @Environment(\.scenePhase) private var scenePhase
    
    init() {
        AppAppearance.apply()
        NotificationManager.shared.incrementLaunchCount()
        // Donate App Shortcuts to Siri so phrases like "Ask Own AI" are
        // available immediately after install, without requiring user setup.
        OwnAIShortcuts.updateAppShortcutParameters()
    }
    
    var body: some Scene {
        WindowGroup {
            ThemedRoot {
                ContentView()
            }
                .environment(llmEngine)
                .environment(historyManager)
                .environment(modelManager)
                .environment(speechManager)
                .environment(monetizationManager)
                .environment(watchSessionManager)
                .environment(memoryStore)
                .onAppear {
                    if let interval = launchPerformanceInterval {
                        PerformanceLogger.end(
                            interval,
                            metadata: "history_count=\(historyManager.conversations.count) model_count=\(modelManager.models.count)"
                        )
                        launchPerformanceInterval = nil
                    }
                    modelManager.configure(monetizationManager: monetizationManager)
                    ConversationSpotlightIndexer.reindexIfOutdated(historyManager.conversations)
                    modelManager.onModelReadyForBenchmark = { model in
                        guard DeviceResourcePolicy.current.shouldRunAutomaticModelBenchmarks else { return }
                        if let existing = modelManager.quickTestResult(for: model.id),
                           existing.success,
                           existing.isCurrent {
                            return
                        }
                        for _ in 0..<60 where llmEngine.state == .generating || llmEngine.state == .loading {
                            try? await Task.sleep(for: .seconds(2))
                        }
                        guard llmEngine.state != .generating, llmEngine.state != .loading else { return }
                        let result = await llmEngine.runQuickTest(model: model)
                        modelManager.saveQuickTestResult(result)
                    }
                    watchSessionManager.configure(
                        llmEngine: llmEngine,
                        historyManager: historyManager,
                        modelManager: modelManager,
                        monetizationManager: monetizationManager
                    )
                    watchSessionManager.handleScenePhaseChange(scenePhase)
                    llmEngine.handleScenePhaseChange(scenePhase)
                    speechManager.handleScenePhaseChange(scenePhase)
                    // A voice download from a previous session may still be
                    // running in the background; reattach its progress.
                    speechManager.resumeVoiceDownloadIfInFlight()
                }
                .onChange(of: scenePhase) {
                    watchSessionManager.handleScenePhaseChange(scenePhase)
                    llmEngine.handleScenePhaseChange(scenePhase)
                    speechManager.handleScenePhaseChange(scenePhase)
                    if scenePhase == .active {
                        historyManager.retryPersistenceIfNeeded()
                        historyManager.applyRetentionPolicy()
                        speechManager.resumeVoiceDownloadIfInFlight()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                    historyManager.retryPersistenceIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    llmEngine.handleMemoryWarning()
                }
        }
    }
}

/// Applies the user's accent theme as the tint for the whole hierarchy and
/// re-applies it live when the theme changes in Settings.
private struct ThemedRoot<Content: View>: View {
    @ViewBuilder let content: () -> Content
    private let theme = AppTheme.shared

    var body: some View {
        content()
            .tint(theme.style == .original ? Color(uiColor: .systemBlue) : theme.accent.accentColor)
    }
}
