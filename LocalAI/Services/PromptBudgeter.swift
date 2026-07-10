import Foundation

enum PromptBudgeter {
    struct Configuration {
        let inputTokenBudget: Int
        let maxOutputTokens: Int

        init(model: ModelInfo, maxOutputTokens: Int, lowPowerMode: Bool) {
            let outputTokens = lowPowerMode ? min(maxOutputTokens, 768) : maxOutputTokens
            self.maxOutputTokens = max(outputTokens, 128)

            var baseBudget: Int
            switch model.engine {
            case .appleFoundation:
                // Apple's on-device model has a hard 4,096-token context window
                // shared by the instructions, the session transcript, the prompt,
                // and the response. Budgeting above it aborts generation
                // mid-response with exceededContextWindowSize.
                baseBudget = model.supportsVision ? 3_500 : 4_096
            case .mlx:
                if model.supportsVision {
                    baseBudget = 2_800
                } else if model.id.localizedCaseInsensitiveContains("128k") ||
                            model.id.localizedCaseInsensitiveContains("long") {
                    baseBudget = 8_000
                } else if model.sizeGB >= 4.0 {
                    baseBudget = 5_500
                } else {
                    baseBudget = 3_800
                }
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
}
