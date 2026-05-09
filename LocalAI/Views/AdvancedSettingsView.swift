//
//  AdvancedSettingsView.swift
//  Own Ai
//
//  Created by Tudor on 09.05.2026.
//

import SwiftUI

struct AdvancedSettingsView: View {
    @AppStorage(PDFOCRMode.storageKey) private var pdfOCRModeRaw = PDFOCRMode.preferNativeText.rawValue
    @AppStorage("lowPowerMode") private var lowPowerMode = false
    @AppStorage("inChatSearchEnabled") private var inChatSearchEnabled = false
    @AppStorage("smartReplyStylesEnabled") private var smartReplyStylesEnabled = false
    @AppStorage("systemPrompt") private var systemPrompt = AIResponseDefaults.defaultSystemPrompt

    @AppStorage("autoRead") private var autoRead = false

    private var pdfOCRMode: PDFOCRMode {
        PDFOCRMode(rawValue: pdfOCRModeRaw) ?? .preferNativeText
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                pdfOCRSection
                behaviorSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - PDF OCR

    private var pdfOCRSection: some View {
        advancedSection("Documents") {
            HStack(spacing: 14) {
                rowIcon(systemImage: "doc.text.viewfinder", tint: .teal)

                VStack(alignment: .leading, spacing: 10) {
                    Text("PDF OCR Mode")
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    Menu {
                        ForEach(PDFOCRMode.allCases) { mode in
                            Button {
                                pdfOCRModeRaw = mode.rawValue
                            } label: {
                                if mode == pdfOCRMode {
                                    Label(mode.title, systemImage: "checkmark")
                                } else {
                                    Text(mode.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(pdfOCRMode.title)
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 8)

                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(Color.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel("PDF OCR Mode")
                    .accessibilityValue(pdfOCRMode.title)

                    Text(pdfOCRMode.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        advancedSection("Behavior") {
            advancedToggleRow(
                icon: "speaker.wave.2.fill",
                tint: .orange,
                title: "Read Replies Aloud",
                subtitle: "Speak control on responses for hands-free playback",
                isOn: $autoRead
            )

            sectionDivider

            advancedToggleRow(
                icon: "battery.25percent",
                tint: .green,
                title: "Low Power Mode",
                subtitle: "Lighter local behavior for lower battery impact",
                isOn: $lowPowerMode
            )

            sectionDivider

            advancedToggleRow(
                icon: "magnifyingglass",
                tint: .blue,
                title: "Search in Conversation",
                subtitle: "Show a search button inside active chats",
                isOn: $inChatSearchEnabled
            )

            sectionDivider

            advancedToggleRow(
                icon: "curlybraces",
                tint: .indigo,
                title: "Reply Style",
                subtitle: "Show quick options under replies",
                isOn: $smartReplyStylesEnabled
            )
            .onChange(of: smartReplyStylesEnabled) {
                systemPrompt = AIResponseDefaults.defaultSystemPrompt
            }
        }
    }

    // MARK: - Reusable Components

    private var sectionDivider: some View {
        Divider()
            .padding(.leading, 62)
    }

    private func advancedSection<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote)
                .fontWeight(.semibold)
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content()
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.04), radius: 10, y: 5)
        }
    }

    private func advancedToggleRow(
        icon: String,
        tint: Color,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 14) {
            rowIcon(systemImage: icon, tint: tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle(title, isOn: isOn)
                .labelsHidden()
                .tint(tint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func rowIcon(systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }
}

#Preview {
    NavigationStack {
        AdvancedSettingsView()
    }
}
