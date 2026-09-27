import Foundation
import SQLite3
import Darwin

nonisolated enum AIPersistentLexicalIndexDiagnostics {
    struct Measurements: Sendable {
        let coldPrepareSeconds: Double
        let warmPrepareSeconds: Double
        let restartPrepareSeconds: Double
        let databaseMetrics: AILexicalIndexDatabaseMetrics
    }

    struct Report: Sendable {
        let checks: Int
        let failures: [String]
        let measurements: Measurements?
    }

    static func run() async -> Report {
        var checks = 0
        var failures: [String] = []
        var measurements: Measurements?
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("DogearPersistentLexical-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: root) }

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            let databaseURL = root.appendingPathComponent("main/index-v1.sqlite3")
            let policy = temporaryPolicy(databaseURL)
            let fileID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
            let source = fixtureSource(
                fileID: fileID,
                contentVersion: "content-v1",
                snapshot: "snapshot-v1",
                segmenter: "segmenter-v1",
                documentNumber: 1,
                texts: [
                    "PRIVATE SENTINEL ORIGINAL PASSAGE 82917. Alpha target appears once.",
                    "Beta target target describes A100-SXM4.",
                    "注意力机制降低显存占用。"
                ]
            )
            let query = AISegmentSearchRequest(query: "target A100-SXM4", topK: 10)
            let memory = try await AIInMemoryBM25IndexBackend().prepare(source: source)
            let sqlite = AISQLiteBM25IndexBackend(storagePolicy: policy)
            let cold = try await sqlite.prepare(source: source)
            check(cold.metadata.backend == .sqlite && cold.metadata.cacheHits == 0
                && cold.metadata.cacheMisses == 1 && cold.metadata.fallbackReason == nil,
                  "SQLite cold preparation did not build exactly one persistent generation.")
            check(cold.indexData == memory.indexData && cold.search(query) == memory.search(query),
                  "SQLite cold data or ranking diverged from the memory backend.")

            let warm = try await sqlite.prepare(source: source)
            check(warm.metadata.backend == .sqlite && warm.metadata.cacheHits == 1
                && warm.metadata.cacheMisses == 0,
                  "Same-process warm preparation did not hit the immutable generation.")
            check(warm.indexData == cold.indexData && warm.search(query) == cold.search(query),
                  "Same-process cache hit changed BM25 values or ranking.")
            await sqlite.close()

            let restartedStore = AISQLiteBM25IndexBackend(storagePolicy: policy)
            let restarted = try await restartedStore.prepare(source: source)
            check(restarted.metadata.backend == .sqlite && restarted.metadata.cacheHits == 1,
                  "A newly opened store did not hit the persisted generation.")
            check(restarted.indexData == cold.indexData && restarted.search(query) == cold.search(query),
                  "Restart cache hit changed BM25 values or ranking.")
            if let metrics = restarted.metadata.databaseMetrics {
                measurements = Measurements(
                    coldPrepareSeconds: cold.metadata.preparationSeconds,
                    warmPrepareSeconds: warm.metadata.preparationSeconds,
                    restartPrepareSeconds: restarted.metadata.preparationSeconds,
                    databaseMetrics: metrics
                )
                check(metrics.databaseBytes > 0 && metrics.totalBytes >= metrics.databaseBytes,
                      "Database/WAL/SHM size metrics were not reported.")
            } else {
                check(false, "Persistent preparation omitted database size metrics.")
            }
            let restartGenerationCount = try await restartedStore.generationCount()
            check(restartGenerationCount == 1,
                  "Cold/warm/restart preparation created duplicate generations.")

            await restartedStore.close()
            let schema = try inspectDatabase(databaseURL)
            check(schema.applicationID == 0x444F4745 && schema.userVersion == 1,
                  "SQLite application_id or user_version is not frozen.")
            check(schema.tables == Set([
                "index_metadata", "source_generation", "segment", "term",
                "source_term_stat", "posting"
            ]), "SQLite schema is missing required minimal tables.")
            check(schema.indexes.contains("source_term_stat_by_term"),
                  "SQLite schema is missing the targeted orphan-cleanup index.")
            check(!schema.columns.contains("text") && !schema.columns.contains("query")
                && !schema.columns.contains("answer") && !schema.columns.contains("api_key"),
                  "SQLite schema introduced full text, query, answer, or secret columns.")
            let rawDatabase = try Data(contentsOf: databaseURL)
            check(rawDatabase.range(of: Data("PRIVATE SENTINEL ORIGINAL PASSAGE 82917".utf8)) == nil,
                  "SQLite persisted the sentinel source passage verbatim.")
            check(rawDatabase.range(of: Data("provider-secret-fixture".utf8)) == nil,
                  "SQLite unexpectedly contains provider data.")
            check(fileMode(root.appendingPathComponent("main")) == 0o700,
                  "Lexical cache directory is not owner-only.")
            check(fileMode(databaseURL) == 0o600,
                  "Lexical SQLite database is not owner-only.")
            check(try diagnosticOwnershipAttributeData(at: databaseURL) != nil,
                  "Lexical cache ownership xattr is missing.")
            let sidecars = [databaseURL.path + "-wal", databaseURL.path + "-shm"]
                .map(URL.init(fileURLWithPath:))
                .filter { manager.fileExists(atPath: $0.path) }
            check(sidecars.allSatisfy { fileMode($0) == 0o600 },
                  "SQLite WAL or SHM file is not owner-only.")
            check((try? databaseURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true,
                  "Lexical database is not excluded from backup.")

            // Fully loaded values remain queryable after their generation is
            // deleted, which is the no-lease cleanup contract.
            let retainedValue = restarted
            let reopenedForRemoval = AISQLiteBM25IndexBackend(storagePolicy: policy)
            try await reopenedForRemoval.removeGeneration(identity: source.descriptor.canonicalIdentity)
            let generationCountAfterRemoval = try await reopenedForRemoval.generationCount()
            check(generationCountAfterRemoval == 0,
                  "Explicit generation deletion left queryable database rows.")
            check(retainedValue.search(query) == memory.search(query),
                  "Deleting derived cache invalidated an active pure-value prepared index.")

            // Add/update/delete and a deterministic rebuild all retain the same
            // semantics while each content version replaces the old generation.
            let added = fixtureSource(
                fileID: fileID,
                contentVersion: "content-added",
                snapshot: "snapshot-added",
                segmenter: "segmenter-v1",
                documentNumber: 1,
                texts: ["alpha", "beta beta", "gamma"]
            )
            let addedIndex = try await reopenedForRemoval.prepare(source: added)
            check(addedIndex.search(AISegmentSearchRequest(query: "gamma")).count == 1,
                  "Persistent add did not create the new segment posting.")
            let updated = fixtureSource(
                fileID: fileID,
                contentVersion: "content-updated",
                snapshot: "snapshot-updated",
                segmenter: "segmenter-v1",
                documentNumber: 1,
                texts: ["delta", "beta beta", "gamma"]
            )
            let updatedIndex = try await reopenedForRemoval.prepare(source: updated)
            check(updatedIndex.metadata.cacheMisses == 1
                && updatedIndex.search(AISegmentSearchRequest(query: "alpha")).isEmpty
                && updatedIndex.search(AISegmentSearchRequest(query: "delta")).count == 1,
                  "Persistent update reused stale terms or failed to replace the generation.")
            let removed = fixtureSource(
                fileID: fileID,
                contentVersion: "content-removed",
                snapshot: "snapshot-removed",
                segmenter: "segmenter-v1",
                documentNumber: 1,
                texts: ["delta", "gamma"]
            )
            let removedIndex = try await reopenedForRemoval.prepare(source: removed)
            let rebuiltMemory = try await AIInMemoryBM25IndexBackend().prepare(source: removed)
            check(removedIndex.search(AISegmentSearchRequest(query: "beta")).isEmpty,
                  "Persistent delete retained removed postings.")
            check(removedIndex.indexData == rebuiltMemory.indexData
                && removedIndex.search(AISegmentSearchRequest(query: "delta gamma", topK: 10))
                    == rebuiltMemory.search(AISegmentSearchRequest(query: "delta gamma", topK: 10)),
                  "Persistent add/update/delete diverged from a clean memory rebuild.")
            let generationCountAfterUpdate = try await reopenedForRemoval.generationCount()
            check(generationCountAfterUpdate == 1,
                  "A file update retained obsolete content generations.")

            // Every identity field participates in the canonical SHA. Supported
            // current-profile changes miss; a future schema is rejected rather
            // than silently reusing current rows.
            let baseDescriptor = source.descriptor
            let identityVariants = [
                AIBM25IndexDescriptor(fileID: fileID, contentVersion: "other", snapshotFingerprint: baseDescriptor.snapshotFingerprint,
                    segmenterVersion: baseDescriptor.segmenterVersion),
                AIBM25IndexDescriptor(fileID: fileID, contentVersion: baseDescriptor.contentVersion, snapshotFingerprint: "other",
                    segmenterVersion: baseDescriptor.segmenterVersion),
                AIBM25IndexDescriptor(fileID: fileID, contentVersion: baseDescriptor.contentVersion,
                    snapshotFingerprint: baseDescriptor.snapshotFingerprint, segmenterVersion: "other"),
                AIBM25IndexDescriptor(fileID: fileID, contentVersion: baseDescriptor.contentVersion,
                    snapshotFingerprint: baseDescriptor.snapshotFingerprint, segmenterVersion: baseDescriptor.segmenterVersion,
                    tokenizerVersion: "other-tokenizer"),
                AIBM25IndexDescriptor(fileID: fileID, contentVersion: baseDescriptor.contentVersion,
                    snapshotFingerprint: baseDescriptor.snapshotFingerprint, segmenterVersion: baseDescriptor.segmenterVersion,
                    schemaVersion: 2)
            ]
            check(Set(([baseDescriptor] + identityVariants).map(\.canonicalIdentity)).count == 6
                && ([baseDescriptor] + identityVariants).allSatisfy { $0.canonicalIdentity.count == 64 },
                  "A content/snapshot/segmenter/tokenizer/schema change did not change canonical identity.")
            do {
                let invalidSchema = AILexicalIndexSource(
                    descriptor: identityVariants[4], documentNumber: 1, records: source.records
                )
                _ = try await reopenedForRemoval.prepare(source: invalidSchema)
                check(false, "A future lexical schema silently reused the current cache.")
            } catch AILexicalIndexBackendError.schemaMismatch {
                check(true, "A future lexical schema was rejected for rebuild by compatible code.")
            } catch {
                check(false, "Schema invalidation produced an unexpected error: \(error)")
            }

            let tokenizerV2 = AILexicalTokenizer(version: "lexical-fixture-v2")
            let tokenizerSource = AILexicalIndexSource(
                descriptor: AIBM25IndexDescriptor(
                    fileID: fileID,
                    contentVersion: "content-tokenizer-v2",
                    snapshotFingerprint: "snapshot-tokenizer-v2",
                    segmenterVersion: "segmenter-v1",
                    tokenizerVersion: tokenizerV2.version
                ),
                documentNumber: 1,
                records: source.records
            )
            await reopenedForRemoval.close()
            let tokenizerStore = AISQLiteBM25IndexBackend(storagePolicy: policy, tokenizer: tokenizerV2)
            let tokenizerPrepared = try await tokenizerStore.prepare(source: tokenizerSource)
            check(tokenizerPrepared.metadata.cacheMisses == 1,
                  "Tokenizer identity change reused an older token generation.")
            await tokenizerStore.close()

            let multiStore = AISQLiteBM25IndexBackend(storagePolicy: policy)

            // Only selected source data contributes to N/avgdl/df. An unrelated
            // cached source cannot perturb the authorized two-source request.
            let second = fixtureSource(
                fileID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
                contentVersion: "second-v1",
                snapshot: "second-snapshot",
                segmenter: "segmenter-v1",
                documentNumber: 2,
                texts: ["target target second", "other"]
            )
            let first = fixtureSource(
                fileID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
                contentVersion: "first-v1",
                snapshot: "first-snapshot",
                segmenter: "segmenter-v1",
                documentNumber: 1,
                texts: ["target first", "filler"]
            )
            let authorizedMemory = try await AIInMemoryBM25IndexBackend().prepare(sources: [first, second])
            let authorizedSQLite = try await multiStore.prepare(sources: [first, second])
            let orderedAuthorizedSources = [first, second]
                .sorted { $0.documentNumber < $1.documentNumber }
            let expectedAuthorizedIdentities = orderedAuthorizedSources
                .map(\.descriptor.canonicalIdentity)
            let expectedAuthorizedNumbers = orderedAuthorizedSources.map(\.documentNumber)
            check(
                authorizedMemory.sourceIdentities == expectedAuthorizedIdentities
                    && authorizedMemory.preparedSources.map(\.sourceIdentity)
                        == expectedAuthorizedIdentities
                    && authorizedMemory.preparedSources.map(\.documentNumber)
                        == expectedAuthorizedNumbers
                    && authorizedSQLite.sourceIdentities == expectedAuthorizedIdentities
                    && authorizedSQLite.preparedSources.map(\.sourceIdentity)
                        == expectedAuthorizedIdentities
                    && authorizedSQLite.preparedSources.map(\.documentNumber)
                        == expectedAuthorizedNumbers,
                "Memory or SQLite prepared shards were not returned in stable request-document order."
            )
            let sqliteShardIDsMatch = zip(
                orderedAuthorizedSources,
                authorizedSQLite.preparedSources
            ).allSatisfy { pair in
                let canonicalIDs = Set(pair.0.records.map { record in
                    AISegmentID(
                        document: 1,
                        page: record.id.page,
                        block: record.id.block,
                        sentence: record.id.sentence
                    )
                })
                return Set(pair.1.bm25.data.segmentLengths.keys) == canonicalIDs
                    && canonicalIDs.allSatisfy { $0.document == 1 }
            }
            check(
                sqliteShardIDsMatch,
                "SQLite prepared shards did not preserve the canonical D001 segment ID set."
            )
            check(authorizedSQLite.indexData == authorizedMemory.indexData,
                  "Multi-source SQLite merge changed authorized corpus statistics.")
            let documentTwo = AISegmentScope(documentNumbers: [2])
            let scopedStats = authorizedSQLite.bm25.scopedStatistics(query: "target", scope: documentTwo)
            check(scopedStats.segmentCount == 2 && scopedStats.documentFrequency["target"] == 1,
                  "Document scope included another source in BM25 statistics.")
            let pageAndBlock = AISegmentScope(
                pageRange: 1...1,
                blockIDs: [AISegmentID(document: 2, page: 1, block: 1, sentence: 1)],
                documentNumbers: [2]
            )
            let narrowStats = authorizedSQLite.bm25.scopedStatistics(query: "target", scope: pageAndBlock)
            check(narrowStats.segmentCount == 1 && narrowStats.documentFrequency["target"] == 1,
                  "Page/block scope did not recompute statistics over its authorized segment.")
            let unrelated = fixtureSource(
                fileID: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
                contentVersion: "unrelated-v1",
                snapshot: "unrelated-snapshot",
                segmenter: "segmenter-v1",
                documentNumber: 3,
                texts: Array(repeating: "target unrelated", count: 12)
            )
            _ = try await multiStore.prepare(source: unrelated)
            let afterUnrelated = try await multiStore.prepare(sources: [first, second])
            check(afterUnrelated.indexData == authorizedSQLite.indexData
                && afterUnrelated.search(AISegmentSearchRequest(query: "target", topK: 10))
                    == authorizedSQLite.search(AISegmentSearchRequest(query: "target", topK: 10)),
                  "An unselected cached source changed authorized BM25 ranking.")

            // A caller-held value survives bounded LRU cleanup.
            try await multiStore.prune(
                maximumBytes: 1,
                retaining: [second.descriptor.canonicalIdentity]
            )
            let retainedGeneration = try await multiStore.containsGeneration(
                identity: second.descriptor.canonicalIdentity
            )
            let prunedGenerationCount = try await multiStore.generationCount()
            check(retainedGeneration,
                  "LRU cleanup removed an explicitly retained generation.")
            check(prunedGenerationCount == 1,
                  "Bounded LRU cleanup retained non-active derived generations.")
            check(authorizedSQLite.search(AISegmentSearchRequest(query: "target", topK: 10))
                == authorizedMemory.search(AISegmentSearchRequest(query: "target", topK: 10)),
                  "LRU cleanup invalidated an already loaded immutable index.")

            // Exercise the production factory boundary, not only the backend
            // protocol in isolation. Cold, same-process warm and reopened
            // SQLite preparations must produce the exact memory ranking.
            let factorySources = [
                workflowSource(
                    fileID: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
                    version: "factory-one-v1",
                    fingerprint: "factory-one-snapshot",
                    pages: ["Alpha target appears once. Filler sentence.",
                            "A100-SXM4 target target is described here."]
                ),
                workflowSource(
                    fileID: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
                    version: "factory-two-v1",
                    fingerprint: "factory-two-snapshot",
                    pages: ["Unrelated observations only.",
                            "A competing target result appears once."]
                )
            ]
            let factoryRegistry = try AISegmentRegistry(sources: factorySources)
            let factoryRequest = AISegmentSearchRequest(query: "A100-SXM4 target", topK: 10)
            let factoryMemoryBackend = RecordingLexicalBackend()
            let factoryMemory = try await AIEvidenceRetrievalFactory.makeSources(
                selection: .lexical,
                registry: factoryRegistry,
                lexicalBackend: factoryMemoryBackend
            )
            let expectedFactoryRanking = try await factoryMemory.retriever.search(factoryRequest)
            let factoryMemoryCounts = await factoryMemoryBackend.sourceCounts()
            let factoryMemoryDocumentNumbers = await factoryMemoryBackend.documentNumbers()
            check(
                factoryMemoryCounts == [factorySources.count]
                    && factoryMemoryDocumentNumbers == [[1, 2]],
                "The production lexical factory did not prepare populated sources in one batch."
            )
            let factoryURL = root.appendingPathComponent("factory/index.sqlite3")
            let factoryStore = AISQLiteBM25IndexBackend(storagePolicy: temporaryPolicy(factoryURL))
            let factoryCold = try await AIEvidenceRetrievalFactory.makeSources(
                selection: .lexical,
                registry: factoryRegistry,
                lexicalBackend: factoryStore
            )
            let coldTouchTransactions = await factoryStore
                .diagnosticCompletedBatchTouchTransactionCount()
            let factoryWarm = try await AIEvidenceRetrievalFactory.makeSources(
                selection: .lexical,
                registry: factoryRegistry,
                lexicalBackend: factoryStore
            )
            let warmTouchTransactions = await factoryStore
                .diagnosticCompletedBatchTouchTransactionCount()
            check(try await factoryCold.retriever.search(factoryRequest) == expectedFactoryRanking,
                  "Factory-injected SQLite cold ranking diverged from the memory backend.")
            check(try await factoryWarm.retriever.search(factoryRequest) == expectedFactoryRanking,
                  "Factory-injected SQLite warm ranking diverged from the memory backend.")
            check(
                coldTouchTransactions == 0 && warmTouchTransactions == 1,
                "Factory-injected SQLite did not publish all warm touches in one transaction."
            )
            await factoryStore.close()
            let reopenedFactoryStore = AISQLiteBM25IndexBackend(storagePolicy: temporaryPolicy(factoryURL))
            let factoryRestart = try await AIEvidenceRetrievalFactory.makeSources(
                selection: .lexical,
                registry: factoryRegistry,
                lexicalBackend: reopenedFactoryStore
            )
            let restartTouchTransactions = await reopenedFactoryStore
                .diagnosticCompletedBatchTouchTransactionCount()
            check(try await factoryRestart.retriever.search(factoryRequest) == expectedFactoryRanking,
                  "Factory-injected SQLite restart ranking diverged from the memory backend.")
            check(try await reopenedFactoryStore.generationCount() == factorySources.count,
                  "Factory-injected SQLite did not preserve one generation per authorized source.")
            check(
                restartTouchTransactions == 1,
                "Factory-injected SQLite restart used more than one warm-touch transaction."
            )
            try await reopenedFactoryStore.clearDerivedCache()

            // No-text sources remain explicit coverage skips and never split a
            // populated request back into per-source backend calls.
            let mixedEmptySource = workflowSource(
                fileID: UUID(uuidString: "30000000-0000-0000-0000-000000000004")!,
                version: "factory-empty-v1",
                fingerprint: "factory-empty-snapshot",
                pages: []
            )
            let mixedRegistry = try AISegmentRegistry(
                sources: [factorySources[0], mixedEmptySource, factorySources[1]]
            )
            let mixedBackend = RecordingLexicalBackend()
            let mixedPreparation = try await AIEvidenceRetrievalFactory.makeSources(
                selection: .lexical,
                registry: mixedRegistry,
                lexicalBackend: mixedBackend
            )
            let mixedCounts = await mixedBackend.sourceCounts()
            let mixedDocumentNumbers = await mixedBackend.documentNumbers()
            check(
                mixedCounts == [2]
                    && mixedDocumentNumbers == [[1, 3]]
                    && mixedPreparation.coverage.requestedCount == 3
                    && mixedPreparation.coverage.preparedFileIDs
                        == [factorySources[0].fileID, factorySources[1].fileID]
                    && mixedPreparation.coverage.skipped.map(\.fileID) == [mixedEmptySource.fileID],
                "Batched lexical preparation lost populated ordering or no-text skip coverage."
            )
            let mixedResults = try await mixedPreparation.retriever.search(factoryRequest)
            check(
                mixedResults.allSatisfy { $0.id.document == 1 || $0.id.document == 3 },
                "Batched lexical shards were mapped to the wrong request document number."
            )

            // Overview selection reads registry records instead of postings.
            // An unprepared text source must be removed from its scope before
            // the 100-candidate cap, or it can crowd out every prepared source.
            let unpreparedTextSource = workflowSource(
                fileID: UUID(uuidString: "30000000-0000-0000-0000-000000000005")!,
                version: "factory-unprepared-v1",
                fingerprint: "factory-unprepared-snapshot",
                pages: (1...101).map { page in
                    "Conclusion finding result show important method evidence therefore page \(page)."
                }
            )
            let overviewRegistry = try AISegmentRegistry(
                sources: [factorySources[0], unpreparedTextSource, factorySources[1]]
            )
            let overviewDescriptors = overviewRegistry.sources.filter {
                $0.documentNumber == 1 || $0.documentNumber == 3
            }
            let overviewIndexSources = overviewDescriptors.map { descriptor in
                AILexicalIndexSource(
                    descriptor: AIBM25IndexDescriptor(
                        fileID: descriptor.fileID,
                        contentVersion: descriptor.version,
                        snapshotFingerprint: descriptor.snapshotFingerprint,
                        segmenterVersion: overviewRegistry.segmenterVersion
                    ),
                    documentNumber: descriptor.documentNumber,
                    records: overviewRegistry.registry(
                        forDocument: descriptor.documentNumber,
                        canonicalIDs: true
                    ).records
                )
            }
            let overviewPrepared = try await AIInMemoryBM25IndexBackend().prepare(
                sources: overviewIndexSources
            )
            var overviewChildren: [AIMultiSourceEvidenceRetriever.Source] = []
            for (descriptor, shard) in zip(
                overviewDescriptors,
                overviewPrepared.preparedSources
            ) {
                overviewChildren.append(.init(
                    documentNumber: descriptor.documentNumber,
                    retriever: try AILexicalEvidenceRetriever(
                        registry: overviewRegistry.registry(
                            forDocument: descriptor.documentNumber,
                            canonicalIDs: true
                        ),
                        preparedIndex: shard.bm25
                    )
                ))
            }
            let overviewRetriever = try AIMultiSourceEvidenceRetriever(
                sources: overviewChildren,
                mode: .scheme1Lexical,
                registry: overviewRegistry,
                globalLexicalIndex: overviewPrepared.bm25
            )
            let overviewResults = try await overviewRetriever.search(
                AISegmentSearchRequest(
                    query: "",
                    topK: 10,
                    strategy: .overviewSalience
                )
            )
            check(
                !overviewResults.isEmpty
                    && Set(overviewResults.map(\.id.document)).isSubset(of: Set([1, 3])),
                "Overview candidates were truncated or polluted by an unprepared text source."
            )

            let rejectingBackend = RejectingLexicalBackend()
            do {
                _ = try await AIEvidenceRetrievalFactory.makeSources(
                    selection: .lexical,
                    registry: factoryRegistry,
                    lexicalBackend: rejectingBackend
                )
                check(false, "A batched lexical backend failure was swallowed.")
            } catch let error as AIBM25IndexError {
                let rejectingCounts = await rejectingBackend.sourceCounts()
                check(
                    error == .invalidIndexData
                        && rejectingCounts == [factorySources.count],
                    "A batched lexical backend failure changed call or propagation semantics."
                )
            }

            let inconsistentGlobalBackend = InconsistentGlobalLexicalBackend()
            do {
                _ = try await AIEvidenceRetrievalFactory.makeSources(
                    selection: .lexical,
                    registry: factoryRegistry,
                    lexicalBackend: inconsistentGlobalBackend
                )
                check(false, "A lexical backend with unauthorized global postings was accepted.")
            } catch let error as AIBM25IndexError {
                let inconsistentCounts = await inconsistentGlobalBackend.sourceCounts()
                check(
                    error == .invalidIndexData
                        && inconsistentCounts == [factorySources.count],
                    "The lexical factory did not fail closed on a global/shard mismatch."
                )
            }

            // The product budget is checked before work and after one atomic
            // lexical batch. A zero budget must avoid the backend entirely.
            let expiredBeforeBatchBackend = RecordingLexicalBackend()
            do {
                _ = try await AIEvidenceRetrievalFactory.makeSources(
                    selection: .lexical,
                    registry: factoryRegistry,
                    lexicalBackend: expiredBeforeBatchBackend,
                    lexicalPreparationBudget: .zero
                )
                check(false, "An over-budget lexical batch was accepted.")
            } catch let error as AIRetrievalError {
                let expiredCounts = await expiredBeforeBatchBackend.sourceCounts()
                check(
                    error == .preparationTimedOut
                        && expiredCounts.isEmpty,
                    "An already expired lexical batch called the backend or reported the wrong error."
                )
            }

            let expiredAfterBatchBackend = DelayedLexicalBackend(delay: .milliseconds(50))
            do {
                _ = try await AIEvidenceRetrievalFactory.makeSources(
                    selection: .lexical,
                    registry: factoryRegistry,
                    lexicalBackend: expiredAfterBatchBackend,
                    lexicalPreparationBudget: .milliseconds(20)
                )
                check(false, "A completed over-budget lexical batch was accepted.")
            } catch let error as AIRetrievalError {
                let expiredCounts = await expiredAfterBatchBackend.sourceCounts()
                check(
                    error == .preparationTimedOut
                        && expiredCounts == [factorySources.count],
                    "A completed over-budget lexical batch was split or reported with the wrong error."
                )
            }

            let cancelledAfterBatchBackend = SelfCancellingLexicalBackend(
                delay: .milliseconds(50)
            )
            let cancelledAfterBatchTask = Task {
                try await AIEvidenceRetrievalFactory.makeSources(
                    selection: .lexical,
                    registry: factoryRegistry,
                    lexicalBackend: cancelledAfterBatchBackend,
                    lexicalPreparationBudget: .milliseconds(20)
                )
            }
            do {
                _ = try await cancelledAfterBatchTask.value
                check(false, "A cancelled over-budget lexical batch was accepted.")
            } catch is CancellationError {
                check(
                    await cancelledAfterBatchBackend.sourceCounts() == [factorySources.count],
                    "Cancellation precedence changed the lexical batch call count."
                )
            } catch {
                check(false, "A cancelled over-budget lexical batch lost CancellationError.")
            }

            // Legacy single registries and empty-source paths must honor the
            // caller-injected backend rather than silently constructing their
            // own memory index.
            let singleRegistry = try AISegmentRegistry(snapshot: AIHighlightTextSnapshot(
                fingerprint: "single-registry",
                pages: [AITextPageSnapshot(
                    pageNumber: 1,
                    text: "single injected backend target.",
                    fingerprint: "single-registry-page"
                )]
            ), documentNumber: 2)
            let singleBackend = RecordingLexicalBackend()
            let singlePreparation = try await AIEvidenceRetrievalFactory.makeSources(
                selection: .lexical,
                registry: singleRegistry,
                lexicalBackend: singleBackend
            )
            let singleCounts = await singleBackend.sourceCounts()
            let singleResults = try await singlePreparation.retriever.search(
                AISegmentSearchRequest(
                    query: "target",
                    scope: AISegmentScope(documentNumbers: [2])
                )
            )
            let wrongDocumentResults = try await singlePreparation.retriever.search(
                AISegmentSearchRequest(
                    query: "target",
                    scope: AISegmentScope(documentNumbers: [1])
                )
            )
            let updatedSingleRegistry = try AISegmentRegistry(
                snapshot: AIHighlightTextSnapshot(
                    fingerprint: "single-registry-updated",
                    pages: [AITextPageSnapshot(
                        pageNumber: 1,
                        text: "updated single injected backend target.",
                        fingerprint: "single-registry-updated-page"
                    )]
                ),
                documentNumber: 2
            )
            _ = try await AIEvidenceRetrievalFactory.makeSources(
                selection: .lexical,
                registry: updatedSingleRegistry,
                lexicalBackend: singleBackend
            )
            let singleDocumentNumbers = await singleBackend.documentNumbers()
            let singleFileIDs = await singleBackend.fileIDs()
            check(singleCounts == [1]
                && singleResults.map(\.id.document) == [2]
                && wrongDocumentResults.isEmpty
                && singleDocumentNumbers == [[2], [2]]
                && singleFileIDs.count == 2
                && singleFileIDs[0] == singleFileIDs[1],
                  "Single-registry backend injection lost D002 scope or stable cache identity.")

            let malformedSingleBackend = UnexpectedGlobalLexicalBackend()
            do {
                _ = try await AIEvidenceRetrievalFactory.makeSources(
                    selection: .lexical,
                    registry: singleRegistry,
                    lexicalBackend: malformedSingleBackend
                )
                check(false, "A single-registry backend with stale global postings was accepted.")
            } catch let error as AIBM25IndexError {
                let malformedCounts = await malformedSingleBackend.sourceCounts()
                check(
                    error == .invalidIndexData && malformedCounts == [1],
                    "Single-registry prepared-index validation did not fail closed."
                )
            }

            let expiredSingleBackend = RecordingLexicalBackend()
            do {
                _ = try await AIEvidenceRetrievalFactory.makeSources(
                    selection: .lexical,
                    registry: singleRegistry,
                    lexicalBackend: expiredSingleBackend,
                    lexicalPreparationBudget: .zero
                )
                check(false, "An expired single-registry lexical request was accepted.")
            } catch let error as AIRetrievalError {
                let expiredCounts = await expiredSingleBackend.sourceCounts()
                check(
                    error == .preparationTimedOut
                        && expiredCounts.isEmpty,
                    "Single-registry preparation ignored its preflight budget."
                )
            }

            let emptySingleRegistry = try AISegmentRegistry(snapshot: AIHighlightTextSnapshot(
                fingerprint: "empty-single-registry",
                pages: []
            ))
            let emptySingleBackend = RecordingLexicalBackend()
            let emptySinglePreparation = try await AIEvidenceRetrievalFactory.makeSources(
                selection: .lexical,
                registry: emptySingleRegistry,
                lexicalBackend: emptySingleBackend
            )
            let emptySingleCounts = await emptySingleBackend.sourceCounts()
            let emptySingleResults = try await emptySinglePreparation.retriever.search(
                AISegmentSearchRequest(query: "target")
            )
            check(emptySingleCounts == [1] && emptySingleResults.isEmpty,
                  "Empty single-registry path ignored its injected backend.")

            let emptyMultiRegistry = try AISegmentRegistry(sources: [workflowSource(
                fileID: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
                version: "empty-multi-v1",
                fingerprint: "empty-multi-snapshot",
                pages: []
            )])
            let emptyMultiBackend = RecordingLexicalBackend()
            _ = try await AIEvidenceRetrievalFactory.makeSources(
                selection: .lexical,
                registry: emptyMultiRegistry,
                lexicalBackend: emptyMultiBackend
            )
            check(await emptyMultiBackend.sourceCounts() == [0],
                  "Empty multi-source production factory path ignored its injected backend.")

            let malformedEmptyMultiBackend = UnexpectedGlobalLexicalBackend()
            do {
                _ = try await AIEvidenceRetrievalFactory.makeSources(
                    selection: .lexical,
                    registry: emptyMultiRegistry,
                    lexicalBackend: malformedEmptyMultiBackend
                )
                check(false, "An empty multi-source backend with stale global postings was accepted.")
            } catch let error as AIBM25IndexError {
                let malformedCounts = await malformedEmptyMultiBackend.sourceCounts()
                check(
                    error == .invalidIndexData && malformedCounts == [0],
                    "Empty multi-source prepared-index validation did not fail closed."
                )
            }

            let expiredEmptyMultiBackend = RecordingLexicalBackend()
            do {
                _ = try await AIEvidenceRetrievalFactory.makeSources(
                    selection: .lexical,
                    registry: emptyMultiRegistry,
                    lexicalBackend: expiredEmptyMultiBackend,
                    lexicalPreparationBudget: .zero
                )
                check(false, "An expired empty multi-source lexical request was accepted.")
            } catch let error as AIRetrievalError {
                let expiredCounts = await expiredEmptyMultiBackend.sourceCounts()
                check(
                    error == .preparationTimedOut
                        && expiredCounts.isEmpty,
                    "Empty multi-source preparation ignored its preflight budget."
                )
            }

            // Indexing never reads or writes an adjacent PDF-like byte source.
            let pdfURL = root.appendingPathComponent("source-fixture.pdf")
            let pdfBytes = Data("%PDF-1.7\nfixture-user-bytes\n%%EOF".utf8)
            try pdfBytes.write(to: pdfURL)
            _ = try await AIInMemoryBM25IndexBackend().prepare(source: first)
            let pdfBytesAfterIndexing = try Data(contentsOf: pdfURL)
            check(pdfBytesAfterIndexing == pdfBytes,
                  "Lexical indexing modified source PDF bytes.")

            await multiStore.close()
            try await multiStore.clearDerivedCache()
        } catch {
            check(false, "Persistent lexical primary fixture failed: \(error)")
        }

        // Multi-source cold builds avoid corpus-wide maintenance per source;
        // replacements clean only their old term candidates, and warm hits
        // publish one atomic access-time batch.
        do {
            let databaseURL = root.appendingPathComponent("batch-maintenance/index.sqlite3")
            let policy = temporaryPolicy(databaseURL)
            let fileIDs = [
                UUID(uuidString: "41000000-0000-0000-0000-000000000001")!,
                UUID(uuidString: "41000000-0000-0000-0000-000000000002")!,
                UUID(uuidString: "41000000-0000-0000-0000-000000000003")!
            ]
            let legacyTokens = ["legacyalpha", "legacybravo", "legacycharlie"]
            let currentTokens = ["freshalpha", "freshbravo", "freshcharlie"]
            let legacySources = zip(fileIDs, legacyTokens).enumerated().map { offset, values in
                fixtureSource(
                    fileID: values.0,
                    contentVersion: "batch-v1",
                    snapshot: "batch-v1-\(offset)",
                    segmenter: AISegmenter.currentVersion,
                    documentNumber: offset + 1,
                    texts: ["\(values.1) sharedretained", "stable target \(offset)"]
                )
            }
            let currentSources = zip(fileIDs, currentTokens).enumerated().map { offset, values in
                fixtureSource(
                    fileID: values.0,
                    contentVersion: "batch-v2",
                    snapshot: "batch-v2-\(offset)",
                    segmenter: AISegmenter.currentVersion,
                    documentNumber: offset + 1,
                    texts: ["\(values.1) sharedretained", "stable target \(offset)"]
                )
            }
            let expected = try await AIInMemoryBM25IndexBackend().prepare(sources: currentSources)
            let request = AISegmentSearchRequest(query: "freshalpha target", topK: 10)
            let store = AISQLiteBM25IndexBackend(storagePolicy: policy)
            let cold = try await store.prepare(sources: legacySources)
            let coldGenerationCount = try await store.generationCount()
            check(cold.metadata.cacheMisses == legacySources.count
                && coldGenerationCount == legacySources.count,
                  "Multi-source cold build did not commit one generation per source.")

            let updated = try await store.prepare(sources: currentSources)
            let updatedGenerationCount = try await store.generationCount()
            check(updated.metadata.cacheMisses == currentSources.count
                && updated.indexData == expected.indexData
                && updated.search(request) == expected.search(request)
                && updatedGenerationCount == currentSources.count,
                  "Targeted multi-source replacement changed generation or ranking semantics.")
            let cacheDirectory = databaseURL.deletingLastPathComponent()
            let sidecars = [databaseURL.path + "-wal", databaseURL.path + "-shm"]
                .map(URL.init(fileURLWithPath:))
                .filter { manager.fileExists(atPath: $0.path) }
            check(fileMode(cacheDirectory) == 0o700
                && fileMode(databaseURL) == 0o600
                && sidecars.allSatisfy { fileMode($0) == 0o600 },
                  "Batched multi-source writes weakened cache file permissions.")
            await store.close()

            let replacementInspection = try inspectMaintenanceDatabase(databaseURL)
            check(Set(legacyTokens).isDisjoint(with: replacementInspection.terms)
                && Set(currentTokens).isSubset(of: replacementInspection.terms)
                && replacementInspection.terms.contains("sharedretained"),
                  "Targeted replacement retained orphan terms or removed a shared live term.")
            let accessTimesBeforeWarm = replacementInspection.accessTimes

            let warmStore = AISQLiteBM25IndexBackend(storagePolicy: policy)
            let warm = try await warmStore.prepare(sources: currentSources)
            check(warm.metadata.cacheHits == currentSources.count
                && warm.indexData == expected.indexData
                && warm.search(request) == expected.search(request),
                  "Batched warm hits changed persistent ranking semantics.")
            await warmStore.close()
            let accessTimesAfterWarm = try inspectMaintenanceDatabase(databaseURL).accessTimes
            check(accessTimesAfterWarm.count == currentSources.count
                && Set(accessTimesAfterWarm.values).count == 1
                && accessTimesAfterWarm != accessTimesBeforeWarm,
                  "Warm generations were not touched as one timestamped batch.")

            let mismatchedTouchStore = AISQLiteBM25IndexBackend(
                storagePolicy: policy,
                diagnosticFault: .batchTouchIdentityMismatch
            )
            let mismatchedTouch = try await mismatchedTouchStore.prepare(sources: currentSources)
            check(mismatchedTouch.metadata.cacheHits == currentSources.count
                && mismatchedTouch.indexData == expected.indexData
                && mismatchedTouch.search(request) == expected.search(request),
                  "Identity-mismatch touch diagnostic changed cached ranking semantics.")
            await mismatchedTouchStore.close()
            check(try inspectMaintenanceDatabase(databaseURL).accessTimes == accessTimesAfterWarm,
                  "Warm touch updated rows whose IDs matched but canonical identities did not.")

            let cancellationStore = AISQLiteBM25IndexBackend(
                storagePolicy: policy,
                diagnosticFault: .batchTouchCancellation(afterRows: 1)
            )
            do {
                _ = try await cancellationStore.prepare(sources: currentSources)
                check(false, "Injected batched-touch cancellation was swallowed.")
            } catch is CancellationError {
                check(true, "Injected batched-touch cancellation propagated.")
            }
            let cancellationSidecars = [databaseURL.path + "-wal", databaseURL.path + "-shm"]
                .map(URL.init(fileURLWithPath:))
                .filter { manager.fileExists(atPath: $0.path) }
            check(fileMode(cacheDirectory) == 0o700
                && fileMode(databaseURL) == 0o600
                && cancellationSidecars.allSatisfy { fileMode($0) == 0o600 },
                  "Cancelled batched touch weakened cache file permissions.")
            await cancellationStore.close()
            check(try inspectMaintenanceDatabase(databaseURL).accessTimes == accessTimesAfterWarm,
                  "Batched-touch cancellation committed a partial access-time update.")

            let restartedStore = AISQLiteBM25IndexBackend(storagePolicy: policy)
            let restarted = try await restartedStore.prepare(sources: currentSources)
            let restartedGenerationCount = try await restartedStore.generationCount()
            check(restarted.metadata.cacheHits == currentSources.count
                && restarted.indexData == expected.indexData
                && restarted.search(request) == expected.search(request)
                && restartedGenerationCount == currentSources.count,
                  "Restart after batched-touch cancellation changed cache consistency.")
            try await restartedStore.clearDerivedCache()
        } catch {
            check(false, "Persistent lexical batch-maintenance fixture failed: \(error)")
        }

        // A cache produced before the targeted term index existed is a
        // disposable incompatible cache. Opening it must not synchronously
        // build an unbounded index on the request path: the current request
        // falls back to memory, and the following prepare builds a fresh v1
        // cache whose ranking stays identical.
        do {
            let databaseURL = root.appendingPathComponent("missing-index/index.sqlite3")
            let policy = temporaryPolicy(databaseURL)
            let source = fixtureSource(
                fileID: UUID(uuidString: "42000000-0000-0000-0000-000000000001")!,
                contentVersion: "missing-index-v1",
                snapshot: "missing-index-snapshot",
                segmenter: AISegmenter.currentVersion,
                documentNumber: 1,
                texts: ["required index rebuild target", "shared durable term"]
            )
            let expected = try await AIInMemoryBM25IndexBackend().prepare(source: source)
            let request = AISegmentSearchRequest(query: "index target", topK: 10)
            let seed = AISQLiteBM25IndexBackend(storagePolicy: policy)
            let seeded = try await seed.prepare(source: source)
            check(seeded.metadata.backend == .sqlite && seeded.indexData == expected.indexData,
                  "Missing-index fixture failed to seed a valid persistent cache.")
            await seed.close()

            try dropRequiredSourceTermIndex(at: databaseURL)
            check(!(try inspectDatabase(databaseURL)).indexes.contains("source_term_stat_by_term"),
                  "Missing-index fixture did not remove the required performance index.")

            let legacyStore = AISQLiteBM25IndexBackend(storagePolicy: policy)
            let fallback = try await legacyStore.prepare(source: source)
            check(fallback.metadata.backend == .memory
                && fallback.metadata.fallbackReason == .incompatible
                && fallback.indexData == expected.indexData
                && fallback.search(request) == expected.search(request),
                  "Missing required index did not use an incompatible memory fallback.")
            check(!manager.fileExists(atPath: databaseURL.path),
                  "Incompatible cache without the required index was not removed.")

            let rebuilt = try await legacyStore.prepare(source: source)
            check(rebuilt.metadata.backend == .sqlite
                && rebuilt.metadata.cacheHits == 0
                && rebuilt.metadata.cacheMisses == 1
                && rebuilt.indexData == expected.indexData
                && rebuilt.search(request) == expected.search(request),
                  "Cache missing the required index was not rebuilt with ranking parity.")
            await legacyStore.close()
            check((try inspectDatabase(databaseURL)).indexes.contains("source_term_stat_by_term"),
                  "Rebuilt cache omitted the required targeted-cleanup index.")
            try await legacyStore.clearDerivedCache()
        } catch {
            check(false, "Missing required SQLite index fixture failed: \(error)")
        }

        // A second connection must warm-load a generation committed to the
        // live writer's uncheckpointed WAL. Initial publication already puts
        // DOGE identity in the main database; subsequent WAL-only updates stay
        // queryable through the read-only ownership probe.
        do {
            let seedDatabase = root.appendingPathComponent("wal-reopen/index.sqlite3")
            let interruptedCleanupDatabases = Dictionary(
                uniqueKeysWithValues: AISQLiteBM25CleanupStage.allCases.map { stage in
                    (stage, root.appendingPathComponent(
                        "wal-cleanup-\(stage.rawValue)/index.sqlite3"
                    ))
                }
            )
            let source = fixtureSource(
                fileID: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
                contentVersion: "wal-crash-v1",
                snapshot: "wal-crash-snapshot",
                segmenter: AISegmenter.currentVersion,
                documentNumber: 1,
                texts: ["wal recovery target", "durable generation"]
            )
            let seedStore = AISQLiteBM25IndexBackend(
                storagePolicy: temporaryPolicy(seedDatabase)
            )
            let seeded = try await seedStore.prepare(source: source)
            let seedHeaderApplicationID = try databaseHeaderApplicationID(seedDatabase)
            check(seeded.metadata.backend == .sqlite
                && seeded.metadata.cacheMisses == 1
                && seedHeaderApplicationID == 0x444F4745
                && manager.fileExists(atPath: seedDatabase.path + "-wal"),
                  "WAL reopen fixture did not retain a live uncheckpointed generation.")

            let reopenedStore = AISQLiteBM25IndexBackend(
                storagePolicy: temporaryPolicy(seedDatabase)
            )
            let reopened = try await reopenedStore.prepare(source: source)
            check(reopened.metadata.backend == .sqlite
                && reopened.metadata.cacheHits == 1
                && reopened.indexData == seeded.indexData,
                  "Read-only ownership validation did not warm-load the live WAL generation.")
            await reopenedStore.close()
            await seedStore.close()

            let clearStore = AISQLiteBM25IndexBackend(
                storagePolicy: temporaryPolicy(seedDatabase)
            )
            try await clearStore.clearDerivedCache()
            let clearCandidates = [
                seedDatabase,
                URL(fileURLWithPath: seedDatabase.path + "-wal"),
                URL(fileURLWithPath: seedDatabase.path + "-shm")
            ]
            check(clearCandidates.allSatisfy { !manager.fileExists(atPath: $0.path) },
                  "Direct cleanup left part of the inode-owned WAL database.")
            let rebuilt = try await clearStore.prepare(source: source)
            let rebuiltWarm = try await clearStore.prepare(source: source)
            check(rebuilt.metadata.backend == .sqlite
                && rebuilt.metadata.cacheMisses == 1
                && rebuiltWarm.metadata.cacheHits == 1
                && rebuiltWarm.indexData == seeded.indexData,
                  "Cleared WAL database did not rebuild and warm-hit consistently.")
            try await clearStore.clearDerivedCache()

            for stage in AISQLiteBM25CleanupStage.allCases {
                guard let interruptedDatabase = interruptedCleanupDatabases[stage] else {
                    check(false, "Missing interrupted-cleanup fixture for \(stage.rawValue).")
                    continue
                }
                let fixtureStore = AISQLiteBM25IndexBackend(
                    storagePolicy: temporaryPolicy(interruptedDatabase)
                )
                _ = try await fixtureStore.prepare(source: source)
                await fixtureStore.close()
                try Data("owned diagnostic wal".utf8).write(
                    to: URL(fileURLWithPath: interruptedDatabase.path + "-wal")
                )
                try Data("owned diagnostic shm".utf8).write(
                    to: URL(fileURLWithPath: interruptedDatabase.path + "-shm")
                )
                let interruptedStore = AISQLiteBM25IndexBackend(
                    storagePolicy: temporaryPolicy(interruptedDatabase),
                    diagnosticFault: .cleanupFailure(stage)
                )
                do {
                    try await interruptedStore.clearDerivedCache()
                    check(false, "Cleanup \(stage.rawValue) interruption returned success.")
                } catch {
                    let attribute = try diagnosticOwnershipAttributeData(
                        at: interruptedDatabase
                    )
                    check(manager.fileExists(atPath: interruptedDatabase.path)
                        && attribute != nil,
                          "Cleanup \(stage.rawValue) lost its retryable owned database inode.")
                }
                await interruptedStore.setDiagnosticFault(nil)
                try await interruptedStore.clearDerivedCache()
                let leftovers = [
                    interruptedDatabase,
                    URL(fileURLWithPath: interruptedDatabase.path + "-wal"),
                    URL(fileURLWithPath: interruptedDatabase.path + "-shm")
                ]
                check(leftovers.allSatisfy { !manager.fileExists(atPath: $0.path) },
                      "Cleanup \(stage.rawValue) interruption could not resume to completion.")
            }
        } catch {
            check(false, "Uncheckpointed WAL/cleanup recovery fixture failed: \(error)")
        }

        // Loaded SQLite integers are untrusted. Two individually valid Int.max
        // token counts must report corruption instead of trapping during a sum.
        do {
            let databaseURL = root.appendingPathComponent(
                "overflow-cache/index.sqlite3"
            )
            let policy = temporaryPolicy(databaseURL)
            let source = fixtureSource(
                fileID: UUID(uuidString: "50000000-0000-0000-0000-000000000002")!,
                contentVersion: "overflow-v1",
                snapshot: "overflow-snapshot",
                segmenter: AISegmenter.currentVersion,
                documentNumber: 1,
                texts: ["overflow target one", "overflow target two"]
            )
            let store = AISQLiteBM25IndexBackend(storagePolicy: policy)
            let expected = try await store.prepare(source: source)
            await store.close()
            try setAllSegmentTokenCountsToIntMax(at: databaseURL)

            let reopened = AISQLiteBM25IndexBackend(storagePolicy: policy)
            let fallback = try await reopened.prepare(source: source)
            check(fallback.metadata.backend == .memory
                && fallback.metadata.fallbackReason == .corrupt
                && fallback.indexData == expected.indexData,
                  "Overflowing cached token statistics did not use corrupt memory fallback.")
            let rebuilt = try await reopened.prepare(source: source)
            check(rebuilt.metadata.backend == .sqlite
                && rebuilt.metadata.cacheMisses == 1
                && rebuilt.indexData == expected.indexData,
                  "Overflowing cache was not safely removed and rebuilt.")
            try await reopened.clearDerivedCache()
        } catch {
            check(false, "Overflowing cache-statistics fixture failed: \(error)")
        }

        // Numeric locator order must remain identical after page 999. The old
        // canonical-string ORDER BY placed P1000 before P101 on warm loads.
        do {
            let databaseURL = root.appendingPathComponent("numeric-order/index.sqlite3")
            let policy = temporaryPolicy(databaseURL)
            let source = largePageSource(count: 1_005)
            let memory = try await AIInMemoryBM25IndexBackend().prepare(source: source)
            let store = AISQLiteBM25IndexBackend(storagePolicy: policy)
            let cold = try await store.prepare(source: source)
            let warm = try await store.prepare(source: source)
            check(cold.indexData == memory.indexData
                && warm.metadata.backend == .sqlite
                && warm.metadata.cacheHits == 1
                && warm.indexData == memory.indexData,
                  "Warm SQLite ordering diverged for four-digit page locators.")
            await store.close()
            let reopened = AISQLiteBM25IndexBackend(storagePolicy: policy)
            let restart = try await reopened.prepare(source: source)
            check(restart.metadata.backend == .sqlite
                && restart.metadata.cacheHits == 1
                && restart.indexData == memory.indexData,
                  "Restart SQLite ordering diverged for four-digit page locators.")

            // Each warm-load loop cooperates with cancellation and never
            // publishes a successful partial prepared value.
            for stage in AISQLiteBM25WarmLoadStage.allCases {
                await reopened.setDiagnosticFault(
                    .warmLoadCancellation(stage, afterRows: 0)
                )
                do {
                    _ = try await reopened.prepare(source: source)
                    check(false, "Warm \(stage.rawValue) cancellation returned success.")
                } catch is CancellationError {
                    check(true, "Warm \(stage.rawValue) cancellation propagated.")
                }
                let count = try await reopened.generationCount()
                check(count == 1,
                      "Warm \(stage.rawValue) cancellation changed the complete generation.")
            }
            await reopened.setDiagnosticFault(nil)
            let afterCancellation = try await reopened.prepare(source: source)
            check(afterCancellation.metadata.cacheHits == 1
                && afterCancellation.indexData == memory.indexData,
                  "Warm cancellation damaged the reusable complete generation.")

            var digestChecks = 0
            do {
                _ = try AILexicalIndexSupport.registryDigest(source) {
                    digestChecks += 1
                    if digestChecks == 2 { throw CancellationError() }
                }
                check(false, "Registry digest cancellation returned success.")
            } catch is CancellationError {
                check(true, "Registry digest cancellation propagated.")
            }
            var mergeChecks = 0
            do {
                _ = try AILexicalIndexSupport.merge(
                    [(documentNumber: 1, data: memory.indexData)],
                    tokenizer: AILexicalTokenizer()
                ) {
                    mergeChecks += 1
                    if mergeChecks == 2 { throw CancellationError() }
                }
                check(false, "Lexical merge cancellation returned success.")
            } catch is CancellationError {
                check(true, "Lexical merge cancellation propagated.")
            }
            var validationChecks = 0
            do {
                _ = try AIBM25PreparedIndex(data: memory.indexData) {
                    validationChecks += 1
                    if validationChecks == 2 { throw CancellationError() }
                }
                check(false, "Prepared-index validation cancellation returned success.")
            } catch is CancellationError {
                check(true, "Prepared-index validation cancellation propagated.")
            }
            try await reopened.clearDerivedCache()
        } catch {
            check(false, "Four-digit locator/cancellation fixture failed: \(error)")
        }

        // Initialization is published only after a fully initialized, synced,
        // inode-owned temporary database is ready. Every pre-publish failure
        // removes only that attempt; a post-publish failure leaves a complete
        // database that a new store can safely reuse.
        for stage in AISQLiteBM25InitializationStage.allCases {
            let databaseURL = root.appendingPathComponent(
                "initialization-\(stage.rawValue)/index.sqlite3"
            )
            let policy = temporaryPolicy(databaseURL)
            let source = fixtureSource(
                fileID: UUID(), contentVersion: "initialization", snapshot: stage.rawValue,
                segmenter: AISegmenter.currentVersion, documentNumber: 1,
                texts: ["atomic initialization target", "durable cache"]
            )
            do {
                let store = AISQLiteBM25IndexBackend(
                    storagePolicy: policy,
                    diagnosticFault: .initializationFailure(stage)
                )
                let fallback = try await store.prepare(source: source)
                check(fallback.metadata.backend == .memory
                    && fallback.metadata.fallbackReason == .injectedFailure,
                      "Initialization \(stage.rawValue) failure did not fall back safely.")
                let directory = databaseURL.deletingLastPathComponent()
                let temporaryFiles = try diagnosticTemporaryDatabases(in: directory)
                check(temporaryFiles.isEmpty,
                      "Initialization \(stage.rawValue) left its temporary database behind.")
                check(manager.fileExists(atPath: databaseURL.path)
                    == (stage == .atomicPublish),
                      "Initialization \(stage.rawValue) exposed the wrong final-file state.")

                let recoveredStore = AISQLiteBM25IndexBackend(storagePolicy: policy)
                let recovered = try await recoveredStore.prepare(source: source)
                let warm = try await recoveredStore.prepare(source: source)
                check(recovered.metadata.backend == .sqlite
                    && recovered.metadata.cacheMisses == 1
                    && warm.metadata.cacheHits == 1
                    && warm.indexData == fallback.indexData,
                      "Initialization \(stage.rawValue) did not recover to a stable warm cache.")
                try await recoveredStore.clearDerivedCache()
            } catch {
                check(false, "Initialization \(stage.rawValue) fixture failed: \(error)")
            }
        }

        do {
            let databaseURL = root.appendingPathComponent(
                "initialization-storage-full/index.sqlite3"
            )
            let source = fixtureSource(
                fileID: UUID(), contentVersion: "initialization-full", snapshot: "full",
                segmenter: AISegmenter.currentVersion, documentNumber: 1,
                texts: ["storage full during initialization"]
            )
            let store = AISQLiteBM25IndexBackend(
                storagePolicy: temporaryPolicy(databaseURL),
                diagnosticFault: .initializationStorageFull(.ownershipAttribute)
            )
            let fallback = try await store.prepare(source: source)
            let temporaryFiles = try diagnosticTemporaryDatabases(
                in: databaseURL.deletingLastPathComponent()
            )
            check(fallback.metadata.backend == .memory
                && fallback.metadata.fallbackReason == .storageFull
                && temporaryFiles.isEmpty
                && !manager.fileExists(atPath: databaseURL.path),
                  "Initialization ENOSPC was misclassified or left owned files.")
        } catch {
            check(false, "Initialization ENOSPC fixture failed: \(error)")
        }

        // Unknown and pre-xattr crash files share the reserved-looking prefix
        // but remain foreign. They are ignored and cannot block a new random
        // initialization; only an exact UUID temp with a valid ownership xattr
        // is eligible for orphan cleanup.
        do {
            let directory = root.appendingPathComponent("temporary-orphans", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let databaseURL = directory.appendingPathComponent("index.sqlite3")
            let unownedTemporary = directory.appendingPathComponent(
                ".dogear-lexical-init-11111111-1111-1111-1111-111111111111.sqlite3"
            )
            let malformedTemporary = directory.appendingPathComponent(
                ".dogear-lexical-init-not-a-uuid.sqlite3"
            )
            let unownedBytes = Data("pre-xattr crash bytes".utf8)
            let malformedBytes = Data("foreign lookalike bytes".utf8)
            try unownedBytes.write(to: unownedTemporary)
            try malformedBytes.write(to: malformedTemporary)
            let unownedTemporaryWAL = URL(fileURLWithPath: unownedTemporary.path + "-wal")
            let unownedWALBytes = Data("foreign pre-xattr wal".utf8)
            try unownedWALBytes.write(to: unownedTemporaryWAL)

            let ownedTemporary = directory.appendingPathComponent(
                ".dogear-lexical-init-22222222-2222-2222-2222-222222222222.sqlite3"
            )
            try Data("owned partial bytes".utf8).write(to: ownedTemporary)
            try setDiagnosticOwnershipAttribute(
                at: ownedTemporary,
                data: diagnosticOwnershipAttributePayload(nonce: UUID())
            )
            let ownedTemporarySidecars = ["-wal", "-shm", "-journal"].map {
                URL(fileURLWithPath: ownedTemporary.path + $0)
            }
            for sidecar in ownedTemporarySidecars {
                try Data("owned temporary sidecar".utf8).write(to: sidecar)
            }

            let source = fixtureSource(
                fileID: UUID(), contentVersion: "orphan", snapshot: "orphan",
                segmenter: AISegmenter.currentVersion, documentNumber: 1,
                texts: ["orphan cleanup target"]
            )
            let store = AISQLiteBM25IndexBackend(storagePolicy: temporaryPolicy(databaseURL))
            let prepared = try await store.prepare(source: source)
            check(prepared.metadata.backend == .sqlite
                && prepared.metadata.cacheMisses == 1,
                  "Foreign reserved-looking temp files blocked a new SQLite cache.")
            check(try Data(contentsOf: unownedTemporary) == unownedBytes
                && Data(contentsOf: malformedTemporary) == malformedBytes
                && Data(contentsOf: unownedTemporaryWAL) == unownedWALBytes
                && !manager.fileExists(atPath: ownedTemporary.path)
                && ownedTemporarySidecars.allSatisfy {
                    !manager.fileExists(atPath: $0.path)
                },
                  "Orphan cleanup changed foreign temps or retained an owned temp.")
            try await store.clearDerivedCache()
        } catch {
            check(false, "Temporary orphan ownership fixture failed: \(error)")
        }

        // A target removed after atomic publication must not be recreated by
        // sqlite3_open_v2. The attempt falls back to memory and leaves no bytes.
        do {
            let databaseURL = root.appendingPathComponent(
                "post-publish-removal/index.sqlite3"
            )
            let policy = temporaryPolicy(databaseURL)
            let source = fixtureSource(
                fileID: UUID(), contentVersion: "post-publish", snapshot: "removed",
                segmenter: AISegmenter.currentVersion, documentNumber: 1,
                texts: ["published target removal"]
            )
            let store = AISQLiteBM25IndexBackend(
                storagePolicy: policy,
                diagnosticFault: .publishedTargetRemoval
            )
            let fallback = try await store.prepare(source: source)
            check(fallback.metadata.backend == .memory
                && fallback.metadata.fallbackReason == .unavailable
                && !manager.fileExists(atPath: databaseURL.path),
                  "A vanished published target was recreated or did not fail closed.")
            let sidecars = [databaseURL.path + "-wal", databaseURL.path + "-shm"]
            check(sidecars.allSatisfy { !manager.fileExists(atPath: $0) },
                  "A vanished published target left newly created SQLite sidecars.")
        } catch {
            check(false, "Post-publish target-removal fixture failed: \(error)")
        }

        // A directory or special file that occupies a SQLite sidecar name is
        // never recursively removed or chmodded. Preparation falls back, and
        // explicit clear refuses while preserving both the directory and DB.
        do {
            let databaseURL = root.appendingPathComponent(
                "sidecar-directory/index.sqlite3"
            )
            let policy = temporaryPolicy(databaseURL)
            let source = fixtureSource(
                fileID: UUID(), contentVersion: "sidecar-directory", snapshot: "directory",
                segmenter: AISegmenter.currentVersion, documentNumber: 1,
                texts: ["sidecar directory safety"]
            )
            let expected = try await AIInMemoryBM25IndexBackend().prepare(source: source)
            let seedStore = AISQLiteBM25IndexBackend(storagePolicy: policy)
            _ = try await seedStore.prepare(source: source)
            await seedStore.close()

            let sidecarDirectory = URL(fileURLWithPath: databaseURL.path + "-shm")
            if manager.fileExists(atPath: sidecarDirectory.path) {
                try manager.removeItem(at: sidecarDirectory)
            }
            try manager.createDirectory(at: sidecarDirectory, withIntermediateDirectories: false)
            let sentinel = sidecarDirectory.appendingPathComponent("user-sentinel.bin")
            let sentinelBytes = Data("do not recursively delete".utf8)
            try sentinelBytes.write(to: sentinel)
            let directoryMode = fileMode(sidecarDirectory)

            let reopened = AISQLiteBM25IndexBackend(storagePolicy: policy)
            let fallback = try await reopened.prepare(source: source)
            let sentinelAfterPrepare = try Data(contentsOf: sentinel)
            check(fallback.metadata.backend == .memory
                && fallback.metadata.fallbackReason == .unavailable
                && fallback.indexData == expected.indexData
                && manager.fileExists(atPath: databaseURL.path)
                && sentinelAfterPrepare == sentinelBytes
                && fileMode(sidecarDirectory) == directoryMode,
                  "A sidecar directory was modified instead of causing safe fallback.")
            do {
                try await reopened.clearDerivedCache()
                check(false, "Clear accepted a directory occupying a sidecar name.")
            } catch {
                let sentinelAfterClear = try Data(contentsOf: sentinel)
                check(manager.fileExists(atPath: databaseURL.path)
                    && sentinelAfterClear == sentinelBytes
                    && fileMode(sidecarDirectory) == directoryMode,
                      "Rejected clear modified a sidecar directory or owned database.")
            }
        } catch {
            check(false, "Sidecar directory safety fixture failed: \(error)")
        }

        // Orphan-temp cleanup follows the same non-recursive rule. A valid
        // ownership xattr does not authorize deleting a directory placed at a
        // sidecar path, so the unrelated tree remains and persistence falls back.
        do {
            let directory = root.appendingPathComponent(
                "temporary-sidecar-directory",
                isDirectory: true
            )
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let databaseURL = directory.appendingPathComponent("index.sqlite3")
            let temporary = directory.appendingPathComponent(
                ".dogear-lexical-init-33333333-3333-3333-3333-333333333333.sqlite3"
            )
            try Data("owned orphan".utf8).write(to: temporary)
            try setDiagnosticOwnershipAttribute(
                at: temporary,
                data: diagnosticOwnershipAttributePayload(nonce: UUID())
            )
            let sidecarDirectory = URL(fileURLWithPath: temporary.path + "-wal")
            try manager.createDirectory(at: sidecarDirectory, withIntermediateDirectories: false)
            let sentinel = sidecarDirectory.appendingPathComponent("user-sentinel.bin")
            let sentinelBytes = Data("preserve orphan sidecar directory".utf8)
            try sentinelBytes.write(to: sentinel)

            let source = fixtureSource(
                fileID: UUID(), contentVersion: "temp-sidecar-directory", snapshot: "directory",
                segmenter: AISegmenter.currentVersion, documentNumber: 1,
                texts: ["temporary sidecar directory safety"]
            )
            let expected = try await AIInMemoryBM25IndexBackend().prepare(source: source)
            let store = AISQLiteBM25IndexBackend(storagePolicy: temporaryPolicy(databaseURL))
            let fallback = try await store.prepare(source: source)
            let sentinelAfterPrepare = try Data(contentsOf: sentinel)
            check(fallback.metadata.backend == .memory
                && fallback.metadata.fallbackReason == .unavailable
                && fallback.indexData == expected.indexData
                && manager.fileExists(atPath: temporary.path)
                && sentinelAfterPrepare == sentinelBytes
                && !manager.fileExists(atPath: databaseURL.path),
                  "Owned-temp cleanup recursively changed a sidecar directory.")
        } catch {
            check(false, "Temporary sidecar directory fixture failed: \(error)")
        }

        // Each transaction stage must roll back both ordinary failures and
        // cancellation. Failure falls back to memory; cancellation propagates.
        for stage in AISQLiteBM25TransactionStage.allCases {
            let stageRoot = root.appendingPathComponent("failure-\(stage.rawValue)", isDirectory: true)
            let policy = temporaryPolicy(stageRoot.appendingPathComponent("index.sqlite3"))
            let source = fixtureSource(
                fileID: UUID(), contentVersion: "failure", snapshot: "failure",
                segmenter: "segmenter-v1", documentNumber: 1,
                texts: ["alpha target", "beta target"]
            )
            do {
                let store = AISQLiteBM25IndexBackend(
                    storagePolicy: policy,
                    diagnosticFault: .failure(stage)
                )
                let fallback = try await store.prepare(source: source)
                check(fallback.metadata.backend == .memory
                    && fallback.metadata.fallbackReason == .injectedFailure,
                      "Injected \(stage.rawValue) failure did not use safe memory fallback.")
                let generationCount = try await store.generationCount()
                check(generationCount == 0,
                      "Injected \(stage.rawValue) failure left a visible generation.")
                try await store.clearDerivedCache()
            } catch {
                check(false, "Injected \(stage.rawValue) failure fixture threw: \(error)")
            }

            let cancelRoot = root.appendingPathComponent("cancel-\(stage.rawValue)", isDirectory: true)
            let cancelPolicy = temporaryPolicy(cancelRoot.appendingPathComponent("index.sqlite3"))
            do {
                let store = AISQLiteBM25IndexBackend(
                    storagePolicy: cancelPolicy,
                    diagnosticFault: .cancellation(stage)
                )
                do {
                    _ = try await store.prepare(source: source)
                    check(false, "Injected \(stage.rawValue) cancellation was swallowed.")
                } catch is CancellationError {
                    check(true, "Injected transaction cancellation propagated.")
                }
                let generationCount = try await store.generationCount()
                check(generationCount == 0,
                      "Injected \(stage.rawValue) cancellation left a visible generation.")
                try await store.clearDerivedCache()
            } catch {
                check(false, "Injected \(stage.rawValue) cancellation fixture failed: \(error)")
            }
        }

        // SQLITE_FULL rolls back then returns an identical in-memory result.
        do {
            let fullPolicy = temporaryPolicy(root.appendingPathComponent("full/index.sqlite3"))
            let source = fixtureSource(
                fileID: UUID(), contentVersion: "full", snapshot: "full",
                segmenter: "segmenter-v1", documentNumber: 1,
                texts: ["storage target", "fallback"]
            )
            let memory = try await AIInMemoryBM25IndexBackend().prepare(source: source)
            let store = AISQLiteBM25IndexBackend(
                storagePolicy: fullPolicy,
                diagnosticFault: .storageFull(.postings)
            )
            let fallback = try await store.prepare(source: source)
            check(fallback.metadata.fallbackReason == .storageFull
                && fallback.indexData == memory.indexData,
                  "SQLITE_FULL did not produce ranking-identical memory fallback.")
            let generationCount = try await store.generationCount()
            check(generationCount == 0,
                  "SQLITE_FULL left a partially visible generation.")
            try await store.clearDerivedCache()
        } catch {
            check(false, "SQLITE_FULL fixture failed: \(error)")
        }

        // Deleted cache rebuild, corruption recovery, disabled persistence,
        // unwritable paths, and symlinks all preserve memory ranking.
        do {
            let fallbackRoot = root.appendingPathComponent("fallbacks", isDirectory: true)
            let databaseURL = fallbackRoot.appendingPathComponent("deleted/index.sqlite3")
            let policy = temporaryPolicy(databaseURL)
            let source = fixtureSource(
                fileID: UUID(), contentVersion: "fallback", snapshot: "fallback",
                segmenter: "segmenter-v1", documentNumber: 1,
                texts: ["fallback target", "other"]
            )
            let memory = try await AIInMemoryBM25IndexBackend().prepare(source: source)
            var store = AISQLiteBM25IndexBackend(storagePolicy: policy)
            let initial = try await store.prepare(source: source)
            await store.close()
            for candidate in [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"),
                              URL(fileURLWithPath: databaseURL.path + "-shm")]
                where manager.fileExists(atPath: candidate.path) {
                try manager.removeItem(at: candidate)
            }
            store = AISQLiteBM25IndexBackend(storagePolicy: policy)
            let rebuilt = try await store.prepare(source: source)
            check(initial.search(AISegmentSearchRequest(query: "target"))
                == rebuilt.search(AISegmentSearchRequest(query: "target"))
                && rebuilt.metadata.cacheMisses == 1,
                  "Deleted cache did not rebuild with identical ranking.")
            await store.close()
            let corruptHandle = try FileHandle(forWritingTo: databaseURL)
            try corruptHandle.truncate(atOffset: 0)
            try corruptHandle.write(contentsOf: Data("not a sqlite database".utf8))
            try corruptHandle.synchronize()
            try corruptHandle.close()
            store = AISQLiteBM25IndexBackend(storagePolicy: policy)
            let corruptFallback = try await store.prepare(source: source)
            check(corruptFallback.metadata.backend == .memory
                && corruptFallback.metadata.fallbackReason == .corrupt
                && corruptFallback.indexData == memory.indexData,
                  "Corrupt cache did not fall back to ranking-identical memory data.")
            let recovered = try await store.prepare(source: source)
            check(recovered.metadata.backend == .sqlite && recovered.metadata.cacheMisses == 1
                && recovered.indexData == memory.indexData,
                  "Store did not rebuild SQLite after corruption fallback.")
            try await store.clearDerivedCache()

            let replacedDatabase = fallbackRoot.appendingPathComponent(
                "replaced-inode/index.sqlite3"
            )
            let replacedPolicy = temporaryPolicy(replacedDatabase)
            let ownedStore = AISQLiteBM25IndexBackend(storagePolicy: replacedPolicy)
            _ = try await ownedStore.prepare(source: source)
            await ownedStore.close()
            check(try diagnosticOwnershipAttributeData(at: replacedDatabase) != nil,
                  "Owned replacement fixture did not begin with an xattr.")
            let replacementBytes = Data("replacement user bytes".utf8)
            try replaceFileWithoutOwnershipAttribute(
                at: replacedDatabase,
                contents: replacementBytes
            )
            let replacedStore = AISQLiteBM25IndexBackend(storagePolicy: replacedPolicy)
            let replacedFallback = try await replacedStore.prepare(source: source)
            let replacedBytesAfterPrepare = try Data(contentsOf: replacedDatabase)
            let replacedAttributeAfterPrepare = try diagnosticOwnershipAttributeData(
                at: replacedDatabase
            )
            check(replacedFallback.metadata.backend == .memory
                && replacedFallback.metadata.fallbackReason == .unavailable
                && replacedBytesAfterPrepare == replacementBytes
                && replacedAttributeAfterPrepare == nil,
                  "A replacement inode without the ownership xattr was claimed or changed.")
            do {
                try await replacedStore.clearDerivedCache()
                check(false, "A replacement inode was authorized for derived-cache deletion.")
            } catch {
                let replacedBytesAfterClear = try Data(contentsOf: replacedDatabase)
                let replacedAttributeAfterClear = try diagnosticOwnershipAttributeData(
                    at: replacedDatabase
                )
                check(replacedBytesAfterClear == replacementBytes
                    && replacedAttributeAfterClear == nil,
                      "Rejected replacement-inode cleanup changed user bytes.")
            }

            let disabled = AISQLiteBM25IndexBackend(storagePolicy: .memoryOnly)
            let disabledResult = try await disabled.prepare(source: source)
            check(disabledResult.metadata.backend == .memory
                && disabledResult.metadata.fallbackReason == .persistenceDisabled
                && disabledResult.indexData == memory.indexData,
                  "Disabled persistence changed retrieval semantics.")

            let blockingFile = fallbackRoot.appendingPathComponent("not-a-directory")
            try manager.createDirectory(at: fallbackRoot, withIntermediateDirectories: true)
            try Data("block directory creation".utf8).write(to: blockingFile)
            let unwritable = AISQLiteBM25IndexBackend(
                storagePolicy: temporaryPolicy(blockingFile.appendingPathComponent("index.sqlite3"))
            )
            let unwritableResult = try await unwritable.prepare(source: source)
            check(unwritableResult.metadata.backend == .memory
                && unwritableResult.metadata.fallbackReason == .unwritable
                && unwritableResult.indexData == memory.indexData,
                  "Unwritable cache path did not use ranking-identical memory fallback.")

            let symlinkRoot = fallbackRoot.appendingPathComponent("symlink", isDirectory: true)
            try manager.createDirectory(at: symlinkRoot, withIntermediateDirectories: true)
            let target = symlinkRoot.appendingPathComponent("target.bin")
            let targetBytes = Data("do-not-touch".utf8)
            try targetBytes.write(to: target)
            let link = symlinkRoot.appendingPathComponent("index.sqlite3")
            try manager.createSymbolicLink(at: link, withDestinationURL: target)
            let symlinkStore = AISQLiteBM25IndexBackend(storagePolicy: temporaryPolicy(link))
            let symlinkResult = try await symlinkStore.prepare(source: source)
            check(symlinkResult.metadata.backend == .memory
                && symlinkResult.metadata.fallbackReason == .unavailable
                && symlinkResult.indexData == memory.indexData,
                  "Symlink cache did not fail closed to memory.")
            let targetBytesAfterRejection = try Data(contentsOf: target)
            check(targetBytesAfterRejection == targetBytes,
                  "Symlink rejection modified its target.")

            let ancestorPolicyRoot = fallbackRoot.appendingPathComponent(
                "ancestor-policy",
                isDirectory: true
            )
            let ancestorTarget = fallbackRoot.appendingPathComponent(
                "ancestor-target",
                isDirectory: true
            )
            try manager.createDirectory(at: ancestorPolicyRoot, withIntermediateDirectories: true)
            try manager.createDirectory(at: ancestorTarget, withIntermediateDirectories: true)
            let ancestorSentinel = ancestorTarget.appendingPathComponent("sentinel.bin")
            let ancestorSentinelBytes = Data("ancestor-target-must-not-change".utf8)
            try ancestorSentinelBytes.write(to: ancestorSentinel)
            let ancestorLink = ancestorPolicyRoot.appendingPathComponent(
                "linked-cache",
                isDirectory: true
            )
            try manager.createSymbolicLink(at: ancestorLink, withDestinationURL: ancestorTarget)
            let ancestorDatabase = ancestorLink.appendingPathComponent("index.sqlite3")
            let ancestorStore = AISQLiteBM25IndexBackend(storagePolicy: temporaryPolicy(
                ancestorDatabase,
                controlledRootURL: ancestorPolicyRoot
            ))
            let ancestorResult = try await ancestorStore.prepare(source: source)
            check(ancestorResult.metadata.backend == .memory
                && ancestorResult.metadata.fallbackReason == .unavailable
                && ancestorResult.indexData == memory.indexData,
                  "An ancestor symlink did not fail closed to memory.")
            check(try Data(contentsOf: ancestorSentinel) == ancestorSentinelBytes
                && !manager.fileExists(atPath: ancestorTarget
                    .appendingPathComponent("index.sqlite3").path),
                  "Ancestor-symlink rejection modified or created target files.")

            let foreignRoot = fallbackRoot.appendingPathComponent("foreign", isDirectory: true)
            try manager.createDirectory(at: foreignRoot, withIntermediateDirectories: true)
            let foreignDatabase = foreignRoot.appendingPathComponent("ordinary.sqlite3")
            try createForeignDatabase(at: foreignDatabase)
            let foreignBytes = try Data(contentsOf: foreignDatabase)
            let foreignStore = AISQLiteBM25IndexBackend(
                storagePolicy: temporaryPolicy(foreignDatabase)
            )
            let foreignResult = try await foreignStore.prepare(source: source)
            check(foreignResult.metadata.backend == .memory
                && foreignResult.metadata.fallbackReason == .unavailable
                && foreignResult.indexData == memory.indexData,
                  "A non-owned SQLite database did not fail closed to memory.")
            check(try Data(contentsOf: foreignDatabase) == foreignBytes
                && diagnosticOwnershipAttributeData(at: foreignDatabase) == nil,
                  "Preparing against a non-owned SQLite database modified it or claimed ownership.")
            do {
                try await foreignStore.clearDerivedCache()
                check(false, "Clearing a non-owned SQLite database unexpectedly succeeded.")
            } catch {
                check(try Data(contentsOf: foreignDatabase) == foreignBytes,
                      "Clear-derived-cache modified or deleted a non-owned SQLite database.")
            }

            let forgedAttributeBytes = diagnosticOwnershipAttributePayload(nonce: UUID())
            try setDiagnosticOwnershipAttribute(
                at: foreignDatabase,
                data: forgedAttributeBytes
            )
            let foreignLoneSidecar = URL(fileURLWithPath: foreignDatabase.path + "-shm")
            let foreignSidecarBytes = Data("foreign lone sidecar".utf8)
            try foreignSidecarBytes.write(to: foreignLoneSidecar)
            let forgedStore = AISQLiteBM25IndexBackend(
                storagePolicy: temporaryPolicy(foreignDatabase)
            )
            let forgedResult = try await forgedStore.prepare(source: source)
            let foreignBytesAfterForgedPrepare = try Data(contentsOf: foreignDatabase)
            let attributeBytesAfterForgedPrepare = try diagnosticOwnershipAttributeData(
                at: foreignDatabase
            )
            let sidecarBytesAfterForgedPrepare = try Data(contentsOf: foreignLoneSidecar)
            check(forgedResult.metadata.fallbackReason == .unavailable
                && foreignBytesAfterForgedPrepare == foreignBytes
                && attributeBytesAfterForgedPrepare == forgedAttributeBytes
                && sidecarBytesAfterForgedPrepare == foreignSidecarBytes,
                  "A forged xattr alone claimed or modified a foreign SQLite database.")
            do {
                try await forgedStore.clearDerivedCache()
                check(false, "A forged xattr authorized deletion of a foreign SQLite database.")
            } catch {
                let foreignBytesAfterRejectedClear = try Data(contentsOf: foreignDatabase)
                let attributeBytesAfterRejectedClear = try diagnosticOwnershipAttributeData(
                    at: foreignDatabase
                )
                check(foreignBytesAfterRejectedClear == foreignBytes
                    && attributeBytesAfterRejectedClear == forgedAttributeBytes,
                      "Foreign SQLite or its forged xattr was changed by rejected cleanup.")
                check(try Data(contentsOf: foreignLoneSidecar) == foreignSidecarBytes,
                      "Rejected cleanup changed a foreign lone sidecar.")
            }

            let containedRoot = fallbackRoot.appendingPathComponent(
                "contained-policy",
                isDirectory: true
            )
            try manager.createDirectory(at: containedRoot, withIntermediateDirectories: true)
            let outsideDatabase = fallbackRoot
                .appendingPathComponent("outside-policy/index.sqlite3")
            let outsideStore = AISQLiteBM25IndexBackend(storagePolicy: temporaryPolicy(
                outsideDatabase,
                controlledRootURL: containedRoot
            ))
            let outsideResult = try await outsideStore.prepare(source: source)
            check(outsideResult.metadata.fallbackReason == .unavailable
                && !manager.fileExists(atPath: outsideDatabase.path),
                  "A database path outside the controlled root was created or opened.")
        } catch {
            check(false, "Persistent lexical fallback fixture failed: \(error)")
        }

        if let measurements {
            print(
                "PERSISTENT LEXICAL: cold=\(measurements.coldPrepareSeconds)s "
                    + "warm=\(measurements.warmPrepareSeconds)s "
                    + "restart=\(measurements.restartPrepareSeconds)s "
                    + "db=\(measurements.databaseMetrics.databaseBytes) "
                    + "wal=\(measurements.databaseMetrics.walBytes) "
                    + "shm=\(measurements.databaseMetrics.sharedMemoryBytes) bytes"
            )
        }
        return Report(checks: checks, failures: failures, measurements: measurements)
    }

    private static func temporaryPolicy(
        _ databaseURL: URL,
        controlledRootURL: URL? = nil
    ) -> AILexicalIndexStoragePolicy {
        AILexicalIndexStoragePolicy(
            persistenceEnabled: true,
            controlledRootURL: controlledRootURL ?? databaseURL.deletingLastPathComponent(),
            databaseURL: databaseURL,
            maximumBytes: 64 * 1_024 * 1_024,
            busyTimeoutMilliseconds: 500,
            backgroundBuildBudgetSeconds: 10
        )
    }

    private static func fixtureSource(
        fileID: UUID,
        contentVersion: String,
        snapshot: String,
        segmenter: String,
        documentNumber: Int,
        texts: [String]
    ) -> AILexicalIndexSource {
        let records = texts.enumerated().map { offset, text in
            AISegmentRecord(
                id: AISegmentID(document: documentNumber, page: offset / 3 + 1,
                    block: offset % 3 + 1, sentence: 1),
                text: text,
                normalizedText: AISegmenter.normalizeForSearch(text),
                sourceRange: AISourceTextRange(location: offset * 1_000, length: text.utf16.count),
                pageFingerprint: "\(snapshot)-page-\(offset / 3 + 1)",
                sourceKind: .nativeText,
                sourceConfidence: offset.isMultiple(of: 2) ? 0.99 : nil
            )
        }
        return AILexicalIndexSource(
            descriptor: AIBM25IndexDescriptor(
                fileID: fileID,
                contentVersion: contentVersion,
                snapshotFingerprint: snapshot,
                segmenterVersion: segmenter
            ),
            documentNumber: documentNumber,
            records: records
        )
    }

    private static func largePageSource(count: Int) -> AILexicalIndexSource {
        let records = (1...count).map { page in
            let text = "numeric locator target page \(page)"
            return AISegmentRecord(
                id: AISegmentID(document: 1, page: page, block: 1, sentence: 1),
                text: text,
                normalizedText: AISegmenter.normalizeForSearch(text),
                sourceRange: AISourceTextRange(location: page * 100, length: text.utf16.count),
                pageFingerprint: "numeric-page-\(page)",
                sourceKind: .nativeText,
                sourceConfidence: nil
            )
        }
        return AILexicalIndexSource(
            descriptor: AIBM25IndexDescriptor(
                fileID: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
                contentVersion: "numeric-order-v1",
                snapshotFingerprint: "numeric-order-snapshot",
                segmenterVersion: "segmenter-v1"
            ),
            documentNumber: 1,
            records: records
        )
    }

    private static func createForeignDatabase(at url: URL) throws {
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        guard openStatus == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close_v2(database) }
        guard sqlite3_exec(
            database,
            "CREATE TABLE user_document(value TEXT); INSERT INTO user_document VALUES ('preserve-me');",
            nil,
            nil,
            nil
        ) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func databaseHeaderApplicationID(_ url: URL) throws -> Int32 {
        let data = try Data(contentsOf: url)
        guard data.count >= 72 else { throw CocoaError(.fileReadCorruptFile) }
        let bytes = [UInt8](data[68..<72])
        return Int32(bitPattern:
            UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
    }

    private static let diagnosticOwnershipAttributeName =
        "com.dogear.derived-lexical-cache"

    private static func diagnosticOwnershipAttributePayload(nonce: UUID) -> Data {
        Data(
            "dogear-derived-lexical-cache\nattribute-version=1\n"
                .appending("application-id=1146046277\n")
                .appending("nonce=\(nonce.uuidString)\n")
                .utf8
        )
    }

    private static func diagnosticOwnershipAttributeData(at url: URL) throws -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG
        else { throw CocoaError(.fileReadUnknown) }
        let size = diagnosticOwnershipAttributeName.withCString { name in
            Darwin.fgetxattr(descriptor, name, nil, 0, 0, 0)
        }
        if size < 0, errno == ENOATTR { return nil }
        guard size >= 0, size <= 1_024 else { throw CocoaError(.fileReadCorruptFile) }
        var bytes = [UInt8](repeating: 0, count: size)
        let readCount = bytes.withUnsafeMutableBytes { buffer in
            diagnosticOwnershipAttributeName.withCString { name in
                Darwin.fgetxattr(descriptor, name, buffer.baseAddress, buffer.count, 0, 0)
            }
        }
        guard readCount == size else { throw CocoaError(.fileReadCorruptFile) }
        return Data(bytes)
    }

    private static func setDiagnosticOwnershipAttribute(at url: URL, data: Data) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG
        else { throw CocoaError(.fileWriteUnknown) }
        let status = data.withUnsafeBytes { bytes in
            diagnosticOwnershipAttributeName.withCString { name in
                Darwin.fsetxattr(
                    descriptor,
                    name,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                )
            }
        }
        guard status == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func diagnosticTemporaryDatabases(in directory: URL) throws -> [URL] {
        let prefix = ".dogear-lexical-init-"
        let suffix = ".sqlite3"
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { candidate in
            let name = candidate.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
            let start = name.index(name.startIndex, offsetBy: prefix.count)
            let end = name.index(name.endIndex, offsetBy: -suffix.count)
            let identifier = String(name[start..<end])
            return UUID(uuidString: identifier)?.uuidString == identifier
        }
    }

    private static func replaceFileWithoutOwnershipAttribute(
        at destination: URL,
        contents: Data
    ) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".diagnostic-replacement-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try contents.write(to: temporary, options: .withoutOverwriting)
        guard try diagnosticOwnershipAttributeData(at: temporary) == nil,
              Darwin.rename(temporary.path, destination.path) == 0
        else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func setAllSegmentTokenCountsToIntMax(at url: URL) throws {
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close_v2(database) }
        guard sqlite3_exec(
            database,
            "UPDATE segment SET token_count = 9223372036854775807",
            nil,
            nil,
            nil
        ) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func dropRequiredSourceTermIndex(at url: URL) throws {
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close_v2(database) }
        guard sqlite3_exec(
            database,
            "DROP INDEX source_term_stat_by_term",
            nil,
            nil,
            nil
        ) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func workflowSource(
        fileID: UUID,
        version: String,
        fingerprint: String,
        pages: [String]
    ) -> AIWorkflowSourceSnapshot {
        let snapshots = pages.enumerated().map { offset, text in
            AITextPageSnapshot(
                pageNumber: offset + 1,
                text: text,
                fingerprint: "\(fingerprint)-page-\(offset + 1)"
            )
        }
        return AIWorkflowSourceSnapshot(
            fileID: fileID,
            displayName: "factory-fixture.pdf",
            snapshot: AIHighlightTextSnapshot(fingerprint: fingerprint, pages: snapshots),
            version: version
        )
    }

    private struct DatabaseInspection {
        let applicationID: Int64
        let userVersion: Int64
        let tables: Set<String>
        let indexes: Set<String>
        let columns: Set<String>
    }

    private static func inspectDatabase(_ url: URL) throws -> DatabaseInspection {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_close_v2(database) }
        func rows(_ sql: String) throws -> [[String]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw CocoaError(.fileReadCorruptFile) }
            defer { sqlite3_finalize(statement) }
            var result: [[String]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append((0..<sqlite3_column_count(statement)).map { index in
                    sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
                })
            }
            return result
        }
        let appID = Int64(try rows("PRAGMA application_id").first?.first ?? "") ?? -1
        let userVersion = Int64(try rows("PRAGMA user_version").first?.first ?? "") ?? -1
        let tables = Set(try rows(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        ).compactMap(\.first))
        let indexes = Set(try rows(
            "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'"
        ).compactMap(\.first))
        var columns = Set<String>()
        for table in tables {
            columns.formUnion(try rows("PRAGMA table_info('\(table)')").compactMap { row in
                row.indices.contains(1) ? row[1] : nil
            })
        }
        return DatabaseInspection(
            applicationID: appID,
            userVersion: userVersion,
            tables: tables,
            indexes: indexes,
            columns: columns
        )
    }

    private struct MaintenanceDatabaseInspection {
        let terms: Set<String>
        let accessTimes: [String: Double]
    }

    private static func inspectMaintenanceDatabase(
        _ url: URL
    ) throws -> MaintenanceDatabaseInspection {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_close_v2(database) }

        var terms = Set<String>()
        var termStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT token FROM term ORDER BY token",
            -1,
            &termStatement,
            nil
        ) == SQLITE_OK, let termStatement else {
            if let termStatement { sqlite3_finalize(termStatement) }
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_finalize(termStatement) }
        while sqlite3_step(termStatement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(termStatement, 0) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            terms.insert(String(cString: value))
        }

        var accessTimes: [String: Double] = [:]
        var accessStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT identity, last_accessed_at FROM source_generation ORDER BY identity",
            -1,
            &accessStatement,
            nil
        ) == SQLITE_OK, let accessStatement else {
            if let accessStatement { sqlite3_finalize(accessStatement) }
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_finalize(accessStatement) }
        while sqlite3_step(accessStatement) == SQLITE_ROW {
            guard let identity = sqlite3_column_text(accessStatement, 0) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            accessTimes[String(cString: identity)] = sqlite3_column_double(accessStatement, 1)
        }
        return MaintenanceDatabaseInspection(terms: terms, accessTimes: accessTimes)
    }

    private static func fileMode(_ url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let value = attributes[.posixPermissions] as? NSNumber
        else { return -1 }
        return value.intValue & 0o777
    }

    private actor RecordingLexicalBackend: AILexicalIndexBackend {
        private var counts: [Int] = []
        private var recordedDocumentNumbers: [[Int]] = []
        private var recordedFileIDs: [[UUID]] = []

        func prepare(sources: [AILexicalIndexSource]) async throws -> AILexicalPreparedIndex {
            counts.append(sources.count)
            recordedDocumentNumbers.append(sources.map(\.documentNumber))
            recordedFileIDs.append(sources.map(\.descriptor.fileID))
            return try await AIInMemoryBM25IndexBackend().prepare(sources: sources)
        }

        func sourceCounts() -> [Int] { counts }
        func documentNumbers() -> [[Int]] { recordedDocumentNumbers }
        func fileIDs() -> [[UUID]] { recordedFileIDs }
    }

    private actor RejectingLexicalBackend: AILexicalIndexBackend {
        private var counts: [Int] = []

        func prepare(sources: [AILexicalIndexSource]) async throws -> AILexicalPreparedIndex {
            counts.append(sources.count)
            throw AIBM25IndexError.invalidIndexData
        }

        func sourceCounts() -> [Int] { counts }
    }

    private actor InconsistentGlobalLexicalBackend: AILexicalIndexBackend {
        private var counts: [Int] = []

        func prepare(sources: [AILexicalIndexSource]) async throws -> AILexicalPreparedIndex {
            counts.append(sources.count)
            let prepared = try await AIInMemoryBM25IndexBackend().prepare(sources: sources)
            guard sources.count > 1, let first = prepared.preparedSources.first else {
                return prepared
            }
            return AILexicalPreparedIndex(
                bm25: first.bm25,
                sourceIdentities: prepared.sourceIdentities,
                preparedSources: prepared.preparedSources,
                metadata: prepared.metadata
            )
        }

        func sourceCounts() -> [Int] { counts }
    }

    private actor DelayedLexicalBackend: AILexicalIndexBackend {
        private let delay: Duration
        private var counts: [Int] = []

        init(delay: Duration) {
            self.delay = delay
        }

        func prepare(sources: [AILexicalIndexSource]) async throws -> AILexicalPreparedIndex {
            counts.append(sources.count)
            try await Task.sleep(for: delay)
            return try await AIInMemoryBM25IndexBackend().prepare(sources: sources)
        }

        func sourceCounts() -> [Int] { counts }
    }

    private actor SelfCancellingLexicalBackend: AILexicalIndexBackend {
        private let delay: Duration
        private var counts: [Int] = []

        init(delay: Duration) {
            self.delay = delay
        }

        func prepare(sources: [AILexicalIndexSource]) async throws -> AILexicalPreparedIndex {
            counts.append(sources.count)
            try await Task.sleep(for: delay)
            let prepared = try await AIInMemoryBM25IndexBackend().prepare(sources: sources)
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return prepared
        }

        func sourceCounts() -> [Int] { counts }
    }

    private actor UnexpectedGlobalLexicalBackend: AILexicalIndexBackend {
        private var counts: [Int] = []

        func prepare(sources: [AILexicalIndexSource]) async throws -> AILexicalPreparedIndex {
            counts.append(sources.count)
            let prepared = try await AIInMemoryBM25IndexBackend().prepare(sources: sources)
            let text = "unauthorized stale posting"
            let unexpectedGlobal = try AIBM25PreparedIndex(records: [AISegmentRecord(
                id: AISegmentID(document: 1, page: 999, block: 1, sentence: 1),
                text: text,
                normalizedText: AISegmenter.normalizeForSearch(text),
                sourceRange: AISourceTextRange(location: 0, length: text.utf16.count),
                pageFingerprint: "unexpected-global-page",
                sourceKind: .nativeText,
                sourceConfidence: nil
            )])
            return AILexicalPreparedIndex(
                bm25: unexpectedGlobal,
                sourceIdentities: prepared.sourceIdentities,
                preparedSources: prepared.preparedSources,
                metadata: prepared.metadata
            )
        }

        func sourceCounts() -> [Int] { counts }
    }
}
