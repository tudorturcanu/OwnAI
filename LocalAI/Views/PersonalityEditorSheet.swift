//
//  PersonalityEditorSheet.swift
//  LocalAI
//
//  Created by Cursor on 13.04.2026.
//

import SwiftUI

struct PersonalityEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    @Binding var draft: UserPersonalityPreset
    let onSave: (UserPersonalityPreset) -> Void

    private let responseLengthOptions = [0, 500, 1000, 1500, 2000]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Name"), text: $draft.name)
                    TextField(String(localized: "Icon (SF Symbol)"), text: $draft.icon)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(String(localized: "Basics"))
                } footer: {
                    Text(String(localized: "Tip: Use an SF Symbol name like “sparkles” or “terminal”."))
                }

                Section(String(localized: "System Prompt")) {
                    TextEditor(text: $draft.systemPrompt)
                        .frame(minHeight: 140)
                        .font(.body)
                }

                Section(String(localized: "Parameters")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(String(localized: "Temperature"))
                            Spacer()
                            Text(String(format: "%.1f", draft.temperature))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $draft.temperature, in: 0.0...1.0)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(String(localized: "Top-P"))
                            Spacer()
                            Text(String(format: "%.1f", draft.topP))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $draft.topP, in: 0.0...1.0)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(String(localized: "Max Length"))
                            Spacer()
                            Text(String(format: String(localized: "%lld tokens", defaultValue: "%lld tokens"), Int64(draft.maxTokens)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Float(draft.maxTokens) },
                                set: { draft.maxTokens = Int($0) }
                            ),
                            in: 64...4096,
                            step: 64
                        )
                    }

                    Picker(String(localized: "Response Size"), selection: $draft.responseCharacterLimit) {
                        ForEach(responseLengthOptions, id: \.self) { option in
                            Text(LocalizedStringKey(responseLengthLabel(for: option))).tag(option)
                        }
                    }
                }

                Section {
                    Picker(String(localized: "Voice"), selection: voiceSelection) {
                        Text(String(localized: "Keep current voice")).tag("")
                        ForEach(voiceOptions) { backend in
                            Text(backend.title).tag(backend.rawValue)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(String(localized: "Speaking Speed"))
                            Spacer()
                            Text(String(format: "%.2f×", draft.speechRate))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $draft.speechRate, in: UserPersonalityPreset.speechRateRange, step: 0.05)
                    }
                } header: {
                    Text(String(localized: "Voice"))
                } footer: {
                    Text(String(localized: "Used when replies are read aloud and in voice conversations. A Kokoro voice is applied only once it has been downloaded in Settings › Advanced."))
                }

                Section(String(localized: "Preview")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: draft.icon.isEmpty ? "sparkles" : draft.icon)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(draft.name.isEmpty ? String(localized: "Untitled") : draft.name)
                                .font(.headline)
                        }

                        Text(draft.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? String(localized: "Add a system prompt to define how the assistant should behave.")
                             : draft.systemPrompt
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                    }
                }
            }
            .navigationTitle(LocalizedStringKey(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var voiceOptions: [SpeechOutputBackend] {
        SpeechManager.isKokoroSupportedOnCurrentDevice ? SpeechOutputBackend.allCases : [.system]
    }

    /// `draft.voice` is optional (nil = keep current); the picker needs a
    /// non-optional tag, so "" stands in for nil.
    private var voiceSelection: Binding<String> {
        Binding(
            get: { draft.voice ?? "" },
            set: { draft.voice = $0.isEmpty ? nil : $0 }
        )
    }

    private func responseLengthLabel(for limit: Int) -> String {
        switch limit {
        case 0:
            return String(localized: "Unlimited")
        default:
            return String(format: String(localized: "%lld chars", defaultValue: "%lld chars"), Int64(limit))
        }
    }
}
