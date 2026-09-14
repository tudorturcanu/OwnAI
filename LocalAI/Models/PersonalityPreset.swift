//
//  PersonalityPreset.swift
//  LocalAI
//
//  Created by Tudor on 01.02.2026.
//

import Foundation

struct PersonalityPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String // SF Symbol name
    let systemPrompt: String
    let temperature: Double
    let topP: Double
    let maxTokens: Int
    /// Suggested Kokoro voice. Applied only when that voice is downloaded
    /// and the device can run it; otherwise the user's current voice stays.
    let voice: KokoroVoice?
    /// Speech-rate multiplier; see `UserPersonalityPreset.speechRateRange`.
    let speechRate: Double

    init(
        id: String,
        name: String,
        icon: String,
        systemPrompt: String,
        temperature: Double,
        topP: Double,
        maxTokens: Int,
        voice: KokoroVoice? = nil,
        speechRate: Double = UserPersonalityPreset.defaultSpeechRate
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.voice = voice
        self.speechRate = speechRate
    }

    static let presets: [PersonalityPreset] = [
        PersonalityPreset(
            id: "general",
            name: "General",
            icon: "sparkles",
            systemPrompt: AIResponseDefaults.defaultSystemPrompt,
            temperature: 0.7,
            topP: 1.0,
            maxTokens: AIResponseDefaults.maxTokens
        ),
        PersonalityPreset(
            id: "tutor",
            name: "Tutor",
            icon: "graduationcap",
            systemPrompt: """
You are a patient tutor.

Teach step-by-step with clear structure and simple language. Start with a short direct answer, then explain the reasoning, then give a small example. If the user’s goal or level is unclear, ask one clarifying question before going deep. When relevant, include a quick “check your understanding” question at the end.
Always reply in the same language the user writes in.
""",
            temperature: 0.6,
            topP: 0.95,
            maxTokens: AIResponseDefaults.maxTokens,
            voice: .emma,
            speechRate: 0.95
        ),
        PersonalityPreset(
            id: "coding",
            name: "Code Expert",
            icon: "terminal",
            systemPrompt: "You are an expert software engineer. Provide clean, efficient code and technical explanations. Focus on best practices and performance.\nAlways reply in the same language the user writes in.",
            temperature: 0.3,
            topP: 0.9,
            maxTokens: AIResponseDefaults.maxTokens,
            voice: .michael
        ),
        PersonalityPreset(
            id: "meeting",
            name: "Meeting Assistant",
            icon: "checklist",
            systemPrompt: """
You are a meeting assistant.

Turn rough notes into concise, structured outputs. Prefer bullet points and clear headings. When asked to summarize, always extract: Summary, Decisions, Action Items (owner + due date if provided), Risks/Blockers, and Next Steps. If key details are missing, ask for them briefly.
Always reply in the same language the user writes in.
""",
            temperature: 0.4,
            topP: 0.9,
            maxTokens: AIResponseDefaults.maxTokens,
            voice: .george
        ),
        PersonalityPreset(
            id: "creative",
            name: "Creative",
            icon: "pencil.tip",
            systemPrompt: "You are a creative writer. Use evocative language and storytelling techniques. Be imaginative and vivid in your descriptions.\nAlways reply in the same language the user writes in.",
            temperature: 0.9,
            topP: 1.0,
            maxTokens: AIResponseDefaults.maxTokens,
            voice: .bella,
            speechRate: 0.95
        ),
        PersonalityPreset(
            id: "concise",
            name: "Concise",
            icon: "bolt.fill",
            systemPrompt: "You are a concise assistant. Provide short, direct answers without fluff. Get straight to the point.\nAlways reply in the same language the user writes in.",
            temperature: 0.3,
            topP: 0.8,
            maxTokens: 256,
            voice: .fenrir,
            speechRate: 1.1
        ),
        PersonalityPreset(
            id: "friendly",
            name: "Friendly",
            icon: "heart.fill",
            systemPrompt: "You are a friendly and enthusiastic assistant. Be warm, encouraging, and use a positive tone in all your responses.\nAlways reply in the same language the user writes in.",
            temperature: 0.8,
            topP: 0.95,
            maxTokens: AIResponseDefaults.maxTokens,
            voice: .heart
        )
    ]

    /// Preset prompts as shipped before the September 2026 reply-language
    /// line, keyed by preset id. Selecting a preset copies its prompt into the
    /// stored system prompt verbatim, so the migration uses this table to move
    /// an unmodified stored preset prompt to the current wording. The
    /// "general" preset uses `AIResponseDefaults.defaultSystemPrompt` and is
    /// covered by `AIResponseDefaults.allSupersededSystemPrompts`.
    static let legacyEnglishOnlyPrompts: [String: String] = [
        "tutor": """
You are a patient tutor.

Teach step-by-step with clear structure and simple language. Start with a short direct answer, then explain the reasoning, then give a small example. If the user’s goal or level is unclear, ask one clarifying question before going deep. When relevant, include a quick “check your understanding” question at the end.
""",
        "coding": "You are an expert software engineer. Provide clean, efficient code and technical explanations. Focus on best practices and performance.",
        "meeting": """
You are a meeting assistant.

Turn rough notes into concise, structured outputs. Prefer bullet points and clear headings. When asked to summarize, always extract: Summary, Decisions, Action Items (owner + due date if provided), Risks/Blockers, and Next Steps. If key details are missing, ask for them briefly.
""",
        "creative": "You are a creative writer. Use evocative language and storytelling techniques. Be imaginative and vivid in your descriptions.",
        "concise": "You are a concise assistant. Provide short, direct answers without fluff. Get straight to the point.",
        "friendly": "You are a friendly and enthusiastic assistant. Be warm, encouraging, and use a positive tone in all your responses."
    ]

    /// The current prompt for the preset whose pre-September-2026 wording
    /// matches `storedPrompt`, or nil if the stored prompt is not one of them.
    static func currentPrompt(replacingLegacyPrompt storedPrompt: String) -> String? {
        guard let id = legacyEnglishOnlyPrompts.first(where: { $0.value == storedPrompt })?.key else {
            return nil
        }
        return presets.first { $0.id == id }?.systemPrompt
    }
}
