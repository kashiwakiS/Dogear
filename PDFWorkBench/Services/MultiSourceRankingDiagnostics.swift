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
            let children = try registry.sources.map { source in
                let local = registry.registry(forDocument: source.documentNumber, canonicalIDs: true)
                let chunks = local.records.map { AIEmbeddingChunk(ids: [$0.id], tokens: [1]) }
                let vector: [Float] = source.documentNumber == 20 ? [1, 0] : [0, 1]
                return AIMultiSourceEvidenceRetriever.Source(documentNumber: source.documentNumber,
                    retriever: try AIHybridEvidenceRetriever(registry: local, embedder: Query(), chunks: chunks,
                        vectors: chunks.map { _ in vector }))
            }
            let hybrid = try AIMultiSourceEvidenceRetriever(
                sources: children,
                mode: .scheme2EvidenceRAG,
                registry: registry
            )
            let semantic = try await hybrid.search(AISegmentSearchRequest(query: "unseen paraphrase", topK: 1))
            check(semantic.first?.id.document == 20, "Global normalized cosine ranking lost a relevant later source.")
            let scoped = try await hybrid.search(AISegmentSearchRequest(query: "unseen paraphrase",
                scope: AISegmentScope(documentNumbers: [5]), topK: 1))
            check(scoped.count == 1 && scoped.first?.id.document == 5, "Global ranking escaped the explicit source scope.")
            let broadHybrid = try await hybrid.search(AISegmentSearchRequest(query: "battery", topK: 20))
            check(Set(broadHybrid.map(\.id.document)).count == 20, "Global hybrid ranking lost broad source diversity.")

            // With topK=1 the frozen pool contains 24 candidates. Source 25 is
            // lexical rank 1 but dense rank 25; its zero-weight lexical rank
            // must not admit it from outside the dense channel pool.
            let poolSources = (1...25).map { number in
                AIWorkflowSourceSnapshot(
                    fileID: UUID(),
                    displayName: "pool-\(number).pdf",
                    snapshot: AIHighlightTextSnapshot(
                        fingerprint: "pool-source-\(number)",
                        pages: [AITextPageSnapshot(
                            pageNumber: 1,
                            text: number == 25 ? "Zirconium marker." : "Unrelated evidence.",
                            fingerprint: "pool-page-\(number)"
                        )]
                    )
                )
            }
            let poolRegistry = try AISegmentRegistry(sources: poolSources)
            let poolChildren = try poolRegistry.sources.map { source in
                let local = poolRegistry.registry(forDocument: source.documentNumber, canonicalIDs: true)
                let chunks = local.records.map { AIEmbeddingChunk(ids: [$0.id], tokens: [1]) }
                let denseScore = Float(26 - source.documentNumber) / 25
                return AIMultiSourceEvidenceRetriever.Source(
                    documentNumber: source.documentNumber,
                    retriever: try AIHybridEvidenceRetriever(
                        registry: local,
                        embedder: Query(),
                        chunks: chunks,
                        vectors: chunks.map { _ in [denseScore, 0] }
                    )
                )
            }
            let pooledHybrid = try AIMultiSourceEvidenceRetriever(
                sources: poolChildren,
                mode: .scheme2EvidenceRAG,
                registry: poolRegistry
            )
            let pooledTop = try await pooledHybrid.search(
                AISegmentSearchRequest(query: "zirconium", topK: 1)
            )
            check(
                pooledTop.first?.id.document == 1,
                "Multi-source hybrid fused a dense candidate outside the frozen channel pool."
            )

            // Scheme 2 must not reinterpret BM25 as a fallback when its dense
            // pool is empty under the frozen 1/0 configuration. Scheme 1 still
            // serves the same lexical evidence through BM25.
            let emptyDenseSources = [AIWorkflowSourceSnapshot(
                fileID: UUID(),
                displayName: "dense-empty.pdf",
                snapshot: AIHighlightTextSnapshot(
                    fingerprint: "dense-empty-source",
                    pages: [AITextPageSnapshot(
                        pageNumber: 1,
                        text: "Lexical fallback marker.",
                        fingerprint: "dense-empty-page"
                    )]
                )
            )]
            let emptyDenseRegistry = try AISegmentRegistry(sources: emptyDenseSources)
            let emptyDenseLocal = emptyDenseRegistry.registry(
                forDocument: 1,
                canonicalIDs: true
            )
            let emptyDenseHybrid = try AIMultiSourceEvidenceRetriever(
                sources: [.init(
                    documentNumber: 1,
                    retriever: try AIHybridEvidenceRetriever(
                        registry: emptyDenseLocal,
                        embedder: Query(),
                        chunks: [],
                        vectors: []
                    )
                )],
                mode: .scheme2EvidenceRAG,
                registry: emptyDenseRegistry
            )
            let emptyDenseRequest = AISegmentSearchRequest(
                query: "lexical fallback marker",
                topK: 5
            )
            let emptyDenseHybridResults = try await emptyDenseHybrid.search(emptyDenseRequest)
            check(
                emptyDenseHybridResults.isEmpty,
                "Multi-source Scheme 2 bypassed zero lexical weight when dense was empty."
            )
            let emptyDenseLexical = try await AIEvidenceRetrievalFactory.makeSources(
                selection: .lexical,
                registry: emptyDenseRegistry
            )
            let emptyDenseLexicalResults = try await emptyDenseLexical.retriever.search(
                emptyDenseRequest
            )
            check(
                emptyDenseLexicalResults.count == 1
                    && emptyDenseLexicalResults.first?.id.document == 1,
                "Multi-source Scheme 1 lost BM25 while removing Scheme 2 fallback."
            )
        } catch { check(false, "Global ranking diagnostics failed: \(error)") }
        return Report(checks: checks, failures: failures)
    }
    private struct Query: AIQueryEmbedding {
        func embedQuery(_ text: String) async throws -> [Float] { [1, 0] }
    }
}
