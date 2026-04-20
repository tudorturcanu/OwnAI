//
//  UserPersonalityPreset.swift
//  LocalAI
//
//  Created by Cursor on 13.04.2026.
//

import Foundation

struct UserPersonalityPreset: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var icon: String
    var systemPrompt: String
    var temperature: Double
    var topP: Double
    var maxTokens: Int
    var responseCharacterLimit: Int

    init(
        id: String = UUID().uuidString,
        name: String,
        icon: String,
        systemPrompt: String,
        temperature: Double,
        topP: Double,
        maxTokens: Int,
        responseCharacterLimit: Int
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.responseCharacterLimit = responseCharacterLimit
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

