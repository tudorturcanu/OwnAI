//
//  AppSettingsReset.swift
//  LocalAI
//
//  One place that knows which UserDefaults keys are *preferences* (safe to
//  drop back to their defaults) as opposed to user content or one-time state.
//  Removing a key is enough: every `@AppStorage` that reads it falls back to
//  the default baked into the view, and the response-settings migration
//  markers stay set so nothing is re-migrated on the next launch.
//

import Foundation

@MainActor
enum AppSettingsReset {
    /// Preferences that "Reset All Settings" restores. Deliberately excludes:
    /// chat history, saved prompts, custom personality presets, model consent,
    /// onboarding completion, and the selected model — those are the user's
    /// data or decisions, not tuning knobs.
    static let resettableKeys: [String] = [
        // Response tuning
        "temperature",
        "topP",
        "maxTokens",
        "responseCharacterLimit",
        "systemPrompt",
        "smartReplyStylesEnabled",
        // Chat UI
        "autoRead",
        "messageTextScale",
        "codeTheme",
        "historyRetentionDays",
        "lowPowerMode",
        // Voice
        "speechRate",
        "speechOutputBackend",
        "speechInputLanguage",
        "speechInputBackend",
        // Documents and images
        DocumentProcessingMode.storageKey,
        DocumentOCRBackend.storageKey,
        ImageProcessingMode.storageKey,
        PDFOCRMode.storageKey,
        RAGEngine.neuralEmbeddingsDefaultsKey,
        // Downloads and diagnostics
        "downloads.allowCellular",
        "downloadNotifications",
        PerformanceMetricsStore.collectionEnabledKey,
        WebSearchEngine.storageKey
    ]

    static func resetToDefaults(defaults: UserDefaults = .standard) {
        for key in resettableKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
