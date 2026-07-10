import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import Shimmer

struct ChatView: View {
    @Environment(LLMEngine.self) private var llmEngine
    @Environment(ChatHistoryManager.self) private var historyManager
    @Environment(ModelManager.self) private var modelManager
    @Environment(SpeechManager.self) private var speechManager
    @Environment(AssistantMemoryStore.self) private var memoryStore
    @Environment(MonetizationManager.self) private var monetizationManager
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
    @AppStorage("voiceConversationMode") private var voiceConversationMode = false
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
    @State private var contextLimitWarningDismissed = false
    @State private var streamingPrefix = ""
    @State private var speechStreamingSpokenCharCount: Int = 0
    @State private var selectedImage: UIImage?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var activeStreamingConversationID: UUID?
    @State private var activeStreamingAssistantID: UUID?
    @State private var pendingSessionReset = false
    @State private var activeGenerationSessionScope: GenerationSessionScope?
    @State private var lastGenerationWasEphemeral: Bool = false
    @State private var activeMlxVisionImageKey: String?
    @State private var selectedDocumentForSources: ConversationDocument?
    @State private var generatedFollowUpSuggestions: [UUID: [String]] = [:]
    // Scroll state: a single pending auto-scroll task (coalesced so rapid
    // triggers, e.g. one per streamed token, collapse into one scroll per
    // frame instead of stacking up) and whether the view is currently
    // "pinned" to the bottom. Auto-scroll only fires while pinned, so a user
    // who scrolls up to re-read history during generation isn't yanked back
    // down — that fight between the user's scroll and a forced scrollTo was
    // the main source of the visible jitter.
    @State private var pendingAutoScrollTask: Task<Void, Never>?
    @State private var isPinnedToBottom = true
    @AppStorage("systemPrompt") private var systemPrompt = AIResponseDefaults.defaultSystemPrompt
    @AppStorage("responseCharacterLimit") private var responseCharacterLimit = AIResponseDefaults.responseCharacterLimit
    @AppStorage("smartReplyStylesEnabled") private var smartReplyStylesEnabled = false
    @AppStorage("inChatSearchEnabled") private var inChatSearchEnabled = false

