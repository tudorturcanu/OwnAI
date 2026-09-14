import SwiftUI

/// Shows what Own AI carries forward from a single conversation: the rolling
/// continuity summary written when older turns are condensed away. The user
/// can read it and reset it — the correction mechanism for the times a small
/// model summarizes badly.
struct ConversationMemoryView: View {
    @Environment(ChatHistoryManager.self) private var historyManager
    @Environment(\.dismiss) private var dismiss

    let conversationID: UUID

    @State private var showResetConfirm = false

    private var summary: String? {
        let trimmed = historyManager.conversation(id: conversationID)?
            .rollingSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let summary {
                        Text(summary)
                            .font(.subheadline)
                            .textSelection(.enabled)
                    } else {
                        Text(String(localized: "No summary yet. One is written automatically when a long chat no longer fits the model's memory, so it can keep the thread."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(String(localized: "Chat Summary"))
                } footer: {
                    Text(String(localized: "Own AI uses this summary silently to stay consistent in long chats. It stays on this device."))
                }
                .listRowBackground(Color.adaptiveCard)

                if summary != nil {
                    Section {
                        Button(String(localized: "Reset Summary"), role: .destructive) {
                            showResetConfirm = true
                        }
                    } footer: {
                        Text(String(localized: "New replies will rely on the visible messages only, until a new summary is written."))
                    }
                    .listRowBackground(Color.adaptiveCard)
                }
            }
            .paperList()
            .navigationTitle(String(localized: "Chat Memory"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton { dismiss() }
                }
            }
            .alert(
                String(localized: "Reset Summary?"),
                isPresented: $showResetConfirm
            ) {
                Button(String(localized: "Cancel"), role: .cancel) {}
                Button(String(localized: "Reset Summary"), role: .destructive) {
                    historyManager.clearRollingSummary(for: conversationID)
                }
            } message: {
                Text(String(localized: "Own AI will forget what it summarized from the earlier part of this chat."))
            }
        }
    }
}

#Preview {
    ConversationMemoryView(conversationID: UUID())
        .environment(ChatHistoryManager())
}
