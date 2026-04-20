//
//  AIPersonalityView.swift
//  LocalAI
//
//  Created by Tudor on 01.02.2026.
//

import SwiftUI

struct AIPersonalityView: View {
    @Environment(MonetizationManager.self) private var monetizationManager
    @AppStorage("systemPrompt") private var systemPrompt = "You are a helpful AI assistant."
    @AppStorage("temperature") private var temperature = 0.7
    @AppStorage("topP") private var topP = 1.0
    @AppStorage("maxTokens") private var maxTokens = 512
    @AppStorage("responseCharacterLimit") private var responseCharacterLimit = 1000
    @AppStorage("customPersonalityPresetsJSON") private var customPresetsJSON = "[]"
    @State private var showUpgradeSheet = false
    @State private var isEditorPresented = false
    @State private var isImportPresented = false
    @State private var importText = ""
    @State private var importErrorMessage: String?
    @State private var draftPreset = UserPersonalityPreset(
        name: "",
        icon: "sparkles",
        systemPrompt: "You are a helpful AI assistant.",
        temperature: 0.7,
        topP: 1.0,
        maxTokens: 512,
        responseCharacterLimit: 1000
    )
    @State private var editingPresetID: String?
    @State private var sharePayload: String?
    @State private var isSavePromptAlertPresented = false
    @State private var savePromptName = ""
    @State private var savedPromptsUpgradeFeature: PremiumFeature?

    private var promptStore: SavedPromptStore { SavedPromptStore.shared }

    private let responseLengthOptions = [0, 500, 1000, 1500, 2000]

    private var selectedPresetID: String? {
        PersonalityPreset.presets.first { preset in
            preset.systemPrompt == systemPrompt &&
            abs(preset.temperature - temperature) < 0.0001 &&
            abs(preset.topP - topP) < 0.0001 &&
            preset.maxTokens == maxTokens
        }?.id
    }

