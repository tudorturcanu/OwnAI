//
//  SpeechManager.swift
//  LocalAI
//
//  Created by Tudor on 31.01.2026.
//

import AVFoundation
import Foundation
import QuartzCore
import Speech
import SwiftUI
import Observation
import Combine
import piper
import libespeak_ng
import WhisperKit

enum SpeechInputBackend: String, CaseIterable, Identifiable {
    case system
    case whisper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System (Apple)"
        case .whisper: return "Whisper"
        }
    }

    var subtitle: String {
        switch self {
        case .system: return "Built-in Apple dictation (English)"
        case .whisper: return "Local Whisper model (multilingual)"
        }
    }
}

enum SpeechOutputBackend: String, CaseIterable, Identifiable {
    case system
    case piperAmy
    case piperNorman

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System Voice"
        case .piperAmy: return "Amy"
        case .piperNorman: return "Norman"
        }
    }

    var subtitle: String {
        switch self {
        case .system: return "Built-in Apple speech"
        case .piperAmy: return "Local TTS (Amy - US Female)"
        case .piperNorman: return "Local TTS (Norman - US Male)"
        }
    }
}

/// Computes a 0...1 loudness level from mic buffers, rate-limited so the
/// UI-facing updates arrive at animation speed (~20 Hz) instead of buffer
/// speed (~50 Hz). Instances are owned by a single audio tap closure and are
/// only ever accessed from the audio render thread, so no locking is needed.
private final class AudioLevelThrottle: @unchecked Sendable {
    private var lastEmit: CFTimeInterval = 0

    /// Returns a level for this buffer, or nil when inside the throttle window.
    func throttledLevel(for buffer: AVAudioPCMBuffer) -> Double? {
        let now = CACurrentMediaTime()
        guard now - lastEmit >= 0.05 else { return nil }
        lastEmit = now

        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sumOfSquares: Float = 0
        let frameCount = Int(buffer.frameLength)
        // Stride so the cost stays flat regardless of buffer size.
        let step = max(1, frameCount / 256)
        var sampleCount = 0
        for index in stride(from: 0, to: frameCount, by: step) {
            let sample = samples[index]
            sumOfSquares += sample * sample
            sampleCount += 1
        }
        let rms = sqrt(sumOfSquares / Float(max(sampleCount, 1)))
        // Map RMS to decibels, then normalize a speech-friendly window
        // (-50 dB near-silence ... -8 dB loud) into 0...1.
        let decibels = 20 * log10(max(rms, .leastNonzeroMagnitude))
        let normalized = (Double(decibels) + 50) / 42
        return min(max(normalized, 0), 1)
    }
}

@MainActor
@Observable
final class SpeechManager: NSObject, SFSpeechRecognizerDelegate {
    nonisolated static var isKokoroSupportedOnCurrentDevice: Bool {
        false
    }

    var isListening = false
    /// Smoothed microphone input level in 0...1 while listening, for voice-mode
    /// visualizations. Derived from RMS power of the recognition tap buffers,
    /// so it costs nothing extra when nothing observes it.
    var inputAudioLevel: Double = 0
    var transcribedText = ""
    var lastFinalTranscription = ""
    var finalTranscriptionVersion = 0
    var isSpeaking = false
    var currentlySpeakingMessageID: UUID?
    var speechCompletionVersion = 0
    var showPermissionAlert = false
    var errorMessage: String?
    var errorVersion = 0
    var speechBackendStatus = "System voice is ready."
    var isPreparingSpeechOutput = false
    var isPreparingTranscription = false

    /// Hands-free endpointing: when true, listening finishes on its own after
    /// the user has said something and then pauses. Neither backend ends a
    /// turn by itself (on-device SFSpeech rarely emits a final result, and the
    /// Whisper stream runs until cancelled), so voice conversation mode turns
    /// this on and dictation into the text field leaves it off.
    @ObservationIgnored var autoStopAfterSilence = false
    @ObservationIgnored private var silenceWatchdog: Task<Void, Never>?
    /// Pause length that ends a turn. Long enough to survive mid-sentence
    /// breaths, short enough that the conversation doesn't feel stalled.
    private static let silenceEndpointInterval: TimeInterval = 1.2

    /// Whisper model variant to download/run. "base" balances accuracy and speed
    /// on phones (~145 MB Core ML download).
    nonisolated static let whisperModelName = "base"

