#if os(macOS)
import Accelerate
#endif
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
        #if os(macOS)
        let raw = defaults.string(forKey: AIRetrievalMode.defaultsKey) ?? AIRetrievalMode.scheme1Lexical.rawValue
        guard let mode = AIRetrievalMode(rawValue: raw) else { throw AIRetrievalError.invalidSelection }
        if mode == .scheme1Lexical { return .lexical }
        guard let id = defaults.string(forKey: packageDefaultsKey),
              id.count == 64, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw AIRetrievalError.modelMissing
        }
        return Self(mode: mode, packageID: id)
        #else
        // iPad currently supports the actual BM25 workflow only.
        return .lexical
        #endif
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
    private let searcher: AISimpleLexicalSearcher

    init(
        registry: AISegmentRegistry,
        preparedIndex: AIBM25PreparedIndex? = nil
    ) throws {
        self.registry = registry
        let index: AIBM25PreparedIndex
        if let preparedIndex {
            index = preparedIndex
        } else {
            index = try AIBM25PreparedIndex(
                records: AIRetrievalWindow.indexRecords(from: registry.records)
            )
        }
        self.searcher = AISimpleLexicalSearcher(
            preparedIndex: index
        )
    }

    func search(_ request: AISegmentSearchRequest) async throws -> [AISegmentSearchResult] {
        try Task.checkCancellation()
        return searcher.search(request, in: registry)
    }
}

#if os(macOS)
nonisolated struct AIEmbeddingChunk: Codable, Equatable, Sendable {
    let anchorID: AISegmentID
    let ids: [AISegmentID]
    let tokens: [Int32]

    init(anchorID: AISegmentID, ids: [AISegmentID], tokens: [Int32]) {
        // A token-budget split can contain only an edge sentence while still
        // representing the parent window. The anchor therefore need not occur
        // in every physical embedding chunk.
        precondition(!ids.isEmpty)
        self.anchorID = anchorID
        self.ids = ids
        self.tokens = tokens
    }

    /// Diagnostic convenience for single-sentence chunks. Production window
    /// construction always supplies the explicit anchor.
    init(ids: [AISegmentID], tokens: [Int32]) {
        precondition(!ids.isEmpty)
        self.init(anchorID: ids[ids.count / 2], ids: ids, tokens: tokens)
    }

    static func make(registry: AISegmentRegistry, tokenizer: AIBertWordPieceTokenizer,
                     maximumChunks: Int = 20_000) throws -> [Self] {
        let limit = min(20_000, max(0, maximumChunks))
        var chunks: [Self] = []
        func append(_ chunk: Self) throws {
            guard chunks.count < limit else { throw AIRetrievalError.indexTooLarge }
            chunks.append(chunk)
        }

        for window in AIRetrievalWindow.make(records: registry.records) {
            try Task.checkCancellation()
            var ids: [AISegmentID] = []
            var tokens: [Int32] = []
            func flush() throws {
                if !ids.isEmpty {
                    try append(Self(anchorID: window.anchorID, ids: ids, tokens: tokens))
                    ids = []
                    tokens = []
                }
            }

            for record in window.records {
                try Task.checkCancellation()
                let part = tokenizer.tokens(record.text)
                if part.count > 510 {
                    try flush()
                    // PDF extraction can produce a page-sized sentence. Embed every
                    // token in order and map each subchunk back to the window anchor.
                    for start in stride(from: 0, to: part.count, by: 510) {
                        try Task.checkCancellation()
                        try append(Self(
                            anchorID: window.anchorID,
                            ids: [record.id],
                            tokens: Array(part[start..<min(start + 510, part.count)])
                        ))
                    }
                    continue
                }
                if !ids.isEmpty && tokens.count + part.count > 254 {
                    try flush()
                }
                ids.append(record.id)
                tokens += part
            }
            try flush()
        }
        return chunks
    }
}

#endif

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

