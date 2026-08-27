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
    let sections: [DocumentSection]
    let extractedPages: Int
    let totalPages: Int
    let fileSize: Int64
    let isTrimmed: Bool
    let textOrigin: DocumentTextOrigin
    let ocrQuality: DocumentExtractionQuality
    let createdAt: Date
    let sourceURL: URL?
    /// Name of the copy of the original file kept inside the app's own storage,
    /// or nil for documents imported before originals were retained. The picked
    /// `sourceURL` is security-scoped and unusable once import ends, so this is
    /// the only handle that can reopen the real file later.
    let storedFileName: String?

    init(
        id: UUID = UUID(),
        name: String,
        content: String,
        sections: [DocumentSection] = [],
        extractedPages: Int,
        totalPages: Int,
        fileSize: Int64,
        isTrimmed: Bool = false,
        textOrigin: DocumentTextOrigin = .native,
        ocrQuality: DocumentExtractionQuality = .normal,
        createdAt: Date = Date(),
        sourceURL: URL?,
        storedFileName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.sections = sections
        self.extractedPages = extractedPages
        self.totalPages = totalPages
        self.fileSize = fileSize
        self.isTrimmed = isTrimmed
        self.textOrigin = textOrigin
        self.ocrQuality = ocrQuality
        self.createdAt = createdAt
        self.sourceURL = sourceURL
        self.storedFileName = storedFileName
    }

    init(from attachedDocument: AttachedDocument, maxCharacters: Int) {
        let normalizedContent = attachedDocument.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = String(normalizedContent.prefix(maxCharacters))
        let trimmedSections: [DocumentSection] = attachedDocument.sections.compactMap { section -> DocumentSection? in
            let upperBound = min(trimmedContent.count, section.upperBound)
            let lowerBound = min(section.lowerBound, upperBound)
            guard upperBound > lowerBound else { return nil }
            return DocumentSection(title: section.title, lowerBound: lowerBound, upperBound: upperBound)
        }
        self.init(
            name: attachedDocument.name,
            content: trimmedContent,
            sections: trimmedSections,
            extractedPages: attachedDocument.extractedPages,
            totalPages: attachedDocument.totalPages,
            fileSize: attachedDocument.fileSize,
            isTrimmed: normalizedContent.count > maxCharacters || attachedDocument.isTrimmed,
            textOrigin: attachedDocument.textOrigin,
            ocrQuality: attachedDocument.ocrQuality,
            sourceURL: attachedDocument.url.isFileURL ? attachedDocument.url : nil,
            storedFileName: attachedDocument.storedFileName
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case content
        case sections
        case extractedPages
        case totalPages
        case fileSize
        case isTrimmed
        case textOrigin
        case ocrQuality
        case createdAt
        case sourceURL
        case storedFileName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        content = try container.decode(String.self, forKey: .content)
        sections = try container.decodeIfPresent([DocumentSection].self, forKey: .sections) ?? []
        extractedPages = try container.decode(Int.self, forKey: .extractedPages)
        totalPages = try container.decode(Int.self, forKey: .totalPages)
        fileSize = try container.decode(Int64.self, forKey: .fileSize)
        isTrimmed = try container.decodeIfPresent(Bool.self, forKey: .isTrimmed) ?? false
        textOrigin = try container.decodeIfPresent(DocumentTextOrigin.self, forKey: .textOrigin) ?? .native
        ocrQuality = try container.decodeIfPresent(DocumentExtractionQuality.self, forKey: .ocrQuality) ?? .normal
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        sourceURL = try container.decodeIfPresent(URL.self, forKey: .sourceURL)
        // Absent for documents stored before originals were retained: those keep
        // working as text-only, they simply cannot open the source file.
        storedFileName = try container.decodeIfPresent(String.self, forKey: .storedFileName)
    }

    var iconName: String {
        let ext = sourceURL?.pathExtension.lowercased() ?? name.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        switch ext {
        case "pdf": return "doc.richtext.fill"
        case "rtf", "rtfd": return "doc.richtext"
        case "doc", "docx": return "doc.text.fill"
        default: return "doc.plaintext"
        }
    }

    var pageInfo: String? {
        guard totalPages > 0 else { return nil }
        if extractedPages < totalPages {
            return "Pages 1–\(extractedPages) of \(totalPages)"
        }
        return "All \(totalPages) page\(totalPages == 1 ? "" : "s")"
    }

    var ocrWarningText: String? {
        ocrQuality.warningText
    }
}
