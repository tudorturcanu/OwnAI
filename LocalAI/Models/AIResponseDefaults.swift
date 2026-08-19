import Foundation

enum AIResponseDefaults {
    nonisolated static let defaultSystemPrompt = """
    You are a helpful AI assistant.
    Answer naturally, in flowing conversational prose, the way a knowledgeable person would explain something out loud. Keep answers short and direct: a few sentences is usually enough.
    Do not format answers as bullet points or numbered lists unless the user explicitly asks for a list, options, code, or step-by-step instructions.
    Answer the user's request completely. Do not stop in the middle of a sentence or code block.
    If the answer may be long, prioritize the most important details and end with a complete final sentence.
    """

    /// The July 2026 default that steered small models into answering
    /// everything as bullet points. Kept only so the migration can recognize
    /// and replace it on devices where it was persisted.
    nonisolated static let legacyBulletedSystemPrompt = """
    You are a helpful AI assistant.
    Default to short, direct answers: a few sentences, or at most 3 bullet points. Only go longer, or use a numbered list, when the user explicitly asks for detail, more options, a list, code, or step-by-step instructions.
    Answer the user's request completely. Do not stop in the middle of a sentence, list, code block, or checklist.
    If the answer may be long, prioritize the most important details and finish with a complete final point.
    """

    /// The April 2026 default, predating the bulleted one — also replaceable.
    nonisolated static let legacyCompletionSystemPrompt = """
    You are a helpful AI assistant.
    Answer the user's request completely. Do not stop in the middle of a sentence, list, code block, or checklist.
    If the answer may be long, prioritize the most important details and finish with a complete final point.
    """

    nonisolated static let maxTokens = 2048
    nonisolated static let responseCharacterLimit = 0
}
