//
//  RAGEngine.swift
//  LocalAI
//
//  Created by Codex on 15.03.2026.
//

import CryptoKit
import Foundation
import NaturalLanguage

struct TextChunk: Identifiable, Codable {
    let id: UUID
    let conversationID: UUID
    let documentID: UUID
    let content: String
    let sourceLocationLabel: String?
    let languageRawValue: String?
    let sequenceIndex: Int
    let embedding: [Float]

    init(
        conversationID: UUID,
        documentID: UUID,
        content: String,
        sourceLocationLabel: String?,
        language: NLLanguage?,
        sequenceIndex: Int,
        embedding: [Float]
    ) {
        self.id = UUID()
        self.conversationID = conversationID
        self.documentID = documentID
        self.content = content
        self.sourceLocationLabel = sourceLocationLabel
        self.languageRawValue = language?.rawValue
        self.sequenceIndex = sequenceIndex
        self.embedding = embedding
    }

    var language: NLLanguage? {
        languageRawValue.flatMap(NLLanguage.init(rawValue:))
    }
}

struct RetrievedChunk: Identifiable, Equatable {
    let id: UUID
    let conversationID: UUID
    let documentID: UUID
    let content: String
    let sourceLocationLabel: String?
    let score: Double
}

actor RAGEngine {
    private struct PersistedState: Codable {
        let version: Int
        let documentFingerprints: [PersistedDocumentFingerprint]
        let chunks: [TextChunk]
    }

    private struct PersistedDocumentFingerprint: Codable {
        let conversationID: UUID
        let documentID: UUID
        let contentHash: String
    }

    private struct DocumentKey: Hashable {
        let conversationID: UUID
        let documentID: UUID
    }

    struct IndexedDocumentSnapshot: Sendable {
        let conversationID: UUID
        let documentID: UUID
        let content: String
        let sections: [DocumentSection]
    }

    static let shared = RAGEngine()
    private static let persistedStateVersion = 3

    private var chunks: [TextChunk] = []
    private var documentFingerprints: [DocumentKey: String] = [:]

    private init() {}

    private var persistenceURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rag_index.json")
    }

    func ingest(
        text: String,
        sections: [DocumentSection],
        documentID: UUID,
        conversationID: UUID
    ) async {
        await MemoryProfiler.measure("RAGEngine.ingest(doc: \(documentID))") {
            let language = dominantLanguage(for: text)
            let rawChunks = chunkText(text, targetSize: 900, overlapSentences: 1)

            for (index, chunkContent) in rawChunks.enumerated() {
                if let vector = embedding(for: chunkContent.content, language: language) {
                    let chunk = TextChunk(
                        conversationID: conversationID,
                        documentID: documentID,
                        content: chunkContent.content,
                        sourceLocationLabel: sourceLocationLabel(for: chunkContent, sections: sections),
                        language: language,
                        sequenceIndex: index,
                        embedding: vector
                    )
                    chunks.append(chunk)
                }
            }

            documentFingerprints[DocumentKey(conversationID: conversationID, documentID: documentID)] = contentHash(for: text)
            persistState()
        }
    }

    func clear(documentID: UUID, conversationID: UUID) {
        chunks.removeAll { $0.documentID == documentID && $0.conversationID == conversationID }
        documentFingerprints.removeValue(forKey: DocumentKey(conversationID: conversationID, documentID: documentID))
        persistState()
    }

    func clearConversation(_ conversationID: UUID) {
        chunks.removeAll { $0.conversationID == conversationID }
        documentFingerprints = documentFingerprints.filter { $0.key.conversationID != conversationID }
        persistState()
    }

    func clearAll() {
        chunks.removeAll()
        documentFingerprints.removeAll()
        persistState()
    }

    func restoreIndexIfCurrent(with documents: [IndexedDocumentSnapshot]) -> Bool {
        guard let state = loadPersistedState(), state.version == Self.persistedStateVersion else {
            return false
        }

        let expectedFingerprints = fingerprints(for: documents)
        let storedFingerprints = Dictionary(
            uniqueKeysWithValues: state.documentFingerprints.map {
                (
                    DocumentKey(conversationID: $0.conversationID, documentID: $0.documentID),
                    $0.contentHash
                )
            }
        )

        guard expectedFingerprints == storedFingerprints else {
            return false
        }

        chunks = state.chunks
        documentFingerprints = storedFingerprints
        return true
    }

    func rebuildIndex(from documents: [IndexedDocumentSnapshot]) async {
        await MemoryProfiler.measure("RAGEngine.rebuildIndex") {
            var rebuiltChunks: [TextChunk] = []
            var rebuiltFingerprints: [DocumentKey: String] = [:]

            let sortedDocuments = documents.sorted {
                ($0.conversationID.uuidString, $0.documentID.uuidString) < ($1.conversationID.uuidString, $1.documentID.uuidString)
            }

            for document in sortedDocuments {
                let language = dominantLanguage(for: document.content)
                let rawChunks = chunkText(document.content, targetSize: 900, overlapSentences: 1)

                for (index, chunkContent) in rawChunks.enumerated() {
                    if let vector = embedding(for: chunkContent.content, language: language) {
                        rebuiltChunks.append(
                            TextChunk(
                                conversationID: document.conversationID,
                                documentID: document.documentID,
                                content: chunkContent.content,
                                sourceLocationLabel: sourceLocationLabel(for: chunkContent, sections: document.sections),
                                language: language,
                                sequenceIndex: index,
                                embedding: vector
                            )
                        )
                    }
                }

                rebuiltFingerprints[DocumentKey(conversationID: document.conversationID, documentID: document.documentID)] = contentHash(for: document.content)
            }

            chunks = rebuiltChunks
            documentFingerprints = rebuiltFingerprints
            persistState()
        }
    }

    func retrieveDetailed(query: String, limit: Int = 3, conversationID: UUID) -> [RetrievedChunk] {
        let queryLanguage = dominantLanguage(for: query)
        guard let queryVector = embedding(for: query, language: queryLanguage) else { return [] }

        let ranked = chunks
            .filter { $0.conversationID == conversationID }
            .filter { chunk in
                guard let queryLanguage else { return true }
                guard let chunkLanguage = chunk.language else { return true }
                return chunkLanguage == queryLanguage
            }
            .map { chunk in
                let score = cosineSimilarity(queryVector, chunk.embedding)
                return (chunk: chunk, score: score)
            }
            .sorted { $0.score > $1.score }

        guard let topScore = ranked.first?.score else { return [] }

        let minimumScore = max(0.18, topScore * 0.62)
        var perDocumentCount: [UUID: Int] = [:]
        var selectedCandidates: [(chunk: TextChunk, score: Double)] = []

        for candidate in ranked {
            guard candidate.score >= minimumScore || selectedCandidates.isEmpty else { break }

            let currentDocumentHits = perDocumentCount[candidate.chunk.documentID, default: 0]
            guard currentDocumentHits < 3 else { continue }

            selectedCandidates.append(candidate)
            perDocumentCount[candidate.chunk.documentID, default: 0] += 1

            if selectedCandidates.count == max(limit * 2, limit) {
                break
            }
        }

        let mergedCandidates = mergeAdjacentCandidates(selectedCandidates)
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.chunk.documentID != rhs.chunk.documentID {
                    return lhs.chunk.documentID.uuidString < rhs.chunk.documentID.uuidString
                }
                return lhs.chunk.sequenceIndex < rhs.chunk.sequenceIndex
            }

        return Array(mergedCandidates.prefix(limit)).map { candidate in
            RetrievedChunk(
                id: candidate.chunk.id,
                conversationID: candidate.chunk.conversationID,
                documentID: candidate.chunk.documentID,
                content: candidate.chunk.content,
                sourceLocationLabel: candidate.chunk.sourceLocationLabel,
                score: candidate.score
            )
        }
    }

    private func dominantLanguage(for text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    private func fingerprints(for documents: [IndexedDocumentSnapshot]) -> [DocumentKey: String] {
        var result: [DocumentKey: String] = [:]
        for document in documents {
            result[DocumentKey(conversationID: document.conversationID, documentID: document.documentID)] = contentHash(for: document.content)
        }
        return result
    }

    private func contentHash(for text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func persistState() {
        let state = PersistedState(
            version: Self.persistedStateVersion,
            documentFingerprints: documentFingerprints.map { key, value in
                PersistedDocumentFingerprint(
                    conversationID: key.conversationID,
                    documentID: key.documentID,
                    contentHash: value
                )
            }
            .sorted {
                ($0.conversationID.uuidString, $0.documentID.uuidString) < ($1.conversationID.uuidString, $1.documentID.uuidString)
            },
            chunks: chunks
        )

        do {
            try SecureFileStore.save(state, to: persistenceURL)
        } catch {
            print("Failed to save RAG index: \(error)")
        }
    }

    private func loadPersistedState() -> PersistedState? {
        do {
            return try SecureFileStore.load(PersistedState.self, from: persistenceURL)
        } catch {
            return nil
        }
    }

    private func embedding(for text: String, language: NLLanguage?) -> [Float]? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if let language {
            if let sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: language),
               let vector = sentenceEmbedding.vector(for: normalized) {
                return vector.map(Float.init)
            }

            if let wordEmbedding = NLEmbedding.wordEmbedding(for: language),
               let vector = wordEmbedding.vector(for: normalized) {
                return vector.map(Float.init)
            }
        }

        if let englishSentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english),
           let vector = englishSentenceEmbedding.vector(for: normalized) {
            return vector.map(Float.init)
        }

        return NLEmbedding.wordEmbedding(for: .english)?
            .vector(for: normalized)?
            .map(Float.init)
    }

    private func mergeAdjacentCandidates(
        _ candidates: [(chunk: TextChunk, score: Double)]
    ) -> [(chunk: TextChunk, score: Double)] {
        let grouped = Dictionary(grouping: candidates, by: \.chunk.documentID)
        var merged: [(chunk: TextChunk, score: Double)] = []

        for documentCandidates in grouped.values {
            let ordered = documentCandidates.sorted { lhs, rhs in
                lhs.chunk.sequenceIndex < rhs.chunk.sequenceIndex
            }

            var currentGroup: [(chunk: TextChunk, score: Double)] = []

            func flushGroup() {
                guard let first = currentGroup.first else { return }
                if currentGroup.count == 1 {
                    merged.append(first)
                } else {
                    let mergedContent = currentGroup
                        .map(\.chunk.content)
                        .joined(separator: "\n\n")
                    let mergedScore = currentGroup.map(\.score).max() ?? first.score
                    let mergedChunk = TextChunk(
                        conversationID: first.chunk.conversationID,
                        documentID: first.chunk.documentID,
                        content: mergedContent,
                        sourceLocationLabel: mergedLocationLabel(for: currentGroup),
                        language: first.chunk.language,
                        sequenceIndex: first.chunk.sequenceIndex,
                        embedding: first.chunk.embedding
                    )
                    merged.append((chunk: mergedChunk, score: mergedScore))
                }
                currentGroup.removeAll(keepingCapacity: true)
            }

            for candidate in ordered {
                if let previous = currentGroup.last,
                   candidate.chunk.sequenceIndex == previous.chunk.sequenceIndex + 1 {
                    currentGroup.append(candidate)
                } else {
                    flushGroup()
                    currentGroup.append(candidate)
                }
            }

            flushGroup()
        }

        return merged
    }

    private struct ChunkCandidate {
        let content: String
        let lowerBound: Int
        let upperBound: Int
    }

    private func chunkText(_ text: String, targetSize: Int, overlapSentences: Int) -> [ChunkCandidate] {
        let cleaned = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        let sentences = sentenceUnits(in: cleaned)
        guard !sentences.isEmpty else {
            return splitLargeText((cleaned, 0, cleaned.count), targetSize: targetSize)
        }

        var result: [ChunkCandidate] = []
        var currentSentences: [(text: String, lowerBound: Int, upperBound: Int)] = []
        var currentLength = 0

        for sentence in sentences {
            let sentenceLength = sentence.text.count + (currentSentences.isEmpty ? 0 : 1)
            let wouldOverflow = currentLength + sentenceLength > targetSize

            if wouldOverflow && !currentSentences.isEmpty {
                result.append(makeChunkCandidate(from: currentSentences))
                currentSentences = Array(currentSentences.suffix(overlapSentences))
                currentLength = currentSentences.reduce(0) { partialResult, value in
                    partialResult + value.text.count
                } + max(0, currentSentences.count - 1)
            }

            if sentence.text.count > targetSize {
                if !currentSentences.isEmpty {
                    result.append(makeChunkCandidate(from: currentSentences))
                    currentSentences.removeAll()
                    currentLength = 0
                }
                result.append(contentsOf: splitLargeText(sentence, targetSize: targetSize))
                continue
            }

            currentSentences.append(sentence)
            currentLength += sentenceLength
        }

        if !currentSentences.isEmpty {
            result.append(makeChunkCandidate(from: currentSentences))
        }

        return result
    }

    private func sentenceUnits(in text: String) -> [(text: String, lowerBound: Int, upperBound: Int)] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var result: [(text: String, lowerBound: Int, upperBound: Int)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                result.append((
                    sentence,
                    text.distance(from: text.startIndex, to: range.lowerBound),
                    text.distance(from: text.startIndex, to: range.upperBound)
                ))
            }
            return true
        }

        if !result.isEmpty {
            return result
        }

        return text
            .components(separatedBy: "\n\n")
            .reduce(into: [(text: String, lowerBound: Int, upperBound: Int)]()) { partialResult, block in
                let sentence = block.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sentence.isEmpty, let range = text.range(of: sentence) else { return }
                partialResult.append((
                    sentence,
                    text.distance(from: text.startIndex, to: range.lowerBound),
                    text.distance(from: text.startIndex, to: range.upperBound)
                ))
            }
    }

    private func splitLargeText(
        _ sentence: (text: String, lowerBound: Int, upperBound: Int),
        targetSize: Int
    ) -> [ChunkCandidate] {
        var result: [ChunkCandidate] = []
        let text = sentence.text
        var startIndex = text.startIndex

        while startIndex < text.endIndex {
            let endIndex = text.index(startIndex, offsetBy: targetSize, limitedBy: text.endIndex) ?? text.endIndex
            let chunk = text[startIndex..<endIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                let localLowerBound = text.distance(from: text.startIndex, to: startIndex)
                let localUpperBound = text.distance(from: text.startIndex, to: endIndex)
                result.append(
                    ChunkCandidate(
                        content: String(chunk),
                        lowerBound: sentence.lowerBound + localLowerBound,
                        upperBound: sentence.lowerBound + localUpperBound
                    )
                )
            }
            startIndex = endIndex
        }

        return result
    }

    private func makeChunkCandidate(
        from sentences: [(text: String, lowerBound: Int, upperBound: Int)]
    ) -> ChunkCandidate {
        ChunkCandidate(
            content: sentences.map(\.text).joined(separator: " "),
            lowerBound: sentences.first?.lowerBound ?? 0,
            upperBound: sentences.last?.upperBound ?? 0
        )
    }

    private func sourceLocationLabel(for chunk: ChunkCandidate, sections: [DocumentSection]) -> String? {
        let overlappingSections = sections.filter { section in
            section.upperBound > chunk.lowerBound && section.lowerBound < chunk.upperBound
        }
        guard let first = overlappingSections.first else { return nil }
        guard let last = overlappingSections.last, last.title != first.title else {
            return first.title
        }
        return "\(first.title)-\(last.title)"
    }

    private func mergedLocationLabel(for candidates: [(chunk: TextChunk, score: Double)]) -> String? {
        let labels = candidates.compactMap(\.chunk.sourceLocationLabel)
        guard let first = labels.first else { return nil }
        guard let last = labels.last, last != first else { return first }
        return "\(first)-\(last)"
    }

    private func cosineSimilarity(_ v1: [Float], _ v2: [Float]) -> Double {
        guard v1.count == v2.count else { return 0 }

        var dotProduct = 0.0
        var magnitude1 = 0.0
        var magnitude2 = 0.0

        for index in 0..<v1.count {
            let lhs = Double(v1[index])
            let rhs = Double(v2[index])
            dotProduct += lhs * rhs
            magnitude1 += lhs * lhs
            magnitude2 += rhs * rhs
        }

        let magnitude = sqrt(magnitude1) * sqrt(magnitude2)
        guard magnitude > 0 else { return 0 }
        return dotProduct / magnitude
    }
}
