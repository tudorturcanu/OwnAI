import SwiftUI

/// Shows and manages the assistant's cross-chat memory. Everything listed
/// here lives only on this device; deleting a fact removes it immediately
/// from future conversations.
struct MemorySettingsView: View {
    @Environment(AssistantMemoryStore.self) private var memoryStore
    @State private var showClearConfirm = false

    var body: some View {
        @Bindable var memoryStore = memoryStore

        List {
            Section {
                Toggle(String(localized: "Remember things about me"), isOn: $memoryStore.isEnabled)
            } footer: {
                Text(String(localized: "Own AI keeps short notes about you — like your name, preferences, and projects — so new chats can pick up where you left off. Notes are extracted on-device, stored only on this device, and never leave it."))
            }

            if memoryStore.isEnabled {
                Section {
                    if memoryStore.facts.isEmpty {
                        Text(String(localized: "Nothing remembered yet. Notes appear here as you chat."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(memoryStore.facts) { fact in
                            Text(fact.text)
                                .font(.subheadline)
                        }
                        .onDelete { offsets in
                            for offset in offsets {
                                memoryStore.remove(memoryStore.facts[offset])
                            }
                        }
                    }
                } header: {
                    Text(String(localized: "Remembered"))
                }

                if !memoryStore.facts.isEmpty {
                    Section {
                        Button(String(localized: "Forget Everything"), role: .destructive) {
                            showClearConfirm = true
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Memory"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            String(localized: "Forget everything Own AI remembers about you?"),
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Forget Everything"), role: .destructive) {
                memoryStore.clear()
            }
        }
    }
}

#Preview {
    NavigationStack {
        MemorySettingsView()
    }
    .environment(AssistantMemoryStore())
}
