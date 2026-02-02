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
    var isSpeaking = false
    var showPermissionAlert = false
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    // TTS
    private let synthesizer = AVSpeechSynthesizer()
    
    override init() {
        super.init()
        speechRecognizer?.delegate = self
        synthesizer.delegate = self
    }
    
    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }
    
    func startListening() throws {
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        
        if authStatus == .notDetermined || audioStatus == .notDetermined {
            requestPermissions()
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
            print("Unable to create request")
            return
        }
        recognitionRequest.shouldReportPartialResults = true
        
        // Keep audio engine running even if silent
        
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { result, error in
            var isFinal = false
            
            if let result = result {
                DispatchQueue.main.async {
                    self.transcribedText = result.bestTranscription.formattedString
                }
                isFinal = result.isFinal
            }
            
            if error != nil || isFinal {
                self.stopListening()
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
    }
    
    func stopListening() {
        audioEngine.stop()
        recognitionRequest?.endAudio()
        audioEngine.inputNode.removeTap(onBus: 0)
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
    }
}

extension SpeechManager: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
        // Reset audio session category to play back
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        isSpeaking = true
    }
}
