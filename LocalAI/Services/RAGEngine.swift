//
//  RAGEngine.swift
//  LocalAI
//
//  Created by Codex on 15.03.2026.
//

import Foundation
import NaturalLanguage

struct TextChunk: Identifiable, Codable {
    let id: UUID
    let conversationID: UUID
    let documentID: UUID
    let content: String
    let embedding: [Double]

    init(conversationID: UUID, documentID: UUID, content: String, embedding: [Double]) {
        self.id = UUID()
        self.conversationID = conversationID
        self.documentID = documentID
        self.content = content
        self.embedding = embedding
    }
}

struct RetrievedChunk: Identifiable, Equatable {
    let id: UUID
    let conversationID: UUID
    let documentID: UUID
    let content: String
    let score: Double
}

actor RAGEngine {
    static let shared = RAGEngine()

    private var chunks: [TextChunk] = []
    private let embeddingModel = NLEmbedding.wordEmbedding(for: .english)

    private init() {}

    func ingest(text: String, documentID: UUID, conversationID: UUID) async {
        await MemoryProfiler.measure("RAGEngine.ingest(doc: \(documentID))") {
            let rawChunks = chunkText(text, size: 800, overlap: 100)

            for chunkContent in rawChunks {
                if let vector = embeddingModel?.vector(for: chunkContent) {
                    let chunk = TextChunk(
                        conversationID: conversationID,
                        documentID: documentID,
                        content: chunkContent,
                        embedding: vector
                    )
                    chunks.append(chunk)
                }
            }
        }
    }

    func clear(documentID: UUID, conversationID: UUID) {
        chunks.removeAll { $0.documentID == documentID && $0.conversationID == conversationID }
    }

    func clearConversation(_ conversationID: UUID) {
        chunks.removeAll { $0.conversationID == conversationID }
    }

    func clearAll() {
        chunks.removeAll()
    }

    func retrieveDetailed(query: String, limit: Int = 3, conversationID: UUID) -> [RetrievedChunk] {
        guard let queryVector = embeddingModel?.vector(for: query) else { return [] }

        return chunks
            .filter { $0.conversationID == conversationID }
            .map { chunk in
                let score = cosineSimilarity(queryVector, chunk.embedding)
                return RetrievedChunk(
                    id: chunk.id,
                    conversationID: chunk.conversationID,
                    documentID: chunk.documentID,
                    content: chunk.content,
                    score: score
                )
            }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    private func chunkText(_ text: String, size: Int, overlap: Int) -> [String] {
        var result: [String] = []
        let characters = Array(text)
        var startIndex = 0

        while startIndex < characters.count {
            let endIndex = min(startIndex + size, characters.count)
            result.append(String(characters[startIndex..<endIndex]))

            if endIndex == characters.count { break }
            startIndex += (size - overlap)
        }

        return result
    }

    private func cosineSimilarity(_ v1: [Double], _ v2: [Double]) -> Double {
        guard v1.count == v2.count else { return 0 }

        var dotProduct = 0.0
        var magnitude1 = 0.0
        var magnitude2 = 0.0

        for index in 0..<v1.count {
            dotProduct += v1[index] * v2[index]
            magnitude1 += v1[index] * v1[index]
            magnitude2 += v2[index] * v2[index]
        }

        let magnitude = sqrt(magnitude1) * sqrt(magnitude2)
        guard magnitude > 0 else { return 0 }
        return dotProduct / magnitude
    }
}
