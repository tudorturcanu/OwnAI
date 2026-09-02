//
//  AdvancedSettingsView.swift
//  Own Ai
//
//  Created by Tudor on 09.05.2026.
//

import SwiftUI

struct AdvancedSettingsView: View {
    @Environment(LLMEngine.self) private var llmEngine
    @Environment(ModelManager.self) private var modelManager
    @Environment(SpeechManager.self) private var speechManager
    @AppStorage(PDFOCRMode.storageKey) private var pdfOCRModeRaw = PDFOCRMode.preferNativeText.rawValue
    @AppStorage(DocumentOCRBackend.storageKey) private var documentOCRBackendRaw = DocumentOCRBackend.appleVision.rawValue
    @AppStorage(DocumentProcessingMode.storageKey) private var documentProcessingModeRaw = DocumentProcessingMode.fast.rawValue
    @AppStorage(ImageProcessingMode.storageKey) private var imageProcessingModeRaw = ImageProcessingMode.fast.rawValue
    @AppStorage("lowPowerMode") private var lowPowerMode = false
    @AppStorage("inChatSearchEnabled") private var inChatSearchEnabled = true
    @AppStorage("smartReplyStylesEnabled") private var smartReplyStylesEnabled = false
    @AppStorage("systemPrompt") private var systemPrompt = AIResponseDefaults.defaultSystemPrompt
    @AppStorage("messageTextScale") private var messageTextScale: Double = 1.0
    @AppStorage("autoRead") private var autoRead = false
    @AppStorage(RAGEngine.neuralEmbeddingsDefaultsKey) private var neuralEmbeddingsEnabled = false
    @ScaledMetric(relativeTo: .body) private var messagePreviewBaseSize: CGFloat = 17
    @State private var whisperModelPresent = false
    @State private var kokoroModelPresent = false
    @State private var showKokoroDownloadAlert = false
    @State private var pendingKokoroBackend: SpeechOutputBackend?

    private var pdfOCRMode: PDFOCRMode {
        PDFOCRMode(rawValue: pdfOCRModeRaw) ?? .preferNativeText
    }

    private var documentOCRBackend: DocumentOCRBackend {
        DocumentOCRBackend(rawValue: documentOCRBackendRaw) ?? .appleVision
    }

    private var isGLMOCRDownloaded: Bool {
        modelManager.models.first(where: { $0.id == ModelInfo.glmOCR_4bit.id })?
            .downloadState.isDownloaded == true
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
        .onAppear {
            if neuralEmbeddingsEnabled {
                neuralEmbeddingsEnabled = false
                Task {
                    await DocumentManager.shared.setNeuralEmbeddingsEnabled(false)
                }
            }
            whisperModelPresent = speechManager.isWhisperModelDownloaded
            kokoroModelPresent = speechManager.isKokoroModelDownloaded
            if documentOCRBackend == .glmOCR && !isGLMOCRDownloaded {
                documentOCRBackendRaw = DocumentOCRBackend.appleVision.rawValue
            }
        }
        .alert(
            kokoroDownloadAlertTitle,
            isPresented: $showKokoroDownloadAlert,
            presenting: pendingKokoroBackend
        ) { backend in
            Button("Download") {
                activateSpeechOutputBackend(backend)
            }
            Button("Cancel", role: .cancel) {}
        } message: { backend in
            Text(kokoroDownloadAlertMessage(for: backend))
        }
    }

    private var kokoroDownloadAlertTitle: String {
        guard let voice = pendingKokoroBackend?.kokoroVoice else { return "" }
        return String(localized: "Download \(voice.displayName)?")
    }

    private func kokoroDownloadAlertMessage(for backend: SpeechOutputBackend) -> String {
        if KokoroModelStore.isWeightsDownloaded {
            return String(localized: "A small voice file (under 1 MB) will be downloaded.")
        }
        return String(localized: "A one-time ~\(KokoroModelStore.approximateWeightsMegabytes) MB download. Speech then works fully offline.")
    }

    // MARK: - Speech Output (Voice)

