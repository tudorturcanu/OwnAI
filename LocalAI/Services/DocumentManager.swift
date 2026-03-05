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
class DocumentManager {
    static let shared = DocumentManager()
    
    var extractionProgress: Double = 0
    
    private init() {}
    
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
        
        let content: String
        var extractedPages = 0
        var totalPages = 0
        let ext = url.pathExtension.lowercased()
        
        switch ext {
        case "pdf":
            let result = try extractTextFromPDF(at: url)
            content = result.text
            extractedPages = result.extractedPages
            totalPages = result.totalPages
            
        case "rtf", "rtfd":
            content = try extractTextFromRTF(at: url)
            
        case "doc", "docx":
            content = try extractTextFromWord(at: url)
            
        default:
            // Plain text, source code, etc.
            content = try String(contentsOf: url, encoding: .utf8)
        }
        
        extractionProgress = 0.9
        
        // Check for empty content
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            extractionProgress = 0
            throw DocumentError.emptyDocument
        }
        
        extractionProgress = 1.0
        
        // Small delay so the user sees the completed progress
        try? await Task.sleep(for: .milliseconds(200))
        extractionProgress = 0
        
        return AttachedDocument(
            url: url,
            content: content,
            extractedPages: extractedPages,
            totalPages: totalPages,
            fileSize: fileSize
        )
    }
    
    // MARK: - Extractors
    
    private static let maxPages = 5
    
    private func extractTextFromPDF(at url: URL) throws -> (text: String, extractedPages: Int, totalPages: Int) {
        guard let pdfDocument = PDFDocument(url: url) else {
            throw DocumentError.extractionFailed
        }
        
        let totalPages = pdfDocument.pageCount
        let pagesToExtract = min(totalPages, Self.maxPages)
        var fullText = ""
        
        for i in 0..<pagesToExtract {
            // Update progress proportionally
            let progress = 0.1 + (Double(i + 1) / Double(pagesToExtract)) * 0.7
            Task { @MainActor in
                self.extractionProgress = progress
            }
            
            if let page = pdfDocument.page(at: i), let pageText = page.string {
                fullText += pageText + "\n"
            }
        }
        
        return (fullText.trimmingCharacters(in: .whitespacesAndNewlines), pagesToExtract, totalPages)
    }
    
    private func extractTextFromRTF(at url: URL) throws -> String {
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
    
    private func extractTextFromWord(at url: URL) throws -> String {
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
