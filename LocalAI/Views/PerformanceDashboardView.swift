import SwiftUI

struct PerformanceDashboardView: View {
    @AppStorage(PerformanceMetricsStore.collectionEnabledKey) private var collectionEnabled = true
    @State private var dashboard = PerformanceDashboardData(
        samples: [],
        summaries: [],
        modelSummaries: [],
        health: PerformanceHealthSummary(
            totalSamples: 0,
            failedOperations: 0,
            peakResidentMemoryBytes: nil
        )
    )
    @State private var isLoading = true
    @State private var isExporting = false
    @State private var exportItems: [Any] = []
    @State private var showShareSheet = false
    @State private var showClearConfirmation = false
    @State private var errorMessage: String?

    private var recentSamples: [PerformanceSample] {
        Array(dashboard.samples.prefix(50))
    }

    var body: some View {
        List {
            overviewSection
            targetsSection
            modelSection
            recentSection
            dataSection
        }
        .navigationTitle("Performance")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh measurements")

                Button(action: exportReport) {
                    if isExporting {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .disabled(isExporting || dashboard.samples.isEmpty)
                .accessibilityLabel("Export performance report")
            }
        }
        .task { await refresh() }
        .sheet(isPresented: $showShareSheet, onDismiss: { discardExportedReport() }) {
            ShareSheet(items: exportItems)
        }
        .alert("Clear Measurements?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                Task {
                    await PerformanceMetricsStore.shared.clear()
                    await refresh()
                }
            }
        } message: {
            Text("This removes locally stored performance history. Console logs and Instruments traces are unaffected.")
        }
        .alert(
            "Performance Report Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var overviewSection: some View {
        Section {
            Toggle(isOn: $collectionEnabled) {
                Label("Save Measurement History", systemImage: "gauge.with.dots.needle.67percent")
            }

            HStack {
                Label("Stored Samples", systemImage: "chart.xyaxis.line")
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("\(dashboard.samples.count)")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Label("Failed Operations", systemImage: "exclamationmark.triangle")
                Spacer()
                Text("\(dashboard.health.failedOperations)")
                    .foregroundStyle(dashboard.health.failedOperations == 0 ? Color.secondary : Color.red)
            }

            if let peakMemory = dashboard.health.peakResidentMemoryBytes {
                HStack {
                    Label("Peak Recorded Memory", systemImage: "memorychip")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(peakMemory), countStyle: .memory))
                        .foregroundStyle(.secondary)
                }
            }

            if let newest = dashboard.samples.first?.timestamp {
                HStack {
                    Label("Latest Measurement", systemImage: "clock")
                    Spacer()
                    Text(newest, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Overview")
        } footer: {
            Text("Measurements stay on this device for up to 30 days. Prompts, responses, and document text are never recorded.")
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        if !dashboard.modelSummaries.isEmpty {
            Section("By Model") {
                ForEach(dashboard.modelSummaries) { summary in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(shortModelName(summary.modelID))
                            .font(.body.weight(.medium))
                            .lineLimit(2)

                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 16) {
                                optionalMetricValue(
                                    "First token",
                                    value: summary.medianFirstTokenMilliseconds,
                                    suffix: ""
                                )
                                optionalMetricValue(
                                    "Generation",
                                    value: summary.medianGenerationMilliseconds,
                                    suffix: ""
                                )
                                optionalMetricValue(
                                    "Speed",
                                    value: summary.medianEffectiveTokensPerSecond,
                                    suffix: " tok/s",
                                    isDuration: false
                                )
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                optionalMetricValue(
                                    "First token",
                                    value: summary.medianFirstTokenMilliseconds,
                                    suffix: ""
                                )
                                optionalMetricValue(
                                    "Generation",
                                    value: summary.medianGenerationMilliseconds,
                                    suffix: ""
                                )
                                optionalMetricValue(
                                    "Speed",
                                    value: summary.medianEffectiveTokensPerSecond,
                                    suffix: " tok/s",
                                    isDuration: false
                                )
                            }
                        }

                        Text("\(summary.generationCount) generation\(summary.generationCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private var targetsSection: some View {
        Section("Speed Targets") {
            if dashboard.summaries.isEmpty {
                ContentUnavailableView(
                    "No Timings Yet",
                    systemImage: "stopwatch",
                    description: Text("Use the app normally, then return here to review launch, model, response, and document timings.")
                )
            } else {
                ForEach(dashboard.summaries) { summary in
                    metricRow(summary)
                }
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        Section {
            if recentSamples.isEmpty {
                Text("No measurements stored.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recentSamples) { sample in
                    sampleRow(sample)
                }
            }
        } header: {
            Text("Recent Measurements")
        } footer: {
            if dashboard.samples.count > recentSamples.count {
                Text("Showing the latest \(recentSamples.count) of \(dashboard.samples.count) measurements. Export the report for the full history.")
            }
        }
    }

    private var dataSection: some View {
        Section {
            Button(action: exportReport) {
                Label("Export JSON Report", systemImage: "square.and.arrow.up")
            }
            .disabled(isExporting || dashboard.samples.isEmpty)

            Button("Clear Measurements", systemImage: "trash", role: .destructive) {
                showClearConfirmation = true
            }
            .disabled(dashboard.samples.isEmpty)
        } header: {
            Text("Data")
        } footer: {
            Text("For Instruments, profile the app with the Points of Interest track. The same operations appear there as signpost intervals.")
        }
    }

    private func metricRow(_ summary: PerformanceMetricSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: metricIcon(for: summary.name))
                    .foregroundStyle(ratingColor(summary.rating))
                    .frame(width: 24)

                Text(summary.name)
                    .font(.body.weight(.medium))

                Spacer()

                Label(ratingTitle(summary.rating), systemImage: ratingIcon(summary.rating))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ratingColor(summary.rating))
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    metricValue("Median", milliseconds: summary.medianMilliseconds)
                    metricValue("P95", milliseconds: summary.p95Milliseconds)
                    metricValue("Latest", milliseconds: summary.latestMilliseconds)
                }

                VStack(alignment: .leading, spacing: 8) {
                    metricValue("Median", milliseconds: summary.medianMilliseconds)
                    metricValue("P95", milliseconds: summary.p95Milliseconds)
                    metricValue("Latest", milliseconds: summary.latestMilliseconds)
                }
            }

            HStack(spacing: 12) {
                Text("\(summary.sampleCount) sample\(summary.sampleCount == 1 ? "" : "s")")
                if let target = summary.targetMilliseconds {
                    Text("Target: \(durationText(target))")
                }
                if let trend = summary.recentTrendPercent {
                    Label(
                        "\(abs(Int(trend.rounded())))% \(trend <= 0 ? "faster" : "slower")",
                        systemImage: trend <= 0 ? "arrow.down.right" : "arrow.up.right"
                    )
                    .foregroundStyle(trend <= 0 ? .green : .orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func metricValue(_ title: String, milliseconds: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(durationText(milliseconds))
                .font(.subheadline.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func optionalMetricValue(
        _ title: String,
        value: Double?,
        suffix: String,
        isDuration: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let value {
                Text(isDuration ? durationText(value) : String(format: "%.1f%@", value, suffix))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            } else {
                Text("—")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sampleRow(_ sample: PerformanceSample) -> some View {
        HStack(spacing: 12) {
            Image(systemName: sampleIcon(sample.kind))
                .foregroundStyle(sample.status == "success" ? Color.secondary : Color.red)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(sample.name)
                    .font(.subheadline.weight(.medium))
                Text(sample.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let duration = sample.durationMilliseconds {
                Text(durationText(duration))
                    .font(.subheadline.monospacedDigit())
            } else if let bytes = sample.residentMemoryBytes {
                Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory))
                    .font(.subheadline.monospacedDigit())
            } else {
                Text(sample.status.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func refresh() async {
        isLoading = true
        dashboard = await PerformanceMetricsStore.shared.dashboardData()
        isLoading = false
    }

    private func exportReport() {
        guard !isExporting else { return }
        isExporting = true
        Task {
            do {
                let url = try await PerformanceMetricsStore.shared.exportReport()
                exportItems = [url]
                showShareSheet = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }

    /// Drops the temporary report file once sharing ends rather than leaving it
    /// in the temporary directory.
    private func discardExportedReport() {
        for case let url as URL in exportItems {
            try? FileManager.default.removeItem(at: url)
        }
        exportItems = []
    }

    private func durationText(_ milliseconds: Double) -> String {
        if milliseconds >= 1_000 {
            return String(format: "%.2f s", milliseconds / 1_000)
        }
        return String(format: "%.0f ms", milliseconds)
    }

    private func metricIcon(for name: String) -> String {
        switch name {
        case "App launch": return "app.badge.checkmark"
        case "Model load": return "square.stack.3d.up"
        case "First token": return "bolt.fill"
        case "Chat response": return "bubble.left.and.text.bubble.right"
        case "Generation": return "text.cursor"
        case "Document extraction": return "doc.text.magnifyingglass"
        case "Document indexing": return "square.stack.3d.down.right"
        default: return "stopwatch"
        }
    }

    private func shortModelName(_ modelID: String) -> String {
        modelID.split(separator: "/").last.map(String.init) ?? modelID
    }

    private func sampleIcon(_ kind: PerformanceSampleKind) -> String {
        switch kind {
        case .interval: return "stopwatch"
        case .event: return "bolt"
        case .memory: return "memorychip"
        }
    }

    private func ratingTitle(_ rating: PerformanceRating) -> String {
        switch rating {
        case .good: return "On target"
        case .warning: return "Watch"
        case .slow: return "Slow"
        case .unscored: return "Measured"
        }
    }

    private func ratingIcon(_ rating: PerformanceRating) -> String {
        switch rating {
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .slow: return "xmark.circle.fill"
        case .unscored: return "circle.fill"
        }
    }

    private func ratingColor(_ rating: PerformanceRating) -> Color {
        switch rating {
        case .good: return .green
        case .warning: return .orange
        case .slow: return .red
        case .unscored: return .secondary
        }
    }
}

#Preview {
    NavigationStack {
        PerformanceDashboardView()
    }
}
