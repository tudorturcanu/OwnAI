//
//  OwnAIShortcuts.swift
//  LocalAI
//
//  Created by Tudor on 26.06.2026.
//

import AppIntents

/// Provides pre-built Siri phrases for Own AI.
///
/// These phrases are automatically surfaced by Siri and the Shortcuts app.
/// Users can trigger them by saying, for example:
///   - "Hey Siri, Ask Own AI [question]"
///   - "Hey Siri, Chat with Own AI"
///
/// Note: iOS does not support custom wake words. Only "Hey Siri" activates
/// voice interaction; users then invoke Own AI via these registered phrases.
struct OwnAIShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskOwnAIIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Chat with \(.applicationName)",
                "Talk to \(.applicationName)",
                "Hey \(.applicationName)",
                "Open \(.applicationName) and ask something",
            ],
            shortTitle: "Ask Own AI",
            systemImageName: "brain.head.profile.fill"
        )
        AppShortcut(
            intent: GetOwnAIAnswerIntent(),
            phrases: [
                "Get an answer from \(.applicationName)",
                "Answer with \(.applicationName)",
            ],
            shortTitle: "Get Answer",
            systemImageName: "text.bubble.fill"
        )
    }

    /// The accent color shown in the Shortcuts app for Own AI shortcuts.
    static let shortcutTileColor: ShortcutTileColor = .navy
}
