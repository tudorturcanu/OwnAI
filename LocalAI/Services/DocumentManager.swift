//
//  DocumentManager.swift
//  LocalAI
//
//  Created by Tudor on 31.01.2026.
//

import Foundation
import PDFKit
import UniformTypeIdentifiers

struct AttachedDocument: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let content: String
    let sections: [DocumentSection]
    let extractedPages: Int
    let totalPages: Int
    let fileSize: Int64
    let isTrimmed: Bool
    
    var name: String {
        url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
    }
    
    /// Human-readable page info, e.g. "Pages 1–5 of 42" or "All 3 pages"
    var pageInfo: String? {
        guard totalPages > 0 else { return nil }
        if extractedPages < totalPages {
            return "Pages 1–\(extractedPages) of \(totalPages)"
        }
        return "All \(totalPages) page\(totalPages == 1 ? "" : "s")"
    }
    
    /// Human-readable file size, e.g. "1.2 MB"
    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var storageNote: String? {
        isTrimmed ? "Only for this chat, trimmed locally" : "Only for this chat"
    }
    
    /// File type icon name
    var iconName: String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext.fill"
        case "rtf", "rtfd": return "doc.richtext"
        case "doc", "docx": return "doc.text.fill"
        default: return "doc.plaintext"
        }
    }
}

enum DocumentError: LocalizedError {
    case fileAccessFailed
    case extractionFailed
    case emptyDocument
    case unsupportedFormat
    
    var errorDescription: String? {
        switch self {
        case .fileAccessFailed: return "Could not access the selected file."
        case .extractionFailed: return "Could not extract text from the file."
        case .emptyDocument: return "No text could be extracted. This may be a scanned document without a text layer."
        case .unsupportedFormat: return "This file format is not supported."
        }
    }
}

@MainActor
@Observable
final class DocumentManager {
    static let shared = DocumentManager()
    static let maxStoredCharacters = 20_000
    private static let maxPersistedCorpusBytes: Int64 = 1_073_741_824
    private static let reclaimBytesOnOverflow: Int64 = 734_003_200

    var extractionProgress: Double = 0
    var documentsByConversationID: [UUID: [ConversationDocument]] = [:]

    private let ragEngine = RAGEngine.shared

