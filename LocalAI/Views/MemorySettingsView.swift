import SwiftUI

/// Shows and manages the assistant's cross-chat memory. Everything listed
/// here lives only on this device; deleting a fact removes it immediately
/// from future conversations.
struct MemorySettingsView: View {
    @Environment(AssistantMemoryStore.self) private var memoryStore
    @State private var showClearConfirm = false
    @State private var editingFact: AssistantMemoryStore.Fact?
    @State private var editText = ""
    @State private var isAddNotePresented = false
    @State private var addText = ""

    private static let noteLengthRange = 6...160

    private func isValidNote(_ text: String) -> Bool {
        Self.noteLengthRange.contains(text.trimmingCharacters(in: .whitespacesAndNewlines).count)
    }

    var body: some View {
        @Bindable var memoryStore = memoryStore

        List {
            Section {
                Toggle(String(localized: "Remember things about me"), isOn: $memoryStore.isEnabled)
            } footer: {
                Text(String(localized: "Memory is off by default. If you enable it, Own AI stores only your name or details you explicitly ask it to remember. Notes stay on this device and never leave it."))
            }
            .listRowBackground(Color.adaptiveCard)

            if memoryStore.isEnabled || !memoryStore.facts.isEmpty {
                Section {
                    if memoryStore.facts.isEmpty {
                        Text(String(localized: "Nothing remembered yet. Notes appear here as you chat, or add one yourself."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(memoryStore.facts) { fact in
                            Button {
                                editText = fact.text
                                editingFact = fact
                            } label: {
                                Text(fact.text)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .onDelete { offsets in
                            for offset in offsets {
                                memoryStore.remove(memoryStore.facts[offset])
                            }
                        }
                    }

                    if memoryStore.isEnabled {
                        Button {
                            addText = ""
                            isAddNotePresented = true
                        } label: {
                            Label(String(localized: "Add a Note"), systemImage: "plus")
                                .font(.subheadline)
                        }
                    }
                } header: {
                    Text(String(localized: "Remembered"))
                } footer: {
                    Text(String(localized: "Tap a note to edit it. Swipe to remove it.") + " " + String(format: String(localized: "Own AI keeps the %lld most recent notes; older ones are dropped.", defaultValue: "Own AI keeps the %lld most recent notes; older ones are dropped."), Int64(AssistantMemoryStore.maxFacts)))
                }
                .listRowBackground(Color.adaptiveCard)

                if !memoryStore.facts.isEmpty {
                    Section {
                        Button(String(localized: "Forget Everything"), role: .destructive) {
                            showClearConfirm = true
                        }
                    }
                    .listRowBackground(Color.adaptiveCard)
                }
            }
        }
        .paperList()
        .navigationTitle(String(localized: "Memory"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            String(localized: "Forget Everything?"),
            isPresented: $showClearConfirm
        ) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Forget Everything"), role: .destructive) {
                memoryStore.clear()
            }
        } message: {
            Text(String(localized: "Forget everything Own AI remembers about you?"))
        }
        .alert(
            String(localized: "Edit Note"),
            isPresented: Binding(
                get: { editingFact != nil },
                set: { if !$0 { editingFact = nil } }
            )
        ) {
            TextField(String(localized: "Note"), text: $editText)
            Button(String(localized: "Cancel"), role: .cancel) {
                editingFact = nil
            }
            Button(String(localized: "Save")) {
                guard let fact = editingFact else { return }
                memoryStore.update(fact, to: editText)
                editingFact = nil
            }
            .disabled(!isValidNote(editText))
        } message: {
            Text(String(localized: "Notes must be between 6 and 160 characters."))
        }
        .alert(
            String(localized: "Add a Note"),
            isPresented: $isAddNotePresented
        ) {
            TextField(String(localized: "Something Own AI should remember"), text: $addText)
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Save")) {
                memoryStore.add([addText])
            }
            .disabled(!isValidNote(addText))
        } message: {
            Text(String(localized: "Notes must be between 6 and 160 characters."))
        }
    }
}

#Preview {
    NavigationStack {
        MemorySettingsView()
    }
    .environment(AssistantMemoryStore())
}
