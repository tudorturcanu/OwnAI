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

enum SpeechOutputBackend: String, CaseIterable, Identifiable {
    case system

    var id: String { rawValue }

    var title: String {
        "System Voice"
    }

    var subtitle: String {
        "Built-in Apple speech"
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

    @ObservationIgnored @AppStorage("speechOutputBackend") private var persistedSpeechOutputBackend = SpeechOutputBackend.system.rawValue

    var speechOutputBackend: SpeechOutputBackend = .system {
        didSet {
            speechOutputBackend = .system
            persistedSpeechOutputBackend = SpeechOutputBackend.system.rawValue
            speechBackendStatus = statusMessage(for: .system)
        }
    }

    override init() {
        super.init()
        speechRecognizer?.delegate = self
        synthesizer.delegate = self
        speechBackendStatus = statusMessage(for: .system)
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
        speakWithSystemVoice(cleanedText)
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

        let wasSpeaking = isSpeaking || synthesizer.isSpeaking
        synthesizer.stopSpeaking(at: .immediate)
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
            speakWithSystemVoice(nextChunk)
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
        speechBackendStatus = statusMessage(for: .system)
    }

    func unloadKokoro() {
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        guard phase != .active else { return }
        stopSpeaking()
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