    private var availableSpeechOutputBackends: [SpeechOutputBackend] {
        SpeechManager.isKokoroSupportedOnCurrentDevice ? SpeechOutputBackend.allCases : [.system]
    }

    private func selectSpeechOutputBackend(_ backend: SpeechOutputBackend) {
        guard speechManager.speechOutputBackend != backend else { return }
        // A voice that still needs its one-time download is confirmed first;
        // the selection only changes once the user agrees.
        if let voice = backend.kokoroVoice, !KokoroModelStore.isReady(for: voice) {
            pendingKokoroBackend = backend
            showKokoroDownloadAlert = true
            return
        }
        activateSpeechOutputBackend(backend)
    }

    private func activateSpeechOutputBackend(_ backend: SpeechOutputBackend) {
        KokoroDiagnostics.log("settings", "selected \(backend.rawValue)")
        speechManager.stopSpeaking()
        speechManager.speechOutputBackend = backend
        guard backend != .system else { return }

        Task {
            let ready = await speechManager.prepareSpeechOutputIfNeeded(downloadIfNeeded: true)
            KokoroDiagnostics.log("settings", "prepare finished ready=\(ready)")
            await MainActor.run {
                kokoroModelPresent = speechManager.isKokoroModelDownloaded
                if !ready, speechManager.speechOutputBackend == backend {
                    speechManager.speechOutputBackend = .system
                }
            }
        }
    }

    private func deleteKokoroModel() {
        speechManager.deleteKokoroModel()
        kokoroModelPresent = speechManager.isKokoroModelDownloaded
    }

