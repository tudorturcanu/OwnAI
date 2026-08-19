import Foundation
import Observation
import SwiftUI
import WatchConnectivity

@MainActor
@Observable
final class WatchConnectivitySessionManager: NSObject {
    private static let watchSystemPrompt = """
    You are replying to a user on Apple Watch.
    Keep the answer extremely brief, practical, and easy to scan.
    Lead with the answer.
    Prefer 1 short sentence plus 1 short follow-up line.
    If a list is necessary, use at most 3 very short bullets.
    Avoid preamble, filler, quotes, and long explanations.
    """
    private static let watchTemperature = 0.35
    private static let watchTopP = 0.8
    private static let watchMaxTokens = 80
    private static let watchMaxCharacters = 170

    var activationState: WCSessionActivationState = .notActivated
    var isReachable = false
    var lastRequestDate: Date?
    var lastErrorMessage: String?

    private weak var llmEngine: LLMEngine?
    private weak var historyManager: ChatHistoryManager?
    private weak var modelManager: ModelManager?
    private weak var monetizationManager: MonetizationManager?
    private var isSceneActive = true
    private var pendingRequests: [PendingWatchRequest] = []
    private var isProcessingQueue = false
    private var completedRequestIDs: Set<UUID> = []

    func configure(
        llmEngine: LLMEngine,
        historyManager: ChatHistoryManager,
        modelManager: ModelManager,
        monetizationManager: MonetizationManager
    ) {
        self.llmEngine = llmEngine
        self.historyManager = historyManager
        self.modelManager = modelManager
        self.monetizationManager = monetizationManager
        activate()
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        isSceneActive = phase == .active
        if isSceneActive {
            processPendingRequestsIfNeeded()
        }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        activationState = session.activationState
        isReachable = session.isReachable
        session.activate()
        processPendingRequestsIfNeeded()
    }

    private func handlePromptRequest(_ request: WatchPromptRequest) async -> WatchPromptResponse {
        lastRequestDate = request.sentAt

        guard let llmEngine, let historyManager, let modelManager, let monetizationManager else {
            return errorResponse(for: request, message: "The iPhone assistant is not ready yet.")
        }

        guard let model = modelManager.selectedModel else {
            return errorResponse(for: request, message: "Select or download a model on your iPhone first.")
        }

        guard modelManager.canSelect(model) else {
            return errorResponse(for: request, message: "This model requires Own AI Pro.", modelName: model.name)
        }

        guard !monetizationManager.hasReachedFreeDailyMessageLimit else {
            return errorResponse(for: request, message: "Today's free messages are used up. They reset tomorrow.", modelName: model.name)
        }

        switch llmEngine.state {
        case .loading, .generating:
            return errorResponse(for: request, message: "The iPhone assistant is busy. Try again in a moment.")
        default:
            break
        }

        modelManager.suspendBackgroundDownloadsForChat()
        let chatLease = await ChatWorkloadCoordinator.shared.beginChat()
        defer {
            Task { @MainActor in
                if await ChatWorkloadCoordinator.shared.endChat(chatLease) {
                    modelManager.resumeBackgroundDownloadsAfterChat()
                }
            }
        }

        if historyManager.currentConversation == nil {
            historyManager.newConversation()
        }

        let conversationID = historyManager.currentConversationID
        // Capture the transcript BEFORE appending the new turn: replies run on
        // an isolated session, so without this every watch follow-up ("and
        // tomorrow?", "why?") arrived with no conversation to follow.
        let contextualPrompt = promptIncludingRecentTranscript(
            request.prompt,
            historyManager: historyManager,
            conversationID: conversationID
        )
        historyManager.addMessage(ChatMessage(role: .user, content: request.prompt))

        do {
            let reply = try await llmEngine.generateIsolatedReply(
                prompt: contextualPrompt,
                systemPrompt: Self.watchSystemPrompt,
                model: model,
                overrides: .init(
                    temperature: Self.watchTemperature,
                    topP: Self.watchTopP,
                    maxTokens: Self.watchMaxTokens
                )
            )

            let normalizedReply = normalizedWatchReply(
                reply.trimmingCharacters(in: .whitespacesAndNewlines)
            )

            historyManager.addMessage(ChatMessage(role: .assistant, content: normalizedReply))
            monetizationManager.registerFreeMessageIfNeeded(for: request.prompt)
            // The watch exchange was appended to the phone's open conversation,
            // but the engine's persistent session never saw it. Reset so the
            // next phone message rebuilds context from the visible history
            // instead of answering from a transcript missing these turns.
            llmEngine.resetSession()

            return WatchPromptResponse(
                requestID: request.id,
                prompt: request.prompt,
                reply: normalizedReply,
                conversationID: conversationID,
                modelName: model.name,
                isError: false
            )
        } catch {
            let message = error.localizedDescription
            historyManager.addMessage(ChatMessage(role: .assistant, content: message))
            lastErrorMessage = message
            // The user turn (and this error bubble) still landed in the open
            // conversation without the engine session seeing them.
            llmEngine.resetSession()
            return errorResponse(for: request, message: message, modelName: model.name)
        }
    }

