//
//  SavedPrompt.swift
//  LocalAI
//

import Foundation

struct SavedPrompt: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var prompt: String

    init(id: UUID = UUID(), name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }
}
