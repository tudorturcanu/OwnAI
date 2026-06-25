import Foundation
import Observation
import WatchKit
import WatchConnectivity

@MainActor
@Observable
final class WatchConnectivityClient: NSObject {
    private static let persistedStateKey = "watchConnectivityClient.state"

    var prompt = ""
    var entries: [WatchChatEntry] = [] {
        didSet {
            guard !isRestoringPersistedState else { return }
            persistState()
        }
    }
    var activationState: WCSessionActivationState = .notActivated
    var isReachable = false
    var isSending = false {
        didSet {
            guard !isRestoringPersistedState else { return }
            persistState()
        }
    }
    var isCapturingVoice = false {
        didSet {
            guard !isRestoringPersistedState else { return }
            persistState()
        }
    }
    var statusMessage = "Connect to your iPhone to send prompts." {
        didSet {
            guard !isRestoringPersistedState else { return }
            persistState()
        }
    }

    private var isRestoringPersistedState = false
    private var deferredRequests: [WatchPromptRequest] = []

    override init() {
        super.init()
        restorePersistedState()
    }

    var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasMessages: Bool {
        !entries.isEmpty
    }

    var latestFailedPrompt: String? {
        guard let failedEntry = entries.last(where: { $0.role == .assistant && $0.isError }) else {
            return nil
        }
        return entries.last(where: { $0.requestID == failedEntry.requestID && $0.role == .user })?.content
    }

    var latestFailureMessage: String? {
        entries.last(where: { $0.role == .assistant && $0.isError })?.content
    }

    var latestPendingPrompt: String? {
        guard let pendingEntry = entries.last(where: { $0.role == .assistant && $0.isPending }) else {
            return nil
        }
        return entries.last(where: { $0.requestID == pendingEntry.requestID && $0.role == .user })?.content
    }

    var stateSummary: WatchStateSummary {
        if isCapturingVoice {
            return .listening
        }
        if isSending {
            return .sending
        }
        if let latestAssistantEntry = entries.last(where: { $0.role == .assistant }) {
            if latestAssistantEntry.isPending {
                return .queued
            }
            if latestAssistantEntry.isError {
                return .error
            }
        }
        return isReachable ? .ready : .disconnected
    }

    func activate() {
        guard WCSession.isSupported() else {
            statusMessage = "Watch not supported."
            return
        }

        let session = WCSession.default
        session.delegate = self
        activationState = session.activationState
        isReachable = session.isReachable
        refreshStatus(using: session)
        if session.activationState != .activated {
            session.activate()
        }
    }

    func sendPrompt() {
        sendPrompt(trimmedPrompt)
    }

    func sendPrompt(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        guard WCSession.isSupported() else {
            statusMessage = "Watch not supported."
            return
        }

        let session = WCSession.default
        let request = WatchPromptRequest(prompt: trimmedText)
        appendPendingEntries(for: request)

        prompt = ""

        guard session.activationState == .activated else {
            deferredRequests.append(request)
            activationState = session.activationState
            isReachable = session.isReachable
            statusMessage = "Connecting to iPhone..."
            session.activate()
            return
        }

        submit(request, using: session)
    }

    func startDictation(suggestions: [String] = []) {
        guard !isSending else { return }
        guard let controller = WKApplication.shared().visibleInterfaceController else {
            statusMessage = "Open the app, then try again."
            playHaptic(.failure)
            return
        }

        isCapturingVoice = true
        statusMessage = "Listening…"
        playHaptic(.start)

        controller.presentTextInputController(
            withSuggestions: suggestions.isEmpty ? nil : suggestions,
            allowedInputMode: .plain
        ) { [weak self] results in
            Task { @MainActor in
                guard let self else { return }
                self.isCapturingVoice = false

                guard let firstResult = results?.first else {
                    self.refreshStatus(using: WCSession.default)
                    return
                }

                let dictatedText: String?
                if let text = firstResult as? String {
                    dictatedText = text
                } else if let emoji = firstResult as? NSString {
                    dictatedText = emoji as String
                } else {
                    dictatedText = nil
                }

                let normalizedText = dictatedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !normalizedText.isEmpty else {
                    self.refreshStatus(using: WCSession.default)
                    return
                }

                self.prompt = normalizedText
                self.sendPrompt()
            }
        }
    }

    func clearHistory() {
        entries.removeAll()
        statusMessage = isReachable ? "Ready on iPhone." : "Connect to your iPhone to send prompts."
    }

    func retryLatestFailedPrompt() {
        guard let latestFailedPrompt else { return }
        prompt = latestFailedPrompt
        sendPrompt()
    }

    func continueOnIPhone(for entry: WatchChatEntry) {
        guard let url = WatchCompanionRoute.conversationURL(for: entry.conversationID) else {
            statusMessage = "Can't open iPhone."
            return
        }

        statusMessage = "Opening on iPhone…"
        WKApplication.shared().openSystemURL(url)
    }

