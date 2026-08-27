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

enum SpeechOutputBackend: Hashable, Identifiable, Sendable {
    case system
    case kokoro(KokoroVoice)

    static var allCases: [SpeechOutputBackend] {
        [.system] + KokoroVoice.allCases.map { .kokoro($0) }
    }

    var id: String { rawValue }

    var rawValue: String {
        switch self {
        case .system: return "system"
        case .kokoro(let voice): return "kokoro:\(voice.rawValue)"
        }
    }

    init?(rawValue: String) {
        if rawValue == "system" {
            self = .system
            return
        }
        let prefix = "kokoro:"
        guard rawValue.hasPrefix(prefix),
              let voice = KokoroVoice(rawValue: String(rawValue.dropFirst(prefix.count))) else {
            return nil
        }
        self = .kokoro(voice)
    }

    var kokoroVoice: KokoroVoice? {
        if case .kokoro(let voice) = self { return voice }
        return nil
    }

    var title: String {
        switch self {
        case .system: return String(localized: "System Voice")
        case .kokoro(let voice): return voice.displayName
        }
    }

    var subtitle: String {
        switch self {
        case .system: return String(localized: "Built-in Apple speech")
        case .kokoro(let voice): return "Kokoro · \(voice.subtitle)"
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
    /// Kokoro runs on MLX, so it inherits the same A14+/GPU-family gate as
    /// the chat models and is compiled out on the simulator.
    nonisolated static var isKokoroSupportedOnCurrentDevice: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return DeviceResourcePolicy.supportsMLXCompute
        #endif
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
    var speechBackendStatus = String(localized: "System voice is ready.")
    var isPreparingSpeechOutput = false
    /// 0...1 while the Kokoro weights/voice are downloading, nil otherwise.
    var speechOutputDownloadProgress: Double?
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

    /// Feature flag: the hands-free full-screen voice conversation is hidden
    /// for release until the listen/speak turn-taking loop is better tested.
    /// Dictation and Speak/Read Aloud are unaffected. Flip to `true` to
    /// re-enable the entry points.
    nonisolated static let isVoiceConversationEnabled = false

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
    private var kokoroSynthesizer: KokoroSynthesizer?
    private var kokoroLoadTask: Task<Bool, Never>?
    private var kokoroSynthesisTask: Task<Void, Never>?
    /// Bumped on every stop/release so in-flight synthesis results from an
    /// earlier utterance are discarded instead of scheduled.
    private var kokoroPlaybackGeneration = UUID()
    /// Frees the ~330 MB of Kokoro weights after a quiet spell, mirroring
    /// LLMEngine's idle unload. Re-armed after every utterance; the next
    /// Speak pays the load + warm-up again (shown as "Preparing voice…").
    private var kokoroIdleUnloadTask: Task<Void, Never>?
    private static let kokoroIdleUnloadInterval: TimeInterval = 600

    @ObservationIgnored @AppStorage("speechOutputBackend") private var persistedSpeechOutputBackend = SpeechOutputBackend.system.rawValue

    var speechOutputBackend: SpeechOutputBackend = .system {
        didSet {
            persistedSpeechOutputBackend = speechOutputBackend.rawValue
            guard oldValue != speechOutputBackend else { return }
            if speechOutputBackend == .system {
                // Free the ~330 MB of weights as soon as they're not wanted.
                releaseKokoro()
                speechBackendStatus = statusMessage(for: .system)
            } else {
                speechBackendStatus = String(localized: "\(speechOutputBackend.title) will prepare when first used.")
            }
        }
    }

    @ObservationIgnored @AppStorage("speechRate") private var persistedSpeechRate = UserPersonalityPreset.defaultSpeechRate

    /// Speech-rate multiplier applied to both Kokoro (`speed`) and the system
    /// voice. Personalities set it; 1.0 is the voice's natural pace.
    var speechRate: Double = UserPersonalityPreset.defaultSpeechRate {
        didSet {
            // Assigning inside didSet doesn't re-trigger the observer, so the
            // clamp is applied in place and then persisted once.
            let clamped = min(max(speechRate, UserPersonalityPreset.speechRateRange.lowerBound),
                              UserPersonalityPreset.speechRateRange.upperBound)
            if clamped != speechRate {
                speechRate = clamped
            }
            persistedSpeechRate = speechRate
        }
    }

    /// The Kokoro voice to synthesize with, or nil when the system voice is
    /// selected or this device can't run MLX.
    private var activeKokoroVoice: KokoroVoice? {
        guard Self.isKokoroSupportedOnCurrentDevice else { return nil }
        return speechOutputBackend.kokoroVoice
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
        // The player -> mainMixer connection is deferred to playback time
        // (see configureAndStartTTSEngine). Connecting here, before the audio
        // session is active for playback, can lock the mixer -> output route to
        // a 0 Hz / 0 channel hardware format, producing silence with no error.

        // Property observers don't fire inside init, so the status is set
        // explicitly. Kokoro weights are never loaded during launch; the
        // saved voice is prepared on first use.
        if let savedBackend = SpeechOutputBackend(rawValue: persistedSpeechOutputBackend),
           savedBackend == .system || Self.isKokoroSupportedOnCurrentDevice {
            speechOutputBackend = savedBackend
        }
        speechRate = min(max(persistedSpeechRate, UserPersonalityPreset.speechRateRange.lowerBound),
                         UserPersonalityPreset.speechRateRange.upperBound)
        speechBackendStatus = speechOutputBackend == .system
            ? statusMessage(for: .system)
            : String(localized: "\(speechOutputBackend.title) will prepare when first used.")

        installAudioObservers()
    }

    /// Kokoro plays through `ttsAudioEngine`, which iOS stops on an audio
    /// route/configuration change (headphones, Bluetooth, the voice-mode
    /// switch to `.playAndRecord`) or an interruption (phone call, Siri).
    /// `AVSpeechSynthesizer` reports those through its delegate, but a
    /// stopped engine just never plays the final buffer — so `isSpeaking`
    /// would stay true forever and the voice-conversation loop would never
    /// re-arm the microphone. Resume when we can, otherwise end the
    /// utterance cleanly.
    private func installAudioObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: ttsAudioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTTSEngineConfigurationChange()
            }
        }
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = rawType.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            Task { @MainActor [weak self] in
                self?.handleAudioSessionInterruption(type)
            }
        }
    }

    private var isKokoroPlaybackActive: Bool {
        isSpeaking && kokoroSynthesizer != nil && (kokoroSynthesisTask != nil || ttsGraphConfigured)
            && !synthesizer.isSpeaking
    }

    private func handleTTSEngineConfigurationChange() {
        guard isKokoroPlaybackActive else { return }
        // Scheduled buffers survive an engine stop; restarting the engine and
        // the player resumes them on the new route.
        do {
            if !ttsAudioEngine.isRunning {
                ttsAudioEngine.prepare()
                try ttsAudioEngine.start()
            }
            ttsPlayerNode.play()
            KokoroDiagnostics.log("speak", "audio configuration changed — playback resumed")
        } catch {
            KokoroDiagnostics.log("speak", "audio configuration changed — could not resume (\(error)); ending utterance")
            stopSpeaking()
        }
    }

    private func handleAudioSessionInterruption(_ type: AVAudioSession.InterruptionType?) {
        guard type == .began, isKokoroPlaybackActive else { return }
        // There is no meaningful "resume mid-sentence" after a phone call;
        // end the utterance so the UI and the voice loop move on.
        KokoroDiagnostics.log("speak", "audio session interrupted — ending utterance")
        stopSpeaking()
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
        KokoroDiagnostics.log(
            "speak()",
            "backend=\(speechOutputBackend.rawValue) supported=\(Self.isKokoroSupportedOnCurrentDevice) loaded=\(kokoroSynthesizer != nil) chars=\(cleanedText.count)"
        )
        guard let voice = activeKokoroVoice else {
            KokoroDiagnostics.log("speak()", "→ system voice")
            speakWithSystemVoice(cleanedText)
            return
        }
        if kokoroSynthesizer != nil {
            speakWithKokoro(cleanedText, voice: voice)
            return
        }
        KokoroDiagnostics.log("speak()", "→ preparing \(voice.rawValue) first")
        // Weights aren't loaded yet: prepare (no download from here — that
        // is Settings' job), then speak with whatever is available. The
        // utterance counts as "speaking" from this moment so the UI flips to
        // its stop state (with a "Preparing voice…" hint) instead of looking
        // like the tap was ignored while the weights load.
        isSpeaking = true
        let generation = kokoroPlaybackGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ready = await self.prepareSpeechOutputIfNeeded(downloadIfNeeded: false)
            // A stop (or a new utterance) in the meantime already reset state.
            guard self.kokoroPlaybackGeneration == generation else { return }
            if ready, self.kokoroSynthesizer != nil, self.speechOutputBackend.kokoroVoice == voice {
                self.speakWithKokoro(cleanedText, voice: voice)
            } else {
                self.speakWithSystemVoice(cleanedText)
            }
        }
    }

    /// Loads the selected Kokoro voice ahead of time (never downloads) so the
    /// first reply doesn't pay the multi-second weight load. Call it when
    /// speech is about to be needed — entering voice mode, or opening a chat
    /// with auto-read on — not on every launch, since it costs ~330 MB.
    func prewarmSpeechOutputIfNeeded() {
        guard let voice = activeKokoroVoice,
              kokoroSynthesizer == nil,
              kokoroLoadTask == nil,
              KokoroModelStore.isReady(for: voice) else { return }
        Task { @MainActor [weak self] in
            await self?.prepareSpeechOutputIfNeeded(downloadIfNeeded: false)
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
        kokoroPlaybackGeneration = UUID()
        kokoroSynthesisTask?.cancel()
        kokoroSynthesisTask = nil
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
            if let voice = activeKokoroVoice {
                let ready = await prepareSpeechOutputIfNeeded(downloadIfNeeded: false)
                guard speechQueueToken == token else { break }
                if ready, kokoroSynthesizer != nil {
                    speakWithKokoro(nextChunk, voice: voice)
                } else {
                    speakWithSystemVoice(nextChunk)
                }
            } else {
                speakWithSystemVoice(nextChunk)
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

    /// Loads the Kokoro engine for the selected voice, downloading the weights
    /// and/or voice tensor first when `downloadIfNeeded` is set. Returns true
    /// when the synthesizer is ready. Concurrent callers share one load.
    @discardableResult
    func prepareSpeechOutputIfNeeded(downloadIfNeeded: Bool) async -> Bool {
        KokoroDiagnostics.log(
            "prepareIfNeeded",
            "backend=\(speechOutputBackend.rawValue) downloadIfNeeded=\(downloadIfNeeded) loaded=\(kokoroSynthesizer != nil) loadInFlight=\(kokoroLoadTask != nil)"
        )
        guard let voice = activeKokoroVoice else {
            KokoroDiagnostics.log("prepareIfNeeded", "no active Kokoro voice (system selected or device unsupported)")
            if speechOutputBackend == .system {
                speechBackendStatus = statusMessage(for: .system)
            }
            return false
        }
        if kokoroSynthesizer != nil, KokoroModelStore.isVoiceDownloaded(voice) {
            KokoroDiagnostics.log("prepareIfNeeded", "already loaded")
            return true
        }
        if let kokoroLoadTask {
            KokoroDiagnostics.log("prepareIfNeeded", "joining in-flight load")
            return await kokoroLoadTask.value
        }
        if !downloadIfNeeded, !KokoroModelStore.isReady(for: voice) {
            KokoroDiagnostics.log(
                "prepareIfNeeded",
                "not downloaded (weights=\(KokoroModelStore.isWeightsDownloaded) voice=\(KokoroModelStore.isVoiceDownloaded(voice))) and download not allowed here"
            )
            speechBackendStatus = String(localized: "Download \(voice.displayName) in Settings to use it.")
            return false
        }

        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            return await self.loadKokoro(voice: voice, downloadIfNeeded: downloadIfNeeded)
        }
        kokoroLoadTask = task
        let ready = await task.value
        kokoroLoadTask = nil
        return ready
    }

    func unloadKokoro() {
        releaseKokoro()
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
    /// `AVSpeechSynthesizer` (playback) are separate: the cancellation
    /// happens at the session/hardware level, not per-engine.
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
    /// playing. Both the speaking and listening paths leave the session
    /// active (with `.duckOthers`), so without this other apps' audio stays
    /// ducked after a voice session ends.
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
        releaseKokoro()
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

    // MARK: - Kokoro (Text-to-Speech)

    nonisolated var isKokoroModelDownloaded: Bool {
        KokoroModelStore.isWeightsDownloaded
    }

    private func loadKokoro(voice: KokoroVoice, downloadIfNeeded: Bool) async -> Bool {
        KokoroDiagnostics.log("prepare", "voice=\(voice.rawValue) ready=\(KokoroModelStore.isReady(for: voice)) downloadIfNeeded=\(downloadIfNeeded) loaded=\(kokoroSynthesizer != nil)"
        )
        isPreparingSpeechOutput = true
        defer {
            isPreparingSpeechOutput = false
            speechOutputDownloadProgress = nil
        }

        if !KokoroModelStore.isReady(for: voice) {
            guard downloadIfNeeded else { return false }
            speechBackendStatus = String(localized: "Downloading \(voice.displayName)…")
            speechOutputDownloadProgress = 0
            do {
                try await KokoroModelStore.download(voice: voice) { fraction in
                    Task { @MainActor [weak self] in
                        self?.speechOutputDownloadProgress = fraction
                    }
                }
            } catch is CancellationError {
                KokoroDiagnostics.log("prepare", "download cancelled")
                return false
            } catch {
                KokoroDiagnostics.log("prepare", "download FAILED: \(error)")
                publishError(String(localized: "Could not download \(voice.displayName): \(error.localizedDescription)"))
                speechBackendStatus = statusMessage(for: .system)
                return false
            }
        }

        // The user may have switched voices (or back to the system voice)
        // while the download ran.
        guard speechOutputBackend.kokoroVoice == voice else { return false }

        if kokoroSynthesizer == nil {
            // Loading under Xcode's Metal API Validation would crash the app
            // inside the first MLX gather; fail visibly instead.
            if KokoroDiagnostics.isMetalValidationEnabled {
                KokoroDiagnostics.log("prepare", "REFUSED: \(KokoroDiagnostics.metalValidationMessage) [\(KokoroDiagnostics.metalEnvironmentSummary)]")
                publishError(KokoroDiagnostics.metalValidationMessage)
                speechBackendStatus = statusMessage(for: .system)
                return false
            }
            speechBackendStatus = String(localized: "Preparing \(voice.displayName)…")
            let weightsURL = KokoroModelStore.weightsURL
            let synthesizer = await Task.detached(priority: .userInitiated) {
                KokoroSynthesizer(weightsURL: weightsURL)
            }.value
            guard speechOutputBackend.kokoroVoice == voice else { return false }
            // The first generateAudio call also compiles the MLX graph; doing
            // it on a throwaway phrase moves that cost into "Preparing…".
            await synthesizer.warmUp(voice: voice)
            guard speechOutputBackend.kokoroVoice == voice else { return false }
            kokoroSynthesizer = synthesizer
        }
        speechBackendStatus = statusMessage(for: .kokoro(voice))
        KokoroDiagnostics.log("prepare", "READY voice=\(voice.rawValue)")
        return true
    }

    private func releaseKokoro() {
        if kokoroSynthesizer != nil || kokoroLoadTask != nil {
            KokoroDiagnostics.log("release", "loaded=\(kokoroSynthesizer != nil) loadInFlight=\(kokoroLoadTask != nil)")
        }
        kokoroLoadTask?.cancel()
        kokoroLoadTask = nil
        kokoroIdleUnloadTask?.cancel()
        kokoroIdleUnloadTask = nil
        kokoroPlaybackGeneration = UUID()
        kokoroSynthesisTask?.cancel()
        kokoroSynthesisTask = nil
        kokoroSynthesizer = nil
        isPreparingSpeechOutput = false
        speechOutputDownloadProgress = nil
    }

    func deleteKokoroModel() {
        releaseKokoro()
        if speechOutputBackend != .system {
            speechOutputBackend = .system
        }
        KokoroModelStore.deleteAll()
    }

    private func configureAndStartTTSEngine() throws {
        if !ttsGraphConfigured {
            // 24 kHz mono matches Kokoro's output; the mixer converts to
            // whatever the active output route uses.
            guard let format = AVAudioFormat(standardFormatWithSampleRate: KokoroSynthesizer.sampleRate, channels: 1) else {
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

    /// Synthesizes `text` sentence by sentence on a background task and
    /// streams each chunk into the player as soon as it's ready, so the
    /// first words play while later sentences are still being generated.
    private func speakWithKokoro(_ text: String, voice: KokoroVoice) {
        guard let synthesizer = kokoroSynthesizer else {
            speakWithSystemVoice(text)
            return
        }
        let chunks = SpeechTextPreparer.chunks(SpeechTextPreparer.clean(text))
        KokoroDiagnostics.log("speak", "voice=\(voice.rawValue) chars=\(text.count) chunks=\(chunks.count) first=\(chunks.first?.count ?? 0) chars"
        )
        guard !chunks.isEmpty else {
            finishKokoroPlayback()
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
            try configureAndStartTTSEngine()
        } catch {
            KokoroDiagnostics.log("speak", "audio session/engine FAILED: \(error)")
            publishError(String(localized: "Audio playback failed: \(error.localizedDescription)"))
            speakWithSystemVoice(text)
            return
        }

        isSpeaking = true
        ttsPlayerNode.play()
        kokoroIdleUnloadTask?.cancel()
        kokoroIdleUnloadTask = nil
        let generation = kokoroPlaybackGeneration
        let utteranceStart = CACurrentMediaTime()
        let speed = speechRate

        kokoroSynthesisTask?.cancel()
        kokoroSynthesisTask = Task.detached(priority: .userInitiated) { [weak self] in
            var scheduled = 0
            for chunk in chunks {
                if Task.isCancelled { return }
                let samples: [Float]
                do {
                    samples = try await synthesizer.synthesize(chunk, voice: voice, speed: speed)
                } catch KokoroError.textTooLong {
                    // Chunks are sized well under the limit; skip the rare
                    // outlier rather than abort the whole reply.
                    continue
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, self.kokoroPlaybackGeneration == generation else { return }
                        self.publishError(error.localizedDescription)
                        self.finishKokoroPlayback()
                    }
                    return
                }
                if Task.isCancelled { return }
                guard let buffer = Self.makePCMBuffer(samples: samples) else { continue }
                scheduled += 1
                if scheduled == 1 {
                    KokoroDiagnostics.log("speak", "first audio scheduled after \(KokoroDiagnostics.millis(since: utteranceStart)) ms")
                }
                await MainActor.run { [weak self] in
                    guard let self, self.kokoroPlaybackGeneration == generation else { return }
                    self.ttsPlayerNode.scheduleBuffer(buffer, at: nil, options: [])
                }
            }
            if Task.isCancelled { return }
            KokoroDiagnostics.log("speak", "all \(scheduled)/\(chunks.count) chunks scheduled in \(KokoroDiagnostics.millis(since: utteranceStart)) ms")

            // A short silent tail is the single "last" buffer: its
            // played-back callback ends the utterance no matter how many of
            // the chunks above were skipped.
            let tail = Self.makePCMBuffer(samples: [Float](repeating: 0, count: Int(KokoroSynthesizer.sampleRate / 20)))
            await MainActor.run { [weak self] in
                guard let self, self.kokoroPlaybackGeneration == generation else { return }
                guard let tail else {
                    self.finishKokoroPlayback()
                    return
                }
                self.ttsPlayerNode.scheduleBuffer(tail, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.kokoroPlaybackGeneration == generation else { return }
                        self.finishKokoroPlayback()
                    }
                }
            }
        }
    }

    private func finishKokoroPlayback() {
        KokoroDiagnostics.log("speak", "playback finished")
        isSpeaking = false
        currentlySpeakingMessageID = nil
        speechCompletionVersion += 1
        scheduleKokoroIdleUnload()
    }

    private func scheduleKokoroIdleUnload() {
        kokoroIdleUnloadTask?.cancel()
        kokoroIdleUnloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.kokoroIdleUnloadInterval * 1_000_000_000))
            guard !Task.isCancelled, let self, self.kokoroSynthesizer != nil else { return }
            // Still mid-utterance or queueing more speech: try again later.
            guard !self.isSpeaking, self.speechQueue.isEmpty else {
                self.scheduleKokoroIdleUnload()
                return
            }
            KokoroDiagnostics.log("release", "idle for \(Int(Self.kokoroIdleUnloadInterval)) s — unloading weights")
            self.releaseKokoro()
            if let voice = self.speechOutputBackend.kokoroVoice {
                self.speechBackendStatus = String(localized: "\(voice.displayName) will prepare when next used.")
            }
        }
    }

    nonisolated private static func makePCMBuffer(samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: KokoroSynthesizer.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
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
        // 0.5 is AVSpeechUtteranceDefaultSpeechRate; scale it by the same
        // multiplier Kokoro uses so a personality's pace carries across voices.
        utterance.rate = Float(0.5 * speechRate)

        synthesizer.speak(utterance)
        isSpeaking = true
    }

    private func statusMessage(for backend: SpeechOutputBackend) -> String {
        switch backend {
        case .system:
            return String(localized: "System voice is ready.")
        case .kokoro(let voice):
            return String(localized: "\(voice.displayName) is ready.")
        }
    }

    private func publishError(_ message: String) {
        errorMessage = message
        errorVersion += 1
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