    // Mirrors ChatView's continuity prompt: the last few completed turns are
    // inlined so an isolated one-shot reply can still follow the conversation.
    private func promptIncludingRecentTranscript(
        _ prompt: String,
        historyManager: ChatHistoryManager,
        conversationID: UUID?
    ) -> String {
        let priorMessages = historyManager.recentCompletedMessages(
            in: conversationID,
            limit: 6
        )

        let transcript = priorMessages
            .suffix(6)
            .compactMap { message -> String? in
                let role = message.role == .user ? "User" : "Assistant"
                let content = AssistantOutputSanitizer
                    .sanitize(message.content)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { return nil }
                // Watch replies are capped at 80 tokens; long earlier turns
                // only crowd out the budget, so keep the head of each.
                return "\(role): \(PromptBudgeter.boundedChatText(content, maxTokens: 125))"
            }
            .joined(separator: "\n\n")

        let storedSummaryRaw = historyManager.conversation(id: conversationID)?
            .rollingSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedSummary = PromptBudgeter.boundedChatText(storedSummaryRaw, maxTokens: 180)

        guard !transcript.isEmpty || !storedSummary.isEmpty else { return prompt }

        var sections: [String] = []
        if !storedSummary.isEmpty {
            sections.append("""
            Summary of the earlier conversation, for continuity only. Use it \
            silently; never recite or recap it:
            \(storedSummary)
            """)
        }
        if !transcript.isEmpty {
            sections.append("""
            Recent conversation context, for continuity only:
            \(transcript)
            """)
        }
        sections.append("""
        Current turn:
        \(prompt)
        """)
        return sections.joined(separator: "\n\n")
    }

    private func errorResponse(
        for request: WatchPromptRequest,
        message: String,
        modelName: String? = nil
    ) -> WatchPromptResponse {
        lastErrorMessage = message
        return WatchPromptResponse(
            requestID: request.id,
            prompt: request.prompt,
            reply: message,
            conversationID: historyManager?.currentConversationID,
            modelName: modelName,
            isError: true
        )
    }

    private func normalizedWatchReply(_ reply: String) -> String {
        guard !reply.isEmpty else {
            return "No reply yet."
        }

        let normalizedLines = reply
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let bulletLines = normalizedLines.filter { line in
            line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("* ")
        }

        if !bulletLines.isEmpty {
            let conciseBullets = bulletLines.prefix(3).map { bullet in
                bullet.replacingOccurrences(of: "* ", with: "• ")
                    .replacingOccurrences(of: "- ", with: "• ")
            }
            return truncatedWatchText(conciseBullets.joined(separator: "\n"))
        }

        let flattened = normalizedLines.joined(separator: " ")
        let shortSentences = flattened
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !shortSentences.isEmpty {
            let conciseReply = shortSentences.prefix(2).joined(separator: ". ")
            return truncatedWatchText(conciseReply)
        }

        return truncatedWatchText(flattened)
    }

