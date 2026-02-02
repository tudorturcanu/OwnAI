//
//  AIPersonalityView.swift
//  LocalAI
//
//  Created by Tudor on 01.02.2026.
//

import SwiftUI
import FoundationModels

struct AIPersonalityView: View {
    @Environment(LLMEngine.self) private var llmEngine
    @AppStorage("systemPrompt") private var systemPrompt = "You are a helpful AI assistant."
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Description
                Text("Customize how the AI behaves and responds to you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                
                // Personality Presets
                VStack(alignment: .leading, spacing: 12) {
                    Text("Presets")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 20)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(PersonalityPreset.presets) { preset in
                                Button {
                                    withAnimation {
                                        systemPrompt = preset.systemPrompt
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: preset.icon)
                                            .font(.footnote)
                                        Text(preset.name)
                                            .font(.subheadline.weight(.medium))
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(systemPrompt == preset.systemPrompt ? Color.blue : Color.white)
                                    .foregroundStyle(systemPrompt == preset.systemPrompt ? .white : .primary)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.black.opacity(0.05), lineWidth: 1)
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                
                // System Prompt Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("System Prompt")
                        .font(.headline)
                        .foregroundStyle(Color(white: 0.2))
                        .padding(.horizontal, 20)
                    
                    VStack(alignment: .leading, spacing: 0) {
                        // Header with Reset Button
                        HStack {
                            Spacer()
                            
                            if systemPrompt != "You are a helpful AI assistant." {
                                Button("Reset Default") {
                                    withAnimation {
                                        systemPrompt = "You are a helpful AI assistant."
                                    }
                                }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.blue)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        
                        // Text Editor
                        TextEditor(text: $systemPrompt)
                            .font(.body)
                            .foregroundStyle(Color(white: 0.1))
                            .frame(height: 120)
                            .padding(12)
                            .scrollContentBackground(.hidden)
                            .background(Color(white: 0.96))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    }
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
                    .padding(.horizontal, 20)
                }
                
                // Creativity & Parameters Section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Parameters")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        
                        Spacer()
                        
                        Button("Reset") {
                            withAnimation {
                                llmEngine.temperature = 0.7
                                llmEngine.topP = 1.0
                                llmEngine.maxTokens = 512
                            }
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
                    }
                    .padding(.horizontal, 20)
                    
                    VStack(alignment: .leading, spacing: 20) {
                        // Temperature
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Temperature")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.1f", llmEngine.temperature))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            
                            Slider(value: Binding(
                                get: { llmEngine.temperature },
                                set: { llmEngine.temperature = $0 }
                            ), in: 0.0...1.0)
                                .tint(Gradient(colors: [.orange, .pink]))
                                
                            HStack {
                                Text("Precise")
                                Spacer()
                                Text("Creative")
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                        
                        Divider()
                        
                        // Top-P
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Top-P")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.1f", llmEngine.topP))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            
                            Slider(value: Binding(
                                get: { llmEngine.topP },
                                set: { llmEngine.topP = $0 }
                            ), in: 0.0...1.0)
                                .tint(Gradient(colors: [.purple, .blue]))
                                
                            Text("Limits the AI to only consider the most likely words whose cumulative probability reaches P.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        
                        Divider()
                        
                        // Max Tokens
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Max Length")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(llmEngine.maxTokens) tokens")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            
                            Slider(value: Binding(
                                get: { Float(llmEngine.maxTokens) },
                                set: { llmEngine.maxTokens = Int($0) }
                            ), in: 64...2048, step: 64)
                                .tint(Gradient(colors: [.green, .teal]))
                                
                            Text("Sets the maximum number of tokens the AI will generate in a single response.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(20)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
                    .padding(.horizontal, 20)
                }
                
                Spacer()
            }
            .padding(.top, 20)
        }
        .background(Color(white: 0.98))
        .navigationTitle("AI Personality")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        AIPersonalityView()
            .environment(LLMEngine())
    }
}
