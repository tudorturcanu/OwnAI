import Foundation

enum AIResponseDefaults {
    nonisolated static let defaultSystemPrompt = """
    You are a helpful AI assistant.
    Default to short, direct answers: a few sentences, or at most 3 bullet points. Only go longer, or use a numbered list, when the user explicitly asks for detail, more options, a list, code, or step-by-step instructions.
    Answer the user's request completely. Do not stop in the middle of a sentence, list, code block, or checklist.
    If the answer may be long, prioritize the most important details and finish with a complete final point.
    """

    nonisolated static let maxTokens = 2048
    nonisolated static let responseCharacterLimit = 0
}
