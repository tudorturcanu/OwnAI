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
    
    static let presets: [PersonalityPreset] = [
        PersonalityPreset(
            id: "general",
            name: "General",
            icon: "sparkles",
            systemPrompt: "You are a helpful AI assistant.",
            temperature: 0.7,
            topP: 1.0,
            maxTokens: 512
        ),
        PersonalityPreset(
            id: "coding",
            name: "Code Expert",
            icon: "terminal",
            systemPrompt: "You are an expert software engineer. Provide clean, efficient code and technical explanations. Focus on best practices and performance.",
            temperature: 0.3,
            topP: 0.9,
            maxTokens: 768
        ),
        PersonalityPreset(
            id: "creative",
            name: "Creative",
            icon: "pencil.tip",
            systemPrompt: "You are a creative writer. Use evocative language and storytelling techniques. Be imaginative and vivid in your descriptions.",
            temperature: 0.9,
            topP: 1.0,
            maxTokens: 768
        ),
        PersonalityPreset(
            id: "concise",
            name: "Concise",
            icon: "bolt.fill",
            systemPrompt: "You are a concise assistant. Provide short, direct answers without fluff. Get straight to the point.",
            temperature: 0.3,
            topP: 0.8,
            maxTokens: 256
        ),
        PersonalityPreset(
            id: "friendly",
            name: "Friendly",
            icon: "heart.fill",
            systemPrompt: "You are a friendly and enthusiastic assistant. Be warm, encouraging, and use a positive tone in all your responses.",
            temperature: 0.8,
            topP: 0.95,
            maxTokens: 512
        )
    ]
}
