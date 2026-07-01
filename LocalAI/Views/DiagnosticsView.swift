//
//  DiagnosticsView.swift
//  Own Ai
//
//  Created by Tudor.
//

import SwiftUI

/// Lists the crash/hang/exception reports MetricKit has captured on this
/// device so they can be shared for a support request, without needing a
/// third-party crash-reporting backend.
struct DiagnosticsView: View {
    private struct ShareItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private let crashReporting = CrashReportingManager.shared

    @State private var reports: [URL] = []
    @State private var shareItem: ShareItem?
    @State private var showClearConfirmation = false

    var body: some View {
        List {
            if reports.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No reports yet")
                            .font(.body)
                            .fontWeight(.medium)
                        Text("iOS generates these automatically after a crash, freeze, or major slowdown, usually within a day. Nothing is sent anywhere unless you share it yourself.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            } else {
                Section {
                    ForEach(reports, id: \.self) { url in
                        Button {
                            shareItem = ShareItem(url: url)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: url.lastPathComponent.hasPrefix("diagnostic") ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
                                    .foregroundStyle(url.lastPathComponent.hasPrefix("diagnostic") ? .orange : .secondary)
                                    .accessibilityHidden(true)
                                Text(displayName(for: url))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityLabel("Share report from \(displayName(for: url))")
                    }
                } footer: {
                    Text("Reports stay on this device until you share or delete them.")
                }

                Section {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Text("Delete All Reports")
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert("Delete all reports?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                crashReporting.deleteAllReports()
                refresh()
            }
        } message: {
            Text("This permanently removes every diagnostic report saved on this device.")
        }
    }

    private func refresh() {
        reports = crashReporting.savedReports
    }

    private func displayName(for url: URL) -> String {
        let isCrash = url.lastPathComponent.hasPrefix("diagnostic")
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(isCrash ? "Crash/Hang Report" : "Metric Report") · \(formatter.string(from: date))"
    }
}