    private func truncatedWatchText(_ text: String) -> String {
        guard text.count > Self.watchMaxCharacters else {
            return text
        }

        let cutoffIndex = text.index(text.startIndex, offsetBy: Self.watchMaxCharacters)
        let truncated = text[..<cutoffIndex]
        if let lastSpace = truncated.lastIndex(of: " ") {
            return "\(truncated[..<lastSpace].trimmingCharacters(in: .whitespacesAndNewlines))…"
        }
        return "\(truncated.trimmingCharacters(in: .whitespacesAndNewlines))…"
    }

    private func enqueue(
        _ request: WatchPromptRequest,
        delivery: PendingWatchRequest.Delivery
    ) {
        guard !completedRequestIDs.contains(request.id) else { return }
        guard !pendingRequests.contains(where: { $0.request.id == request.id }) else { return }

        pendingRequests.append(PendingWatchRequest(request: request, delivery: delivery))
        processPendingRequestsIfNeeded()
    }

    private func processPendingRequestsIfNeeded() {
        guard !isProcessingQueue else { return }
        guard !pendingRequests.isEmpty else { return }
        guard canProcessPendingRequests else { return }

        isProcessingQueue = true

        Task { @MainActor [weak self] in
            await self?.drainPendingRequests()
        }
    }

    private func drainPendingRequests() async {
        while !pendingRequests.isEmpty, canProcessPendingRequests {
            let next = pendingRequests.removeFirst()
            let response = await handlePromptRequest(next.request)
            completedRequestIDs.insert(next.request.id)
            deliver(response, via: next.delivery)
        }

        isProcessingQueue = false

        if !pendingRequests.isEmpty, canProcessPendingRequests {
            processPendingRequestsIfNeeded()
        }
    }

    private func deliver(
        _ response: WatchPromptResponse,
        via delivery: PendingWatchRequest.Delivery
    ) {
        do {
            let payload = try WatchConnectivityCodec.encodeMessage(
                response,
                key: WatchConnectivityPayloadKey.response
            )

            switch delivery {
            case .interactive(let replyHandler):
                replyHandler(payload)
            case .background:
                WCSession.default.transferUserInfo(payload)
            }
        } catch {
            lastErrorMessage = error.localizedDescription

            if case .interactive(let replyHandler) = delivery {
                let fallback = WatchPromptResponse(
                    requestID: response.requestID,
                    prompt: response.prompt,
                    reply: error.localizedDescription,
                    isError: true
                )
                let payload = (try? WatchConnectivityCodec.encodeMessage(
                    fallback,
                    key: WatchConnectivityPayloadKey.response
                )) ?? [:]
                replyHandler(payload)
            }
        }
    }

    private var canProcessPendingRequests: Bool {
        guard let model = modelManager?.selectedModel else {
            return true
        }
        return model.engine != .mlx || isSceneActive
    }
}

private struct PendingWatchRequest {
    enum Delivery {
        case interactive(([String: Any]) -> Void)
        case background
    }

    let request: WatchPromptRequest
    let delivery: Delivery
}

extension WatchConnectivitySessionManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.activationState = activationState
            self.isReachable = session.isReachable
            self.lastErrorMessage = error?.localizedDescription
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            guard let request = try? WatchConnectivityCodec.decodeMessage(
                WatchPromptRequest.self,
                from: message,
                key: WatchConnectivityPayloadKey.request
            ) else {
                return
            }

            self.enqueue(request, delivery: .background)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            do {
                let request = try WatchConnectivityCodec.decodeMessage(
                    WatchPromptRequest.self,
                    from: message,
                    key: WatchConnectivityPayloadKey.request
                )
                self.enqueue(request, delivery: .interactive(replyHandler))
            } catch {
                let fallback = WatchPromptResponse(
                    requestID: UUID(),
                    prompt: "",
                    reply: error.localizedDescription,
                    isError: true
                )
                let payload = (try? WatchConnectivityCodec.encodeMessage(
                    fallback,
                    key: WatchConnectivityPayloadKey.response
                )) ?? [:]
                replyHandler(payload)
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        Task { @MainActor in
            guard let request = try? WatchConnectivityCodec.decodeMessage(
                WatchPromptRequest.self,
                from: userInfo,
                key: WatchConnectivityPayloadKey.request
            ) else {
                return
            }

            self.enqueue(request, delivery: .background)
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in
            session.activate()
        }
    }
    #endif
}
