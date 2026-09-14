//
//  DownloadProgressIndicator.swift
//  LocalAI
//
//  Compact, always-visible signal that a model download is in flight, plus the
//  shared number formatting the downloads screen and the model cards both use.
//

import SwiftUI

// MARK: - Formatting

/// One place for the strings that describe a transfer, so the toolbar pill, the
/// model card and the downloads screen never disagree about how a rate or a
/// remaining time is written.
enum DownloadProgressFormat {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter
    }()

    /// Whole percent — a download bar with a decimal place on it reads as
    /// instrumentation, not progress.
    static func percent(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        return String(
            format: String(localized: "%lld%%", defaultValue: "%lld%%"),
            Int64((clamped * 100).rounded())
        )
    }

    static func bytes(_ value: Double) -> String {
        byteFormatter.string(fromByteCount: Int64(max(value, 0)))
    }

    /// "1.2 GB of 4.1 GB". Both halves are estimates off the catalog size, so
    /// they are only ever shown together with a progress bar.
    static func transferred(fraction: Double, totalBytes: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        return String(
            format: String(localized: "%@ of %@", defaultValue: "%@ of %@"),
            bytes(totalBytes * clamped),
            bytes(totalBytes)
        )
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        String(
            format: String(localized: "%@/s", defaultValue: "%@/s"),
            bytes(bytesPerSecond)
        )
    }

    /// Time left, or nil when there is no rate to divide by yet. Anything under
    /// ten seconds becomes "Almost done": the estimate is far too jumpy at that
    /// range to put a number on.
    static func timeRemaining(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds < 10 {
            return String(localized: "Almost done")
        }
        guard let formatted = durationFormatter.string(from: seconds.rounded()) else { return nil }
        return String(
            format: String(localized: "%@ left", defaultValue: "%@ left"),
            formatted
        )
    }
}

// MARK: - Ring

/// Determinate ring used wherever the indicator has to fit in a toolbar-sized
/// square. Falls back to a slow sweep while the position is still unknown
/// (queued, or a download that has not reported yet) so it never shows an empty
/// ring that looks broken.
struct DownloadProgressRing: View {
    let progress: Double?
    var lineWidth: CGFloat = 2.5
    var tint: Color = .brandAccent

    @State private var sweep = false
    /// Honours Reduce Motion: the indeterminate state stops spinning and shows
    /// a static partial ring instead.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(tint.opacity(0.18), lineWidth: lineWidth)

            if let progress {
                Circle()
                    .trim(from: 0, to: max(min(progress, 1), 0.02))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: progress)
            } else {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(sweep ? 270 : -90))
                    .animation(
                        reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false),
                        value: sweep
                    )
                    .onAppear { sweep = true }
            }
        }
    }
}

// MARK: - Toolbar Indicator

/// Tappable download status for a navigation bar: a progress ring wrapped
/// around a down-arrow, with the percentage read out to assistive technology.
/// Renders nothing at all when there is no download activity, so callers can
/// place it unconditionally.
struct DownloadActivityToolbarButton: View {
    @Environment(ModelManager.self) private var modelManager
    let action: () -> Void

    private var progress: Double? {
        modelManager.aggregateDownloadProgress
    }

    private var isValidating: Bool {
        modelManager.activeDownloadModels.contains { $0.downloadState.isValidating }
            && modelManager.activeDownloadModels.allSatisfy { $0.downloadState.isValidating }
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if let progress {
            parts.append(DownloadProgressFormat.percent(progress))
        }
        if let remaining = modelManager.aggregateDownloadTimeRemaining,
           let formatted = DownloadProgressFormat.timeRemaining(remaining) {
            parts.append(formatted)
        }
        let count = modelManager.activeDownloadModels.count + modelManager.queuedDownloadModels.count
        if count > 1 {
            parts.append(String(
                format: String(localized: "%lld models", defaultValue: "%lld models"),
                Int64(count)
            ))
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        if modelManager.hasDownloadActivity {
            Button(action: action) {
                ZStack {
                    DownloadProgressRing(progress: progress, tint: isValidating ? .green : .brandAccent)
                        .frame(width: 30, height: 30)

                    // The number goes inside the ring rather than beside it:
                    // the navigation bar also carries the model selector, and a
                    // wider pill here starts truncating that instead.
                    if let progress, !isValidating {
                        Text(DownloadProgressFormat.percent(progress))
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                            .foregroundStyle(Color.brandAccent)
                            .padding(.horizontal, 2)
                    } else {
                        Image(systemName: isValidating ? "checkmark.seal" : "arrow.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(isValidating ? Color.green : Color.brandAccent)
                    }
                }
                .frame(width: 32, height: 32)
                .background(Color.adaptive(white: 0.95))
                .clipShape(Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Downloads in progress"))
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(String(localized: "Opens the downloads screen."))
        }
    }
}

// MARK: - Inline Banner

/// Full-width summary for use inside a scrolling screen (settings, the models
/// list). Same numbers as the toolbar ring, with room to name what is coming
/// down and how much is left. This is the bare label — wrap it in a
/// `NavigationLink` or a `Button` to make it lead to the downloads screen.
struct DownloadActivitySummaryLabel: View {
    @Environment(ModelManager.self) private var modelManager

    private var headline: String {
        let active = modelManager.activeDownloadModels
        if let first = active.first {
            if active.count > 1 {
                return String(
                    format: String(localized: "%@ and %lld more", defaultValue: "%@ and %lld more"),
                    first.name,
                    Int64(active.count - 1)
                )
            }
            return first.name
        }
        if let queued = modelManager.queuedDownloadModels.first {
            return queued.name
        }
        return String(localized: "Downloading")
    }

    private var detail: String {
        var parts: [String] = []
        let active = modelManager.activeDownloadModels
        if !active.isEmpty, active.allSatisfy({ $0.downloadState.isValidating }) {
            parts.append(String(localized: "Verifying"))
        } else if let speed = modelManager.aggregateDownloadSpeedBytesPerSecond {
            parts.append(DownloadProgressFormat.speed(speed))
        }
        if let remaining = modelManager.aggregateDownloadTimeRemaining,
           let formatted = DownloadProgressFormat.timeRemaining(remaining) {
            parts.append(formatted)
        }
        let queuedCount = modelManager.queuedDownloadModels.count
        if queuedCount > 0 {
            parts.append(String(
                format: String(localized: "%lld waiting", defaultValue: "%lld waiting"),
                Int64(queuedCount)
            ))
        }
        if parts.isEmpty {
            parts.append(String(localized: "Starting…"))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    DownloadProgressRing(
                        progress: modelManager.aggregateDownloadProgress,
                        lineWidth: 3
                    )
                    .frame(width: 36, height: 36)

                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.brandAccent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.adaptive(white: 0.16))
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Color.adaptive(white: 0.45))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let progress = modelManager.aggregateDownloadProgress {
                    Text(DownloadProgressFormat.percent(progress))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.brandAccent)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.adaptive(white: 0.6))
            }

            DownloadProgressBar(
                progress: modelManager.aggregateDownloadProgress,
                height: 5
            )
        }
        .padding(14)
        .background(Color.adaptiveCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.brandAccent.opacity(0.16), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Downloads in progress"))
        .accessibilityValue("\(headline), \(detail)")
        .accessibilityHint(String(localized: "Opens the downloads screen."))
    }
}
