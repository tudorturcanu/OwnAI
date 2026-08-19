import Foundation

enum AutoModelPreference: String, CaseIterable, Identifiable {
    case faster
    case balanced
    case bestQuality

    var id: String { rawValue }

    var title: String {
        switch self {
        case .faster: return String(localized: "Faster")
        case .balanced: return String(localized: "Balanced")
        case .bestQuality: return String(localized: "Best Quality")
        }
    }

    var symbolName: String {
        switch self {
        case .faster: return "bolt.fill"
        case .balanced: return "slider.horizontal.3"
        case .bestQuality: return "sparkles"
        }
    }
}

enum AutoModelTask: String {
    case chat
    case documents
    case images
    case coding
    case reasoning

    var title: String {
        switch self {
        case .chat: return String(localized: "chat")
        case .documents: return String(localized: "documents")
        case .images: return String(localized: "images")
        case .coding: return String(localized: "coding")
        case .reasoning: return String(localized: "reasoning")
        }
    }
}

struct AutoModelSelectionNotice: Identifiable, Equatable {
    let id = UUID()
    let modelID: String
    let message: String
}

enum AutoModelTaskClassifier {
    nonisolated static func classify(
        prompt: String,
        hasImage: Bool,
        hasDocuments: Bool
    ) -> AutoModelTask {
        if hasImage { return .images }
        if hasDocuments { return .documents }

        let normalized = prompt.lowercased()
        let codingSignals = [
            "```", "compile", "compiler", "stack trace", "exception", "debug",
            "refactor", "function", "func ", "class ", "struct ", "swiftui", "swift",
            "typescript", "javascript", "python", "sql", "api endpoint", "pull request",
            "regex", "html", "css", "json", "yaml", "algorithm", "code "
        ]
        if codingSignals.contains(where: normalized.contains) {
            return .coding
        }

        let reasoningSignals = [
            "step by step", "analyze", "compare", "evaluate", "trade-off",
            "tradeoff", "reason through", "prove", "calculate", "solve",
            "root cause", "pros and cons", "why does", "how would you",
            "derivative", "integral", "equation", "formula", "proof",
            "math", "theorem", "probability", "statistics"
        ]
        if reasoningSignals.contains(where: normalized.contains) || prompt.count > 700 {
            return .reasoning
        }

        return .chat
    }
}

