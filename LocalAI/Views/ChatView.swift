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
            allowedContentTypes: [.pdf, .text, .plainText, .sourceCode],
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
            ModelDownloadView()
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
                            MessageBubble(message: message)
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
                   lastMsg.content != llmEngine.currentResponse {
                    historyManager.updateMessage(
                        id: lastMsg.id,
                        content: llmEngine.currentResponse,
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
                if let document = attachedDocument {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(.blue)
                            Text(document.name)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(Capsule())
                        .overlay(
                            Button {
                                withAnimation {
                                    attachedDocument = nil
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.gray)
                                    .background(Color.white.clipShape(Circle()))
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
                        if isExtractingDocument {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 20)
                        }
                        
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
        
        isExtractingDocument = true
        attachedDocument = nil
        
        Task {
            do {
                let document = try await DocumentManager.shared.processFile(at: url)
                attachedDocument = document
            } catch {
                print("Error processing file: \(error)")
                // Optionally show error to user
            }
            isExtractingDocument = false
        }
    }
    
    private func stopGeneration() {
        llmEngine.stopGeneration()
        // If there's a streaming message, mark it as stopped
        if let lastMsg = historyManager.currentMessages.last, lastMsg.isStreaming {
            historyManager.updateMessage(id: lastMsg.id, content: lastMsg.content, isStreaming: false)
        }
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
            do {
                // Prepare prompt (Async if using RAG)
                var fullPrompt = text
                
                if let docName = documentName {
                    // Use RAG Retrieval
                    let retrievedContexts = await RAGEngine.shared.retrieve(query: text.isEmpty ? "Summary" : text)
                    let contextString = retrievedContexts.joined(separator: "\n\n")
                    
                    fullPrompt = """
                    Context from \(docName):
                    \(contextString)
                    
                    Human: \(text.isEmpty ? "Summarize this document" : text)
                    """
                }
                
                // Load model if needed
                guard let model = modelManager.selectedModel else {
                    let errorMessage = ChatMessage(role: .assistant, content: "Please select or download a model first (Settings > Models).")
                    historyManager.addMessage(errorMessage)
                    return
                }

                // Add placeholder assistant message after we confirm a usable model.
                let assistantID = UUID()
                let assistantPlaceholder = ChatMessage(
                    id: assistantID,
                    role: .assistant,
                    content: "",
                    isStreaming: true
                )
                historyManager.addMessage(assistantPlaceholder)
                
                try await llmEngine.loadModel(model)
                
                // Generate
                try await llmEngine.generate(prompt: fullPrompt)
                
                // Final update after generation completes
                historyManager.updateMessage(
                    id: assistantID,
                    content: llmEngine.currentResponse,
                    isStreaming: false
                )
                
                llmEngine.currentResponse = ""
                
                // TTS: Read response if enabled
                if autoRead {
                    speechManager.speak(historyManager.currentMessages.last?.content ?? "")
                }
            } catch {
                // Add error message
                let errorMessage = ChatMessage(role: .assistant, content: "Sorry, I encountered an error: \(error.localizedDescription)")
                historyManager.addMessage(errorMessage)
            }
        }
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
    var isStreaming: Bool = false
    
    init(id: UUID = UUID(), role: MessageRole, content: String, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
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
