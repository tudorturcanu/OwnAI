//
//  ConversationDocument.swift
//  LocalAI
//
//  Created by Codex on 15.03.2026.
//

import Foundation

struct ConversationDocument: Identifiable, Equatable, Codable {
    let id: UUID
    let name: String
    let content: String
    let extractedPages: Int
    let totalPages: Int
    let fileSize: Int64
    let isTrimmed: Bool
    let createdAt: Date
    let sourceURL: URL?

    init(
        id: UUID = UUID(),
        name: String,
        content: String,
        extractedPages: Int,
        totalPages: Int,
        fileSize: Int64,
        isTrimmed: Bool = false,
        createdAt: Date = Date(),
        sourceURL: URL?
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.extractedPages = extractedPages
        self.totalPages = totalPages
        self.fileSize = fileSize
        self.isTrimmed = isTrimmed
        self.createdAt = createdAt
        self.sourceURL = sourceURL
    }

    init(from attachedDocument: AttachedDocument, maxCharacters: Int) {
        let normalizedContent = attachedDocument.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = String(normalizedContent.prefix(maxCharacters))
        self.init(
            name: attachedDocument.name,
            content: trimmedContent,
            extractedPages: attachedDocument.extractedPages,
            totalPages: attachedDocument.totalPages,
            fileSize: attachedDocument.fileSize,
            isTrimmed: normalizedContent.count > maxCharacters || attachedDocument.isTrimmed,
            sourceURL: attachedDocument.url.isFileURL ? attachedDocument.url : nil
        )
    }
}
