import Foundation

/// Scheme 1 preparation is shared by native front ends. Only the Mac extension
/// composes Dense embeddings; iPad requests cannot initialize a model backend.
nonisolated enum AIEvidenceRetrievalFactory {
    static func makeSources(
        selection: AIRetrievalSelection,
        registry: AISegmentRegistry,
        progress: (@Sendable (Int, Int) async -> Void)? = nil,
        indexed: (@Sendable (Int, Bool, Double) async -> Void)? = nil,
        cacheRoot: URL? = nil,
        maximumRequestChunks: Int = 20_000,
        lexicalBackend: (any AILexicalIndexBackend)? = nil,
        lexicalPreparationBudget: Duration = .seconds(180)
    ) async throws -> AIMultiSourceRetrievalPreparation {
        if selection.mode == .scheme1Lexical {
            return try await makeSharedLexicalSources(
                registry: registry,
                backend: lexicalBackend ?? AISharedMemoryBM25IndexBackend.shared,
                started: .now,
                preparationBudget: lexicalPreparationBudget
            )
        }
        #if os(macOS)
        return try await makeSources(selection: selection, registry: registry,
            progress: progress, indexed: indexed, sharedEmbedder: nil,
            cacheRoot: cacheRoot, maximumRequestChunks: maximumRequestChunks,
            lexicalBackend: lexicalBackend, lexicalPreparationBudget: lexicalPreparationBudget)
        #else
        throw AIRetrievalError.invalidSelection
        #endif
    }

    private static func makeSharedLexicalSources(
        registry: AISegmentRegistry,
        backend: any AILexicalIndexBackend,
        started: ContinuousClock.Instant,
        preparationBudget: Duration
    ) async throws -> AIMultiSourceRetrievalPreparation {
        if registry.sources.isEmpty {
            let source = singleRegistryLexicalSource(registry)
            try checkLexicalPreparationStatus(started: started, preparationBudget: preparationBudget)
            let prepared = try await backend.prepare(source: source)
            try checkLexicalPreparationStatus(started: started, preparationBudget: preparationBudget)
            _ = try validateLexicalPreparedIndex(prepared, sources: [source])
            return AIMultiSourceRetrievalPreparation(
                retriever: try AILexicalEvidenceRetriever(registry: registry, preparedIndex: prepared.bm25),
                coverage: AIMultiSourceCoverage()
            )
        }
        if registry.records.isEmpty {
            try checkLexicalPreparationStatus(started: started, preparationBudget: preparationBudget)
            let prepared = try await backend.prepare(sources: [])
            try checkLexicalPreparationStatus(started: started, preparationBudget: preparationBudget)
            _ = try validateLexicalPreparedIndex(prepared, sources: [])
            return AIMultiSourceRetrievalPreparation(
                retriever: try AILexicalEvidenceRetriever(registry: registry, preparedIndex: prepared.bm25),
                coverage: AIMultiSourceCoverage(requestedCount: registry.sources.count, preparedFileIDs: [],
                    skipped: registry.sources.map { .init(documentNumber: $0.documentNumber, fileID: $0.fileID,
                        reason: "No extractable text; no OCR was performed.") }, usedFileIDs: [])
            )
        }
        return try await makeLexicalSources(registry: registry, backend: backend,
            started: started, preparationBudget: preparationBudget)
    }

    private struct LexicalSourceCandidate {
        let descriptor: AIWorkflowSourceDescriptor
        let registry: AISegmentRegistry
        let indexSource: AILexicalIndexSource
    }

    private static func makeLexicalSources(
        registry: AISegmentRegistry,
        backend: any AILexicalIndexBackend,
        started: ContinuousClock.Instant,
        preparationBudget: Duration
    ) async throws -> AIMultiSourceRetrievalPreparation {
        var candidates: [LexicalSourceCandidate] = []
        var skipped: [AIMultiSourceCoverage.Skipped] = []
        candidates.reserveCapacity(registry.sources.count)
        skipped.reserveCapacity(registry.sources.count)

        for source in registry.sources {
            try Task.checkCancellation()
            let local = registry.registry(forDocument: source.documentNumber, canonicalIDs: true)
            if local.records.isEmpty {
                skipped.append(.init(
                    documentNumber: source.documentNumber,
                    fileID: source.fileID,
                    reason: "No extractable text; no OCR was performed."
                ))
                continue
            }
            candidates.append(LexicalSourceCandidate(
                descriptor: source,
                registry: local,
                indexSource: AILexicalIndexSource(
                    descriptor: AIBM25IndexDescriptor(
                        fileID: source.fileID,
                        // Retrieval artifacts follow extracted page text. Broad
                        // source versions still protect final publication, but
                        // annotation-only PDF rewrites must not rebuild BM25.
                        contentVersion: source.snapshotFingerprint,
                        snapshotFingerprint: source.snapshotFingerprint,
                        segmenterVersion: AIRetrievalWindow.indexVersion(
                            segmenterVersion: registry.segmenterVersion
                        )
                    ),
                    // Persist canonical D001 records while retaining the real
                    // request ordinal for the merged request-wide index.
                    documentNumber: source.documentNumber,
                    records: AIRetrievalWindow.indexRecords(from: local.records)
                )
            ))
        }

        // Lexical preparation is one atomic request. Cancellation remains
        // cooperative inside each backend. A batch that completes within the
        // budget is accepted as a whole; an over-budget batch fails as a whole,
        // so request-wide statistics and reported coverage cannot disagree.
        let orderedCandidates = candidates.sorted {
            $0.descriptor.documentNumber < $1.descriptor.documentNumber
        }
        try checkLexicalPreparationStatus(
            started: started,
            preparationBudget: preparationBudget
        )
        let preparedIndex = try await backend.prepare(
            sources: orderedCandidates.map(\.indexSource)
        )
        try checkLexicalPreparationStatus(
            started: started,
            preparationBudget: preparationBudget
        )
        let shardsByDocument = try validateLexicalPreparedIndex(
            preparedIndex,
            sources: orderedCandidates.map(\.indexSource)
        )

        var children: [AIMultiSourceEvidenceRetriever.Source] = []
        var preparedFileIDs: [UUID] = []
        children.reserveCapacity(orderedCandidates.count)
        preparedFileIDs.reserveCapacity(orderedCandidates.count)
        for candidate in orderedCandidates {
            try Task.checkCancellation()
            guard let shard = shardsByDocument[candidate.descriptor.documentNumber],
                  shard.sourceIdentity == candidate.indexSource.descriptor.canonicalIdentity else {
                throw AIBM25IndexError.invalidIndexData
            }
            children.append(.init(
                documentNumber: candidate.descriptor.documentNumber,
                retriever: try AILexicalEvidenceRetriever(
                    registry: candidate.registry,
                    preparedIndex: shard.bm25
                )
            ))
            preparedFileIDs.append(candidate.descriptor.fileID)
        }

        return AIMultiSourceRetrievalPreparation(
            retriever: try AIMultiSourceEvidenceRetriever(
                sources: children,
                mode: .scheme1Lexical,
                registry: registry,
                globalLexicalIndex: preparedIndex.bm25
            ),
            coverage: AIMultiSourceCoverage(
                requestedCount: registry.sources.count,
                preparedFileIDs: preparedFileIDs,
                skipped: skipped,
                usedFileIDs: []
            )
        )
    }

    private static func checkLexicalPreparationStatus(
        started: ContinuousClock.Instant,
        preparationBudget: Duration
    ) throws {
        try Task.checkCancellation()
        guard started.duration(to: .now) < preparationBudget else {
            throw AIRetrievalError.preparationTimedOut
        }
    }

    private static func validateLexicalPreparedIndex(
        _ preparedIndex: AILexicalPreparedIndex,
        sources: [AILexicalIndexSource]
    ) throws -> [Int: AILexicalPreparedSource] {
        let orderedSources = sources.sorted { $0.documentNumber < $1.documentNumber }
        let expectedDocumentNumbers = orderedSources.map(\.documentNumber)
        let expectedIdentities = orderedSources.map(\.descriptor.canonicalIdentity)
        guard preparedIndex.sourceIdentities == expectedIdentities,
              preparedIndex.preparedSources.map(\.documentNumber) == expectedDocumentNumbers,
              preparedIndex.preparedSources.map(\.sourceIdentity) == expectedIdentities else {
            throw AIBM25IndexError.invalidIndexData
        }

        var shardsByDocument: [Int: AILexicalPreparedSource] = [:]
        shardsByDocument.reserveCapacity(preparedIndex.preparedSources.count)
        var shardValues: [(documentNumber: Int, data: AIBM25IndexData)] = []
        shardValues.reserveCapacity(preparedIndex.preparedSources.count)
        for (source, shard) in zip(orderedSources, preparedIndex.preparedSources) {
            let expectedIDs = Set(source.records.map { record in
                AISegmentID(
                    document: 1,
                    page: record.id.page,
                    block: record.id.block,
                    sentence: record.id.sentence
                )
            })
            guard source.descriptor.tokenizerVersion == preparedIndex.bm25.tokenizer.version,
                  Set(shard.bm25.data.segmentLengths.keys) == expectedIDs,
                  expectedIDs.allSatisfy({ $0.document == 1 }),
                  shard.bm25.tokenizer.version == preparedIndex.bm25.tokenizer.version,
                  shard.bm25.parameters == preparedIndex.bm25.parameters,
                  shardsByDocument.updateValue(shard, forKey: shard.documentNumber) == nil else {
                throw AIBM25IndexError.invalidIndexData
            }
            shardValues.append((shard.documentNumber, shard.bm25.data))
        }
        let mergedShardData = try AILexicalIndexSupport.merge(
            shardValues,
            tokenizer: preparedIndex.bm25.tokenizer
        )
        guard mergedShardData == preparedIndex.bm25.data,
              shardsByDocument.count == orderedSources.count else {
            throw AIBM25IndexError.invalidIndexData
        }
        return shardsByDocument
    }

    private static func singleRegistryLexicalSource(
        _ registry: AISegmentRegistry
    ) -> AILexicalIndexSource {
        let documentNumbers = Set(registry.records.map(\.id.document))
        let documentNumber = documentNumbers.count == 1
            ? documentNumbers.first ?? 1
            : 1
        let digest = AIRetrievalHash.data(
            Data("single-lexical-source-slot-v2|document=\(documentNumber)".utf8)
        )
        let prefix = String(digest.prefix(32))
        let uuidComponents: [String] = [
            String(prefix.prefix(8)),
            String(prefix.dropFirst(8).prefix(4)),
            String(prefix.dropFirst(12).prefix(4)),
            String(prefix.dropFirst(16).prefix(4)),
            String(prefix.dropFirst(20).prefix(12))
        ]
        let uuidText = uuidComponents.joined(separator: "-")
        // SHA-256 hex always forms a valid UUID spelling. Keep an explicit
        // fallback so malformed future hash implementations remain fail-safe.
        let fileID = UUID(uuidString: uuidText)
            ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        return AILexicalIndexSource(
            descriptor: AIBM25IndexDescriptor(
                fileID: fileID,
                contentVersion: registry.snapshotFingerprint,
                snapshotFingerprint: registry.snapshotFingerprint,
                segmenterVersion: AIRetrievalWindow.indexVersion(
                    segmenterVersion: registry.segmenterVersion
                )
            ),
            documentNumber: documentNumber,
            records: AIRetrievalWindow.indexRecords(from: registry.records)
        )
    }
}

