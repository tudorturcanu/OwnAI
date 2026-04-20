import Foundation

enum AIResponseDefaults {
    nonisolated static let defaultSystemPrompt = """
    You are a helpful AI assistant.
    Answer the user's request completely. Do not stop in the middle of a sentence, list, code block, or checklist.
    If the answer may be long, prioritize the most important details and finish with a complete final point.
    """

    nonisolated static let maxTokens = 2048
    nonisolated static let responseCharacterLimit = 0
}
