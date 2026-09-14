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
    @AppStorage(WebSearchEngine.storageKey) private var webSearchEngineRaw = WebSearchEngine.google.rawValue
    @State private var showReplyStylePromptResetConfirmation = false
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
    @State private var showGLMOCRConsentSheet = false

    private var pdfOCRMode: PDFOCRMode {
        PDFOCRMode(rawValue: pdfOCRModeRaw) ?? .preferNativeText
    }

    private var documentOCRBackend: DocumentOCRBackend {
        DocumentOCRBackend(rawValue: documentOCRBackendRaw) ?? .appleVision
    }

    private var isGLMOCRDownloaded: Bool {
        glmOCRModel?.downloadState.isDownloaded == true
    }

    /// The live catalog entry, so the control below tracks real download
    /// progress rather than the static `ModelInfo.glmOCR_4bit` template.
    private var glmOCRModel: ModelInfo? {
        modelManager.models.first(where: { $0.id == ModelInfo.glmOCR_4bit.id })
    }

    private var glmOCRConsentKey: String {
        "modelConsent.\(ModelInfo.glmOCR_4bit.id)"
    }

    /// Downloads GLM OCR in place. This used to be a NavigationLink into the
    /// full Models screen, which dropped the user somewhere they then had to
    /// find the model themselves and navigate back from.
    @ViewBuilder
    private var glmOCRDownloadControl: some View {
        let model = glmOCRModel ?? ModelInfo.glmOCR_4bit

        switch model.downloadState {
        case .downloading(let progress, _), .validating(let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.brandAccent)

                HStack(spacing: 8) {
                    Text(String(
                        format: String(localized: "Downloading GLM OCR — %lld%%"),
                        Int64((progress * 100).rounded())
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                    Spacer(minLength: 8)

                    Button(String(localized: "Cancel")) {
                        modelManager.cancelDownload(model.id)
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.brandAccent)
                }
            }
            .accessibilityElement(children: .combine)

        case .error(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    startGLMOCRDownload()
                } label: {
                    Label(String(localized: "Try Again"), systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.brandAccent)
                .frame(minHeight: 44)
            }

        default:
            Button {
                startGLMOCRDownload()
            } label: {
                Label(
                    String(
                        format: String(localized: "Download GLM OCR · %@"),
                        glmOCRSizeText
                    ),
                    systemImage: "arrow.down.circle"
                )
                .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.brandAccent)
            .frame(minHeight: 44)
        }
    }

    private var glmOCRSizeText: String {
        let bytes = Int64(ModelInfo.glmOCR_4bit.sizeGB * 1_000_000_000)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func startGLMOCRDownload() {
        guard UserDefaults.standard.bool(forKey: glmOCRConsentKey) else {
            showGLMOCRConsentSheet = true
            return
        }
        modelManager.downloadModel(ModelInfo.glmOCR_4bit.id)
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
            .readableContentWidth()
        }
        .background(Color.adaptiveGroupedBackground.ignoresSafeArea())
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .cellularRestrictionAlert()
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
        .alert(
            String(localized: "Reset custom instructions?"),
            isPresented: $showReplyStylePromptResetConfirmation
        ) {
            Button(String(localized: "Reset"), role: .destructive) {
                systemPrompt = AIResponseDefaults.defaultSystemPrompt
            }
            Button(String(localized: "Keep Mine"), role: .cancel) {}
        } message: {
            Text(String(localized: "Reply styles work best with the standard instructions. Resetting replaces the AI instructions you wrote."))
        }
        // GLM OCR ships with model terms, so the in-place download clears the
        // same consent gate the Models screen uses before it starts.
        .sheet(isPresented: $showGLMOCRConsentSheet) {
            ModelConsentSheet(model: glmOCRModel ?? ModelInfo.glmOCR_4bit) {
                UserDefaults.standard.set(true, forKey: glmOCRConsentKey)
                showGLMOCRConsentSheet = false
                modelManager.downloadModel(ModelInfo.glmOCR_4bit.id)
            } onCancel: {
                showGLMOCRConsentSheet = false
            }
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
        advancedPickerRow(
            icon: "waveform",
            tint: .brandAccentDeep,
            title: "Voice",
            subtitle: Text(speechOutputSubtitle)
        ) {
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
                pickerMenuLabel(
                    speechManager.speechOutputBackend.title,
                    tint: .brandAccentDeep,
                    isBusy: speechManager.isPreparingSpeechOutput
                )
            }
            .disabled(speechManager.isPreparingSpeechOutput)
            .accessibilityLabel("Voice")
            .accessibilityValue(speechManager.speechOutputBackend.title)
        } footer: {
            if speechManager.speechOutputBackend == .system && kokoroModelPresent && !speechManager.isPreparingSpeechOutput {
                Button(role: .destructive) {
                    deleteKokoroModel()
                } label: {
                    Text("Delete Kokoro Voice Model (~\(KokoroModelStore.approximateWeightsMegabytes) MB)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
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
        advancedPickerRow(
            icon: "mic.fill",
            tint: .red,
            title: "Dictation",
            subtitle: Text(speechInputSubtitle)
        ) {
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
                pickerMenuLabel(
                    speechManager.speechInputBackend.title,
                    tint: .red,
                    isBusy: speechManager.isPreparingTranscription
                )
            }
            .disabled(speechManager.isPreparingTranscription)
            .accessibilityLabel("Dictation Backend")
            .accessibilityValue(speechManager.speechInputBackend.title)
        } footer: {
            if speechManager.speechInputBackend == .system && whisperModelPresent && !speechManager.isPreparingTranscription {
                Button(role: .destructive) {
                    deleteWhisperModel()
                } label: {
                    Text("Delete Whisper Model (~145 MB)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
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
            advancedPickerRow(
                icon: "doc.text.magnifyingglass",
                tint: .brandAccent,
                title: "Document Processing",
                subtitle: Text(documentProcessingMode.subtitle)
            ) {
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
                    pickerMenuLabel(documentProcessingMode.title, tint: .brandAccent)
                }
                .accessibilityLabel("Document Processing")
                .accessibilityValue(documentProcessingMode.title)
            }

            sectionDivider

            advancedPickerRow(
                icon: "photo.on.rectangle.angled",
                tint: .brandAccentDeep,
                title: "Image Processing",
                subtitle: Text(imageProcessingMode.subtitle)
            ) {
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
                    pickerMenuLabel(imageProcessingMode.title, tint: .brandAccentDeep)
                }
                .accessibilityLabel("Image Processing")
                .accessibilityValue(imageProcessingMode.title)
            }

            sectionDivider

            advancedPickerRow(
                icon: "doc.text.viewfinder",
                tint: .brandAccent,
                title: "PDF OCR Mode",
                subtitle: Text(pdfOCRMode.subtitle)
            ) {
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
                    pickerMenuLabel(pdfOCRMode.title, tint: .brandAccent)
                }
                .accessibilityLabel("PDF OCR Mode")
                .accessibilityValue(pdfOCRMode.title)
            }

            sectionDivider

            advancedPickerRow(
                icon: "text.viewfinder",
                tint: .brandAccent,
                title: "OCR Engine",
                subtitle: Text(documentOCRBackend.subtitle)
            ) {
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
                    pickerMenuLabel(documentOCRBackend.title, tint: .brandAccent)
                }
                .accessibilityLabel("OCR Engine")
                .accessibilityValue(documentOCRBackend.title)
            } footer: {
                if !isGLMOCRDownloaded {
                    glmOCRDownloadControl
                }
            }
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
                tint: .brandAccent,
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

            webSearchRow

            sectionDivider

            advancedToggleRow(
                icon: "curlybraces",
                tint: .brandAccentDeep,
                title: "Reply Style",
                subtitle: "Show quick options under replies",
                isOn: $smartReplyStylesEnabled
            )
            .onChange(of: smartReplyStylesEnabled) {
                // Reply styles assume the stock prompt. Ask before discarding
                // instructions the user wrote; a silent reset behind an
                // innocuous-looking toggle was a nasty surprise.
                guard systemPrompt != AIResponseDefaults.defaultSystemPrompt else { return }
                showReplyStylePromptResetConfirmation = true
            }
        }
    }

    private var webSearchEngine: WebSearchEngine {
        WebSearchEngine(rawValue: webSearchEngineRaw) ?? .google
    }

    /// The only action in the app that leaves the device, so which site it
    /// goes to is the user's call rather than a hardcoded Google URL.
    private var webSearchRow: some View {
        advancedPickerRow(
            icon: "globe",
            tint: .brandAccent,
            title: "Web Search",
            subtitle: Text("Used by \"Search on Web\" in a message's menu. Nothing leaves the device until you tap it.")
        ) {
            Menu {
                ForEach(WebSearchEngine.allCases) { engine in
                    Button {
                        webSearchEngineRaw = engine.rawValue
                    } label: {
                        if engine == webSearchEngine {
                            Label(engine.title, systemImage: "checkmark")
                        } else {
                            Text(engine.title)
                        }
                    }
                }
            } label: {
                pickerMenuLabel(webSearchEngine.title, tint: .brandAccent)
            }
            .accessibilityLabel(Text("Web Search"))
            .accessibilityValue(Text(webSearchEngine.title))
        }
    }

    // MARK: - Text Size

    private var textSizeSection: some View {
        advancedSection("Display") {
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    rowIcon(systemImage: "textformat.size", tint: .brandAccentDeep)

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
                            .foregroundStyle(messageTextScale == 1.0 ? Color.adaptive(white: 0.7) : .brandAccent)
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
                        .tint(.brandAccentDeep)

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
        CardDivider(leadingInset: 62)
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
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.brandHairline, lineWidth: AppDesign.hairlineWidth))
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

    /// A row with a menu-style control. The icon sits beside the title and the
    /// control, description and any footer hang under the title, so the icon
    /// reads as part of the row instead of floating halfway down a tall stack.
    private func advancedPickerRow<Control: View, Footer: View>(
        icon: String,
        tint: Color,
        title: LocalizedStringKey,
        subtitle: Text,
        @ViewBuilder control: () -> Control,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            rowIcon(systemImage: icon, tint: tint)

            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .frame(minHeight: rowIconSize, alignment: .leading)

                control()

                subtitle
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                footer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func advancedPickerRow<Control: View>(
        icon: String,
        tint: Color,
        title: LocalizedStringKey,
        subtitle: Text,
        @ViewBuilder control: () -> Control
    ) -> some View {
        advancedPickerRow(icon: icon, tint: tint, title: title, subtitle: subtitle, control: control) {
            EmptyView()
        }
    }

    private func pickerMenuLabel(_ title: String, tint: Color, isBusy: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if isBusy {
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
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private let rowIconSize: CGFloat = 34

    private func rowIcon(systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: rowIconSize, height: rowIconSize)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
    }

}

#Preview {
    NavigationStack {
        AdvancedSettingsView()
    }
}
