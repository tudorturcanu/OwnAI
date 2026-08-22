//
//  KokoroVoiceService.swift
//  LocalAI
//
//  On-demand Kokoro-82M text-to-speech: model/voice download, the MLX
//  synthesizer, and the text preparation that feeds it. Kokoro-82M is
//  Apache-2.0 (hexgrad/Kokoro-82M); KokoroSwift is MIT; MisakiSwift (G2P)
//  is Apache-2.0. Nothing here ships inside the app binary — weights and
//  voices are fetched from Hugging Face the first time a Kokoro voice is
//  selected, mirroring the Whisper download flow.
//

import Foundation
import Hub
import QuartzCore
#if !targetEnvironment(simulator)
import MLX
import KokoroSwift
#endif

// MARK: - Voices

/// The curated subset of Kokoro voices the app exposes. Each voice is a
/// ~0.5 MB style tensor fetched lazily on first selection; the ~315 MB
/// model weights are shared by all of them.
enum KokoroVoice: String, CaseIterable, Identifiable, Sendable {
    case heart = "af_heart"
    case bella = "af_bella"
    case michael = "am_michael"
    case fenrir = "am_fenrir"
    case emma = "bf_emma"
    case george = "bm_george"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .heart: return "Heart"
        case .bella: return "Bella"
        case .michael: return "Michael"
        case .fenrir: return "Fenrir"
        case .emma: return "Emma"
        case .george: return "George"
        }
    }

    var isBritish: Bool { rawValue.hasPrefix("b") }
    var isFemale: Bool { rawValue.dropFirst().hasPrefix("f") }

    var subtitle: String {
        let accent = isBritish ? String(localized: "British English") : String(localized: "US English")
        let gender = isFemale ? String(localized: "female") : String(localized: "male")
        return "\(accent) · \(gender)"
    }

    /// Path of the style tensor inside the Hugging Face repo.
    var repoFileName: String { "voices/\(rawValue).safetensors" }
}

// MARK: - Model store

/// Locations and download logic for the Kokoro weights and voice tensors.
/// swift-transformers' HubApi lays snapshots out under
/// <downloadBase>/models/<repo>/..., the same layout Whisper and the MLX
/// chat models use.
enum KokoroModelStore {
    nonisolated static let repoID = "mlx-community/Kokoro-82M-bf16"
    nonisolated static let weightsFileName = "kokoro-v1_0.safetensors"
    /// Advertised in Settings; the real file is ~312 MB.
    nonisolated static let approximateWeightsMegabytes = 315
    /// A weights file smaller than this is a truncated download, not a model.
    nonisolated private static let minimumPlausibleWeightsBytes: UInt64 = 300_000_000

    nonisolated static var downloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kokoro", isDirectory: true)
    }

    nonisolated static var snapshotFolder: URL {
        downloadBase.appendingPathComponent("models/\(repoID)", isDirectory: true)
    }

    nonisolated static var weightsURL: URL {
        snapshotFolder.appendingPathComponent(weightsFileName)
    }

    nonisolated static func voiceURL(_ voice: KokoroVoice) -> URL {
        snapshotFolder.appendingPathComponent(voice.repoFileName)
    }

    nonisolated static var isWeightsDownloaded: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: weightsURL.path),
              let size = attributes[.size] as? UInt64 else { return false }
        return size >= minimumPlausibleWeightsBytes
    }

    nonisolated static func isVoiceDownloaded(_ voice: KokoroVoice) -> Bool {
        FileManager.default.fileExists(atPath: voiceURL(voice).path)
    }

    nonisolated static func isReady(for voice: KokoroVoice) -> Bool {
        isWeightsDownloaded && isVoiceDownloaded(voice)
    }

    /// Downloads whatever is missing for `voice` (weights and/or the voice
    /// tensor). `progress` is 0...1 across the whole operation; the weights
    /// dominate it, the voice file is a rounding error.
    nonisolated static func download(
        voice: KokoroVoice,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let base = downloadBase
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let hub = HubApi(downloadBase: base)
        KokoroDiagnostics.log("download", "START voice=\(voice.rawValue) weightsPresent=\(isWeightsDownloaded) voicePresent=\(isVoiceDownloaded(voice)) dest=\(snapshotFolder.path)"
        )
        defer {
            KokoroDiagnostics.log("download", "END weightsPresent=\(isWeightsDownloaded) voicePresent=\(isVoiceDownloaded(voice))"
            )
        }

        if !isWeightsDownloaded {
            // A stale partial file would otherwise be reported as present by
            // the size check on the next launch.
            try? FileManager.default.removeItem(at: weightsURL)
            try await hub.snapshot(from: repoID, matching: [weightsFileName]) { fileProgress in
                progress(min(0.98, fileProgress.fractionCompleted * 0.98))
            }
            try Task.checkCancellation()
            guard isWeightsDownloaded else {
                throw KokoroError.incompleteDownload
            }
        }

        if !isVoiceDownloaded(voice) {
            try await hub.snapshot(from: repoID, matching: [voice.repoFileName]) { _ in }
            try Task.checkCancellation()
        }
        progress(1.0)
    }

    nonisolated static func deleteAll() {
        try? FileManager.default.removeItem(at: downloadBase)
    }
}

