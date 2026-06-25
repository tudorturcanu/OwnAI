import SwiftUI
import Combine

private let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

struct WatchAppView: View {
    @Environment(WatchConnectivityClient.self) private var connectivityClient
    @State private var isTypeSheetPresented = false

    private let quickPrompts: [(icon: String, text: String)] = [
        ("doc.text.magnifyingglass", String(localized: "Summarize this")),
        ("arrow.right.circle", String(localized: "Next step")),
        ("text.line.first.and.arrowtriangle.forward", String(localized: "Reply in 1 line")),
        ("star.circle", String(localized: "Key takeaway"))
    ]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        if connectivityClient.isCapturingVoice {
                            WatchStateBanner(
                                title: String(localized: "Listening"),
                                message: sendingMessage,
                                iconName: "waveform.circle.fill",
                                tint: .orange,
                                showWaveform: true
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                        } else if connectivityClient.isSending {
                            WatchStateBanner(
                                title: String(localized: "Sending to iPhone"),
                                message: sendingMessage,
                                iconName: "arrow.triangle.2.circlepath.circle.fill",
                                tint: .blue
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                        } else if let failureMessage = connectivityClient.latestFailureMessage {
                            WatchStateBanner(
                                title: String(localized: "Couldn't Send Reply"),
                                message: failureMessage,
                                iconName: "exclamationmark.circle.fill",
                                tint: .red,
                                buttonTitle: connectivityClient.latestFailedPrompt == nil ? nil : String(localized: "Retry"),
                                action: connectivityClient.latestFailedPrompt == nil ? nil : {
                                    connectivityClient.retryLatestFailedPrompt()
                                }
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
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
                            isReady: connectivityClient.isReachable && !connectivityClient.isSending && !connectivityClient.isCapturingVoice,
                            isDisabled: connectivityClient.isSending || connectivityClient.isCapturingVoice,
                            action: { connectivityClient.startDictation(suggestions: quickPrompts.map(\.text)) }
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
                    .animation(.easeInOut(duration: 0.25), value: connectivityClient.isCapturingVoice)
                    .animation(.easeInOut(duration: 0.25), value: connectivityClient.isSending)
                }
                .background(WatchAnimatedBackground())
                .navigationTitle("Own Ai")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if connectivityClient.hasMessages {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(role: .destructive) {
                                withAnimation {
                                    connectivityClient.clearHistory()
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption.weight(.semibold))
                            }
                            .accessibilityLabel("Clear chat history")
                        }
                    }
                }
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
            return String(format: String(localized: "\"%@\" is running on iPhone."), preview)
        }
        return String(localized: "Your iPhone is working on it.")
    }
}

// MARK: - Animated Background

private struct WatchAnimatedBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 10.0)) { timeline in
            let t = watchDisplayDate(for: timeline.date).timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: 20.0) / 20.0
            let angle = phase * Double.pi * 2.0
            let orangeOpacity = 0.08 + 0.06 * sin(angle)
            let purpleOpacity = 0.04 + 0.03 * cos(angle + 1.0)
            let blueOpacity = 0.06 + 0.04 * sin(angle + 2.0)
            LinearGradient(
                colors: [
                    Color.orange.opacity(orangeOpacity),
                    Color.purple.opacity(purpleOpacity),
                    Color.blue.opacity(blueOpacity)
                ],
                startPoint: UnitPoint(
                    x: 0.2 + 0.15 * sin(angle),
                    y: 0.0 + 0.1 * cos(angle)
                ),
                endPoint: UnitPoint(
                    x: 0.8 - 0.1 * cos(angle),
                    y: 1.0 - 0.15 * sin(angle)
                )
            )
        }
    }

    /// Keep simulator visuals pinned to the classic 9:41 watch time.
    /// Real devices continue to use the live clock.
    private func watchDisplayDate(for date: Date) -> Date {
        #if targetEnvironment(simulator)
        return Calendar.current.date(
            bySettingHour: 9,
            minute: 41,
            second: Calendar.current.component(.second, from: date),
            of: date
        ) ?? date
        #else
        return date
        #endif
    }
}

