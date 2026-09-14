//
//  SavedPromptsView.swift
//  LocalAI
//
//  Pro feature: library of up to 20 named system prompts.
//

import SwiftUI
import UIKit

struct SavedPromptsView: View {
    @Environment(MonetizationManager.self) private var monetizationManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("systemPrompt") private var activeSystemPrompt = AIResponseDefaults.defaultSystemPrompt

    @State private var promptStore = SavedPromptStore.shared
    @State private var isAddSheetPresented = false
    @State private var editingPrompt: SavedPrompt?
    @State private var promptPendingDeletion: SavedPrompt?
    @State private var upgradeFeature: PremiumFeature?
    @State private var searchText = ""
    private static let selectionHaptic = UISelectionFeedbackGenerator()

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visiblePrompts: [SavedPrompt] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return promptStore.prompts }
        return promptStore.prompts.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.prompt.localizedCaseInsensitiveContains(query)
        }
    }

    private var canAddPrompt: Bool {
        promptStore.prompts.count < SavedPromptStore.maxPrompts
    }

    private func duplicatePrompt(_ prompt: SavedPrompt) {
        guard promptStore.duplicate(id: prompt.id) else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            UIAccessibility.post(
                notification: .announcement,
                argument: String(localized: "Prompt library is full. Delete a prompt to make room.")
            )
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(
            notification: .announcement,
            argument: String(localized: "Prompt duplicated")
        )
    }

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
                ToolbarItemGroup(placement: .primaryAction) {
                    if !promptStore.prompts.isEmpty {
                        EditButton()
                    }

                    Button {
                        isAddSheetPresented = true
                    } label: {
                        // Title + symbol: the title shows if a side bar
                        // (iPhone Duo) moves the item into overflow.
                        Label(String(localized: "Add prompt"), systemImage: "plus")
                    }
                    .disabled(promptStore.prompts.count >= SavedPromptStore.maxPrompts)
                }
            }
        }
        .sheet(isPresented: $isAddSheetPresented) {
            PromptEditorSheet(existingPrompt: nil) { name, prompt in
                guard promptStore.add(name: name, prompt: prompt) else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                UIAccessibility.post(
                    notification: .announcement,
                    argument: String(localized: "Prompt saved")
                )
            }
        }
        .sheet(item: $editingPrompt) { prompt in
            PromptEditorSheet(existingPrompt: prompt) { name, newPrompt in
                promptStore.update(id: prompt.id, name: name, prompt: newPrompt)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                UIAccessibility.post(
                    notification: .announcement,
                    argument: String(localized: "Prompt updated")
                )
            }
        }
        .sheet(item: $upgradeFeature) { feature in
            UpgradeView(feature: feature) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    isAddSheetPresented = true
                }
            }
                .environment(monetizationManager)
        }
        .confirmationDialog(
            String(localized: "Delete Prompt?"),
            isPresented: Binding(
                get: { promptPendingDeletion != nil },
                set: { if !$0 { promptPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: promptPendingDeletion
        ) { prompt in
            Button(String(localized: "Delete"), role: .destructive) {
                promptStore.delete(id: prompt.id)
                promptPendingDeletion = nil
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                UIAccessibility.post(
                    notification: .announcement,
                    argument: String(localized: "Prompt deleted")
                )
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                promptPendingDeletion = nil
            }
        } message: { prompt in
            Text(
                String(
                    format: String(localized: "“%@” will be permanently removed.", defaultValue: "“%@” will be permanently removed."),
                    prompt.name
                )
            )
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
                        ForEach(visiblePrompts) { prompt in
                            promptRow(prompt)
                                // Reordering a filtered list would move the
                                // wrong rows, so drag-to-reorder only works
                                // unfiltered.
                                .moveDisabled(isSearching)
                        }
                        .onDelete { offsets in
                            guard let index = offsets.first,
                                  visiblePrompts.indices.contains(index) else { return }
                            promptPendingDeletion = visiblePrompts[index]
                        }
                        .onMove { from, to in
                            guard !isSearching else { return }
                            promptStore.move(fromOffsets: from, toOffset: to)
                        }
                    } footer: {
                        let count = promptStore.prompts.count
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(count)/\(SavedPromptStore.maxPrompts) prompts")
                            if count >= SavedPromptStore.maxPrompts {
                                Text(String(localized: "Delete a prompt to make room for a new one."))
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.adaptiveCard)
                }
                .paperList()
                .listStyle(.insetGrouped)
                .searchable(text: $searchText, prompt: Text(String(localized: "Search prompts")))
                .overlay {
                    if isSearching && visiblePrompts.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            }
        }
    }

    private func promptRow(_ prompt: SavedPrompt) -> some View {
        let isActive = activeSystemPrompt == prompt.prompt
        return Button {
            Self.selectionHaptic.selectionChanged()
            withAnimation(reduceMotion ? nil : .spring(response: 0.3)) {
                activeSystemPrompt = prompt.prompt
            }
            UIAccessibility.post(
                notification: .announcement,
                argument: String(
                    format: String(localized: "%@ is now active", defaultValue: "%@ is now active"),
                    prompt.name
                )
            )
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isActive ? Color.brandAccent.opacity(0.12) : Color.adaptive(white: 0.9))
                        .frame(width: 44, height: 44)
                    Image(systemName: isActive ? "checkmark.circle.fill" : "books.vertical.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isActive ? .brandAccent : .secondary)
                        .accessibilityHidden(true)
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
                        .foregroundStyle(.brandAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.brandAccent.opacity(0.1), in: Capsule())
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(prompt.name)
        .accessibilityValue(isActive ? String(localized: "Active") : String(localized: "Not active"))
        .accessibilityHint(String(localized: "Activates this prompt."))
        .swipeActions(edge: .leading) {
            Button {
                editingPrompt = prompt
            } label: {
                Label(String(localized: "Edit"), systemImage: "pencil")
            }
            .tint(.brandAccent)

            Button {
                duplicatePrompt(prompt)
            } label: {
                Label(String(localized: "Duplicate"), systemImage: "plus.square.on.square")
            }
            .tint(.brandAccent)
            .disabled(!canAddPrompt)
        }
        .contextMenu {
            Button {
                editingPrompt = prompt
            } label: {
                Label(String(localized: "Edit"), systemImage: "pencil")
            }
            Button {
                duplicatePrompt(prompt)
            } label: {
                Label(String(localized: "Duplicate"), systemImage: "plus.square.on.square")
            }
            .disabled(!canAddPrompt)
            Button(role: .destructive) {
                promptPendingDeletion = prompt
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            AppLottieView(animation: .bookmarkPop, loops: false, tint: .brandAccent)
                .frame(width: 48, height: 48)

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
                    .background(Color.brandAccent)
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
                    LinearGradient(colors: [.brandAccent, .brandAccentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text(String(localized: "Prompt Library"))
                    .font(.display(.title2, weight: .bold))
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
                        LinearGradient(colors: [.brandAccent, .brandAccentDeep], startPoint: .leading, endPoint: .trailing)
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
                .listRowBackground(Color.adaptiveCard)

                Section {
                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(minHeight: 160)
                        .overlay(alignment: .topLeading) {
                            if prompt.isEmpty {
                                Text(String(localized: "e.g. You are a concise coding assistant. Answer with short examples."))
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                } header: {
                    Text(String(localized: "System Prompt"))
                } footer: {
                    Text(String(localized: "This text will be sent as the AI's instructions at the start of each conversation."))
                }
                .listRowBackground(Color.adaptiveCard)
            }
            .paperList()
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
