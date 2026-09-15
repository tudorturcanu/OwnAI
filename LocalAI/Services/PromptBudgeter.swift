import Foundation

enum PromptBudgeter {
    struct Configuration {
        let inputTokenBudget: Int
        let maxOutputTokens: Int

        init(model: ModelInfo, maxOutputTokens: Int, lowPowerMode: Bool) {
            let deviceLimit = DeviceResourcePolicy.current.generationTokenLimit(
                lowPowerMode: lowPowerMode || ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalState: ProcessInfo.processInfo.thermalState
            )
            let outputTokens = min(maxOutputTokens, deviceLimit)
            self.maxOutputTokens = max(outputTokens, 128)

            var baseBudget: Int
            switch model.engine {
            case .appleFoundation:
                // Apple's system model has a hard context window shared by the
                // instructions, the session transcript, the prompt, and the
                // response. Budgeting above it aborts generation mid-response
                // with a context-size error. The window is read from the model
                // the OS serves: 4,096 tokens on iOS 26 and AFM 3 Core, larger
                // on AFM 3 Core Advanced. The image reserve keeps the tuned
                // 3,500-token budget on a 4,096 window.
                let contextWindow = AppleFoundationModelBridge.currentProfile().contextSize
                baseBudget = model.supportsVision ? contextWindow - 596 : contextWindow
            case .mlx:
                baseBudget = PromptBudgeter.mlxContextWindow(for: model)
                if !lowPowerMode {
                    let adaptiveBonus = UserDefaults.standard.integer(forKey: "mlxAdaptiveInputBudgetBonus")
                    baseBudget += min(max(adaptiveBonus, 0), 2_000)
                }
            }

            // Keep a cushion for chat templates, tool-like wrappers, image descriptions,
            // and model-specific special tokens that are not visible in the prompt string.
            let reserved = self.maxOutputTokens + 384
            self.inputTokenBudget = max(900, baseBudget - reserved)
        }
    }

    /// Rough context window for an MLX model.
    ///
    /// Single source of truth: LLMEngine sizes its response budget and triggers
    /// rolling condensation against the same number. If the two drift, the
    /// engine condenses the transcript against a window the prompt was never
    /// budgeted for. `128k` matches the released Phi 3 Mini 128K build; `long`
    /// is reserved for future long-context identifiers.
    /// Models whose architecture keeps a long context cheap on-device, sized
    /// individually instead of by the generic heuristics below. Nemotron 3
    /// Nano is a hybrid Mamba-Transformer: only 4 of its 42 layers carry a
    /// growing KV cache, so a 12K window costs a fraction of what it would on
    /// a pure Transformer of the same size — and the model is trained for it
    /// (262K max, ~91% RULER recall at 128K). The low-memory-phone clamp in
    /// DeviceResourcePolicy still applies on constrained devices.
    nonisolated private static let extendedWindowByModelID: [String: Int] = [
        "mlx-community/NVIDIA-Nemotron-3-Nano-4B-OptiQ-4bit": 12_000
    ]

    nonisolated static func mlxContextWindow(for model: ModelInfo) -> Int {
        let modelWindow: Int
        if let extendedWindow = extendedWindowByModelID[model.id] {
            modelWindow = extendedWindow
        } else if model.supportsVision {
            modelWindow = 2_800
        } else if model.id.localizedCaseInsensitiveContains("128k") ||
            model.id.localizedCaseInsensitiveContains("long") {
            modelWindow = 8_000
        } else if model.sizeGB >= 4.0 {
            modelWindow = 5_500
        } else {
            modelWindow = 3_800
        }
        return min(modelWindow, DeviceResourcePolicy.current.maximumContextTokens)
    }

    struct DocumentSnippet {
        let title: String
        let location: String?
        let content: String
    }

    struct DocumentPackage {
        let context: String
        let sourceTitles: [String]
        let omittedCount: Int
    }

    nonisolated static func documentPackage(
        snippets: [DocumentSnippet],
        configuration: Configuration,
        reservedTokens: Int
    ) -> DocumentPackage {
        let budget = max(500, configuration.inputTokenBudget - reservedTokens)
        var remainingTokens = budget
        var blocks: [String] = []
        // `sourceTitles` is ordered so that its position matches the `[Source n]`
        // marker the model is asked to cite: sourceTitles[n - 1] is Source n. Each
        // distinct document·location gets one stable number, reused when the same
        // source contributes multiple passages, so the chips shown in the UI line
        // up 1:1 with the inline citations in the answer.
        var sourceTitles: [String] = []
        var numberByKey: [String: Int] = [:]
        var omittedCount = 0

        for (index, snippet) in snippets.enumerated() {
            let sourceTitle = snippet.location.map { "\(snippet.title) · \($0)" } ?? snippet.title
            let assignedNumber = numberByKey[sourceTitle] ?? (sourceTitles.count + 1)
            let header = "[Source \(assignedNumber): \(snippet.title)]"
            let locationLine = snippet.location.map { "Location: \($0)\n" } ?? ""
            let overhead = estimatedTokenCount(header + "\n" + locationLine) + 12
            let availableForContent = remainingTokens - overhead

            guard availableForContent >= 80 else {
                omittedCount += snippets.count - index
                break
            }

            let content = clippedText(snippet.content, maxTokens: min(availableForContent, maxTokensPerSnippet))
            let block = """
            \(header)
            \(locationLine)\(content)
            """
            let usedTokens = estimatedTokenCount(block)

            guard usedTokens <= remainingTokens else {
                omittedCount += 1
                continue
            }

            blocks.append(block)
            if numberByKey[sourceTitle] == nil {
                numberByKey[sourceTitle] = assignedNumber
                sourceTitles.append(sourceTitle)
            }
            remainingTokens -= usedTokens
        }

        return DocumentPackage(
            context: blocks.joined(separator: "\n\n"),
            sourceTitles: sourceTitles,
            omittedCount: omittedCount
        )
    }

