//
//  SavedPromptsView.swift
//  LocalAI
//
//  Pro feature: library of up to 20 named system prompts.
//

import SwiftUI

struct SavedPromptsView: View {
    @Environment(MonetizationManager.self) private var monetizationManager
    @AppStorage("systemPrompt") private var activeSystemPrompt = "You are a helpful AI assistant."

    @State private var promptStore = SavedPromptStore.shared
    @State private var isAddSheetPresented = false
    @State private var editingPrompt: SavedPrompt?
    @State private var upgradeFeature: PremiumFeature?
    @State private var activatedPromptID: UUID?

    var body: some View {
        Group {
            if monetizationManager.canUse(.savedPrompts) {
                libraryContent
            } else {
                proGateView
            }
        }
        .navigationTitle(String(localized: "Prompt Library"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if monetizationManager.canUse(.savedPrompts) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddSheetPresented = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(promptStore.prompts.count >= SavedPromptStore.maxPrompts)
                }
            }
        }
        .sheet(isPresented: $isAddSheetPresented) {
            PromptEditorSheet(existingPrompt: nil) { name, prompt in
                promptStore.add(name: name, prompt: prompt)
            }
        }
        .sheet(item: $editingPrompt) { prompt in
            PromptEditorSheet(existingPrompt: prompt) { name, newPrompt in
                promptStore.update(id: prompt.id, name: name, prompt: newPrompt)
            }
        }
        .sheet(item: $upgradeFeature) { feature in
            UpgradeView(feature: feature)
                .environment(monetizationManager)
        }
    }

    // MARK: - Library Content

    private var libraryContent: some View {
        Group {
            if promptStore.prompts.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(promptStore.prompts) { prompt in
                            promptRow(prompt)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                promptStore.delete(id: promptStore.prompts[index].id)
                            }
                        }
                        .onMove { from, to in
                            promptStore.move(fromOffsets: from, toOffset: to)
                        }
                    } footer: {
                        let count = promptStore.prompts.count
                        Text("\(count)/\(SavedPromptStore.maxPrompts) prompts")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.insetGrouped)
                .environment(\.editMode, .constant(.active))
            }
        }
    }

    private func promptRow(_ prompt: SavedPrompt) -> some View {
        let isActive = activeSystemPrompt == prompt.prompt
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? Color.orange.opacity(0.12) : Color(uiColor: .systemGray5))
                    .frame(width: 40, height: 40)
                Image(systemName: isActive ? "checkmark.circle.fill" : "books.vertical.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isActive ? .orange : .secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(prompt.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(prompt.prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if isActive {
                Text(String(localized: "Active"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.1), in: Capsule())
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3)) {
                activeSystemPrompt = prompt.prompt
                activatedPromptID = prompt.id
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                editingPrompt = prompt
            } label: {
                Label(String(localized: "Edit"), systemImage: "pencil")
            }
            .tint(.blue)
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange.opacity(0.7))

            VStack(spacing: 8) {
                Text(String(localized: "No Saved Prompts"))
                    .font(.title3.bold())
                Text(String(localized: "Save your favourite system prompts here and switch between them instantly."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                isAddSheetPresented = true
            } label: {
                Label(String(localized: "Add First Prompt"), systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(Color.orange)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Pro Gate

    private var proGateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 52))
                .foregroundStyle(
                    LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            VStack(spacing: 10) {
                Text(String(localized: "Prompt Library"))
                    .font(.title2.bold())
                Text(String(localized: "Save up to 20 named AI personalities and switch between them instantly. Available with Own AI Pro."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                upgradeFeature = .savedPrompts
            } label: {
                Text(String(localized: "Unlock with Pro"))
                    .font(.headline)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing)
                    )
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Prompt Editor Sheet

struct PromptEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let existingPrompt: SavedPrompt?
    let onSave: (String, String) -> Void

    @State private var name: String
    @State private var prompt: String

    init(existingPrompt: SavedPrompt?, onSave: @escaping (String, String) -> Void) {
        self.existingPrompt = existingPrompt
        self.onSave = onSave
        _name = State(initialValue: existingPrompt?.name ?? "")
        _prompt = State(initialValue: existingPrompt?.prompt ?? "")
    }

    private var isEditing: Bool { existingPrompt != nil }
    private var canSave: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "e.g. Coding Assistant"), text: $name)
                } header: {
                    Text(String(localized: "Name"))
                }

                Section {
                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(minHeight: 160)
                } header: {
                    Text(String(localized: "System Prompt"))
                } footer: {
                    Text(String(localized: "This text will be sent as the AI's instructions at the start of each conversation."))
                }
            }
            .navigationTitle(isEditing ? String(localized: "Edit Prompt") : String(localized: "New Prompt"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? String(localized: "Save") : String(localized: "Add")) {
                        onSave(name, prompt)
                        dismiss()
                    }
                    .disabled(!canSave)
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        SavedPromptsView()
    }
    .environment(MonetizationManager())
}
