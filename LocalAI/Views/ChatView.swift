import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct ChatView: View {
    @Environment(LLMEngine.self) private var llmEngine
    @Environment(ChatHistoryManager.self) private var historyManager
    @Environment(ModelManager.self) private var modelManager
    @Environment(SpeechManager.self) private var speechManager
    @Environment(MonetizationManager.self) private var monetizationManager
    @State private var documentManager = DocumentManager.shared
    
    @State private var messageText = ""
    @State private var isFileImporterPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var isExtractingDocument = false
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
    @State private var streamingPrefix = ""
    @State private var speechStreamingSpokenCharCount: Int = 0
    @State private var selectedImage: UIImage?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var activeStreamingConversationID: UUID?
    @State private var activeStreamingAssistantID: UUID?
    @State private var pendingSessionReset = false
    @State private var selectedDocumentForSources: ConversationDocument?
    @AppStorage("systemPrompt") private var systemPrompt = AIResponseDefaults.defaultSystemPrompt
    @AppStorage("responseCharacterLimit") private var responseCharacterLimit = AIResponseDefaults.responseCharacterLimit
    @AppStorage("smartReplyStylesEnabled") private var smartReplyStylesEnabled = false

    @State private var editingMessage: ChatMessage?
    @State private var editedMessageText: String = ""
    @State private var isEditSheetPresented = false
    
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
    }

    private var modalContent: some View {
        lifecycleContent
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.pdf, .image, .text, .plainText, .sourceCode, .rtf, .rtfd, .docx],
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
            .sheet(isPresented: $isEditSheetPresented) {
                NavigationStack {
                    VStack(spacing: 12) {
                        TextEditor(text: $editedMessageText)
                            .font(.body)
                            .frame(minHeight: 180)
                            .padding(10)
                            .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 12))

                        Spacer()
                    }
                    .padding(16)
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
            .confirmationDialog(String(localized: "Add to chat"), isPresented: $showAttachmentOptions, titleVisibility: .visible) {
                Button(String(localized: "Photo or Screenshot")) {
                    isPhotoPickerPresented = true
                }

                Button(String(localized: "Open Document")) {
                    guard monetizationManager.canUse(.unlimitedDocuments) || currentConversationDocuments.isEmpty else {
                        upgradeFeature = .unlimitedDocuments
                        return
                    }
                    isFileImporterPresented = true
                }

                Button(String(localized: "Cancel"), role: .cancel) { }
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
            }
            .onChange(of: modelManager.selectedModelID) {
                prewarmModel()
            }
            .onChange(of: historyManager.currentConversationID) {
                speechManager.stopSpeaking()
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
        let migrationKey = "didMigrateFullResponseDefaults"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }

        if defaults.object(forKey: "maxTokens") == nil || defaults.integer(forKey: "maxTokens") <= 512 {
            defaults.set(AIResponseDefaults.maxTokens, forKey: "maxTokens")
        }

        if defaults.object(forKey: "responseCharacterLimit") == nil || defaults.integer(forKey: "responseCharacterLimit") == 1000 {
            defaults.set(AIResponseDefaults.responseCharacterLimit, forKey: "responseCharacterLimit")
        }

        if defaults.string(forKey: "systemPrompt") == "You are a helpful AI assistant." {
            defaults.set(AIResponseDefaults.defaultSystemPrompt, forKey: "systemPrompt")
        }

        defaults.set(true, forKey: migrationKey)
    }

    private var baseContent: some View {
        ZStack {
            // Background Gradient
            backgroundView
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Messages area
                messagesView
                
                // Input area
                inputView
            }
        }
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
    
    private func prewarmModel() {
        guard let model = modelManager.selectedModel else { return }
        Task {
            await llmEngine.prewarmIfNeeded(model: model)
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
                                onBranchFromHere: { message in
                                    branchConversation(from: message)
                                },
                                onTogglePin: { message in
                                    historyManager.togglePinned(messageID: message.id, in: historyManager.currentConversationID)
                                }
                            )
                                .id(message.id)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation(.spring(response: 0.3)) {
                                            historyManager.deleteMessage(id: message.id)
                                        }
                                    } label: {
                                        Label(String(localized: "Delete"), systemImage: "trash")
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
            .onChange(of: historyManager.currentMessages.count) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: llmEngine.state) {
                if llmEngine.state != .generating {
                    activeStreamingConversationID = nil
                    activeStreamingAssistantID = nil
                    if pendingSessionReset {
                        pendingSessionReset = false
                        llmEngine.resetSession()
                    }
                }
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: historyManager.currentConversationID) {
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
                scrollToBottom(proxy: proxy, delay: 0.02, animated: false)
            }
        }
    }

    private func scrollToTop(proxy: ScrollViewProxy) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            proxy.scrollTo("top", anchor: .top)
        }
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy, delay: Double = 0, animated: Bool = true) {
        let performScroll = {
            let scrollAction = {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            if animated {
                withAnimation(.easeInOut(duration: 0.25)) { // Gentler scroll to match liquid text
                    scrollAction()
                }
            } else {
                scrollAction()
            }
        }
        
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                performScroll()
            }
        } else {
            performScroll()
        }
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        ChatEmptyStateView(
            isInputFocused: isInputFocused,
            selectedModelName: modelManager.selectedModel?.name,
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

    // MARK: - Input View
    
    private var inputView: some View {
        VStack(spacing: 0) {
            if !historyManager.currentMessages.isEmpty {
                Divider()
            }
            
            VStack(spacing: 8) {
                if voiceConversationMode {
                    voiceModeBanner
                }

                // Documents scoped to the current chat
                if isExtractingDocument {
                    HStack(spacing: 8) {
                        ProgressView(value: documentManager.extractionProgress)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                        Text(String(localized: "Extracting…"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
                        showAttachmentOptions = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color(white: 0.4))
                            .frame(width: 36, height: 36)
                            .background(Color(white: 0.95))
                            .clipShape(Circle())
                    }
                    .disabled(isExtractingDocument || speechManager.isListening)
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
                    .background(Color.white.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color.black.opacity(speechManager.isListening ? 0.2 : 0.05), lineWidth: 1)
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
                    } else if speechManager.isListening {
                        // Stop listening button
                        Button {
                            toggleListening()
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 24)) // Icon size
                                .foregroundStyle(.red)
                                .frame(width: 36, height: 36)
                                .background(Color.white)
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
                        }
                        .disabled(!canSend)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .padding(.top, currentConversationDocuments.isEmpty ? 12 : 4)
                .onChange(of: selectedPhotoItem) {
                    handlePhotoSelection()
                }
            }
            .background(Color.clear)
        }
    }
    
    private var sendButtonGradient: LinearGradient {
        if !canSend && llmEngine.state != .generating {
            return LinearGradient(colors: [Color(white: 0.85)], startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(colors: [.black], startPoint: .top, endPoint: .bottom)
    }
    
    private var canSend: Bool {
        let hasInput = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !currentConversationDocuments.isEmpty || selectedImage != nil
        let hasModel = modelManager.selectedModel != nil
        return hasInput && hasModel && llmEngine.state != .generating && llmEngine.state != .loading && !monetizationManager.hasReachedFreeDailyMessageLimit
    }

    private var currentConversationDocuments: [ConversationDocument] {
        documentManager.documents(for: historyManager.currentConversationID)
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
                    .foregroundStyle(Color(white: 0.35))

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
                                .foregroundStyle(Color(white: 0.6))
                        }
                        .buttonStyle(.plain)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func documentChipDetail(for document: ConversationDocument) -> some View {
        if document.textOrigin != .native {
            Text(document.textOrigin.accessibilityLabel)
                .font(.caption2)
                .foregroundStyle(Color(white: 0.45))
                .lineLimit(1)
        } else if let pageInfo = document.pageInfo {
            Text(pageInfo)
                .font(.caption2)
                .foregroundStyle(Color(white: 0.45))
                .lineLimit(1)
        }
    }

    private var voiceModeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: speechManager.isListening ? "waveform.circle.fill" : "waveform.circle")
                .foregroundStyle(speechManager.isListening ? .red : .blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Conversation Mode"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(white: 0.15))
                Text(speechManager.isListening ? String(localized: "Listening for your next turn") : String(localized: "Replies are spoken and listening restarts automatically"))
                    .font(.caption2)
                    .foregroundStyle(Color(white: 0.5))
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
            .background(Color.white.opacity(0.9))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.04), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .accessibilityHint(String(localized: "Reads the latest assistant reply aloud."))
    }

    private var microphoneControls: some View {
        HStack(spacing: 8) {
            if voiceConversationMode {
                Button {
                    voiceConversationMode = false
                } label: {
                    Image(systemName: "waveform.slash")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color(white: 0.35))
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.9))
                        .clipShape(Circle())
                }
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
        }
    }
    
    // MARK: - Actions
    
    private func handleFileImport(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard let conversationID = historyManager.currentConversationID else { return }
        guard monetizationManager.canUse(.unlimitedDocuments) || currentConversationDocuments.isEmpty else {
            upgradeFeature = .unlimitedDocuments
            return
        }
        
        withAnimation(.spring(response: 0.3)) {
            isExtractingDocument = true
        }
        
        Task {
            do {
                let document = try await documentManager.processFile(at: url)
                await documentManager.addDocumentToConversation(from: document, conversationID: conversationID)
                if let warning = document.ocrWarningText {
                    showExtractionNotice(warning)
                }
            } catch {
                print("Error processing file: \(error)")
                documentError = error.localizedDescription
            }
            withAnimation(.spring(response: 0.3)) {
                isExtractingDocument = false
            }
        }
    }
    
    private func stopGeneration() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
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
        guard canSend else { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        guard let model = modelManager.selectedModel else { return }
        if !hasConsent(for: model.id) {
            shouldSendAfterConsent = true
            showModelConsentSheet = true
            return
        }

        performSendMessage()
    }
    
    private func performSendMessage() {
        if speechManager.isListening {
            speechManager.stopListening()
        }
        
        if llmEngine.state == .generating {
            stopGeneration()
            return
        }
        
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversationID = historyManager.currentConversationID
        let imageToSend = selectedImage
        
        if text.isEmpty && currentConversationDocuments.isEmpty && imageToSend == nil { return }
        
        var displayText: String
        if text.isEmpty && imageToSend != nil {
            displayText = "What's in this image?"
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
        
        // Generate response
        Task {
            let promptContext = await buildPromptContext(
                userText: text.isEmpty && imageToSend != nil ? displayText : text,
                conversationID: conversationID
            )
            
            guard let model = modelManager.selectedModel else { return }
            
            // For non-vision models with image, prepend note
            var effectivePrompt = promptContext.prompt
            if imageToSend != nil, !model.supportsVision {
                effectivePrompt = "[Note: The user attached an image, but the selected model does not support image analysis. Please describe the image in text or select a vision-capable model.]\n\n" + effectivePrompt
            }
            
            await runAssistantResponse(
                prompt: effectivePrompt,
                conversationID: conversationID,
                resetSession: false,
                image: model.supportsVision ? imageToSend : nil,
                assistantSourceTitles: promptContext.sourceTitles,
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

        guard monetizationManager.shouldShowThreeMessagesLeftWarning else { return }
        monetizationManager.markThreeMessagesLeftWarningShown()
        showUsageToast(String(localized: "3 free messages left today."))
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
        shouldChargeUsage: Bool = false
    ) async {
        do {
            guard let model = modelManager.selectedModel else {
                let errorMessage = ChatMessage(role: .assistant, content: String(localized: "Please select or download a model first (Settings > Models)."))
                historyManager.addMessage(errorMessage, to: conversationID)
                return
            }

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
                    sourceTitles: assistantSourceTitles
                )
            } else {
                let assistantPlaceholder = ChatMessage(
                    id: assistantID,
                    role: .assistant,
                    content: placeholderContent,
                    sourceTitles: assistantSourceTitles,
                    isStreaming: true
                )
                historyManager.addMessage(assistantPlaceholder, to: conversationID)
            }

            try await llmEngine.loadModel(model)

            if resetSession {
                llmEngine.resetSession()
            }

            if shouldChargeUsage {
                monetizationManager.registerFreeMessageIfNeeded()
                showUsageToastIfNeededAfterSend()
            }

            try await llmEngine.generate(
                prompt: promptWithResponseLimit(prompt, existingPrefix: existingPrefix),
                image: image
            )

            if case .error(let message) = llmEngine.state {
                let errorText = userFacingErrorText(from: message)
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
                return
            }

            let finalizedContent = enforcedResponseLimit(
                for: combinedStreamingContent(for: llmEngine.currentResponse)
            )
            let finalizedParts = AssistantOutputSanitizer.parts(from: finalizedContent)
            if finalizedParts.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               finalizedParts.thinkingContent != nil,
               missingAnswerRetryCount == 0 {
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
                    assistantSourceTitles: assistantSourceTitles
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
            if voiceConversationMode {
                speechManager.speak(errorText)
            }
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
                .foregroundStyle(Color(white: 0.2))

            Spacer()

            Button {
                withAnimation(.spring(response: 0.3)) {
                    selectedImage = nil
                    selectedPhotoItem = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color(white: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Remove attached image"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.72))
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
        if speechManager.isSpeaking || !speechManager.isSpeechQueueEmpty {
            speechManager.stopSpeaking()
            return
        }

        if speechManager.isListening {
            speechManager.stopListening()
        }

        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        speechManager.speak(text)
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
        guard llmEngine.state != .generating else { return }
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

        let separator = message.content.hasSuffix("\n") ? "" : "\n\n"
        let prefix = message.content + separator
        let prompt = """
        Continue exactly where you stopped.
        Do not repeat the earlier text.
        Finish the same answer naturally and concisely.
        """

        Task {
            await runAssistantResponse(
                prompt: prompt,
                conversationID: historyManager.currentConversationID,
                assistantID: message.id,
                existingPrefix: prefix,
                placeholderContent: prefix,
                assistantSourceTitles: message.sourceTitles
            )
        }
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

    private func applyEditedMessageAndRerun() {
        guard let editingMessage else { return }
        guard llmEngine.state != .generating else { return }

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
                conversationID: conversationID
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
        guard llmEngine.state != .generating else { return [] }
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
        guard llmEngine.state != .generating else { return }
        guard historyManager.currentMessages.last?.id == message.id else { return }

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
        guard llmEngine.state != .generating else { return }
        guard historyManager.currentMessages.last?.id == message.id else { return }
        guard let promptSeed = retryPromptSeed(for: message) else { return }

        Task {
            let promptContext = await buildPromptContext(
                userText: promptSeed,
                conversationID: historyManager.currentConversationID
            )
            await runAssistantResponse(
                prompt: promptContext.prompt,
                conversationID: historyManager.currentConversationID,
                resetSession: true,
                assistantID: message.id,
                existingPrefix: "",
                placeholderContent: "",
                assistantSourceTitles: promptContext.sourceTitles
            )
        }
    }

    private func canContinue(_ message: ChatMessage) -> Bool {
        guard message.role == .assistant else { return false }
        guard !message.isStreaming else { return false }
        guard llmEngine.state != .generating else { return false }
        guard historyManager.currentMessages.last?.id == message.id else { return false }
        guard hasRecoverableConversationContext else { return false }
        if missingFinalAnswer(message) { return true }
        return looksTruncated(message.content) && likelyHitResponseLimit(message.content)
    }

    private func canRetryAfterReset(_ message: ChatMessage) -> Bool {
        guard message.role == .assistant else { return false }
        guard !message.isStreaming else { return false }
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
        guard trimmed.count >= 80 else { return false }
        if trimmed.hasSuffix("```") { return false }

        if let lastScalar = trimmed.unicodeScalars.last {
            let terminalCharacters = CharacterSet(charactersIn: ".!?\"')]}”")
            if terminalCharacters.contains(lastScalar) {
                return false
            }
        }

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
            " for"
        ]

        if trailingFragments.contains(where: { lowercased.hasSuffix($0) }) {
            return true
        }

        if let lastScalar = trimmed.unicodeScalars.last {
            let inconclusiveCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ",:;-("))
            return inconclusiveCharacters.contains(lastScalar)
        }

        return false
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

    private func promptWithResponseLimit(_ prompt: String, existingPrefix: String) -> String {
        guard let remainingCharacters = remainingResponseCharacters(after: existingPrefix) else {
            return prompt
        }

        return """
        Keep the final visible answer under \(remainingCharacters) additional characters.
        Prioritize a complete answer over extra detail.
        If needed, shorten the wording instead of trailing off.

        \(prompt)
        """
    }

    private func remainingResponseCharacters(after existingPrefix: String) -> Int? {
        guard responseCharacterLimit > 0 else { return nil }

        let usedCharacters = AssistantOutputSanitizer
            .sanitize(existingPrefix)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .count

        return max(responseCharacterLimit - usedCharacters, 0)
    }

    private func enforcedResponseLimit(for rawContent: String) -> String {
        guard responseCharacterLimit > 0 else { return rawContent }

        let parts = AssistantOutputSanitizer.parts(from: rawContent)
        let limitedVisibleContent = trimmedResponseContent(parts.content, limit: responseCharacterLimit)
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

    private func buildPromptContext(userText: String, conversationID: UUID?) async -> (prompt: String, sourceTitles: [String]) {
        let trimmedText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveRequest = trimmedText.isEmpty ? String(localized: "Summarize the documents in this chat.") : trimmedText

        guard let conversationID, documentManager.hasDocuments(in: conversationID) else {
            return (trimmedText, [])
        }

        let snippets = await documentManager.retrieveRelevantSnippets(
            for: effectiveRequest,
            conversationID: conversationID,
            limit: 4
        )

        if !snippets.isEmpty {
            var seenTitles = Set<String>()
            let sourceTitles = snippets.map { item in
                if let location = item.chunk.sourceLocationLabel {
                    return "\(item.document.name) · \(location)"
                }
                return item.document.name
            }
            .filter { seenTitles.insert($0).inserted }
            let context = snippets.enumerated().map { index, item in
                let locationLine = item.chunk.sourceLocationLabel.map { "Location: \($0)\n" } ?? ""
                return """
                [Source \(index + 1): \(item.document.name)]
                \(locationLine)\(item.chunk.content)
                """
            }
            .joined(separator: "\n\n")

            return (
                """
                You have access to documents that belong only to this chat.
                Use the retrieved passages when they are relevant to the user's request.
                If the snippets are insufficient, say that briefly instead of guessing.
                Cite sources inline as [Source n] when you rely on them.

                Chat documents:
                \(context)

                User request: \(effectiveRequest)
                """,
                sourceTitles
            )
        }

        let fallbackDocuments = documentManager.documents(for: conversationID).prefix(2)
        let fallbackSourceTitles = fallbackDocuments.map(\.name)
        let fallbackContext = fallbackDocuments.map { document in
            """
            [Document: \(document.name)]
            \(String(document.content.prefix(2_000)))
            """
        }
        .joined(separator: "\n\n")

        return (
            """
            You have access to documents that belong only to this chat.
            Use them when they help answer the request, and say briefly if the available text is limited.

            Chat documents:
            \(fallbackContext)

            User request: \(effectiveRequest)
            """,
            fallbackSourceTitles
        )
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

struct SendButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private extension UTType {
    static let docx = UTType(filenameExtension: "docx") ?? .data
}

#Preview {
    ChatView()
        .environment(LLMEngine())
        .environment(ChatHistoryManager())
        .environment(ModelManager())
        .environment(MonetizationManager())
        .environment(SpeechManager())
}
