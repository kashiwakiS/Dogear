import Accelerate
import CryptoKit
import Foundation

nonisolated enum AIRetrievalMode: String, CaseIterable, Sendable {
    case scheme1Lexical
    case scheme2EvidenceRAG
    static let defaultsKey = "PDFWorkBench.AIRetrievalMode"
}

nonisolated struct AIRetrievalSelection: Sendable {
    let mode: AIRetrievalMode
    let packageID: String?
    static let lexical = AIRetrievalSelection(mode: .scheme1Lexical, packageID: nil)
    static let packageDefaultsKey = "PDFWorkBench.AIEmbeddingPackage"

    static func capture(from defaults: UserDefaults) throws -> Self {
        let raw = defaults.string(forKey: AIRetrievalMode.defaultsKey) ?? AIRetrievalMode.scheme1Lexical.rawValue
        guard let mode = AIRetrievalMode(rawValue: raw) else { throw AIRetrievalError.invalidSelection }
        if mode == .scheme1Lexical { return .lexical }
        guard let id = defaults.string(forKey: packageDefaultsKey),
              id.count == 64, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw AIRetrievalError.modelMissing
        }
        return Self(mode: mode, packageID: id)
    }
}

nonisolated enum AIRetrievalError: LocalizedError, Equatable {
    case invalidSelection, modelMissing, invalidModel, invalidVector, inputTooLong, indexTooLarge, preparationTimedOut
    var errorDescription: String? {
        switch self {
        case .preparationTimedOut: "Source preparation exceeded its time budget. Narrow the source set or use lightweight retrieval."
        case .invalidSelection: "Choose a supported retrieval mode in Settings."
        case .modelMissing: "Import the BGE Small EN model in Settings before using semantic retrieval."
        case .invalidModel: "The local embedding model is invalid or incompatible. Import a verified model package."
        case .invalidVector: "The local embedding model returned invalid vectors. No result was accepted."
        case .inputTooLong: "The search query exceeds this model's token limit. Shorten the query; no text was silently truncated."
        case .indexTooLarge: "This source exceeds the remaining local embedding index budget. Narrow the source set or choose lightweight retrieval."
        }
    }
}

nonisolated protocol AIEvidenceRetrieving: Sendable {
    func search(_ request: AISegmentSearchRequest) async throws -> [AISegmentSearchResult]
}

nonisolated struct AILexicalEvidenceRetriever: AIEvidenceRetrieving {
    let registry: AISegmentRegistry
    func search(_ request: AISegmentSearchRequest) async throws -> [AISegmentSearchResult] {
        try Task.checkCancellation()
        return AISimpleLexicalSearcher().search(request, in: registry)
    }
}

nonisolated struct AIEmbeddingChunk: Codable, Equatable, Sendable {
    let ids: [AISegmentID]
    let tokens: [Int32]

    static func make(registry: AISegmentRegistry, tokenizer: AIBertWordPieceTokenizer,
                     maximumChunks: Int = 20_000) throws -> [Self] {
        let limit = min(20_000, max(0, maximumChunks))
        var chunks: [Self] = []
        var ids: [AISegmentID] = []
        var tokens: [Int32] = []
        func append(_ chunk: Self) throws {
            guard chunks.count < limit else { throw AIRetrievalError.indexTooLarge }
            chunks.append(chunk)
        }
        func flush() throws {
            if !ids.isEmpty { try append(Self(ids: ids, tokens: tokens)); ids = []; tokens = [] }
        }
        for record in registry.records {
            try Task.checkCancellation()
            let part = tokenizer.tokens(record.text)
            if part.count > 510 {
                try flush()
                // PDF extraction can produce a page-sized sentence. Embed every token
                // in order while keeping the immutable sentence and its locator intact.
                // Retrieval resolves all subchunks back to this one evidence record.
                for start in stride(from: 0, to: part.count, by: 510) {
                    try Task.checkCancellation()
                    try append(Self(ids: [record.id], tokens: Array(part[start..<min(start + 510, part.count)])))
                }
                continue
            }
            if let previous = ids.last,
               previous.document != record.id.document || previous.page != record.id.page
                || previous.block != record.id.block || previous.sentence + 1 != record.id.sentence
                || tokens.count + part.count > 254 || ids.count >= 3 {
                try flush()
            }
            ids.append(record.id); tokens += part
        }
        try flush()
        return chunks
    }
}