enum KokoroError: LocalizedError {
    case unsupportedDevice
    case incompleteDownload
    case missingFiles
    case voiceTensorMissing
    case textTooLong

    var errorDescription: String? {
        switch self {
        case .unsupportedDevice:
            return String(localized: "Kokoro voices need an A14 or newer device.")
        case .incompleteDownload:
            return String(localized: "The Kokoro voice download did not complete.")
        case .missingFiles:
            return String(localized: "Kokoro voice files are missing. Download the voice again in Settings.")
        case .voiceTensorMissing:
            return String(localized: "The selected Kokoro voice file is damaged.")
        case .textTooLong:
            return String(localized: "This passage is too long for the Kokoro voice.")
        }
    }
}

// MARK: - Synthesizer

#if !targetEnvironment(simulator)
/// Owns the loaded `KokoroTTS` engine and a per-voice style cache. Generation
/// is synchronous and MLX must not be driven concurrently, so the actor
/// serializes every request. Construct it off the main actor — loading
/// ~312 MB of weights and compiling the MLX graph takes seconds.
actor KokoroSynthesizer {
    private let engine: KokoroTTS
    private var voiceCache: [KokoroVoice: MLXArray] = [:]

    nonisolated static let sampleRate = Double(KokoroTTS.Constants.samplingRate)

    init(weightsURL: URL) {
        KokoroDiagnostics.warnIfMetalValidationEnabled()
        let started = CACurrentMediaTime()
        KokoroDiagnostics.log("load", "START weights=\(weightsURL.lastPathComponent)")
        // LLMEngine applies the same limit before its first MLX call; doing
        // it here too keeps idle GPU cache bounded when only TTS is loaded.
        MLX.Memory.cacheLimit = Int(DeviceResourcePolicy.current.mlxCacheLimitBytes)
        engine = KokoroTTS(modelPath: weightsURL, g2p: .misaki)
        KokoroDiagnostics.log("load", "END \(KokoroDiagnostics.millis(since: started)) ms")
    }

    /// Runs a short throwaway synthesis so the MLX graph is compiled and the
    /// voice tensor cached before the first real utterance.
    func warmUp(voice: KokoroVoice) {
        let started = CACurrentMediaTime()
        do {
            _ = try synthesize("Ready.", voice: voice)
            KokoroDiagnostics.log("warmUp", "voice=\(voice.rawValue) \(KokoroDiagnostics.millis(since: started)) ms")
        } catch {
            KokoroDiagnostics.log("warmUp", "FAILED voice=\(voice.rawValue): \(error)")
        }
    }

    /// Synthesizes one chunk of already-cleaned text. Chunks must stay under
    /// Kokoro's 510-phoneme limit; see `SpeechTextPreparer.chunks(_:)`.
    func synthesize(_ text: String, voice: KokoroVoice) throws -> [Float] {
        let style = try loadStyle(for: voice)
        let started = CACurrentMediaTime()
        do {
            let (samples, _) = try engine.generateAudio(
                voice: style,
                language: voice.isBritish ? .enGB : .enUS,
                text: text
            )
            let audioSeconds = Double(samples.count) / Self.sampleRate
            KokoroDiagnostics.log("synthesize", "chars=\(text.count) audio=\(String(format: "%.2f", audioSeconds))s in \(KokoroDiagnostics.millis(since: started)) ms"
            )
            return samples
        } catch KokoroTTS.KokoroTTSError.tooManyTokens {
            KokoroDiagnostics.log("synthesize", "tooManyTokens chars=\(text.count)")
            throw KokoroError.textTooLong
        } catch {
            KokoroDiagnostics.log("synthesize", "FAILED chars=\(text.count): \(error)")
            throw error
        }
    }

    private func loadStyle(for voice: KokoroVoice) throws -> MLXArray {
        if let cached = voiceCache[voice] { return cached }
        let url = KokoroModelStore.voiceURL(voice)
        guard FileManager.default.fileExists(atPath: url.path) else {
            KokoroDiagnostics.log("voice", "MISSING \(url.path)")
            throw KokoroError.missingFiles
        }
        let arrays = try MLX.loadArrays(url: url)
        // The mlx-community voice files store a single [510, 1, 256] tensor
        // under the key "voice".
        guard let style = arrays["voice"] ?? arrays.values.first else {
            KokoroDiagnostics.log("voice", "NO TENSOR keys=\(Array(arrays.keys))")
            throw KokoroError.voiceTensorMissing
        }
        KokoroDiagnostics.log("voice", "loaded \(voice.rawValue) shape=\(style.shape) dtype=\(style.dtype)")
        voiceCache[voice] = style
        return style
    }
}
#else
/// MLX is compiled out on the simulator; the stub keeps `SpeechManager`
/// free of platform conditionals.
actor KokoroSynthesizer {
    nonisolated static let sampleRate: Double = 24_000

    init(weightsURL: URL) {}

    func warmUp(voice: KokoroVoice) {}

    func synthesize(_ text: String, voice: KokoroVoice) throws -> [Float] {
        throw KokoroError.unsupportedDevice
    }
}
#endif