    nonisolated static func budgetedPrompt(
        instructions: String,
        context: String,
        userRequest: String,
        configuration: Configuration
    ) -> String {
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRequest = userRequest.trimmingCharacters(in: .whitespacesAndNewlines)

        let requestBudget = max(280, min(1_200, configuration.inputTokenBudget / 3))
        let safeRequest = clippedTextPreservingEdges(trimmedRequest, maxTokens: requestBudget)

        let fixedPrompt = """
        \(trimmedInstructions)

        User request: \(safeRequest)
        """
        let fixedTokens = estimatedTokenCount(fixedPrompt)
        let contextBudget = max(0, configuration.inputTokenBudget - fixedTokens)
        let safeContext = clippedText(trimmedContext, maxTokens: contextBudget)

        if safeContext.isEmpty {
            return fixedPrompt
        }

        return """
        \(trimmedInstructions)

        Chat documents:
        \(safeContext)

        User request: \(safeRequest)
        """
    }

    nonisolated static func finalPromptGuard(_ prompt: String, configuration: Configuration) -> String {
        guard estimatedTokenCount(prompt) > configuration.inputTokenBudget else {
            return prompt
        }
        return clippedTextPreservingEdges(prompt, maxTokens: configuration.inputTokenBudget)
    }

    nonisolated static func estimatedTokenCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let wordEstimate = Double(trimmed.split { $0.isWhitespace || $0.isNewline }.count) * 1.35
        let characterEstimate = Double(trimmed.count) / 4.0
        return Int(max(wordEstimate, characterEstimate).rounded(.up))
    }

    nonisolated static var maxTokensPerSnippet: Int {
        700
    }

    nonisolated static func snippetSizedText(_ text: String, maxTokens: Int = maxTokensPerSnippet) -> String {
        let maxCharacters = max(80, maxTokens * 4)
        let start = text.firstIndex { !$0.isWhitespace && !$0.isNewline } ?? text.endIndex
        guard start < text.endIndex else { return "" }

        if let end = text.index(start, offsetBy: maxCharacters, limitedBy: text.endIndex) {
            return String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines) +
                "\n[Context clipped to fit the model.]"
        }

        return String(text[start..<text.endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func boundedChatText(_ text: String, maxTokens: Int) -> String {
        clippedTextPreservingEdges(text, maxTokens: maxTokens)
    }

    nonisolated private static func clippedText(_ text: String, maxTokens: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxTokens > 0, estimatedTokenCount(trimmed) > maxTokens else {
            return trimmed
        }

        let maxCharacters = max(80, maxTokens * 4)
        let prefix = String(trimmed.prefix(maxCharacters))
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "\n[Context clipped to fit the model.]"
    }

    nonisolated private static func clippedTextPreservingEdges(_ text: String, maxTokens: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxTokens > 0, estimatedTokenCount(trimmed) > maxTokens else {
            return trimmed
        }

        let maxCharacters = max(160, maxTokens * 4)
        let headCount = maxCharacters * 2 / 3
        let tailCount = maxCharacters - headCount
        let head = trimmed.prefix(headCount).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = trimmed.suffix(tailCount).trimmingCharacters(in: .whitespacesAndNewlines)

        return """
        \(head)

        [Middle content clipped to fit the model.]

        \(tail)
        """
    }

    // Substrings that mark a sentence as a directive aimed at the assistant
    // rather than a fact about the conversation, across the app's supported
    // languages (en/de/es/fr). Compared against a lowercased, diacritic-folded
    // copy of each sentence.
    nonisolated private static let continuityInjectionMarkers: [String] = [
        // English
        "ignore previous", "ignore all previous", "ignore the above",
        "disregard previous", "disregard the above", "disregard your",
        "system prompt", "your instructions", "these instructions",
        "you must", "you are now", "from now on you", "act as", "pretend to be",
        "reveal your", "override your", "new instructions",
        // German
        "ignoriere", "vergiss die", "systemaufforderung", "du musst",
        "ab jetzt bist", "tu so als", "neue anweisung",
        // Spanish
        "ignora las", "ignora todo", "olvida las", "instrucciones del sistema",
        "a partir de ahora", "actua como", "haz de cuenta", "nuevas instrucciones",
        // French
        "ignore les", "oublie les", "invite systeme", "tu dois",
        "desormais tu", "fais comme si", "nouvelles instructions"
    ]

    /// Neutralizes a model-written continuity summary before it is merged into
    /// privileged session instructions. The summary is derived from
    /// conversation content, so a user could try to smuggle a directive
    /// ("ignore your rules") into it and have it promoted to the instructions
    /// channel on the next rolling condense. This drops sentences that read as
    /// instructions to the assistant. Defense-in-depth: the low-temperature
    /// greedy summarizer rarely emits such text, and the merge frame already
    /// tells the model to treat this block as silent background, not commands.
    nonisolated static func sanitizedContinuitySummary(_ summary: String) -> String {
        let normalizedWhitespace = summary
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")

        var sentences: [String] = []
        var current = ""
        for character in normalizedWhitespace {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                sentences.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sentences.append(current)
        }

        let kept = sentences.filter { sentence in
            let folded = sentence
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return !continuityInjectionMarkers.contains { folded.contains($0) }
        }

        return kept
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
