//
//  DocumentManager.swift
//  LocalAI
//
//  Created by Tudor on 31.01.2026.
//

import Foundation
import CoreImage
import PDFKit
import UniformTypeIdentifiers
import Vision
import UIKit

struct AttachedDocument: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let content: String
    let sections: [DocumentSection]
    let extractedPages: Int
    let totalPages: Int
    let fileSize: Int64
    let isTrimmed: Bool
    let textOrigin: DocumentTextOrigin
    let ocrQuality: DocumentExtractionQuality
    
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

    var provenanceText: String? {
        textOrigin.badgeTitle
    }

    var ocrWarningText: String? {
        ocrQuality.warningText
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
    case extractionTimedOut
    case emptyDocument
    case unsupportedFormat
    
    var errorDescription: String? {
        switch self {
        case .fileAccessFailed: return "Could not access the selected file."
        case .extractionFailed: return "Could not extract text from the file."
        case .extractionTimedOut: return "Document extraction took too long and was cancelled. Try a smaller PDF or switch document processing to Fast in Settings."
        case .emptyDocument: return "No text could be extracted. This may be a scanned document without a text layer."
        case .unsupportedFormat: return "This file format is not supported."
        }
    }
}

@MainActor
@Observable
final class DocumentManager {
    static let shared = DocumentManager()
    private static let maxPersistedCorpusBytes: Int64 = 1_073_741_824
    private static let reclaimBytesOnOverflow: Int64 = 734_003_200
    private static let extractionTimeout: Duration = .seconds(30)

    /// Reserved sentinel scope for documents that belong to the persistent,
    /// cross-chat library rather than a single conversation. Real conversation IDs
    /// are random UUIDs, so this fixed value never collides with one. Storing the
    /// library under this key lets it reuse all the per-conversation ingest,
    /// indexing, and persistence machinery for free.
    static let libraryScopeID = UUID(uuidString: "11111111-0000-4000-A000-11111111CAFE") ?? UUID()