#if os(macOS)
actor AIHybridEvidenceRetriever: AIEvidenceRetrieving {
    private let registry: AISegmentRegistry
    private let embedder: any AIQueryEmbedding
    private let chunks: [AIEmbeddingChunk]
    private let vectors: [[Float]]
    nonisolated let indexedChunkCount: Int

    init(
        registry: AISegmentRegistry,
        embedder: any AIQueryEmbedding,
        chunks: [AIEmbeddingChunk],
        vectors: [[Float]]
    ) throws {
        self.registry = registry; self.embedder = embedder; self.chunks = chunks; self.vectors = vectors
        self.indexedChunkCount = chunks.count
    }

    func search(_ request: AISegmentSearchRequest) async throws -> [AISegmentSearchResult] {
        try Task.checkCancellation()
        let limit = min(100, max(1, request.topK))
        let pool = AIRetrievalFusionConfiguration.frozen.candidatePoolSize(forResultLimit: limit)
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let vector = try await embedder.embedQuery(query.isEmpty ? "main findings methods results limitations conclusion" : query)
        let denseIDs = Array(try rankedDenseSegments(vector: vector, scope: request.scope).prefix(pool).map(\.id))
        return Self.finalizeDenseResults(
            denseIDs,
            limit: limit,
            strategy: request.strategy
        )
    }

    nonisolated static func finalizeDenseResults(
        _ denseIDs: [AISegmentID],
        limit: Int,
        strategy: AISegmentSearchStrategy
    ) -> [AISegmentSearchResult] {
        let fused = Self.fuse(lexical: [], dense: denseIDs)
        if strategy == .overviewSalience {
            return Self.distributeAcrossPages(fused, limit: limit)
        }
        return Array(fused.prefix(limit))
    }

    /// Promotes the first candidate from each page while preserving the
    /// original relative order within both the promoted and deferred groups.
    nonisolated static func distributeAcrossPages(
        _ ranked: [AISegmentSearchResult],
        limit: Int
    ) -> [AISegmentSearchResult] {
        guard limit > 0 else { return [] }
        var pages = Set<Int>()
        var firstPerPage: [AISegmentSearchResult] = []
        var remaining: [AISegmentSearchResult] = []
        for candidate in ranked {
            if pages.insert(candidate.id.page).inserted {
                firstPerPage.append(candidate)
            } else {
                remaining.append(candidate)
            }
        }
        return Array((firstPerPage + remaining).prefix(limit))
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
            // Filter before ranking. Multiple subchunks map to one stable window
            // anchor and contribute at most one candidate to the pool.
            guard chunk.ids.allSatisfy(scope.includes) else { continue }
            let score = Double(vDSP.dot(vector, vectors[index]))
            scores[chunk.anchorID] = max(scores[chunk.anchorID] ?? -.infinity, score)
        }
        return scores.map { AISegmentSearchResult(id: $0.key, score: $0.value) }
            .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
    }

    nonisolated static func fuse(lexical: [AISegmentID], dense: [AISegmentID]) -> [AISegmentSearchResult] {
        AIRetrievalFusion.fuse(lexical: lexical, dense: dense, configuration: .frozen)
    }
}

#endif

