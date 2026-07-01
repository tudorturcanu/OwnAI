//
//  OwnAIIntent.swift
//  LocalAI
//
//  Created by Tudor on 26.06.2026.
//

import AppIntents
import Foundation

/// App Intent that lets users ask Own AI a question via Siri.
///
/// Usage: "Hey Siri, Ask Own AI [question]"
/// The app will open with the question pre-filled and auto-sent in the chat view.
struct AskOwnAIIntent: AppIntent {

    static let title: LocalizedStringResource = "Ask Own AI"
    static let description = IntentDescription(
        "Talk to Own AI models directly using Shortcuts. Ask a question and Own AI will respond in the app.",
        categoryName: "Chat"
    )

    /// Opens the app when the intent runs so the user sees the streamed response.
    static let openAppWhenRun: Bool = true

    @Parameter(
        title: "Question",
        description: "The question or message you want to send to Own AI.",
        requestValueDialog: IntentDialog("What would you like to ask Own AI?")
    )
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Own AI \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Post a notification so ContentView can pick up the query and auto-send it.
        // This works whether the app was backgrounded or freshly launched, because
        // `openAppWhenRun = true` ensures the app is foregrounded before perform() returns.
        NotificationCenter.default.post(
            name: .ownAISiriQuery,
            object: nil,
            userInfo: [OwnAISiriQueryKey.query: query]
        )
        return .result()
    }
}

// MARK: - Notification Name

extension Notification.Name {
    /// Posted by `AskOwnAIIntent` when Siri delivers a query to the app.
    static let ownAISiriQuery = Notification.Name("com.ownai.siriQuery")
}

/// Keys used in the `ownAISiriQuery` notification's `userInfo` dictionary.
enum OwnAISiriQueryKey {
    static let query = "query"
}
