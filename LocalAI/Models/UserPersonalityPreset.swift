//
//  UserPersonalityPreset.swift
//  LocalAI
//
//  Created by Cursor on 13.04.2026.
//

import Foundation

struct UserPersonalityPreset: Identifiable, Codable, Equatable {
    /// Speech-rate multiplier bounds shared by presets, the editor, and
    /// `SpeechManager`. 1.0 is the voice's natural pace.
    static let speechRateRange: ClosedRange<Double> = 0.7...1.3
    static let defaultSpeechRate = 1.0

    let id: String
    var name: String
    var icon: String
    var systemPrompt: String
    var temperature: Double
    var topP: Double
    var maxTokens: Int
    var responseCharacterLimit: Int
    /// A `SpeechOutputBackend` raw value ("system" or "kokoro:<voice>"), or
    /// nil to leave the user's current voice untouched when the preset is
    /// applied.
    var voice: String?
    var speechRate: Double

    init(
        id: String = UUID().uuidString,
        name: String,
        icon: String,
        systemPrompt: String,
        temperature: Double,
        topP: Double,
        maxTokens: Int,
        responseCharacterLimit: Int,
        voice: String? = nil,
        speechRate: Double = UserPersonalityPreset.defaultSpeechRate
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.responseCharacterLimit = responseCharacterLimit
        self.voice = voice
        self.speechRate = speechRate
    }

    // Presets saved (or exported/imported) before voice settings existed
    // have no `voice`/`speechRate` keys; decode them with the defaults
    // instead of failing and wiping the user's library.
    private enum CodingKeys: String, CodingKey {
        case id, name, icon, systemPrompt, temperature, topP, maxTokens, responseCharacterLimit, voice, speechRate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        temperature = try container.decode(Double.self, forKey: .temperature)
        topP = try container.decode(Double.self, forKey: .topP)
        maxTokens = try container.decode(Int.self, forKey: .maxTokens)
        responseCharacterLimit = try container.decode(Int.self, forKey: .responseCharacterLimit)
        voice = try container.decodeIfPresent(String.self, forKey: .voice)
        speechRate = try container.decodeIfPresent(Double.self, forKey: .speechRate) ?? Self.defaultSpeechRate
    }
}

extension UserPersonalityPreset {
    static func encode(_ presets: [UserPersonalityPreset]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(presets)
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeList(from json: String) throws -> [UserPersonalityPreset] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let data = Data(trimmed.utf8)
        let decoder = JSONDecoder()

        if trimmed.first == "[" {
            return try decoder.decode([UserPersonalityPreset].self, from: data)
        }
        return [try decoder.decode(UserPersonalityPreset.self, from: data)]
    }
}