#if os(macOS)
extension AIEvidenceRetrievalFactory {
    static func makeSources(
        selection: AIRetrievalSelection,
        registry: AISegmentRegistry,
        progress: (@Sendable (Int, Int) async -> Void)? = nil,
        indexed: (@Sendable (Int, Bool, Double) async -> Void)? = nil,
        sharedEmbedder: (any AITextEmbedding)?,
        cacheRoot: URL? = nil,
        maximumRequestChunks: Int = 20_000,
        lexicalBackend: (any AILexicalIndexBackend)? = nil,
        lexicalPreparationBudget: Duration = .seconds(180)
    ) async throws -> AIMultiSourceRetrievalPreparation {
        if selection.mode == .scheme1Lexical {
            return try await makeSharedLexicalSources(
                registry: registry,
                backend: lexicalBackend ?? AISharedMemoryBM25IndexBackend.shared,
                started: .now,
                preparationBudget: lexicalPreparationBudget
            )
        }
        // Dense composition stays on Mac and never prepares a lexical backend.
        let started = ContinuousClock.now
        let embeddingCache = AISQLiteEmbeddingIndexCache(
            databaseURL: AISQLiteEmbeddingIndexCache.databaseURL(cacheRoot: cacheRoot)
        )
        if registry.sources.isEmpty {
            if registry.records.isEmpty {
                // No authorized text means there is no dense work to do.
                // Return an empty Scheme 2 adapter without loading a model,
                // writing a vector cache, or embedding the later query.
                return AIMultiSourceRetrievalPreparation(
                    retriever: try AIMultiSourceEvidenceRetriever(
                        sources: [],
                        mode: .scheme2EvidenceRAG,
                        registry: registry
                    ),
                    coverage: AIMultiSourceCoverage()
                )
            }
            let retriever = try await make(
                selection: selection,
                registry: registry,
                progress: progress,
                indexed: indexed,
                cacheRoot: cacheRoot,
                sharedEmbedder: sharedEmbedder,
                maximumChunks: maximumRequestChunks,
                lexicalPreparedIndex: nil,
                embeddingCache: embeddingCache
            )
            return AIMultiSourceRetrievalPreparation(
                retriever: retriever,
                coverage: AIMultiSourceCoverage()
            )
        }
        if registry.records.isEmpty {
            return AIMultiSourceRetrievalPreparation(
                retriever: try AIMultiSourceEvidenceRetriever(
                    sources: [],
                    mode: .scheme2EvidenceRAG,
                    registry: registry
                ),
                coverage: AIMultiSourceCoverage(requestedCount: registry.sources.count, preparedFileIDs: [],
                    skipped: registry.sources.map { .init(documentNumber: $0.documentNumber, fileID: $0.fileID,
                        reason: "No extractable text; no OCR was performed.") }, usedFileIDs: [])
            )
        }

        var children: [AIMultiSourceEvidenceRetriever.Source] = []
        var prepared: [UUID] = []
        var skipped: [AIMultiSourceCoverage.Skipped] = []
        var remainingChunks = min(20_000, max(0, maximumRequestChunks))
        guard let package = selection.packageID else { throw AIRetrievalError.modelMissing }
        let embedder: any AITextEmbedding
        if let sharedEmbedder { embedder = sharedEmbedder }
        else { embedder = try await AIEmbeddingModelPool.shared.model(
            packageURL: AILocalEmbeddingModels.packageURL(package), packageID: package) }
        let queryEmbedder: any AIQueryEmbedding = AICachedQueryEmbedder(base: embedder)
        for source in registry.sources {
            try Task.checkCancellation()
            let local = registry.registry(forDocument: source.documentNumber, canonicalIDs: true)
            if local.records.isEmpty {
                skipped.append(.init(documentNumber: source.documentNumber, fileID: source.fileID,
                    reason: "No extractable text; no OCR was performed."))
                continue
            }
            if started.duration(to: .now) >= .seconds(180) {
                skipped.append(.init(documentNumber: source.documentNumber, fileID: source.fileID,
                    reason: "Source preparation time budget exhausted."))
                continue
            }
            do {
                let child = try await make(selection: selection, registry: local,
                    progress: progress, indexed: indexed, cacheRoot: cacheRoot,
                    sharedEmbedder: embedder, queryEmbedder: queryEmbedder,
                    preparationDeadline: started.advanced(by: .seconds(180)), maximumChunks: remainingChunks,
                    lexicalPreparedIndex: nil, embeddingCache: embeddingCache)
                if let hybrid = child as? AIHybridEvidenceRetriever { remainingChunks -= hybrid.indexedChunkCount }
                children.append(.init(documentNumber: source.documentNumber, retriever: child))
                prepared.append(source.fileID)
            } catch is CancellationError { throw CancellationError() }
            catch let error as AIRetrievalError where error == .inputTooLong || error == .indexTooLarge || error == .preparationTimedOut {
                skipped.append(.init(documentNumber: source.documentNumber, fileID: source.fileID,
                    reason: error.localizedDescription))
            }
        }
        return AIMultiSourceRetrievalPreparation(retriever: try AIMultiSourceEvidenceRetriever(
            sources: children,
            mode: selection.mode,
            registry: registry,
            globalLexicalIndex: nil
        ),
            coverage: AIMultiSourceCoverage(requestedCount: registry.sources.count,
                preparedFileIDs: prepared, skipped: skipped, usedFileIDs: []))
    }

