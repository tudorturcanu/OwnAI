//
//  SavedPromptStore.swift
//  LocalAI
//

import Foundation

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
        guard !trimmedPrompt.isEmpty else { return }

        prompts[index].name = trimmedName.isEmpty ? String(localized: "Untitled Prompt") : trimmedName
        prompts[index].prompt = trimmedPrompt
        persist()
    }

    func delete(id: UUID) {
        prompts.removeAll { $0.id == id }
        persist()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        let movingPrompts = fromOffsets.map { prompts[$0] }
        for index in fromOffsets.sorted(by: >) {
            prompts.remove(at: index)
        }
        let adjustedDestination = toOffset - fromOffsets.filter { $0 < toOffset }.count
        prompts.insert(contentsOf: movingPrompts, at: adjustedDestination)
        persist()
    }

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
