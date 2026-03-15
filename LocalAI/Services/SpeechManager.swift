//
//  SpeechManager.swift
//  LocalAI
//
//  Created by Tudor on 31.01.2026.
//

import Foundation
import Speech
import AVFoundation

@MainActor
@Observable
class SpeechManager: NSObject, SFSpeechRecognizerDelegate {
    var isListening = false
    var transcribedText = ""
    var lastFinalTranscription = ""
    var finalTranscriptionVersion = 0
    var isSpeaking = false
    var speechCompletionVersion = 0
    var showPermissionAlert = false
    var errorMessage: String?
    var errorVersion = 0
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var isRequestingPermissions = false
    
    // TTS
    private let synthesizer = AVSpeechSynthesizer()
    
    override init() {
        super.init()
        speechRecognizer?.delegate = self
        synthesizer.delegate = self
    }
    
    func startListening() throws {
        guard !isListening else { return }
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
        
        // Cancel existing task if any
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }
        
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        
        // Remove existing tap if any to prevent crash
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        
        guard let recognitionRequest = recognitionRequest else {
            publishError("Could not start speech recognition.")
            return
        }
        recognitionRequest.shouldReportPartialResults = true
        
        // IMPORTANT: Enforce on-device recognition for privacy
        if #available(iOS 13, *) {
            recognitionRequest.requiresOnDeviceRecognition = true
        }
        
        // Keep audio engine running even if silent
        
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
            
            if error != nil || isFinal {
                Task { @MainActor in
                    if let error {
                        let nsError = error as NSError
                        if nsError.domain != "kAFAssistantErrorDomain" || nsError.code != 216 {
                            self.publishError(error.localizedDescription)
                        }
                    }
                    self.stopListening()
                }
            }
        }
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer, when) in
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
    
    func stopListening() {
        guard isListening || recognitionTask != nil || recognitionRequest != nil else { return }
        audioEngine.stop()
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask = nil
        recognitionRequest = nil
        isListening = false
    }
    
    // MARK: - TTS
    
    func speak(_ text: String) {
        // Stop any current speech
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5
        
        synthesizer.speak(utterance)
        isSpeaking = true
    }
    
    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        speechCompletionVersion += 1
    }

    private func publishError(_ message: String) {
        errorMessage = message
        errorVersion += 1
    }
}

extension SpeechManager: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
        speechCompletionVersion += 1
        // Reset audio session category to play back
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        isSpeaking = true
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
        speechCompletionVersion += 1
    }
}
