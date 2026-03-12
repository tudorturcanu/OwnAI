//
//  ChatView.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import SwiftUI

//
//  ChatView.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

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
    @State private var attachedDocument: AttachedDocument?
    @State private var isExtractingDocument = false
    @AppStorage("autoRead") private var autoRead = false
    @State private var showExportSheet = false
    @FocusState private var isInputFocused: Bool
    @State private var showModelDownloadSheet = false
    @State private var showModelConsentSheet = false
    @State private var shouldSendAfterConsent = false
    @State private var documentError: String?
    @State private var streamingPrefix = ""
    
    var body: some View {
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
        .onAppear {
            prewarmModel()
        }
        .onChange(of: modelManager.selectedModelID) {
            prewarmModel()
        }
        .onChange(of: speechManager.transcribedText) {
            if !speechManager.transcribedText.isEmpty {
                messageText = speechManager.transcribedText
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.pdf, .text, .plainText, .sourceCode, .rtf, .rtfd, .init(filenameExtension: "docx")!],
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
        .alert("Document Error", isPresented: Binding(
            get: { documentError != nil },
            set: { if !$0 { documentError = nil } }
        )) {
            Button("OK", role: .cancel) { documentError = nil }
        } message: {
            Text(documentError ?? "An unknown error occurred.")
        }
    }
    
    private func prewarmModel() {
        guard let model = modelManager.selectedModel else { return }
        Task {
            await llmEngine.prewarmIfNeeded(model: model)
        }
    }
    
    private var backgroundView: some View {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.9, green: 0.85, blue: 1.0), location: 0),     // Soft purple top
                .init(color: Color(red: 1.0, green: 0.95, blue: 0.9), location: 0.5),   // Soft orange middle
                .init(color: Color.white, location: 1.0)                                // White bottom
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .opacity(historyManager.currentMessages.isEmpty ? 1 : 0.3)
        .animation(.default, value: historyManager.currentMessages.isEmpty)
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
                            MessageBubble(
                                message: message,
                                showsContinue: canContinue(message),
                                onContinue: canContinue(message) ? { continueResponse(for: message) } : nil
                            )
                                .id(message.id)
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
        VStack(spacing: 32) {
            // Top Status Capsule (Floating)
            modelStatusView
                .padding(.top, isInputFocused ? 10 : 20)
            
            if !isInputFocused {
                Spacer()
            }
            
            VStack(spacing: isInputFocused ? 12 : 24) {
                if !isInputFocused {
                    SparkleView()
                }
                
                VStack(spacing: 4) {
                    Text("Start a Conversation")
                        .font(isInputFocused ? .headline : .title2.bold())
                        .foregroundStyle(Color(white: 0.15))
                    
                    if let model = modelManager.selectedModel {
                        Text("Using \(model.name)")
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.4))
                    } else if !modelManager.isAppleIntelligenceAvailable {
                        Button {
                            showModelDownloadSheet = true
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.app")
                                Text("Download a Model")
                            }
                            .font(.subheadline.bold())
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(Capsule())
                        }
                    } else {
                        Text("Select or download a model in Settings")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            
            Spacer()
            
            // Suggestion Cards
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    SuggestionCard(title: "Tell me", subtitle: "something fascinating") {
                        messageText = "Tell me something fascinating"
                        sendMessage()
                    }
                    SuggestionCard(title: "Explain", subtitle: "complex topics simply") {
                        messageText = "Explain a complex topic like black holes simply"
                        sendMessage()
                    }
                    SuggestionCard(title: "Write", subtitle: "an email or story") {
                        messageText = "Write a short creative story about a robot"
                        sendMessage()
                    }
                    SuggestionCard(title: "Discover", subtitle: "my next book") {
                        messageText = "Help me discover my next book"
                        sendMessage()
                    }
                    SuggestionCard(title: "Plan", subtitle: "my weekend trip") {
                        messageText = "Help me plan a relaxing weekend trip"
                        sendMessage()
                    }
                    SuggestionCard(title: "Boost", subtitle: "my productivity") {
                        messageText = "How can I boost my productivity?"
                        sendMessage()
                    }
                    SuggestionCard(title: "Debug", subtitle: "my code snippet") {
                        messageText = "Help me debug this Swift code snippet:\n"
                        sendMessage()
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Input View
    
    private var inputView: some View {
        VStack(spacing: 0) {
            if !historyManager.currentMessages.isEmpty {
                Divider()
            }
            
            VStack(spacing: 8) {
                // Attached Document Pill
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
                } else if let document = attachedDocument {
                    HStack {
                        HStack(spacing: 8) {
                            Image(systemName: document.iconName)
                                .font(.title3)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.blue, .blue.opacity(0.7)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.name)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                HStack(spacing: 4) {
                                    Text(document.fileSizeText)
                                    if let pageInfo = document.pageInfo {
                                        Text("·")
                                        Text(pageInfo)
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
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
                        .overlay(
                            Button {
                                withAnimation(.spring(response: 0.3)) {
                                    attachedDocument = nil
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.white)
                                    .background(Color.gray.opacity(0.7).clipShape(Circle()))
                            }
                            .offset(x: 6, y: -6),
                            alignment: .topTrailing
                        )
                        
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                HStack(spacing: 10) {
                    // Plus button
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
                    } else if messageText.isEmpty && attachedDocument == nil {
                        // Microphone button
                        Button {
                            toggleListening()
                        } label: {
                            Image(systemName: "mic.fill")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.black)
                                .clipShape(Circle())
                        }
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
                .padding(.top, attachedDocument == nil ? 12 : 4)
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
        let hasInput = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedDocument != nil
        let hasModel = modelManager.selectedModel != nil
        return hasInput && hasModel && llmEngine.state != .generating && llmEngine.state != .loading
    }
    
    // MARK: - Model Status
    
    private var modelStatusView: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            Text(statusText)
                .font(.caption)
                .foregroundStyle(Color(white: 0.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(white: 0.94))
        .clipShape(Capsule())
    }
    
    private var statusColor: Color {
        guard modelManager.selectedModel != nil else { return .red }
        switch llmEngine.state {
        case .ready: return .green
        case .loading, .generating: return .orange
        case .idle: return .yellow
        case .error: return .red
        }
    }
    
    private var statusText: String {
        guard let model = modelManager.selectedModel else {
            return "No Model"
        }
        switch llmEngine.state {
        case .ready:
            return model.name
        case .loading: return "Loading..."
        case .generating: return "Thinking..."
        case .idle: return "Ready"
        case .error: return "Error"
        }
    }
    
    // MARK: - Actions
    
    private func handleFileImport(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        
        withAnimation(.spring(response: 0.3)) {
            isExtractingDocument = true
            attachedDocument = nil
        }
        
        Task {
            do {
                let document = try await documentManager.processFile(at: url)
                withAnimation(.spring(response: 0.3)) {
                    attachedDocument = document
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
            try? speechManager.startListening()
        }
    }
    
    private func sendMessage() {
        guard canSend else { return }

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
        
        var text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let documentContent = attachedDocument?.content
        let documentName = attachedDocument?.name
        
        // If there's a document but no text, we can still send
        if text.isEmpty && attachedDocument == nil { return }
        
        // construct display text
        var displayText = text
        if let name = documentName {
            if displayText.isEmpty {
                displayText = "Sent a document: \(name)"
            } else {
                displayText = "[\(name)] " + displayText
            }
        }
        
        // Add user message
        let userMessage = ChatMessage(role: .user, content: displayText)
        historyManager.addMessage(userMessage)
        
        messageText = ""
        attachedDocument = nil
        
        // Generate response
        Task {
            // Prepare prompt (Async if using RAG)
            var fullPrompt = text
            
            if let docName = documentName, let docContent = documentContent, !docContent.isEmpty {
                // Direct injection — truncate to fit model context window
                let maxChars = 3000
                let truncatedContent = String(docContent.prefix(maxChars))
                
                fullPrompt = """
                Below is text from the document "\(docName)":
                ---
                \(truncatedContent)
                ---
                
                \(text.isEmpty ? "Summarize this document." : text)
                """
            }

            let shouldResetSession = documentName != nil
            await runAssistantResponse(prompt: fullPrompt, resetSession: shouldResetSession)
        }
    }

    private func runAssistantResponse(
        prompt: String,
        resetSession: Bool = false,
        assistantID: UUID = UUID(),
        existingPrefix: String = "",
        placeholderContent: String = "",
        missingAnswerRetryCount: Int = 0
    ) async {
        do {
            guard let model = modelManager.selectedModel else {
                let errorMessage = ChatMessage(role: .assistant, content: "Please select or download a model first (Settings > Models).")
                historyManager.addMessage(errorMessage)
                return
            }

            streamingPrefix = existingPrefix
            llmEngine.currentResponse = ""

            if historyManager.currentMessages.contains(where: { $0.id == assistantID }) {
                historyManager.updateMessage(
                    id: assistantID,
                    content: placeholderContent,
                    isStreaming: true
                )
            } else {
                let assistantPlaceholder = ChatMessage(
                    id: assistantID,
                    role: .assistant,
                    content: placeholderContent,
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
                var errorText = "Sorry, I encountered an error: \(message)"
                if message.contains("unsupported language") || message.contains("locale") {
                    errorText = "This document's language is not supported by Apple Intelligence. Try switching to an MLX model (like Gemma) in Settings → Models for multi-language support."
                }
                let fallbackContent = failureContent(
                    assistantID: assistantID,
                    existingPrefix: existingPrefix,
                    errorText: errorText
                )
                historyManager.updateMessage(
                    id: assistantID,
                    content: fallbackContent,
                    isStreaming: false
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
                    missingAnswerRetryCount: 1
                )
                return
            }

            historyManager.updateMessage(
                id: assistantID,
                content: finalizedContent,
                isStreaming: false
            )

            llmEngine.currentResponse = ""
            streamingPrefix = ""

            if autoRead {
                speechManager.speak(historyManager.currentMessages.last?.content ?? "")
            }
        } catch {
            let errorText = "Sorry, I encountered an error: \(error.localizedDescription)"
            if historyManager.currentMessages.contains(where: { $0.id == assistantID }) {
                let fallbackContent = failureContent(
                    assistantID: assistantID,
                    existingPrefix: existingPrefix,
                    errorText: errorText
                )
                historyManager.updateMessage(
                    id: assistantID,
                    content: fallbackContent,
                    isStreaming: false
                )
            } else {
                historyManager.addMessage(ChatMessage(role: .assistant, content: errorText))
            }
            llmEngine.currentResponse = ""
            streamingPrefix = ""
        }
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
                    placeholderContent: rawAssistantContent(for: message)
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
                placeholderContent: prefix
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

}

// MARK: - Chat Message Model

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let role: MessageRole
    let content: String
    let thinkingContent: String?
    var isStreaming: Bool = false
    
    init(id: UUID = UUID(), role: MessageRole, content: String, thinkingContent: String? = nil, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.thinkingContent = thinkingContent
        self.isStreaming = isStreaming
    }
    
    enum MessageRole: String, Codable {
        case user
        case assistant
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

#Preview {
    ChatView()
        .environment(LLMEngine())
        .environment(ChatHistoryManager())
        .environment(ModelManager())
        .environment(SpeechManager())
}

struct SparkleView: View {
    @State private var animate = false

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 60, weight: .light))
            .foregroundStyle(
                LinearGradient(
                    colors: [.orange.opacity(0.8), .pink.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            // 1. Control the opacity and scale manually
            .opacity(animate ? 1.0 : 0.3)
            .scaleEffect(animate ? 1.1 : 0.95)
            // 2. Apply a slow, smooth animation
            .animation(
                .easeInOut(duration: 2.5) // Change seconds here to slow it down
                .repeatForever(autoreverses: true),
                value: animate
            )
            .onAppear {
                animate = true
            }
    }
}