    private var speechOutputRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                rowIcon(systemImage: "waveform", tint: .pink)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Voice")
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    Menu {
                        ForEach(availableSpeechOutputBackends) { backend in
                            Button {
                                selectSpeechOutputBackend(backend)
                            } label: {
                                if backend == speechManager.speechOutputBackend {
                                    Label(backend.title, systemImage: "checkmark")
                                } else {
                                    Text(backend.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(speechManager.speechOutputBackend.title)
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 8)

                            if speechManager.isPreparingSpeechOutput {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .accessibilityHidden(true)
                            }
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(Color.pink.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(speechManager.isPreparingSpeechOutput)
                    .accessibilityLabel("Voice")
                    .accessibilityValue(speechManager.speechOutputBackend.title)

                    Text(speechOutputSubtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if speechManager.speechOutputBackend == .system && kokoroModelPresent && !speechManager.isPreparingSpeechOutput {
                Button(role: .destructive) {
                    deleteKokoroModel()
                } label: {
                    Text("Delete Kokoro Voice Model (~\(KokoroModelStore.approximateWeightsMegabytes) MB)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .padding(.leading, 48)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var speechOutputSubtitle: String {
        if speechManager.speechOutputDownloadProgress != nil {
            return String(localized: "Downloading…")
        }
        if speechManager.isPreparingSpeechOutput {
            return speechManager.speechBackendStatus
        }
        if !SpeechManager.isKokoroSupportedOnCurrentDevice {
            return String(localized: "Kokoro voices need an A14 or newer device.")
        }
        let backend = speechManager.speechOutputBackend
        if let voice = backend.kokoroVoice, !KokoroModelStore.isReady(for: voice) {
            return String(localized: "\(voice.displayName) needs a one-time ~\(KokoroModelStore.approximateWeightsMegabytes) MB download.")
        }
        return backend.subtitle
    }

    private func selectSpeechInputBackend(_ backend: SpeechInputBackend) {
        guard speechManager.speechInputBackend != backend else { return }
        if speechManager.isListening { speechManager.stopListening() }

        if backend == .whisper {
            speechManager.speechInputBackend = .whisper
            Task {
                let ok = await speechManager.prepareTranscriptionIfNeeded(downloadIfNeeded: true)
                await MainActor.run {
                    whisperModelPresent = speechManager.isWhisperModelDownloaded
                    if !ok { speechManager.speechInputBackend = .system }
                }
            }
        } else {
            speechManager.speechInputBackend = .system
            speechManager.unloadWhisper()
        }
    }

    private func deleteWhisperModel() {
        speechManager.speechInputBackend = .system
        speechManager.deleteWhisperModel()
        whisperModelPresent = speechManager.isWhisperModelDownloaded
    }

    // MARK: - Speech Input (Dictation)

    private var speechInputRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                rowIcon(systemImage: "mic.fill", tint: .red)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Dictation")
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    Menu {
                        ForEach(SpeechInputBackend.allCases) { backend in
                            Button {
                                selectSpeechInputBackend(backend)
                            } label: {
                                if backend == speechManager.speechInputBackend {
                                    Label(backend.title, systemImage: "checkmark")
                                } else {
                                    Text(backend.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(speechManager.speechInputBackend.title)
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 8)

                            if speechManager.isPreparingTranscription {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .accessibilityHidden(true)
                            }
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(speechManager.isPreparingTranscription)
                    .accessibilityLabel("Dictation Backend")
                    .accessibilityValue(speechManager.speechInputBackend.title)

                    Text(speechInputSubtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if speechManager.speechInputBackend == .system && whisperModelPresent && !speechManager.isPreparingTranscription {
                Button(role: .destructive) {
                    deleteWhisperModel()
                } label: {
                    Text("Delete Whisper Model (~145 MB)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .padding(.leading, 48)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var speechInputSubtitle: String {
        if speechManager.isPreparingTranscription {
            return String(localized: "Downloading the Whisper model…")
        }
        return speechManager.speechInputBackend.subtitle
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

            sectionDivider

            HStack(spacing: 14) {
                rowIcon(systemImage: "text.viewfinder", tint: .orange)

                VStack(alignment: .leading, spacing: 10) {
                    Text("OCR Engine")
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    Menu {
                        ForEach(DocumentOCRBackend.allCases) { backend in
                            Button {
                                documentOCRBackendRaw = backend.rawValue
                            } label: {
                                if backend == documentOCRBackend {
                                    Label(backend.title, systemImage: "checkmark")
                                } else {
                                    Text(backend.title)
                                }
                            }
                            .disabled(backend == .glmOCR && !isGLMOCRDownloaded)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(documentOCRBackend.title)
                                .font(.subheadline)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel("OCR Engine")
                    .accessibilityValue(documentOCRBackend.title)

                    Text(documentOCRBackend.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !isGLMOCRDownloaded {
                        NavigationLink {
                            ModelDownloadView()
                        } label: {
                            Label("Download GLM OCR in Models", systemImage: "arrow.down.circle")
                                .font(.footnote.weight(.semibold))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        advancedSection("Behavior") {
            speechOutputRow

            sectionDivider

            if SpeechManager.isWhisperEnabled {
                speechInputRow

                sectionDivider
            }

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
                            .foregroundStyle(messageTextScale == 1.0 ? Color.adaptive(white: 0.7) : .blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(messageTextScale == 1.0)
                    .frame(minHeight: 44)
                }

                HStack(spacing: 12) {
                    Image(systemName: "textformat.size.smaller")
                        .font(.caption)
                        .foregroundStyle(Color.adaptive(white: 0.5))

                    Slider(value: $messageTextScale, in: 0.8...1.3, step: 0.05)
                        .tint(.purple)

                    Image(systemName: "textformat.size.larger")
                        .font(.caption)
                        .foregroundStyle(Color.adaptive(white: 0.5))
                }

                // Preview bubble
                Text("This is how messages will look.")
                    .font(.system(size: messagePreviewBaseSize * messageTextScale))
                    .foregroundStyle(Color.adaptive(white: 0.3))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.adaptive(white: 0.96), in: RoundedRectangle(cornerRadius: 14))
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
            .background(Color.adaptiveCard, in: RoundedRectangle(cornerRadius: 16))
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
            .accessibilityHidden(true)

            Spacer(minLength: 8)

            Toggle(title, isOn: isOn)
                .labelsHidden()
                .tint(tint)
                .accessibilityHint(Text(subtitle))
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
            .accessibilityHidden(true)
    }

}

#Preview {
    NavigationStack {
        AdvancedSettingsView()
    }
}