    /// Feature flag: Whisper dictation is hidden for release until the slow
    /// (~1 min) model load is improved. Flip to `true` to re-enable the UI.
    nonisolated static let isWhisperEnabled = false

    @ObservationIgnored @AppStorage("speechInputBackend") private var persistedSpeechInputBackend = SpeechInputBackend.system.rawValue
    /// Optional ISO language code for Whisper (nil = auto-detect / multilingual).
    @ObservationIgnored @AppStorage("speechInputLanguage") private var speechInputLanguage = ""

    var speechInputBackend: SpeechInputBackend = .system {
        didSet { persistedSpeechInputBackend = speechInputBackend.rawValue }
    }

    private var whisperKit: WhisperKit?
    private var whisperTranscriber: AudioStreamTranscriber?
    private var whisperStreamTask: Task<Void, Never>?
    private var whisperLoadTask: Task<WhisperKit?, Never>?

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var isRequestingPermissions = false
    private var lastNoSpeechRestartAt: Date = .distantPast
    private var listeningRestartToken = UUID()

    private let synthesizer = AVSpeechSynthesizer()
    private var speechQueue: [String] = []
    private var isProcessingSpeechQueue = false
    private var speechQueueProcessingTask: Task<Void, Never>?
    private var speechQueueToken = UUID()

    private let ttsAudioEngine = AVAudioEngine()
    private let ttsPlayerNode = AVAudioPlayerNode()
    private var ttsGraphConfigured = false
    private var piperSynthesizer: OpaquePointer?
    private var piperSynthesisTask: Task<Void, Never>?
    private var piperLoadTask: Task<Void, Never>?

    @ObservationIgnored @AppStorage("speechOutputBackend") private var persistedSpeechOutputBackend = SpeechOutputBackend.system.rawValue

    var speechOutputBackend: SpeechOutputBackend = .system {
        didSet {
            persistedSpeechOutputBackend = speechOutputBackend.rawValue
            if oldValue != speechOutputBackend {
                releasePiper()
            }
            if speechOutputBackend == .system {
                speechBackendStatus = statusMessage(for: .system)
            }
        }
    }

    override init() {
        super.init()
        speechRecognizer?.delegate = self
        synthesizer.delegate = self

        if let savedInputBackend = SpeechInputBackend(rawValue: persistedSpeechInputBackend) {
            // If Whisper was previously selected but the feature is now hidden,
            // fall back to the system backend so dictation keeps working.
            speechInputBackend = (savedInputBackend == .whisper && !Self.isWhisperEnabled) ? .system : savedInputBackend
        }

        ttsAudioEngine.attach(ttsPlayerNode)
        // Note: the player -> mainMixer connection is deferred to playback time
        // (see configureTTSGraphIfNeeded). Connecting here, before the audio
        // session is active for playback, can lock the mixer -> output route to
        // a 0 Hz / 0 channel hardware format, producing silence with no error.

        if let savedBackend = SpeechOutputBackend(rawValue: persistedSpeechOutputBackend) {
            speechOutputBackend = savedBackend
            if savedBackend == .system {
                speechBackendStatus = statusMessage(for: .system)
            } else {
                // Preserve an existing user's choice, but do not synchronously
                // load ONNX weights during launch. Piper is prepared on first use.
                speechBackendStatus = "\(savedBackend.title) will prepare when first used."
            }
        } else {
            speechBackendStatus = statusMessage(for: .system)
        }
    }

    func startListening() throws {
        guard !isListening else { return }

        if speechInputBackend == .whisper {
            startWhisperListening()
            return
        }

        listeningRestartToken = UUID()
        guard speechRecognizer?.isAvailable == true else {
            publishError("Speech recognition is currently unavailable.")
            return
        }

        let authStatus = SFSpeechRecognizer.authorizationStatus()
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        if authStatus == .notDetermined || audioStatus == .notDetermined {
            guard !isRequestingPermissions else { return }
            isRequestingPermissions = true
            Task {
                let granted = await requestPermissionsIfNeeded()
                isRequestingPermissions = false

                if granted {
                    do {
                        try startListening()
                    } catch {
                        showPermissionAlert = true
                    }
                } else {
                    showPermissionAlert = true
                }
            }
            return
        }

        guard authStatus == .authorized && audioStatus == .authorized else {
            showPermissionAlert = true
            return
        }

        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }

