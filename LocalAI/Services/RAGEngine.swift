//
//  RAGEngine.swift
//  LocalAI
//
//  Created by ANTIGRAVITY on 01.02.2026.
//

import Foundation
import NaturalLanguage

struct TextChunk: Identifiable, Codable {
    let id: UUID
    let documentID: UUID
    let content: String
    let embedding: [Double]
    
    init(documentID: UUID, content: String, embedding: [Double]) {
        self.id = UUID()
        self.documentID = documentID
        self.content = content
        self.embedding = embedding
    }
}

actor RAGEngine {
    static let shared = RAGEngine()
    
    private var chunks: [TextChunk] = []
    
    // NLEmbedding is thread-safe
    private var embeddingModel = NLEmbedding.wordEmbedding(for: .english)
    
    private init() {}
    
    // MARK: - Ingestion
    
    func ingest(text: String, documentID: UUID) async {
        // 1. Chunking (Simple character based for now, can improve to sentence based)
        let rawChunks = chunkText(text, size: 800, overlap: 100)
        
        // 2. Embedding
        // NLEmbedding is synchronous, so we run it here.
        // Ideally we'd batch this or run in detached task if very large.
        
        for chunkContent in rawChunks {
            if let vector = embeddingModel?.vector(for: chunkContent) {
                let chunk = TextChunk(documentID: documentID, content: chunkContent, embedding: vector)
                chunks.append(chunk)
            }
        }
        
        print("RAG: Ingested \(rawChunks.count) chunks for doc \(documentID)")
    }
    
    func clear(documentID: UUID) {
        chunks.removeAll { $0.documentID == documentID }
    }
    
    func clearAll() {
        chunks.removeAll()
    }
    
    // MARK: - Retrieval
    
    func retrieve(query: String, limit: Int = 3) -> [String] {
        guard let queryVector = embeddingModel?.vector(for: query) else { return [] }
        
        // Calculate Cosine Similarity
        // Sim(A,B) = (A . B) / (|A| * |B|)
        // NLEmbedding vectors are usually normalized? Let's check documentation or assume not.
        // Actually usually they are not normalized in NLEmbedding unless specified. 
        // But for performance, let's just do dot product if we assume normalized, or full cosine.
        
        // Let's do full cosine similarity
        let sortedChunks = chunks.map { chunk -> (TextChunk, Double) in
            let score = cosineSimilarity(queryVector, chunk.embedding)
            return (chunk, score)
        }
        .sorted { $0.1 > $1.1 }
        
        return sortedChunks.prefix(limit).map { $0.0.content }
    }
    
    // MARK: - Helpers
    
    private func chunkText(_ text: String, size: Int, overlap: Int) -> [String] {
        var chunks: [String] = []
        let characters = Array(text)
        var startIndex = 0
        
        while startIndex < characters.count {
            let endIndex = min(startIndex + size, characters.count)
            let chunk = String(characters[startIndex..<endIndex])
            chunks.append(chunk)
            
            if endIndex == characters.count { break }
            startIndex += (size - overlap)
        }
        
        return chunks
    }
    
    private func cosineSimilarity(_ v1: [Double], _ v2: [Double]) -> Double {
        guard v1.count == v2.count else { return 0 }
        
        var dotProduct = 0.0
        var mag1 = 0.0
        var mag2 = 0.0
        
        for i in 0..<v1.count {
            dotProduct += v1[i] * v2[i]
            mag1 += v1[i] * v1[i]
            mag2 += v2[i] * v2[i]
        }
        
        let magnitude = sqrt(mag1) * sqrt(mag2)
        if magnitude == 0 { return 0 }
        
        return dotProduct / magnitude
    }
}
