import Foundation

nonisolated enum AISharedMemoryBM25CacheDiagnostics {
    struct Report: Sendable {
        let checks: Int
        let failures: [String]
    }

    static func run() async -> Report {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }

        do {
            let a = source(
                fileID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
                documentNumber: 1,
                contentVersion: "content-a",
                snapshot: "snapshot-a",
                segmenter: "segmenter-a",
                texts: ["alpha evidence", "shared term"]
            )
            let b = source(
                fileID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
                documentNumber: 2,
                contentVersion: "content-b",
                snapshot: "snapshot-b",
                segmenter: "segmenter-a",
                texts: ["beta evidence", "shared term"]
            )
            let query = AISegmentSearchRequest(query: "alpha shared", topK: 10)

            let basic = AISharedMemoryBM25IndexBackend(maximumGenerations: 8, maximumCost: 10_000)
            let cold = try await basic.prepare(sources: [b, a])
            let warm = try await basic.prepare(sources: [a, b])
            check(
                cold.metadata.cacheHits == 0 && cold.metadata.cacheMisses == 2
                    && warm.metadata.cacheHits == 2 && warm.metadata.cacheMisses == 0,
                "Shared memory BM25 did not report deterministic cold/warm generations."
            )
            check(
                cold.indexData == warm.indexData && cold.search(query) == warm.search(query),
                "A warm shared-memory generation changed BM25 values or score bits."
            )
            let basicState = await basic.snapshotForDiagnostics()
            check(
                basicState.generations == 2 && basicState.builds == 2
                    && basicState.hits == 2 && basicState.misses == 2,
                "Shared memory BM25 counters did not match cold/warm preparation."
            )

            let changedB = source(
                fileID: b.descriptor.fileID,
                documentNumber: 2,
                contentVersion: "content-b2",
                snapshot: "snapshot-b2",
                segmenter: "segmenter-a",
                texts: ["gamma replacement", "shared term"]
            )
            let partial = try await basic.prepare(sources: [a, changedB])
            let freshPartial = try await AIInMemoryBM25IndexBackend().prepare(sources: [a, changedB])
            check(
                partial.metadata.cacheHits == 1 && partial.metadata.cacheMisses == 1,
                "Changing one authorized source did not produce one hit and one miss."
            )
            check(
                partial.indexData == freshPartial.indexData
                    && partial.search(AISegmentSearchRequest(query: "gamma shared", topK: 10))
                        == freshPartial.search(AISegmentSearchRequest(query: "gamma shared", topK: 10)),
                "A partial memory-cache hit diverged from a clean authorized-corpus build."
            )

            let sameIdentityDifferentDigest = source(
                fileID: a.descriptor.fileID,
                documentNumber: 1,
                contentVersion: a.descriptor.contentVersion,
                snapshot: a.descriptor.snapshotFingerprint,
                segmenter: a.descriptor.segmenterVersion,
                texts: ["forged replacement text"]
            )
            let digestMiss = try await basic.prepare(source: sameIdentityDifferentDigest)
            let digestWarm = try await basic.prepare(source: sameIdentityDifferentDigest)
            check(
                digestMiss.metadata.cacheHits == 0 && digestMiss.metadata.cacheMisses == 1
                    && digestWarm.metadata.cacheHits == 1,
                "Registry digest changes reused an incompatible canonical generation."
            )

            let versionChanged = source(
                fileID: a.descriptor.fileID,
                documentNumber: 1,
                contentVersion: a.descriptor.contentVersion,
                snapshot: a.descriptor.snapshotFingerprint,
                segmenter: "segmenter-b",
                texts: ["alpha evidence", "shared term"]
            )
            let versionMiss = try await basic.prepare(source: versionChanged)
            check(
                versionMiss.metadata.cacheHits == 0 && versionMiss.metadata.cacheMisses == 1,
                "A segmenter/window identity change reused an older memory generation."
            )
            let unsupportedTokenizer = AILexicalIndexSource(
                descriptor: AIBM25IndexDescriptor(
                    fileID: a.descriptor.fileID,
                    contentVersion: a.descriptor.contentVersion,
                    snapshotFingerprint: a.descriptor.snapshotFingerprint,
                    segmenterVersion: a.descriptor.segmenterVersion,
                    tokenizerVersion: "future-tokenizer"
                ),
                documentNumber: 1,
                records: a.records
            )
            do {
                _ = try await basic.prepare(source: unsupportedTokenizer)
                check(false, "An incompatible tokenizer identity was accepted by the memory cache.")
            } catch let error as AILexicalIndexBackendError {
                if case .tokenizerMismatch = error { check(true, "") }
                else { check(false, "Tokenizer mismatch returned an unexpected validation error.") }
            }

            let ordinalCache = AISharedMemoryBM25IndexBackend(
                maximumGenerations: 8,
                maximumCost: 10_000
            )
            _ = try await ordinalCache.prepare(sources: [a, b])
            let swappedA = remap(a, to: 2)
            let swappedB = remap(b, to: 1)
            let remapped = try await ordinalCache.prepare(sources: [swappedA, swappedB])
            let remappedAlpha = remapped.search(AISegmentSearchRequest(query: "alpha", topK: 10))
            check(
                remapped.metadata.cacheHits == 2
                    && remappedAlpha.first?.id.document == 2,
                "Cached canonical shards did not follow the current request ordinals."
            )

            let authorizedA = try await ordinalCache.prepare(source: a)
            check(
                authorizedA.metadata.cacheHits == 1
                    && authorizedA.search(AISegmentSearchRequest(query: "beta", topK: 10)).isEmpty
                    && authorizedA.indexData.segmentLengths.keys.allSatisfy { $0.document == 1 },
                "An unselected cached source changed authorized BM25 statistics or results."
            )

            let lru = AISharedMemoryBM25IndexBackend(maximumGenerations: 2, maximumCost: 10_000)
            let c = source(
                fileID: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
                documentNumber: 3,
                contentVersion: "content-c",
                snapshot: "snapshot-c",
                segmenter: "segmenter-a",
                texts: ["charlie evidence"]
            )
            _ = try await lru.prepare(source: a)
            _ = try await lru.prepare(source: b)
            _ = try await lru.prepare(source: a)
            _ = try await lru.prepare(source: c)
            let evictedB = try await lru.prepare(source: b)
            let lruState = await lru.snapshotForDiagnostics()
            check(
                evictedB.metadata.cacheMisses == 1 && lruState.generations == 2,
                "Bounded LRU did not evict the least-recently-used generation."
            )
            check(lruState.cost <= 10_000, "Shared memory BM25 exceeded its configured cost bound.")

            let cancelled = AISharedMemoryBM25IndexBackend(
                maximumGenerations: 8,
                maximumCost: 10_000,
                diagnosticFault: .cancellationBeforePublication
            )
            do {
                _ = try await cancelled.prepare(source: a)
                check(false, "Cancelled memory preparation returned a complete value.")
            } catch is CancellationError {
                let cancelledState = await cancelled.snapshotForDiagnostics()
                check(
                    cancelledState.generations == 0 && cancelledState.builds == 0,
                    "Cancelled memory preparation published a generation."
                )
            } catch {
                check(false, "Cancelled memory preparation returned an unexpected error.")
            }

            let concurrent = AISharedMemoryBM25IndexBackend(maximumGenerations: 8, maximumCost: 10_000)
            async let first = concurrent.prepare(source: a)
            async let second = concurrent.prepare(source: a)
            let concurrentValues = try await (first, second)
            let concurrentMetadata = [concurrentValues.0.metadata, concurrentValues.1.metadata]
            let concurrentState = await concurrent.snapshotForDiagnostics()
            check(
                concurrentMetadata.map(\.cacheMisses).sorted() == [0, 1]
                    && concurrentMetadata.map(\.cacheHits).sorted() == [0, 1]
                    && concurrentState.builds == 1 && concurrentState.generations == 1,
                "Concurrent identical prepares built or published more than one generation."
            )

            await AISharedMemoryBM25IndexBackend.shared.resetForDiagnostics()
            let snapshot = AIHighlightTextSnapshot(
                fingerprint: "shared-factory-snapshot",
                pages: [AITextPageSnapshot(
                    pageNumber: 1,
                    text: "Factory alpha evidence. Factory supporting detail.",
                    fingerprint: "shared-factory-page"
                )]
            )
            let registry = try AISegmentRegistry(sources: [AIWorkflowSourceSnapshot(
                fileID: UUID(uuidString: "20000000-0000-0000-0000-000000000010")!,
                displayName: "shared-memory.pdf",
                snapshot: snapshot
            )])
            _ = try await AIEvidenceRetrievalFactory.makeSources(selection: .lexical, registry: registry)
            _ = try await AIEvidenceRetrievalFactory.makeSources(selection: .lexical, registry: registry)
            let factoryState = await AISharedMemoryBM25IndexBackend.shared.snapshotForDiagnostics()
            check(
                factoryState.builds == 1 && factoryState.misses == 1 && factoryState.hits == 1,
                "The Scheme 1 product factory did not reuse its shared memory generation."
            )
            await AISharedMemoryBM25IndexBackend.shared.resetForDiagnostics()
        } catch {
            failures.append("Shared memory BM25 diagnostics failed: \(error)")
        }

        // The product singleton must never inherit fixture generations or
        // counters, including after a diagnostic failure.
        await AISharedMemoryBM25IndexBackend.shared.resetForDiagnostics()
        return Report(checks: checks, failures: failures)
    }

    private static func remap(
        _ source: AILexicalIndexSource,
        to documentNumber: Int
    ) -> AILexicalIndexSource {
        AILexicalIndexSource(
            descriptor: source.descriptor,
            documentNumber: documentNumber,
            records: source.records.map { record in
                AISegmentRecord(
                    id: AISegmentID(
                        document: documentNumber,
                        page: record.id.page,
                        block: record.id.block,
                        sentence: record.id.sentence
                    ),
                    text: record.text,
                    normalizedText: record.normalizedText,
                    sourceRange: record.sourceRange,
                    pageFingerprint: record.pageFingerprint,
                    sourceKind: record.sourceKind,
                    sourceConfidence: record.sourceConfidence
                )
            }
        )
    }

    private static func source(
        fileID: UUID,
        documentNumber: Int,
        contentVersion: String,
        snapshot: String,
        segmenter: String,
        texts: [String]
    ) -> AILexicalIndexSource {
        var location = 0
        let records = texts.enumerated().map { offset, text in
            defer { location += text.utf16.count + 1 }
            return AISegmentRecord(
                id: AISegmentID(
                    document: documentNumber,
                    page: 1,
                    block: 1,
                    sentence: offset + 1
                ),
                text: text,
                normalizedText: AISegmenter.normalizeForSearch(text),
                sourceRange: AISourceTextRange(location: location, length: text.utf16.count),
                pageFingerprint: "page-\(snapshot)",
                sourceKind: .nativeText,
                sourceConfidence: nil
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
}
