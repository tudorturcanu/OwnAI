//
//  KokoroSpeechEngine.swift
//  LocalAIKit
//
//  Created by Codex on 18.03.2026.
//

import Foundation

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

public struct KokoroSpeechAudio {
    public let segments: [[Float]]
    public let interSegmentSilenceSampleCount: Int
    public let sampleRate: Double
    
    public init(segments: [[Float]], interSegmentSilenceSampleCount: Int, sampleRate: Double) {
        self.segments = segments
        self.interSegmentSilenceSampleCount = interSegmentSilenceSampleCount
        self.sampleRate = sampleRate
    }
}

#if !targetEnvironment(simulator)
import KokoroSwift
import MLX
import MLXUtilsLibrary

public actor KokoroSpeechEngine {
    private enum Asset: CaseIterable {
        case model
        case voices

        var fileName: String {
            switch self {
            case .model:
                return "kokoro-v1_0.safetensors"
            case .voices:
                return "voices.npz"
            }
        }

        var remoteURL: URL {
            switch self {
            case .model:
                return URL(string: "https://huggingface.co/mlx-community/Kokoro-82M-bf16/resolve/main/kokoro-v1_0.safetensors")!
            case .voices:
                return URL(string: "https://raw.githubusercontent.com/mlalma/KokoroTestApp/main/Resources/voices.npz")!
            }
        }

        var minimumExpectedBytes: Int64 {
            switch self {
            case .model:
                return 300_000_000
            case .voices:
                return 10_000_000
            }
        }
    }

    private let fileManager = FileManager.default
    private var tts: KokoroTTS?
    private var voices: [String: MLXArray] = [:]
    private var sortedVoiceNames: [String] = []
    private var loadedVoiceName: String?

    public init() {}

    public func unload() {
        log("unload")
        tts = nil
        voices.removeAll()
        sortedVoiceNames.removeAll()
        loadedVoiceName = nil
    }

    public func prepareIfNeeded(preferredVoiceName: String?) async throws {
        let startedAt = Date()
        try await Self.ensureForegroundExecution()
        // If we already have a TTS instance and the requested voice is loaded, skip.
        if let tts, !voices.isEmpty {
            if preferredVoiceName == nil {
                log("prepare skipped reason=cached-default elapsed=\(Self.format(Date().timeIntervalSince(startedAt)))s")
                return
            }
            if let loadedVoiceName, preferredVoiceName == loadedVoiceName {
                log("prepare skipped reason=cached-voice voice=\(loadedVoiceName) elapsed=\(Self.format(Date().timeIntervalSince(startedAt)))s")
                return
            }
        }

        let assetDirectory = try assetDirectoryURL()
        try fileManager.createDirectory(at: assetDirectory, withIntermediateDirectories: true)

        for asset in Asset.allCases {
            let destination = assetDirectory.appendingPathComponent(asset.fileName)
            if !fileManager.fileExists(atPath: destination.path) {
                log("asset missing file=\(asset.fileName) downloading")
                try await downloadAsset(asset, to: destination)
            } else {
                log("asset ready file=\(asset.fileName)")
            }
        }

        let modelURL = assetDirectory.appendingPathComponent(Asset.model.fileName)
        let voicesURL = assetDirectory.appendingPathComponent(Asset.voices.fileName)
        let loadedVoices = NpyzReader.read(fileFromPath: voicesURL) ?? [:]

        guard !loadedVoices.isEmpty else {
            throw NSError(
                domain: "KokoroSpeechEngine",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Kokoro voices could not be loaded."]
            )
        }

        sortedVoiceNames = loadedVoices.keys
            .map { String($0.split(separator: ".")[0]) }
            .sorted()

        let voiceNameToUse: String
        if let preferredVoiceName, sortedVoiceNames.contains(preferredVoiceName) {
            voiceNameToUse = preferredVoiceName
        } else if sortedVoiceNames.contains("af_bella") {
            voiceNameToUse = "af_bella"
        } else if let first = sortedVoiceNames.first {
            voiceNameToUse = first
        } else {
            throw NSError(
                domain: "KokoroSpeechEngine",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "No Kokoro voices are available."]
            )
        }

        if self.tts == nil {
            let modelInitStartedAt = Date()
            tts = KokoroTTS(modelPath: modelURL)
            log("tts initialized elapsed=\(Self.format(Date().timeIntervalSince(modelInitStartedAt)))s")
        }

        loadedVoiceName = voiceNameToUse
        let voiceKey = "\(voiceNameToUse).npy"
        guard let voiceEmbedding = loadedVoices[voiceKey] else {
            throw NSError(
                domain: "KokoroSpeechEngine",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "The selected Kokoro voice is unavailable."]
            )
        }
        voices = [voiceKey: voiceEmbedding]
        log("prepare finished voice=\(voiceNameToUse) voiceCount=\(sortedVoiceNames.count) elapsed=\(Self.format(Date().timeIntervalSince(startedAt)))s")
    }

    public func defaultVoiceName() async throws -> String {
        try await prepareIfNeeded(preferredVoiceName: nil)
        guard let loadedVoiceName else {
            throw NSError(
                domain: "KokoroSpeechEngine",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Kokoro default voice couldn't be determined."]
            )
        }
        return loadedVoiceName
    }

    public func synthesize(text: String, preferredVoiceName: String?) async throws -> KokoroSpeechAudio {
        let startedAt = Date()
        try await Self.ensureForegroundExecution()
        try await prepareIfNeeded(preferredVoiceName: preferredVoiceName)

        guard let tts else {
            throw NSError(
                domain: "KokoroSpeechEngine",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Kokoro is not ready yet."]
            )
        }

        guard let selectedVoiceName = loadedVoiceName else {
            throw NSError(
                domain: "KokoroSpeechEngine",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Kokoro voice wasn't loaded."]
            )
        }
        guard let voice = voices["\(selectedVoiceName).npy"] else {
            throw NSError(
                domain: "KokoroSpeechEngine",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "The selected Kokoro voice is unavailable."]
            )
        }

        let language: Language = selectedVoiceName.hasPrefix("b") ? .enGB : .enUS
        let chunks = chunked(text: text)
        log("synthesize start chars=\(text.count) chunks=\(chunks.count) voice=\(selectedVoiceName)")
        let silenceSampleCount = Int(KokoroTTS.Constants.samplingRate) / 8
        var segments: [[Float]] = []
        segments.reserveCapacity(chunks.count)

        for (index, chunk) in chunks.enumerated() {
            try await Self.ensureForegroundExecution()
            let chunkStartedAt = Date()
            let samples = try autoreleasepool {
                let (s, _) = try tts.generateAudio(
                    voice: voice,
                    language: language,
                    text: chunk,
                    speed: 1.0
                )
                return s
            }
            segments.append(samples)
            log("chunk finished index=\(index + 1)/\(chunks.count) chars=\(chunk.count) samples=\(samples.count) elapsed=\(Self.format(Date().timeIntervalSince(chunkStartedAt)))s")
        }

        let totalSamples = segments.reduce(0) { $0 + $1.count }
        log("synthesize finished chars=\(text.count) chunks=\(chunks.count) totalSamples=\(totalSamples) elapsed=\(Self.format(Date().timeIntervalSince(startedAt)))s")
        return KokoroSpeechAudio(
            segments: segments,
            interSegmentSilenceSampleCount: silenceSampleCount,
            sampleRate: Double(KokoroTTS.Constants.samplingRate)
        )
    }

    public func synthesizeStreaming(
        text: String,
        preferredVoiceName: String?,
        onChunk: @escaping @Sendable (KokoroSpeechAudio) async throws -> Void
    ) async throws {
        let startedAt = Date()
        try await Self.ensureForegroundExecution()
        try await prepareIfNeeded(preferredVoiceName: preferredVoiceName)

        guard let tts else {
            throw NSError(
                domain: "KokoroSpeechEngine",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Kokoro is not ready yet."]
            )
        }

        guard let selectedVoiceName = loadedVoiceName else {
            throw NSError(
                domain: "KokoroSpeechEngine",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Kokoro voice wasn't loaded."]
            )
        }
        guard let voice = voices["\(selectedVoiceName).npy"] else {
            throw NSError(
                domain: "KokoroSpeechEngine",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "The selected Kokoro voice is unavailable."]
            )
        }

        let language: Language = selectedVoiceName.hasPrefix("b") ? .enGB : .enUS
        let chunks = chunked(text: text)
        log("streaming synth start chars=\(text.count) chunks=\(chunks.count) voice=\(selectedVoiceName)")
        let silenceSampleCount = Int(KokoroTTS.Constants.samplingRate) / 8

        for (index, chunk) in chunks.enumerated() {
            try await Self.ensureForegroundExecution()
            let chunkStartedAt = Date()
            let samples = try autoreleasepool {
                let (s, _) = try tts.generateAudio(
                    voice: voice,
                    language: language,
                    text: chunk,
                    speed: 1.0
                )
                return s
            }
            let isLastChunk = index == chunks.count - 1
            log("streaming chunk finished index=\(index + 1)/\(chunks.count) chars=\(chunk.count) samples=\(samples.count) elapsed=\(Self.format(Date().timeIntervalSince(chunkStartedAt)))s")
            try await onChunk(
                KokoroSpeechAudio(
                    segments: [samples],
                    interSegmentSilenceSampleCount: isLastChunk ? 0 : silenceSampleCount,
                    sampleRate: Double(KokoroTTS.Constants.samplingRate)
                )
            )
        }

        log("streaming synth finished chars=\(text.count) chunks=\(chunks.count) elapsed=\(Self.format(Date().timeIntervalSince(startedAt)))s")
    }

    private func assetDirectoryURL() throws -> URL {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return baseURL.appendingPathComponent("Kokoro", isDirectory: true)
    }

    private func downloadAsset(_ asset: Asset, to destination: URL) async throws {
        let startedAt = Date()
        let (temporaryURL, response) = try await URLSession.shared.download(from: asset.remoteURL)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw NSError(
                domain: "KokoroSpeechEngine",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Kokoro download failed for \(asset.fileName)."]
            )
        }

        let attributes = try fileManager.attributesOfItem(atPath: temporaryURL.path)
        let size = attributes[.size] as? Int64 ?? 0
        guard size >= asset.minimumExpectedBytes else {
            throw NSError(
                domain: "KokoroSpeechEngine",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Downloaded Kokoro asset is incomplete: \(asset.fileName)."]
            )
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        log("asset downloaded file=\(asset.fileName) bytes=\(size) elapsed=\(Self.format(Date().timeIntervalSince(startedAt)))s")
    }

    private func chunked(text: String) -> [String] {
        let cleaned = text
            .replacingOccurrences(of: "\n\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        let maxChunkLength = 260
        let separators = CharacterSet(charactersIn: ".!?\n")
        let sentences = cleaned
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !sentences.isEmpty else {
            return stride(from: 0, to: cleaned.count, by: maxChunkLength).map { start in
                let startIndex = cleaned.index(cleaned.startIndex, offsetBy: start)
                let endIndex = cleaned.index(startIndex, offsetBy: min(maxChunkLength, cleaned.distance(from: startIndex, to: cleaned.endIndex)), limitedBy: cleaned.endIndex) ?? cleaned.endIndex
                return String(cleaned[startIndex..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        var chunks: [String] = []
        var current = ""

        for sentence in sentences {
            if current.isEmpty {
                current = sentence
                continue
            }

            let candidate = current + ". " + sentence
            if candidate.count <= maxChunkLength {
                current = candidate
            } else {
                chunks.append(current)
                current = sentence
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    private func log(_ message: String) {
        print("[KokoroSpeechEngine] \(message)")
    }

    private static func ensureForegroundExecution() async throws {
#if canImport(UIKit) && !os(watchOS)
        let isActive = await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        guard isActive else {
            throw CancellationError()
        }
#endif
    }

    private static func format(_ interval: TimeInterval) -> String {
        String(format: "%.3f", interval)
    }
}
#else
public actor KokoroSpeechEngine {
    public init() {}
    public func unload() {}
    public func prepareIfNeeded(preferredVoiceName: String?) async throws {}
    public func defaultVoiceName() async throws -> String { "" }
    public func synthesize(text: String, preferredVoiceName: String?) async throws -> KokoroSpeechAudio {
        KokoroSpeechAudio(segments: [], interSegmentSilenceSampleCount: 0, sampleRate: 0)
    }
    public func synthesizeStreaming(
        text: String,
        preferredVoiceName: String?,
        onChunk: @escaping @Sendable (KokoroSpeechAudio) async throws -> Void
    ) async throws {}
}
#endif