/// One canonical (D001) index per file; this adapter alone maps request ordinals.
nonisolated struct AIMultiSourceEvidenceRetriever: AIEvidenceRetrieving {
    struct Source: Sendable {
        let documentNumber: Int
        let retriever: any AIEvidenceRetrieving
    }
    let sources: [Source]
    let mode: AIRetrievalMode
    var registry: AISegmentRegistry? = nil
    private let globalLexicalSearcher: AISimpleLexicalSearcher?

    init(
        sources: [Source],
        mode: AIRetrievalMode,
        registry: AISegmentRegistry? = nil,
        globalLexicalIndex: AIBM25PreparedIndex? = nil
    ) throws {
        self.sources = sources
        self.mode = mode
        self.registry = registry
        if mode == .scheme2EvidenceRAG {
            #if os(macOS)
            guard globalLexicalIndex == nil,
                  sources.allSatisfy({ $0.retriever is AIHybridEvidenceRetriever }) else {
                throw AIRetrievalError.invalidSelection
            }
            self.globalLexicalSearcher = nil
            return
            #else
            throw AIRetrievalError.invalidSelection
            #endif
        }
        guard let registry else {
            self.globalLexicalSearcher = nil
            return
        }
        let preparedNumbers = Set(sources.map(\.documentNumber))
        let records = AIRetrievalWindow.indexRecords(
            from: registry.records.filter { preparedNumbers.contains($0.id.document) }
        )
        let index: AIBM25PreparedIndex
        if let globalLexicalIndex {
            index = globalLexicalIndex
        } else {
            index = try AIBM25PreparedIndex(records: records)
        }
        self.globalLexicalSearcher = AISimpleLexicalSearcher(
            preparedIndex: index
        )
    }

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
            if mode == .scheme2EvidenceRAG {
                #if os(macOS)
                guard let hybrid = source.retriever as? AIHybridEvidenceRetriever else {
                    throw AIRetrievalError.invalidSelection
                }
                let localDense = try await hybrid.denseCandidates(localRequest).map { result in
                    AISegmentSearchResult(id: AISegmentID(document: number, page: result.id.page,
                        block: result.id.block, sentence: result.id.sentence), score: result.score)
                }
                denseCandidates += localDense
                let localLimit = min(100, max(1, request.topK))
                let localPool = AIRetrievalFusionConfiguration.frozen.candidatePoolSize(
                    forResultLimit: localLimit
                )
                rankings.append(AIHybridEvidenceRetriever.finalizeDenseResults(
                    Array(localDense.prefix(localPool).map(\.id)),
                    limit: localLimit,
                    strategy: request.strategy
                ))
                #else
                throw AIRetrievalError.invalidSelection
                #endif
            } else {
                let results = try await source.retriever.search(localRequest)
                rankings.append(results.map { result in
                    AISegmentSearchResult(id: AISegmentID(document: number, page: result.id.page,
                        block: result.id.block, sentence: result.id.sentence), score: result.score)
                })
            }
        }
        let limit = min(100, max(1, request.topK))
        guard let registry else { return Self.balance(rankings, limit: limit) }
        let pool = AIRetrievalFusionConfiguration.frozen.candidatePoolSize(forResultLimit: limit)
        let ranked: [AISegmentSearchResult]
        if mode == .scheme1Lexical {
            guard let globalLexicalSearcher else {
                return Self.balance(rankings, limit: limit)
            }
            // Rank across the fixed corpus before distributing candidates by source.
            // A later selected file must not disappear merely because top_k is small.
            let preparedNumbers = Set(sources.map(\.documentNumber))
            let scopedNumbers = request.scope.documentNumbers.isEmpty
                ? preparedNumbers
                : request.scope.documentNumbers.intersection(preparedNumbers)
            guard !scopedNumbers.isEmpty else {
                return Self.balance(rankings, limit: limit)
            }
            let scopedBlocks = request.scope.blockIDs.filter {
                preparedNumbers.contains($0.document)
            }
            guard request.scope.blockIDs.isEmpty || !scopedBlocks.isEmpty else {
                return Self.balance(rankings, limit: limit)
            }
            let preparedScope = AISegmentScope(
                pageRange: request.scope.pageRange,
                blockIDs: scopedBlocks,
                documentNumbers: scopedNumbers
            )
            ranked = Array(globalLexicalSearcher.rankedCandidates(AISegmentSearchRequest(
                query: request.query,
                scope: preparedScope,
                topK: 100,
                strategy: request.strategy
            ), in: registry)
                .prefix(pool))
        } else {
            #if os(macOS)
            denseCandidates.sort { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
            let dense = Array(denseCandidates.prefix(pool))
            // Scheme 2 constructs and queries only the dense channel. Keeping
            // fusion here preserves the frozen rank-only scoring identity.
            ranked = AIHybridEvidenceRetriever.fuse(
                lexical: [],
                dense: dense.map(\.id)
            )
            #else
            throw AIRetrievalError.invalidSelection
            #endif
        }
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
        let sourceRankings = order.compactMap { documentNumber -> [AISegmentSearchResult]? in
            guard let candidates = grouped[documentNumber] else { return nil }
            #if os(macOS)
            guard mode == .scheme2EvidenceRAG,
                  request.strategy == .overviewSalience else {
                return candidates
            }
            // Global dense/RRF scores choose each source's candidate set. Reapply
            // the overview contract inside each source before round-robin source
            // balancing so a run of high-scoring segments from one page cannot
            // erase the child's page distribution.
            return AIHybridEvidenceRetriever.distributeAcrossPages(
                candidates,
                limit: candidates.count
            )
            #else
            return candidates
            #endif
        }
        return Self.balance(sourceRankings, limit: limit)
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

#if os(macOS)
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

#endif

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

#if os(macOS)
nonisolated protocol AITextEmbedding: AIQueryEmbedding {
    var tokenizer: AIBertWordPieceTokenizer { get }
    func embed(tokens: [Int32]) async throws -> [Float]
}
#endif