// MARK: - Diagnostics

enum KokoroDiagnostics {
    /// Goes through `safeDiagnostic`, the only logger that reaches the Xcode
    /// console here (`PerformanceLogger.memory` hashes its message as private
    /// and the scheme disables os_activity). Never pass user text.
    nonisolated static func log(_ tag: String, _ message: String) {
        let line = tag.isEmpty ? "Kokoro \(message)" : "Kokoro.\(tag) \(message)"
        #if DEBUG
        print("🎙️ \(line)")
        #endif
        PerformanceLogger.safeDiagnostic(line)
    }

    nonisolated static func millis(since start: CFTimeInterval) -> Int {
        Int((CACurrentMediaTime() - start) * 1000)
    }

    /// Xcode's "Metal API Validation" (Scheme → Run → Diagnostics) wraps
    /// every encoder in MTLDebug* objects that assert on MLX's gather kernel
    /// passing an empty buffer to setBytes ("bytes argument cannot be nil").
    /// It never runs outside the debugger, but a debug session with it on
    /// dies inside the first synthesis — so Kokoro refuses to load instead.
    nonisolated static var isMetalValidationEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["MTL_DEBUG_LAYER"] == "1" || env["METAL_DEVICE_WRAPPER_TYPE"] == "1"
    }

    nonisolated static let metalValidationMessage =
        "Metal API Validation is enabled in this Xcode run, and MLX aborts under it. Edit Scheme › Run › Diagnostics › Metal API Validation → Disabled."

    /// The raw Xcode-injected variables, for the log — so "validation is on"
    /// is never a guess.
    nonisolated static var metalEnvironmentSummary: String {
        let env = ProcessInfo.processInfo.environment
        let keys = ["MTL_DEBUG_LAYER", "METAL_DEVICE_WRAPPER_TYPE", "MTL_SHADER_VALIDATION", "METAL_CAPTURE_ENABLED"]
        return keys.map { "\($0)=\(env[$0] ?? "unset")" }.joined(separator: " ")
    }

    nonisolated static func warnIfMetalValidationEnabled() {
        guard isMetalValidationEnabled else { return }
        log("", "WARNING: \(metalValidationMessage) [\(metalEnvironmentSummary)]")
    }
}

