import SwiftUI

struct WatchAppView: View {
    @Environment(WatchConnectivityClient.self) private var connectivityClient
    @State private var isTypeSheetPresented = false

    private let quickPrompts = [
        "Summarize this",
        "Next step",
        "Reply in 1 line",
        "Key takeaway"
    ]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        if connectivityClient.isCapturingVoice {
                            WatchStateBanner(
                                title: "Listening",
                                message: "Speak your prompt. The watch will send it when dictation finishes.",
                                iconName: "waveform.circle.fill",
                                tint: .orange
                            )
                        } else if connectivityClient.isSending {
                            WatchStateBanner(
                                title: "Sending to iPhone",
                                message: sendingMessage,
                                iconName: "arrow.triangle.2.circlepath.circle.fill",
                                tint: .blue
                            )
                        } else if let failureMessage = connectivityClient.latestFailureMessage {
                            WatchStateBanner(
                                title: "Couldn’t Send Reply",
                                message: failureMessage,
                                iconName: "exclamationmark.circle.fill",
                                tint: .red,
                                buttonTitle: connectivityClient.latestFailedPrompt == nil ? nil : "Retry",
                                action: connectivityClient.latestFailedPrompt == nil ? nil : {
                                    connectivityClient.retryLatestFailedPrompt()
                                }
                            )
                        }