// MARK: - Waveform Animation

private struct WatchWaveformView: View {
    let tint: Color
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: isAnimating ? barHeight(for: index) : 4)
                    .animation(
                        .easeInOut(duration: barDuration(for: index))
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.1),
                        value: isAnimating
                    )
            }
        }
        .frame(height: 18)
        .onAppear { isAnimating = true }
    }

    private func barHeight(for index: Int) -> CGFloat {
        switch index {
        case 0: return 12
        case 1: return 18
        case 2: return 10
        case 3: return 15
        default: return 8
        }
    }

    private func barDuration(for index: Int) -> Double {
        switch index {
        case 0: return 0.45
        case 1: return 0.35
        case 2: return 0.5
        case 3: return 0.4
        default: return 0.4
        }
    }
}

// MARK: - Thinking Dots

private struct WatchThinkingDots: View {
    @State private var activeIndex = 0
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.orange.opacity(index == activeIndex ? 0.9 : 0.3))
                    .frame(width: 6, height: 6)
                    .scaleEffect(index == activeIndex ? 1.3 : 1.0)
                    .animation(.easeInOut(duration: 0.3), value: activeIndex)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                activeIndex = (activeIndex + 1) % 3
            }
        }
    }
}

// MARK: - Primary Action Card

private struct WatchPrimaryActionCard: View {
    let isCapturingVoice: Bool
    let isReady: Bool
    let isDisabled: Bool
    let action: () -> Void

    @State private var pulseScale: CGFloat = 1.0

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
                    ZStack {
                        if isReady && !isCapturingVoice {
                            Circle()
                                .fill(.orange.opacity(0.25))
                                .frame(width: 28, height: 28)
                                .scaleEffect(pulseScale)
                                .opacity(2.0 - Double(pulseScale))
                        }
                        Image(systemName: isCapturingVoice ? "waveform.circle.fill" : "mic.circle.fill")
                            .font(.title3.weight(.semibold))
                    }

                    Text(isCapturingVoice ? String(localized: "Listening...") : String(localized: "Speak to Ask"))
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(isDisabled)
            .accessibilityLabel(isCapturingVoice ? String(localized: "Listening") : String(localized: "Speak to ask"))
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
        .onAppear {
            if isReady {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    pulseScale = 1.5
                }
            }
        }
        .onChange(of: isReady) {
            if isReady {
                pulseScale = 1.0
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    pulseScale = 1.5
                }
            } else {
                pulseScale = 1.0
            }
        }
    }
}

// MARK: - Status Row

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

// MARK: - Quick Prompt Section

private struct WatchQuickPromptSection: View {
    let prompts: [(icon: String, text: String)]
    let isDisabled: Bool
    let onPromptSelected: (String) -> Void
    let onTypeTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick prompts")
                .font(.headline)

            ForEach(prompts, id: \.text) { prompt in
                Button {
                    onPromptSelected(prompt.text)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: prompt.icon)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(width: 16)
                        Text(prompt.text)
                    }
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

// MARK: - Typed Prompt Sheet

private struct WatchTypedPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WatchConnectivityClient.self) private var connectivityClient

    private let maxCharacters = 200

    var body: some View {
        @Bindable var connectivityClient = connectivityClient

        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Type a prompt", text: $connectivityClient.prompt, axis: .vertical)
                    .lineLimit(2...5)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                connectivityClient.trimmedPrompt.isEmpty ? .clear : .orange.opacity(0.4),
                                lineWidth: 1.5
                            )
                    )
                    .accessibilityLabel("Prompt")

                HStack {
                    Text("\(connectivityClient.trimmedPrompt.count)/\(maxCharacters)")
                        .font(.caption2)
                        .foregroundStyle(
                            connectivityClient.trimmedPrompt.count > maxCharacters
                                ? .red
                                : .secondary
                        )
                        .monospacedDigit()

                    Spacer()
                }

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

// MARK: - Empty State

private struct WatchEmptyState: View {
    let isReachable: Bool
    let isSending: Bool