// MARK: - Text preparation

/// Turns assistant Markdown into something a TTS engine can read aloud, and
/// splits it into chunks that fit Kokoro's token limit while still ending on
/// natural pauses.
enum SpeechTextPreparer {
    /// Kokoro refuses inputs over 510 phoneme tokens; English phonemes run
    /// close to one per character, so this leaves comfortable headroom.
    nonisolated static let maxChunkCharacters = 240
    /// Chunk-size ramp. Synthesis is roughly linear in length (~11 ms/char
    /// measured on device) and nothing plays until the first chunk is done,
    /// so the opener is short (40 chars ≈ 450 ms to first word). Each later
    /// chunk must finish synthesizing before the previous one stops playing
    /// (a chunk yields ~6× its synthesis time in audio), so sizes grow
    /// gradually rather than jumping straight to the maximum.
    nonisolated static let chunkCharacterRamp = [40, 120]

    nonisolated static func clean(_ markdown: String) -> String {
        var text = markdown

        // Fenced code is unreadable as speech; say that it's there instead.
        text = text.replacingOccurrences(
            of: #"```[\s\S]*?```"#,
            with: " code block. ",
            options: .regularExpression
        )
        // Inline code: keep the content, drop the backticks.
        text = text.replacingOccurrences(of: "`", with: "")
        // Images carry nothing to read; links read their label.
        text = text.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        // Headings, emphasis, quotes, list markers, table rules.
        text = text.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*>\s?"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*\d+[.)]\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "|", with: ", ")
        text = text.replacingOccurrences(of: #"[*_~]{1,3}"#, with: "", options: .regularExpression)
        // Collapse the whitespace all of the above leaves behind.
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits cleaned text into speakable chunks, preferring sentence ends,
    /// then clause breaks, then word boundaries. The size limit follows
    /// `chunkCharacterRamp` for the opening chunks and `maxCharacters` after.
    nonisolated static func chunks(_ text: String, maxCharacters: Int = maxChunkCharacters) -> [String] {
        var result: [String] = []
        func limit() -> Int {
            result.count < chunkCharacterRamp.count
                ? min(chunkCharacterRamp[result.count], maxCharacters)
                : maxCharacters
        }

        for paragraph in text.split(whereSeparator: \.isNewline) {
            var current = ""
            for sentence in sentences(in: String(paragraph)) {
                // Pack sentences while they fit the limit for the chunk
                // currently being built; a sentence that is too long on its
                // own is split at clause/word boundaries for that same limit.
                if current.isEmpty {
                    current = sentence
                } else if current.count + 1 + sentence.count <= limit() {
                    current += " " + sentence
                } else {
                    result.append(contentsOf: splitOversized(current, maxCharacters: limit()))
                    current = sentence
                }
                while current.count > limit() {
                    let pieces = splitOversized(current, maxCharacters: limit())
                    guard pieces.count > 1 else { break }
                    result.append(pieces[0])
                    current = pieces.dropFirst().joined(separator: " ")
                }
            }
            if !current.isEmpty {
                result.append(contentsOf: splitOversized(current, maxCharacters: limit()))
            }
        }
        return result
    }

    nonisolated private static func sentences(in paragraph: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in paragraph {
            current.append(character)
            if ".!?".contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    /// Breaks a single over-long sentence at commas/semicolons, then at
    /// spaces, so no chunk exceeds the limit.
    nonisolated private static func splitOversized(_ sentence: String, maxCharacters: Int) -> [String] {
        guard sentence.count > maxCharacters else { return [sentence] }
        var pieces: [String] = []
        var current = ""
        let words = sentence.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count <= maxCharacters {
                current = candidate
                if let last = word.last, ",;:".contains(last), current.count > maxCharacters / 2 {
                    pieces.append(current)
                    current = ""
                }
            } else {
                if !current.isEmpty { pieces.append(current) }
                current = word
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