    private func apply(response: WatchPromptResponse) {
        isSending = false

        if let index = entries.firstIndex(where: {
            $0.requestID == response.requestID && $0.role == .assistant
        }) {
            entries[index] = .assistant(
                id: entries[index].id,
                requestID: response.requestID,
                content: response.reply,
                conversationID: response.conversationID,
                modelName: response.modelName,
                respondedAt: response.respondedAt,
                isError: response.isError
            )
        } else {
            entries.append(
                .assistant(
                    id: UUID(),
                    requestID: response.requestID,
                    content: response.reply,
                    conversationID: response.conversationID,
                    modelName: response.modelName,
                    respondedAt: response.respondedAt,
                    isError: response.isError
                )
            )
        }

        if response.isError {
            statusMessage = response.reply
            playHaptic(.failure)
        } else if let modelName = response.modelName {
            statusMessage = "Answered with \(modelName)."
            playHaptic(.success)
        } else {
            statusMessage = "Reply ready."
            playHaptic(.success)
        }
    }

    private func failPendingResponse(requestID: UUID, message: String) {
        isSending = false
        if let index = entries.firstIndex(where: {
            $0.requestID == requestID && $0.role == .assistant && $0.isPending
        }) {
            entries[index] = .assistant(
                id: entries[index].id,
                requestID: entries[index].requestID,
                content: message,
                conversationID: entries[index].conversationID,
                modelName: nil,
                respondedAt: nil,
                isError: true
            )
        }
        statusMessage = message
        playHaptic(.failure)
    }

    private func appendPendingEntries(for request: WatchPromptRequest) {
        entries.append(.user(prompt: request.prompt, requestID: request.id))
        entries.append(
            .assistantPlaceholder(
                id: UUID(),
                requestID: request.id,
                state: .queued
            )
        )
    }

    private func updatePendingEntry(
        requestID: UUID,
        state: WatchChatEntry.PendingState,
        content: String
    ) {
        guard let index = entries.firstIndex(where: {
            $0.requestID == requestID && $0.role == .assistant && $0.isPending
        }) else {
            return
        }

        entries[index] = entries[index].updatingPendingState(state, content: content)
    }

    private func queueRequest(
        _ request: WatchPromptRequest,
        using session: WCSession,
        fallbackMessage: String? = nil
    ) {
        isSending = false

        do {
            let payload = try WatchConnectivityCodec.encodeMessage(
                request,
                key: WatchConnectivityPayloadKey.request
            )
            session.transferUserInfo(payload)
            updatePendingEntry(
                requestID: request.id,
                state: .queued,
                content: "Queued for iPhone..."
            )

            if let fallbackMessage, !fallbackMessage.isEmpty {
                statusMessage = "Queued — \(fallbackMessage)"
            } else {
                statusMessage = "Queued for iPhone."
            }
            playHaptic(.click)
        } catch {
            failPendingResponse(requestID: request.id, message: error.localizedDescription)
        }
    }

    private func submit(_ request: WatchPromptRequest, using session: WCSession) {
        guard session.isReachable else {
            isReachable = false
            queueRequest(request, using: session)
            return
        }

        isSending = true
        updatePendingEntry(
            requestID: request.id,
            state: .sending,
            content: "Waiting for iPhone..."
        )
        statusMessage = "Sending to iPhone..."
        playHaptic(.click)

        do {
            let payload = try WatchConnectivityCodec.encodeMessage(
                request,
                key: WatchConnectivityPayloadKey.request
            )

            session.sendMessage(payload) { [weak self] reply in
                Task { @MainActor in
                    guard let self else { return }
                    do {
                        let response = try WatchConnectivityCodec.decodeMessage(
                            WatchPromptResponse.self,
                            from: reply,
                            key: WatchConnectivityPayloadKey.response
                        )
                        self.apply(response: response)
                    } catch {
                        self.failPendingResponse(
                            requestID: request.id,
                            message: error.localizedDescription
                        )
                    }
                }
            } errorHandler: { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.queueRequest(
                        request,
                        using: WCSession.default,
                        fallbackMessage: error.localizedDescription
                    )
                }
            }
        } catch {
            queueRequest(request, using: WCSession.default, fallbackMessage: error.localizedDescription)
        }
    }

    private func flushDeferredRequests(using session: WCSession) {
        guard session.activationState == .activated else { return }
        guard !deferredRequests.isEmpty else { return }

        let pending = deferredRequests
        deferredRequests.removeAll()

        for request in pending {
            submit(request, using: session)
        }
    }

    private func persistState() {
        let persistedState = PersistedWatchState(
            statusMessage: statusMessage,
            isSending: isSending,
            isCapturingVoice: isCapturingVoice,
            entries: entries
        )

        guard let data = try? JSONEncoder().encode(persistedState) else {
            return
        }

        UserDefaults.standard.set(data, forKey: Self.persistedStateKey)
    }

    private func restorePersistedState() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistedStateKey),
              let persistedState = try? JSONDecoder().decode(PersistedWatchState.self, from: data) else {
            UserDefaults.standard.removeObject(forKey: Self.persistedStateKey)
            return
        }

        isRestoringPersistedState = true
        entries = persistedState.entries
        statusMessage = persistedState.statusMessage
        isSending = false
        isCapturingVoice = false
        isRestoringPersistedState = false
    }

    private func playHaptic(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }

    private func refreshStatus(using session: WCSession) {
        if isCapturingVoice {
            statusMessage = "Listening…"
        } else if isSending {
            statusMessage = "Sending to iPhone…"
        } else if session.activationState != .activated {
            statusMessage = "Connecting to iPhone..."
        } else if session.isReachable {
            statusMessage = "Ready on iPhone."
        } else if session.isCompanionAppInstalled {
            statusMessage = "Open the iPhone app."
        } else {
            statusMessage = "Install the iPhone app."
        }
    }
}

