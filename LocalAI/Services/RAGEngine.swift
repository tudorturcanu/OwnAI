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
    /// Identifies which model produced `embedding`. Vectors from different
    /// embedders live in incompatible spaces and must never be compared.
    let embedderID: String

    init(
        conversationID: UUID,
        documentID: UUID,
        content: String,
        sourceLocationLabel: String?,
        language: NLLanguage?,
        sequenceIndex: Int,
        embedding: [Float],
        embedderID: String
    ) {
        self.id = UUID()
        self.conversationID = conversationID
        self.documentID = documentID
        self.content = content
        self.sourceLocationLabel = sourceLocationLabel
        self.languageRawValue = language?.rawValue
        self.sequenceIndex = sequenceIndex
        self.embedding = embedding
        self.embedderID = embedderID
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

    private struct RetrievalCandidate {
        let chunk: TextChunk
        let semanticScore: Double
        let lexicalScore: Double
        let phraseScore: Double

        var score: Double {
            semanticScore * 0.68 + lexicalScore * 0.27 + phraseScore * 0.05
        }
    }

    private struct LexicalSearchSummary {
        let bestLexicalScore: Double
        let bestPhraseScore: Double
        let strongMatchCount: Int
    }

    struct IndexedDocumentSnapshot: Sendable {
        let conversationID: UUID
        let documentID: UUID
        let content: String
        let sections: [DocumentSection]
    }

    static let shared = RAGEngine()
    // v4: chunks gained `embedderID`; switching the embedding backend forces a rebuild.
    private static let persistedStateVersion = 4
    private static let persistenceDebounceNanoseconds: UInt64 = 1_000_000_000

    /// UserDefaults key controlling whether neural embeddings are used.
    static let neuralEmbeddingsDefaultsKey = "neuralEmbeddingsEnabled"
    /// Tag for vectors produced by Apple's NLEmbedding fallback.
    private static let legacyEmbedderID = "nl-embedding-v1"

    private var chunks: [TextChunk] = []
    private var documentFingerprints: [DocumentKey: String] = [:]
    private var pendingPersistTask: Task<Void, Never>?
    private var hasPendingPersist = false

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
        await ChatWorkloadCoordinator.shared.waitUntilChatIsIdle()
        let performanceInterval = PerformanceLogger.begin(
            "DocumentIndexing",
            label: "Document indexing",
            metadata: "characters=\(text.count) sections=\(sections.count) neural=\(UserDefaults.standard.bool(forKey: Self.neuralEmbeddingsDefaultsKey))"
        )
        var indexedChunkCount = 0
        await MemoryProfiler.measure("RAGEngine.ingest(doc: \(documentID))") {
            let language = dominantLanguage(for: text)
            let rawChunks = chunkText(text, targetSize: 900, overlapSentences: 1)
            indexedChunkCount = rawChunks.count
            let embeddings = await embedDocumentChunks(rawChunks.map(\.content), language: language)

            for (index, chunkContent) in rawChunks.enumerated() {
                if let embedded = embeddings[index] {
                    let chunk = TextChunk(
                        conversationID: conversationID,
                        documentID: documentID,
                        content: chunkContent.content,
                        sourceLocationLabel: sourceLocationLabel(for: chunkContent, sections: sections),
                        language: language,
                        sequenceIndex: index,
                        embedding: embedded.vector,
                        embedderID: embedded.embedderID
                    )
                    chunks.append(chunk)
                }
            }

            documentFingerprints[DocumentKey(conversationID: conversationID, documentID: documentID)] = contentHash(for: text)
            schedulePersistState()
        }
        await releaseNeuralEmbedderIfNeeded()
        PerformanceLogger.end(
            performanceInterval,
            metadata: "chunks=\(indexedChunkCount)"
        )
    }

    func clear(documentID: UUID, conversationID: UUID) {
        chunks.removeAll { $0.documentID == documentID && $0.conversationID == conversationID }
        documentFingerprints.removeValue(forKey: DocumentKey(conversationID: conversationID, documentID: documentID))
        schedulePersistState()
    }

    func clearConversation(_ conversationID: UUID) {
        chunks.removeAll { $0.conversationID == conversationID }
        documentFingerprints = documentFingerprints.filter { $0.key.conversationID != conversationID }
        schedulePersistState()
    }

    /// Duplicates already-computed chunks into another conversation scope.
    /// Returns the document IDs that had a complete source fingerprint; callers
    /// can ingest any missing documents normally.
    func cloneConversationIndex(
        from sourceConversationID: UUID,
        to targetConversationID: UUID,
        documentIDs: Set<UUID>
    ) -> Set<UUID> {
        guard sourceConversationID != targetConversationID, !documentIDs.isEmpty else { return [] }

        chunks.removeAll {
            $0.conversationID == targetConversationID && documentIDs.contains($0.documentID)
        }
        for documentID in documentIDs {
            documentFingerprints.removeValue(
                forKey: DocumentKey(conversationID: targetConversationID, documentID: documentID)
            )
        }

        let sourceChunks = chunks.filter {
            $0.conversationID == sourceConversationID && documentIDs.contains($0.documentID)
        }
        chunks.append(contentsOf: sourceChunks.map { chunk in
            TextChunk(
                conversationID: targetConversationID,
                documentID: chunk.documentID,
                content: chunk.content,
                sourceLocationLabel: chunk.sourceLocationLabel,
                language: chunk.language,
                sequenceIndex: chunk.sequenceIndex,
                embedding: chunk.embedding,
                embedderID: chunk.embedderID
            )
        })

        var clonedDocumentIDs: Set<UUID> = []
        for documentID in documentIDs {
            let sourceKey = DocumentKey(conversationID: sourceConversationID, documentID: documentID)
            guard let fingerprint = documentFingerprints[sourceKey] else { continue }
            let targetKey = DocumentKey(conversationID: targetConversationID, documentID: documentID)
            documentFingerprints[targetKey] = fingerprint
            clonedDocumentIDs.insert(documentID)
        }
        schedulePersistState()
        return clonedDocumentIDs
    }

    func clearAll() {
        chunks.removeAll()
        documentFingerprints.removeAll()
        persistStateImmediately()
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
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        hasPendingPersist = false
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
                await ChatWorkloadCoordinator.shared.waitUntilChatIsIdle()
                let language = dominantLanguage(for: document.content)
                let rawChunks = chunkText(document.content, targetSize: 900, overlapSentences: 1)
                let embeddings = await embedDocumentChunks(rawChunks.map(\.content), language: language)

                for (index, chunkContent) in rawChunks.enumerated() {
                    if let embedded = embeddings[index] {
                        rebuiltChunks.append(
                            TextChunk(
                                conversationID: document.conversationID,
                                documentID: document.documentID,
                                content: chunkContent.content,
                                sourceLocationLabel: sourceLocationLabel(for: chunkContent, sections: document.sections),
                                language: language,
                                sequenceIndex: index,
                                embedding: embedded.vector,
                                embedderID: embedded.embedderID
                            )
                        )
                    }
                }

                rebuiltFingerprints[DocumentKey(conversationID: document.conversationID, documentID: document.documentID)] = contentHash(for: document.content)
            }

            chunks = rebuiltChunks
            documentFingerprints = rebuiltFingerprints
            persistStateImmediately()
        }
        await releaseNeuralEmbedderIfNeeded()
    }

    /// Retrieves the most relevant chunks across one or more scopes. Passing both a
    /// conversation's ID and the shared library scope lets a chat search its own
    /// attached documents and the persistent library in a single ranked pass.
    func retrieveDetailed(query: String, limit: Int = 3, conversationIDs: Set<UUID>) async -> [RetrievedChunk] {
        let scopedChunks = chunks.filter { conversationIDs.contains($0.conversationID) }
        guard !scopedChunks.isEmpty else { return [] }

        let queryLanguage = dominantLanguage(for: query)
        let normalizedQuery = normalizedSearchText(query)
        let queryTerms = searchTerms(in: query)
        let lexicalSummary = lexicalSearchSummary(
            scopedChunks,
            queryTerms: queryTerms,
            normalizedQuery: normalizedQuery
        )
        let shouldUseSemanticSearch = shouldUseSemanticSearch(
            lexicalSummary: lexicalSummary,
            queryTerms: queryTerms
        )
        let hasNeuralChunks = scopedChunks.contains { $0.embedderID == EmbeddingService.embedderIdentifier }
        let queryEmbedding = shouldUseSemanticSearch
            ? await embedQuery(query, language: queryLanguage, allowNeural: hasNeuralChunks)
            : nil

        if queryEmbedding?.embedderID == EmbeddingService.embedderIdentifier {
            await EmbeddingService.shared.unload()
        }

        guard queryEmbedding != nil || !queryTerms.isEmpty else { return [] }

        let ranked = rankedCandidates(
            scopedChunks,
            queryEmbedding: queryEmbedding,
            queryLanguage: queryLanguage,
            queryTerms: queryTerms,
            normalizedQuery: normalizedQuery,
            limit: limit
        )

        guard let topScore = ranked.first?.score else { return [] }

        let minimumScore = max(0.16, topScore * 0.55)
        var perDocumentCount: [UUID: Int] = [:]
        var selectedCandidates: [(chunk: TextChunk, score: Double)] = []

        for candidate in ranked {
            guard candidate.score >= minimumScore || candidate.lexicalScore >= 0.45 || selectedCandidates.isEmpty else { break }

            let currentDocumentHits = perDocumentCount[candidate.chunk.documentID, default: 0]
            guard currentDocumentHits < 3 else { continue }

            selectedCandidates.append((chunk: candidate.chunk, score: candidate.score))
            perDocumentCount[candidate.chunk.documentID, default: 0] += 1

            if selectedCandidates.count == max(limit * 2, limit) {
                break
            }
        }

        let mergedCandidates = mergeAdjacentCandidates(expandingNeighbours(of: selectedCandidates, within: scopedChunks))
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

    private func schedulePersistState() {
        hasPendingPersist = true
        pendingPersistTask?.cancel()
        pendingPersistTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.persistenceDebounceNanoseconds)
            } catch {
                return
            }
            await self?.flushPendingPersistState()
        }
    }

    private func flushPendingPersistState() {
        guard hasPendingPersist else { return }
        persistStateImmediately()
    }

    private func persistStateImmediately() {
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        hasPendingPersist = false

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
        }
    }

    private func loadPersistedState() -> PersistedState? {
        do {
            return try SecureFileStore.load(PersistedState.self, from: persistenceURL)
        } catch {
            return nil
        }
    }

    private var neuralEmbeddingsEnabled: Bool {
        false
    }

    private func releaseNeuralEmbedderIfNeeded() async {
        if neuralEmbeddingsEnabled {
            await EmbeddingService.shared.unload()
        }
    }

    private func lexicalSearchSummary(
        _ scopedChunks: [TextChunk],
        queryTerms: [String],
        normalizedQuery: String
    ) -> LexicalSearchSummary? {
        guard !scopedChunks.isEmpty else { return nil }

        var bestScore = 0.0
        var bestLexicalScore = 0.0
        var bestPhraseScore = 0.0
        var strongMatchCount = 0

        for chunk in scopedChunks {
            let lexicalScore = lexicalSimilarity(queryTerms: queryTerms, candidateText: chunk.content)
            let phraseScore = phraseMatchScore(normalizedQuery: normalizedQuery, candidateText: chunk.content)
            let combinedScore = lexicalScore * 0.27 + phraseScore * 0.05

            if combinedScore > bestScore {
                bestScore = combinedScore
                bestLexicalScore = lexicalScore
                bestPhraseScore = phraseScore
            }

            if phraseScore >= 0.65 || lexicalScore >= 0.55 {
                strongMatchCount += 1
            }
        }

        return LexicalSearchSummary(
            bestLexicalScore: bestLexicalScore,
            bestPhraseScore: bestPhraseScore,
            strongMatchCount: strongMatchCount
        )
    }

    private func shouldUseSemanticSearch(
        lexicalSummary: LexicalSearchSummary?,
        queryTerms: [String]
    ) -> Bool {
        guard neuralEmbeddingsEnabled else { return true }
        guard !queryTerms.isEmpty else { return true }
        guard let lexicalSummary else { return true }

        if lexicalSummary.bestPhraseScore >= 1 || lexicalSummary.bestLexicalScore >= 0.72 {
            return false
        }

        return lexicalSummary.strongMatchCount < 3
    }

    private func rankedCandidates(
        _ scopedChunks: [TextChunk],
        queryEmbedding: (vector: [Float], embedderID: String)?,
        queryLanguage: NLLanguage?,
        queryTerms: [String],
        normalizedQuery: String,
        limit: Int
    ) -> [(chunk: TextChunk, score: Double, lexicalScore: Double)] {
        let rankingPoolSize = max(limit * 16, 64)
        var ranked: [(chunk: TextChunk, score: Double, lexicalScore: Double)] = []
        ranked.reserveCapacity(rankingPoolSize)

        for chunk in scopedChunks {
            // Only compare vectors from the same embedder; otherwise rely on
            // lexical/phrase signals so mixed-embedder indexes still work.
            let semanticScore: Double
            if let queryEmbedding, queryEmbedding.embedderID == chunk.embedderID {
                semanticScore = max(0, cosineSimilarity(queryEmbedding.vector, chunk.embedding))
            } else {
                semanticScore = 0
            }
            let lexicalScore = lexicalSimilarity(queryTerms: queryTerms, candidateText: chunk.content)
            let phraseScore = phraseMatchScore(normalizedQuery: normalizedQuery, candidateText: chunk.content)
            let languageMultiplier = languageCompatibilityMultiplier(queryLanguage: queryLanguage, chunkLanguage: chunk.language)
            let candidate = RetrievalCandidate(
                chunk: chunk,
                semanticScore: semanticScore * languageMultiplier,
                lexicalScore: lexicalScore,
                phraseScore: phraseScore
            )

            ranked.append((chunk: chunk, score: candidate.score, lexicalScore: lexicalScore))
            ranked.sort { $0.score > $1.score }
            if ranked.count > rankingPoolSize {
                ranked.removeLast()
            }
        }

        return ranked
    }

    /// Embeds document chunks, aligned 1:1 with `texts` (nil entries are skipped
    /// by callers). Uses the neural embedder when enabled and available, otherwise
    /// falls back to NLEmbedding.
    private func embedDocumentChunks(
        _ texts: [String],
        language: NLLanguage?
    ) async -> [(vector: [Float], embedderID: String)?] {
        if neuralEmbeddingsEnabled,
           let vectors = await EmbeddingService.shared.embed(texts, kind: .document),
           vectors.count == texts.count {
            return vectors.map { ($0, EmbeddingService.embedderIdentifier) }
        }

        var results: [(vector: [Float], embedderID: String)?] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            await ChatWorkloadCoordinator.shared.waitUntilChatIsIdle()
            results.append(
                legacyEmbedding(for: text, language: language).map { ($0, Self.legacyEmbedderID) }
            )
        }
        return results
    }

    private func embedQuery(
        _ text: String,
        language: NLLanguage?,
        allowNeural: Bool
    ) async -> (vector: [Float], embedderID: String)? {
        if allowNeural,
           neuralEmbeddingsEnabled,
           let vectors = await EmbeddingService.shared.embed([text], kind: .query),
           let vector = vectors.first {
            return (vector, EmbeddingService.embedderIdentifier)
        }

        return legacyEmbedding(for: text, language: language).map { ($0, Self.legacyEmbedderID) }
    }

    private func legacyEmbedding(for text: String, language: NLLanguage?) -> [Float]? {
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

    private func languageCompatibilityMultiplier(queryLanguage: NLLanguage?, chunkLanguage: NLLanguage?) -> Double {
        guard let queryLanguage, let chunkLanguage else { return 1.0 }
        guard queryLanguage != chunkLanguage else { return 1.0 }

        // Language detection is noisy for short questions, acronyms, code, and OCR text.
        // Penalize cross-language semantic matches instead of discarding potentially exact lexical hits.
        return 0.82
    }

    private func lexicalSimilarity(queryTerms: [String], candidateText: String) -> Double {
        guard !queryTerms.isEmpty else { return 0 }

        let candidateTerms = searchTerms(in: candidateText)
        guard !candidateTerms.isEmpty else { return 0 }

        let candidateCounts = candidateTerms.reduce(into: [String: Int]()) { counts, term in
            counts[term, default: 0] += 1
        }
        let uniqueQueryTerms = Array(Set(queryTerms))
        let matchedTerms = uniqueQueryTerms.filter { candidateCounts[$0, default: 0] > 0 }
        guard !matchedTerms.isEmpty else { return 0 }

        let coverage = Double(matchedTerms.count) / Double(uniqueQueryTerms.count)
        let frequency = matchedTerms.reduce(0.0) { partialResult, term in
            partialResult + min(1.0, Double(candidateCounts[term, default: 0]) / 3.0)
        } / Double(uniqueQueryTerms.count)

        return min(1.0, coverage * 0.75 + frequency * 0.25)
    }

    private func phraseMatchScore(normalizedQuery: String, candidateText: String) -> Double {
        guard normalizedQuery.count >= 12 else { return 0 }
        let normalizedCandidate = normalizedSearchText(candidateText)
        if normalizedCandidate.contains(normalizedQuery) {
            return 1.0
        }

        let queryWords = normalizedQuery.split(separator: " ")
        guard queryWords.count >= 4 else { return 0 }

        let phraseLength = min(6, queryWords.count)
        for startIndex in 0...(queryWords.count - phraseLength) {
            let phrase = queryWords[startIndex..<(startIndex + phraseLength)].joined(separator: " ")
            if normalizedCandidate.contains(phrase) {
                return 0.65
            }
        }

        return 0
    }

    private func searchTerms(in text: String) -> [String] {
        normalizedSearchText(text)
            .split(separator: " ")
            .map(String.init)
            .filter { term in
                guard term.count >= 2 else { return false }
                return !Self.stopWords.contains(term)
            }
    }

    private func normalizedSearchText(_ text: String) -> String {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        var result = ""
        result.reserveCapacity(folded.count)

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                result.append(" ")
            }
        }

        return result
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "can", "could",
        "de", "der", "die", "das", "des", "du", "el", "en", "et", "for",
        "from", "how", "i", "if", "in", "is", "it", "la", "le", "les",
        "me", "mit", "of", "on", "or", "que", "show", "summarize", "tell",
        "that", "the", "their", "this", "to", "und", "was", "what", "when",
        "where", "which", "who", "why", "with", "you", "your"
    ]

    /// Widens each document's best hit to the chunks either side of it.
    ///
    /// Chunking packs sentences to a character target with no regard for where a
    /// clause begins or ends, so a provision longer than that target is split
    /// across consecutive chunks. Scored independently, the half that phrases
    /// the question wins and the half carrying the rest of the answer can miss
    /// the cut entirely — a lease clause whose notice period and its fee land in
    /// different chunks answers only half of "what are my obligations".
    ///
    /// Only the top hit per document is widened, so the added context stays
    /// bounded at two chunks per document rather than scaling with `limit`, and
    /// neighbours are scored below the hit that pulled them in so they never
    /// displace a directly matched chunk in the final ranking.
    /// `mergeAdjacentCandidates` then stitches each run back into one passage.
    private func expandingNeighbours(
        of selected: [(chunk: TextChunk, score: Double)],
        within scopedChunks: [TextChunk]
    ) -> [(chunk: TextChunk, score: Double)] {
        guard !selected.isEmpty else { return selected }

        func key(_ chunk: TextChunk) -> String {
            "\(chunk.conversationID)|\(chunk.documentID)|\(chunk.sequenceIndex)"
        }
        func neighbourKey(_ chunk: TextChunk, offset: Int) -> String {
            "\(chunk.conversationID)|\(chunk.documentID)|\(chunk.sequenceIndex + offset)"
        }

        var chunksByKey: [String: TextChunk] = [:]
        for chunk in scopedChunks {
            chunksByKey[key(chunk)] = chunk
        }

        var present = Set(selected.map { key($0.chunk) })
        var bestByDocument: [UUID: (chunk: TextChunk, score: Double)] = [:]
        for candidate in selected {
            if let existing = bestByDocument[candidate.chunk.documentID], existing.score >= candidate.score {
                continue
            }
            bestByDocument[candidate.chunk.documentID] = candidate
        }

        var expanded = selected
        for candidate in bestByDocument.values {
            for offset in [-1, 1] {
                let neighbour = neighbourKey(candidate.chunk, offset: offset)
                guard !present.contains(neighbour), let chunk = chunksByKey[neighbour] else { continue }
                present.insert(neighbour)
                expanded.append((chunk: chunk, score: candidate.score * 0.5))
            }
        }
        return expanded
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
                        embedding: first.chunk.embedding,
                        embedderID: first.chunk.embedderID
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