    private var userPresets: [UserPersonalityPreset] {
        (try? UserPersonalityPreset.decodeList(from: customPresetsJSON)) ?? []
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Description
                Text(String(localized: "Customize how the AI behaves and responds to you."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)

                // Prompt Library NavigationLink
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "Saved Prompts"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 20)

                    NavigationLink {
                        SavedPromptsView()
                            .environment(monetizationManager)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "books.vertical.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.orange)
                                .frame(width: 34, height: 34)
                                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(String(localized: "Prompt Library"))
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(String(localized: "\(promptStore.prompts.count) saved prompt\(promptStore.prompts.count == 1 ? "" : "s")"))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if !monetizationManager.canUse(.savedPrompts) {
                                Image(systemName: "crown.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
                        .padding(.horizontal, 20)
                    }
                    .buttonStyle(.plain)
                }

                // Personality Presets
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "Presets"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 20)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(PersonalityPreset.presets) { preset in
                                Button {
                                    withAnimation {
                                        applyPreset(preset)
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: preset.icon)
                                            .font(.footnote)
                                        Text(LocalizedStringKey(preset.name))
                                            .font(.subheadline.weight(.medium))
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(selectedPresetID == preset.id ? Color.blue : Color.white)
                                    .foregroundStyle(selectedPresetID == preset.id ? .white : .primary)
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

                // Custom Presets
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(String(localized: "Your Presets"))
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Spacer()

                        Button {
                            guard monetizationManager.canUse(.advancedPersonality) else {
                                showUpgradeSheet = true
                                return
                            }
                            editingPresetID = nil
                            draftPreset = UserPersonalityPreset(
                                name: "",
                                icon: "sparkles",
                                systemPrompt: systemPrompt,
                                temperature: temperature,
                                topP: topP,
                                maxTokens: maxTokens,
                                responseCharacterLimit: responseCharacterLimit
                            )
                            isEditorPresented = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.subheadline.weight(.semibold))
                                .padding(8)
                                .background(Color.black.opacity(0.05), in: Circle())
                        }
                        .buttonStyle(.plain)

                        Button(String(localized: "Import")) {
                            guard monetizationManager.canUse(.advancedPersonality) else {
                                showUpgradeSheet = true
                                return
                            }
                            importText = ""
                            importErrorMessage = nil
                            isImportPresented = true
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
                    }
                    .padding(.horizontal, 20)

                    VStack(spacing: 10) {
                        if userPresets.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "tray")
                                    .foregroundStyle(.secondary)
                                Text(String(localized: "Create a preset to save your favorite prompt and tuning."))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        } else {
                            ForEach(userPresets) { preset in
                                Button {
                                    withAnimation {
                                        applyUserPreset(preset)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: preset.icon)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 28)
                                            .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(preset.name)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.primary)
                                            Text(preset.systemPrompt)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(String(localized: "Edit")) {
                                        guard monetizationManager.canUse(.advancedPersonality) else {
                                            showUpgradeSheet = true
                                            return
                                        }
                                        editingPresetID = preset.id
                                        draftPreset = preset
                                        isEditorPresented = true
                                    }

                                    Button(String(localized: "Export")) {
                                        if let json = try? UserPersonalityPreset.encode([preset]) {
                                            sharePayload = json
                                        }
                                    }

                                    Button(role: .destructive) {
                                        deleteUserPreset(id: preset.id)
                                    } label: {
                                        Text(String(localized: "Delete"))
                                    }
                                }
                            }
                        }
                    }
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
                    .padding(.horizontal, 20)
                    .overlay {
                        if !monetizationManager.canUse(.advancedPersonality) {
                            lockedOverlay
                        }
                    }
                }
                
                // System Prompt Section
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "System Prompt"))
                        .font(.headline)
                        .foregroundStyle(Color(white: 0.2))
                        .padding(.horizontal, 20)
                    
                    VStack(alignment: .leading, spacing: 0) {
                        // Header with Save / Reset
                        HStack {
                            Spacer()

                            Button(String(localized: "Save to Library")) {
                                guard monetizationManager.canUse(.savedPrompts) else {
                                    savedPromptsUpgradeFeature = .savedPrompts
                                    return
                                }
                                savePromptName = ""
                                isSavePromptAlertPresented = true
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)

                            if systemPrompt != "You are a helpful AI assistant." {
                                Button(String(localized: "Reset Default")) {
                                    withAnimation {
                                        systemPrompt = "You are a helpful AI assistant."
                                    }
                                }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.blue)
                                .padding(.leading, 8)
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
                    .overlay {
                        if !monetizationManager.canUse(.advancedPersonality) {
                            lockedOverlay
                        }
                    }
                }
                
                // Creativity & Parameters Section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(String(localized: "Parameters"))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        
                        Spacer()
                        
                        Button(String(localized: "Reset")) {
                            withAnimation {
                                temperature = 0.7
                                topP = 1.0
                                maxTokens = 512
                                responseCharacterLimit = 1000
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
                                Text(String(localized: "Temperature"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.1f", temperature))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            
                            Slider(value: $temperature, in: 0.0...1.0)
                                .tint(Gradient(colors: [.orange, .pink]))
                                
                            HStack {
                                Text(String(localized: "Precise"))
                                Spacer()
                                Text(String(localized: "Creative"))
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                        
                        Divider()
                        
                        // Top-P
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(String(localized: "Top-P"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.1f", topP))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            
                            Slider(value: $topP, in: 0.0...1.0)
                                .tint(Gradient(colors: [.purple, .blue]))
                                
                            Text(String(localized: "Limits the AI to only consider the most likely words whose cumulative probability reaches P."))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        
                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(String(localized: "Response Size"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(responseLengthLabel(for: responseCharacterLimit))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            Picker(String(localized: "Response Size"), selection: $responseCharacterLimit) {
                                ForEach(responseLengthOptions, id: \.self) { option in
                                    Text(LocalizedStringKey(responseLengthLabel(for: option))).tag(option)
                                }
                            }
                            .pickerStyle(.menu)

                            Text(String(localized: "Adds a strict visible-character cap to assistant replies. Useful if you want short answers that do not keep going."))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        Divider()
                        
                        // Max Tokens
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(String(localized: "Max Length"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: String(localized: "%lld tokens", defaultValue: "%lld tokens"), Int64(maxTokens)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            
                            Slider(value: Binding(
                                get: { Float(maxTokens) },
                                set: { maxTokens = Int($0) }
                            ), in: 64...2048, step: 64)
                                .tint(Gradient(colors: [.green, .teal]))
                                
                            Text(String(localized: "Sets the maximum number of tokens the AI will generate in a single response."))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(20)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
                    .padding(.horizontal, 20)
                    .overlay {
                        if !monetizationManager.canUse(.advancedPersonality) {
                            lockedOverlay
                        }
                    }
                }
                
                Spacer()
            }
            .padding(.top, 20)
        }
        .background(Color(white: 0.98))
        .navigationTitle(String(localized: "AI Personality"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showUpgradeSheet) {
            UpgradeView(feature: .advancedPersonality)
                .environment(monetizationManager)
        }
        .sheet(item: $savedPromptsUpgradeFeature) { feature in
            UpgradeView(feature: feature)
                .environment(monetizationManager)
        }
        .alert(String(localized: "Save to Prompt Library"), isPresented: $isSavePromptAlertPresented) {
            TextField(String(localized: "Prompt name"), text: $savePromptName)
            Button(String(localized: "Save")) {
                let name = savePromptName.trimmingCharacters(in: .whitespacesAndNewlines)
                promptStore.add(
                    name: name.isEmpty ? String(localized: "Untitled Prompt") : name,
                    prompt: systemPrompt
                )
            }
            Button(String(localized: "Cancel"), role: .cancel) { }
        } message: {
            Text(String(localized: "Give this prompt a name so you can find it later."))
        }
        .sheet(isPresented: $isEditorPresented) {
            PersonalityEditorSheet(
                title: editingPresetID == nil ? String(localized: "New Preset") : String(localized: "Edit Preset"),
                draft: $draftPreset
            ) { saved in
                upsertUserPreset(saved, editingID: editingPresetID)
            }
        }
        .sheet(isPresented: $isImportPresented) {
            NavigationStack {
                VStack(spacing: 12) {
                    Text(String(localized: "Paste a preset JSON to import."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    TextEditor(text: $importText)
                        .font(.body)
                        .frame(minHeight: 180)
                        .padding(10)
                        .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 12))

                    if let importErrorMessage {
                        Text(importErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Spacer()
                }
                .padding(16)
                .navigationTitle(String(localized: "Import Preset"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) { isImportPresented = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Import")) {
                            importPresets(from: importText)
                        }
                        .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .sheet(isPresented: shareSheetPresentedBinding, onDismiss: { sharePayload = nil }) {
            ShareSheet(items: [sharePayload ?? ""])
        }
    }

    private func applyPreset(_ preset: PersonalityPreset) {
        systemPrompt = preset.systemPrompt
        temperature = preset.temperature
        topP = preset.topP
        maxTokens = preset.maxTokens
    }

    private func applyUserPreset(_ preset: UserPersonalityPreset) {
        systemPrompt = preset.systemPrompt
        temperature = preset.temperature
        topP = preset.topP
        maxTokens = preset.maxTokens
        responseCharacterLimit = preset.responseCharacterLimit
    }

    private func upsertUserPreset(_ preset: UserPersonalityPreset, editingID: String?) {
        var current = userPresets
        if let editingID, let idx = current.firstIndex(where: { $0.id == editingID }) {
            var updated = preset
            updated = UserPersonalityPreset(
                id: editingID,
                name: updated.name,
                icon: updated.icon,
                systemPrompt: updated.systemPrompt,
                temperature: updated.temperature,
                topP: updated.topP,
                maxTokens: updated.maxTokens,
                responseCharacterLimit: updated.responseCharacterLimit
            )
            current[idx] = updated
        } else {
            current.insert(preset, at: 0)
        }
        persistUserPresets(current)
    }

    private func deleteUserPreset(id: String) {
        let filtered = userPresets.filter { $0.id != id }
        persistUserPresets(filtered)
    }

    private func persistUserPresets(_ presets: [UserPersonalityPreset]) {
        do {
            customPresetsJSON = try UserPersonalityPreset.encode(presets)
        } catch {
            // If encoding fails, do not overwrite existing storage.
        }
    }

    private func importPresets(from text: String) {
        do {
            let imported = try UserPersonalityPreset.decodeList(from: text)
            guard !imported.isEmpty else {
                importErrorMessage = String(localized: "No presets found in this text.")
                return
            }
            var merged = userPresets
            for preset in imported {
                if let idx = merged.firstIndex(where: { $0.id == preset.id }) {
                    merged[idx] = preset
                } else {
                    merged.insert(preset, at: 0)
                }
            }
            persistUserPresets(merged)
            isImportPresented = false
        } catch {
            importErrorMessage = String(localized: "That doesn’t look like valid preset JSON.")
        }
    }

    private var shareSheetPresentedBinding: Binding<Bool> {
        Binding(
            get: { sharePayload != nil },
            set: { if !$0 { sharePayload = nil } }
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

    private var lockedOverlay: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(.ultraThinMaterial)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "crown.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    Text(String(localized: "Own AI Pro"))
                        .font(.headline)
                        .foregroundStyle(Color(white: 0.15))
                    Text(String(localized: "Unlock custom prompts and response tuning."))
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color(white: 0.45))
                    Button(String(localized: "Unlock Pro")) {
                        showUpgradeSheet = true
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                .padding(20)
            }
    }
}

#Preview {
    NavigationStack {
        AIPersonalityView()
    }
    .environment(MonetizationManager())
}

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

@MainActor
@Observable
final class SavedPromptStore {
    static let shared = SavedPromptStore()
    static let maxPrompts = 20

    private static let storageKey = "savedPrompts.v1"

    private(set) var prompts: [SavedPrompt] = []

    private init() {
        load()
    }

    // MARK: - CRUD

    /// Adds a new prompt. Returns false if the 20-prompt cap is reached.
    @discardableResult
    func add(name: String, prompt: String) -> Bool {
        guard prompts.count < Self.maxPrompts else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return false }
        let saved = SavedPrompt(
            name: trimmedName.isEmpty ? String(localized: "Untitled Prompt") : trimmedName,
            prompt: trimmedPrompt
        )
        prompts.insert(saved, at: 0)
        persist()
        return true
    }

    func update(id: UUID, name: String, prompt: String) {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        prompts[index].name = trimmedName.isEmpty ? String(localized: "Untitled Prompt") : trimmedName
        prompts[index].prompt = trimmedPrompt
        persist()
    }

    func delete(id: UUID) {
        prompts.removeAll { $0.id == id }
        persist()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        prompts.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(prompts) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([SavedPrompt].self, from: data) else {
            return
        }
        prompts = decoded
    }
}