nonisolated enum AIRetrievalHash {
    static func data(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    static func file(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

actor AIHybridEvidenceRetriever: AIEvidenceRetrieving {
    private let registry: AISegmentRegistry
    private let embedder: any AIQueryEmbedding
    private let chunks: [AIEmbeddingChunk]
    private let vectors: [[Float]]
    nonisolated let indexedChunkCount: Int

    init(registry: AISegmentRegistry, embedder: any AIQueryEmbedding, chunks: [AIEmbeddingChunk], vectors: [[Float]]) {
        self.registry = registry; self.embedder = embedder; self.chunks = chunks; self.vectors = vectors
        self.indexedChunkCount = chunks.count
    }

    func search(_ request: AISegmentSearchRequest) async throws -> [AISegmentSearchResult] {
        try Task.checkCancellation()
        let limit = min(100, max(1, request.topK))
        let pool = min(100, max(24, limit * 3))
        let lexical = AISimpleLexicalSearcher().search(AISegmentSearchRequest(
            query: request.query, scope: request.scope, topK: pool, strategy: request.strategy
        ), in: registry)
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let vector = try await embedder.embedQuery(query.isEmpty ? "main findings methods results limitations conclusion" : query)
        let denseIDs = Array(try rankedDenseSegments(vector: vector, scope: request.scope).prefix(pool).map(\.id))
        let fused = Self.fuse(lexical: lexical.map(\.id), dense: denseIDs)
        if request.strategy == .overviewSalience {
            // Preserve first-pass page distribution, then fill by rank.
            var pages = Set<Int>()
            let distributed = fused.filter { pages.insert($0.id.page).inserted }
            let picked = Set(distributed.prefix(limit).map(\.id))
            return Array((Array(distributed.prefix(limit)) + fused.filter { !picked.contains($0.id) }).prefix(limit))
        }
        return Array(fused.prefix(limit))
    }

    /// Raw cosine scores are comparable across files using the same normalized model.
    func denseCandidates(_ request: AISegmentSearchRequest) async throws -> [AISegmentSearchResult] {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let vector = try await embedder.embedQuery(query.isEmpty ? "main findings methods results limitations conclusion" : query)
        return Array(try rankedDenseSegments(vector: vector, scope: request.scope).prefix(100))
    }

    private func rankedDenseSegments(vector: [Float], scope: AISegmentScope) throws -> [AISegmentSearchResult] {
        var scores: [AISegmentID: Double] = [:]
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            // Filter before ranking. Multiple subchunks must not crowd one sentence
            // into the candidate pool repeatedly or inflate its fusion score.
            guard chunk.ids.allSatisfy(scope.includes) else { continue }
            let score = Double(vDSP.dot(vector, vectors[index]))
            for id in chunk.ids { scores[id] = max(scores[id] ?? -.infinity, score) }
        }
        return scores.map { AISegmentSearchResult(id: $0.key, score: $0.value) }
            .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
    }

    nonisolated static func fuse(lexical: [AISegmentID], dense: [AISegmentID]) -> [AISegmentSearchResult] {
        var scores: [AISegmentID: Double] = [:]
        for ranking in [lexical, dense] {
            var seen = Set<AISegmentID>()
            for (rank, id) in ranking.enumerated() where seen.insert(id).inserted {
                scores[id, default: 0] += 1.0 / Double(60 + rank + 1)
            }
        }
        return scores.map { AISegmentSearchResult(id: $0.key, score: $0.value) }
            .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
    }
}

/// One canonical (D001) index per file; this adapter alone maps request ordinals.
nonisolated struct AIMultiSourceEvidenceRetriever: AIEvidenceRetrieving {
    struct Source: Sendable {
        let documentNumber: Int
        let retriever: any AIEvidenceRetrieving
    }
    let sources: [Source]
    var registry: AISegmentRegistry? = nil

    func search(_ request: AISegmentSearchRequest) async throws -> [AISegmentSearchResult] {
        var rankings: [[AISegmentSearchResult]] = []
        var denseCandidates: [AISegmentSearchResult] = []
        for source in sources {
            try Task.checkCancellation()
            let number = source.documentNumber
            guard request.scope.documentNumbers.isEmpty || request.scope.documentNumbers.contains(number) else { continue }
            let blocks = request.scope.blockIDs.filter { $0.document == number }
            if !request.scope.blockIDs.isEmpty && blocks.isEmpty { continue }
            let localScope = AISegmentScope(pageRange: request.scope.pageRange,
                blockIDs: Set(blocks.map { AISegmentID(document: 1, page: $0.page, block: $0.block, sentence: $0.sentence) }))
            let localRequest = AISegmentSearchRequest(query: request.query,
                scope: localScope, topK: request.topK, strategy: request.strategy)
            let results = try await source.retriever.search(localRequest)
            if let hybrid = source.retriever as? AIHybridEvidenceRetriever {
                denseCandidates += try await hybrid.denseCandidates(localRequest).map { result in
                    AISegmentSearchResult(id: AISegmentID(document: number, page: result.id.page,
                        block: result.id.block, sentence: result.id.sentence), score: result.score)
                }
            }
            rankings.append(results.map { result in
                AISegmentSearchResult(id: AISegmentID(document: number, page: result.id.page,
                    block: result.id.block, sentence: result.id.sentence), score: result.score)
            })
        }
        let limit = min(100, max(1, request.topK))
        guard let registry else { return Self.balance(rankings, limit: limit) }
        // Rank across the fixed corpus before distributing candidates by source.
        // A later selected file must not disappear merely because top_k is small.
        let preparedNumbers = Set(sources.map(\.documentNumber))
        let lexical = AISimpleLexicalSearcher().search(AISegmentSearchRequest(query: request.query,
            scope: request.scope, topK: 100, strategy: request.strategy), in: registry)
            .filter { preparedNumbers.contains($0.id.document) }
        denseCandidates.sort { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        let ranked = denseCandidates.isEmpty ? lexical : AIHybridEvidenceRetriever.fuse(
            lexical: lexical.map(\.id), dense: denseCandidates.map(\.id))
        var byID = Dictionary(uniqueKeysWithValues: ranked.map { ($0.id, $0) })
        for candidate in rankings.flatMap({ $0 }) where byID[candidate.id] == nil {
            byID[candidate.id] = AISegmentSearchResult(id: candidate.id, score: 0)
        }
        let sorted = byID.values.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        var order: [Int] = []
        var grouped: [Int: [AISegmentSearchResult]] = [:]
        for candidate in sorted {
            if grouped[candidate.id.document] == nil { order.append(candidate.id.document) }
            grouped[candidate.id.document, default: []].append(candidate)
        }
        return Self.balance(order.compactMap { grouped[$0] }, limit: limit)
    }

    static func balance(_ rankings: [[AISegmentSearchResult]], limit: Int) -> [AISegmentSearchResult] {
        var results: [AISegmentSearchResult] = []
        var rank = 0
        // Distribute within the caller's globally ranked source order; retain each file's candidate order.
        while results.count < limit {
            var added = false
            for ranking in rankings where rank < ranking.count {
                results.append(ranking[rank])
                added = true
                if results.count == limit { break }
            }
            if !added { break }
            rank += 1
        }
        return results
    }
}

nonisolated protocol AIQueryEmbedding: Sendable {
    func embedQuery(_ text: String) async throws -> [Float]
}

/// Per-request shared query cache. Child file searches run cooperatively in order.
actor AICachedQueryEmbedder: AIQueryEmbedding {
    private let base: any AIQueryEmbedding
    private var cache: [String: [Float]] = [:]
    init(base: any AIQueryEmbedding) { self.base = base }
    func embedQuery(_ text: String) async throws -> [Float] {
        try Task.checkCancellation()
        if let value = cache[text] { return value }
        let value = try await base.embedQuery(text)
        try Task.checkCancellation()
        if cache.count >= 64 { cache.removeAll(keepingCapacity: true) }
        cache[text] = value
        return value
    }
}

nonisolated struct AIMultiSourceCoverage: Sendable, Equatable {
    struct Skipped: Sendable, Equatable {
        let documentNumber: Int
        let fileID: UUID
        let reason: String
    }
    var requestedCount = 0
    var preparedFileIDs: [UUID] = []
    var skipped: [Skipped] = []
    var usedFileIDs: [UUID] = []

    func withUsedDocuments(_ numbers: Set<Int>, registry: AISegmentRegistry) -> Self {
        var value = self
        value.usedFileIDs = registry.sources.filter { numbers.contains($0.documentNumber) }.map(\.fileID)
        return value
    }
}

nonisolated struct AIMultiSourceRetrievalPreparation: Sendable {
    let retriever: any AIEvidenceRetrieving
    let coverage: AIMultiSourceCoverage
}

nonisolated protocol AITextEmbedding: AIQueryEmbedding {
    var tokenizer: AIBertWordPieceTokenizer { get }
    func embed(tokens: [Int32]) async throws -> [Float]
}