    /// UserDefaults key controlling whether the library is searched from every chat.
    static let librarySearchEnabledDefaultsKey = "librarySearchEnabled"

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
        defer {
            extractionProgress = 0
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
        let pdfOCRMode = Self.currentPDFOCRMode()
        let documentProcessingMode = Self.currentDocumentProcessingMode()
        
        let ext = url.pathExtension.lowercased()
        Self.documentDiagnostic("process start file=\(url.lastPathComponent) ext=\(ext) size=\(fileSize) ocrMode=\(pdfOCRMode.rawValue) processingMode=\(documentProcessingMode.rawValue)")

        do {
            let attachedDocument = try await MemoryProfiler.measure("DocumentManager.processFile(\(url.lastPathComponent))") {
                let extractionTask = Task.detached(priority: .userInitiated) {
                    try Self.extractContent(
                        at: url,
                        fileExtension: ext,
                        pdfOCRMode: pdfOCRMode,
                        documentProcessingMode: documentProcessingMode
                    )
                }
                Self.documentDiagnostic("extraction started file=\(url.lastPathComponent) timeoutSeconds=30")
                let extraction = try await Self.valueWithExtractionTimeout(from: extractionTask)

                extractionProgress = 0.9

                // Check for empty content
                guard !extraction.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DocumentError.emptyDocument
                }

                extractionProgress = 1.0

                // Small delay so the user sees the completed progress
                try? await Task.sleep(for: .milliseconds(200))

                return AttachedDocument(
                    url: url,
                    content: extraction.text,
                    sections: extraction.sections,
                    extractedPages: extraction.extractedPages,
                    totalPages: extraction.totalPages,
                    fileSize: fileSize,
                    isTrimmed: extraction.text.count > documentProcessingMode.maxStoredCharacters,
                    textOrigin: extraction.textOrigin,
                    ocrQuality: extraction.ocrQuality
                )
            }

            Self.documentDiagnostic("process success file=\(url.lastPathComponent) chars=\(attachedDocument.content.count) pages=\(attachedDocument.extractedPages)/\(attachedDocument.totalPages)")
            return attachedDocument
        } catch {
            Self.documentDiagnostic("process failed file=\(url.lastPathComponent) error=\(error.localizedDescription)")
            throw error
        }
    }

    nonisolated
    private static func valueWithExtractionTimeout(
        from extractionTask: Task<ExtractionResult, Error>
    ) async throws -> ExtractionResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let race = ExtractionTimeoutRace()

                Task {
                    do {
                        let result = try await extractionTask.value
                        race.resumeOnce {
                            continuation.resume(returning: result)
                        }
                    } catch {
                        race.resumeOnce {
                            continuation.resume(throwing: error)
                        }
                    }
                }

                Task {
                    do {
                        try await Task.sleep(for: extractionTimeout)
                        extractionTask.cancel()
                        Self.documentDiagnostic("extraction timed out timeoutSeconds=30")
                        race.resumeOnce {
                            continuation.resume(throwing: DocumentError.extractionTimedOut)
                        }
                    } catch {
                        // The timer task can be cancelled after extraction wins the race.
                    }
                }
            }
        } onCancel: {
            extractionTask.cancel()
        }
    }

    private final class ExtractionTimeoutRace: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false

        func resumeOnce(_ resume: () -> Void) {
            lock.lock()
            guard !didResume else {
                lock.unlock()
                return
            }
            didResume = true
            lock.unlock()
            resume()
        }
    }

    nonisolated
    private static func documentDiagnostic(_ message: String) {
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

    // MARK: - Library (cross-chat)

    /// Documents in the persistent, cross-chat library.
    var libraryDocuments: [ConversationDocument] {
        documentsByConversationID[Self.libraryScopeID] ?? []
    }

    var hasLibraryDocuments: Bool {
        !libraryDocuments.isEmpty
    }

    /// Whether the library is consulted from every chat. Defaults to on.
    var librarySearchEnabled: Bool {
        if UserDefaults.standard.object(forKey: Self.librarySearchEnabledDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: Self.librarySearchEnabledDefaultsKey)
    }

    func setLibrarySearchEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.librarySearchEnabledDefaultsKey)
    }

    func addDocumentToLibrary(from attachedDocument: AttachedDocument) async {
        await addDocumentToConversation(from: attachedDocument, conversationID: Self.libraryScopeID)
    }

    func removeFromLibrary(id: UUID) {
        removeDocument(id: id, from: Self.libraryScopeID)
    }

    /// Whether answering in `conversationID` should consult any documents — its own
    /// attachments or, when enabled, the shared library.
    func shouldSearchDocuments(in conversationID: UUID?) -> Bool {
        hasDocuments(in: conversationID) || (librarySearchEnabled && hasLibraryDocuments)
    }

    func addDocumentToConversation(from attachedDocument: AttachedDocument, conversationID: UUID) async {
        let maxStoredCharacters = Self.currentDocumentProcessingMode().maxStoredCharacters
        let document = ConversationDocument(from: attachedDocument, maxCharacters: maxStoredCharacters)
        guard !document.content.isEmpty else {
            return
        }


        var documents = documentsByConversationID[conversationID] ?? []
        let keepsSingleChatDocument = conversationID != Self.libraryScopeID
        if let existingIndex = documents.firstIndex(where: {
            $0.name == document.name && $0.content == document.content
        }) {
            let existing = documents.remove(at: existingIndex)
            let replacedDocuments = keepsSingleChatDocument ? documents : []
            if keepsSingleChatDocument {
                documents = [existing]
            } else {
                documents.insert(existing, at: 0)
            }
            documentsByConversationID[conversationID] = documents
            let pruned = enforceStorageBudget(keeping: existing.id)
            savePersistedDocuments()
            if pruned {
                await reindexAllDocuments()
            } else {
                for replacedDocument in replacedDocuments {
                    await ragEngine.clear(documentID: replacedDocument.id, conversationID: conversationID)
                }
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

        let replacedDocuments = keepsSingleChatDocument ? documents : []
        if keepsSingleChatDocument {
            documents = [document]
        } else {
            documents.insert(document, at: 0)
        }
        documentsByConversationID[conversationID] = documents
        let pruned = enforceStorageBudget(keeping: document.id)
        savePersistedDocuments()
        if pruned {
            await reindexAllDocuments()
        } else {
            for replacedDocument in replacedDocuments {
                await ragEngine.clear(documentID: replacedDocument.id, conversationID: conversationID)
            }
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
        var scopes: Set<UUID> = [conversationID]
        if librarySearchEnabled, hasLibraryDocuments {
            scopes.insert(Self.libraryScopeID)
        }

        let retrieved = await ragEngine.retrieveDetailed(query: query, limit: limit, conversationIDs: scopes)
        // Resolve each chunk back to its document from the scope it came from.
        let documents = (documentsByConversationID[conversationID] ?? []) + libraryDocuments
        let resolved: [(document: ConversationDocument, chunk: RetrievedChunk)] = retrieved.compactMap { chunk -> (document: ConversationDocument, chunk: RetrievedChunk)? in
            guard let document = documents.first(where: { $0.id == chunk.documentID }) else {
                return nil
            }
            return (document: document, chunk: chunk)
        }
        return resolved
    }
    
    // MARK: - Extractors
    
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

    private static func debugPreview(_ text: String, maxLength: Int = 180) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxLength else { return normalized }
        return String(normalized.prefix(maxLength)) + "..."
    }

    private func savePersistedDocuments() {
        do {
            let entries = documentsByConversationID.map { conversationID, documents in
                PersistedConversationDocuments(conversationID: conversationID, documents: documents)
            }
            try SecureFileStore.save(entries, to: documentsURL)
        } catch {
        }
    }

    private func reindexAllDocuments() async {
        await ragEngine.rebuildIndex(from: indexedDocumentSnapshots)
    }

    /// Rebuilds the semantic index for all documents using the currently selected
    /// embedding backend. Safe to call after toggling neural embeddings.
    func rebuildSemanticIndex() async {
        await reindexAllDocuments()
    }

    /// Keeps neural embeddings disabled and rebuilds the index with the lightweight backend.
    func setNeuralEmbeddingsEnabled(_ _: Bool) async {
        UserDefaults.standard.set(false, forKey: RAGEngine.neuralEmbeddingsDefaultsKey)
        await EmbeddingService.shared.unload()
        await reindexAllDocuments()
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
        fileExtension: String,
        pdfOCRMode: PDFOCRMode,
        documentProcessingMode: DocumentProcessingMode
    ) throws -> ExtractionResult {
        try Task.checkCancellation()
        return switch fileExtension {
        case "pdf":
            try extractTextFromPDF(
                at: url,
                pdfOCRMode: pdfOCRMode,
                maxPages: documentProcessingMode.maxPDFPages
            )
        case "rtf", "rtfd":
            genericSectionedText(try extractTextFromRTF(at: url))
        case "doc", "docx":
            genericSectionedText(try extractTextFromWord(at: url))
        case "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "webp":
            try extractTextFromImage(at: url)
        case "txt", "text":
            sectionedText(try extractTextFile(at: url), style: .lineRanges)
        case "md", "markdown":
            sectionedText(try extractTextFile(at: url), style: .markdown)
        case "csv", "tsv":
            sectionedText(try extractTextFile(at: url), style: .tabular)
        case "json", "jsonl":
            sectionedText(try extractTextFile(at: url), style: .json)
        case "log":
            sectionedText(try extractTextFile(at: url), style: .log)
        case "swift", "py", "js", "ts", "tsx", "jsx", "java", "kt", "go", "rs", "c", "cc", "cpp", "h", "hpp", "m", "mm", "cs", "rb", "php", "sh", "zsh", "yml", "yaml", "toml", "xml", "html", "css", "sql":
            sectionedText(try extractTextFile(at: url), style: .sourceCode)
        default:
            sectionedText(try extractTextFile(at: url), style: .lineRanges)
        }
    }
    
    nonisolated
    private static func extractTextFromPDF(
        at url: URL,
        pdfOCRMode: PDFOCRMode,
        maxPages: Int
    ) throws -> ExtractionResult {
        try Task.checkCancellation()
        guard let pdfDocument = PDFDocument(url: url) else {
            throw DocumentError.extractionFailed
        }
        
        let totalPages = pdfDocument.pageCount
        let pagesToExtract = min(totalPages, max(1, maxPages))
        var fullText = ""
        var sections: [DocumentSection] = []
        var didUseNativeText = false
        var didUseOCR = false
        var ocrCharacterCount = 0
        
        for i in 0..<pagesToExtract {
            try Task.checkCancellation()
            guard let page = pdfDocument.page(at: i) else { continue }

            let nativeText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            let shouldUseOCR: Bool
            switch pdfOCRMode {
            case .preferNativeText:
                shouldUseOCR = nativeText?.isEmpty ?? true
            case .ocrScannedPages:
                shouldUseOCR = shouldOCRScannedPage(nativeText)
            case .ocrAllPages:
                shouldUseOCR = true
            }

            if !shouldUseOCR, let nativeText, !nativeText.isEmpty {
                append(pageText: nativeText, title: "Page \(i + 1)", to: &fullText, sections: &sections)
                didUseNativeText = true
                continue
            }

            try Task.checkCancellation()
            guard let renderedPage = renderPDFPage(page),
                  let ocrText = try? recognizeText(from: renderedPage).trimmingCharacters(in: .whitespacesAndNewlines),
                  !ocrText.isEmpty else {
                if let nativeText, !nativeText.isEmpty {
                    append(pageText: nativeText, title: "Page \(i + 1)", to: &fullText, sections: &sections)
                    didUseNativeText = true
                }
                continue
            }
            try Task.checkCancellation()

            if shouldUseOCR || nativeText == nil || nativeText?.isEmpty == true {
                append(pageText: ocrText, title: "Page \(i + 1) (OCR)", to: &fullText, sections: &sections)
                didUseOCR = true
                ocrCharacterCount += ocrText.count
            } else if let nativeText, !nativeText.isEmpty {
                append(pageText: nativeText, title: "Page \(i + 1)", to: &fullText, sections: &sections)
                didUseNativeText = true
            }
        }

        let normalized = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let adjustedSections = normalizedSections(for: normalized, originalText: fullText, sections: sections)
        return ExtractionResult(
            text: normalized,
            sections: adjustedSections,
            extractedPages: pagesToExtract,
            totalPages: totalPages,
            textOrigin: provenanceOrigin(didUseNativeText: didUseNativeText, didUseOCR: didUseOCR),
            ocrQuality: ocrQuality(
                didUseOCR: didUseOCR,
                ocrCharacterCount: ocrCharacterCount
            )
        )
    }
    
    nonisolated
    private static func extractTextFromImage(at url: URL) throws -> ExtractionResult {
        try Task.checkCancellation()
        let ocrText = try recognizeText(from: url).trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard !ocrText.isEmpty else {
            throw DocumentError.emptyDocument
        }

        return ExtractionResult(
            text: ocrText,
            sections: [DocumentSection(title: "Image (OCR)", lowerBound: 0, upperBound: ocrText.count)],
            extractedPages: 1,
            totalPages: 1,
            textOrigin: .ocr,
            ocrQuality: ocrQuality(didUseOCR: true, ocrCharacterCount: ocrText.count)
        )
    }
    
    nonisolated
    private static func extractTextFromRTF(at url: URL) throws -> String {
        try Task.checkCancellation()
        let data = try Data(contentsOf: url)
        try Task.checkCancellation()
        
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
        try Task.checkCancellation()
        let data = try Data(contentsOf: url)
        try Task.checkCancellation()
        
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
    private static func genericSectionedText(_ text: String) -> ExtractionResult {
        sectionedText(text, style: .document)
    }

    private enum TextSectioningStyle {
        case document
        case lineRanges
        case markdown
        case tabular
        case json
        case log
        case sourceCode
    }

    private struct TextLine {
        let number: Int
        let text: String
        let lowerBound: Int
        let upperBound: Int
    }

    nonisolated
    private static func extractTextFile(at url: URL) throws -> String {
        try Task.checkCancellation()
        let data = try Data(contentsOf: url)
        try Task.checkCancellation()
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .unicode,
            .isoLatin1,
            .ascii,
            .macOSRoman
        ]

        for encoding in encodings {
            if let text = String(data: data, encoding: encoding),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }

        throw DocumentError.extractionFailed
    }

    nonisolated
    private static func sectionedText(_ text: String, style: TextSectioningStyle) -> ExtractionResult {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return ExtractionResult(text: "", sections: [], extractedPages: 0, totalPages: 0, textOrigin: .native, ocrQuality: .normal)
        }

        let rawSections: [DocumentSection]
        switch style {
        case .document:
            rawSections = [DocumentSection(title: "Document", lowerBound: 0, upperBound: text.count)]
        case .lineRanges:
            rawSections = lineRangeSections(in: text, linesPerSection: 80, titlePrefix: "Lines")
        case .markdown:
            rawSections = markdownSections(in: text)
        case .tabular:
            rawSections = lineRangeSections(in: text, linesPerSection: 60, titlePrefix: "Rows")
        case .json:
            rawSections = lineRangeSections(in: text, linesPerSection: 80, titlePrefix: "JSON lines")
        case .log:
            rawSections = lineRangeSections(in: text, linesPerSection: 120, titlePrefix: "Log lines")
        case .sourceCode:
            rawSections = sourceCodeSections(in: text)
        }

        let adjustedSections = normalizedSections(for: normalized, originalText: text, sections: rawSections)
        return ExtractionResult(
            text: normalized,
            sections: adjustedSections.isEmpty
                ? [DocumentSection(title: "Document", lowerBound: 0, upperBound: normalized.count)]
                : adjustedSections,
            extractedPages: 0,
            totalPages: 0,
            textOrigin: .native,
            ocrQuality: .normal
        )
    }

    nonisolated
    private static func lineRangeSections(
        in text: String,
        linesPerSection: Int,
        titlePrefix: String
    ) -> [DocumentSection] {
        let lines = textLines(in: text)
        guard !lines.isEmpty else { return [] }

        var sections: [DocumentSection] = []
        var index = 0
        while index < lines.count {
            let endIndex = min(index + linesPerSection, lines.count)
            let group = lines[index..<endIndex]
            guard let first = group.first, let last = group.last else { break }
            sections.append(
                DocumentSection(
                    title: "\(titlePrefix) \(first.number)-\(last.number)",
                    lowerBound: first.lowerBound,
                    upperBound: last.upperBound
                )
            )
            index = endIndex
        }
        return sections
    }

    nonisolated
    private static func markdownSections(in text: String) -> [DocumentSection] {
        let lines = textLines(in: text)
        guard !lines.isEmpty else { return [] }

        var headingStarts: [(title: String, lineIndex: Int)] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let title = trimmed
                .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            headingStarts.append((title, index))
        }

        guard !headingStarts.isEmpty else {
            return lineRangeSections(in: text, linesPerSection: 80, titlePrefix: "Lines")
        }

        return headingStarts.enumerated().compactMap { offset, heading in
            let startLine = lines[heading.lineIndex]
            let nextLineIndex = offset + 1 < headingStarts.count ? headingStarts[offset + 1].lineIndex : lines.count
            let endLine = lines[max(heading.lineIndex, nextLineIndex - 1)]
            guard endLine.upperBound > startLine.lowerBound else { return nil }
            return DocumentSection(
                title: heading.title,
                lowerBound: startLine.lowerBound,
                upperBound: endLine.upperBound
            )
        }
    }

    nonisolated
    private static func sourceCodeSections(in text: String) -> [DocumentSection] {
        let lines = textLines(in: text)
        guard !lines.isEmpty else { return [] }

        let declarationPrefixes = [
            "class ", "struct ", "enum ", "protocol ", "actor ", "func ",
            "def ", "function ", "interface ", "type ", "extension "
        ]
        var starts: [(title: String, lineIndex: Int)] = []

        for (index, line) in lines.enumerated() {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard declarationPrefixes.contains(where: { trimmed.hasPrefix($0) }) else { continue }
            let title = trimmed.prefix(80).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            starts.append((String(title), index))
        }

        guard !starts.isEmpty else {
            return lineRangeSections(in: text, linesPerSection: 100, titlePrefix: "Lines")
        }

        return starts.enumerated().compactMap { offset, declaration in
            let startLine = lines[declaration.lineIndex]
            let nextLineIndex = offset + 1 < starts.count ? starts[offset + 1].lineIndex : lines.count
            let endLine = lines[max(declaration.lineIndex, nextLineIndex - 1)]
            guard endLine.upperBound > startLine.lowerBound else { return nil }
            return DocumentSection(
                title: declaration.title,
                lowerBound: startLine.lowerBound,
                upperBound: endLine.upperBound
            )
        }
    }

    nonisolated
    private static func textLines(in text: String) -> [TextLine] {
        var lines: [TextLine] = []
        var lineStart = text.startIndex
        var lineNumber = 1

        while lineStart < text.endIndex {
            let newlineIndex = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let lineText = String(text[lineStart..<newlineIndex])
            lines.append(
                TextLine(
                    number: lineNumber,
                    text: lineText,
                    lowerBound: text.distance(from: text.startIndex, to: lineStart),
                    upperBound: text.distance(from: text.startIndex, to: newlineIndex)
                )
            )

            guard newlineIndex < text.endIndex else { break }
            lineStart = text.index(after: newlineIndex)
            lineNumber += 1
        }

        if lines.isEmpty, !text.isEmpty {
            lines.append(TextLine(number: 1, text: text, lowerBound: 0, upperBound: text.count))
        }

        return lines
    }

    nonisolated
    private static func append(
        pageText: String,
        title: String,
        to fullText: inout String,
        sections: inout [DocumentSection]
    ) {
        if !fullText.isEmpty {
            fullText += "\n\n"
        }
        let sectionStart = fullText.count
        fullText += pageText
        let sectionEnd = fullText.count
        sections.append(
            DocumentSection(
                title: title,
                lowerBound: sectionStart,
                upperBound: sectionEnd
            )
        )
    }

    nonisolated
    private static func renderPDFPage(_ page: PDFPage) -> UIImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let maxDimension: CGFloat = 1400
        let longestEdge = max(bounds.width, bounds.height)
        let scale = max(1.0, min(maxDimension / longestEdge, 3.0))
        let outputSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)

        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: outputSize))

            context.cgContext.translateBy(x: 0, y: outputSize.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
    }

    nonisolated
    private static func recognizeText(from image: UIImage) throws -> String {
        try Task.checkCancellation()
        guard let cgImage = preprocessForOCR(from: image) else {
            throw DocumentError.extractionFailed
        }
        try Task.checkCancellation()

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: .up,
            options: [:]
        )
        try handler.perform([request])
        try Task.checkCancellation()

        guard let observations = request.results, !observations.isEmpty else {
            return ""
        }

        let lines = observations
            .sorted {
                let lhsBox = $0.boundingBox
                let rhsBox = $1.boundingBox
                if abs(lhsBox.midY - rhsBox.midY) > 0.03 {
                    return lhsBox.midY > rhsBox.midY
                }
                return lhsBox.midX < rhsBox.midX
            }
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.joined(separator: "\n")
    }

    nonisolated
    private static func preprocessForOCR(from image: UIImage) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        guard image.size.width > 0, image.size.height > 0 else { return nil }

        let rendererFormat = UIGraphicsImageRendererFormat.default()
        rendererFormat.scale = 1
        let normalizedImage = UIGraphicsImageRenderer(size: image.size, format: rendererFormat).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }

        guard let sourceCGImage = normalizedImage.cgImage else {
            return nil
        }

        let source = CIImage(cgImage: sourceCGImage)
        let cleaned = source
            .clampedToExtent()
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.18,
                kCIInputBrightnessKey: 0.02
            ])
            .applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.35
            ])
            .cropped(to: source.extent)

        return CIContext(options: [.useSoftwareRenderer: false])
            .createCGImage(cleaned, from: cleaned.extent)
    }

    nonisolated
    private static func recognizeText(from url: URL) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        guard let image = UIImage(contentsOfFile: url.path),
              let cgImage = preprocessForOCR(from: image) else {
            throw DocumentError.extractionFailed
        }
        try Task.checkCancellation()

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try handler.perform([request])
        try Task.checkCancellation()

        guard let observations = request.results, !observations.isEmpty else {
            return ""
        }

        let lines = observations
            .sorted {
                let lhsBox = $0.boundingBox
                let rhsBox = $1.boundingBox
                if abs(lhsBox.midY - rhsBox.midY) > 0.03 {
                    return lhsBox.midY > rhsBox.midY
                }
                return lhsBox.midX < rhsBox.midX
            }
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.joined(separator: "\n")
    }

    nonisolated
    private static func provenanceOrigin(didUseNativeText: Bool, didUseOCR: Bool) -> DocumentTextOrigin {
        switch (didUseNativeText, didUseOCR) {
        case (true, true):
            return .mixed
        case (false, true):
            return .ocr
        default:
            return .native
        }
    }

    nonisolated
    private static func ocrQuality(didUseOCR: Bool, ocrCharacterCount: Int) -> DocumentExtractionQuality {
        guard didUseOCR else { return .normal }
        return ocrCharacterCount < 160 ? .weak : .normal
    }

    nonisolated
    private static func shouldOCRScannedPage(_ nativeText: String?) -> Bool {
        guard let nativeText, !nativeText.isEmpty else { return true }

        let lineCount = nativeText.split(whereSeparator: \.isNewline).count
        if nativeText.count < 120 {
            return true
        }

        return lineCount <= 2 && nativeText.count < 220
    }

    nonisolated
    private static func currentPDFOCRMode() -> PDFOCRMode {
        PDFOCRMode(
            rawValue: UserDefaults.standard.string(forKey: "pdfOCRMode") ?? PDFOCRMode.preferNativeText.rawValue
        ) ?? .preferNativeText
    }

    nonisolated
    private static func currentDocumentProcessingMode() -> DocumentProcessingMode {
        DocumentProcessingMode(
            rawValue: UserDefaults.standard.string(forKey: DocumentProcessingMode.storageKey) ?? DocumentProcessingMode.fast.rawValue
        ) ?? .fast
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

private struct ExtractionResult {
    let text: String
    let sections: [DocumentSection]
    let extractedPages: Int
    let totalPages: Int
    let textOrigin: DocumentTextOrigin
    let ocrQuality: DocumentExtractionQuality
}

private struct PersistedConversationDocuments: Codable {
    let conversationID: UUID
    let documents: [ConversationDocument]
}

/// Manages saving, loading, and deleting image attachments for chat messages.
final class ImageAttachmentManager: Sendable {
    static let shared = ImageAttachmentManager()

    private let directoryName = "chat_images"
    private let maxDimension: CGFloat = 1024
    private let compressionQuality: CGFloat = 0.8

    private init() {
        ensureDirectoryExists()
    }

    // MARK: - Public API

    /// Save an image for a given message ID. Returns the file name on success.
    func saveImage(_ image: UIImage, for messageID: UUID) -> String? {
        guard let resized = downsample(image, maxDimension: maxDimension),
              let data = resized.jpegData(compressionQuality: compressionQuality) else {
            return nil
        }

        let fileName = "\(messageID.uuidString).jpg"
        let fileURL = imagesDirectory.appendingPathComponent(fileName)

        do {
            try data.write(to: fileURL, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    /// Load an image by file name.
    func loadImage(named fileName: String) -> UIImage? {
        let fileURL = imagesDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return UIImage(contentsOfFile: fileURL.path)
    }

    /// Delete a single image by file name.
    func deleteImage(named fileName: String) {
        let fileURL = imagesDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Delete all stored images.
    func deleteAllImages() {
        try? FileManager.default.removeItem(at: imagesDirectory)
        ensureDirectoryExists()
    }

    // MARK: - Private

    private var imagesDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private func ensureDirectoryExists() {
        let url = imagesDirectory
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func downsample(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
        let size = image.size
        guard size.width > maxDimension || size.height > maxDimension else { return image }

        let scale: CGFloat
        if size.width > size.height {
            scale = maxDimension / size.width
        } else {
            scale = maxDimension / size.height
        }

        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
