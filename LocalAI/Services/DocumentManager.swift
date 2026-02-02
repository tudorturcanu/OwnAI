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
    
    var name: String {
        url.lastPathComponent
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
        
        if url.pathExtension.lowercased() == "pdf" {
            content = try extractTextFromPDF(at: url)
        } else {
            // Assume text/code
            content = try String(contentsOf: url, encoding: .utf8)
        }
        
        let id = UUID()
        // Ingest into RAG Engine
        await RAGEngine.shared.ingest(text: content, documentID: id)
        
        return AttachedDocument(url: url, content: content) // Note: AttachedDocument definition needs ID update or use existing UUID
    }
    
    private func extractTextFromPDF(at url: URL) throws -> String {
        guard let pdfDocument = PDFDocument(url: url) else {
            throw DocumentError.extractionFailed
        }
        
        var fullText = ""
        for i in 0..<pdfDocument.pageCount {
            if let page = pdfDocument.page(at: i), let pageText = page.string {
                fullText += pageText + "\n"
            }
        }
        
        return fullText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