    static func make(
        selection: AIRetrievalSelection,
        registry: AISegmentRegistry,
        progress: (@Sendable (Int, Int) async -> Void)? = nil,
        indexed: (@Sendable (Int, Bool, Double) async -> Void)? = nil,
        packageURL: URL? = nil,
        cacheRoot: URL? = nil,
        sharedEmbedder: (any AITextEmbedding)? = nil,
        queryEmbedder: (any AIQueryEmbedding)? = nil,
        preparationDeadline: ContinuousClock.Instant? = nil,
        maximumChunks: Int = 20_000,
        lexicalPreparedIndex: AIBM25PreparedIndex? = nil,
        embeddingCache: AISQLiteEmbeddingIndexCache? = nil
    ) async throws -> any AIEvidenceRetrieving {
        guard selection.mode == .scheme2EvidenceRAG else {
            return try AILexicalEvidenceRetriever(
                registry: registry,
                preparedIndex: lexicalPreparedIndex
            )
        }
        let started = Date()
        guard let packageID = selection.packageID else { throw AIRetrievalError.modelMissing }
        await progress?(0, 0)
        try Task.checkCancellation()
        let embedder: any AITextEmbedding
        if let sharedEmbedder { embedder = sharedEmbedder }
        else { embedder = try await AIEmbeddingModelPool.shared.model(
            packageURL: packageURL ?? AILocalEmbeddingModels.packageURL(packageID), packageID: packageID) }
        let chunks = try AIEmbeddingChunk.make(registry: registry, tokenizer: embedder.tokenizer,
            maximumChunks: maximumChunks)
        if let preparationDeadline, ContinuousClock.now >= preparationDeadline { throw AIRetrievalError.preparationTimedOut }
        let descriptor = try AIEmbeddingCacheDescriptor(
            registry: registry,
            packageID: packageID,
            dimensions: 384,
            chunks: chunks
        )
        let cache = embeddingCache ?? AISQLiteEmbeddingIndexCache(
            databaseURL: AISQLiteEmbeddingIndexCache.databaseURL(cacheRoot: cacheRoot)
        )
        var vectors: [[Float]] = []
        var cacheHit = false
        if let cached = try await cache.loadBestEffort(
            descriptor: descriptor,
            chunks: chunks
        ) {
            vectors = cached
            cacheHit = true
            await progress?(chunks.count, chunks.count)
        } else {
            await progress?(0, chunks.count)
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                if let preparationDeadline, ContinuousClock.now >= preparationDeadline { throw AIRetrievalError.preparationTimedOut }
                vectors.append(try await embedder.embed(tokens: chunk.tokens))
                if let preparationDeadline, ContinuousClock.now >= preparationDeadline { throw AIRetrievalError.preparationTimedOut }
                await progress?(index + 1, chunks.count)
            }
            try Task.checkCancellation()
            // Persistence is a derived optimization. A corrupt, unavailable or
            // unwritable cache must not discard vectors already computed for
            // this request; cancellation still propagates.
            _ = try await cache.storeBestEffort(
                descriptor: descriptor,
                chunks: chunks,
                vectors: vectors
            )
        }
        try Task.checkCancellation()
        if let preparationDeadline, ContinuousClock.now >= preparationDeadline { throw AIRetrievalError.preparationTimedOut }
        await indexed?(chunks.count, cacheHit, Date().timeIntervalSince(started))
        return try AIHybridEvidenceRetriever(
            registry: registry,
            embedder: queryEmbedder ?? AICachedQueryEmbedder(base: embedder),
            chunks: chunks,
            vectors: vectors
        )
    }
}
#endif
