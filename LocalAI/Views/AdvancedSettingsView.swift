//
//  AdvancedSettingsView.swift
//  Own Ai
//
//  Created by Tudor on 09.05.2026.
//

import SwiftUI

struct AdvancedSettingsView: View {
    @AppStorage(PDFOCRMode.storageKey) private var pdfOCRModeRaw = PDFOCRMode.preferNativeText.rawValue
    @AppStorage(DocumentProcessingMode.storageKey) private var documentProcessingModeRaw = DocumentProcessingMode.fast.rawValue
    @AppStorage(ImageProcessingMode.storageKey) private var imageProcessingModeRaw = ImageProcessingMode.fast.rawValue
    @AppStorage("lowPowerMode") private var lowPowerMode = false
    @AppStorage("inChatSearchEnabled") private var inChatSearchEnabled = false
    @AppStorage("smartReplyStylesEnabled") private var smartReplyStylesEnabled = false
    @AppStorage("systemPrompt") private var systemPrompt = AIResponseDefaults.defaultSystemPrompt
    @AppStorage("messageTextScale") private var messageTextScale: Double = 1.0

    @AppStorage("autoRead") private var autoRead = false

    private var pdfOCRMode: PDFOCRMode {
        PDFOCRMode(rawValue: pdfOCRModeRaw) ?? .preferNativeText
    }

    private var documentProcessingMode: DocumentProcessingMode {
        DocumentProcessingMode(rawValue: documentProcessingModeRaw) ?? .fast
    }

    private var imageProcessingMode: ImageProcessingMode {
        ImageProcessingMode(rawValue: imageProcessingModeRaw) ?? .fast
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                pdfOCRSection
                behaviorSection
                textSizeSection
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
                rowIcon(systemImage: "doc.text.magnifyingglass", tint: .blue)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Document Processing")
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    Menu {
                        ForEach(DocumentProcessingMode.allCases) { mode in
                            Button {
                                documentProcessingModeRaw = mode.rawValue
                            } label: {
                                if mode == documentProcessingMode {
                                    Label(mode.title, systemImage: "checkmark")
                                } else {
                                    Text(mode.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(documentProcessingMode.title)
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
                        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel("Document Processing")
                    .accessibilityValue(documentProcessingMode.title)

                    Text(documentProcessingMode.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            sectionDivider

            HStack(spacing: 14) {
                rowIcon(systemImage: "photo.on.rectangle.angled", tint: .purple)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Image Processing")
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    Menu {
                        ForEach(ImageProcessingMode.allCases) { mode in
                            Button {
                                imageProcessingModeRaw = mode.rawValue
                            } label: {
                                if mode == imageProcessingMode {
                                    Label(mode.title, systemImage: "checkmark")
                                } else {
                                    Text(mode.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(imageProcessingMode.title)
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
                        .background(Color.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel("Image Processing")
                    .accessibilityValue(imageProcessingMode.title)

                    Text(imageProcessingMode.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            sectionDivider

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

    // MARK: - Text Size

    private var textSizeSection: some View {
        advancedSection("Display") {
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    rowIcon(systemImage: "textformat.size", tint: .purple)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Message Text Size")
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)

                        Text("\(Int(messageTextScale * 100))% of default")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            messageTextScale = 1.0
                        }
                    } label: {
                        Text("Reset")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(messageTextScale == 1.0 ? Color(white: 0.7) : .blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(messageTextScale == 1.0)
                }

                HStack(spacing: 12) {
                    Image(systemName: "textformat.size.smaller")
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.5))

                    Slider(value: $messageTextScale, in: 0.8...1.3, step: 0.05)
                        .tint(.purple)

                    Image(systemName: "textformat.size.larger")
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.5))
                }

                // Preview bubble
                Text("This is how messages will look.")
                    .font(.system(size: 17 * messageTextScale))
                    .foregroundStyle(Color(white: 0.3))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
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
