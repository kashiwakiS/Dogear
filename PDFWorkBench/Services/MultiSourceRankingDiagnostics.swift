import Foundation

nonisolated enum MultiSourceRankingDiagnostics {
    struct Report { let checks: Int; let failures: [String] }
    static func run() async -> Report {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { checks += 1; if !condition { failures.append(message) } }
        do {
            let sources = (1...20).map { number in
                let text = number == 20 ? "Zirconium battery coating retained forty percent more capacity." : "Battery methods describe temperature and routine measurements."
                return AIWorkflowSourceSnapshot(fileID: UUID(), displayName: "same.pdf",
                    snapshot: AIHighlightTextSnapshot(fingerprint: "source-\(number)",
                        pages: [AITextPageSnapshot(pageNumber: 1, text: text, fingerprint: "page-\(number)")]))
            }
            let registry = try AISegmentRegistry(sources: sources)
            let lexical = try await AIEvidenceRetrievalFactory.makeSources(selection: .lexical, registry: registry)
            let query = AISegmentSearchRequest(query: "zirconium battery", topK: 1)
            let lexicalResult = try await lexical.retriever.search(query)
            check(lexicalResult.first?.id.document == 20, "Focused lexical search lost a relevant later source when topK was below source count.")
            check(lexicalResult.count == 1, "Focused search exceeded its requested candidate budget.")
            let broad = try await lexical.retriever.search(AISegmentSearchRequest(query: "battery", topK: 20))
            check(Set(broad.map(\.id.document)).count == 20, "Broad lexical search lost source diversity.")
            let reversed = try AISegmentRegistry(sources: Array(sources.reversed()))
            let reordered = try await AIEvidenceRetrievalFactory.makeSources(selection: .lexical, registry: reversed)
            let reorderedResult = try await reordered.retriever.search(query)
            check(reorderedResult.first?.id.document == 1, "Source ordering overrode lexical relevance.")
            let children = registry.sources.map { source in
                let local = registry.registry(forDocument: source.documentNumber, canonicalIDs: true)
                let chunks = local.records.map { AIEmbeddingChunk(ids: [$0.id], tokens: [1]) }
                let vector: [Float] = source.documentNumber == 20 ? [1, 0] : [0, 1]
                return AIMultiSourceEvidenceRetriever.Source(documentNumber: source.documentNumber,
                    retriever: AIHybridEvidenceRetriever(registry: local, embedder: Query(), chunks: chunks,
                        vectors: chunks.map { _ in vector }))
            }
            let hybrid = AIMultiSourceEvidenceRetriever(sources: children, registry: registry)
            let semantic = try await hybrid.search(AISegmentSearchRequest(query: "unseen paraphrase", topK: 1))
            check(semantic.first?.id.document == 20, "Global normalized cosine ranking lost a relevant later source.")
            let scoped = try await hybrid.search(AISegmentSearchRequest(query: "unseen paraphrase",
                scope: AISegmentScope(documentNumbers: [5]), topK: 1))
            check(scoped.count == 1 && scoped.first?.id.document == 5, "Global ranking escaped the explicit source scope.")
            let broadHybrid = try await hybrid.search(AISegmentSearchRequest(query: "battery", topK: 20))
            check(Set(broadHybrid.map(\.id.document)).count == 20, "Global hybrid ranking lost broad source diversity.")
        } catch { check(false, "Global ranking diagnostics failed: \(error)") }
        return Report(checks: checks, failures: failures)
    }
    private struct Query: AIQueryEmbedding {
        func embedQuery(_ text: String) async throws -> [Float] { [1, 0] }
    }
}
