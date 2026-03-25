import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(LLMEngine.self) private var llmEngine
    @Environment(ChatHistoryManager.self) private var historyManager
    @Environment(ModelManager.self) private var modelManager
    @Environment(SpeechManager.self) private var speechManager
    @State private var documentManager = DocumentManager.shared
    
    @State private var messageText = ""
    @State private var isFileImporterPresented = false
    @State private var isExtractingDocument = false
    @AppStorage("autoRead") private var autoRead = false
    @AppStorage("voiceConversationMode") private var voiceConversationMode = false
    @State private var showExportSheet = false
    @FocusState private var isInputFocused: Bool
    @State private var showModelDownloadSheet = false
    @State private var showModelConsentSheet = false
    @State private var shouldSendAfterConsent = false
    @State private var documentError: String?
    @State private var voiceError: String?
    @State private var streamingPrefix = ""
    @State private var speechStreamingSpokenCharCount: Int = 0
    @AppStorage("systemPrompt") private var systemPrompt = "You are a helpful AI assistant."
    
    var body: some View {
        alertContent
    }

    private var alertContent: some View {
        modalContent
            .alert("Document Error", isPresented: documentErrorBinding) {
                Button("OK", role: .cancel) { documentError = nil }
            } message: {
                Text(documentError ?? "An unknown error occurred.")
            }
            .alert("Voice Error", isPresented: voiceErrorBinding) {
                Button("OK", role: .cancel) { voiceError = nil }
            } message: {
                Text(voiceError ?? "Voice input is unavailable.")
            }
            .onChange(of: voiceConversationMode) {
                if voiceConversationMode {
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
                allowedContentTypes: [.pdf, .text, .plainText, .sourceCode, .rtf, .rtfd, .docx],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result: result)
            }
            .alert("Microphone Access Required", isPresented: Bindable(speechManager).showPermissionAlert) {
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Please enable microphone and speech recognition access in Settings to use voice input.")
            }
            .sheet(isPresented: $showModelDownloadSheet) {
                NavigationStack {
                    ModelDownloadView()
                }
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
                    Text("No model selected.")
                        .padding()
                }
            }
    }

    private var lifecycleContent: some View {
        baseContent
            .onAppear {
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
                llmEngine.resetSession()
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
                                recoveryAction: recoveryAction
                            )
                                .id(message.id)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation(.spring(response: 0.3)) {
                                            historyManager.deleteMessage(id: message.id)
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
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
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: historyManager.currentConversationID) {
                scrollToTop(proxy: proxy)
            }
            .onChange(of: llmEngine.currentResponse) {
                // Update the last message in history if it's currently streaming
                if let lastMsg = historyManager.currentMessages.last, 
                   lastMsg.role == .assistant && lastMsg.isStreaming &&
                   combinedStreamingContent(for: llmEngine.currentResponse) != lastMsg.content {
                    historyManager.updateMessage(
                        id: lastMsg.id,
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
                        Text("Extracting…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .transition(.opacity)
                } else if !currentConversationDocuments.isEmpty {
                    conversationDocumentsStrip
                }

                HStack(spacing: 10) {
                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color(white: 0.4))
                            .frame(width: 36, height: 36)
                            .background(Color(white: 0.95))
                            .clipShape(Circle())
                    }
                    .disabled(isExtractingDocument || speechManager.isListening)
                    
                    // Text field
                    HStack {
                        TextField(speechManager.isListening ? "Listening..." : "Ask anything", text: $messageText, axis: .vertical)
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
        let hasInput = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !currentConversationDocuments.isEmpty
        let hasModel = modelManager.selectedModel != nil
        return hasInput && hasModel && llmEngine.state != .generating && llmEngine.state != .loading
    }

    private var currentConversationDocuments: [ConversationDocument] {
        documentManager.documents(for: historyManager.currentConversationID)
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
        let defaultPrompt = "You are a helpful AI assistant."
        guard systemPrompt != defaultPrompt else { return nil }
        if let matched = PersonalityPreset.presets.first(where: { $0.systemPrompt == systemPrompt }) {
            return (matched.name, matched.icon)
        }
        return ("Custom personality", "slider.horizontal.3")
    }

    private var conversationDocumentsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Text(currentConversationDocuments.count == 1 ? "1 doc in this chat" : "\(currentConversationDocuments.count) docs in this chat")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(white: 0.35))

                ForEach(currentConversationDocuments) { document in
                    HStack(spacing: 8) {
                        Image(systemName: documentIconName(for: document))
                            .font(.caption)
                            .foregroundStyle(.blue)

                        Text(document.name)
                            .font(.caption)
                            .lineLimit(1)

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

    private var voiceModeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: speechManager.isListening ? "waveform.circle.fill" : "waveform.circle")
                .foregroundStyle(speechManager.isListening ? .red : .blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Conversation Mode")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(white: 0.15))
                Text(speechManager.isListening ? "Listening for your next turn" : "Replies are spoken and listening restarts automatically")
                    .font(.caption2)
                    .foregroundStyle(Color(white: 0.5))
            }

            Spacer()

            Toggle("Conversation Mode", isOn: $voiceConversationMode)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func speakReplyButton(for message: ChatMessage) -> some View {
        Button {
            toggleSpeechPlayback(for: message)
        } label: {
            Label(
                speechManager.isSpeaking ? "Stop Speaking" : "Speak Reply",
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
        .accessibilityHint("Reads the latest assistant reply aloud.")
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
        
        withAnimation(.spring(response: 0.3)) {
            isExtractingDocument = true
        }
        
        Task {
            do {
                let document = try await documentManager.processFile(at: url)
                await documentManager.addDocumentToConversation(from: document, conversationID: conversationID)
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
        if let lastMsg = historyManager.currentMessages.last, lastMsg.isStreaming {
            historyManager.updateMessage(
                id: lastMsg.id,
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
        
        if text.isEmpty && currentConversationDocuments.isEmpty { return }
        
        let displayText = text.isEmpty && !currentConversationDocuments.isEmpty ? "Summarize the documents in this chat." : text
        
        // Add user message
        let userMessage = ChatMessage(role: .user, content: displayText)
        historyManager.addMessage(userMessage)
        
        messageText = ""
        
        // Generate response
        Task {
            let promptContext = await buildPromptContext(
                userText: text,
                conversationID: conversationID
            )
            await runAssistantResponse(
                prompt: promptContext.prompt,
                resetSession: false,
                assistantSourceTitles: promptContext.sourceTitles
            )
        }
    }

    private func runAssistantResponse(
        prompt: String,
        resetSession: Bool = false,
        assistantID: UUID = UUID(),
        existingPrefix: String = "",
        placeholderContent: String = "",
        missingAnswerRetryCount: Int = 0,
        assistantSourceTitles: [String] = []
    ) async {
        do {
            guard let model = modelManager.selectedModel else {
                let errorMessage = ChatMessage(role: .assistant, content: "Please select or download a model first (Settings > Models).")
                historyManager.addMessage(errorMessage)
                return
            }

            streamingPrefix = existingPrefix
            speechStreamingSpokenCharCount = AssistantOutputSanitizer.sanitize(existingPrefix)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .count
            llmEngine.currentResponse = ""

            if historyManager.currentMessages.contains(where: { $0.id == assistantID }) {
                historyManager.updateMessage(
                    id: assistantID,
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
                historyManager.addMessage(assistantPlaceholder)
            }

            try await llmEngine.loadModel(model)

            if resetSession {
                llmEngine.resetSession()
            }

            try await llmEngine.generate(prompt: prompt)

            if case .error(let message) = llmEngine.state {
                let errorText = userFacingErrorText(from: message)
                let fallbackContent = failureContent(
                    assistantID: assistantID,
                    existingPrefix: existingPrefix,
                    errorText: errorText
                )
                historyManager.updateMessage(
                    id: assistantID,
                    content: fallbackContent,
                    isStreaming: false,
                    sourceTitles: assistantSourceTitles
                )
                llmEngine.currentResponse = ""
                streamingPrefix = ""
                return
            }

            let finalizedContent = combinedStreamingContent(for: llmEngine.currentResponse)
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
                content: finalizedContent,
                isStreaming: false,
                sourceTitles: assistantSourceTitles
            )

            llmEngine.currentResponse = ""
            streamingPrefix = ""

            let spokenReply = historyManager.currentMessages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if voiceConversationMode, !spokenReply.isEmpty {
                speechManager.speak(spokenReply)
            } else if voiceConversationMode {
                startListeningIfPossible()
            }
        } catch {
            let errorText = userFacingErrorText(from: error.localizedDescription)
            if historyManager.currentMessages.contains(where: { $0.id == assistantID }) {
                let fallbackContent = failureContent(
                    assistantID: assistantID,
                    existingPrefix: existingPrefix,
                    errorText: errorText
                )
                historyManager.updateMessage(
                    id: assistantID,
                    content: fallbackContent,
                    isStreaming: false,
                    sourceTitles: assistantSourceTitles
                )
            } else {
                historyManager.addMessage(ChatMessage(role: .assistant, content: errorText, sourceTitles: assistantSourceTitles))
            }
            llmEngine.currentResponse = ""
            streamingPrefix = ""
            if voiceConversationMode {
                speechManager.speak(errorText)
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
                assistantID: message.id,
                existingPrefix: prefix,
                placeholderContent: prefix,
                assistantSourceTitles: message.sourceTitles
            )
        }
    }

    private func retryAction(for message: ChatMessage) -> MessageBubble.RecoveryAction? {
        guard canRetryAfterReset(message) else { return nil }
        return MessageBubble.RecoveryAction(
            title: "Retry",
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
        return looksTruncated(message.content)
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
            return "This document's language is not supported by Apple Intelligence. Try switching to an MLX model (like Gemma) in Settings -> Models for multi-language support."
        }

        if lowercased.contains("jinja.templateexception") {
            return "Sorry, I hit a model template error. Tap Retry to clear the current chat context and try again."
        }

        return "Sorry, I encountered an error: \(message)"
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
        existingPrefix: String,
        errorText: String
    ) -> String {
        if let existingMessage = historyManager.currentMessages.first(where: { $0.id == assistantID }) {
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
    
    private func hasConsent(for modelID: String) -> Bool {
        UserDefaults.standard.bool(forKey: "modelConsent.\(modelID)")
    }

    private func setConsent(for modelID: String) {
        UserDefaults.standard.set(true, forKey: "modelConsent.\(modelID)")
    }

    private func buildPromptContext(userText: String, conversationID: UUID?) async -> (prompt: String, sourceTitles: [String]) {
        let trimmedText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveRequest = trimmedText.isEmpty ? "Summarize the documents in this chat." : trimmedText

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
        .environment(SpeechManager())
}
