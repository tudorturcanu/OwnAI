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

    var extractionProgress: Double = 0
    var documentsByConversationID: [UUID: [ConversationDocument]] = [:]

    private let ragEngine = RAGEngine.shared

    private init() {
        loadPersistedDocuments()
        removeLegacyLibraryIfNeeded()
        Task {
            await reindexAllDocuments()
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
            extractedPages: extraction.extractedPages,
            totalPages: extraction.totalPages,
            fileSize: fileSize,
            isTrimmed: extraction.text.count > Self.maxStoredCharacters
        )
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
            savePersistedDocuments()
            await ragEngine.clear(documentID: existing.id, conversationID: conversationID)
            await ragEngine.ingest(text: existing.content, documentID: existing.id, conversationID: conversationID)
            return
        }

        documents.insert(document, at: 0)
        documentsByConversationID[conversationID] = documents
        savePersistedDocuments()
        await ragEngine.ingest(text: document.content, documentID: document.id, conversationID: conversationID)
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
            let data = try Data(contentsOf: documentsURL)
            let persistedEntries = try JSONDecoder().decode([PersistedConversationDocuments].self, from: data)
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
            let data = try JSONEncoder().encode(entries)
            try data.write(to: documentsURL, options: .atomic)
        } catch {
            print("Failed to save conversation documents: \(error)")
        }
    }

    private func reindexAllDocuments() async {
        await ragEngine.clearAll()
        for (conversationID, documents) in documentsByConversationID {
            for document in documents {
                await ragEngine.ingest(
                    text: document.content,
                    documentID: document.id,
                    conversationID: conversationID
                )
            }
        }
    }

    nonisolated
    private static func extractContent(
        at url: URL,
        fileExtension: String
    ) throws -> (text: String, extractedPages: Int, totalPages: Int) {
        return switch fileExtension {
        case "pdf":
            try extractTextFromPDF(at: url)
        case "rtf", "rtfd":
            (try extractTextFromRTF(at: url), 0, 0)
        case "doc", "docx":
            (try extractTextFromWord(at: url), 0, 0)
        default:
            (try String(contentsOf: url, encoding: .utf8), 0, 0)
        }
    }
    
    nonisolated
    private static func extractTextFromPDF(at url: URL) throws -> (text: String, extractedPages: Int, totalPages: Int) {
        guard let pdfDocument = PDFDocument(url: url) else {
            throw DocumentError.extractionFailed
        }
        
        let totalPages = pdfDocument.pageCount
        let pagesToExtract = min(totalPages, Self.maxPages)
        var fullText = ""
        
        for i in 0..<pagesToExtract {
            if let page = pdfDocument.page(at: i), let pageText = page.string {
                fullText += pageText + "\n"
            }
        }
        
        return (fullText.trimmingCharacters(in: .whitespacesAndNewlines), pagesToExtract, totalPages)
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
}

private struct PersistedConversationDocuments: Codable {
    let conversationID: UUID
    let documents: [ConversationDocument]
}
