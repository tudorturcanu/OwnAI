import Foundation

enum SmartReplyStyle: String, CaseIterable, Identifiable {
    case shorter
    case deeper
    case simpler
    case checklist
    case citeSources

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shorter:
            return String(localized: "Shorter")
        case .deeper:
            return String(localized: "Go deeper")
        case .simpler:
            return String(localized: "Simpler")
        case .checklist:
            return String(localized: "Checklist")
        case .citeSources:
            return String(localized: "Cite")
        }
    }

    var systemImage: String {
        switch self {
        case .shorter:
            return "minus.magnifyingglass"
        case .deeper:
            return "plus.magnifyingglass"
        case .simpler:
            return "textformat"
        case .checklist:
            return "checklist"
        case .citeSources:
            return "quote.bubble"
        }
    }

    func instruction(previousAnswer: String) -> String {
        let trimmedAnswer = previousAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        let rewriteInstruction: String

        switch self {
        case .shorter:
            rewriteInstruction = """
            Rewrite the previous answer to be shorter and more direct.
            Keep only the core points in 2-3 sentences maximum.
            """
        case .deeper:
            rewriteInstruction = """
            Rewrite the previous answer with more depth.
            Add helpful structure, context, tradeoffs, and concrete examples where useful.
            """
        case .simpler:
            rewriteInstruction = """
            Rewrite the previous answer in simpler language.
            Keep it accurate, avoid jargon, and explain any necessary technical terms briefly.
            """
        case .checklist:
            rewriteInstruction = """
            Turn the previous answer into a practical checklist.
            Keep the steps clear, action-oriented, and ordered when order matters.
            """
        case .citeSources:
            rewriteInstruction = """
            Rewrite the previous answer with clearer source references.
            Cite relevant document sources inline when the answer relies on them.
            Do not invent sources.
            """
        }

        return """
        \(rewriteInstruction)
        Do not mention that you are rewriting.

        Previous answer:
        \(trimmedAnswer)
        """
    }
}
