//
//  DownloadsView.swift
//  LocalAI
//
//  One screen for everything in flight: what is downloading, what is waiting
//  behind it, and what failed. Reachable from the chat toolbar indicator and
//  from Settings.
//

import SwiftUI

struct DownloadsView: View {
    /// Adds a Done button. Set when the screen is presented as a sheet rather
    /// than pushed onto an existing navigation stack, which has its own back
    /// button and must not get a second dismissal control.
    var isPresentedAsSheet: Bool = false

    @Environment(ModelManager.self) private var modelManager
    @Environment(\.dismiss) private var dismiss
    @State private var showCancelAllConfirmation = false

    private var active: [ModelInfo] { modelManager.activeDownloadModels }
    private var queued: [ModelInfo] { modelManager.queuedDownloadModels }
    private var failed: [ModelInfo] { modelManager.failedDownloadModels }

    private var isEmpty: Bool {
        active.isEmpty && queued.isEmpty && failed.isEmpty
    }

    private var showsSummary: Bool {
        modelManager.hasDownloadActivity && active.count + queued.count > 1
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if isEmpty {
                    emptyState
                } else {
                    // With a single transfer the row below already says the
                    // name, the rate and the time left; a card repeating them
                    // is just the same sentence twice.
                    if showsSummary {
                        summaryCard
                    }

                    if !active.isEmpty {
                        section(title: String(localized: "Downloading")) {
                            ForEach(active) { model in
                                ActiveDownloadRow(model: model)
                            }
                        }
                    }

                    if !queued.isEmpty {
                        section(title: String(localized: "Up Next")) {
                            ForEach(Array(queued.enumerated()), id: \.element.id) { index, model in
                                QueuedDownloadRow(model: model, position: index + 1)
                            }
                        }
                    }

                    if !failed.isEmpty {
                        section(title: String(localized: "Needs Attention")) {
                            ForEach(failed) { model in
                                FailedDownloadRow(model: model)
                            }
                        }
                    }

                    if modelManager.hasDownloadActivity {
                        backgroundNote
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 40)
            // Rows appearing and disappearing as downloads finish is the normal
            // case on this screen, not an edge case.
            .animation(.easeInOut(duration: 0.25), value: active.map(\.id))
            .animation(.easeInOut(duration: 0.25), value: queued.map(\.id))
            .animation(.easeInOut(duration: 0.25), value: failed.map(\.id))
        }
        .background(Color.adaptive(white: 0.96))
        .navigationTitle(String(localized: "Downloads"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if isPresentedAsSheet {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
            if modelManager.hasDownloadActivity {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showCancelAllConfirmation = true
                    } label: {
                        Text(String(localized: "Stop All"))
                    }
                }
            }
        }
        .confirmationDialog(
            String(localized: "Stop all downloads?"),
            isPresented: $showCancelAllConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Stop All"), role: .destructive) {
                modelManager.cancelAllDownloads()
            }
            Button(String(localized: "Keep Downloading"), role: .cancel) {}
        } message: {
            Text(String(localized: "Partly downloaded files are kept, so you can pick up where you left off."))
        }
        .cellularRestrictionAlert()
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    DownloadProgressRing(
                        progress: modelManager.aggregateDownloadProgress,
                        lineWidth: 6
                    )
                    .frame(width: 68, height: 68)