        if autoStopAfterSilence {
            try activateBargeInCapableSession()
        } else {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        guard let recognitionRequest = recognitionRequest else {
            publishError("Could not start speech recognition.")
            return
        }
        recognitionRequest.shouldReportPartialResults = true

        if #available(iOS 13, *) {
            recognitionRequest.requiresOnDeviceRecognition = true
        }
        // Tune the recognizer for free-form conversational speech rather than
        // its default (short search-style phrases), and let it insert
        // punctuation. Both noticeably improve transcript quality and give the
        // model cleaner, better-segmented input than an unpunctuated run-on.
        recognitionRequest.taskHint = .dictation
        if #available(iOS 16.0, *) {
            recognitionRequest.addsPunctuation = true
        }

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            var isFinal = false

            if let result = result {
                Task { @MainActor in
                    let text = result.bestTranscription.formattedString
                    if text != self.transcribedText {
                        self.transcribedText = text
                        self.restartSilenceWatchdog()
                    }
                    if result.isFinal {
                        self.lastFinalTranscription = text
                        self.finalTranscriptionVersion += 1
                    }
                }
                isFinal = result.isFinal
            }

            if let error {
                if !isFinal, self.isNoSpeechDetectedError(error) {
                    let shouldRestart = self.isListening
                    let restartToken = self.listeningRestartToken
                    self.stopListening(false)
                    guard shouldRestart else { return }

                    let now = Date()
                    let cooldown: TimeInterval = 2.0
                    let delay = max(0, cooldown - now.timeIntervalSince(self.lastNoSpeechRestartAt))
                    self.lastNoSpeechRestartAt = now

                    Task { @MainActor in
                        let nanos = UInt64((delay == 0 ? 0.5 : delay) * 1_000_000_000)
                        if nanos > 0 {
                            try? await Task.sleep(nanoseconds: nanos)
                        }
                        guard self.listeningRestartToken == restartToken else { return }
                        do {
                            try self.startListening()
                        } catch let startError {
                            self.publishError(startError.localizedDescription)
                        }
                    }
                    return
                }

                Task { @MainActor in
                    if !self.isCancellationError(error) {
                        self.publishError(error.localizedDescription)
                    }
                    self.stopListening()
                }
            } else if isFinal {
                Task { @MainActor in
                    self.stopListening()
                }
            }
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        // Throttle state for the level meter lives in a box owned by the tap
        // closure; it is only ever touched from the audio render thread.
        let levelThrottle = AudioLevelThrottle()
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
            if let level = levelThrottle.throttledLevel(for: buffer) {
                Task { @MainActor [weak self] in
                    guard let self, self.isListening else { return }
                    // Light exponential smoothing so the visual doesn't flicker.
                    self.inputAudioLevel = self.inputAudioLevel * 0.6 + level * 0.4
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()

        isListening = true
        transcribedText = ""
        errorMessage = nil
    }

    private func requestPermissionsIfNeeded() async -> Bool {
        var speechStatus = SFSpeechRecognizer.authorizationStatus()
        var audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        if speechStatus == .notDetermined {
            speechStatus = await requestSpeechAuthorization()
        }

        if audioStatus == .notDetermined {
            let granted = await requestMicrophoneAuthorization()
            audioStatus = granted ? .authorized : .denied
        }

        return speechStatus == .authorized && audioStatus == .authorized
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Re-arms the pause timer after new transcription text. When it fires
    /// with the text unchanged, the user has stopped talking: finish the turn
    /// and publish the transcript so the conversation loop can send it.
    private func restartSilenceWatchdog() {
        silenceWatchdog?.cancel()
        silenceWatchdog = nil
        guard autoStopAfterSilence, isListening,
              !transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        silenceWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.silenceEndpointInterval * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isListening else { return }
            self.finishListeningAfterSilence()
        }
    }

    private func finishListeningAfterSilence() {
        // The Whisper path commits the transcript as part of stopping.
        if whisperTranscriber != nil || whisperStreamTask != nil {
            stopWhisperListening()
            return
        }
        // The SFSpeech path won't deliver a final result once the task is
        // cancelled, so commit the last partial ourselves.
        let final = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        stopListening()
        if !final.isEmpty {
            lastFinalTranscription = final
            finalTranscriptionVersion += 1
        }
    }

    func stopListening(_ invalidateRestartToken: Bool = true) {
        silenceWatchdog?.cancel()
        silenceWatchdog = nil
        if whisperTranscriber != nil || whisperStreamTask != nil {
            stopWhisperListening()
            return
        }
        guard isListening || recognitionTask != nil || recognitionRequest != nil else { return }
        audioEngine.stop()
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask = nil
        recognitionRequest = nil
        isListening = false
        inputAudioLevel = 0
        if invalidateRestartToken {
            listeningRestartToken = UUID()
        }
    }

    var pendingSpeechQueueCount: Int {
        speechQueue.count
    }

    var isSpeechQueueEmpty: Bool {
        speechQueue.isEmpty
    }

    private func isNoSpeechDetectedError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == 216 {
            return true
        }

        let lowercased = nsError.localizedDescription.lowercased()
        return lowercased.contains("no speech") ||
            lowercased.contains("no audio") ||
            lowercased.contains("didn't hear") ||
            lowercased.contains("didn't detect")
    }

    /// True when `error` merely reports that the recognition request was
    /// cancelled. We cancel deliberately every time listening stops — most
    /// visibly right after a voice message is sent — and the framework then
    /// reports that teardown back through the completion handler. It is never
    /// something the user needs to see, so it must not surface as an alert.
    /// Codes and domains differ across iOS versions and between the cloud and
    /// on-device (kLSR) recognizers, so match broadly.
    private func isCancellationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case ("kAFAssistantErrorDomain", 216),
             ("kAFAssistantErrorDomain", 1101),
             ("kAFAssistantErrorDomain", 1107),
             ("kAFAssistantErrorDomain", 1110),
             ("kLSRErrorDomain", 301):
            return true
        case (NSCocoaErrorDomain, NSUserCancelledError):
            return true
        default:
            return nsError.localizedDescription.lowercased().contains("cancel")
        }
    }

    func speak(_ text: String, messageID: UUID? = nil) {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return }
        stopSpeaking()
        currentlySpeakingMessageID = messageID
        if speechOutputBackend == .system {
            speakWithSystemVoice(cleanedText)
        } else if piperSynthesizer == nil {
            let requestedBackend = speechOutputBackend
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.prepareSpeechOutputIfNeeded()
                guard self.speechOutputBackend == requestedBackend else { return }
                if self.piperSynthesizer != nil {
                    self.speakWithPiper(cleanedText)
                } else {
                    self.speakWithSystemVoice(cleanedText)
                }
            }
        } else {
            speakWithPiper(cleanedText)
        }
    }

    func enqueueSpeak(_ text: String) {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return }

        speechQueue.append(cleanedText)
        guard !isProcessingSpeechQueue else { return }

        isProcessingSpeechQueue = true
        let token = speechQueueToken
        speechQueueProcessingTask = Task { @MainActor in
            await processSpeechQueue(token: token)
        }
    }

    func stopSpeaking() {
        speechQueueToken = UUID()
        speechQueue.removeAll()
        speechQueueProcessingTask?.cancel()
        speechQueueProcessingTask = nil
        isProcessingSpeechQueue = false

        let wasSpeaking = isSpeaking || synthesizer.isSpeaking || ttsPlayerNode.isPlaying
        
        synthesizer.stopSpeaking(at: .immediate)
        piperSynthesisTask?.cancel()
        piperSynthesisTask = nil
        ttsPlayerNode.stop()
        
        isSpeaking = false
        currentlySpeakingMessageID = nil
        if wasSpeaking {
            speechCompletionVersion += 1
        }
    }

    private func processSpeechQueue(token: UUID) async {
        while speechQueueToken == token {
            guard !speechQueue.isEmpty else { break }

            let nextChunk = speechQueue.removeFirst()
            let completionVersionBefore = speechCompletionVersion
            if speechOutputBackend == .system {
                speakWithSystemVoice(nextChunk)
            } else {
                await prepareSpeechOutputIfNeeded()
                if piperSynthesizer != nil {
                    speakWithPiper(nextChunk)
                } else {
                    speakWithSystemVoice(nextChunk)
                }
            }
            await waitForSpeechCompletion(since: completionVersionBefore, token: token)
        }

        isProcessingSpeechQueue = false
        speechQueueProcessingTask = nil
    }

    private func waitForSpeechCompletion(since version: Int, token: UUID) async {
        let deadline = Date().addingTimeInterval(120)
        while speechQueueToken == token,
              speechCompletionVersion == version,
              Date() < deadline,
              (isSpeaking || synthesizer.isSpeaking) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func prepareSpeechOutputIfNeeded() async {
        guard speechOutputBackend != .system else {
            speechBackendStatus = statusMessage(for: .system)
            return
        }
        guard piperSynthesizer == nil else { return }
        if let piperLoadTask {
            await piperLoadTask.value
            return
        }

        let backend = speechOutputBackend
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadPiper(backend: backend)
        }
        piperLoadTask = task
        await task.value
        piperLoadTask = nil
    }

    func unloadKokoro() {
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        guard phase != .active else { return }
        stopSpeaking()
        if isListening { stopListening() }
        releaseAudioSessionIfIdle()
    }

    /// Puts the shared session into simultaneous record+playback with the
    /// system's built-in echo cancellation, so the mic can stay open while
    /// the assistant is talking: real "talk over it to interrupt" barge-in,
    /// instead of a strict listen-then-speak-then-listen turn every time.
    /// `.voiceChat` activates OS-level acoustic echo cancellation for the
    /// whole session — the same primitive VoIP apps use — which is what
    /// keeps the recognizer from hearing the device's own TTS output as if
    /// the user had spoken, even though `audioEngine` (recording) and
    /// `ttsAudioEngine` (Piper playback) are separate engine instances: the
    /// cancellation happens at the session/hardware level, not per-engine.
    /// Used only while hands-free Voice Conversation mode
    /// (`autoStopAfterSilence`) is active; the single-shot "tap mic, dictate
    /// one message" flow keeps the simpler, mutually exclusive
    /// `.record`/`.playback` categories, which is lower-risk when nothing
    /// needs to overlap.
    private func activateBargeInCapableSession() throws {
        let session = AVAudioSession.sharedInstance()
        // Skip reconfiguring a session that's already in the right
        // category/mode - most calls land here while TTS is already
        // rendering on it (that's the point of barge-in), and re-issuing
        // setCategory/setActive while another engine is actively playing
        // risks an audible glitch for no benefit.
        guard session.category != .playAndRecord || session.mode != .voiceChat else { return }
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.duckOthers, .allowBluetooth, .defaultToSpeaker]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// Deactivates the shared audio session once nothing is recording or
    /// playing. The Piper playback path and the listening path both leave the
    /// session active (with `.duckOthers`), so without this other apps' audio
    /// stays ducked after a voice session ends.
    func releaseAudioSessionIfIdle() {
        guard !isListening, !isSpeaking, !synthesizer.isSpeaking else { return }
        if ttsAudioEngine.isRunning {
            ttsAudioEngine.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Whisper (Speech-to-Text)

    /// swift-transformers HubApi lays Whisper Core ML models out under
    /// <downloadBase>/models/argmaxinc/whisperkit-coreml/openai_whisper-<variant>.
    nonisolated private static var whisperDownloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("whisperkit", isDirectory: true)
    }

    nonisolated private static var whisperModelFolder: URL {
        whisperDownloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(whisperModelName)", isDirectory: true)
    }

    nonisolated var isWhisperModelDownloaded: Bool {
        FileManager.default.fileExists(atPath: Self.whisperModelFolder.path)
    }

    /// Loads (and optionally downloads) the Whisper model. Returns true on success.
    @discardableResult
    func prepareTranscriptionIfNeeded(downloadIfNeeded: Bool) async -> Bool {
        if whisperKit != nil {
            return true
        }
        if !downloadIfNeeded && !isWhisperModelDownloaded {
            return false
        }

        if let whisperLoadTask {
            whisperKit = await whisperLoadTask.value
            return whisperKit != nil
        }

        isPreparingTranscription = true
        let base = Self.whisperDownloadBase
        let modelName = Self.whisperModelName
        let task = Task { () -> WhisperKit? in
            do {
                try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                // `load: true` is required: WhisperKit's init only calls
                // loadModels() when `load == true` (or modelFolder is set).
                // Without it the instance is created but the model/tokenizer
                // are never loaded (modelState stays .unloaded, tokenizer nil).
                let config = WhisperKitConfig(
                    model: modelName,
                    downloadBase: base,
                    load: true,
                    download: true
                )
                let kit = try await WhisperKit(config)
                return kit
            } catch {
                return nil
            }
        }
        whisperLoadTask = task
        let loaded = await task.value
        whisperLoadTask = nil
        whisperKit = loaded
        isPreparingTranscription = false
        return loaded != nil
    }

    func unloadWhisper() {
        whisperLoadTask?.cancel()
        whisperLoadTask = nil
        whisperStreamTask?.cancel()
        whisperStreamTask = nil
        whisperTranscriber = nil
        whisperKit = nil
        isPreparingTranscription = false
    }

    /// Releases optional speech models before interactive text chat. Voice
    /// Conversation preserves them because speech is part of that foreground
    /// interaction rather than background work.
    func prioritizeInteractiveChat(preserveVoiceFeatures: Bool) {
        guard !preserveVoiceFeatures else { return }
        stopSpeaking()
        if isListening {
            stopListening()
        }
        unloadWhisper()
        releasePiper()
        isPreparingSpeechOutput = false
    }

    func deleteWhisperModel() {
        unloadWhisper()
        try? FileManager.default.removeItem(at: Self.whisperDownloadBase)
    }

    private func startWhisperListening() {
        listeningRestartToken = UUID()
        Task {
            let granted = await requestMicrophoneAuthorization()
            guard granted else {
                showPermissionAlert = true
                return
            }

            guard await prepareTranscriptionIfNeeded(downloadIfNeeded: false) else {
                publishError("Download the Whisper model in Settings to use it.")
                return
            }
            guard let whisperKit else {
                publishError("Whisper model is not ready.")
                return
            }
            guard let tokenizer = whisperKit.tokenizer else {
                publishError("Whisper model is not ready.")
                return
            }

            stopSpeaking()

            var options = DecodingOptions()
            options.task = .transcribe
            let trimmedLanguage = speechInputLanguage.trimmingCharacters(in: .whitespaces)
            options.language = trimmedLanguage.isEmpty ? nil : trimmedLanguage
            options.usePrefillPrompt = !(options.language == nil)

            let transcriber = AudioStreamTranscriber(
                audioEncoder: whisperKit.audioEncoder,
                featureExtractor: whisperKit.featureExtractor,
                segmentSeeker: whisperKit.segmentSeeker,
                textDecoder: whisperKit.textDecoder,
                tokenizer: tokenizer,
                audioProcessor: whisperKit.audioProcessor,
                decodingOptions: options,
                stateChangeCallback: { [weak self] _, newState in
                    Task { @MainActor in
                        self?.handleWhisperState(newState)
                    }
                }
            )
            whisperTranscriber = transcriber
            isListening = true
            transcribedText = ""
            errorMessage = nil

            whisperStreamTask = Task {
                do {
                    try await transcriber.startStreamTranscription()
                } catch {
                    if !(error is CancellationError) && !self.isCancellationError(error) {
                        await MainActor.run {
                            self.publishError(error.localizedDescription)
                            self.stopWhisperListening()
                        }
                    }
                }
            }
        }
    }

    private func handleWhisperState(_ state: AudioStreamTranscriber.State) {
        var text = state.confirmedSegments.map(\.text).joined(separator: " ")
        if !state.currentText.isEmpty {
            text += (text.isEmpty ? "" : " ") + state.currentText
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != transcribedText {
            transcribedText = trimmed
            restartSilenceWatchdog()
        }
    }

    private func stopWhisperListening() {
        silenceWatchdog?.cancel()
        silenceWatchdog = nil
        whisperStreamTask?.cancel()
        whisperStreamTask = nil

        if let transcriber = whisperTranscriber {
            Task { await transcriber.stopStreamTranscription() }
        }
        whisperTranscriber = nil

        let final = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !final.isEmpty {
            lastFinalTranscription = final
            finalTranscriptionVersion += 1
        }
        isListening = false
        listeningRestartToken = UUID()
    }

    // MARK: - Piper Integration

    private func getPiperModelPaths(for backend: SpeechOutputBackend) -> (model: String, config: String)? {
        let modelName: String
        switch backend {
        case .piperAmy:
            modelName = "en_US-amy-medium.onnx"
        case .piperNorman:
            modelName = "en_US-norman-medium.onnx"
        default:
            return nil
        }
        
        if let path = Bundle.main.path(forResource: modelName, ofType: nil) ?? 
                      Bundle.main.path(forResource: (modelName as NSString).deletingPathExtension, ofType: (modelName as NSString).pathExtension) {
            return (path, path + ".json")
        }
        
        if let path = Bundle.main.path(forResource: modelName, ofType: nil, inDirectory: "PiperAudioFiles") {
            return (path, path + ".json")
        }
        
        // Also check if we have a direct path within the app bundle by searching
        if let resourcePath = Bundle.main.resourcePath {
            let url = URL(fileURLWithPath: resourcePath).appendingPathComponent("PiperAudioFiles/\(modelName)")
            if FileManager.default.fileExists(atPath: url.path) {
                return (url.path, url.path + ".json")
            }
        }
        
        return nil
    }
    
    private func loadPiper(backend: SpeechOutputBackend) async {
        guard let paths = getPiperModelPaths(for: backend) else {
            publishError("Could not find Piper model files for \(backend.title)")
            return
        }
        
        guard let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            publishError("Could not access Documents directory for espeak-ng data")
            return
        }
        
        do {
            try ensureEspeakDataInstalled(inRoot: docsURL)
        } catch {
            publishError("Failed to install espeak-ng data: \(error.localizedDescription)")
            return
        }
        
        let espeakDataPath = docsURL.path
        isPreparingSpeechOutput = true
        speechBackendStatus = "Preparing \(backend.title)…"
        let modelPath = paths.model
        let configPath = paths.config
        let pointerAddress = await Task.detached(priority: .userInitiated) {
            piper_create(modelPath, configPath, espeakDataPath).map { UInt(bitPattern: $0) }
        }.value
        isPreparingSpeechOutput = false

        guard speechOutputBackend == backend else {
            if let pointerAddress, let synth = OpaquePointer(bitPattern: pointerAddress) {
                piper_free(synth)
            }
            return
        }
        guard let pointerAddress, let synth = OpaquePointer(bitPattern: pointerAddress) else {
            publishError("Failed to initialize Piper synthesizer")
            return
        }
        piperSynthesizer = synth
        speechBackendStatus = statusMessage(for: backend)
    }

    private func releasePiper() {
        piperLoadTask?.cancel()
        piperLoadTask = nil
        piperSynthesisTask?.cancel()
        piperSynthesisTask = nil
        if let synth = piperSynthesizer {
            piper_free(synth)
            piperSynthesizer = nil
        }
    }

    private func ensureEspeakDataInstalled(inRoot rootURL: URL) throws {
        let dataURL = rootURL.appendingPathComponent("espeak-ng-data", isDirectory: true)
        let requiredFiles = [
            "en_dict",
            "phondata",
            "phonindex",
            "phontab"
        ]
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: dataURL.path) {
            let hasRequiredFiles = requiredFiles.allSatisfy { fileName in
                fileManager.fileExists(atPath: dataURL.appendingPathComponent(fileName).path)
            }
            if !hasRequiredFiles {
                try? fileManager.removeItem(at: dataURL)
            }
        }

        try EspeakLib.ensureBundleInstalled(inRoot: rootURL)

        let missingFiles = requiredFiles.filter { fileName in
            !fileManager.fileExists(atPath: dataURL.appendingPathComponent(fileName).path)
        }
        guard missingFiles.isEmpty else {
            throw NSError(
                domain: "SpeechManager",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Missing compiled espeak-ng files: \(missingFiles.joined(separator: ", "))"]
            )
        }
    }
    
    private func configureAndStartTTSEngine() throws {
        if !ttsGraphConfigured {
            // 22050 Hz mono matches the Piper voice models; the mixer handles
            // sample-rate conversion to whatever the active output route uses.
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1) else {
                throw NSError(domain: "SpeechManager", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not create TTS audio format"])
            }
            ttsAudioEngine.connect(ttsPlayerNode, to: ttsAudioEngine.mainMixerNode, format: format)
            ttsGraphConfigured = true
        }

        if !ttsAudioEngine.isRunning {
            ttsAudioEngine.prepare()
            try ttsAudioEngine.start()
        }
    }

    private func speakWithPiper(_ text: String) {
        guard let synth = piperSynthesizer else {
            publishError("Piper synthesizer not loaded")
            return
        }
        
        do {
            if autoStopAfterSilence {
                try activateBargeInCapableSession()
            } else {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.duckOthers])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            }
        } catch {
            publishError("Failed to activate audio for playback: \(error.localizedDescription)")
            return
        }

        // Connect and start the engine now that the playback route is active so
        // the mixer -> output connection picks up the real hardware format.
        do {
            try configureAndStartTTSEngine()
        } catch {
            publishError("Audio engine failed to start: \(error.localizedDescription)")
            return
        }

        isSpeaking = true
        ttsPlayerNode.play()
        
        piperSynthesisTask?.cancel()
        
        piperSynthesisTask = Task.detached { [weak self] in
            let options = piper_default_synthesize_options(synth)
            var mutableOptions = options
            
            let startResult = text.withCString { cString in
                piper_synthesize_start(synth, cString, &mutableOptions)
            }
            
            guard startResult == PIPER_OK else {
                await MainActor.run {
                    self?.publishError("Failed to start Piper synthesis")
                    self?.stopSpeaking()
                }
                return
            }
            
            var chunk = piper_audio_chunk()
            var scheduledFinal = false
            while !Task.isCancelled {
                let nextResult = piper_synthesize_next(synth, &chunk)
                if nextResult == PIPER_DONE { break }
                if nextResult != PIPER_OK {
                    await MainActor.run {
                        self?.publishError("Error during Piper synthesis")
                    }
                    break
                }

                let numSamples = Int(chunk.num_samples)
                guard numSamples > 0 else {
                    if chunk.is_last { break }
                    continue
                }
                
                guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(chunk.sample_rate), channels: 1) else {
                    continue
                }
                
                guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else {
                    continue
                }
                pcmBuffer.frameLength = AVAudioFrameCount(numSamples)
                if let channelData = pcmBuffer.floatChannelData?[0] {
                    for i in 0..<numSamples {
                        channelData[i] = chunk.samples[i]
                    }
                }
                
                let isLast = chunk.is_last
                if isLast { scheduledFinal = true }
                await MainActor.run {
                    self?.ttsPlayerNode.scheduleBuffer(pcmBuffer, at: nil, options: []) {
                        if isLast {
                            Task { @MainActor in
                                guard let self = self else { return }
                                self.isSpeaking = false
                                self.currentlySpeakingMessageID = nil
                                self.speechCompletionVersion += 1
                            }
                        }
                    }
                }

                if isLast { break }
            }

            // If synthesis ended without a non-empty final chunk (empty last
            // chunk, or PIPER_DONE before any is_last), no scheduleBuffer
            // completion will fire. Reset state directly so playback isn't left
            // "speaking" forever and the speech queue can advance.
            if !scheduledFinal && !Task.isCancelled {
                await MainActor.run {
                    guard let self = self else { return }
                    self.isSpeaking = false
                    self.currentlySpeakingMessageID = nil
                    self.speechCompletionVersion += 1
                }
            }
        }
    }

    private func speakWithSystemVoice(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        do {
            if autoStopAfterSilence {
                try activateBargeInCapableSession()
            } else {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.duckOthers])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            }
        } catch {
            publishError("Failed to activate audio for playback: \(error.localizedDescription)")
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5

        synthesizer.speak(utterance)
        speechBackendStatus = statusMessage(for: .system)
        isSpeaking = true
    }

    private func publishError(_ message: String) {
        errorMessage = message
        errorVersion += 1
    }

    private func statusMessage(for backend: SpeechOutputBackend) -> String {
        switch backend {
        case .system:
            return "System voice is ready."
        case .piperAmy, .piperNorman:
            return "\(backend.title) is ready."
        }
    }
}

extension SpeechManager: @preconcurrency AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
        currentlySpeakingMessageID = nil
        speechCompletionVersion += 1
        // In barge-in mode the mic may still be listening on the same shared
        // session; tearing it down here would cut that off. Let
        // releaseAudioSessionIfIdle() (gated on isListening) decide instead.
        guard !autoStopAfterSilence else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        isSpeaking = true
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
        currentlySpeakingMessageID = nil
        speechCompletionVersion += 1
    }
}