                        if connectivityClient.hasMessages {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(connectivityClient.entries) { entry in
                                    WatchMessageBubble(entry: entry)
                                        .id(entry.id)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            WatchEmptyState(
                                isReachable: connectivityClient.isReachable,
                                isSending: connectivityClient.isSending || connectivityClient.isCapturingVoice
                            )
                        }

                        WatchStatusRow(
                            state: connectivityClient.stateSummary,
                            message: connectivityClient.statusMessage
                        )

                        WatchPrimaryActionCard(
                            isCapturingVoice: connectivityClient.isCapturingVoice,
                            isDisabled: connectivityClient.isSending || connectivityClient.isCapturingVoice,
                            action: connectivityClient.startDictation
                        )

                        WatchQuickPromptSection(
                            prompts: quickPrompts,
                            isDisabled: connectivityClient.isSending || connectivityClient.isCapturingVoice,
                            onPromptSelected: { prompt in
                                connectivityClient.sendPrompt(prompt)
                            },
                            onTypeTap: {
                                isTypeSheetPresented = true
                            }
                        )
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .background(backgroundGradient)
                .navigationTitle("Own Ai")
                .navigationBarTitleDisplayMode(.inline)
                .onChange(of: connectivityClient.entries.count) {
                    guard let lastID = connectivityClient.entries.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
        .onAppear {
            connectivityClient.activate()
        }
        .sheet(isPresented: $isTypeSheetPresented) {
            WatchTypedPromptSheet()
                .environment(connectivityClient)
        }
    }

    private var sendingMessage: String {
        if let latestPendingPrompt = connectivityClient.latestPendingPrompt {
            let preview = latestPendingPrompt.count > 28 ? "\(latestPendingPrompt.prefix(28))…" : latestPendingPrompt
            return "\"\(preview)\" is running on iPhone."
        }
        return "Your iPhone is working on it."
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color.orange.opacity(0.12),
                Color.clear,
                Color.blue.opacity(0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct WatchPrimaryActionCard: View {
    let isCapturingVoice: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask by voice")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Text("Fastest on watch. Speak and get a short answer back.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: isCapturingVoice ? "waveform.circle.fill" : "mic.circle.fill")
                        .font(.title3.weight(.semibold))

                    Text(isCapturingVoice ? "Listening..." : "Speak to Ask")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(isDisabled)
            .accessibilityLabel(isCapturingVoice ? "Listening" : "Speak to ask")
            .accessibilityHint("Starts dictation and sends the prompt to your iPhone.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            LinearGradient(
                colors: [.orange.opacity(0.16), .yellow.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct WatchStatusRow: View {
    let state: WatchStateSummary
    let message: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Label(state.label, systemImage: state.iconName)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(chipBackground)
                .clipShape(Capsule())

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chipBackground: some ShapeStyle {
        switch state {
        case .listening:
            return AnyShapeStyle(.orange.opacity(0.18))
        case .sending:
            return AnyShapeStyle(.blue.opacity(0.16))
        case .queued:
            return AnyShapeStyle(.yellow.opacity(0.18))
        case .ready:
            return AnyShapeStyle(.green.opacity(0.16))
        case .disconnected:
            return AnyShapeStyle(.gray.opacity(0.18))
        case .error:
            return AnyShapeStyle(.red.opacity(0.16))
        }
    }
}

private struct WatchQuickPromptSection: View {
    let prompts: [String]
    let isDisabled: Bool
    let onPromptSelected: (String) -> Void
    let onTypeTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick prompts")
                .font(.headline)

            ForEach(prompts, id: \.self) { prompt in
                Button(prompt) {
                    onPromptSelected(prompt)
                }
                .buttonStyle(.bordered)
                .disabled(isDisabled)
            }

            Button("Type prompt", systemImage: "keyboard") {
                onTypeTap()
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .disabled(isDisabled)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WatchTypedPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WatchConnectivityClient.self) private var connectivityClient

    var body: some View {
        @Bindable var connectivityClient = connectivityClient

        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Type a prompt", text: $connectivityClient.prompt, axis: .vertical)
                    .lineLimit(2...5)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("Prompt")

                Button("Send", systemImage: "arrow.up.circle.fill") {
                    connectivityClient.sendPrompt()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(connectivityClient.isSending || connectivityClient.trimmedPrompt.isEmpty)

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Type Prompt")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct WatchEmptyState: View {
    let isReachable: Bool
    let isSending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image("logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text("Own Ai")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            Image(systemName: isSending ? "waveform.badge.mic" : "mic.and.signal.meter")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(isReachable ? .orange : .secondary)

            Text(emptyTitle)
                .font(.headline)

            Text(emptyMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            LinearGradient(
                colors: [.white.opacity(0.55), .gray.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var emptyTitle: String {
        if isSending {
            return "Working"
        }
        if isReachable {
            return "Ask Something"
        }
        return "Open iPhone App"
    }

    private var emptyMessage: String {
        if isSending {
            return "Your iPhone is handling it."
        }
        if isReachable {
            return "Tap the mic or use a quick prompt."
        }
        return "Open the iPhone app to send and receive replies."
    }
}

private struct WatchStateBanner: View {
    let title: String
    let message: String
    let iconName: String
    let tint: Color
    let buttonTitle: String?
    let action: (() -> Void)?

    init(
        title: String,
        message: String,
        iconName: String,
        tint: Color,
        buttonTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.iconName = iconName
        self.tint = tint
        self.buttonTitle = buttonTitle
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: iconName)
                .font(.headline)
                .foregroundStyle(tint)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            LinearGradient(
                colors: [tint.opacity(0.16), .white.opacity(0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct WatchMessageBubble: View {
    @Environment(WatchConnectivityClient.self) private var connectivityClient
    let entry: WatchChatEntry
    @State private var isExpanded = false

    private let collapsedLineLimit = 6
    private let collapseThreshold = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.role == .user ? "You" : "Own Ai")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(entry.content)
                .font(.system(.body, design: .rounded))
                .lineLimit(isExpandable && !isExpanded ? collapsedLineLimit : nil)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let pendingState = entry.pendingState {
                WatchMessageStatePill(state: pendingState)
            }

            if let modelName = entry.modelName, !entry.isPending {
                Text(modelName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if isExpandable {
                Button(isExpanded ? "Show Less" : "Read More") {
                    isExpanded.toggle()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityHint(isExpanded ? "Collapses the full reply." : "Expands the full reply.")
            }

            if showsContinueOnIPhone {
                Button("Continue on iPhone", systemImage: "iphone") {
                    connectivityClient.continueOnIPhone(for: entry)
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
                .accessibilityHint("Opens this conversation on your paired iPhone.")
            }
        }
        .padding(8)
        .background(backgroundStyle)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderStyle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var backgroundStyle: some ShapeStyle {
        if entry.role == .user {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [.orange.opacity(0.22), .pink.opacity(0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        if entry.isError {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [.red.opacity(0.16), .red.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        if entry.pendingState == .queued {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [.yellow.opacity(0.16), .orange.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        if entry.pendingState == .sending {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [.blue.opacity(0.18), .cyan.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [.white.opacity(0.55), .blue.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var borderStyle: Color {
        if entry.role == .user {
            return .orange.opacity(0.18)
        }
        if entry.isError {
            return .red.opacity(0.20)
        }
        if entry.pendingState == .queued {
            return .yellow.opacity(0.28)
        }
        if entry.pendingState == .sending {
            return .blue.opacity(0.24)
        }
        return .white.opacity(0.24)
    }

    private var isExpandable: Bool {
        !entry.isPending && entry.content.count > collapseThreshold
    }

    private var showsContinueOnIPhone: Bool {
        entry.role == .assistant && !entry.isPending && entry.conversationID != nil
    }

    private var accessibilityLabel: String {
        let speaker = entry.role == .user ? "You" : "Own Ai"
        return "\(speaker). \(entry.content)"
    }
}

private struct WatchMessageStatePill: View {
    let state: WatchChatEntry.PendingState

    var body: some View {
        Label(title, systemImage: iconName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
    }

    private var title: String {
        switch state {
        case .sending:
            return "Sending"
        case .queued:
            return "Queued"
        }
    }

    private var iconName: String {
        switch state {
        case .sending:
            return "arrow.up.circle"
        case .queued:
            return "clock"
        }
    }

    private var color: Color {
        switch state {
        case .sending:
            return .blue
        case .queued:
            return .orange
        }
    }
}

#Preview {
    WatchAppView()
        .environment({
            let client = WatchConnectivityClient()
            client.entries = [
                .user(prompt: "Summarize my last chat.", requestID: UUID()),
                .assistant(
                    id: UUID(),
                    requestID: UUID(),
                    content: "Your iPhone companion target is wired and ready for the next step.",
                    conversationID: UUID(),
                    modelName: "Qwen3 1.7B",
                    isError: false
                )
            ]
            client.statusMessage = "Connected to your iPhone."
            return client
        }())
}
