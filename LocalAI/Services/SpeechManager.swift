//
//  SpeechManager.swift
//  LocalAI
//
//  Created by Tudor on 31.01.2026.
//

import AVFoundation
import Foundation
import Speech
import SwiftUI
import Observation
import Combine
import piper
import libespeak_ng

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

@MainActor
@Observable
final class SpeechManager: NSObject, SFSpeechRecognizerDelegate {
    nonisolated static var isKokoroSupportedOnCurrentDevice: Bool {
        false
    }

    var isListening = false
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
    private var piperSynthesizer: OpaquePointer?
    private var piperSynthesisTask: Task<Void, Never>?

    @ObservationIgnored @AppStorage("speechOutputBackend") private var persistedSpeechOutputBackend = SpeechOutputBackend.piperAmy.rawValue

    var speechOutputBackend: SpeechOutputBackend = .piperAmy {
        didSet {
            persistedSpeechOutputBackend = speechOutputBackend.rawValue
            if speechOutputBackend != .system {
                loadPiper(backend: speechOutputBackend)
            } else {
                speechBackendStatus = statusMessage(for: .system)
            }
        }
    }

    override init() {
        super.init()
        speechRecognizer?.delegate = self
        synthesizer.delegate = self
        
        ttsAudioEngine.attach(ttsPlayerNode)
        let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)
        ttsAudioEngine.connect(ttsPlayerNode, to: ttsAudioEngine.mainMixerNode, format: format)
        
        if let savedBackend = SpeechOutputBackend(rawValue: persistedSpeechOutputBackend) {
            speechOutputBackend = savedBackend
            if savedBackend != .system {
                loadPiper(backend: savedBackend)
            } else {
                speechBackendStatus = statusMessage(for: .system)
            }
        } else {
            speechBackendStatus = statusMessage(for: .system)
        }
    }

    func startListening() throws {
        guard !isListening else { return }
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

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

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

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { result, error in
            var isFinal = false

            if let result = result {
                Task { @MainActor in
                    self.transcribedText = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.lastFinalTranscription = result.bestTranscription.formattedString
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
                    let nsError = error as NSError
                    if nsError.domain != "kAFAssistantErrorDomain" || nsError.code != 216 {
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
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
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

    func stopListening(_ invalidateRestartToken: Bool = true) {
        guard isListening || recognitionTask != nil || recognitionRequest != nil else { return }
        audioEngine.stop()
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask = nil
        recognitionRequest = nil
        isListening = false
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

    func speak(_ text: String, messageID: UUID? = nil) {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return }
        stopSpeaking()
        currentlySpeakingMessageID = messageID
        if speechOutputBackend == .system {
            speakWithSystemVoice(cleanedText)
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
                speakWithPiper(nextChunk)
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
        if speechOutputBackend != .system && piperSynthesizer == nil {
            loadPiper(backend: speechOutputBackend)
        } else if speechOutputBackend == .system {
            speechBackendStatus = statusMessage(for: .system)
        }
    }

    func unloadKokoro() {
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        guard phase != .active else { return }
        stopSpeaking()
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
    
    private func loadPiper(backend: SpeechOutputBackend) {
        if let synth = piperSynthesizer {
            piper_free(synth)
            piperSynthesizer = nil
        }
        
        guard let paths = getPiperModelPaths(for: backend) else {
            publishError("Could not find Piper model files for \(backend.title)")
            return
        }
        
        guard let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            publishError("Could not access Documents directory for espeak-ng data")
            return
        }
        
        do {
            try EspeakLib.ensureBundleInstalled(inRoot: docsURL)
        } catch {
            publishError("Failed to install espeak-ng data: \(error.localizedDescription)")
            return
        }
        
        let espeakDataPath = docsURL.path
        
        let synth = piper_create(paths.model, paths.config, espeakDataPath)
        if synth == nil {
            publishError("Failed to initialize Piper synthesizer")
        } else {
            piperSynthesizer = synth
            speechBackendStatus = statusMessage(for: backend)
        }
    }
    
    private func speakWithPiper(_ text: String) {
        guard let synth = piperSynthesizer else {
            publishError("Piper synthesizer not loaded")
            return
        }
        
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to set audio session active for playback: \(error.localizedDescription)")
        }
        
        if !ttsAudioEngine.isRunning {
            try? ttsAudioEngine.start()
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
                
                let format = AVAudioFormat(standardFormatWithSampleRate: Double(chunk.sample_rate), channels: 1)!
                
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
        }
    }

    private func speakWithSystemVoice(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
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