enum WatchStateSummary {
    case listening
    case sending
    case queued
    case ready
    case disconnected
    case error

    var label: String {
        switch self {
        case .listening:
            return "Listening"
        case .sending:
            return "Sending"
        case .queued:
            return "Queued"
        case .ready:
            return "Ready"
        case .disconnected:
            return "iPhone"
        case .error:
            return "Error"
        }
    }

    var iconName: String {
        switch self {
        case .listening:
            return "waveform"
        case .sending:
            return "arrow.up.circle"
        case .queued:
            return "clock"
        case .ready:
            return "checkmark.circle"
        case .disconnected:
            return "iphone.slash"
        case .error:
            return "exclamationmark.circle"
        }
    }
}

private struct PersistedWatchState: Codable {
    let statusMessage: String
    let isSending: Bool
    let isCapturingVoice: Bool
    let entries: [WatchChatEntry]
}

extension WatchConnectivityClient: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.activationState = activationState
            self.isReachable = session.isReachable
            self.statusMessage = error?.localizedDescription ?? self.statusMessage
            self.refreshStatus(using: session)
            if error == nil {
                self.flushDeferredRequests(using: session)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            self.refreshStatus(using: session)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        Task { @MainActor in
            do {
                let response = try WatchConnectivityCodec.decodeMessage(
                    WatchPromptResponse.self,
                    from: userInfo,
                    key: WatchConnectivityPayloadKey.response
                )
                self.apply(response: response)
            } catch {
                self.statusMessage = error.localizedDescription
            }
        }
    }
}

struct WatchChatEntry: Identifiable, Equatable, Codable {
    enum PendingState: Equatable, Codable {
        case sending
        case queued
    }

    let id: UUID
    let requestID: UUID
    let role: Role
    let content: String
    let conversationID: UUID?
    let modelName: String?
    let pendingState: PendingState?
    let respondedAt: Date?
    let isError: Bool

    var isPending: Bool {
        pendingState != nil
    }

    enum Role: Codable {
        case user
        case assistant
    }

    static func user(prompt: String, requestID: UUID) -> WatchChatEntry {
        WatchChatEntry(
            id: UUID(),
            requestID: requestID,
            role: .user,
            content: prompt,
            conversationID: nil,
            modelName: nil,
            pendingState: nil,
            respondedAt: nil,
            isError: false
        )
    }

    static func assistantPlaceholder(
        id: UUID,
        requestID: UUID,
        state: PendingState
    ) -> WatchChatEntry {
        WatchChatEntry(
            id: id,
            requestID: requestID,
            role: .assistant,
            content: state == .sending ? "Waiting for iPhone..." : "Queued for iPhone...",
            conversationID: nil,
            modelName: nil,
            pendingState: state,
            respondedAt: nil,
            isError: false
        )
    }

    static func assistant(
        id: UUID,
        requestID: UUID,
        content: String,
        conversationID: UUID?,
        modelName: String?,
        respondedAt: Date?,
        isError: Bool
    ) -> WatchChatEntry {
        WatchChatEntry(
            id: id,
            requestID: requestID,
            role: .assistant,
            content: content,
            conversationID: conversationID,
            modelName: modelName,
            pendingState: nil,
            respondedAt: respondedAt,
            isError: isError
        )
    }

    func updatingPendingState(_ state: PendingState, content: String) -> WatchChatEntry {
        WatchChatEntry(
            id: id,
            requestID: requestID,
            role: role,
            content: content,
            conversationID: conversationID,
            modelName: modelName,
            pendingState: state,
            respondedAt: respondedAt,
            isError: isError
        )
    }
}
