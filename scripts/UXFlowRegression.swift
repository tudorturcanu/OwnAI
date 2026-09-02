import Foundation

@main
enum UXFlowRegression {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let contentView = try source(root, "LocalAI/ContentView.swift")
        let onboarding = try source(root, "LocalAI/Views/OnboardingView.swift")
        let chat = try source(root, "LocalAI/Views/ChatView.swift")
        let history = try source(root, "LocalAI/Views/ChatHistoryView.swift")
        let suggestions = try source(root, "LocalAI/Views/Components/ChatSuggestion.swift")
        let suggestionCard = try source(root, "LocalAI/Views/Components/SuggestionCard.swift")
        let messageBubble = try source(root, "LocalAI/Views/Components/MessageBubble.swift")
        let savedPrompts = try source(root, "LocalAI/Views/SavedPromptsView.swift")
        let settings = try source(root, "LocalAI/Views/SettingsView.swift")
        let voiceConversation = try source(root, "LocalAI/Views/VoiceConversationView.swift")
        let modelDownload = try source(root, "LocalAI/Views/ModelDownloadView.swift")
        let monetization = try source(root, "LocalAI/Services/MonetizationManager.swift")
        let app = try source(root, "LocalAI/LocalAIApp.swift")

        require(contentView.contains(".fullScreenCover(isPresented: $showOnboarding)"),
                "onboarding must remain an explicit full-screen flow")
        require(contentView.contains(".interactiveDismissDisabled()"),
                "onboarding must not be accidentally dismissed")
        require(contentView.contains("OnboardingView(isPresented: $showOnboarding, onComplete: completeOnboarding)"),
                "onboarding completion callback is not wired")
        require(onboarding.contains("onComplete()\n        isPresented = false"),
                "onboarding must only persist completion after the explicit final action")
        require(onboarding.contains("@AccessibilityFocusState private var focusedPage: Int?"),
                "onboarding must move VoiceOver focus when pages change")
        require(onboarding.contains(".accessibilityFocused($focusedPage, equals: privacyPageIndex)"),
                "privacy-page heading is not connected to VoiceOver focus")

        require(suggestions.contains("var requiresInput = false"),
                "prompt templates lost their input-required contract")
        require(chat.contains("if suggestion.requiresInput"),
                "input-required suggestions are no longer handled")
        require(!chat.contains("voiceSessionStartMessageCount"),
                "voice mode must not clear or truncate the conversation")

        require(monetization.contains("case unlimitedMessages"),
                "daily-limit paywall needs a dedicated user-facing feature")
        require(chat.contains("case .unlimitedMessages:\n                            sendMessage()"),
                "message send must resume after upgrade")
        require(chat.contains("case .imageInput:"),
                "image selection must resume after upgrade")
        require(chat.contains("case .voiceMode:\n                            requestVoiceConversation()"),
                "voice conversation must resume after upgrade")
        require(chat.contains("photoItemAwaitingUpgrade = item"),
                "selected photo must survive the upgrade flow")
        require(chat.contains("Own AI couldn’t read that image. Try another photo."),
                "image failures need a visible recovery message")
        require(chat.contains("UIAccessibility.post(notification: .announcement, argument: message)"),
                "transient chat feedback must be announced to VoiceOver")
        require(!chat.contains(".onTapGesture(perform: onDismiss)"),
                "dismissible notifications must keep native button semantics")

        require(suggestionCard.contains("dynamicTypeSize.isAccessibilitySize ? 280 : 210"),
                "suggestion cards must expand at accessibility text sizes")
        require(messageBubble.contains("message.isStreaming && !reduceMotion"),
                "streaming shimmer must honor Reduce Motion")
        require(messageBubble.contains("No mail app is available. The report details were copied"),
                "problem reports need a recovery path when Mail is unavailable")
        require(messageBubble.contains("private func openReport(_ url: URL, fallbackText: String)"),
                "report actions must share one failure-handling path")
        require(savedPrompts.contains("EditButton()"),
                "prompt ordering needs native edit mode")
        require(savedPrompts.contains("String(localized: \"Delete Prompt?\")"),
                "permanent prompt deletion needs confirmation")
        require(!savedPrompts.contains(".environment(\\.editMode, .constant(.active))"),
                "prompt library must not remain permanently in edit mode")
        require(settings.contains("guard feature == .conversationExport else { return }"),
                "settings export must resume after upgrade")
        require(settings.contains("String(localized: \"All chats deleted\")"),
                "destructive history completion must be announced")
        require(voiceConversation.contains("UIAccessibility.post(notification: .announcement, argument: statusText)"),
                "voice phase changes must be announced")
        require(voiceConversation.contains("if dynamicTypeSize.isAccessibilitySize"),
                "voice header must reflow at accessibility text sizes")
        require(voiceConversation.contains(".disabled(phase == .thinking)"),
                "the voice orb must not expose an action while thinking")
        require(voiceConversation.contains("dynamicTypeSize.isAccessibilitySize ? 170 : 220"),
                "voice controls must fit short screens at accessibility text sizes")
        require(voiceConversation.contains("Transcript: %@"),
                "visually shortened voice transcripts must remain complete for VoiceOver")
        require(modelDownload.contains("@ScaledMetric(relativeTo: .body) private var closeButtonSize = 44.0"),
                "download cancellation must keep a 44-point touch target")
        require(modelDownload.contains(".accessibilityLabel(String(localized: \"Downloading model\"))"),
                "download progress and cancellation must remain separate VoiceOver elements")
        require(modelDownload.contains(".accessibilityLabel(String(localized: \"Thinking mode\"))"),
                "model thinking control needs an explicit accessible state")
        require(!modelDownload.contains(".minimumScaleFactor"),
                "model controls must wrap instead of shrinking accessibility text")

        require(history.contains("List {"),
                "history must use a native List so swipe actions remain functional")
        require(history.contains(".swipeActions(edge: .trailing"),
                "history row actions are missing")
        require(!app.contains(".preferredColorScheme(.light)"),
                "the app must honor the system color scheme")

        print("Core UX flow regression passed")
    }

    private static func source(_ root: URL, _ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}