    @State private var editingMessage: ChatMessage?
    @State private var editedMessageText: String = ""
    @State private var isEditSheetPresented = false
    @State private var inChatSearchText: String = ""
    @State private var isInChatSearchActive = false


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
                    guard monetizationManager.canUse(.voiceMode) else {
                        voiceConversationMode = false
                        upgradeFeature = .voiceMode
                        return
                    }
                    startListeningIfPossible()
                } else {
                    speechManager.stopListening()
                    speechManager.stopSpeaking()
                }
            }
            .onChange(of: siriPendingQuery) {
                guard let query = siriPendingQuery,
                      !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return }
                siriPendingQuery = nil
                messageText = query
                sendMessage()
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
                .environmentObject(modelManager)
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
                UpgradeView(feature: feature)
                    .environment(monetizationManager)
            }
            .sheet(item: $selectedDocumentForSources) { document in
                DocumentSourceDrawerView(document: document)
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
            }
            .onDisappear {
                speechManager.stopSpeaking()
                cancelDocumentExtraction(showError: false)
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
            .onChange(of: llmEngine.currentResponse) {
                guard llmEngine.state == .generating else { return }
                guard voiceConversationMode else { return }
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
                            guard guardCanAddAttachment(action: String(localized: "adding a photo")) else { return }
                            dismissKeyboard()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                showAttachmentOptions = false
                            }
                            isPhotoPickerPresented = true
                        },
                        onDocumentImport: {
                            guard guardCanAddAttachment(action: String(localized: "adding a document")) else { return }
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
                            }
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.body.weight(.medium))
                            .foregroundStyle(isInChatSearchActive ? Color.blue : Color.adaptive(white: 0.3))
                            .frame(width: 32, height: 32)
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
    }

    private var warmingUpIndicator: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption.weight(.semibold))

            Text(String(localized: "Warming up"))
                .font(.caption.weight(.semibold))
                .shimmering(active: true, bandSize: 0.22)
        }
        .foregroundStyle(.blue)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.45), lineWidth: 1)
        )
        .accessibilityLabel(String(localized: "Warming up"))
    }

    // MARK: - In-Chat Search

    private var inChatSearchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.medium))
                .foregroundStyle(Color.adaptive(white: 0.45))

            TextField(String(localized: "Search in conversation…"), text: $inChatSearchText)
                .textFieldStyle(.plain)
                .font(.body)

            if !inChatSearchText.isEmpty {
                Text(String(format: String(localized: "%lld matches", defaultValue: "%lld matches"), Int64(inChatSearchMatchCount)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.adaptive(white: 0.5))
                    .fixedSize()
            }

            Button {
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
    }

    private var inChatSearchMatchCount: Int {
        guard !inChatSearchText.isEmpty else { return 0 }
        return historyManager.currentMessages.filter {
            $0.content.localizedCaseInsensitiveContains(inChatSearchText)
        }.count
    }

    private func messageMatchesSearch(_ message: ChatMessage) -> Bool {
        guard isInChatSearchActive, !inChatSearchText.isEmpty else { return true }
        return message.content.localizedCaseInsensitiveContains(inChatSearchText)
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
                                showsQuickActions: message.role == .assistant
                                    && historyManager.currentMessages.last?.id == message.id
                                    && !message.isStreaming
                                    && canStartChatRequest,
                                liveStreamingContent: liveStreamingContent(for: message)
                            )
                                .id(message.id)
                                .opacity(messageMatchesSearch(message) ? 1.0 : 0.25)
                                .animation(.easeInOut(duration: 0.2), value: inChatSearchText)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation(.spring(response: 0.3)) {
                                            historyManager.deleteMessage(id: message.id)
                                        }
                                    } label: {
                                        Label(String(localized: "Delete"), systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    if message.role == .assistant,
                                       historyManager.currentMessages.last?.id == message.id,
                                       canStartChatRequest {
                                        Button {
                                            Self.mediumHaptic.impactOccurred()
                                            regenerate(message: message, style: .more)
                                        } label: {
                                            Label(String(localized: "Regenerate"), systemImage: "arrow.clockwise")
                                        }
                                        .tint(.blue)
                                    }
                                }
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
            // Re-pin when the user scrolls (or is auto-scrolled) back near
            // the bottom. This direction only sets isPinnedToBottom = true —
            // never false. Driving "false" from geometry too was the bug:
            // while streaming, each new line wraps and grows contentSize
            // before contentOffset catches up, so distanceFromBottom spikes
            // for a frame even though the user did nothing. That false
            // unpin skipped the next auto-scroll, the content kept growing
            // underneath, and the eventual catch-up jump was the jitter.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let distanceFromBottom = geometry.contentSize.height
                    - geometry.containerSize.height
                    - geometry.contentOffset.y
                return distanceFromBottom < 48
            } action: { _, isNearBottom in
                guard isNearBottom, !isPinnedToBottom else { return }
                chatDiagnostic("scroll pinnedToBottom false -> true (reached bottom)")
                isPinnedToBottom = true
            }
            // The only thing that should unpin auto-scroll is the user
            // deliberately dragging the list (revealing earlier messages).
            // Tied to an actual touch gesture instead of geometry so it
            // can't be confused with content growing under a stationary
            // viewport.
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard value.translation.height > 12, isPinnedToBottom else { return }
                        chatDiagnostic("scroll pinnedToBottom true -> false (user dragged)")
                        isPinnedToBottom = false
                    }
            )
            .onChange(of: historyManager.currentMessages.count) {
                // A new message (the user's own send, or the assistant
                // placeholder that follows it) always re-pins and jumps to
                // bottom — this is a deliberate, discrete event, not a
                // continuous stream, so a single animated scroll is correct.
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
                isPinnedToBottom = true
                scrollToTop(proxy: proxy)
            }
            .onChange(of: llmEngine.currentResponse) {
                // Update the last message in history if it's currently streaming
                if let conversationID = activeStreamingConversationID,
                   let assistantID = activeStreamingAssistantID,
                   let message = historyManager.message(id: assistantID, in: conversationID),
                   message.role == .assistant && message.isStreaming &&
                   combinedStreamingContent(for: llmEngine.currentResponse) != message.content {
                    historyManager.updateMessage(
                        id: assistantID,
                        in: conversationID,
                        content: combinedStreamingContent(for: llmEngine.currentResponse),
                        isStreaming: true
                    )
                }
                requestAutoScroll(proxy: proxy)
            }
        }
    }

    private func scrollToTop(proxy: ScrollViewProxy) {
        pendingAutoScrollTask?.cancel()
        pendingAutoScrollTask = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            proxy.scrollTo("top", anchor: .top)
        }
    }

    /// Discrete, user-driven jump to bottom (new message sent/received,
    /// conversation switched). Always runs, re-pins, and cancels any
    /// in-flight streaming auto-scroll so the two never fight.
    private func scrollToBottomForced(proxy: ScrollViewProxy, animated: Bool = true) {
        chatDiagnostic("scroll forced bottom (animated=\(animated))")
        pendingAutoScrollTask?.cancel()
        pendingAutoScrollTask = nil
        isPinnedToBottom = true
        let scrollAction = { proxy.scrollTo("bottom", anchor: .bottom) }
        if animated {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                scrollAction()
            }
        } else {
            scrollAction()
        }
    }

    /// Continuous, content-driven follow during streaming. Only acts while
    /// the user is pinned to the bottom, and coalesces rapid-fire calls
    /// (one per streamed token) into a single scroll per frame instead of
    /// queuing one delayed scroll per token — the prior queuing is what let
    /// several scrollTo calls land out of order while the content was still
    /// reflowing, producing visible jitter.
    private func requestAutoScroll(proxy: ScrollViewProxy) {
        guard isPinnedToBottom else {
            chatDiagnostic("scroll auto-scroll skipped (not pinned to bottom)")
            return
        }
        pendingAutoScrollTask?.cancel()
        pendingAutoScrollTask = Task { @MainActor in
            // One frame's worth of coalescing window, not a fixed artificial delay.
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else {
                chatDiagnostic("scroll auto-scroll coalesced (superseded by a newer request)")
                return
            }
            // No animation: an animated scrollTo competing with the content
            // above it growing every token is exactly what produced the
            // bounce. Snapping keeps the bottom anchor glued in place while
            // streaming; the discrete jumps above stay animated.
            chatDiagnostic("scroll auto-scroll fired")
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    // MARK: - Empty State
    
    private var emptyStateView: some View {
        ChatEmptyStateView(
            isInputFocused: isInputFocused,
            selectedModelName: modelManager.selectedModel?.name,
            downloadingModelName: activeDownloadingModel?.name,
            isWarmingUp: llmEngine.isPrewarming,
            isAppleIntelligenceAvailable: modelManager.isAppleIntelligenceAvailable,
            personalityLabel: currentPersonalityLabel,
            onDownloadModel: {
                showModelDownloadSheet = true
            },
            onSuggestion: { text in
                messageText = text
                sendMessage()
            }
        )
    }

    private var pendingSelectedModel: ModelInfo? {
        modelManager.selectedModelID.flatMap { id in
            modelManager.models.first(where: { $0.id == id })
        }
    }

    private var activeDownloadingModel: (name: String, progress: Double?)? {
        guard let pendingSelectedModel else { return nil }
        if case .downloading(let progress, _) = pendingSelectedModel.downloadState {
            return (pendingSelectedModel.name, progress)
        }
        return nil
    }

    // MARK: - Input View
    
    private var inputView: some View {
        VStack(spacing: 0) {
            if !historyManager.currentMessages.isEmpty {
                Divider()
            }
            
            VStack(spacing: 8) {
                if shouldShowContextLimitWarning {
                    contextLimitBanner
                }

                if voiceConversationMode {
                    voiceModeBanner
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
                        Button(String(localized: "Cancel")) {
                            cancelDocumentExtraction(showError: false)
                        }
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
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
                        guard guardCanAddAttachment(action: String(localized: "adding an attachment")) else { return }
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
                            .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
                    )
                    
                    if llmEngine.state == .generating {
                        // Stop button during generation
                        Button(action: stopGeneration) {
                            Image(systemName: "stop.fill")
                                .font(.body.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.black)
                                .clipShape(Circle())
                        }
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
                                            .easeOut(duration: 1).repeatForever(autoreverses: false),
                                            value: speechManager.isListening
                                        )
                                )
                        }
                        .accessibilityLabel(String(localized: "Stop listening"))
                    } else if messageText.isEmpty && currentConversationDocuments.isEmpty {
                        microphoneControls
                    } else {
                        // Send button
                        Button(action: sendMessage) {
                            Image(systemName: "arrow.up")
                                .font(.body.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(sendButtonGradient)
                                .clipShape(Circle())
                                .shadow(color: canSend ? .blue.opacity(0.3) : .clear, radius: 8, y: 4)
                        }
                        .disabled(!canSend)
                        .scaleEffect(canSend ? 1.0 : 0.9)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: canSend)
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
                        Text("\(messageText.count) characters")
                            .font(.caption2.weight(.medium))
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
        return LinearGradient(colors: [.black], startPoint: .top, endPoint: .bottom)
    }
    
    private var canSend: Bool {
        let hasInput = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !currentConversationDocuments.isEmpty || selectedImage != nil
        let hasModel = modelManager.selectedModel != nil
        return hasInput && hasModel && canStartChatRequest && !monetizationManager.hasReachedFreeDailyMessageLimit
    }

    private var canStartChatRequest: Bool {
        !documentImportState.isActive && llmEngine.state != .generating && llmEngine.state != .loading
    }

    private var canStartAttachment: Bool {
        canStartChatRequest && !speechManager.isListening
    }

    private var currentChatHasAttachment: Bool {
        selectedImage != nil || !currentConversationDocuments.isEmpty || currentChatHasSentImageAttachment
    }

    private var currentChatHasSentImageAttachment: Bool {
        historyManager.messages(in: historyManager.currentConversationID).contains { message in
            message.imageFileName != nil
        }
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

    private func guardCanAddAttachment(action: String) -> Bool {
        guard guardCanStartAttachment(action: action) else { return false }
        guard !currentChatHasAttachment else {
            showExtractionNotice(String(format: String(localized: "Remove the current attachment before %@."), action))
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
                            selectedDocumentForSources = document
                        } label: {
                            documentChipLabel(for: document)
                        }
                        .buttonStyle(.plain)

                        Button {
                            guard let conversationID = historyManager.currentConversationID else { return }
                            withAnimation(.spring(response: 0.3)) {
                                documentManager.removeDocument(id: document.id, from: conversationID)
                            }
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
            .accessibilityLabel(String(localized: "Dismiss"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .transition(.opacity)
    }

    private var voiceModeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: speechManager.isListening ? "waveform.circle.fill" : "waveform.circle")
                .foregroundStyle(speechManager.isListening ? .red : .blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Conversation Mode"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.adaptive(white: 0.15))
                Text(speechManager.isListening ? String(localized: "Listening for your next turn") : String(localized: "Replies are spoken and listening restarts automatically"))
                    .font(.caption2)
                    .foregroundStyle(Color.adaptive(white: 0.5))
            }

            Spacer()

            Toggle(String(localized: "Conversation Mode"), isOn: $voiceConversationMode)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func usageLimitToast(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)

            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
    }

    private func extractionNoticeToast(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.orange.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
    }

    private func speakReplyButton(for message: ChatMessage) -> some View {
        Button {
            toggleSpeechPlayback(for: message)
        } label: {
            Label(
                speechManager.isSpeaking ? String(localized: "Stop Speaking") : String(localized: "Speak Reply"),
                systemImage: speechManager.isSpeaking ? "speaker.slash.fill" : "speaker.wave.2.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.blue)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.adaptiveCard.opacity(0.9))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.04), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
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
            if voiceConversationMode {
                Button {
                    voiceConversationMode = false
                } label: {
                    Image(systemName: "waveform.slash")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.adaptive(white: 0.35))
                        .frame(width: 36, height: 36)
                        .background(Color.adaptiveCard.opacity(0.9))
                        .clipShape(Circle())
                }
                .accessibilityLabel(String(localized: "Turn off conversation mode"))
            }

            Button {
                if voiceConversationMode {
                    startListeningIfPossible()
                } else {
                    toggleListening()
                }
            } label: {
                Image(systemName: voiceConversationMode ? "waveform" : "mic.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.black)
                    .clipShape(Circle())
            }
            .accessibilityLabel(String(localized: "Start voice input"))
        }
    }
    
    // MARK: - Actions
    
    private func handleFileImport(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard let conversationID = historyManager.currentConversationID else { return }
        guard guardCanAddAttachment(action: String(localized: "adding a document")) else { return }

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
                await documentManager.addDocumentToConversation(from: document, conversationID: conversationID)
                try Task.checkCancellation()
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
        case .extracting(let id, let fileName, let task), .indexing(let id, let fileName, let task):
            chatDiagnostic("document import cancel requested id=\(id) file=\(fileName) showError=\(showError)")
            task.cancel()
        case .idle:
            break
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

    private func startListeningIfPossible() {
        guard llmEngine.state != .generating else { return }
        guard !speechManager.isSpeaking else { return }
        guard speechManager.isSpeechQueueEmpty else { return }
        do {
            try speechManager.startListening()
        } catch {
            voiceError = error.localizedDescription
            voiceConversationMode = false
        }
    }
    
    private func sendMessage() {
        if monetizationManager.hasReachedFreeDailyMessageLimit {
            showUsageLimitToast()
            return
        }
        guard guardCanStartChatRequest(action: String(localized: "sending")) else { return }
        guard canSend else { return }
        Self.lightHaptic.impactOccurred()

        guard let model = modelManager.selectedModel else { return }
        if !hasConsent(for: model.id) {
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
        if let imageToSend {
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
        selectedPhotoItem = nil
        isInputFocused = false
        
        // Generate response
        Task {
            guard let model = modelManager.selectedModel else { return }
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
        let message = String(localized: "Free plan limit reached.")
        showUsageToast(message)
    }

    private func showUsageToastIfNeededAfterSend() {
        guard !monetizationManager.hasPro else { return }

        if monetizationManager.hasReachedFreeDailyMessageLimit {
            showUsageLimitToast()
            return
        }

        // Count down each of the last three so the limit never surprises.
        let remaining = monetizationManager.freeMessagesRemainingToday
        guard remaining <= 3 else { return }
        showUsageToast(String(format: String(
            localized: "%lld free messages left.",
            defaultValue: "%lld free messages left."
        ), Int64(remaining)))
    }

    private func showUsageToast(_ message: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            usageLimitToastMessage = message
        }

        Task {
            try? await Task.sleep(for: .seconds(2.5))
            await MainActor.run {
                if usageLimitToastMessage == message {
                    withAnimation(.easeOut(duration: 0.2)) {
                        usageLimitToastMessage = nil
                    }
                }
            }
        }
    }

    private func showExtractionNotice(_ message: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            extractionNoticeMessage = message
        }

        Task {
            try? await Task.sleep(for: .seconds(3.0))
            await MainActor.run {
                if extractionNoticeMessage == message {
                    withAnimation(.easeOut(duration: 0.2)) {
                        extractionNoticeMessage = nil
                    }
                }
            }
        }
    }

    private func chatDiagnostic(_ message: String) {
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
        generationOverrides: LLMEngine.GenerationOverrides? = nil
    ) async {
        defer {
            finalizeStreamingMessageIfNeeded(
                assistantID: assistantID,
                conversationID: conversationID,
                assistantSourceTitles: assistantSourceTitles
            )
        }

        do {
            guard let model = modelManager.selectedModel else {
                chatDiagnostic("response blocked no-model assistantID=\(assistantID) conversation=\(conversationID?.uuidString ?? "nil")")
                let errorMessage = ChatMessage(role: .assistant, content: String(localized: "Please select or download a model first (Settings > Models)."))
                historyManager.addMessage(errorMessage, to: conversationID)
                return
            }

            chatDiagnostic("response start assistantID=\(assistantID) conversation=\(conversationID?.uuidString ?? "nil") model=\(model.id) engine=\(model.engine.rawValue) promptChars=\(prompt.count) retry=\(missingAnswerRetryCount)")
            streamingPrefix = existingPrefix
            speechStreamingSpokenCharCount = AssistantOutputSanitizer.sanitize(existingPrefix)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .count
            llmEngine.currentResponse = ""
            activeStreamingConversationID = conversationID
            activeStreamingAssistantID = assistantID

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
                monetizationManager.registerFreeMessageIfNeeded(for: prompt)
                showUsageToastIfNeededAfterSend()
            }

            let continuityPrompt = shouldResetSession
                ? promptIncludingRecentTranscript(
                    prompt,
                    conversationID: conversationID,
                    assistantID: assistantID
                )
                : prompt

            let effectiveOverrides = generationOverrides ?? adaptiveGenerationOverrides(
                prompt: continuityPrompt,
                model: model,
                autoContinuationCount: autoContinuationCount,
                image: image
            )
            chatDiagnostic("response generate begin assistantID=\(assistantID) shouldReset=\(shouldResetSession)")
            try await llmEngine.generate(
                prompt: budgetedGenerationPrompt(
                    promptWithResponseLimit(continuityPrompt, existingPrefix: existingPrefix),
                    model: model
                ),
                overrides: effectiveOverrides,
                image: image
            )
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
                let errorText = userFacingErrorText(from: message)
                chatDiagnostic("response engine error assistantID=\(assistantID) error=\(message)")
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
                llmEngine.currentResponse = ""
                streamingPrefix = ""
                invalidateGenerationSessionScope()
                return
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
            chatDiagnostic("response finalized assistantID=\(assistantID) contentChars=\(finalizedContent.count) contentWords=\(wordCount(in: finalizedContent))")
            activeGenerationSessionScope = nextSessionScope
            lastGenerationWasEphemeral = isEphemeral
            if let mlxVisionImageKey {
                activeMlxVisionImageKey = mlxVisionImageKey
            } else if shouldResetSession {
                activeMlxVisionImageKey = nil
            }

            await refineConversationInsightsIfNeeded(
                conversationID: conversationID,
                model: model,
                assistantID: assistantID
            )
            rememberUserFactsIfNeeded(conversationID: conversationID, assistantID: assistantID)

            llmEngine.currentResponse = ""
            streamingPrefix = ""

            let spokenReply = historyManager.message(id: assistantID, in: conversationID)?
                .content
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if voiceConversationMode, !spokenReply.isEmpty {
                speechManager.speak(spokenReply)
            } else if voiceConversationMode {
                startListeningIfPossible()
            }
        } catch {
            chatDiagnostic("response failed assistantID=\(assistantID) error=\(error.localizedDescription)")
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
        llmEngine.currentResponse = ""
        streamingPrefix = ""
        ReviewPromptManager.noteSuccessfulResponse()
    }

    // Fire-and-forget cross-chat memory extraction from the latest user
    // message. Runs on an isolated on-device session, so it never blocks the
    // reply and does nothing on devices without Apple Intelligence.
    private func rememberUserFactsIfNeeded(conversationID: UUID?, assistantID: UUID) {
        guard memoryStore.isEnabled else { return }
        guard let conversation = historyManager.conversation(id: conversationID),
              let userMessage = conversation.messages.last(where: { $0.role == .user }) else {
            return
        }
        let text = userMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Very short messages ("thanks", "continue") never contain durable facts.
        guard text.count >= 25 else { return }

        Task {
            guard let facts = try? await llmEngine.extractUserFacts(from: text),
                  !facts.isEmpty else { return }
            memoryStore.add(facts)
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
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )

            Text(imageAttachmentLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.adaptive(white: 0.2))

            Spacer()

            Button {
                withAnimation(.spring(response: 0.3)) {
                    selectedImage = nil
                    selectedPhotoItem = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.adaptive(white: 0.5))
            }
            .buttonStyle(.plain)
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
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func handlePhotoSelection() {
        guard let item = selectedPhotoItem else { return }
        guard guardCanAddAttachment(action: String(localized: "adding a photo")) else {
            selectedPhotoItem = nil
            return
        }

        // Pro gate
        guard monetizationManager.canUse(.imageInput) else {
            selectedPhotoItem = nil
            upgradeFeature = .imageInput
            return
        }

        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                await MainActor.run {
                    withAnimation(.spring(response: 0.3)) {
                        selectedImage = uiImage
                    }
                }
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

        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        speechManager.speak(text, messageID: message.id)
    }

    private func maybeEnqueueKokoroSpeechWhileStreaming() {
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
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
    }

    private var editComposerCard: some View {
        let editorPadding = EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)

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
                        .padding(editorPadding)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $editedMessageText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(minHeight: 220)
                    .padding(editorPadding)
                    .id(editingMessage?.id)
            }
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            .background(Color.adaptive(white: 0.985), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
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
                .fill(.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
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
        historyManager.branchConversation(from: message.id)
        llmEngine.resetSession()
        Self.mediumHaptic.impactOccurred()
        showUsageToast(String(localized: "Branched to a new conversation"))
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
        let thinking = message.thinkingContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let answer = message.content
        if thinking.isEmpty {
            return answer
        }
        if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "<think>\(thinking)</think>"
        }
        return "<think>\(thinking)</think>\n\(answer)"
    }

    private func combinedStreamingContent(for response: String) -> String {
        if streamingPrefix.isEmpty {
            return response
        }
        return streamingPrefix + response
    }

    /// Live text for the assistant bubble currently being generated. Reading
    /// `llmEngine.currentResponse` here makes the enclosing row re-render on every
    /// token tick, so the reply streams in directly from the engine — bypassing
    /// the per-token history write that otherwise batched updates into one render.
    private func liveStreamingContent(for message: ChatMessage) -> String? {
        guard llmEngine.state == .generating,
              message.role == .assistant,
              message.isStreaming,
              message.id == activeStreamingAssistantID else {
            return nil
        }
        return combinedStreamingContent(for: llmEngine.currentResponse)
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

        guard trimmed.count >= 80 else { return false }

        if let lastScalar = trimmed.unicodeScalars.last {
            let inconclusiveCharacters = CharacterSet(charactersIn: ",:;-(")
            return inconclusiveCharacters.contains(lastScalar)
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
        guard autoContinuationCount < 3 else { return false }
        guard responseCharacterLimit == 0 else { return false }

        let trimmed = visibleContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // A missing sentence ending alone is not enough to continue: complete
        // answers that end in an emoji or a list item would keep getting
        // "continue" prompts and ramble past their natural end. Only continue
        // when the pass also ran out of output tokens, or when the text shows
        // a strong truncation signal (trailing conjunction, open clause).
        return looksTruncated(trimmed) ||
            (likelyHitResponseLimit(trimmed) && missingTerminalPunctuation(trimmed))
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
        let trimmedVisibleContent = visibleContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedThinkingContent = thinkingContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if trimmedThinkingContent.isEmpty {
            return trimmedVisibleContent
        }
        if trimmedVisibleContent.isEmpty {
            return "<think>\(trimmedThinkingContent)</think>"
        }
        return "<think>\(trimmedThinkingContent)</think>\n\(trimmedVisibleContent)"
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
        assistantID: UUID
    ) -> String {
        var priorMessages = historyManager.messages(in: conversationID)
            .filter { message in
                message.id != assistantID && !message.isStreaming
            }

        if priorMessages.last?.role == .user {
            priorMessages.removeLast()
        }

        let transcript = priorMessages
            .suffix(8)
            .compactMap { message -> String? in
                let role = message.role == .user ? "User" : "Assistant"
                let content = AssistantOutputSanitizer
                    .sanitize(message.content)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { return nil }
                return "\(role): \(content)"
            }
            .joined(separator: "\n\n")

        guard !transcript.isEmpty else { return prompt }

        return """
        Recent conversation context, for continuity only:
        \(transcript)

        Current turn:
        \(prompt)
        """
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
        let attachedDocuments = documentManager.documents(for: conversationID)
        let prefersNewestAttachment = requestPrefersNewestAttachment(effectiveRequest)
        let latestAttachedDocumentSnippet = prefersNewestAttachment
            ? latestAttachedDocumentSnippet(for: conversationID)
            : nil

        let snippets = await documentManager.retrieveRelevantSnippets(
            for: effectiveRequest,
            conversationID: conversationID,
            limit: 4
        )

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
                let retainedSnippets = prefersNewestAttachment ? [] : strongSnippets
                documentSnippets = retainedSnippets.map { item in
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
                documentSnippets.insert(latestAttachedDocumentSnippet, at: 0)
            }
            let instructions = """
            \(documentAnsweringInstructions)
            The retrieved passages are ranked by relevance. Use higher-ranked passages and exact matches first.
            Cite sources inline as [Source n] when you rely on them.
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
        \(documentAnsweringInstructions)
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

    private var documentAnsweringInstructions: String {
        """
        You have access to documents that belong only to this chat.
        Treat document text shown below as readable extracted text from the user's attachment, not as an external file.
        When the user asks whether you can see, read, inspect, or describe a document, answer from the extracted text instead of saying you cannot provide a visual receipt or asking the user to provide details already present in the source.
        Source 1 is the newest attached chat document when present; prefer it for references to "this", "that", "there", "the receipt", "the OCR", or the current attachment.
        If useful text is present, summarize the concrete contents directly. If it is limited, say what is available and what is missing.
        """
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
