import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import Shimmer

private struct ChatModelFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ChatView: View {
    @Environment(LLMEngine.self) private var llmEngine
    @Environment(ChatHistoryManager.self) private var historyManager
    @Environment(ModelManager.self) private var modelManager
    @Environment(SpeechManager.self) private var speechManager
    @Environment(AssistantMemoryStore.self) private var memoryStore
    @Environment(MonetizationManager.self) private var monetizationManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var documentManager = DocumentManager.shared

    /// Binding populated by Siri via ContentView. When non-nil, the query is
    /// auto-filled in the text field and sent. Reset to nil after handling.
    @Binding var siriPendingQuery: String?

    init(siriPendingQuery: Binding<String?> = .constant(nil)) {
        _siriPendingQuery = siriPendingQuery
    }

    @State private var messageText = ""
    @State private var isFileImporterPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var documentImportState: DocumentImportState = .idle
    @AppStorage("autoRead") private var autoRead = false

    // Deliberately not persisted: a voice session is ephemeral, and restoring
    // it at launch would present the full-screen voice UI with a live
    // microphone before the user asked for it.
    @State private var voiceConversationMode = false
    @State private var showExportSheet = false
    @FocusState private var isInputFocused: Bool
    @State private var showModelDownloadSheet = false
    @State private var showModelConsentSheet = false
    @State private var showAttachmentOptions = false
    @State private var shouldSendAfterConsent = false
    @State private var upgradeFeature: PremiumFeature?
    @State private var documentError: String?
    @State private var voiceError: String?
    @State private var usageLimitToastMessage: String?
    @State private var extractionNoticeMessage: String?
    @State private var modelRecoveryNoticeMessage: String?
    @State private var runtimePerformanceToast: RuntimePerformanceStatus?
    @State private var runtimePerformanceDismissTask: Task<Void, Never>?
    @State private var performanceStatusRevision = 0
    @State private var recentMemoryPressure = false
    @State private var contextLimitWarningDismissed = false
    @State private var streamingPrefix = ""
    @State private var speechStreamingSpokenCharCount: Int = 0
    @State private var selectedImage: UIImage?
    @State private var selectedImageData: Data?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoItemAwaitingUpgrade: PhotosPickerItem?
    @State private var activeStreamingConversationID: UUID?
    @State private var activeStreamingAssistantID: UUID?
    @State private var pendingSessionReset = false
    @State private var activeGenerationSessionScope: GenerationSessionScope?
    @State private var lastGenerationWasEphemeral: Bool = false
    @State private var activeMlxVisionImageKey: String?
    @State private var selectedDocumentForSources: ConversationDocument?
    /// Section titles to badge when the sources sheet is opened from a reply's
    /// "Show Sources"; cleared when it is opened from the attachment chip.
    @State private var sourceHighlightTitles: Set<String> = []
    /// Set while a document removal awaits the user's confirmation.
    @State private var documentPendingRemoval: ConversationDocument?
    /// What the document pipeline is doing before generation starts, shown as a
    /// capsule like `warmingUpIndicator`. Nil outside document retrieval.
    @State private var retrievalStatus: String?
    @State private var generatedFollowUpSuggestions: [UUID: [String]] = [:]
    @State private var postResponseEnrichmentTask: Task<Void, Never>?
    @State private var streamingState = ChatStreamingState()
    // Scroll state: whether the view should follow new content at the
    // bottom. The list itself lays out naturally from the top; while
    // "following", streamed content triggers a plain (non-animated)
    // scrollTo("bottom") so the newest text stays in view. A user who
    // scrolls up to re-read history stops following and isn't yanked
    // back down; reaching the bottom again resumes following.
    @State private var isFollowingBottom = true
    // Mirrors the scroll geometry's "near bottom" test so the stop-follow
    // drag gesture can tell a real scroll-up (content moved away from the
    // bottom) from a keyboard-dismiss swipe (finger moves down but the
    // content stays at the bottom, so this stays true).
    @State private var isScrollNearBottom = true
    @AppStorage("systemPrompt") private var systemPrompt = AIResponseDefaults.defaultSystemPrompt
    @AppStorage("responseCharacterLimit") private var responseCharacterLimit = AIResponseDefaults.responseCharacterLimit
    @AppStorage("smartReplyStylesEnabled") private var smartReplyStylesEnabled = false
    @AppStorage("inChatSearchEnabled") private var inChatSearchEnabled = true

    @State private var editingMessage: ChatMessage?
    @State private var editedMessageText: String = ""
    // TextEditor is backed by UITextView, which can retain its rendered text
    // across sheet presentations. Give every editing session its own identity
    // so the UIKit view is recreated with the current binding value.
    @State private var editComposerSessionID = UUID()
    @State private var isEditSheetPresented = false
    @State private var inChatSearchText: String = ""
    @State private var isInChatSearchActive = false
    @FocusState private var isSearchFieldFocused: Bool
    /// Cached in-chat search matches in conversation order, rebuilt by
    /// `recomputeInChatSearchMatches()` when `inChatSearchCacheKey` changes.
    @State private var inChatSearchMatchIDs: [UUID] = []
    @State private var inChatSearchMatchIDSet: Set<UUID> = []
    /// Position within `inChatSearchMatchIDs` that the match chevrons point at.
    @State private var inChatSearchMatchIndex = 0

    /// Set when a history search result is tapped; scrolls the chat to that message.
    @State private var pendingSearchJump: SearchJumpTarget?
    /// The message currently flashing after a search jump.
    @State private var highlightedMessageID: UUID?

    private struct SearchJumpTarget: Equatable {
        let conversationID: UUID
        let messageID: UUID
        let query: String
        /// Distinguishes repeat taps on the same result, which must re-trigger the jump.
        let requestID: UUID
    }

    /// A message the user sent while the selected model was still
    /// downloading; it auto-sends once a usable model becomes available.
    @State private var queuedFirstMessage: String?


