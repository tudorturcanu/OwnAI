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
}

enum DocumentError: LocalizedError {
    case fileAccessFailed
    case extractionFailed
    case unsupportedFormat
    
    var errorDescription: String? {
        switch self {
        case .fileAccessFailed: return "Could not access the selected file."
        case .extractionFailed: return "Could not extract text from the file."
        case .unsupportedFormat: return "This file format is not supported."
        }
    }
}

@MainActor
class DocumentManager {
    static let shared = DocumentManager()
    
    private init() {}
    
    func processFile(at url: URL) async throws -> AttachedDocument {
        // Start accessing security scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            throw DocumentError.fileAccessFailed
        }
        
        defer {
            url.stopAccessingSecurityScopedResource()
        }
        
        let content: String
        var extractedPages = 0
        var totalPages = 0
        
        if url.pathExtension.lowercased() == "pdf" {
            let result = try extractTextFromPDF(at: url)
            content = result.text
            extractedPages = result.extractedPages
            totalPages = result.totalPages
        } else {
            // Assume text/code
            content = try String(contentsOf: url, encoding: .utf8)
        }
        
        let id = UUID()
        // Ingest into RAG Engine
        await RAGEngine.shared.ingest(text: content, documentID: id)
        
        return AttachedDocument(url: url, content: content, extractedPages: extractedPages, totalPages: totalPages)
    }
    
    private static let maxPages = 5
    
    private func extractTextFromPDF(at url: URL) throws -> (text: String, extractedPages: Int, totalPages: Int) {
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
}