    private init() {
        loadPersistedDocuments()
        removeLegacyLibraryIfNeeded()
        if enforceStorageBudget() {
            savePersistedDocuments()
        }
        Task {
            let restored = await ragEngine.restoreIndexIfCurrent(with: indexedDocumentSnapshots)
            if !restored {
                await reindexAllDocuments()
            }
        }
    }

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("conversation_documents.json")
    }
    
    func processFile(at url: URL) async throws -> AttachedDocument {
        // Start accessing security scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            throw DocumentError.fileAccessFailed
        }
        
        defer {
            url.stopAccessingSecurityScopedResource()
        }
        
        // Get file size
        let fileSize: Int64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        } else {
            fileSize = 0
        }
        
        extractionProgress = 0.1
        
        let ext = url.pathExtension.lowercased()
        let attachedDocument = try await MemoryProfiler.measure("DocumentManager.processFile(\(url.lastPathComponent))") {
            let extraction = try await Task.detached(priority: .userInitiated) {
                try Self.extractContent(at: url, fileExtension: ext)
            }.value
            
            extractionProgress = 0.9
            
            // Check for empty content
            guard !extraction.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                extractionProgress = 0
                throw DocumentError.emptyDocument
            }
            
            extractionProgress = 1.0
            
            // Small delay so the user sees the completed progress
            try? await Task.sleep(for: .milliseconds(200))
            extractionProgress = 0
            
            return AttachedDocument(
                url: url,
                content: extraction.text,
                sections: extraction.sections,
                extractedPages: extraction.extractedPages,
                totalPages: extraction.totalPages,
                fileSize: fileSize,
                isTrimmed: extraction.text.count > Self.maxStoredCharacters
            )
        }
        
        return attachedDocument
    }

    func documents(for conversationID: UUID?) -> [ConversationDocument] {
        guard let conversationID else { return [] }
        return documentsByConversationID[conversationID] ?? []
    }

    func hasDocuments(in conversationID: UUID?) -> Bool {
        !documents(for: conversationID).isEmpty
    }

    var totalStoredDocumentCount: Int {
        documentsByConversationID.values.reduce(0) { $0 + $1.count }
    }

    var totalStoredDocumentBytes: Int64 {
        documentsByConversationID.values
            .flatMap { $0 }
            .reduce(into: Int64(0)) { partialResult, document in
                partialResult += Int64(document.content.lengthOfBytes(using: .utf8))
            }
    }

    func addDocumentToConversation(from attachedDocument: AttachedDocument, conversationID: UUID) async {
        let document = ConversationDocument(from: attachedDocument, maxCharacters: Self.maxStoredCharacters)
        guard !document.content.isEmpty else { return }

        var documents = documentsByConversationID[conversationID] ?? []
        if let existingIndex = documents.firstIndex(where: {
            $0.name == document.name && $0.content == document.content
        }) {
            let existing = documents.remove(at: existingIndex)
            documents.insert(existing, at: 0)
            documentsByConversationID[conversationID] = documents
            let pruned = enforceStorageBudget(keeping: existing.id)
            savePersistedDocuments()
            if pruned {
                await reindexAllDocuments()
            } else {
                await ragEngine.clear(documentID: existing.id, conversationID: conversationID)
                await ragEngine.ingest(
                    text: existing.content,
                    sections: existing.sections,
                    documentID: existing.id,
                    conversationID: conversationID
                )
            }
            return
        }

        documents.insert(document, at: 0)
        documentsByConversationID[conversationID] = documents
        let pruned = enforceStorageBudget(keeping: document.id)
        savePersistedDocuments()
        if pruned {
            await reindexAllDocuments()
        } else {
            await ragEngine.ingest(
                text: document.content,
                sections: document.sections,
                documentID: document.id,
                conversationID: conversationID
            )
        }
    }

    func removeDocument(id: UUID, from conversationID: UUID) {
        guard var documents = documentsByConversationID[conversationID] else { return }
        documents.removeAll { $0.id == id }
        if documents.isEmpty {
            documentsByConversationID.removeValue(forKey: conversationID)
        } else {
            documentsByConversationID[conversationID] = documents
        }
        savePersistedDocuments()
        Task {
            await ragEngine.clear(documentID: id, conversationID: conversationID)
        }
    }

    func clearDocuments(for conversationID: UUID) {
        documentsByConversationID.removeValue(forKey: conversationID)
        savePersistedDocuments()
        Task {
            await ragEngine.clearConversation(conversationID)
        }
    }

    func clearAllDocuments() {
        documentsByConversationID.removeAll()
        savePersistedDocuments()
        Task {
            await ragEngine.clearAll()
        }
    }

    func retrieveRelevantSnippets(
        for query: String,
        conversationID: UUID,
        limit: Int = 3
    ) async -> [(document: ConversationDocument, chunk: RetrievedChunk)] {
        let retrieved = await ragEngine.retrieveDetailed(query: query, limit: limit, conversationID: conversationID)
        let documents = documentsByConversationID[conversationID] ?? []
        return retrieved.compactMap { chunk in
            guard let document = documents.first(where: { $0.id == chunk.documentID }) else {
                return nil
            }
            return (document: document, chunk: chunk)
        }
    }
    
    // MARK: - Extractors
    
    private static let maxPages = 5

    private func removeLegacyLibraryIfNeeded() {
        let legacyURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("saved_documents.json")
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }

    private func loadPersistedDocuments() {
        do {
            let persistedEntries = try SecureFileStore.load([PersistedConversationDocuments].self, from: documentsURL)
            documentsByConversationID = Dictionary(uniqueKeysWithValues: persistedEntries.map {
                ($0.conversationID, $0.documents)
            })
        } catch {
            documentsByConversationID = [:]
        }
    }

    private func savePersistedDocuments() {
        do {
            let entries = documentsByConversationID.map { conversationID, documents in
                PersistedConversationDocuments(conversationID: conversationID, documents: documents)
            }
            try SecureFileStore.save(entries, to: documentsURL)
        } catch {
            print("Failed to save conversation documents: \(error)")
        }
    }

    private func reindexAllDocuments() async {
        await ragEngine.rebuildIndex(from: indexedDocumentSnapshots)
    }

    private var indexedDocumentSnapshots: [RAGEngine.IndexedDocumentSnapshot] {
        documentsByConversationID.flatMap { conversationID, documents in
            documents.map { document in
                RAGEngine.IndexedDocumentSnapshot(
                    conversationID: conversationID,
                    documentID: document.id,
                    content: document.content,
                    sections: document.sections
                )
            }
        }
    }

    private func enforceStorageBudget(keeping protectedDocumentID: UUID? = nil) -> Bool {
        var currentTotal = totalStoredDocumentBytes
        guard currentTotal > Self.maxPersistedCorpusBytes else { return false }

        struct Candidate {
            let conversationID: UUID
            let documentID: UUID
            let createdAt: Date
            let byteCount: Int64
            let isProtected: Bool
        }

        var candidates = documentsByConversationID.flatMap { conversationID, documents in
            documents.map { document in
                Candidate(
                    conversationID: conversationID,
                    documentID: document.id,
                    createdAt: document.createdAt,
                    byteCount: Int64(document.content.lengthOfBytes(using: .utf8)),
                    isProtected: document.id == protectedDocumentID
                )
            }
        }

        candidates.sort {
            if $0.isProtected != $1.isProtected {
                return !$0.isProtected && $1.isProtected
            }
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.documentID.uuidString < $1.documentID.uuidString
        }

        var reclaimedBytes: Int64 = 0
        var removedDocumentIDsByConversation: [UUID: Set<UUID>] = [:]

        for candidate in candidates {
            if candidate.isProtected && currentTotal <= Self.maxPersistedCorpusBytes {
                continue
            }

            removedDocumentIDsByConversation[candidate.conversationID, default: []].insert(candidate.documentID)
            reclaimedBytes += candidate.byteCount
            currentTotal -= candidate.byteCount

            if reclaimedBytes >= Self.reclaimBytesOnOverflow {
                break
            }
        }

        guard !removedDocumentIDsByConversation.isEmpty else { return false }

        for (conversationID, removedIDs) in removedDocumentIDsByConversation {
            guard var documents = documentsByConversationID[conversationID] else { continue }
            documents.removeAll { removedIDs.contains($0.id) }
            if documents.isEmpty {
                documentsByConversationID.removeValue(forKey: conversationID)
            } else {
                documentsByConversationID[conversationID] = documents
            }
        }

        return true
    }

    nonisolated
    private static func extractContent(
        at url: URL,
        fileExtension: String
    ) throws -> (text: String, sections: [DocumentSection], extractedPages: Int, totalPages: Int) {
        return switch fileExtension {
        case "pdf":
            try extractTextFromPDF(at: url)
        case "rtf", "rtfd":
            genericSectionedText(try extractTextFromRTF(at: url))
        case "doc", "docx":
            genericSectionedText(try extractTextFromWord(at: url))
        default:
            genericSectionedText(try String(contentsOf: url, encoding: .utf8))
        }
    }
    
    nonisolated
    private static func extractTextFromPDF(at url: URL) throws -> (text: String, sections: [DocumentSection], extractedPages: Int, totalPages: Int) {
        guard let pdfDocument = PDFDocument(url: url) else {
            throw DocumentError.extractionFailed
        }
        
        let totalPages = pdfDocument.pageCount
        let pagesToExtract = min(totalPages, Self.maxPages)
        var fullText = ""
        var sections: [DocumentSection] = []
        
        for i in 0..<pagesToExtract {
            if let page = pdfDocument.page(at: i), let pageText = page.string {
                let normalizedPageText = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedPageText.isEmpty else { continue }
                let startOffset = fullText.count
                if !fullText.isEmpty {
                    fullText += "\n\n"
                }
                let sectionStart = fullText.count
                fullText += normalizedPageText
                let sectionEnd = fullText.count
                sections.append(
                    DocumentSection(
                        title: "Page \(i + 1)",
                        lowerBound: sectionStart,
                        upperBound: sectionEnd
                    )
                )
            }
        }

        let normalized = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let adjustedSections = normalizedSections(for: normalized, originalText: fullText, sections: sections)
        return (normalized, adjustedSections, pagesToExtract, totalPages)
    }
    
    nonisolated
    private static func extractTextFromRTF(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else {
            // Try RTFD
            guard let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtfd],
                documentAttributes: nil
            ) else {
                throw DocumentError.extractionFailed
            }
            return attributed.string
        }
        
        return attributed.string
    }
    
    nonisolated
    private static func extractTextFromWord(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        
        // NSAttributedString can handle .docx files via the .docFormat option
        // For .docx (Office Open XML), try reading as HTML-like format
        if let attributed = try? NSAttributedString(
            data: data,
            options: [:],
            documentAttributes: nil
        ) {
            let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }
        
        throw DocumentError.extractionFailed
    }

    nonisolated
    private static func genericSectionedText(_ text: String) -> (text: String, sections: [DocumentSection], extractedPages: Int, totalPages: Int) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return ("", [], 0, 0)
        }
        return (
            normalized,
            [DocumentSection(title: "Document", lowerBound: 0, upperBound: normalized.count)],
            0,
            0
        )
    }

    nonisolated
    private static func normalizedSections(
        for normalizedText: String,
        originalText: String,
        sections: [DocumentSection]
    ) -> [DocumentSection] {
        guard !normalizedText.isEmpty, !sections.isEmpty else { return [] }

        let leadingTrimCount = originalText.distance(
            from: originalText.startIndex,
            to: originalText.firstIndex(where: { !$0.isWhitespace && !$0.isNewline }) ?? originalText.endIndex
        )
        let maxIndex = normalizedText.count

        return sections.compactMap { section in
            let lowerBound = max(0, section.lowerBound - leadingTrimCount)
            let upperBound = min(maxIndex, section.upperBound - leadingTrimCount)
            guard upperBound > lowerBound else { return nil }
            return DocumentSection(title: section.title, lowerBound: lowerBound, upperBound: upperBound)
        }
    }
}

private struct PersistedConversationDocuments: Codable {
    let conversationID: UUID
    let documents: [ConversationDocument]
}