    // MARK: - Shared Haptic Generators (avoid per-tap allocation)
    private static let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private static let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)

    private struct GenerationSessionScope: Equatable {
        let modelID: String
        let conversationID: UUID?
        let documentSignature: String
    }

    private enum DocumentImportState {
        case idle
        case extracting(id: UUID, fileName: String, task: Task<Void, Never>)
        case indexing(id: UUID, fileName: String, task: Task<Void, Never>)

        var isActive: Bool {
            if case .idle = self { return false }
            return true
        }

        var canCancel: Bool {
            if case .extracting = self { return true }
            return false
        }

        var fileName: String? {
            if case .extracting(_, let fileName, _) = self { return fileName }
            if case .indexing(_, let fileName, _) = self { return fileName }
            return nil
        }

        var statusText: String {
            switch self {
            case .idle:
                return ""
            case .extracting(_, let fileName, _):
                if fileName.lowercased().hasSuffix(".pdf") {
                    return String(localized: "Reading PDF…")
                }
                return String(localized: "Reading document…")
            case .indexing:
                return String(localized: "Indexing document…")
            }
        }

    }
    
    var body: some View {
        alertContent
    }

    private var alertContent: some View {
        modalContent
            .alert("Document Error", isPresented: documentErrorBinding) {
                Button("OK", role: .cancel) { documentError = nil }
            } message: {
                Text(documentError ?? String(localized: "An unknown error occurred."))
            }
            .alert("Voice Error", isPresented: voiceErrorBinding) {
                Button("OK", role: .cancel) { voiceError = nil }
            } message: {
                Text(voiceError ?? String(localized: "Voice input is unavailable."))
            }
            .onChange(of: voiceConversationMode) {
                if voiceConversationMode {
                    guard SpeechManager.isVoiceConversationEnabled else {
                        voiceConversationMode = false
                        return
                    }
                    guard monetizationManager.canUse(.voiceMode) else {
                        voiceConversationMode = false
                        upgradeFeature = .voiceMode
                        return
                    }
                    speechManager.autoStopAfterSilence = true
                    // Warm the model now so it loads while the user speaks their
                    // first sentence, rather than paying that latency after the
                    // transcript is finalized. Idempotent and guarded.
                    prewarmModel()
                    startListeningIfPossible()
                } else {
                    speechManager.autoStopAfterSilence = false
                    // Partial transcripts mirror into the input field while
                    // listening; drop them so ending the session doesn't leave
                    // half a sentence in the compose box.
                    if !speechManager.transcribedText.isEmpty,
                       messageText == speechManager.transcribedText {
                        messageText = ""
                    }
                    speechManager.stopListening()
                    speechManager.stopSpeaking()
                    speechManager.releaseAudioSessionIfIdle()
                    // Keep the completed voice conversation visible. Starting a
                    // fresh chat remains an explicit user action in the toolbar.
                }
            }
            // The voice screen is a cover over the chat, so the conversation
            // loop handlers on this view keep running behind it.
            .fullScreenCover(isPresented: $voiceConversationMode) {
                VoiceConversationView(
                    isActive: $voiceConversationMode,
                    onStartListening: startListeningIfPossible
                )
            }
            .onChange(of: siriPendingQuery) {
                guard let query = siriPendingQuery,
                      !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return }
                siriPendingQuery = nil
                messageText = query
                sendMessage()
            }
            // First message queued while the model was still downloading:
            // send it the moment a usable model appears. Also retries when
            // the engine finishes loading, in case the model became usable
            // while a prewarm was still holding the send gate closed.
            .onChange(of: modelManager.selectedModel?.id) {
                attemptQueuedSend()
            }
            .onChange(of: llmEngine.state) {
                attemptQueuedSend()
            }
            // If the download fails, hand the queued text back to the input
            // instead of leaving it stranded.
            .onChange(of: pendingSelectedModel?.downloadState) {
                guard let queued = queuedFirstMessage,
                      case .error = pendingSelectedModel?.downloadState
                else { return }
                queuedFirstMessage = nil
                messageText = queued
            }
    }

    private var modalContent: some View {
        lifecycleContent
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.pdf, .image, .text, .plainText, .sourceCode, .rtf, .rtfd, .docx, .markdown, .jsonDocument, .commaSeparatedText, .logText],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result: result)
            }
            .photosPicker(
                isPresented: $isPhotoPickerPresented,
                selection: $selectedPhotoItem,
                matching: .images,
                photoLibrary: .shared()
            )
            .alert(String(localized: "Microphone Access Required"), isPresented: Bindable(speechManager).showPermissionAlert) {
                Button(String(localized: "Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) { }
            } message: {
                Text(String(localized: "Please enable microphone and speech recognition access in Settings to use voice input."))
            }
            .sheet(isPresented: $showModelDownloadSheet) {
                NavigationStack {
                    ModelDownloadView()
                }
                .environment(llmEngine)
                .environment(modelManager)
                .environment(monetizationManager)
            }
            .sheet(isPresented: $showModelConsentSheet) {
                if let selectedModel = modelManager.selectedModel {
                    ModelConsentSheet(model: selectedModel) {
                        setConsent(for: selectedModel.id)
                        showModelConsentSheet = false
                        if shouldSendAfterConsent {
                            shouldSendAfterConsent = false
                            performSendMessage()
                        }
                    } onCancel: {
                        showModelConsentSheet = false
                        shouldSendAfterConsent = false
                    }
                } else {
                    Text(String(localized: "No model selected."))
                        .padding()
                }
            }
            .sheet(item: $upgradeFeature) { feature in
                UpgradeView(feature: feature) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        switch feature {
                        case .unlimitedMessages:
                            sendMessage()
                        case .imageInput:
                            guard let item = photoItemAwaitingUpgrade else { return }
                            photoItemAwaitingUpgrade = nil
                            processPhotoItem(item)
                        case .voiceMode:
                            requestVoiceConversation()
                        default:
                            break
                        }
                    }
                }
                    .environment(monetizationManager)
            }
            .sheet(item: $selectedDocumentForSources) { document in
                DocumentSourceDrawerView(
                    document: document,
                    highlightedSectionTitles: sourceHighlightTitles
                )
            }
            .sheet(isPresented: $isEditSheetPresented, onDismiss: {
                editingMessage = nil
                editedMessageText = ""
            }) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            editSheetHeader

                            if let editingMessage {
                                originalMessageCard(message: editingMessage)
                            }

                            editComposerCard
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                    }
                    .background(
                        LinearGradient(
                            colors: [
                                Color.adaptive(white: 0.98),
                                Color.adaptive(white: 0.95),
                                Color.adaptive(white: 0.98)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .ignoresSafeArea()
                    )
                    .navigationTitle(String(localized: "Edit Message"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "Cancel")) { isEditSheetPresented = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Re-run")) {
                                applyEditedMessageAndRerun()
                            }
                            .disabled(editedMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.thinMaterial)
                .onAppear {
                    if let editingMessage {
                        editedMessageText = editingMessage.content
                    }
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if let usageLimitToastMessage {
                        usageLimitToast(message: usageLimitToastMessage)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if let extractionNoticeMessage {
                        extractionNoticeToast(message: extractionNoticeMessage)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if let modelRecoveryNoticeMessage {
                        modelRecoveryToast(message: modelRecoveryNoticeMessage)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if let status = runtimePerformanceToast {
                        runtimePerformancePill(status, onDismiss: dismissRuntimePerformanceToast)
                    }

                    if speechManager.isPreparingSpeechOutput {
                        preparingVoicePill
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if let notice = modelManager.lastAutoSelectionNotice {
                        AutoSelectionToastView(
                            message: notice.message,
                            autoDismissAfter: ModelManager.autoSelectionNoticeDuration,
                            onDismiss: {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    modelManager.dismissAutoSelectionNotice(notice.id)
                                }
                            }
                        )
                        .id(notice.id)
                        .transition(toastTransition)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 110)
            }
    }

    private var lifecycleContent: some View {
        baseContent
            .onAppear {
                migrateFullResponseDefaultsIfNeeded()
                prewarmModel()
                // Load the selected Kokoro voice ahead of the first Speak /
                // voice session. Skipped on 4 GB phones, where the ~330 MB
                // would compete with the chat model; they pay a one-time
                // "Preparing voice…" on first use instead. No-op unless a
                // Kokoro voice is selected and already downloaded.
                if autoRead || !DeviceResourcePolicy.current.isLowMemoryPhone {
                    speechManager.prewarmSpeechOutputIfNeeded()
                }
                showRuntimePerformanceToastIfNeeded(runtimePerformanceStatus)
            }
            .onDisappear {
                speechManager.stopSpeaking()
                cancelDocumentExtraction(showError: false)
                postResponseEnrichmentTask?.cancel()
                postResponseEnrichmentTask = nil
                runtimePerformanceDismissTask?.cancel()
                runtimePerformanceDismissTask = nil
            }
            .onChange(of: runtimePerformanceStatus) { _, status in
                showRuntimePerformanceToastIfNeeded(status)
            }
            .onChange(of: modelManager.selectedModelID) {
                invalidateGenerationSessionScope()
                contextLimitWarningDismissed = false
                if llmEngine.state == .generating {
                    pendingSessionReset = true
                } else {
                    llmEngine.resetSession()
                }
                prewarmModel()
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                performanceStatusRevision += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
                performanceStatusRevision += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                recentMemoryPressure = true
                performanceStatusRevision += 1
                postResponseEnrichmentTask?.cancel()
                postResponseEnrichmentTask = nil
                speechManager.prioritizeInteractiveChat(
                    preserveVoiceFeatures: voiceConversationMode
                )
                Task {
                    await EmbeddingService.shared.unload()
                }
                Task {
                    try? await Task.sleep(for: .seconds(60))
                    recentMemoryPressure = false
                    performanceStatusRevision += 1
                }
            }
            .onChange(of: historyManager.currentConversationID) {
                speechManager.stopSpeaking()
                invalidateGenerationSessionScope()
                contextLimitWarningDismissed = false
                if llmEngine.state == .generating {
                    pendingSessionReset = true
                } else {
                    llmEngine.resetSession()
                }
            }
            .onChange(of: speechManager.transcribedText) {
                if !speechManager.transcribedText.isEmpty {
                    messageText = speechManager.transcribedText
                }
                // Barge-in: once the user has clearly started talking (not a
                // stray phoneme picked up over the reply) while the assistant
                // is still speaking, cut it off immediately instead of
                // waiting for the reply to finish.
                if voiceConversationMode, speechManager.isSpeaking,
                   speechManager.transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 {
                    speechManager.stopSpeaking()
                }
            }
            .onChange(of: speechManager.isSpeaking) {
                guard voiceConversationMode, speechManager.isSpeaking else { return }
                // Arm the mic the instant the reply starts, rather than after
                // it finishes, so the user can interrupt by talking over it.
                guard !speechManager.isListening else { return }
                startListeningIfPossible()
            }
            .onChange(of: speechManager.finalTranscriptionVersion) {
                guard voiceConversationMode else { return }
                let transcription = speechManager.lastFinalTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !transcription.isEmpty else { return }
                messageText = transcription
                sendMessage()
            }
            .onChange(of: speechManager.errorVersion) {
                guard let message = speechManager.errorMessage, !message.isEmpty else { return }
                voiceError = message
                voiceConversationMode = false
            }
            .onChange(of: speechManager.speechCompletionVersion) {
                guard voiceConversationMode else { return }
                guard llmEngine.state != .generating else { return }
                guard !speechManager.isListening else { return }
                guard speechManager.isSpeechQueueEmpty else { return }
                startListeningIfPossible()
            }
    }

    private func migrateFullResponseDefaultsIfNeeded() {
        AIResponseSettingsMigration.migrateIfNeeded()
    }

    private var baseContent: some View {
        ZStack {
            // Background Gradient
            backgroundView
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // In-chat search bar
                if isInChatSearchActive {
                    inChatSearchBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Messages area
                messagesView
                
                // Input area
                inputView
            }

            if llmEngine.isPrewarming && !historyManager.currentMessages.isEmpty {
                VStack {
                    warmingUpIndicator
                        .padding(.top, 12)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Document retrieval happens before the reply placeholder exists, so
            // without this the send button goes quiet for the whole search —
            // on-device query embedding included — and the app reads as hung
            // exactly while it does its most distinctive work.
            if let retrievalStatus, !llmEngine.isPrewarming {
                VStack {
                    retrievalStatusIndicator(retrievalStatus)
                        .padding(.top, 12)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if showAttachmentOptions {
                // Dimmed background backdrop
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            showAttachmentOptions = false
                        }
                    }
                
                // Attachment popup container
                VStack {
                    Spacer()
                    
                    AttachmentOptionsPopup(
                        onPhotoPicker: {
                            guard guardCanAddPhoto(action: String(localized: "adding a photo")) else { return }
                            dismissKeyboard()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                showAttachmentOptions = false
                            }
                            isPhotoPickerPresented = true
                        },
                        onDocumentImport: {
                            guard guardCanAddDocument(action: String(localized: "adding a document")) else { return }
                            dismissKeyboard()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                showAttachmentOptions = false
                            }
                            isFileImporterPresented = true
                        },
                        onCancel: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                showAttachmentOptions = false
                            }
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.92)),
                    removal: .opacity.combined(with: .scale(scale: 0.95))
                ))
                .zIndex(100)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if inChatSearchEnabled && !historyManager.currentMessages.isEmpty {
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            isInChatSearchActive.toggle()
                            if !isInChatSearchActive {
                                inChatSearchText = ""
                                isSearchFieldFocused = false
                            }
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.body.weight(.medium))
                            .foregroundStyle(isInChatSearchActive ? Color.blue : Color.adaptive(white: 0.3))
                            .frame(width: 44, height: 44)
                            .background(Color.adaptive(white: 0.95))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("f", modifiers: [.command])
                    .accessibilityLabel(String(localized: "Search in conversation"))
                }
            }
        }
        .onChange(of: inChatSearchEnabled) {
            guard !inChatSearchEnabled else { return }
            inChatSearchText = ""
            isInChatSearchActive = false
        }
        // A new query, chat, or message restarts stepping from the first hit.
        .onChange(of: inChatSearchCacheKey, initial: true) {
            recomputeInChatSearchMatches()
        }
        .onChange(of: inChatSearchText) {
            inChatSearchMatchIndex = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .ownAIConversationSearchMatch)) { notification in
            guard let conversationID = notification.userInfo?[ConversationSearchMatchKey.conversationID] as? UUID,
                  let messageID = notification.userInfo?[ConversationSearchMatchKey.messageID] as? UUID
            else { return }

            let query = notification.userInfo?[ConversationSearchMatchKey.query] as? String ?? ""
            pendingSearchJump = SearchJumpTarget(
                conversationID: conversationID,
                messageID: messageID,
                query: query,
                requestID: UUID()
            )
        }
    }

    private var warmingUpIndicator: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption.weight(.semibold))

            Text(String(localized: "Warming up"))
                .font(.caption.weight(.semibold))
                .shimmering(active: !reduceMotion, bandSize: 0.22)
        }
        .foregroundStyle(.blue)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.adaptiveBorder(opacity: 0.45), lineWidth: 1)
        )
        .accessibilityLabel(String(localized: "Warming up"))
    }

    private func retrievalStatusIndicator(_ status: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.caption.weight(.semibold))

            Text(status)
                .font(.caption.weight(.semibold))
                .shimmering(active: !reduceMotion, bandSize: 0.22)
        }
        .foregroundStyle(.blue)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.adaptiveBorder(opacity: 0.45), lineWidth: 1)
        )
        .accessibilityLabel(status)
    }

    // MARK: - In-Chat Search

    private var inChatSearchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.medium))
                .foregroundStyle(Color.adaptive(white: 0.45))
                .accessibilityHidden(true)

            TextField(String(localized: "Search in conversation…"), text: $inChatSearchText)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isSearchFieldFocused)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { stepInChatSearchMatch(by: 1) }

            if !inChatSearchText.isEmpty {
                let matchIDs = inChatSearchMatchIDs

                Text(matchIDs.isEmpty
                     ? String(localized: "No matches")
                     : "\(inChatSearchMatchIndex + 1)/\(matchIDs.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.adaptive(white: 0.5))
                    .fixedSize()

                HStack(spacing: 2) {
                    Button {
                        stepInChatSearchMatch(by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.caption.weight(.bold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(String(localized: "Previous match"))

                    Button {
                        stepInChatSearchMatch(by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(String(localized: "Next match"))
                }
                .buttonStyle(.plain)
                .foregroundStyle(matchIDs.count > 1 ? Color.blue : Color.adaptive(white: 0.6))
                .disabled(matchIDs.count < 2)
            }

            Button {
                isSearchFieldFocused = false
                withAnimation(.spring(response: 0.3)) {
                    inChatSearchText = ""
                    isInChatSearchActive = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(Color.adaptive(white: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Close search"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .onAppear { isSearchFieldFocused = true }
    }

    /// Recomputes the cached in-chat matches. Every per-message lookup below
    /// reads the cache, so a render costs one pass over the conversation rather
    /// than one pass per message.
    private func recomputeInChatSearchMatches() {
        let tokens = ConversationSearchEngine.tokens(for: inChatSearchText)
        guard isInChatSearchActive, !tokens.isEmpty else {
            inChatSearchMatchIDs = []
            inChatSearchMatchIDSet = []
            inChatSearchMatchIndex = 0
            return
        }

        inChatSearchMatchIDs = historyManager.currentMessages
            .filter { ConversationSearchEngine.containsAllTokens($0.content, tokens: tokens) }
            .map(\.id)
        inChatSearchMatchIDSet = Set(inChatSearchMatchIDs)

        if inChatSearchMatchIndex >= inChatSearchMatchIDs.count {
            inChatSearchMatchIndex = 0
        }
    }

    /// Invalidates the match cache whenever the query, chat, or message list changes.
    private var inChatSearchCacheKey: String {
        let conversationID = historyManager.currentConversationID?.uuidString ?? ""
        return "\(isInChatSearchActive)|\(inChatSearchText)|\(conversationID)|\(historyManager.currentMessages.count)"
    }

    /// The match the up/down chevrons are currently parked on.
    private var inChatSearchActiveMatchID: UUID? {
        guard inChatSearchMatchIndex < inChatSearchMatchIDs.count else { return nil }
        return inChatSearchMatchIDs[inChatSearchMatchIndex]
    }

    /// Moves to the next/previous match, wrapping around at either end.
    private func stepInChatSearchMatch(by offset: Int) {
        let count = inChatSearchMatchIDs.count
        guard count > 0 else { return }
        Self.lightHaptic.impactOccurred()
        inChatSearchMatchIndex = ((inChatSearchMatchIndex + offset) % count + count) % count
    }

    /// True when the message should carry the highlight tint — either the match
    /// the chevrons are on, or a message just jumped to from history search.
    private func isSearchFocused(_ message: ChatMessage) -> Bool {
        if highlightedMessageID == message.id { return true }
        return inChatSearchActiveMatchID == message.id
    }

    private func messageMatchesSearch(_ message: ChatMessage) -> Bool {
        guard isInChatSearchActive, !inChatSearchText.isEmpty else { return true }
        return inChatSearchMatchIDSet.contains(message.id)
    }

    private var documentErrorBinding: Binding<Bool> {
        Binding(
            get: { documentError != nil },
            set: { if !$0 { documentError = nil } }
        )
    }

    private var voiceErrorBinding: Binding<Bool> {
        Binding(
            get: { voiceError != nil },
            set: { if !$0 { voiceError = nil } }
        )
    }

    private func dismissKeyboard() {
        isInputFocused = false
    }
    
    private func prewarmModel() {
        guard let model = modelManager.selectedModel else { return }
        Task {
            await llmEngine.prewarmIfNeeded(model: model)
        }
        // Warm the Whisper model in the background so the first mic tap is
        // instant instead of paying the ~1 min Core ML load. Only when Whisper
        // is the active backend and the model is already on disk.
        if speechManager.speechInputBackend == .whisper, speechManager.isWhisperModelDownloaded {
            Task {
                await speechManager.prepareTranscriptionIfNeeded(downloadIfNeeded: false)
            }
        }
    }
    
    private var backgroundView: some View {
        AnimatedChatBackgroundView(isEmpty: historyManager.currentMessages.isEmpty)
    }
    
    // MARK: - Messages View
    
    private func deleteMessage(_ message: ChatMessage) {
        withAnimation(.spring(response: 0.3)) {
            historyManager.deleteMessage(id: message.id)
        }
    }


    /// One message row. Kept out of `messagesView` because the row and the
    /// surrounding scroll chain together exceed what the type checker will
    /// solve as a single expression.
    @ViewBuilder
    private func messageRow(for message: ChatMessage) -> some View {
        let recoveryAction = retryAction(for: message)
        MessageBubble(
            message: message,
            showsContinue: canContinue(message),
            onContinue: canContinue(message) ? { continueResponse(for: message) } : nil,
            recoveryAction: recoveryAction,
            onEdit: { message in
                startEdit(message)
            },
            onRegenerateMore: { message in
                regenerate(message: message, style: .more)
            },
            onRegenerateLess: { message in
                regenerate(message: message, style: .less)
            },
            smartReplyStyles: smartReplyStyles(for: message),
            onSmartReplyStyle: { message, style in
                regenerate(message: message, style: style)
            },
            followUpSuggestions: followUpSuggestions(for: message),
            onBranchFromHere: { message in
                branchConversation(from: message)
            },
            onTogglePin: { message in
                historyManager.togglePinned(messageID: message.id, in: historyManager.currentConversationID)
            },
            onSpeak: { message in
                if speechManager.isSpeaking && speechManager.currentlySpeakingMessageID == message.id {
                    speechManager.stopSpeaking()
                } else {
                    speechManager.speak(message.content, messageID: message.id)
                }
            },
            onSearchWeb: { message in
                if let url = URL(string: "https://www.google.com/search?q=\(message.content.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                    UIApplication.shared.open(url)
                }
            },
            onFollowUp: { _, followUpText in
                messageText = followUpText
                sendMessage()
            },
            onShowSources: { message in
                showSources(for: message)
            },
            showsQuickActions: message.role == .assistant
                && historyManager.currentMessages.last?.id == message.id
                && !message.isStreaming
                && canStartChatRequest,
            // Keep the bubble on the live streaming buffer
            // until the message is finalized — the persisted
            // message.content stays empty during streaming
            // (persistStreamingSnapshot doesn't publish it),
            // so gating on the engine-cleared
            // activeStreamingAssistantID handed off to an
            // empty placeholder for a frame and blanked the
            // reply. message.isStreaming flips false exactly
            // when the final text is written, so the handoff
            // is seamless.
            streamingState: message.isStreaming
                && streamingState.assistantID == message.id
                ? streamingState
                : nil,
            onDelete: deleteMessage
        )
            .id(message.id)
            .opacity(messageMatchesSearch(message) ? 1.0 : 0.25)
            .animation(.easeInOut(duration: 0.2), value: inChatSearchText)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.orange.opacity(isSearchFocused(message) ? 0.16 : 0))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -6)
            )
            .animation(.easeInOut(duration: 0.35), value: highlightedMessageID)
            .animation(.easeInOut(duration: 0.2), value: inChatSearchActiveMatchID)
    }

    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    // Top anchor for resetting scroll
                    Color.clear
                        .frame(height: 1)
                        .id("top")
                        
                    if historyManager.currentMessages.isEmpty {
                        emptyStateView
                    } else {
                        ForEach(historyManager.currentMessages) { message in
                            messageRow(for: message)
                        }

                        if let speakableMessage = latestSpeakableAssistantMessage {
                            speakReplyButton(for: speakableMessage)
                        }
                    }
                    
                    // Persistent bottom anchor for scrolling
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            // While following, let the system hold the bottom edge in place
            // as streamed content grows. This happens inside the layout
            // pass, unlike a scrollTo issued after the fact, so it can't
            // lag the reflow and flicker. Scoped to .sizeChanges only —
            // no .alignment role — so the list still lays out naturally
            // from the top and short conversations aren't bottom-hugging.
            .defaultScrollAnchor(isFollowingBottom ? .bottom : nil, for: .sizeChanges)
            // Resume following when the user scrolls (or is auto-scrolled)
            // back near the bottom. This direction only sets
            // isFollowingBottom = true — never false. Driving "false" from
            // geometry too was a past bug: while streaming, each new line
            // wraps and grows contentSize before contentOffset catches up,
            // so distanceFromBottom spikes for a frame even though the user
            // did nothing.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let distanceFromBottom = geometry.contentSize.height
                    - geometry.containerSize.height
                    - geometry.contentOffset.y
                return distanceFromBottom < 48
            } action: { _, isNearBottom in
                isScrollNearBottom = isNearBottom
                guard isNearBottom, !isFollowingBottom else { return }
                chatDiagnostic("scroll followingBottom false -> true (reached bottom)")
                isFollowingBottom = true
            }
            // The only thing that should stop the follow is the user
            // deliberately dragging the list (revealing earlier messages).
            // Tied to an actual touch gesture instead of geometry so it
            // can't be confused with content growing under a stationary
            // viewport. The isScrollNearBottom check filters out the
            // interactive keyboard-dismiss swipe: that drag also moves
            // down, but the content never leaves the bottom.
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard value.translation.height > 12, isFollowingBottom,
                              !isScrollNearBottom else { return }
                        chatDiagnostic("scroll followingBottom true -> false (user dragged)")
                        isFollowingBottom = false
                    }
            )
            .onChange(of: historyManager.currentMessages.count) {
                // A new message (the user's own send, or the assistant
                // placeholder that follows it) always resumes following and
                // jumps to bottom — this is a deliberate, discrete event,
                // so a single animated scroll is correct.
                scrollToBottomForced(proxy: proxy)
            }
            .onChange(of: llmEngine.state) { oldState, newState in
                chatDiagnostic("engine state \(diagnosticDescription(for: oldState)) -> \(diagnosticDescription(for: newState))")
                // Only clear the streaming IDs when generation actually ENDS.
                // Clearing on every non-generating state wiped them during the
                // model-load (.loading/.ready) that runs after the IDs are set
                // but before generation begins — which broke live streaming into
                // the bubble (the final reply still showed via the direct write).
                if oldState == .generating && newState != .generating {
                    activeStreamingConversationID = nil
                    activeStreamingAssistantID = nil
                }
                if newState != .generating, pendingSessionReset {
                    pendingSessionReset = false
                    llmEngine.resetSession()
                    invalidateGenerationSessionScope()
                }
                // No scroll call here: the `currentMessages.count` and
                // `currentResponse` handlers already cover every moment the
                // content actually changes. A scroll tied to engine state
                // too used to race those with a different animation curve,
                // which is what produced the visible bounce.
            }
            .onChange(of: historyManager.currentConversationID) {
                isFollowingBottom = true
                scrollToTop(proxy: proxy)
            }
            .onChange(of: pendingSearchJump) { _, target in
                guard let target else { return }
                Task { await performSearchJump(target, proxy: proxy) }
            }
            // Keep the current in-chat search hit in view as the user steps
            // through matches (and when the first hit appears while typing).
            .onChange(of: inChatSearchActiveMatchID) { _, matchID in
                guard isInChatSearchActive, let matchID else { return }
                isFollowingBottom = false
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    proxy.scrollTo(matchID, anchor: .center)
                }
            }
            .overlay(alignment: .bottom) {
                jumpToBottomButton(proxy: proxy)
            }
        }
    }

    /// Way back to the newest message once the user has scrolled up. Without it
    /// a reply that keeps streaming off-screen leaves no way down but a long
    /// manual drag. Hidden while already following the tail.
    @ViewBuilder
    private func jumpToBottomButton(proxy: ScrollViewProxy) -> some View {
        let isVisible = !isFollowingBottom
            && !isScrollNearBottom
            && !historyManager.currentMessages.isEmpty
            && !isInChatSearchActive

        Button {
            scrollToBottomForced(proxy: proxy)
        } label: {
            Image(systemName: "chevron.down")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.adaptive(white: 0.25))
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(Color.adaptiveBorder(opacity: 0.5), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(String(localized: "Scroll to latest message"))
        .padding(.bottom, 8)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.8)
        .allowsHitTesting(isVisible)
        .animation(
            reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8),
            value: isVisible
        )
    }

    /// Scrolls to the message a history search matched and flashes it briefly.
    ///
    /// Runs after a short delay so the conversation switch (which resets the
    /// scroll to the top) and the sheet dismissal have both settled first.
    private func performSearchJump(_ target: SearchJumpTarget, proxy: ScrollViewProxy) async {
        try? await Task.sleep(for: .milliseconds(400))
        guard pendingSearchJump == target,
              historyManager.currentConversationID == target.conversationID,
              historyManager.containsMessage(target.messageID, in: target.conversationID)
        else { return }

        // The target is usually above the bottom, so stop following the tail —
        // otherwise the next layout pass would yank the view back down.
        isFollowingBottom = false

        if inChatSearchEnabled, !target.query.isEmpty {
            inChatSearchText = target.query
            isInChatSearchActive = true
        }

        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            proxy.scrollTo(target.messageID, anchor: .center)
        }
        highlightedMessageID = target.messageID

        try? await Task.sleep(for: .seconds(2.2))
        guard highlightedMessageID == target.messageID else { return }
        highlightedMessageID = nil
        pendingSearchJump = nil
    }

    private func scrollToTop(proxy: ScrollViewProxy) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            proxy.scrollTo("top", anchor: .top)
        }
    }

    /// Discrete, user-driven jump to bottom (new message sent/received,
    /// conversation switched). Always runs and resumes following, so the
    /// streaming that follows keeps the newest text in view.
    private func scrollToBottomForced(proxy: ScrollViewProxy, animated: Bool = true) {
        chatDiagnostic("scroll forced bottom (animated=\(animated))")
        isFollowingBottom = true
        let scrollAction = { proxy.scrollTo("bottom", anchor: .bottom) }
        if animated {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                scrollAction()
            }
        } else {
            scrollAction()
        }
    }

    // MARK: - Empty State
    
    private var emptyStateView: some View {
        ChatEmptyStateView(
            isInputFocused: isInputFocused,
            selectedModelName: modelManager.selectedModel?.name,
            downloadingModelName: activeDownloadingModel?.name,
            downloadProgress: activeDownloadingModel?.progress,
            downloadDetail: downloadDetailText,
            isWarmingUp: llmEngine.isPrewarming,
            isAppleIntelligenceAvailable: modelManager.isAppleIntelligenceAvailable,
            personalityLabel: currentPersonalityLabel,
            onDownloadModel: {
                showModelDownloadSheet = true
            },
            onSuggestion: { suggestion in
                messageText = suggestion.prompt
                if suggestion.requiresInput {
                    isInputFocused = true
                } else {
                    sendMessage()
                }
            },
            onVoiceConversation: voiceConversationAction
        )
    }

    /// `nil` while the voice conversation feature is hidden, which also removes
    /// the empty state's entry point.
    private var voiceConversationAction: (() -> Void)? {
        guard SpeechManager.isVoiceConversationEnabled else { return nil }
        return {
            requestVoiceConversation()
        }
    }

    private var pendingSelectedModel: ModelInfo? {
        modelManager.selectedModelID.flatMap { id in
            modelManager.models.first(where: { $0.id == id })
        }
    }

    private var activeDownloadingModel: (name: String, progress: Double?, speed: Double?, sizeGB: Double)? {
        guard let pendingSelectedModel else { return nil }
        if case .downloading(let progress, let speed) = pendingSelectedModel.downloadState {
            return (pendingSelectedModel.name, progress, speed, pendingSelectedModel.sizeGB)
        }
        if case .validating(let progress) = pendingSelectedModel.downloadState {
            return (pendingSelectedModel.name, progress, nil, pendingSelectedModel.sizeGB)
        }
        return nil
    }

    /// "42% · about 3 min left" while downloading, when speed is known.
    private var downloadDetailText: String? {
        guard let download = activeDownloadingModel, let progress = download.progress else { return nil }
        let percent = Int(progress * 100)
        guard let speed = download.speed, speed > 0, download.sizeGB > 0, progress < 1 else {
            return String(format: String(localized: "%lld%%", defaultValue: "%lld%%"), Int64(percent))
        }
        let remainingBytes = download.sizeGB * 1_000_000_000 * (1 - progress)
        let secondsLeft = remainingBytes / speed
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = secondsLeft >= 3600 ? [.hour, .minute] : (secondsLeft >= 60 ? [.minute] : [.second])
        formatter.maximumUnitCount = 2
        guard let timeText = formatter.string(from: max(secondsLeft, 1)) else {
            return String(format: String(localized: "%lld%%", defaultValue: "%lld%%"), Int64(percent))
        }
        return String(
            format: String(localized: "%lld%% · about %@ left", defaultValue: "%lld%% · about %@ left"),
            Int64(percent),
            timeText
        )
    }

    // MARK: - Input View
    
    private var inputView: some View {
        VStack(spacing: 0) {
            if !historyManager.currentMessages.isEmpty {
                Divider()
            }
            
            VStack(spacing: 8) {
                if shouldShowUsageAllowance {
                    usageAllowanceBanner
                }

                if let queuedFirstMessage {
                    queuedMessageBanner(queuedFirstMessage)
                }

                if llmEngine.state == .loading {
                    modelLoadingBanner
                }

                if shouldShowContextLimitWarning {
                    contextLimitBanner
                }

                // Documents scoped to the current chat
                if documentImportState.isActive {
                    HStack(spacing: 8) {
                        ProgressView(value: documentImportProgress)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                        Text(documentImportState.statusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if documentImportState.canCancel {
                            Button(String(localized: "Cancel")) {
                                cancelDocumentExtraction(showError: false)
                            }
                            .font(.caption2.weight(.semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .transition(.opacity)
                } else if !currentConversationDocuments.isEmpty {
                    conversationDocumentsStrip
                }

                // Image preview
                if let selectedImage {
                    imagePreviewStrip(selectedImage)
                }

                HStack(spacing: 10) {
                    Button {
                        guard guardCanStartAttachment(action: String(localized: "adding an attachment")) else { return }
                        dismissKeyboard()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            showAttachmentOptions = true
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.adaptive(white: 0.4))
                            .frame(width: 36, height: 36)
                            .background(Color.adaptive(white: 0.95))
                            .clipShape(Circle())
                    }
                    .disabled(!canStartAttachment)
                    .opacity(canStartAttachment ? 1 : 0.45)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(String(localized: "Add to chat"))
                    .accessibilityHint(String(localized: "Opens options for adding a photo, screenshot, or document."))
                    
                    // Text field
                    HStack {
                        TextField(speechManager.isListening ? String(localized: "Listening...") : String(localized: "Ask anything"), text: $messageText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...5)
                            .focused($isInputFocused)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color.adaptiveBorder(opacity: 0.5), lineWidth: 0.5)
                    )
                    
                    if llmEngine.state == .generating {
                        // Stop button during generation
                        Button(action: stopGeneration) {
                            Image(systemName: "stop.fill")
                                .font(.body.weight(.bold))
                                .foregroundStyle(Color.adaptive(white: 1))
                                .frame(width: 36, height: 36)
                                .background(Color.adaptive(white: 0))
                                .clipShape(Circle())
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel(String(localized: "Stop generating"))
                    } else if speechManager.isListening {
                        // Stop listening button
                        Button {
                            toggleListening()
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 24)) // Icon size
                                .foregroundStyle(.red)
                                .frame(width: 36, height: 36)
                                .background(Color.adaptiveCard)
                                .clipShape(Circle())
                                .overlay(
                                    Circle() // Pulsating ring
                                        .stroke(Color.red.opacity(0.5), lineWidth: 2)
                                        .scaleEffect(speechManager.isListening ? 1.4 : 1.0)
                                        .opacity(speechManager.isListening ? 0 : 1)
                                        .animation(
                                            reduceMotion
                                                ? nil
                                                : .easeOut(duration: 1).repeatForever(autoreverses: false),
                                            value: speechManager.isListening
                                        )
                                )
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel(String(localized: "Stop listening"))
                    } else if messageText.isEmpty && currentConversationDocuments.isEmpty {
                        microphoneControls
                    } else {
                        // Send button
                        Button(action: sendMessage) {
                            Image(systemName: "arrow.up")
                                .font(.body.weight(.bold))
                                .foregroundStyle(Color.adaptive(white: 1))
                                .frame(width: 36, height: 36)
                                .background(sendButtonGradient)
                                .clipShape(Circle())
                                .shadow(color: canSend ? .blue.opacity(0.3) : .clear, radius: 8, y: 4)
                        }
                        .disabled(!canSend)
                        .frame(minWidth: 44, minHeight: 44)
                        .scaleEffect(reduceMotion ? 1.0 : (canSend ? 1.0 : 0.9))
                        .animation(
                            reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7),
                            value: canSend
                        )
                        .accessibilityLabel(String(localized: "Send message"))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
                .padding(.top, currentConversationDocuments.isEmpty ? 12 : 4)
                .onChange(of: selectedPhotoItem) {
                    handlePhotoSelection()
                }

                // Character count indicator
                if messageText.count > 100 {
                    HStack {
                        Spacer()
                        Text(String(
                            format: String(localized: "%lld characters", defaultValue: "%lld characters"),
                            Int64(messageText.count)
                        ))
                            .font(.caption2.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.adaptive(white: 0.5))
                            .padding(.trailing, 20)
                            .padding(.bottom, 8)
                    }
                    .transition(.opacity)
                } else {
                    Spacer()
                        .frame(height: 8)
                }
            }
            .background(Color.clear)
        }
    }
    
    private var sendButtonGradient: LinearGradient {
        if !canSend && llmEngine.state != .generating {
            return LinearGradient(colors: [Color.adaptive(white: 0.85)], startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(colors: [Color.adaptive(white: 0)], startPoint: .top, endPoint: .bottom)
    }
    
    private var canSend: Bool {
        let hasInput = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !currentConversationDocuments.isEmpty || selectedImage != nil
        // A downloading model counts: sending then queues the message.
        let hasModel = modelManager.selectedModel != nil
            || (activeDownloadingModel != nil && queuedFirstMessage == nil)
        return hasInput && hasModel && canStartChatRequest
    }

    private var shouldShowUsageAllowance: Bool {
        !monetizationManager.hasPro && monetizationManager.freeMessagesRemainingToday <= 3
    }

    private var usageAllowanceBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: monetizationManager.hasReachedFreeDailyMessageLimit
                  ? "exclamationmark.circle.fill"
                  : "message.badge.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    monetizationManager.hasReachedFreeDailyMessageLimit
                        ? String(localized: "Daily free limit reached")
                        : String(
                            format: String(localized: "%lld free messages left today", defaultValue: "%lld free messages left today"),
                            Int64(monetizationManager.freeMessagesRemainingToday)
                        )
                )
                .font(.footnote.weight(.semibold))

                if monetizationManager.hasReachedFreeDailyMessageLimit {
                    Text(String(localized: "More free messages are available tomorrow."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Button(String(localized: "Upgrade")) {
                upgradeFeature = .unlimitedMessages
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(minHeight: 44)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
    }

    private var runtimePerformanceStatus: RuntimePerformanceStatus? {
        _ = performanceStatusRevision
        return RuntimePerformanceStatus.current(
            appLowPowerMode: llmEngine.lowPowerMode,
            recentMemoryPressure: recentMemoryPressure
        )
    }

    private var canStartChatRequest: Bool {
        !documentImportState.isActive && llmEngine.state != .generating && llmEngine.state != .loading
    }

    private var canStartAttachment: Bool {
        canStartChatRequest && !speechManager.isListening
    }

    private func guardCanStartChatRequest(action: String) -> Bool {
        if documentImportState.isActive {
            showExtractionNotice(String(format: String(localized: "Finish or cancel document import before %@."), action))
            return false
        }
        guard llmEngine.state != .loading else { return false }
        guard llmEngine.state != .generating else { return false }
        return true
    }

    private func guardCanStartAttachment(action: String) -> Bool {
        guard guardCanStartChatRequest(action: action) else { return false }
        guard !speechManager.isListening else { return false }
        return true
    }

    private func guardCanAddPhoto(action: String) -> Bool {
        guard guardCanStartAttachment(action: action) else { return false }
        guard selectedImage == nil && currentConversationDocuments.isEmpty else {
            showExtractionNotice(String(format: String(localized: "Remove the current attachment before %@."), action))
            return false
        }
        return true
    }

    private func guardCanAddDocument(action: String) -> Bool {
        guard guardCanStartAttachment(action: action) else { return false }
        guard selectedImage == nil else {
            showExtractionNotice(String(format: String(localized: "Remove the current attachment before %@."), action))
            return false
        }
        guard currentConversationDocuments.isEmpty || monetizationManager.canUse(.unlimitedDocuments) else {
            upgradeFeature = .unlimitedDocuments
            return false
        }
        return true
    }

    private var currentConversationDocuments: [ConversationDocument] {
        documentManager.documents(for: historyManager.currentConversationID)
    }

    private var documentImportProgress: Double {
        switch documentImportState {
        case .idle:
            return 0
        case .extracting:
            return documentManager.extractionProgress
        case .indexing:
            return 0.95
        }
    }

    private var imageAttachmentLabel: String {
        guard let selectedModel else {
            return String(localized: "Photo ready")
        }

        return selectedModel.supportsVision
            ? String(localized: "Photo ready")
            : String(localized: "Photo attached")
    }

    private var latestSpeakableAssistantMessage: ChatMessage? {
        guard autoRead else { return nil }
        guard let lastMessage = historyManager.currentMessages.last else { return nil }
        guard lastMessage.role == .assistant, !lastMessage.isStreaming else { return nil }
        let trimmedContent = lastMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return nil }
        return lastMessage
    }

    private var currentPersonalityLabel: (name: String, icon: String)? {
        guard systemPrompt != AIResponseDefaults.defaultSystemPrompt else { return nil }
        if let matched = PersonalityPreset.presets.first(where: { $0.systemPrompt == systemPrompt }) {
            return (matched.name, matched.icon)
        }
        return (String(localized: "Custom personality"), "slider.horizontal.3")
    }

    private var conversationDocumentsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Text(currentConversationDocuments.count == 1 ? String(localized: "1 doc in this chat") : String(format: String(localized: "%lld docs in this chat", defaultValue: "%lld docs in this chat"), Int64(currentConversationDocuments.count)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.adaptive(white: 0.35))

                ForEach(currentConversationDocuments) { document in
                    HStack(spacing: 8) {
                        Image(systemName: documentIconName(for: document))
                            .font(.caption)
                            .foregroundStyle(.blue)

                        Button {
                            sourceHighlightTitles = []
                            selectedDocumentForSources = document
                        } label: {
                            documentChipLabel(for: document)
                        }
                        .buttonStyle(.plain)

                        Button {
                            documentPendingRemoval = document
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.adaptive(white: 0.6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Remove document"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.blue.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.blue.opacity(0.15), lineWidth: 1)
                            )
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .confirmationDialog(
            String(localized: "Remove this document?"),
            isPresented: Binding(
                get: { documentPendingRemoval != nil },
                set: { if !$0 { documentPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: documentPendingRemoval
        ) { document in
            Button(String(localized: "Remove Document"), role: .destructive) {
                guard let conversationID = historyManager.currentConversationID else { return }
                withAnimation(.spring(response: 0.3)) {
                    documentManager.removeDocument(id: document.id, from: conversationID)
                }
            }
        } message: { document in
            Text(String(format: String(localized: "\"%@\" and its extracted text are deleted from this chat. Answers can no longer draw on it.", defaultValue: "\"%@\" and its extracted text are deleted from this chat. Answers can no longer draw on it."), document.name))
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func documentChipLabel(for document: ConversationDocument) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(document.name)
                    .font(.caption)
                    .lineLimit(1)

                if let badgeTitle = document.textOrigin.badgeTitle {
                    Text(badgeTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                        .accessibilityLabel(document.textOrigin.accessibilityLabel)
                }
            }

            documentChipDetail(for: document)
        }
        .frame(maxWidth: 200, alignment: .leading)
    }

    @ViewBuilder
    private func documentChipDetail(for document: ConversationDocument) -> some View {
        if document.textOrigin != .native {
            Text(document.textOrigin.accessibilityLabel)
                .font(.caption2)
                .foregroundStyle(Color.adaptive(white: 0.45))
                .lineLimit(1)
        }
    }

    // Large models take seconds to load into memory; without this the send
    // button just silently refuses and the app reads as frozen.
    private func queuedMessageBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.checkmark")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Ready to send"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.adaptive(white: 0.15))
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(Color.adaptive(white: 0.5))
                    .lineLimit(2)
                Text(String(localized: "Sends automatically once the model finishes downloading."))
                    .font(.caption2)
                    .foregroundStyle(Color.adaptive(white: 0.5))
            }

            Spacer()

            Button(String(localized: "Cancel")) {
                queuedFirstMessage = nil
                messageText = text
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: String(localized: "Cancel queued message")) {
            queuedFirstMessage = nil
            messageText = text
        }
    }

    private var modelLoadingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: String(
                    localized: "Loading %@…",
                    defaultValue: "Loading %@…"
                ), selectedModel?.name ?? String(localized: "model")))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.adaptive(white: 0.15))
                Text(String(localized: "You can keep typing — sending unlocks in a moment."))
                    .font(.caption2)
                    .foregroundStyle(Color.adaptive(white: 0.5))
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .transition(.opacity)
    }

    // Warn before the model's fixed context window silently drops older
    // turns, so degraded recall reads as a known limit instead of a bug.
    private var shouldShowContextLimitWarning: Bool {
        guard !contextLimitWarningDismissed else { return false }
        guard llmEngine.state != .generating else { return false }
        return llmEngine.contextUsageFraction(for: selectedModel) >= 0.8
    }

    private var contextLimitBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "This conversation is getting long"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.adaptive(white: 0.15))
                Text(String(localized: "Older messages may be forgotten. Start a new chat for best results."))
                    .font(.caption2)
                    .foregroundStyle(Color.adaptive(white: 0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button {
                withAnimation { contextLimitWarningDismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.adaptive(white: 0.45))
                    .frame(width: 24, height: 24)
                    .background(Color.adaptive(white: 0.94))
                    .clipShape(Circle())
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(String(localized: "Dismiss"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .transition(.opacity)
    }

    /// Slide-up for the toasts, collapsing to a plain fade when the user has
    /// Reduce Motion enabled.
    private var toastTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .move(edge: .bottom).combined(with: .opacity)
    }

    private func usageLimitToast(message: String) -> some View {
        toastCard(
            icon: "exclamationmark.circle.fill",
            tint: .orange,
            message: message,
            onDismiss: { dismissUsageToast(message) }
        )
    }

    private func extractionNoticeToast(message: String) -> some View {
        toastCard(
            icon: "exclamationmark.triangle.fill",
            tint: .orange,
            message: message,
            onDismiss: { dismissExtractionNotice(message) }
        )
    }

    private func modelRecoveryToast(message: String) -> some View {
        toastCard(
            icon: "arrow.triangle.2.circlepath.circle.fill",
            tint: .yellow,
            message: message,
            onDismiss: { dismissModelRecoveryNotice(message) }
        )
    }

    /// Shared light-mode notification card used by the chat toasts.
    private func toastCard(
        icon: String,
        tint: Color,
        message: String,
        onDismiss: @escaping () -> Void
    ) -> some View {
        Button(action: onDismiss) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(tint.opacity(0.12)))
                    .accessibilityHidden(true)

                Text(message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.adaptive(white: 0.15))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.adaptiveBorder(opacity: 0.6), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityHint(Text(String(localized: "Dismisses this notification.")))
    }

    private func runtimePerformancePill(
        _ status: RuntimePerformanceStatus,
        onDismiss: @escaping () -> Void
    ) -> some View {
        Button(action: onDismiss) {
            Label(status.message, systemImage: status.symbolName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityLabel(status.message)
        .accessibilityHint(Text(String(localized: "Dismisses this notification.")))
    }

    /// Shown while Kokoro weights load (or download) so a tap on Speak never
    /// looks ignored during the multi-second first-use preparation.
    private var preparingVoicePill: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(speechManager.speechBackendStatus)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func speakReplyButton(for message: ChatMessage) -> some View {
        Button {
            toggleSpeechPlayback(for: message)
        } label: {
            HStack(spacing: 6) {
                if speechManager.isPreparingSpeechOutput {
                    ProgressView().controlSize(.mini)
                    Text(String(localized: "Preparing voice…"))
                } else {
                    Label(
                        speechManager.isSpeaking ? String(localized: "Stop Speaking") : String(localized: "Speak Reply"),
                        systemImage: speechManager.isSpeaking ? "speaker.slash.fill" : "speaker.wave.2.fill"
                    )
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.blue)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.adaptiveCard.opacity(0.9))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.04), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .accessibilityHint(String(localized: "Reads the latest assistant reply aloud."))
    }

    private func followUpSuggestions(for message: ChatMessage) -> [String] {
        guard message.role == .assistant else { return [] }
        guard !message.isStreaming else { return [] }
        guard canStartChatRequest else { return [] }
        guard historyManager.currentMessages.last?.id == message.id else { return [] }
        guard !isInChatSearchActive else { return [] }
        guard smartReplyStylesEnabled else { return [] }

        if let generated = generatedFollowUpSuggestions[message.id], !generated.isEmpty {
            return generated
        }

        let content = message.content
        let lower = content.lowercased()
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var suggestions: [String] = []

        // Code-related reply → offer to explain or run it
        if content.contains("```") {
            suggestions.append("Explain this code step by step")
            suggestions.append("Show me an example of how to use this")
        }

        // List-heavy reply → offer checklist or summary
        let bulletLines = content.components(separatedBy: .newlines).filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("-") || t.hasPrefix("•") || t.hasPrefix("*") ||
                   t.range(of: #"^\d+[\.)]\s"#, options: .regularExpression) != nil
        }
        if bulletLines.count >= 3 {
            suggestions.append("Summarize this in one sentence")
            if !suggestions.contains("Show me an example of how to use this") {
                suggestions.append("Give me a real-world example")
            }
        }

        // Question in the reply → offer to elaborate
        if lower.contains("?") || lower.contains("would you like") || lower.contains("shall i") {
            suggestions.append("Yes, please continue")
        }

        // Long reply → offer simplified version
        let wordCount = content.split { $0.isWhitespace }.count
        if wordCount > 120, !suggestions.contains("Summarize this in one sentence") {
            suggestions.append("Give me a shorter summary")
        }

        // Generic always-useful fallback chips
        if suggestions.isEmpty || suggestions.count < 2 {
            let fallbacks = ["Tell me more", "Give me an example", "Explain it differently"]
            for f in fallbacks {
                if !suggestions.contains(f) { suggestions.append(f) }
                if suggestions.count >= 3 { break }
            }
        }

        return Array(suggestions.prefix(3))
    }

    private var microphoneControls: some View {
        HStack(spacing: 8) {
            // Dictation: transcribe into the text field.
            Button {
                toggleListening()
            } label: {
                Image(systemName: "mic.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(speechManager.isListening ? .white : Color.adaptive(white: 1))
                    .frame(width: 36, height: 36)
                    .background(speechManager.isListening ? Color.red : Color.adaptive(white: 0))
                    .clipShape(Circle())
            }
            .accessibilityLabel(speechManager.isListening
                ? String(localized: "Stop voice input")
                : String(localized: "Start voice input"))
            .frame(minWidth: 44, minHeight: 44)

            // Hands-free voice conversation (full-screen).
            if SpeechManager.isVoiceConversationEnabled {
                voiceConversationButton
            }
        }
    }

    private var voiceConversationButton: some View {
        Button {
            requestVoiceConversation()
        } label: {
            Image(systemName: "waveform")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.blue)
                .clipShape(Circle())
        }
        .accessibilityLabel(String(localized: "Start voice conversation"))
        .frame(minWidth: 44, minHeight: 44)
    }

    private func requestVoiceConversation() {
        guard SpeechManager.isVoiceConversationEnabled else { return }
        guard monetizationManager.canUse(.voiceMode) else {
            upgradeFeature = .voiceMode
            return
        }

        dismissKeyboard()
        speechManager.stopListening()
        speechManager.prewarmSpeechOutputIfNeeded()
        voiceConversationMode = true
    }
    
    // MARK: - Actions
    
    private func handleFileImport(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard let conversationID = historyManager.currentConversationID else { return }
        guard guardCanAddDocument(action: String(localized: "adding a document")) else { return }

        cancelDocumentExtraction(showError: false)
        
        let extractionID = UUID()
        let fileName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        chatDiagnostic("document import selected id=\(extractionID) file=\(fileName) conversation=\(conversationID)")
        let extractionTask = Task {
            do {
                chatDiagnostic("document import reading id=\(extractionID) file=\(fileName)")
                let document = try await documentManager.processFile(at: url)
                try Task.checkCancellation()
                transitionDocumentImportToIndexing(extractionID)
                let didCommit = await documentManager.addDocumentToConversation(
                    from: document,
                    conversationID: conversationID,
                    allowsMultipleDocuments: monetizationManager.canUse(.unlimitedDocuments)
                )
                guard didCommit else { throw CancellationError() }
                chatDiagnostic("document import stored id=\(extractionID) file=\(fileName) chars=\(document.content.count)")
                if let warning = document.ocrWarningText {
                    showExtractionNotice(warning)
                }
            } catch is CancellationError {
                chatDiagnostic("document import cancelled id=\(extractionID) file=\(fileName)")
                // User-initiated cancellation should quietly restore the composer.
            } catch {
                chatDiagnostic("document import failed id=\(extractionID) file=\(fileName) error=\(error.localizedDescription)")
                documentError = error.localizedDescription
            }
            if isCurrentDocumentExtraction(extractionID) {
                chatDiagnostic("document import idle id=\(extractionID) file=\(fileName)")
                withAnimation(.spring(response: 0.3)) {
                    documentImportState = .idle
                }
            }
        }
        withAnimation(.spring(response: 0.3)) {
            documentImportState = .extracting(id: extractionID, fileName: fileName, task: extractionTask)
        }
    }

    private func cancelDocumentExtraction(showError: Bool) {
        switch documentImportState {
        case .extracting(let id, let fileName, let task):
            chatDiagnostic("document import cancel requested id=\(id) file=\(fileName) showError=\(showError)")
            task.cancel()
        case .indexing(let id, let fileName, _):
            // Indexing begins only after the final cancellation check. From this
            // point the document is committed, so cancelling would make the UI
            // claim failure after storage has already changed.
            chatDiagnostic("document import cancel ignored after commit id=\(id) file=\(fileName)")
            return
        case .idle:
            return
        }
        documentManager.extractionProgress = 0
        if showError {
            documentError = String(localized: "Document extraction was cancelled.")
        }
        withAnimation(.spring(response: 0.3)) {
            documentImportState = .idle
        }
    }

    private func isCurrentDocumentExtraction(_ extractionID: UUID) -> Bool {
        if case .extracting(let activeID, _, _) = documentImportState {
            return activeID == extractionID
        }
        if case .indexing(let activeID, _, _) = documentImportState {
            return activeID == extractionID
        }
        return false
    }

    private func transitionDocumentImportToIndexing(_ extractionID: UUID) {
        guard case .extracting(let activeID, let fileName, let task) = documentImportState,
              activeID == extractionID else {
            return
        }
        chatDiagnostic("document import indexing id=\(activeID) file=\(fileName)")
        withAnimation(.spring(response: 0.3)) {
            documentImportState = .indexing(id: activeID, fileName: fileName, task: task)
        }
    }
    
    private func stopGeneration() {
        Self.mediumHaptic.impactOccurred()
        if let conversationID = activeStreamingConversationID,
           let assistantID = activeStreamingAssistantID,
           let message = historyManager.message(id: assistantID, in: conversationID),
           message.isStreaming {
            historyManager.updateMessage(
                id: assistantID,
                in: conversationID,
                content: combinedStreamingContent(for: llmEngine.currentResponse),
                isStreaming: false
            )
        }
        llmEngine.onStreamingUpdate = nil
        streamingState.reset(assistantID: activeStreamingAssistantID)
        llmEngine.stopGeneration()
        streamingPrefix = ""
    }    
    private func toggleListening() {
        if speechManager.isListening {
            speechManager.stopListening()
        } else {
            startListeningIfPossible()
        }
    }

    /// Arms the mic. Unlike a plain "record my next message" start, this is
    /// also called while the assistant is mid-reply (see the `isSpeaking`
    /// onChange below): SpeechManager's barge-in session lets recording and
    /// TTS playback run at once, so the mic can already be capturing before
    /// the user starts talking over the reply.
    private func startListeningIfPossible() {
        // Block arming the mic while the model is still silently "thinking"
        // (nothing audible yet to interrupt). Once streaming TTS has started
        // speaking, generation is very often still running concurrently
        // (later sentences keep streaming in while the first is spoken), so
        // `isSpeaking` overrides the block - that concurrent window is
        // exactly when barge-in needs to be armed.
        guard llmEngine.state != .generating || speechManager.isSpeaking else { return }
        do {
            try speechManager.startListening()
        } catch {
            voiceError = error.localizedDescription
            voiceConversationMode = false
        }
    }
    
    /// Sends the message queued during a model download once a usable model
    /// exists and the engine can accept a request.
    private func attemptQueuedSend() {
        guard let queued = queuedFirstMessage,
              modelManager.selectedModel != nil,
              canStartChatRequest
        else { return }
        queuedFirstMessage = nil
        messageText = queued
        sendMessage()
    }

    private func sendMessage() {
        prioritizeInteractiveChat()
        if monetizationManager.hasReachedFreeDailyMessageLimit {
            // The toast renders under the voice cover; end the session first
            // so the user sees it instead of a silently stalled voice loop.
            if voiceConversationMode { voiceConversationMode = false }
            showUsageLimitToast()
            return
        }
        // No usable model yet, but one is on its way: queue the message so
        // the first-run download wait isn't dead time.
        if modelManager.selectedModel == nil, activeDownloadingModel != nil {
            let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            Self.lightHaptic.impactOccurred()
            queuedFirstMessage = trimmed
            messageText = ""
            isInputFocused = false
            return
        }
        guard guardCanStartChatRequest(action: String(localized: "sending")) else { return }
        guard canSend else { return }
        Self.lightHaptic.impactOccurred()

        guard let model = modelManager.selectedModel else { return }
        if model.requiresImageInput, selectedImage == nil {
            showExtractionNotice(String(localized: "GLM OCR requires an attached image. Choose another model for text chat."))
            return
        }
        if !hasConsent(for: model.id) {
            // A sheet cannot present over the voice cover; dismiss it first.
            if voiceConversationMode { voiceConversationMode = false }
            shouldSendAfterConsent = true
            showModelConsentSheet = true
            return
        }

        performSendMessage()
    }
    
    private func performSendMessage() {
        guard guardCanStartChatRequest(action: String(localized: "sending")) else { return }
        if speechManager.isListening {
            speechManager.stopListening()
        }
        
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversationID = historyManager.currentConversationID
        let imageToSend = selectedImage
        
        if text.isEmpty && currentConversationDocuments.isEmpty && imageToSend == nil { return }
        
        var displayText: String
        if text.isEmpty && imageToSend != nil {
            displayText = selectedModel?.isTranslateGemma == true
                ? "Translate the text in this image."
                : "What's in this image?"
        } else if text.isEmpty && !currentConversationDocuments.isEmpty {
            displayText = "Summarize the documents in this chat."
        } else {
            displayText = text
        }
        
        // Save image and create message
        let messageID = UUID()
        var imageFileName: String?
        if let preparedImageData = selectedImageData {
            imageFileName = ImageAttachmentManager.shared.savePreparedImageData(
                preparedImageData,
                for: messageID
            )
        } else if let imageToSend {
            imageFileName = ImageAttachmentManager.shared.saveImage(imageToSend, for: messageID)
        }
        
        let userMessage = ChatMessage(
            id: messageID,
            role: .user,
            content: displayText,
            imageFileName: imageFileName
        )
        historyManager.addMessage(userMessage, to: conversationID)
        
        messageText = ""
        selectedImage = nil
        selectedImageData = nil
        selectedPhotoItem = nil
        isInputFocused = false
        
        // Generate response
        Task {
            guard let model = await modelManager.modelForRequest(
                prompt: displayText,
                hasImage: imageToSend != nil,
                hasDocuments: !currentConversationDocuments.isEmpty,
                warmModelID: llmEngine.readyModelID,
                lowPowerMode: llmEngine.lowPowerMode
            ) else { return }
            let promptContext = await buildPromptContext(
                userText: text.isEmpty && imageToSend != nil ? displayText : text,
                conversationID: conversationID,
                model: model
            )

            // For non-vision models with image, prepend note
            var effectivePrompt = promptContext.prompt
            if let imageToSend {
                let imageContext = await ImageAnalysisContextBuilder.context(
                    for: imageToSend,
                    mode: ImageProcessingMode.current
                )

                if let imageContext, model.engine == .mlx || !model.supportsVision {
                    effectivePrompt = """
                    [Image analysis context from on-device OCR and visual detection]
                    \(imageContext)

                    [User request]
                    \(effectivePrompt)
                    """
                }

                if !model.supportsVision {
                    effectivePrompt = "[Note: The selected model cannot inspect pixels directly, so answer from the on-device image context when it is useful. If the context is insufficient, say so briefly.]\n\n" + effectivePrompt
                } else if model.isTranslateGemma {
                    effectivePrompt = "[Note: The user attached an image. If it contains visible text, translate it into the user's language unless they specified a different target language. If the image has no readable text, say so briefly.]\n\n" + effectivePrompt
                }
            }
            
            await runAssistantResponse(
                prompt: effectivePrompt,
                conversationID: conversationID,
                resetSession: promptContext.hasDocumentContext,
                image: model.supportsVision ? imageToSend : nil,
                assistantSourceTitles: promptContext.sourceTitles,
                retryPromptSeed: promptContext.retryPromptSeed,
                shouldChargeUsage: true
            )
        }
    }

    private var selectedModel: ModelInfo? {
        modelManager.selectedModel
    }

    private func showUsageLimitToast() {
        let message = String(localized: "Daily free limit reached — more messages tomorrow.")
        showUsageToast(message)
    }

    private func showUsageToastIfNeededAfterSend(messageWasCharged: Bool) {
        guard !monetizationManager.hasPro else { return }

        if monetizationManager.hasReachedFreeDailyMessageLimit {
            showUsageLimitToast()
            return
        }

        // Count down each of the last three so the limit never surprises —
        // but only when this send actually consumed one, so uncharged short
        // messages don't repeat the same number.
        guard messageWasCharged else { return }
        let remaining = monetizationManager.freeMessagesRemainingToday
        guard remaining <= 3 else { return }
        showUsageToast(String(format: String(
            localized: "%lld free messages left.",
            defaultValue: "%lld free messages left."
        ), Int64(remaining)))
    }

    private func showUsageToast(_ message: String) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
            usageLimitToastMessage = message
        }
        UIAccessibility.post(notification: .announcement, argument: message)

        Task {
            try? await Task.sleep(for: .seconds(2.5))
            await MainActor.run {
                if usageLimitToastMessage == message {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        usageLimitToastMessage = nil
                    }
                }
            }
        }
    }

    private func dismissUsageToast(_ message: String) {
        guard usageLimitToastMessage == message else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            usageLimitToastMessage = nil
        }
    }

    private func showExtractionNotice(_ message: String) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
            extractionNoticeMessage = message
        }
        UIAccessibility.post(notification: .announcement, argument: message)

        Task {
            try? await Task.sleep(for: .seconds(3.0))
            await MainActor.run {
                if extractionNoticeMessage == message {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        extractionNoticeMessage = nil
                    }
                }
            }
        }
    }

    private func dismissExtractionNotice(_ message: String) {
        guard extractionNoticeMessage == message else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            extractionNoticeMessage = nil
        }
    }

    private func showModelRecoveryNotice(_ message: String) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
            modelRecoveryNoticeMessage = message
        }
        UIAccessibility.post(notification: .announcement, argument: message)
        Task {
            try? await Task.sleep(for: .seconds(4))
            if modelRecoveryNoticeMessage == message {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    modelRecoveryNoticeMessage = nil
                }
            }
        }
    }

    private func dismissModelRecoveryNotice(_ message: String) {
        guard modelRecoveryNoticeMessage == message else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            modelRecoveryNoticeMessage = nil
        }
    }

    /// Runtime conditions can last for minutes, but their notification should
    /// behave like every other toast: appear briefly, then get out of the way.
    private func showRuntimePerformanceToastIfNeeded(_ status: RuntimePerformanceStatus?) {
        runtimePerformanceDismissTask?.cancel()

        guard let status else {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                runtimePerformanceToast = nil
            }
            runtimePerformanceDismissTask = nil
            return
        }

        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
            runtimePerformanceToast = status
        }
        UIAccessibility.post(notification: .announcement, argument: status.message)

        runtimePerformanceDismissTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard runtimePerformanceToast == status else { return }
                dismissRuntimePerformanceToast()
            }
        }
    }

    private func dismissRuntimePerformanceToast() {
        runtimePerformanceDismissTask?.cancel()
        runtimePerformanceDismissTask = nil
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            runtimePerformanceToast = nil
        }
    }

    private func isRecoverableModelFailure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return !normalized.contains("cancel") &&
            !normalized.contains("stopped") &&
            !normalized.contains("daily free limit")
    }

    private func chatDiagnostic(_ message: String) {
        PerformanceLogger.diagnostic("ChatView \(message)")
    }

    private func wordCount(in content: String) -> Int {
        content.split { $0.isWhitespace }.count
    }

    private func diagnosticDescription(for state: LLMEngineState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .loading:
            return "loading"
        case .ready:
            return "ready"
        case .generating:
            return "generating"
        case .error(let message):
            return "error(\(message))"
        }
    }

    private func runAssistantResponse(
        prompt: String,
        conversationID: UUID?,
        resetSession: Bool = false,
        assistantID: UUID = UUID(),
        existingPrefix: String = "",
        placeholderContent: String = "",
        missingAnswerRetryCount: Int = 0,
        image: UIImage? = nil,
        assistantSourceTitles: [String] = [],
        retryPromptSeed: String? = nil,
        shouldChargeUsage: Bool = false,
        autoContinuationCount: Int = 0,
        generationOverrides: LLMEngine.GenerationOverrides? = nil,
        recoveryAttempted: Bool = false
    ) async {
        prioritizeInteractiveChat()
        modelManager.suspendBackgroundDownloadsForChat()
        let chatLease = await ChatWorkloadCoordinator.shared.beginChat()
        defer {
            Task { @MainActor in
                let becameIdle = await ChatWorkloadCoordinator.shared.endChat(chatLease)
                if becameIdle {
                    modelManager.resumeBackgroundDownloadsAfterChat()
                }
            }
        }
        let responsePerformanceInterval = PerformanceLogger.begin(
            "ChatResponse",
            label: "Chat response",
            metadata: "prompt_characters=\(prompt.count) image=\(image != nil) retry=\(missingAnswerRetryCount)"
        )
        var responsePerformanceStatus = "failed"
        var responseOutputCharacters = 0
        var responseModelID = "none"
        defer {
            responseOutputCharacters = max(responseOutputCharacters, llmEngine.currentResponse.count)
            finalizeStreamingMessageIfNeeded(
                assistantID: assistantID,
                conversationID: conversationID,
                assistantSourceTitles: assistantSourceTitles
            )
            PerformanceLogger.end(
                responsePerformanceInterval,
                status: responsePerformanceStatus,
                metadata: "model=\(responseModelID) output_characters=\(responseOutputCharacters)"
            )
        }

        do {
            guard var model = await modelManager.modelForRequest(
                prompt: prompt,
                hasImage: image != nil,
                hasDocuments: !assistantSourceTitles.isEmpty,
                warmModelID: llmEngine.readyModelID,
                lowPowerMode: llmEngine.lowPowerMode
            ) else {
                chatDiagnostic("response blocked no-model assistantID=\(assistantID) conversation=\(conversationID?.uuidString ?? "nil")")
                let errorMessage = ChatMessage(role: .assistant, content: String(localized: "Please select or download a model first (Settings > Models)."))
                historyManager.addMessage(errorMessage, to: conversationID)
                return
            }
            if !recoveryAttempted,
               let fasterModel = await modelManager.slowRecoveryModel(
                   for: model,
                   requiresVision: image != nil
               ) {
                let slowModel = model
                modelManager.activateRecoveryModel(fasterModel)
                model = fasterModel
                showModelRecoveryNotice(String(format: String(
                    localized: "%@ has been consistently slow here. Using %@ instead.",
                    defaultValue: "%@ has been consistently slow here. Using %@ instead."
                ), slowModel.name, fasterModel.name))
            }
            responseModelID = model.id

            chatDiagnostic("response start assistantID=\(assistantID) conversation=\(conversationID?.uuidString ?? "nil") model=\(model.id) engine=\(model.engine.rawValue) promptChars=\(prompt.count) retry=\(missingAnswerRetryCount)")
            streamingPrefix = existingPrefix
            speechStreamingSpokenCharCount = AssistantOutputSanitizer.sanitize(existingPrefix)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .count
            llmEngine.currentResponse = ""
            activeStreamingConversationID = conversationID
            activeStreamingAssistantID = assistantID
            streamingState.begin(assistantID: assistantID, initialContent: existingPrefix)
            llmEngine.onStreamingUpdate = { response in
                let combined = existingPrefix.isEmpty ? response : existingPrefix + response
                streamingState.update(combined, assistantID: assistantID)
                if let conversationID {
                    historyManager.persistStreamingSnapshot(
                        messageID: assistantID,
                        conversationID: conversationID,
                        content: combined
                    )
                }
                if voiceConversationMode {
                    maybeEnqueueSpeechWhileStreaming()
                }
            }

            if historyManager.containsMessage(assistantID, in: conversationID) {
                historyManager.updateMessage(
                    id: assistantID,
                    in: conversationID,
                    content: placeholderContent,
                    isStreaming: true,
                    sourceTitles: assistantSourceTitles,
                    retryPromptSeed: retryPromptSeed
                )
            } else {
                let assistantPlaceholder = ChatMessage(
                    id: assistantID,
                    role: .assistant,
                    content: placeholderContent,
                    sourceTitles: assistantSourceTitles,
                    retryPromptSeed: retryPromptSeed,
                    isStreaming: true
                )
                historyManager.addMessage(assistantPlaceholder, to: conversationID)
            }
            chatDiagnostic("response placeholder streaming assistantID=\(assistantID) existingPrefixChars=\(existingPrefix.count)")

            try await llmEngine.loadModel(model)
            chatDiagnostic("response model loaded assistantID=\(assistantID) state=\(diagnosticDescription(for: llmEngine.state))")

            let nextSessionScope = generationSessionScope(for: model, conversationID: conversationID)
            let mlxVisionImageKey = model.engine == .mlx && model.supportsVision
                ? llmEngine.mlxImageFingerprint(for: image)
                : nil
            
            let isEphemeral = model.engine == .mlx && (
                !llmEngine.mlxModelSupportsSystemRole(modelID: model.id)
            )
            let isNewMlxVisionImage = mlxVisionImageKey != nil && activeMlxVisionImageKey != mlxVisionImageKey

            let shouldResetSession = resetSession ||
                activeGenerationSessionScope != nextSessionScope ||
                !llmEngine.hasConversationContext(for: model) ||
                lastGenerationWasEphemeral ||
                isNewMlxVisionImage

            if shouldResetSession {
                chatDiagnostic("response reset session assistantID=\(assistantID) resetRequested=\(resetSession)")
                llmEngine.resetSession()
            }

            if shouldChargeUsage {
                let charged = monetizationManager.registerFreeMessageIfNeeded(for: prompt)
                showUsageToastIfNeededAfterSend(messageWasCharged: charged)
            }

            let continuityPrompt = shouldResetSession
                ? promptIncludingRecentTranscript(
                    prompt,
                    conversationID: conversationID,
                    assistantID: assistantID,
                    model: model
                )
                : prompt

            let effectiveOverrides = generationOverrides ?? adaptiveGenerationOverrides(
                prompt: continuityPrompt,
                model: model,
                autoContinuationCount: autoContinuationCount,
                image: image
            )
            chatDiagnostic("response generate begin assistantID=\(assistantID) shouldReset=\(shouldResetSession)")
            // Persist any summary rolling condensation produces during a
            // generation on the conversation that generation was started for
            // (delivered back by the engine), so continuity survives
            // conversation switches and app restarts.
            llmEngine.onRollingSummaryUpdate = { summary, summaryConversationID in
                historyManager.updateRollingSummary(summary, for: summaryConversationID)
            }
            try await llmEngine.generate(
                prompt: budgetedGenerationPrompt(
                    promptWithResponseLimit(continuityPrompt, existingPrefix: existingPrefix),
                    model: model
                ),
                overrides: effectiveOverrides,
                image: image,
                conversationID: conversationID
            )
            responseOutputCharacters = llmEngine.currentResponse.count
            responsePerformanceStatus = {
                if case .error = llmEngine.state { return "failed" }
                return "success"
            }()
            chatDiagnostic("response generate end assistantID=\(assistantID) state=\(diagnosticDescription(for: llmEngine.state)) streamedChars=\(llmEngine.currentResponse.count) streamedWords=\(wordCount(in: llmEngine.currentResponse))")

            if generationOverrides == nil, case .ready = llmEngine.state, let maxTokensUsed = effectiveOverrides.maxTokens {
                AdaptiveTokenBudget.recordOutcome(
                    modelID: model.id,
                    hitLimit: passLikelyHitTokenLimit(
                        rawResponse: llmEngine.currentResponse,
                        maxTokensUsed: maxTokensUsed
                    )
                )
            }

            if case .error(let message) = llmEngine.state {
                chatDiagnostic("response engine error assistantID=\(assistantID) error=\(message)")
                throw ChatModelFailure(message: message)
            }

            let finalizedContent = enforcedResponseLimit(
                for: combinedStreamingContent(for: llmEngine.currentResponse),
                existingPrefix: existingPrefix
            )
            let finalizedParts = AssistantOutputSanitizer.parts(from: finalizedContent)
            if finalizedParts.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               finalizedParts.thinkingContent != nil,
               missingAnswerRetryCount == 0 {
                chatDiagnostic("response missing final answer retry assistantID=\(assistantID)")
                llmEngine.currentResponse = ""
                streamingPrefix = ""
                await runAssistantResponse(
                    prompt: """
                    Provide only the final answer to the user.
                    Do not include reasoning, thoughts, or <think> tags.
                    Answer the original request directly.
                    """,
                    conversationID: conversationID,
                    assistantID: assistantID,
                    existingPrefix: "",
                    placeholderContent: finalizedContent,
                    missingAnswerRetryCount: 1,
                    assistantSourceTitles: assistantSourceTitles,
                    retryPromptSeed: retryPromptSeed
                )
                return
            }

            if shouldAutoContinueResponse(
                visibleContent: finalizedParts.content,
                autoContinuationCount: autoContinuationCount
            ) {
                chatDiagnostic("response auto-continue assistantID=\(assistantID) count=\(autoContinuationCount + 1)")
                llmEngine.currentResponse = ""
                streamingPrefix = ""
                await runAssistantResponse(
                    prompt: continuationPrompt(
                        for: finalizedParts.content,
                        sourceTitles: assistantSourceTitles
                    ),
                    conversationID: conversationID,
                    assistantID: assistantID,
                    existingPrefix: continuationPrefix(for: finalizedContent),
                    placeholderContent: finalizedContent,
                    assistantSourceTitles: assistantSourceTitles,
                    retryPromptSeed: retryPromptSeed,
                    autoContinuationCount: autoContinuationCount + 1
                )
                return
            }

            historyManager.updateMessage(
                id: assistantID,
                in: conversationID,
                content: finalizedContent,
                isStreaming: false,
                sourceTitles: assistantSourceTitles
            )
            // A quiet cue that the reply landed - mirrors the tap-to-send
            // haptic so the round trip feels answered, not just displayed.
            Self.lightHaptic.impactOccurred()
            chatDiagnostic("response finalized assistantID=\(assistantID) contentChars=\(finalizedContent.count) contentWords=\(wordCount(in: finalizedContent))")
            modelManager.markModelUsed(model.id)
            activeGenerationSessionScope = nextSessionScope
            lastGenerationWasEphemeral = isEphemeral
            if let mlxVisionImageKey {
                activeMlxVisionImageKey = mlxVisionImageKey
            } else if shouldResetSession {
                activeMlxVisionImageKey = nil
            }

            schedulePostResponseEnrichment(
                conversationID: conversationID,
                model: model,
                assistantID: assistantID
            )

            llmEngine.currentResponse = ""
            streamingPrefix = ""

            // Speak only the visible answer: stored content can still carry
            // <think> reasoning and control markers, which must never be
            // read aloud. Most sentences were already enqueued sentence-by-
            // sentence while streaming (maybeEnqueueSpeechWhileStreaming), so
            // only the trailing fragment after the last spoken boundary is
            // left to say — enqueue that instead of the whole reply, or the
            // already-playing queue would be wiped and restarted from zero.
            let spokenReply = AssistantOutputSanitizer
                .sanitize(historyManager.message(id: assistantID, in: conversationID)?.content ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let alreadySpokenCount = min(speechStreamingSpokenCharCount, spokenReply.count)
            let remainingStart = spokenReply.index(spokenReply.startIndex, offsetBy: alreadySpokenCount)
            let remainingTail = String(spokenReply[remainingStart...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            speechStreamingSpokenCharCount = 0
            if voiceConversationMode, !remainingTail.isEmpty {
                speechManager.enqueueSpeak(remainingTail)
            } else if voiceConversationMode, speechManager.isSpeechQueueEmpty {
                startListeningIfPossible()
            }
        } catch {
            chatDiagnostic("response failed assistantID=\(assistantID) error=\(error.localizedDescription)")
            if !recoveryAttempted,
               isRecoverableModelFailure(error.localizedDescription),
               let failedModel = modelManager.models.first(where: { $0.id == responseModelID }),
               let recoveryModel = modelManager.recoveryModel(
                   excluding: failedModel.id,
                   requiresVision: image != nil
               ) {
                let failedResult = ModelQuickTestResult(
                    modelID: failedModel.id,
                    success: false,
                    responseSnippet: error.localizedDescription,
                    durationMs: 0,
                    timestamp: Date(),
                    operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
                )
                modelManager.saveQuickTestResult(failedResult)
                modelManager.activateRecoveryModel(recoveryModel)
                llmEngine.unloadModel()
                llmEngine.currentResponse = ""
                streamingPrefix = ""
                invalidateGenerationSessionScope()
                showModelRecoveryNotice(String(format: String(
                    localized: "%@ could not continue. Retrying once with %@.",
                    defaultValue: "%@ could not continue. Retrying once with %@."
                ), failedModel.name, recoveryModel.name))
                responsePerformanceStatus = "recovered"
                await runAssistantResponse(
                    prompt: prompt,
                    conversationID: conversationID,
                    resetSession: true,
                    assistantID: assistantID,
                    existingPrefix: existingPrefix,
                    placeholderContent: placeholderContent,
                    missingAnswerRetryCount: missingAnswerRetryCount,
                    image: image,
                    assistantSourceTitles: assistantSourceTitles,
                    retryPromptSeed: retryPromptSeed,
                    shouldChargeUsage: false,
                    autoContinuationCount: autoContinuationCount,
                    generationOverrides: generationOverrides,
                    recoveryAttempted: true
                )
                return
            }
            let errorText = userFacingErrorText(from: error.localizedDescription)
            if historyManager.containsMessage(assistantID, in: conversationID) {
                let fallbackContent = failureContent(
                    assistantID: assistantID,
                    conversationID: conversationID,
                    existingPrefix: existingPrefix,
                    errorText: errorText
                )
                historyManager.updateMessage(
                    id: assistantID,
                    in: conversationID,
                    content: fallbackContent,
                    isStreaming: false,
                    sourceTitles: assistantSourceTitles
                )
            } else {
                historyManager.addMessage(
                    ChatMessage(role: .assistant, content: errorText, sourceTitles: assistantSourceTitles),
                    to: conversationID
                )
            }
            llmEngine.currentResponse = ""
            streamingPrefix = ""
            invalidateGenerationSessionScope()
            if voiceConversationMode {
                speechManager.speak(errorText)
            }
        }
    }

    private func finalizeStreamingMessageIfNeeded(
        assistantID: UUID,
        conversationID: UUID?,
        assistantSourceTitles: [String]
    ) {
        guard let message = historyManager.message(id: assistantID, in: conversationID),
              message.role == .assistant,
              message.isStreaming else {
            return
        }

        let streamedContent = combinedStreamingContent(for: llmEngine.currentResponse)
        let fallbackContent = rawAssistantContent(for: message)
        let finalContent = streamedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackContent
            : streamedContent

        chatDiagnostic("response finalizer closed streaming assistantID=\(assistantID) contentChars=\(finalContent.count) contentWords=\(wordCount(in: finalContent)) streamedChars=\(streamedContent.count)")
        historyManager.updateMessage(
            id: assistantID,
            in: conversationID,
            content: enforcedResponseLimit(for: finalContent, existingPrefix: streamingPrefix),
            isStreaming: false,
            sourceTitles: assistantSourceTitles
        )

        if activeStreamingAssistantID == assistantID {
            activeStreamingConversationID = nil
            activeStreamingAssistantID = nil
        }
        streamingState.reset(assistantID: assistantID)
        llmEngine.onStreamingUpdate = nil
        llmEngine.currentResponse = ""
        streamingPrefix = ""
        ReviewPromptManager.noteSuccessfulResponse()
    }

    // Cross-chat memory extraction from the latest user message. Its caller
    // owns the cancellable, delayed enrichment task so a new chat can preempt it.
    private func rememberUserFactsIfNeeded(conversationID: UUID?, assistantID: UUID) async {
        guard memoryStore.isEnabled else { return }
        guard let conversation = historyManager.conversation(id: conversationID),
              let userMessage = conversation.messages.last(where: { $0.role == .user }) else {
            return
        }
        let text = userMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Very short messages ("thanks", "continue") never contain durable facts.
        guard text.count >= 25 else { return }
        // Only messages where the user talks about themselves can contain
        // durable user facts. Without this, the extractor turned messages
        // about other people (or nothing at all) into invented "facts".
        guard AssistantMemoryStore.containsSelfReference(text) else { return }

        guard let facts = try? await llmEngine.extractUserFacts(from: text),
              !facts.isEmpty,
              !Task.isCancelled else { return }
        // The extractor is generative, so accept only verbatim evidence
        // from the user's message. This prevents invented preferences or
        // topics from poisoning every later model's system prompt.
        let grounded = AssistantMemoryStore.verifiedExtractedFacts(facts, from: text)
        guard !grounded.isEmpty else { return }
        memoryStore.add(grounded)
    }

    private func prioritizeInteractiveChat() {
        postResponseEnrichmentTask?.cancel()
        postResponseEnrichmentTask = nil

        guard DeviceResourcePolicy.current.isLowMemoryPhone else { return }
        speechManager.prioritizeInteractiveChat(
            preserveVoiceFeatures: voiceConversationMode
        )
        Task {
            await EmbeddingService.shared.unload()
        }
    }

    private func schedulePostResponseEnrichment(
        conversationID: UUID?,
        model: ModelInfo,
        assistantID: UUID
    ) {
        postResponseEnrichmentTask?.cancel()
        guard DeviceResourcePolicy.current.shouldRunPostResponseEnrichment else {
            postResponseEnrichmentTask = nil
            return
        }

        postResponseEnrichmentTask = Task { @MainActor in
            // Give the composer and model a quiet window. Starting another
            // answer cancels this task before it can contend with chat.
            try? await Task.sleep(for: .seconds(4))
            await ChatWorkloadCoordinator.shared.waitUntilChatIsIdle()
            guard !Task.isCancelled, llmEngine.state == .ready else { return }

            await refineConversationInsightsIfNeeded(
                conversationID: conversationID,
                model: model,
                assistantID: assistantID
            )
            guard !Task.isCancelled, llmEngine.state == .ready else { return }
            await rememberUserFactsIfNeeded(
                conversationID: conversationID,
                assistantID: assistantID
            )
        }
    }

    private func refineConversationInsightsIfNeeded(
        conversationID: UUID?,
        model: ModelInfo,
        assistantID: UUID
    ) async {
        guard model.engine == .appleFoundation,
              let conversation = historyManager.conversation(id: conversationID),
              let userMessage = conversation.messages.first(where: { $0.role == .user }),
              let assistantMessage = historyManager.message(id: assistantID, in: conversationID),
              assistantMessage.role == .assistant,
              !assistantMessage.isStreaming else {
            return
        }

        let assistantResponse = AssistantOutputSanitizer
            .sanitize(assistantMessage.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assistantResponse.isEmpty else { return }

        do {
            let shouldGenerateFollowUps = smartReplyStylesEnabled
            let generatedTitle: String
            let generatedFollowUps: [String]

            if shouldGenerateFollowUps {
                let insights = try await llmEngine.generateConversationInsights(
                    userMessage: userMessage.content,
                    assistantResponse: assistantResponse,
                    model: model
                )
                generatedTitle = insights.title
                generatedFollowUps = insights.suggestedFollowUps
            } else {
                generatedTitle = try await llmEngine.generateConversationTitle(
                    userMessage: userMessage.content,
                    assistantResponse: assistantResponse,
                    model: model
                )
                generatedFollowUps = []
            }

            let fallbackTitle = ChatConversation.fallbackTitle(for: userMessage.content)
            if conversation.messages.count == 2,
               conversation.title == fallbackTitle || conversation.title == "New Chat" {
                historyManager.updateTitle(generatedTitle, for: conversationID)
            }

            if shouldGenerateFollowUps, !generatedFollowUps.isEmpty {
                generatedFollowUpSuggestions[assistantID] = generatedFollowUps
            }
        } catch {
        }
    }

    private func imagePreviewStrip(_ image: UIImage) -> some View {
        HStack(spacing: 10) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.adaptiveBorder(opacity: 0.3), lineWidth: 1)
                )

            Text(imageAttachmentLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.adaptive(white: 0.2))

            Spacer()

            Button {
                withAnimation(.spring(response: 0.3)) {
                    selectedImage = nil
                    selectedImageData = nil
                    selectedPhotoItem = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.adaptive(white: 0.5))
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(String(localized: "Remove attached image"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.adaptiveCard.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.adaptiveBorder(opacity: 0.25), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func handlePhotoSelection() {
        guard let item = selectedPhotoItem else { return }
        selectedPhotoItem = nil
        guard guardCanAddPhoto(action: String(localized: "adding a photo")) else {
            return
        }

        guard monetizationManager.canUse(.imageInput) else {
            photoItemAwaitingUpgrade = item
            upgradeFeature = .imageInput
            return
        }

        processPhotoItem(item)
    }

    private func processPhotoItem(_ item: PhotosPickerItem) {
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let preparedData = await ImageAttachmentManager.shared.prepareImageData(data),
                      let uiImage = UIImage(data: preparedData) else {
                    throw ChatModelFailure(message: String(localized: "Own AI couldn’t read that image. Try another photo."))
                }

                photoItemAwaitingUpgrade = nil
                withAnimation(.spring(response: 0.3)) {
                    selectedImage = uiImage
                    selectedImageData = preparedData
                }
            } catch {
                showExtractionNotice(String(localized: "Own AI couldn’t read that image. Try another photo."))
            }
        }
    }

    private func toggleSpeechPlayback(for message: ChatMessage) {
        if speechManager.isSpeaking && speechManager.currentlySpeakingMessageID == message.id {
            speechManager.stopSpeaking()
            return
        }

        if speechManager.isListening {
            speechManager.stopListening()
        }

        let text = AssistantOutputSanitizer.sanitize(message.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        speechManager.speak(text, messageID: message.id)
    }

    private func maybeEnqueueSpeechWhileStreaming() {
        // SpeechManager handles the actual synthesis/playback queue; here we only decide *what* chunk to enqueue.
        let visibleText = AssistantOutputSanitizer
            .sanitize(combinedStreamingContent(for: llmEngine.currentResponse))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !visibleText.isEmpty else { return }
        guard speechStreamingSpokenCharCount < visibleText.count else { return }
        
        let spokenCount = min(speechStreamingSpokenCharCount, visibleText.count)
        let startIndex = visibleText.index(visibleText.startIndex, offsetBy: spokenCount)
        let tail = visibleText[startIndex...]
        
        // Kokoro chunk size needs to be small enough that sentence 2 can start
        // before the model finishes generating the whole sentence.
        let minChunkChars = 6
        
        // Prefer sentence-like boundaries (end punctuation / newline).
        if let boundaryEnd = lastSpeakableBoundaryEndIndex(in: tail) {
            let chunk = tail[..<boundaryEnd]
            let trimmedChunk = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Avoid enqueuing tiny fragments that make Kokoro feel sluggish.
            guard trimmedChunk.count >= minChunkChars else { return }
            
            speechManager.enqueueSpeak(String(trimmedChunk))
            speechStreamingSpokenCharCount = visibleText.distance(from: visibleText.startIndex, to: boundaryEnd)
            return
        }
        
        // If we don't have an end boundary yet, enqueue an earlier chunk so sentence 2 can start sooner.
        // (Lower threshold helps avoid silence gaps in short sentences.)
        let fallbackTriggerChars = 30
        guard tail.count >= fallbackTriggerChars else { return }
        
        let fallbackMaxChars = 90
        let desiredEndCount = min(fallbackMaxChars, tail.count)
        let desiredEnd = tail.index(tail.startIndex, offsetBy: desiredEndCount)
        let prefix = tail[..<desiredEnd]
        
        // Cut at the last whitespace before `desiredEnd` to avoid chopping words.
        let endForChunk = lastWhitespaceEndIndex(in: prefix) ?? desiredEnd
        guard endForChunk > tail.startIndex else { return }
        
        let chunk = tail[..<endForChunk]
        let trimmedChunk = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedChunk.count >= minChunkChars else { return }
        
        speechManager.enqueueSpeak(String(trimmedChunk))
        speechStreamingSpokenCharCount = visibleText.distance(from: visibleText.startIndex, to: endForChunk)
    }

    private func lastSpeakableBoundaryEndIndex(in text: Substring) -> String.Index? {
        var lastEnd: String.Index? = nil
        var idx = text.startIndex
        
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "\n" {
                lastEnd = text.index(after: idx)
            } else if ch == "." || ch == "!" || ch == "?" {
                let next = text.index(after: idx)
                if next == text.endIndex || text[next].isWhitespace {
                    lastEnd = text.index(after: idx)
                }
            }
            idx = text.index(after: idx)
        }
        
        return lastEnd
    }
    
    private func lastWhitespaceEndIndex(in text: Substring) -> String.Index? {
        guard !text.isEmpty else { return nil }
        var idx = text.endIndex
        while idx > text.startIndex {
            idx = text.index(before: idx)
            if text[idx].isWhitespace {
                return text.index(after: idx)
            }
        }
        return nil
    }

    private func continueResponse(for message: ChatMessage) {
        guard guardCanStartChatRequest(action: String(localized: "continuing")) else { return }
        guard let lastMessage = historyManager.currentMessages.last, lastMessage.id == message.id else { return }
        guard hasRecoverableConversationContext else { return }

        if missingFinalAnswer(message) {
            Task {
                await runAssistantResponse(
                    prompt: """
                    Provide only the final answer to the user.
                    Do not include reasoning, thoughts, or <think> tags.
                    Answer the original request directly.
                    """,
                    conversationID: historyManager.currentConversationID,
                    assistantID: message.id,
                    existingPrefix: "",
                    placeholderContent: rawAssistantContent(for: message),
                    assistantSourceTitles: message.sourceTitles
                )
            }
            return
        }

        let prompt = continuationPrompt(for: message.content, sourceTitles: message.sourceTitles)

        Task {
            await runAssistantResponse(
                prompt: prompt,
                conversationID: historyManager.currentConversationID,
                assistantID: message.id,
                existingPrefix: continuationPrefix(for: message.content),
                placeholderContent: message.content,
                assistantSourceTitles: message.sourceTitles
            )
        }
    }

    private func continuationPrompt(for content: String, sourceTitles: [String]) -> String {
        let sourceMap = sourceTitles.enumerated().map { index, title in
            "[Source \(index + 1): \(title)]"
        }.joined(separator: "\n")
        let sourceContext = sourceMap.isEmpty ? "" : """

        Available source labels:
        \(sourceMap)
        """

        return """
        Previous visible answer:
        \(content)
        \(sourceContext)

        Continue the previous visible answer exactly where it stopped.
        Do not repeat the previous answer.
        Start with the next missing words only.
        Finish the same answer naturally and concisely.
        """
    }

    private func continuationPrefix(for content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastScalar = trimmed.unicodeScalars.last else { return content }

        let terminalCharacters = CharacterSet(charactersIn: ".!?\"')]}”")
        if terminalCharacters.contains(lastScalar) || endsWithEmoji(trimmed) {
            return content.hasSuffix("\n") ? content : content + "\n\n"
        }

        return content
    }

    private func startEdit(_ message: ChatMessage) {
        guard message.role == .user else { return }
        guard llmEngine.state != .generating else { return }

        guard let idx = historyManager.currentMessages.firstIndex(where: { $0.id == message.id }) else { return }

        // Keep edits scoped to the most recent user turn so the underlying model context stays coherent.
        let isLast = idx == historyManager.currentMessages.count - 1
        let isSecondLast = idx == historyManager.currentMessages.count - 2
        guard isLast || isSecondLast else { return }

        editingMessage = message
        editedMessageText = message.content
        editComposerSessionID = UUID()
        isEditSheetPresented = true
    }

    private var editSheetHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Refine the prompt"))
                .font(.title2.bold())
                .foregroundStyle(Color.adaptive(white: 0.12))

            Text(String(localized: "Update the last user message and rerun the answer from that point."))
                .font(.subheadline)
                .foregroundStyle(Color.adaptive(white: 0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func originalMessageCard(message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "quote.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)

                Text(String(localized: "Original message"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.adaptive(white: 0.45))

                Spacer()
            }

            Text(message.content)
                .font(.callout)
                .foregroundStyle(Color.adaptive(white: 0.2))
                .lineLimit(4)
                .multilineTextAlignment(.leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.adaptiveCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.adaptiveBorder(opacity: 0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
    }

    private var editComposerCard: some View {
        let editorPadding = EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        // TextEditor adds its own text-container inset inside this outer padding.
        // Match it so an empty editor's placeholder sits on the text baseline.
        let placeholderPadding = EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "Your revision"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.adaptive(white: 0.45))

                Spacer()

                Text(String(format: String(localized: "%lld characters", defaultValue: "%lld characters"), Int64(editedMessageText.count)))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.adaptive(white: 0.5))
            }

            ZStack(alignment: .topLeading) {
                if editedMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(String(localized: "Rewrite the message here..."))
                        .font(.callout)
                        .foregroundStyle(Color.adaptive(white: 0.55))
                        .padding(placeholderPadding)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $editedMessageText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(minHeight: 220)
                    .padding(editorPadding)
                    .id(editComposerSessionID)
            }
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            .background(Color.adaptive(white: 0.985), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.adaptiveBorder(opacity: 0.3), lineWidth: 1)
            )

            HStack(spacing: 10) {
                Button {
                    if let editingMessage {
                        editedMessageText = editingMessage.content
                    }
                } label: {
                    Label(String(localized: "Reset"), systemImage: "arrow.uturn.backward")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.adaptive(white: 0.4))
                .disabled(editedMessageText == (editingMessage?.content ?? ""))

                Spacer()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.adaptiveCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.adaptiveBorder(opacity: 0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
    }

    private func applyEditedMessageAndRerun() {
        guard let editingMessage else { return }
        guard guardCanStartChatRequest(action: String(localized: "rerunning")) else { return }

        if monetizationManager.hasReachedFreeDailyMessageLimit {
            showUsageLimitToast()
            return
        }

        guard let model = modelManager.selectedModel else { return }
        if !hasConsent(for: model.id) {
            shouldSendAfterConsent = false
            showModelConsentSheet = true
            return
        }

        let conversationID = historyManager.currentConversationID
        let newText = editedMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else { return }

        historyManager.updateMessage(
            id: editingMessage.id,
            in: conversationID,
            content: newText,
            isStreaming: false
        )
        historyManager.truncateConversation(after: editingMessage.id, in: conversationID)

        isEditSheetPresented = false
        self.editingMessage = nil

        Task {
            let promptContext = await buildPromptContext(
                userText: newText,
                conversationID: conversationID,
                model: model
            )
            await runAssistantResponse(
                prompt: promptContext.prompt,
                conversationID: conversationID,
                resetSession: true,
                assistantSourceTitles: promptContext.sourceTitles,
                shouldChargeUsage: true
            )
        }
    }

    private enum RegenerateStyle {
        case more
        case less
    }

    private func regenerate(message: ChatMessage, style: RegenerateStyle) {
        let smartStyle: SmartReplyStyle
        switch style {
        case .more:
            smartStyle = .deeper
        case .less:
            smartStyle = .shorter
        }

        regenerate(message: message, style: smartStyle)
    }

    private func smartReplyStyles(for message: ChatMessage) -> [SmartReplyStyle] {
        guard smartReplyStylesEnabled else { return [] }
        guard message.role == .assistant else { return [] }
        guard !message.isStreaming else { return [] }
        guard canStartChatRequest else { return [] }
        guard historyManager.currentMessages.last?.id == message.id else { return [] }
        guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let content = message.content
        var styles: [SmartReplyStyle] = [.shorter, .deeper]
        if shouldOfferSimplerReplyStyle(for: content) {
            styles.append(.simpler)
        }
        if shouldOfferChecklistReplyStyle(for: content) {
            styles.append(.checklist)
        }
        if !message.sourceTitles.isEmpty {
            styles.append(.citeSources)
        }
        return styles
    }

    private func shouldOfferChecklistReplyStyle(for content: String) -> Bool {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return false }

        let words = trimmedContent.split(whereSeparator: \.isWhitespace)
        let paragraphs = trimmedContent.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let sentenceBreaks = trimmedContent.filter { ".!?".contains($0) }.count
        let structuredLines = paragraphs.filter { line in
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedLine.hasPrefix("-")
                || trimmedLine.hasPrefix("*")
                || trimmedLine.hasPrefix("•")
                || trimmedLine.range(of: #"^\d+[\.)]\s"#, options: .regularExpression) != nil
        }

        return words.count >= 90 || paragraphs.count >= 5 || sentenceBreaks >= 5 || structuredLines.count >= 4
    }

    private func shouldOfferSimplerReplyStyle(for content: String) -> Bool {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return false }

        let lowercasedWords = Set(trimmedContent.lowercased().split { character in
            !character.isLetter && !character.isNumber
        })
        let technicalTerms: Set<Substring> = [
            "api", "async", "cache", "cli", "compile", "database", "dependency",
            "endpoint", "framework", "json", "latency", "migration", "model",
            "protocol", "refactor", "repository", "schema", "sdk", "server",
            "swift", "token"
        ]

        let hasCodeFormatting = trimmedContent.contains("`") || trimmedContent.contains("```")
        let hasTechnicalTerm = !lowercasedWords.isDisjoint(with: technicalTerms)
        let hasSymbolHeavyText = trimmedContent.contains("->") || trimmedContent.contains("::") || trimmedContent.contains("()")

        return hasCodeFormatting || hasTechnicalTerm || hasSymbolHeavyText
    }

    private func regenerate(message: ChatMessage, style: SmartReplyStyle) {
        guard message.role == .assistant else { return }
        guard guardCanStartChatRequest(action: String(localized: "regenerating")) else { return }
        guard historyManager.currentMessages.last?.id == message.id else { return }

        Self.lightHaptic.impactOccurred()

        Task {
            await runAssistantResponse(
                prompt: style.instruction(previousAnswer: message.content),
                conversationID: historyManager.currentConversationID,
                assistantID: message.id,
                existingPrefix: "",
                placeholderContent: "",
                assistantSourceTitles: message.sourceTitles,
                shouldChargeUsage: false
            )
        }
    }

    private func branchConversation(from message: ChatMessage) {
        guard llmEngine.state != .generating else { return }
        Task {
            if await historyManager.branchConversation(from: message.id) {
                llmEngine.resetSession()
                Self.mediumHaptic.impactOccurred()
                showUsageToast(String(localized: "Branched to a new conversation"))
            } else {
                showUsageToast(String(localized: "Could not branch because an image attachment was unavailable."))
            }
        }
    }

    private func retryAction(for message: ChatMessage) -> MessageBubble.RecoveryAction? {
        guard canRetryAfterReset(message) else { return nil }
        return MessageBubble.RecoveryAction(
            title: String(localized: "Retry"),
            systemImage: "arrow.clockwise",
            action: { retryResponseAfterReset(for: message) }
        )
    }

    private func retryResponseAfterReset(for message: ChatMessage) {
        guard guardCanStartChatRequest(action: String(localized: "retrying")) else { return }
        guard historyManager.currentMessages.last?.id == message.id else { return }
        guard let promptSeed = retryPromptSeed(for: message) else { return }

        Task {
            let promptContext = await buildPromptContext(
                userText: promptSeed,
                conversationID: historyManager.currentConversationID,
                model: modelManager.selectedModel
            )
            await runAssistantResponse(
                prompt: promptContext.prompt,
                conversationID: historyManager.currentConversationID,
                resetSession: true,
                assistantID: message.id,
                existingPrefix: "",
                placeholderContent: "",
                assistantSourceTitles: promptContext.sourceTitles,
                retryPromptSeed: promptSeed
            )
        }
    }

    private func canContinue(_ message: ChatMessage) -> Bool {
        guard message.role == .assistant else { return false }
        guard !message.isStreaming else { return false }
        guard canStartChatRequest else { return false }
        guard historyManager.currentMessages.last?.id == message.id else { return false }
        guard hasRecoverableConversationContext else { return false }
        if missingFinalAnswer(message) { return true }
        return looksTruncated(message.content) ||
            likelyHitResponseLimit(message.content) ||
            likelyHitResponseCharacterLimit(message.content)
    }

    private func canRetryAfterReset(_ message: ChatMessage) -> Bool {
        guard message.role == .assistant else { return false }
        guard !message.isStreaming else { return false }
        guard canStartChatRequest else { return false }
        guard historyManager.currentMessages.last?.id == message.id else { return false }
        guard retryPromptSeed(for: message) != nil else { return false }

        let content = message.content.lowercased()
        let thinking = message.thinkingContent?.lowercased() ?? ""
        return [
            "jinja.templateexception",
            "sorry, i encountered an error:",
            "sorry, i hit a model template error",
            "tap retry to clear the current chat context and try again",
            "the operation couldn’t be completed",
            "the operation couldn't be completed"
        ]
        .contains(where: { marker in
            content.contains(marker) || thinking.contains(marker)
        })
    }

    private func retryPromptSeed(for message: ChatMessage) -> String? {
        if let retryPromptSeed = message.retryPromptSeed?.trimmingCharacters(in: .whitespacesAndNewlines),
           !retryPromptSeed.isEmpty {
            return retryPromptSeed
        }

        guard let messageIndex = historyManager.currentMessages.firstIndex(where: { $0.id == message.id }) else {
            return nil
        }

        return historyManager.currentMessages[..<messageIndex]
            .reversed()
            .first(where: { $0.role == .user })?
            .content
    }

    private func userFacingErrorText(from message: String) -> String {
        let lowercased = message.lowercased()

        if lowercased.contains("unsupported language") || lowercased.contains("locale") {
            return String(localized: "This document's language is not supported by Apple Intelligence. Try switching to an MLX model (like Gemma) in Settings -> Models for multi-language support.")
        }

        if lowercased.contains("jinja.templateexception") {
            return String(localized: "Sorry, I hit a model template error. Tap Retry to clear the current chat context and try again.")
        }

        return String(format: String(localized: "Sorry, I encountered an error: %@", defaultValue: "Sorry, I encountered an error: %@"), message)
    }

    private func missingFinalAnswer(_ message: ChatMessage) -> Bool {
        message.role == .assistant &&
        message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !(message.thinkingContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func rawAssistantContent(for message: ChatMessage) -> String {
        AssistantOutputSanitizer.canonicalized(
            AssistantOutputSanitizer.Parts(
                content: message.content,
                thinkingContent: message.thinkingContent
            )
        )
    }

    private func combinedStreamingContent(for response: String) -> String {
        if streamingPrefix.isEmpty {
            return response
        }
        return streamingPrefix + response
    }

    private func failureContent(
        assistantID: UUID,
        conversationID: UUID?,
        existingPrefix: String,
        errorText: String
    ) -> String {
        if let existingMessage = historyManager.message(id: assistantID, in: conversationID) {
            if let preservedContent = failureContent(
                preserving: rawAssistantContent(for: existingMessage),
                errorText: errorText
            ) {
                return preservedContent
            }
        }

        if let preservedContent = failureContent(
            preserving: combinedStreamingContent(for: llmEngine.currentResponse),
            errorText: errorText
        ) {
            return preservedContent
        }

        if !existingPrefix.isEmpty {
            return String(existingPrefix.dropLast(existingPrefix.hasSuffix("\n\n") ? 2 : 0))
        }

        return errorText
    }

    private func failureContent(preserving rawAssistantContent: String, errorText: String) -> String? {
        let parts = AssistantOutputSanitizer.parts(from: rawAssistantContent)
        let hasVisibleAnswer = !parts.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasThinking = !(parts.thinkingContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        guard hasVisibleAnswer || hasThinking else { return nil }
        if hasVisibleAnswer {
            return rawAssistantContent
        }

        let trimmedRawContent = rawAssistantContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmedRawContent)\n\n\(errorText)"
    }

    private var hasRecoverableConversationContext: Bool {
        guard let model = modelManager.selectedModel else { return false }
        return llmEngine.hasConversationContext(for: model)
    }

    private func looksTruncated(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("```") { return false }

        if let lastScalar = trimmed.unicodeScalars.last {
            let terminalCharacters = CharacterSet(charactersIn: ".!?\"')]}”")
            if terminalCharacters.contains(lastScalar) {
                return false
            }
        }
        if endsWithEmoji(trimmed) { return false }

        let lowercased = trimmed.lowercased()
        let trailingFragments = [
            " and",
            " or",
            " but",
            " because",
            " so",
            " to",
            " with",
            " that",
            " which",
            " then",
            " of",
            " in",
            " for",
            " from",
            " as",
            " like",
            " such as",
            " including",
            " possibly",
            " probably",
            " likely",
            " maybe",
            " about",
            " around",
            " between"
        ]

        if trailingFragments.contains(where: { lowercased.hasSuffix($0) }) {
            return true
        }

        guard trimmed.count >= 60 else { return false }

        if let lastScalar = trimmed.unicodeScalars.last {
            let inconclusiveCharacters = CharacterSet(charactersIn: ",:;-(")
            if inconclusiveCharacters.contains(lastScalar) {
                return true
            }
            // A long reply that simply stops on an ordinary word - no
            // terminal punctuation, no emoji, no closing fence - is far more
            // often a cut generation than a deliberate ending. Exclude list
            // items and headings, which legitimately end this way.
            let lastLine = trimmed.split(separator: "\n").last.map(String.init) ?? trimmed
            let lastLineTrimmed = lastLine.trimmingCharacters(in: .whitespaces)
            let looksLikeListOrHeading = lastLineTrimmed.hasPrefix("- ")
                || lastLineTrimmed.hasPrefix("* ")
                || lastLineTrimmed.hasPrefix("#")
                || (lastLineTrimmed.first?.isNumber == true && lastLineTrimmed.contains(". "))
            if !looksLikeListOrHeading,
               CharacterSet.letters.contains(lastScalar) || CharacterSet.decimalDigits.contains(lastScalar) {
                return true
            }
        }

        return false
    }

    private func missingTerminalPunctuation(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 40 else { return false }
        guard let lastScalar = trimmed.unicodeScalars.last else { return false }

        // Emoji endings ("Let me know! 🎉") close a sentence just like
        // punctuation does.
        let terminalCharacters = CharacterSet(charactersIn: ".!?\"')]}”`")
        return !terminalCharacters.contains(lastScalar) && !endsWithEmoji(trimmed)
    }

    private func endsWithEmoji(_ content: String) -> Bool {
        guard let last = content.last else { return false }
        return last.unicodeScalars.contains { $0.properties.isEmojiPresentation }
    }

    private func likelyHitResponseLimit(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let configuredMaxTokens = llmEngine.lowPowerMode ? min(llmEngine.maxTokens, 768) : llmEngine.maxTokens
        guard configuredMaxTokens > 0 else { return false }

        let wordEstimate = Double(trimmed.split { $0.isWhitespace }.count) * 1.35
        let characterEstimate = Double(trimmed.count) / 4.0
        let estimatedTokens = max(wordEstimate, characterEstimate)

        return estimatedTokens >= Double(configuredMaxTokens) * 0.8
    }

    private func likelyHitResponseCharacterLimit(_ content: String) -> Bool {
        guard responseCharacterLimit > 0 else { return false }

        let visibleContent = AssistantOutputSanitizer
            .sanitize(content)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !visibleContent.isEmpty else { return false }
        return visibleContent.count >= max(responseCharacterLimit - 8, 1)
    }

    private func shouldAutoContinueResponse(
        visibleContent: String,
        autoContinuationCount: Int
    ) -> Bool {
        // On 4 GB phones one bounded pass is safer than chaining up to four
        // generations and growing the session cache for extra detail.
        guard !DeviceResourcePolicy.current.isLowMemoryPhone else { return false }
        guard autoContinuationCount < 3 else { return false }
        guard responseCharacterLimit == 0 else { return false }

        let trimmed = visibleContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // A missing sentence ending alone is not enough to continue: complete
        // answers that end in an emoji or a list item would keep getting
        // "continue" prompts and ramble past their natural end. Only continue
        // when the pass also ran out of output tokens, or when the text shows
        // a strong truncation signal (trailing conjunction, open clause), or
        // when the reply is an acknowledgment stub that promised content it
        // never delivered.
        return looksTruncated(trimmed) ||
            (likelyHitResponseLimit(trimmed) && missingTerminalPunctuation(trimmed)) ||
            isAcknowledgmentOnlyStub(trimmed)
    }

    /// Detects the small-model failure where the reply is only the first half
    /// of the learned "acknowledge, then deliver" shape — e.g. "Of course,
    /// happy to share a few more ideas." — and then stops because the sentence
    /// sounds complete. Deliberately narrow: an opener phrase up front, a
    /// deferral word promising content, and nothing that looks like payload.
    private func isAcknowledgmentOnlyStub(_ trimmed: String) -> Bool {
        guard trimmed.count <= 160 else { return false }
        // A question back to the user is a real reply, not a stub.
        guard !trimmed.contains("?") else { return false }
        // Digits, colons, line breaks, quotes, or code markers all indicate
        // the reply carries actual content.
        let payloadMarkers = CharacterSet(charactersIn: "0123456789:\n`\"“”*")
        guard trimmed.rangeOfCharacter(from: payloadMarkers) == nil else { return false }

        let folded = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let openers = [
            "sure", "of course", "happy to", "glad to", "absolutely",
            "certainly", "no problem", "great question", "i can help",
            "i'd be happy", "alright", "let's"
        ]
        guard openers.contains(where: { folded.hasPrefix($0) }) else {
            return false
        }

        let deferrals = [
            "share", "ideas", "suggestion", "option", "few more", "more of",
            "pick", "begin", "get started", "dive in", "go over", "look at",
            "help with", "walk you through", "ready to help"
        ]
        return deferrals.contains { folded.contains($0) }
    }

    private func adaptiveGenerationOverrides(
        prompt: String,
        model: ModelInfo,
        autoContinuationCount: Int,
        image: UIImage?
    ) -> LLMEngine.GenerationOverrides {
        let configuredMaxTokens = max(llmEngine.maxTokens, AIResponseDefaults.maxTokens)
        let estimatedPromptTokens = PromptBudgeter.estimatedTokenCount(prompt)

        let minimumOutputTokens: Int
        if autoContinuationCount > 0 {
            minimumOutputTokens = 768
        } else if image != nil {
            minimumOutputTokens = 384
        } else if estimatedPromptTokens < 300 {
            minimumOutputTokens = 1536
        } else if estimatedPromptTokens < 900 {
            minimumOutputTokens = 2048
        } else {
            minimumOutputTokens = 1024
        }

        let learnedBoost = AdaptiveTokenBudget.boost(for: model.id)
        let maxTokens = min(max(configuredMaxTokens, minimumOutputTokens) + learnedBoost, 4096)
        return LLMEngine.GenerationOverrides(
            temperature: nil,
            topP: nil,
            maxTokens: maxTokens
        )
    }

    /// Whether this pass's raw streamed output looks like it ran out of room
    /// rather than finishing naturally, so the learned budget can adapt.
    private func passLikelyHitTokenLimit(rawResponse: String, maxTokensUsed: Int) -> Bool {
        guard maxTokensUsed > 0 else { return false }
        let trimmed = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let wordEstimate = Double(trimmed.split { $0.isWhitespace }.count) * 1.35
        let characterEstimate = Double(trimmed.count) / 4.0
        let estimatedTokens = max(wordEstimate, characterEstimate)

        return estimatedTokens >= Double(maxTokensUsed) * 0.85
    }

    private func promptWithResponseLimit(_ prompt: String, existingPrefix: String) -> String {
        guard let additionalCharacterLimit = additionalResponseCharacterLimit() else {
            return prompt
        }

        return """
        Keep the final visible answer under \(additionalCharacterLimit) additional characters.
        Prioritize a complete answer over extra detail.
        If needed, shorten the wording instead of trailing off.

        \(prompt)
        """
    }

    private func additionalResponseCharacterLimit() -> Int? {
        guard responseCharacterLimit > 0 else { return nil }
        return responseCharacterLimit
    }

    private func visibleCharacterCount(in rawContent: String) -> Int {
        AssistantOutputSanitizer
            .sanitize(rawContent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .count
    }

    private func enforcedResponseLimit(for rawContent: String, existingPrefix: String = "") -> String {
        guard responseCharacterLimit > 0 else { return rawContent }

        let limit = visibleCharacterCount(in: existingPrefix) + responseCharacterLimit
        let parts = AssistantOutputSanitizer.parts(from: rawContent)
        let limitedVisibleContent = trimmedResponseContent(parts.content, limit: limit)
        guard limitedVisibleContent != parts.content else { return rawContent }

        return reconstructedAssistantContent(
            visibleContent: limitedVisibleContent,
            thinkingContent: parts.thinkingContent
        )
    }

    private func reconstructedAssistantContent(visibleContent: String, thinkingContent: String?) -> String {
        AssistantOutputSanitizer.canonicalized(
            AssistantOutputSanitizer.Parts(
                content: visibleContent.trimmingCharacters(in: .whitespacesAndNewlines),
                thinkingContent: thinkingContent
            )
        )
    }

    private func trimmedResponseContent(_ content: String, limit: Int) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        guard limit > 1 else { return String(trimmed.prefix(limit)) }

        let hardLimit = max(limit - 1, 1)
        let tentative = String(trimmed.prefix(hardLimit))

        let sentenceBoundary = tentative.lastIndex(where: { ".!?\n".contains($0) })
        let whitespaceBoundary = tentative.lastIndex(where: { $0.isWhitespace })
        let chosenBoundary = sentenceBoundary ?? whitespaceBoundary ?? tentative.index(before: tentative.endIndex)
        let clipped = tentative[...chosenBoundary].trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = clipped.isEmpty ? tentative.trimmingCharacters(in: .whitespacesAndNewlines) : String(clipped)

        if finalText.hasSuffix(".") || finalText.hasSuffix("!") || finalText.hasSuffix("?") {
            return finalText
        }

        return finalText + "…"
    }
    
    private func hasConsent(for modelID: String) -> Bool {
        UserDefaults.standard.bool(forKey: "modelConsent.\(modelID)")
    }

    private func setConsent(for modelID: String) {
        UserDefaults.standard.set(true, forKey: "modelConsent.\(modelID)")
    }

    private func invalidateGenerationSessionScope() {
        activeGenerationSessionScope = nil
        lastGenerationWasEphemeral = false
        activeMlxVisionImageKey = nil
    }

    private func generationSessionScope(
        for model: ModelInfo,
        conversationID: UUID?
    ) -> GenerationSessionScope {
        GenerationSessionScope(
            modelID: model.id,
            conversationID: conversationID,
            documentSignature: documentSignature(for: conversationID)
        )
    }

    private func documentSignature(for conversationID: UUID?) -> String {
        documentManager.documents(for: conversationID)
            .map { document in
                "\(document.id.uuidString):\(document.content.count)"
            }
            .joined(separator: "|")
    }

    private func promptIncludingRecentTranscript(
        _ prompt: String,
        conversationID: UUID?,
        assistantID: UUID,
        model: ModelInfo
    ) -> String {
        var priorMessages = historyManager.recentCompletedMessages(
            in: conversationID,
            excluding: assistantID,
            limit: 10
        )

        if priorMessages.last?.role == .user {
            priorMessages.removeLast()
        }

        let configuration = promptBudgetConfiguration(for: model)
        let promptTokens = PromptBudgeter.estimatedTokenCount(prompt)
        let deviceCap = DeviceResourcePolicy.current.isLowMemoryPhone ? 600 : 1_200
        var remainingTranscriptTokens = max(
            180,
            min(deviceCap, (configuration.inputTokenBudget - promptTokens) / 2)
        )
        var transcriptBlocks: [String] = []
        transcriptBlocks.reserveCapacity(8)
        for message in priorMessages.suffix(8).reversed() {
            guard remainingTranscriptTokens >= 60 else { break }
            let role = message.role == .user ? "User" : "Assistant"
            let boundedRaw = PromptBudgeter.boundedChatText(
                message.content,
                maxTokens: min(remainingTranscriptTokens, 260)
            )
            let content = AssistantOutputSanitizer
                .sanitize(boundedRaw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            let block = "\(role): \(content)"
            transcriptBlocks.insert(block, at: 0)
            remainingTranscriptTokens -= PromptBudgeter.estimatedTokenCount(block) + 8
        }
        let transcript = transcriptBlocks.joined(separator: "\n\n")

        // A summary persisted by an earlier rolling condensation covers the
        // turns that are too old for the transcript window below — without
        // it, reopening a long chat only remembers the last few messages.
        let storedSummaryRaw = historyManager.conversation(id: conversationID)?
            .rollingSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedSummary = PromptBudgeter.boundedChatText(
            storedSummaryRaw,
            maxTokens: DeviceResourcePolicy.current.isLowMemoryPhone ? 240 : 420
        )

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

    private func buildPromptContext(
        userText: String,
        conversationID: UUID?,
        model: ModelInfo?
    ) async -> (prompt: String, sourceTitles: [String], hasDocumentContext: Bool, retryPromptSeed: String) {
        let trimmedText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveRequest = trimmedText.isEmpty ? String(localized: "Summarize the documents in this chat.") : trimmedText

        guard let conversationID, documentManager.shouldSearchDocuments(in: conversationID) else {
            return (budgetedGenerationPrompt(trimmedText, model: model), [], false, effectiveRequest)
        }

        let configuration = promptBudgetConfiguration(for: model)
        let usesCompactInstructions = configuration.inputTokenBudget < Self.compactInstructionsBudgetThreshold
        let attachedDocuments = documentManager.documents(for: conversationID)
        let prefersNewestAttachment = requestPrefersNewestAttachment(effectiveRequest)
        let latestAttachedDocumentSnippet = prefersNewestAttachment
            ? latestAttachedDocumentSnippet(for: conversationID)
            : nil

        withAnimation(.easeInOut(duration: 0.2)) {
            retrievalStatus = String(localized: "Searching documents…")
        }
        defer {
            withAnimation(.easeInOut(duration: 0.2)) {
                retrievalStatus = nil
            }
        }

        let snippets = await documentManager.retrieveRelevantSnippets(
            for: effectiveRequest,
            conversationID: conversationID,
            limit: 4
        )

        if let located = snippets.first(where: { $0.chunk.sourceLocationLabel != nil }),
           let label = located.chunk.sourceLocationLabel {
            retrievalStatus = String(
                format: String(localized: "Reading %@…", defaultValue: "Reading %@…"),
                label
            )
        }

        let strongSnippets = snippets.filter { item in
            item.document.id == attachedDocuments.first?.id || item.chunk.score >= 0.22
        }

        if !snippets.isEmpty {
            var documentSnippets = snippets.map { item in
                PromptBudgeter.DocumentSnippet(
                    title: item.document.name,
                    location: item.chunk.sourceLocationLabel,
                    content: item.chunk.content
                )
            }
            if let latestAttachedDocumentSnippet {
                // The ranked passages lead, because they are the ones selected to
                // answer this question. The newest attachment still rides along so
                // that "this"/"the attachment" style requests resolve against it,
                // but it never replaces retrieval: a question can name the
                // attachment and still depend on text far past its opening.
                documentSnippets = strongSnippets.map { item in
                    PromptBudgeter.DocumentSnippet(
                        title: item.document.name,
                        location: item.chunk.sourceLocationLabel,
                        content: item.chunk.content
                    )
                }
                documentSnippets.removeAll { snippet in
                    snippet.title == latestAttachedDocumentSnippet.title &&
                    snippet.location == latestAttachedDocumentSnippet.location
                }
                // Shrink the orientation snippet when ranked passages accompany it,
                // so the head of the document cannot consume the whole budget and
                // push the passages that actually answer the question out.
                let orientationSnippet = documentSnippets.isEmpty
                    ? latestAttachedDocumentSnippet
                    : PromptBudgeter.DocumentSnippet(
                        title: latestAttachedDocumentSnippet.title,
                        location: latestAttachedDocumentSnippet.location,
                        content: PromptBudgeter.snippetSizedText(
                            latestAttachedDocumentSnippet.content,
                            maxTokens: 260
                        )
                    )
                documentSnippets.append(orientationSnippet)
            }
            let instructions = """
            \(documentAnsweringInstructions(compact: usesCompactInstructions))
            The retrieved passages are ranked by relevance. Use higher-ranked passages and exact matches first.
            Do not write "[Source n]" markers in the answer. The app shows the sources beneath your reply; name the section or heading in prose instead when it helps the reader.
            """
            let reservedTokens = PromptBudgeter.estimatedTokenCount(instructions + "\n\nUser request: \(effectiveRequest)")
            let package = PromptBudgeter.documentPackage(
                snippets: documentSnippets,
                configuration: configuration,
                reservedTokens: reservedTokens
            )
            let finalPrompt = PromptBudgeter.budgetedPrompt(
                instructions: instructions,
                context: contextWithOmissionNote(package.context, omittedCount: package.omittedCount),
                userRequest: effectiveRequest,
                configuration: configuration
            )

            return (
                finalPrompt,
                package.sourceTitles,
                true,
                effectiveRequest
            )
        }

        let fallbackDocuments = documentManager.documents(for: conversationID).prefix(2)
        let fallbackSourceDocuments = latestAttachedDocumentSnippet != nil
            ? fallbackDocuments.prefix(1)
            : fallbackDocuments
        let documentSnippets = fallbackSourceDocuments.map { document in
            PromptBudgeter.DocumentSnippet(
                title: document.name,
                location: nil,
                content: PromptBudgeter.snippetSizedText(document.content)
            )
        }
        let instructions = """
        \(documentAnsweringInstructions(compact: usesCompactInstructions))
        """
        let reservedTokens = PromptBudgeter.estimatedTokenCount(instructions + "\n\nUser request: \(effectiveRequest)")
        let package = PromptBudgeter.documentPackage(
            snippets: Array(documentSnippets),
            configuration: configuration,
            reservedTokens: reservedTokens
        )
        let finalPrompt = PromptBudgeter.budgetedPrompt(
            instructions: instructions,
            context: contextWithOmissionNote(package.context, omittedCount: package.omittedCount),
            userRequest: effectiveRequest,
            configuration: configuration
        )

        return (
            finalPrompt,
            package.sourceTitles,
            true,
            effectiveRequest
        )
    }

    private func latestAttachedDocumentSnippet(for conversationID: UUID) -> PromptBudgeter.DocumentSnippet? {
        guard let document = documentManager.documents(for: conversationID).first else {
            return nil
        }

        return PromptBudgeter.DocumentSnippet(
            title: document.name,
            location: String(localized: "Newest attached document"),
            content: PromptBudgeter.snippetSizedText(document.content)
        )
    }

    /// Budget below which the instructions are condensed. Apple's Foundation
    /// model and low-memory phones (capped at 2,048 context tokens by
    /// `DeviceResourcePolicy.maximumContextTokens`) can land near the floor of
    /// `PromptBudgeter.Configuration`, and instructions are charged against the
    /// same budget as the passages — on a small window the full wording would
    /// buy guidance at the price of the evidence it is meant to govern.
    private static let compactInstructionsBudgetThreshold = 1_500

    private func documentAnsweringInstructions(compact: Bool) -> String {
        guard !compact else {
            return """
            You have access to documents that belong only to this chat.
            The text below is extracted from the user's own attachment; answer from it rather than saying you cannot open a file.
            A passage labelled "Newest attached document" is the opening of the most recent attachment; prefer it for "this", "that", or "the receipt", and the ranked passages otherwise.
            State every obligation, deadline, amount, condition, and exception the passages contain, even if that runs long, but add nothing they do not state.
            When asked for exact wording, quote it verbatim in quotation marks.
            """
        }

        return """
        You have access to documents that belong only to this chat.
        Treat document text shown below as readable extracted text from the user's attachment, not as an external file.
        When the user asks whether you can see, read, inspect, or describe a document, answer from the extracted text instead of saying you cannot provide a visual receipt or asking the user to provide details already present in the source.
        A passage labelled "Newest attached document" is the opening of the most recently attached file; prefer it for references to "this", "that", "there", "the receipt", "the OCR", or the current attachment, and prefer the ranked passages for every other question.
        If useful text is present, summarize the concrete contents directly. If it is limited, say what is available and what is missing.
        Here completeness outweighs the usual preference for short answers: state every obligation, deadline, amount, condition, and exception the passages contain, even when that takes more than a few sentences. Cover the whole of a provision rather than its first requirement.
        Length must come from the passages, never from padding: add nothing they do not state, and do not restate a point to make the answer longer.
        Do not join separate provisions with "only if", "otherwise", "unless", or "instead" unless the passages state that relationship. Where the document keeps two requirements separate, report them separately, even when one appears to be the alternative to the other.
        When the user asks for the exact wording of a clause, reproduce it verbatim in quotation marks before explaining it.
        """
    }

    /// Opens the Document Sources sheet scoped to the reply's evidence. Source
    /// titles are stored as "name · location", with merged runs joined by "-"
    /// ("Page 2-Page 3"), so the location half is split back into the section
    /// titles the drawer's cards carry.
    private func showSources(for message: ChatMessage) {
        guard let conversationID = historyManager.currentConversationID else { return }
        let documents = documentManager.documents(for: conversationID) + documentManager.libraryDocuments
        let separator = " · "

        var matchedDocument: ConversationDocument?
        var titles: Set<String> = []
        for sourceTitle in message.sourceTitles {
            let components = sourceTitle.components(separatedBy: separator)
            guard let name = components.first else { continue }
            guard let document = documents.first(where: { $0.name == name }) else { continue }
            if matchedDocument == nil {
                matchedDocument = document
            }
            guard document.id == matchedDocument?.id, components.count > 1 else { continue }
            let location = components.dropFirst().joined(separator: separator)
            for part in location.components(separatedBy: "-") {
                titles.insert(part.trimmingCharacters(in: .whitespaces))
            }
        }

        guard let matchedDocument else { return }
        sourceHighlightTitles = titles
        selectedDocumentForSources = matchedDocument
    }

    private func requestPrefersNewestAttachment(_ request: String) -> Bool {
        let normalized = request.lowercased()
        let attachmentPhrases = [
            "current attachment",
            "attached document",
            "attached file",
            "the attachment",
            "this attachment",
            "this document",
            "that document",
            "the receipt",
            "the ocr"
        ]
        if attachmentPhrases.contains(where: { normalized.contains($0) }) {
            return true
        }

        let tokens = Set(
            normalized
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        )
        let currentAttachmentTerms: Set<String> = [
            "receipt",
            "this",
            "that",
            "there",
            "it",
            "see",
            "read",
            "inspect",
            "describe",
            "current",
            "attached",
            "attachment",
            "ocr"
        ]
        return !tokens.isDisjoint(with: currentAttachmentTerms)
    }

    private func debugSnippetSummary(_ snippets: [PromptBudgeter.DocumentSnippet]) -> String {
        snippets.enumerated().map { index, snippet in
            "#\(index + 1):\(snippet.title)@\(snippet.location ?? "nil"):chars=\(snippet.content.count):preview='\(debugPromptPreview(snippet.content, maxLength: 80))'"
        }.joined(separator: " | ")
    }

    private func debugPromptPreview(_ text: String, maxLength: Int = 180) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxLength else { return normalized }
        return String(normalized.prefix(maxLength)) + "..."
    }

    private func budgetedGenerationPrompt(_ prompt: String, model: ModelInfo?) -> String {
        PromptBudgeter.finalPromptGuard(
            prompt,
            configuration: promptBudgetConfiguration(for: model)
        )
    }

    private func promptBudgetConfiguration(for model: ModelInfo?) -> PromptBudgeter.Configuration {
        let selected = model ?? modelManager.selectedModel ?? ModelInfo.appleFoundation
        return PromptBudgeter.Configuration(
            model: selected,
            maxOutputTokens: llmEngine.maxTokens,
            lowPowerMode: llmEngine.lowPowerMode
        )
    }

    private func contextWithOmissionNote(_ context: String, omittedCount: Int) -> String {
        guard omittedCount > 0 else { return context }
        let note = "[\(omittedCount) additional source passage\(omittedCount == 1 ? "" : "s") omitted to fit the model context.]"
        guard !context.isEmpty else { return note }
        return context + "\n\n" + note
    }

    private func documentIconName(for document: ConversationDocument) -> String {
        let ext = document.sourceURL?.pathExtension.lowercased() ?? ""
        switch ext {
        case "pdf":
            return "doc.richtext.fill"
        case "rtf", "rtfd":
            return "doc.richtext"
        case "doc", "docx":
            return "doc.text.fill"
        default:
            return "doc.plaintext"
        }
    }

}

// MARK: - Auto Selection Toast

/// The auto model-selection toast. Owns a draining progress line so the
/// remaining time is legible, dismisses on tap, and honors Reduce Motion.
private struct AutoSelectionToastView: View {
    let message: String
    let autoDismissAfter: TimeInterval
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 1

    var body: some View {
        Button(action: onDismiss) {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.purple)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.purple.opacity(0.12)))
                        .accessibilityHidden(true)

                    Text(message)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.adaptive(white: 0.15))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }

                if !reduceMotion {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.purple.opacity(0.35))
                            .frame(width: max(0, geo.size.width * progress))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 3)
                    .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.adaptiveBorder(opacity: 0.6), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityHint(Text(String(localized: "Dismisses this notification.")))
        .onAppear {
            UIAccessibility.post(notification: .announcement, argument: message)
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: autoDismissAfter)) {
                progress = 0
            }
        }
    }
}

// MARK: - Send Button Style



private extension UTType {
    static let docx = UTType(filenameExtension: "docx") ?? .data
    static let markdown = UTType(filenameExtension: "md") ?? .plainText
    static let jsonDocument = UTType(filenameExtension: "json") ?? .plainText
    static let commaSeparatedText = UTType(filenameExtension: "csv") ?? .plainText
    static let logText = UTType(filenameExtension: "log") ?? .plainText
}

#Preview {
    ChatView()
        .environment(LLMEngine())
        .environment(ChatHistoryManager())
        .environment(ModelManager())
        .environment(MonetizationManager())
        .environment(SpeechManager())
}
