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
    case invalidSelection, modelMissing, invalidModel, invalidVector, inputTooLong, indexTooLarge
    var errorDescription: String? {
        switch self {
        case .invalidSelection: "Choose a supported retrieval mode in Settings."
        case .modelMissing: "Import the BGE Small EN model in Settings before using semantic retrieval."
        case .invalidModel: "The local embedding model is invalid or incompatible. Import a verified model package."
        case .invalidVector: "The local embedding model returned invalid vectors. No result was accepted."
        case .inputTooLong: "A source sentence or search query exceeds this model's token limit. No text was silently truncated."
        case .indexTooLarge: "This document exceeds the local embedding index limit. Choose lightweight retrieval."
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

    static func make(registry: AISegmentRegistry, tokenizer: AIBertWordPieceTokenizer) throws -> [Self] {
        var chunks: [Self] = []
        var ids: [AISegmentID] = []
        var tokens: [Int32] = []
        func flush() {
            if !ids.isEmpty { chunks.append(Self(ids: ids, tokens: tokens)); ids = []; tokens = [] }
        }
        for record in registry.records {
            try Task.checkCancellation()
            let part = tokenizer.tokens(record.text)
            guard part.count <= 510 else { throw AIRetrievalError.inputTooLong }
            if let previous = ids.last,
               previous.document != record.id.document || previous.page != record.id.page
                || previous.block != record.id.block || previous.sentence + 1 != record.id.sentence
                || tokens.count + part.count > 254 || ids.count >= 3 {
                flush()
            }
            ids.append(record.id); tokens += part
        }
        flush()
        guard chunks.count <= 20_000 else { throw AIRetrievalError.indexTooLarge }
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
    private let embedder: AICoreMLEmbedder
    private let chunks: [AIEmbeddingChunk]
    private let vectors: [[Float]]

    init(registry: AISegmentRegistry, embedder: AICoreMLEmbedder, chunks: [AIEmbeddingChunk], vectors: [[Float]]) {
        self.registry = registry; self.embedder = embedder; self.chunks = chunks; self.vectors = vectors
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
        var dense: [(AISegmentID, Float)] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            // Chunks never cross a page or block; filter before ranking, not after truncation.
            guard chunk.ids.allSatisfy(request.scope.includes) else { continue }
            let score = vDSP.dot(vector, vectors[index])
            dense += chunk.ids.map { ($0, score) }
        }
        dense.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        let denseIDs = Array(dense.prefix(pool).map(\.0))
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