                    if let progress = modelManager.aggregateDownloadProgress {
                        Text(DownloadProgressFormat.percent(progress))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(Color.blue)
                    } else {
                        Image(systemName: "arrow.down")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(Color.blue)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(summaryHeadline)
                        .font(.headline)
                        .foregroundStyle(Color.adaptive(white: 0.16))

                    if let detail = summaryDetail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(Color.adaptive(white: 0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .background(Color.adaptiveCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.03), radius: 6, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summaryHeadline)
        .accessibilityValue(summaryDetail ?? "")
    }

    private var summaryHeadline: String {
        let total = active.count + queued.count
        if total <= 1, let single = active.first ?? queued.first {
            return single.name
        }
        return String(
            format: String(localized: "%lld models", defaultValue: "%lld models"),
            Int64(total)
        )
    }

    private var summaryDetail: String? {
        var parts: [String] = []
        if !active.isEmpty, active.allSatisfy({ $0.downloadState.isValidating }) {
            parts.append(String(localized: "Verifying the download"))
        } else if let speed = modelManager.aggregateDownloadSpeedBytesPerSecond {
            parts.append(DownloadProgressFormat.speed(speed))
        } else {
            parts.append(String(localized: "Connecting…"))
        }
        if let remaining = modelManager.aggregateDownloadTimeRemaining,
           let formatted = DownloadProgressFormat.timeRemaining(remaining) {
            parts.append(formatted)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var backgroundNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.footnote)
                .foregroundStyle(Color.adaptive(white: 0.5))
            Text(String(localized: "Downloads keep going for about half a minute after you leave Own AI, then pause. Reopen the app and they pick up where they left off, even if it was closed in between."))
                .font(.footnote)
                .foregroundStyle(Color.adaptive(white: 0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 14) {
            AppLottieView(animation: .downloadIdle, tint: Color.adaptive(white: 0.65))
                .frame(width: 64, height: 64)

            Text(String(localized: "No downloads in progress"))
                .font(.headline)
                .foregroundStyle(Color.adaptive(white: 0.2))

            Text(String(localized: "When you download a model it shows up here with its progress, speed, and time remaining."))
                .font(.subheadline)
                .foregroundStyle(Color.adaptive(white: 0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .padding(.horizontal, 16)
        .background(Color.adaptiveCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.03), radius: 6, y: 3)
    }

    // MARK: - Layout Helpers

    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.adaptive(white: 0.4))
                .padding(.horizontal, 4)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Active Row

/// One in-flight model: name, size, a determinate bar, and the three numbers
/// people actually check — how much has landed, how fast, how much longer.
struct ActiveDownloadRow: View {
    let model: ModelInfo
    @Environment(ModelManager.self) private var modelManager

    private var progress: Double? { model.downloadState.progressFraction }
    private var isValidating: Bool { model.downloadState.isValidating }
    private var isUserPaused: Bool {
        modelManager.pauseReason(for: model.id)?.isUserRequested ?? false
    }

    private var statusLine: String {
        if isValidating {
            return String(localized: "Verifying files…")
        }
        var parts: [String] = []
        if let progress {
            parts.append(DownloadProgressFormat.transferred(
                fraction: progress,
                totalBytes: model.estimatedTotalBytes
            ))
        }
        if let reason = modelManager.pauseReason(for: model.id) {
            parts.append(reason.statusText)
            return parts.joined(separator: " · ")
        }
        if let speed = model.downloadState.speedBytesPerSecond {
            parts.append(DownloadProgressFormat.speed(speed))
        }
        if let remaining = modelManager.downloadTimeRemaining(for: model),
           let formatted = DownloadProgressFormat.timeRemaining(remaining) {
            parts.append(formatted)
        }
        if parts.isEmpty {
            parts.append(String(localized: "Starting…"))
        }
        return parts.joined(separator: " · ")
    }

    /// Spelled out as a property rather than built inline: passing
    /// `DownloadProgressFormat.percent` as a bare method reference crosses out
    /// of the view's main-actor context, which Swift 6 rejects outright.
    private var accessibilityValue: String {
        guard let progress else { return statusLine }
        return "\(DownloadProgressFormat.percent(progress)), \(statusLine)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Centred now that the title is a single line of text next to a
            // 44pt hit target; top alignment left the name floating above it.
            HStack(spacing: 12) {
                // No size subtitle here: the status line under the bar
                // already ends in "of 4.1 GB", and the two were quoting the
                // same number in two different roundings.
                Text(model.name)
                    .font(.headline)
                    .foregroundStyle(Color.adaptive(white: 0.16))
                    .lineLimit(2)

                Spacer(minLength: 8)

                if let progress {
                    Text(DownloadProgressFormat.percent(progress))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(Color.blue)
                }

                // Pause/resume is the non-destructive control, so it sits
                // before the X and is the one a stray tap is more likely to hit.
                if !isValidating {
                    DownloadPauseResumeButton(
                        isPaused: isUserPaused,
                        pause: { modelManager.pauseDownload(model.id) },
                        resume: { modelManager.resumeDownload(model.id) }
                    )
                }

                Button(role: .cancel) {
                    modelManager.cancelDownload(model.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(Color.adaptive(white: 0.45))
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Cancel download"))
                .accessibilityInputLabels([
                    String(localized: "Cancel"),
                    String(localized: "Stop download")
                ])
            }

            DownloadProgressBar(progress: progress, tint: isValidating ? .green : .blue)

            Text(statusLine)
                .font(.caption)
                .foregroundStyle(Color.adaptive(white: 0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(16)
        .background(Color.adaptiveCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.03), radius: 6, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.name)
        .accessibilityValue(accessibilityValue)
    }
}

/// Shared pause/play toggle for the download rows and the model card. Kept
/// as one view so the two surfaces cannot drift in size or labelling.
struct DownloadPauseResumeButton: View {
    let isPaused: Bool
    let pause: () -> Void
    let resume: () -> Void

    @ScaledMetric(relativeTo: .body) private var buttonSize = 44.0

    var body: some View {
        Button {
            if isPaused { resume() } else { pause() }
        } label: {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.caption.bold())
                .foregroundStyle(isPaused ? Color.blue : Color.adaptive(white: 0.45))
                .frame(width: buttonSize, height: buttonSize)
                .background(isPaused ? Color.blue.opacity(0.1) : Color.black.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPaused
            ? String(localized: "Resume download")
            : String(localized: "Pause download"))
        .accessibilityInputLabels(isPaused
            ? [String(localized: "Resume"), String(localized: "Continue download")]
            : [String(localized: "Pause"), String(localized: "Pause download")])
    }
}

// MARK: - Queued Row

struct QueuedDownloadRow: View {
    let model: ModelInfo
    let position: Int
    @Environment(ModelManager.self) private var modelManager

    var body: some View {
        HStack(spacing: 12) {
            Text("\(position)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.adaptive(white: 0.45))
                .frame(width: 26, height: 26)
                .background(Color.adaptive(white: 0.93))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(model.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.adaptive(white: 0.16))
                    .lineLimit(1)
                Text(String(
                    format: String(localized: "%@ · waiting for the current download", defaultValue: "%@ · waiting for the current download"),
                    model.sizeLabel
                ))
                .font(.caption)
                .foregroundStyle(Color.adaptive(white: 0.5))
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(role: .cancel) {
                modelManager.cancelDownload(model.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(Color.adaptive(white: 0.45))
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Remove from queue"))
        }
        .padding(14)
        .background(Color.adaptiveCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.03), radius: 6, y: 3)
    }
}

// MARK: - Failed Row

struct FailedDownloadRow: View {
    let model: ModelInfo
    @Environment(ModelManager.self) private var modelManager
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    private var message: String {
        if case .error(let message) = model.downloadState { return message }
        return String(localized: "The download stopped.")
    }

    private var errorAction: DownloadErrorAction {
        modelManager.downloadErrorAction(for: model.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.adaptive(white: 0.16))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Color.adaptive(white: 0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    perform(errorAction)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: errorAction.iconName)
                        Text(errorAction.title)
                            .fontWeight(.medium)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.blue.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(ActionButtonStyle())

                Button {
                    modelManager.dismissDownloadFailure(for: model.id)
                } label: {
                    Text(String(localized: "Dismiss"))
                        .font(.subheadline)
                        .foregroundStyle(Color.adaptive(white: 0.45))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(Color.adaptive(white: 0.94))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(ActionButtonStyle())
            }
        }
        .padding(16)
        .background(Color.adaptiveCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.03), radius: 6, y: 3)
    }

    private func perform(_ action: DownloadErrorAction) {
        switch action {
        case .retry:
            modelManager.downloadModel(model.id, selectWhenFinished: true)
        case .repair:
            modelManager.repairModel(model.id, selectWhenFinished: true)
        case .freeSpace:
            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                openURL(settingsURL)
            }
        case .cellularRestricted, .unsupported:
            // Both are resolved somewhere else (Settings, or a different model),
            // so there is nothing to do here but get out of the way.
            dismiss()
        }
    }
}

// MARK: - Progress Bar

/// Determinate bar that degrades to an indeterminate shimmer while the position
/// is unknown, rather than showing a zero-width bar that reads as stalled.
struct DownloadProgressBar: View {
    let progress: Double?
    var tint: Color = .blue
    var height: CGFloat = 8

    @State private var slidePhase: CGFloat = -0.4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.adaptive(white: 0.92))

                if let progress {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(width * min(max(progress, 0), 1), height))
                        .animation(.easeOut(duration: 0.3), value: progress)
                } else if reduceMotion {
                    Capsule()
                        .fill(tint.opacity(0.5))
                        .frame(width: width * 0.3)
                } else {
                    Capsule()
                        .fill(tint.opacity(0.5))
                        .frame(width: width * 0.3)
                        .offset(x: width * slidePhase)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                                slidePhase = 1.1
                            }
                        }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

#Preview {
    NavigationStack {
        DownloadsView()
            .environment(ModelManager())
    }
}