    @State private var appeared = false
    @State private var glowPhase: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    let startDegrees = Double(glowPhase) * 360.0
                    Circle()
                        .fill(
                            AngularGradient(
                                colors: [.orange, .pink, .purple, .blue, .orange],
                                center: .center,
                                startAngle: .degrees(startDegrees),
                                endAngle: .degrees(startDegrees + 360.0)
                            )
                        )
                        .frame(width: 34, height: 34)
                        .blur(radius: 4)
                        .opacity(0.5)

                    Image("logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }

                Text("Own Ai")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            Image(systemName: isSending ? "waveform.badge.mic" : "mic.and.signal.meter")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(isReachable ? .orange : .secondary)
                .symbolEffect(.pulse, options: .repeating, isActive: isSending)

            Text(emptyTitle)
                .font(.headline)

            Text(emptyMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                appeared = true
            }
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                glowPhase = 1
            }
        }
    }

    private var emptyTitle: String {
        if isSending {
            return String(localized: "Working")
        }
        if isReachable {
            return String(localized: "Ask Something")
        }
        return String(localized: "Open iPhone App")
    }

    private var emptyMessage: String {
        if isSending {
            return String(localized: "Your iPhone is handling it.")
        }
        if isReachable {
            return String(localized: "Tap the mic or use a quick prompt.")
        }
        return String(localized: "Open the iPhone app to send and receive replies.")
    }
}

// MARK: - State Banner

private struct WatchStateBanner: View {
    let title: String
    let message: String
    let iconName: String
    let tint: Color
    let buttonTitle: String?
    let action: (() -> Void)?
    let showWaveform: Bool

    init(
        title: String,
        message: String,
        iconName: String,
        tint: Color,
        buttonTitle: String? = nil,
        action: (() -> Void)? = nil,
        showWaveform: Bool = false
    ) {
        self.title = title
        self.message = message
        self.iconName = iconName
        self.tint = tint
        self.buttonTitle = buttonTitle
        self.action = action
        self.showWaveform = showWaveform
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(title, systemImage: iconName)
                    .font(.headline)
                    .foregroundStyle(tint)

                if showWaveform {
                    WatchWaveformView(tint: tint)
                }
            }

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

// MARK: - Message Bubble

private struct WatchMessageBubble: View {
    @Environment(WatchConnectivityClient.self) private var connectivityClient
    let entry: WatchChatEntry
    @State private var isExpanded = false

    private let collapsedLineLimit = 6
    private let collapseThreshold = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.role == .user ? String(localized: "You") : String(localized: "Own Ai"))
                .font(.caption2.weight(.bold))
                .foregroundStyle(entry.role == .user ? .orange : .secondary)

            if entry.isPending {
                HStack(spacing: 8) {
                    WatchThinkingDots()
                    Text(entry.content)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(entry.content)
                    .font(.callout)
                    .lineLimit(isExpandable && !isExpanded ? collapsedLineLimit : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let pendingState = entry.pendingState {
                WatchMessageStatePill(state: pendingState)
            }

            if !entry.isPending {
                HStack(spacing: 6) {
                    if let modelName = entry.modelName {
                        Text(modelName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let respondedAt = entry.respondedAt {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Text(relativeFormatter.localizedString(for: respondedAt, relativeTo: .now))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if isExpandable {
                Button(isExpanded ? String(localized: "Show Less") : String(localized: "Read More")) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityHint(isExpanded ? String(localized: "Collapses the full reply.") : String(localized: "Expands the full reply."))
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
        .padding(10)
        .background(backgroundStyle)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(borderStyle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)

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
        let speaker = entry.role == .user ? String(localized: "You") : String(localized: "Own Ai")
        return "\(speaker). \(entry.content)"
    }


}

// MARK: - Message State Pill

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
            return String(localized: "Sending")
        case .queued:
            return String(localized: "Queued")
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
                    respondedAt: .now,
                    isError: false
                )
            ]
            client.statusMessage = "Connected to your iPhone."
            return client
        }())
}
