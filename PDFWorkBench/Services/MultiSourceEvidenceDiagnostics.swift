import Foundation
import Darwin

/// Offline checks exercise production aggregation/index caching with deterministic
/// mock vectors. These timings are not Small EN inference or answer-quality claims.
nonisolated enum MultiSourceEvidenceDiagnostics {
    struct Measurement: Sendable {
        let documents: Int
        let segments: Int
        let segmentationSeconds: Double
        let tokenizationSeconds: Double
        let lexicalColdSeconds: Double
        let lexicalWarmSeconds: Double
        let mockIndexColdSeconds: Double
        let mockIndexWarmSeconds: Double
        let mockSearchColdSeconds: Double
        let mockSearchWarmSeconds: Double
    }
    struct Report: Sendable {
        let checks: Int
        let failures: [String]
        let measurements: [Measurement]
        let realMeasurements: [RealMeasurement]
    }
    struct MemorySample: Codable, Sendable {
        let residentBytes: UInt64
        let physicalFootprintBytes: UInt64
    }
    struct RealQueryMeasurement: Codable, Sendable {
        let queryID: String
        let query: String
        let queryTokens: Int
        let unknownTokens: Int
        let queryTokenizationSeconds: Double
        let mode: String
        let coldSearchSeconds: Double
        let repeatedSearchSeconds: Double
        let candidateCount: Int
        let returnedFiles: Int
        let expectedRelevantPages: Int
        let relevantPagesRetrieved: Int
        let firstRelevantRank: Int?
        let precisionAtK: Double?
        let topIDs: [String]
    }
    struct RealMeasurement: Codable, Sendable {
        let documents: Int
        let pages: Int
        let segments: Int
        let chunks: Int
        let segmentationSeconds: Double
        let tokenizationSeconds: Double
        let lexicalPreparationSeconds: Double
        let hybridColdPreparationSeconds: Double
        let hybridWarmPreparationSeconds: Double
        let hybridReorderedPreparationSeconds: Double
        let coldDocumentInferenceCalls: Int
        let warmAdditionalDocumentInferenceCalls: Int
        let reorderedAdditionalDocumentInferenceCalls: Int
        let coldQueryInferenceCalls: Int
        let coldCacheHits: Int
        let warmCacheHits: Int
        let reorderedCacheHits: Int
        let warmFirstQuerySeconds: Double
        let cacheBytes: Int
        let beforePreparationMemory: MemorySample?
        let afterColdMemory: MemorySample?
        let afterWarmMemory: MemorySample?
        let queries: [RealQueryMeasurement]
    }

    static func run() async -> Report {
        var checks = 0
        var failures: [String] = []
        var measurements: [Measurement] = []
        var realMeasurements: [RealMeasurement] = []
        func check(_ result: Bool, _ message: String) {
            checks += 1
            if !result { failures.append(message) }
        }
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DogearMultiSource-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        do {
            let tokenizer = try makeTokenizer()
            for count in [1, 5, 20] {
                let sources = fixtures(count: count)
                let segmentationStart = Date()
                let registry = try AISegmentRegistry(sources: sources, mainDocumentNumber: 1)
                let segmentation = Date().timeIntervalSince(segmentationStart)
                let tokenizationStart = Date()
                for number in 1...count {
                    _ = try AIEmbeddingChunk.make(registry: registry.registry(forDocument: number, canonicalIDs: true), tokenizer: tokenizer)
                }
                let tokenization = Date().timeIntervalSince(tokenizationStart)
                let query = AISegmentSearchRequest(query: "shared evidence result", topK: 40)
                let lexicalStart = Date()
                let lexical = try await AIEvidenceRetrievalFactory.makeSources(selection: .lexical, registry: registry)
                let coldLexical = try await lexical.retriever.search(query)
                let lexicalCold = Date().timeIntervalSince(lexicalStart)
                let warmLexicalStart = Date()
                let warmLexical = try await lexical.retriever.search(query)
                let lexicalWarm = Date().timeIntervalSince(warmLexicalStart)
                check(coldLexical == warmLexical, "\(count): lexical results changed on reuse")
                check(Set(coldLexical.prefix(count).map { $0.id.document }).count == count,
                      "\(count): a long document crowded out other sources")
                check(registry.documentMap().pages.count == sources.reduce(0) { $0 + $1.snapshot.pages.count },
                      "\(count): same page numbers merged across files")
                let scoped = try await lexical.retriever.search(AISegmentSearchRequest(query: query.query,
                    scope: AISegmentScope(pageRange: 2...2, documentNumbers: [count]), topK: 20))
                check(!scoped.isEmpty && scoped.allSatisfy { $0.id.document == count && $0.id.page == 2 },
                      "\(count): source/page scope escaped")

                let model = MockEmbedder(tokenizer: tokenizer)
                let selection = AIRetrievalSelection(mode: .scheme2EvidenceRAG, packageID: String(repeating: "a", count: 64))
                let root = cacheRoot.appendingPathComponent("\(count)")
                let indexStart = Date()
                let hybrid = try await AIEvidenceRetrievalFactory.makeSources(selection: selection, registry: registry,
                    sharedEmbedder: model, cacheRoot: root)
                let indexCold = Date().timeIntervalSince(indexStart)
                let documentCalls = await model.documentCalls
                let searchStart = Date()
                let coldHybrid = try await hybrid.retriever.search(query)
                _ = try await hybrid.retriever.search(AISegmentSearchRequest(query: query.query,
                    scope: AISegmentScope(pageRange: 2...2), topK: 10))
                let searchCold = Date().timeIntervalSince(searchStart)
                check(await model.queryCalls == 1, "\(count): same query was embedded once per document/scope")
                check(Set(coldHybrid.prefix(count).map { $0.id.document }).count == count,
                      "\(count): hybrid lost source balance")
                let warmStart = Date()
                let repeated = try await AIEvidenceRetrievalFactory.makeSources(selection: selection, registry: registry,
                    sharedEmbedder: model, cacheRoot: root)
                let indexWarm = Date().timeIntervalSince(warmStart)
                check(await model.documentCalls == documentCalls, "\(count): warm cache recomputed source vectors")
                let warmSearchStart = Date()
                let warmHybrid = try await repeated.retriever.search(query)
                let searchWarm = Date().timeIntervalSince(warmSearchStart)
                check(coldHybrid == warmHybrid, "\(count): cached hybrid ranking changed")
                let reordered = try AISegmentRegistry(sources: Array(sources.reversed()))
                _ = try await AIEvidenceRetrievalFactory.makeSources(selection: selection, registry: reordered,
                    sharedEmbedder: model, cacheRoot: root)
                check(await model.documentCalls == documentCalls, "\(count): request ordinal changed persistent cache identity")
                let cacheFiles = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                check(cacheFiles.count == count, "\(count): per-file caches duplicated after reordering")
                measurements.append(Measurement(documents: count, segments: registry.records.count,
                    segmentationSeconds: segmentation, tokenizationSeconds: tokenization,
                    lexicalColdSeconds: lexicalCold, lexicalWarmSeconds: lexicalWarm,
                    mockIndexColdSeconds: indexCold, mockIndexWarmSeconds: indexWarm,
                    mockSearchColdSeconds: searchCold, mockSearchWarmSeconds: searchWarm))
                print("MULTI RAG MOCK documents=\(count) segments=\(registry.records.count) segmentation=\(segmentation) tokenization=\(tokenization) lexicalCold=\(lexicalCold) lexicalWarm=\(lexicalWarm) mockIndexCold=\(indexCold) mockIndexWarm=\(indexWarm) mockSearchCold=\(searchCold) mockSearchWarm=\(searchWarm)")
            }
            let sources = fixtures(count: 2)
            let registry = try AISegmentRegistry(sources: sources, mainDocumentNumber: 2)
            let firstChunks = try AIEmbeddingChunk.make(registry: registry.registry(forDocument: 1, canonicalIDs: true), tokenizer: tokenizer).count
            let bounded = try await AIEvidenceRetrievalFactory.makeSources(
                selection: AIRetrievalSelection(mode: .scheme2EvidenceRAG, packageID: String(repeating: "b", count: 64)),
                registry: registry, sharedEmbedder: MockEmbedder(tokenizer: tokenizer),
                cacheRoot: cacheRoot.appendingPathComponent("aggregate-budget"), maximumRequestChunks: firstChunks)
            check(bounded.coverage.preparedFileIDs == [sources[0].fileID], "Aggregate chunk budget expanded once per source")
            check(bounded.coverage.skipped.map(\.fileID) == [sources[1].fileID], "Over-budget source was not reported in coverage")
            let longSource = AIWorkflowSourceSnapshot(fileID: UUID(), displayName: "long-extracted-sentence.pdf",
                snapshot: AIHighlightTextSnapshot(fingerprint: "long-extracted-sentence", pages: [
                    AITextPageSnapshot(pageNumber: 3, text: String(repeating: "shared ", count: 1_020) + "evidence",
                        fingerprint: "long-extracted-sentence-page")]))
            let smallSource = AIWorkflowSourceSnapshot(fileID: UUID(), displayName: "short.pdf",
                snapshot: AIHighlightTextSnapshot(fingerprint: "short", pages: [
                    AITextPageSnapshot(pageNumber: 1, text: "The evidence reports a limitation.", fingerprint: "short-page")]))
            let splitRegistry = try AISegmentRegistry(sources: [longSource, smallSource])
            let splitModel = MockEmbedder(tokenizer: tokenizer)
            let splitSelection = AIRetrievalSelection(mode: .scheme2EvidenceRAG, packageID: String(repeating: "c", count: 64))
            let splitRoot = cacheRoot.appendingPathComponent("split-sentences")
            let splitPrepared = try await AIEvidenceRetrievalFactory.makeSources(selection: splitSelection,
                registry: splitRegistry, sharedEmbedder: splitModel, cacheRoot: splitRoot, maximumRequestChunks: 4)
            check(splitPrepared.coverage.preparedFileIDs == [longSource.fileID, smallSource.fileID]
                && splitPrepared.coverage.skipped.isEmpty, "Losslessly split source was skipped despite sufficient request budget")
            check(await splitModel.documentCalls == 4, "Split source did not embed all three subchunks plus the second source")
            _ = try await AIEvidenceRetrievalFactory.makeSources(selection: splitSelection,
                registry: splitRegistry, sharedEmbedder: splitModel, cacheRoot: splitRoot, maximumRequestChunks: 4)
            check(await splitModel.documentCalls == 4, "Split source cache was not reused")
            let splitBounded = try await AIEvidenceRetrievalFactory.makeSources(selection: splitSelection,
                registry: splitRegistry, sharedEmbedder: splitModel, cacheRoot: splitRoot, maximumRequestChunks: 3)
            check(splitBounded.coverage.preparedFileIDs == [longSource.fileID]
                && splitBounded.coverage.skipped.map(\.fileID) == [smallSource.fileID],
                "Cached split subchunks did not consume the shared request budget")
            check(registry.snapshotFingerprint == sources[1].snapshot.fingerprint, "Main-file native commit fingerprint was lost")
            do {
                _ = try AISegmentRegistry(sources: [sources[0], sources[0]])
                check(false, "Duplicate file identity was accepted")
            } catch { check(error as? AISegmentRegistryError == .duplicateSource(sources[0].fileID), "Wrong duplicate source error") }
            let primary = registry.records.first { $0.id.document == 2 }!.id
            let secondary = registry.records.first { $0.id.document == 1 }!.id
            let executor = AIHighlightToolExecutor(registry: registry, intent: .overview, mainDocumentNumber: 2)
            _ = await executor.execute(.readSegments(AIReadSegmentsRequest(ids: [primary, secondary])))
            let candidate = AIHighlightCandidate(candidateID: "read-only", segmentIDs: [secondary], category: .keyFinding, importance: 3, note: nil)
            let staged = await executor.execute(.stageHighlights(AIStageHighlightsRequest(draftRevision: 0, title: "Scope", items: [candidate])))
            if case .staged(let result) = staged { check(!result.applied && result.error == .annotationsForbidden, "Reference file accepted annotation") }
            else { check(false, "Wrong staging response") }
            check(await executor.currentDraft().revision == 0, "Rejected reference edit changed draft revision")
            let noMain = AIHighlightToolExecutor(registry: registry, intent: .overview, mainDocumentNumber: nil)
            _ = await noMain.execute(.readSegments(AIReadSegmentsRequest(ids: [primary])))
            let mainCandidate = AIHighlightCandidate(candidateID: "main", segmentIDs: [primary], category: .keyFinding, importance: 3, note: nil)
            if case .staged(let result) = await noMain.execute(.stageHighlights(AIStageHighlightsRequest(draftRevision: 0, title: "None", items: [mainCandidate]))) {
                check(result.error == .annotationsForbidden, "No-main request could stage annotations")
            }
            let scan = AIWorkflowSourceSnapshot(fileID: UUID(), displayName: "scan.pdf",
                snapshot: AIHighlightTextSnapshot(fingerprint: "scan", pages: [.init(pageNumber: 1, text: "", fingerprint: "empty")]))
            let partialRegistry = try AISegmentRegistry(sources: [sources[0], scan])
            let partial = try await AIEvidenceRetrievalFactory.makeSources(selection: .lexical, registry: partialRegistry)
            check(partial.coverage.requestedCount == 2 && partial.coverage.preparedFileIDs == [sources[0].fileID]
                && partial.coverage.skipped.map(\.fileID) == [scan.fileID], "Scan coverage was silently overstated")
            let cancelled = Task { () throws -> [AISegmentSearchResult] in
                try await Task.sleep(for: .seconds(10))
                return try await partial.retriever.search(AISegmentSearchRequest(query: "evidence"))
            }
            cancelled.cancel()
            do { _ = try await cancelled.value; check(false, "Cancelled multi-source retrieval completed") }
            catch { check(error is CancellationError, "Cancellation became a skipped source") }

            let image = AIToolInputImage(id: UUID(), mimeType: "image/png", data: Data([1, 2, 3]))
            let visual = AIHighlightToolExecutor(registry: try AISegmentRegistry(sources: []), intent: .question("Describe the image"),
                verifiesAnswerEvidence: true, mainDocumentNumber: nil, images: [image])
            let invocation = AIToolInvocation(callID: "visual", name: AIHighlightToolName.publishAnswer,
                arguments: Data("{\"completion_status\":\"answered\",\"title\":\"Image\",\"result_markdown\":\"A diagram.\",\"evidence_segment_ids\":[],\"evidence_image_ids\":[\"\(image.id.uuidString)\"],\"final_draft_revision\":0,\"terminate\":true}".utf8))
            let review = try await visual.reviewRequest(for: invocation)
            check(review?.images == [image], "Visual review did not receive the actual cited attachment")
            let invented = AIPublishAnswerRequest(completionStatus: .answered, title: "Wrong", resultMarkdown: "Claim", evidenceSegmentIDs: [],
                finalDraftRevision: 0, terminate: false, evidenceImageIDs: [UUID()])
            check(await visual.publish(invented).error == .missingEvidence, "Invented image evidence accepted")
        } catch { check(false, "Multi-source diagnostic error: \(error)") }
        if let hint = ProcessInfo.processInfo.environment["DOGEAR_RAG_MODEL_PACKAGE"] {
            let real = await runRealModel(packageHint: hint, cacheRoot: cacheRoot.appendingPathComponent("real-model"))
            checks += real.checks
            failures += real.failures
            realMeasurements = real.measurements
        } else {
            print("MULTI RAG REAL MODEL: SKIPPED (set DOGEAR_RAG_MODEL_PACKAGE=installed or a verified package path); mock timings above are not model inference measurements")
        }
        return Report(checks: checks, failures: failures, measurements: measurements, realMeasurements: realMeasurements)
    }

    /// Actual BGE Small EN execution against small, authored fixtures. No provider or network is used.
    private static func runRealModel(packageHint: String, cacheRoot: URL) async
        -> (checks: Int, failures: [String], measurements: [RealMeasurement]) {
        var checks = 0
        var failures: [String] = []
        var measurements: [RealMeasurement] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append("Real multi-source: " + message) }
        }
        do {
            // Same explicit package selection as AIEvidenceRetrievalDiagnostics. Never infer a download.
            let packageURL: URL
            if packageHint == "installed" {
                guard let packageID = UserDefaults.standard.string(forKey: AIRetrievalSelection.packageDefaultsKey) else {
                    throw AIRetrievalError.modelMissing
                }
                packageURL = try AILocalEmbeddingModels.packageURL(packageID)
            } else { packageURL = URL(fileURLWithPath: packageHint, isDirectory: true) }
            let memoryBeforeLoad = processMemory()
            let loadStart = Date()
            let (manifest, packageID) = try AILocalEmbeddingModels.validatePackage(at: packageURL)
            let actualModel = try AICoreMLEmbedder(packageURL: packageURL, packageID: packageID)
            let loadSeconds = Date().timeIntervalSince(loadStart)
            print("MULTI RAG REAL MODEL: actual_model=\(manifest.model) package=\(packageID) compute=cpuOnly corpus=authored-synthetic-v1 provider_calls=0 load_and_validation_seconds=\(loadSeconds) memory_before_load=\(memoryDescription(memoryBeforeLoad)) memory_after_load=\(memoryDescription(processMemory()))")
            let selection = AIRetrievalSelection(mode: .scheme2EvidenceRAG, packageID: packageID)

            for count in [1, 5, 20] {
                let sources = realFixtures(count: count)
                let segmentationStart = Date()
                let registry = try AISegmentRegistry(sources: sources, mainDocumentNumber: 1)
                let segmentationSeconds = Date().timeIntervalSince(segmentationStart)
                let tokenizer = actualModel.tokenizer
                let tokenizationStart = Date()
                var chunks = 0
                for number in 1...count {
                    chunks += try AIEmbeddingChunk.make(registry: registry.registry(forDocument: number, canonicalIDs: true), tokenizer: tokenizer).count
                }
                let tokenizationSeconds = Date().timeIntervalSince(tokenizationStart)
                check(chunks <= 300, "\(count) documents exceeded the bounded real-model fixture budget")
                check(Set(sources.map(\.fileID)).count == count && Set(sources.map(\.displayName)).count == 1,
                      "\(count): same-name fixtures did not retain distinct identities")
                let lexicalStart = Date()
                let lexical = try await AIEvidenceRetrievalFactory.makeSources(selection: .lexical, registry: registry)
                let lexicalPreparation = Date().timeIntervalSince(lexicalStart)
                let model = CountedRealEmbedder(base: actualModel)
                let coldStats = RealIndexStatistics()
                let root = cacheRoot.appendingPathComponent("\(count)")
                let beforeMemory = processMemory()
                let coldStart = Date()
                let cold = try await AIEvidenceRetrievalFactory.makeSources(selection: selection, registry: registry,
                    indexed: { _, hit, _ in await coldStats.record(hit: hit) }, sharedEmbedder: model, cacheRoot: root)
                let coldSeconds = Date().timeIntervalSince(coldStart)
                let afterColdMemory = processMemory()
                let coldCounts = await model.counts()
                check(cold.coverage.preparedFileIDs.count == count && cold.coverage.skipped.isEmpty,
                      "\(count): real-model preparation skipped part of the bounded fixture")
                check(coldCounts.documents == chunks, "\(count): cold index did not embed each fixture chunk once")

                var queryMeasurements: [RealQueryMeasurement] = []
                let queries = realQueries(documentCount: count)
                for fixture in queries {
                    let tokenStart = Date()
                    let tokens = tokenizer.tokens(manifest.queryPrefix + fixture.query)
                    let tokenSeconds = Date().timeIntervalSince(tokenStart)
                    let request = AISegmentSearchRequest(query: fixture.query, topK: max(10, count * 2))
                    for (mode, retriever) in [("lexical", lexical.retriever), ("actual-small-en-hybrid", cold.retriever)] {
                        let searchStart = Date()
                        let results = try await retriever.search(request)
                        let searchSeconds = Date().timeIntervalSince(searchStart)
                        let repeatStart = Date()
                        let repeated = try await retriever.search(request)
                        let repeatSeconds = Date().timeIntervalSince(repeatStart)
                        check(results == repeated, "\(count)/\(fixture.id)/\(mode): same-instance ranking changed on repeated search")
                        check(results.allSatisfy { registry.record(for: $0.id) != nil },
                              "\(count)/\(fixture.id)/\(mode): result escaped source identity")
                        let relevantResults = results.enumerated().filter { fixture.pages.contains(PageKey(document: $0.element.id.document, page: $0.element.id.page)) }
                        let retrievedPages = Set(relevantResults.map { PageKey(document: $0.element.id.document, page: $0.element.id.page) })
                        queryMeasurements.append(RealQueryMeasurement(queryID: fixture.id, query: fixture.query,
                            queryTokens: tokens.count, unknownTokens: tokens.filter { $0 == 100 }.count,
                            queryTokenizationSeconds: tokenSeconds, mode: mode, coldSearchSeconds: searchSeconds,
                            repeatedSearchSeconds: repeatSeconds, candidateCount: results.count,
                            returnedFiles: Set(results.map { $0.id.document }).count,
                            expectedRelevantPages: fixture.pages.count, relevantPagesRetrieved: retrievedPages.count,
                            firstRelevantRank: relevantResults.first.map { $0.offset + 1 },
                            precisionAtK: fixture.pages.isEmpty || results.isEmpty ? nil : Double(relevantResults.count) / Double(results.count),
                            topIDs: results.prefix(12).map { $0.id.description }))
                    }
                }
                let afterQueries = await model.counts()
                check(afterQueries.queries == queries.count,
                      "\(count): real query inference repeated across documents or repeated searches")
                let warmStats = RealIndexStatistics()
                let warmStart = Date()
                let warm = try await AIEvidenceRetrievalFactory.makeSources(selection: selection, registry: registry,
                    indexed: { _, hit, _ in await warmStats.record(hit: hit) }, sharedEmbedder: model, cacheRoot: root)
                let warmSeconds = Date().timeIntervalSince(warmStart)
                let afterWarmMemory = processMemory()
                let warmCounts = await model.counts()
                check(warmCounts.documents == coldCounts.documents, "\(count): actual model re-embedded warm source caches")
                let warmFirstQueryStart = Date()
                let warmQuery = try await warm.retriever.search(AISegmentSearchRequest(query: queries[0].query, topK: max(10, count * 2)))
                let warmFirstQuerySeconds = Date().timeIntervalSince(warmFirstQueryStart)
                let originalQuery = try await cold.retriever.search(AISegmentSearchRequest(query: queries[0].query, topK: max(10, count * 2)))
                check(warmQuery == originalQuery, "\(count): persistent cache changed real hybrid ranking")

                let reorderedRegistry = try AISegmentRegistry(sources: Array(sources.reversed()))
                let reorderedStats = RealIndexStatistics()
                let reorderedStart = Date()
                let reordered = try await AIEvidenceRetrievalFactory.makeSources(selection: selection, registry: reorderedRegistry,
                    indexed: { _, hit, _ in await reorderedStats.record(hit: hit) }, sharedEmbedder: model, cacheRoot: root)
                let reorderedSeconds = Date().timeIntervalSince(reorderedStart)
                let reorderedCounts = await model.counts()
                check(reorderedCounts.documents == coldCounts.documents, "\(count): source reordering caused real re-embedding")
                // Fair round-robin ordering intentionally follows selection order. Compare within each stable file.
                for number in 1...count {
                    let reversedNumber = count + 1 - number
                    let original = try await warm.retriever.search(AISegmentSearchRequest(query: queries[0].query,
                        scope: AISegmentScope(documentNumbers: [number]), topK: 3))
                    let reversed = try await reordered.retriever.search(AISegmentSearchRequest(query: queries[0].query,
                        scope: AISegmentScope(documentNumbers: [reversedNumber]), topK: 3))
                    check(original.map { localID($0.id) } == reversed.map { localID($0.id) },
                          "\(count): source reordering changed file \(number)'s local ranking")
                }
                let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
                check(files.count == count && files.allSatisfy { $0.pathExtension == "json" },
                      "\(count): reordering left duplicate or partial real-model caches")
                let cacheBytes = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
                let coldHits = await coldStats.hits
                let warmHits = await warmStats.hits
                let reorderedHits = await reorderedStats.hits
                check(coldHits == 0 && warmHits == count && reorderedHits == count,
                      "\(count): actual cold/warm/reordered cache-hit telemetry disagreed")
                let measurement = RealMeasurement(documents: count, pages: sources.reduce(0) { $0 + $1.snapshot.pages.count },
                    segments: registry.records.count, chunks: chunks, segmentationSeconds: segmentationSeconds,
                    tokenizationSeconds: tokenizationSeconds, lexicalPreparationSeconds: lexicalPreparation,
                    hybridColdPreparationSeconds: coldSeconds, hybridWarmPreparationSeconds: warmSeconds,
                    hybridReorderedPreparationSeconds: reorderedSeconds, coldDocumentInferenceCalls: coldCounts.documents,
                    warmAdditionalDocumentInferenceCalls: warmCounts.documents - coldCounts.documents,
                    reorderedAdditionalDocumentInferenceCalls: reorderedCounts.documents - warmCounts.documents,
                    coldQueryInferenceCalls: afterQueries.queries, coldCacheHits: coldHits, warmCacheHits: warmHits,
                    reorderedCacheHits: reorderedHits, warmFirstQuerySeconds: warmFirstQuerySeconds, cacheBytes: cacheBytes,
                    beforePreparationMemory: beforeMemory, afterColdMemory: afterColdMemory, afterWarmMemory: afterWarmMemory,
                    queries: queryMeasurements)
                measurements.append(measurement)
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                print("MULTI RAG REAL MEASUREMENT " + String(decoding: try encoder.encode(measurement), as: UTF8.self))
            }

            let cancelModel = CountedRealEmbedder(base: actualModel)
            let cancelRegistry = try AISegmentRegistry(sources: realFixtures(count: 20))
            let cancelled = Task {
                try await AIEvidenceRetrievalFactory.makeSources(selection: selection, registry: cancelRegistry,
                    sharedEmbedder: cancelModel, cacheRoot: cacheRoot.appendingPathComponent("cancelled"))
            }
            // Wait for a real embedding call to be dispatched, rather than canceling a sleeping dummy task.
            for _ in 0..<200 {
                if await cancelModel.counts().documents > 0 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let beforeCancel = await cancelModel.counts()
            let cancelStart = Date()
            cancelled.cancel()
            do { _ = try await cancelled.value; check(false, "In-progress real index completed after cancellation") }
            catch { check(error is CancellationError, "Real index cancellation was converted to a skipped source or another error") }
            let cancellationSeconds = Date().timeIntervalSince(cancelStart)
            let afterCancel = await cancelModel.counts()
            check(beforeCancel.documents > 0, "Cancellation fixture never dispatched a model invocation")
            let cancelFiles = (try? FileManager.default.contentsOfDirectory(at: cacheRoot.appendingPathComponent("cancelled"), includingPropertiesForKeys: nil)) ?? []
            check(cancelFiles.allSatisfy { $0.pathExtension == "json" }, "Cancellation left a partial embedding cache")
            print("MULTI RAG REAL CANCELLATION seconds=\(cancellationSeconds) document_calls_dispatched=\(beforeCancel.documents) calls_completed_before_cancel=\(beforeCancel.completedDocuments) calls_completed_after_cancel=\(afterCancel.completedDocuments) note=synchronous_CoreML_prediction_is_cooperatively_cancelled_at_its_boundary")
            print("MULTI RAG REAL MODEL: \(checks) invariant checks, \(failures.count) failures; relevance observations use synthetic ground truth and do not evaluate generated answers")
        } catch { check(false, "Evaluation failed: \(error)") }
        return (checks, failures, measurements)
    }

    private struct PageKey: Hashable { let document: Int; let page: Int }
    private struct RealQuery { let id: String; let query: String; let pages: Set<PageKey> }

    private static func realQueries(documentCount: Int) -> [RealQuery] {
        var conflict: Set<PageKey> = [PageKey(document: 1, page: 3)]
        if documentCount >= 2 { conflict.insert(PageKey(document: 2, page: 1)) }
        return [
            RealQuery(id: "english-paraphrase", query: "How does the system identify digits drawn by hand?", pages: [PageKey(document: 1, page: 1)]),
            RealQuery(id: "chinese", query: "实验中电池续航提高了多少？", pages: documentCount >= 3 ? [PageKey(document: 3, page: 1)] : []),
            RealQuery(id: "conflicting-findings", query: "Do the independent studies agree that adaptive sampling extends battery life?", pages: conflict),
            RealQuery(id: "unsupported-question", query: "What is the measured mass of the hypothetical xenon planet Zephyr QX7?", pages: [])
        ]
    }

    private static func realFixtures(count: Int) -> [AIWorkflowSourceSnapshot] {
        (1...count).map { number in
            let pages = (1...(number == 1 ? 24 : 5)).map { page -> AITextPageSnapshot in
                let text: String
                switch (number, page) {
                case (1, 1): text = "A convolutional neural network classifies handwritten digits from grayscale pixel arrays. Successive learned filters extract stroke patterns and visual shapes. A softmax output selects one of ten numeral classes."
                case (1, 2): text = "Early stopping prevents overfitting by monitoring validation error. Training stops when held-out accuracy no longer improves. Evaluation examples remain separate from the training images."
                case (1, 3): text = "The first controlled study found that adaptive sampling extended sensor battery life by eighteen percent. Sensors were tested at constant temperature with identical battery capacity. The researchers attribute the gain to fewer radio transmissions."
                case (2, 1): text = "An independent replication found that adaptive sampling did not extend sensor battery life. Its measured battery lifetime was two percent shorter than fixed-rate sampling. Frequent wake-up costs offset the energy saved by fewer radio transmissions."
                case (3, 1): text = "中文实验报告表明，自适应采样使电池续航提高了百分之十二。实验保持温度和电池容量一致。研究人员同时指出，结论只适用于低频传感器。"
                default:
                    let topics = [
                        "A botanical survey describes leaf shapes in coastal trees. The dataset records seasonal flowering dates. Measurements were collected on marked field plots.",
                        "A sorting algorithm arranges integer records in ascending order. The analysis counts comparisons and memory allocations. Large arrays were partitioned into independent blocks.",
                        "An archive catalog lists pottery fragments by excavation layer. Researchers compare surface colors and decorative patterns. Dates are recorded as approximate historical ranges.",
                        "The laboratory printer deposits colored toner onto paper. Maintenance logs record cartridge replacements and cleaning cycles. These records contain no evaluation of learning algorithms."
                    ]
                    text = topics[(number + page) % topics.count]
                }
                return AITextPageSnapshot(pageNumber: page, text: text,
                    fingerprint: AIRetrievalHash.data(Data("real-fixture-v1|\(number)|\(page)|\(text)".utf8)))
            }
            let fingerprint = AIRetrievalHash.data(Data(pages.map(\.fingerprint).joined(separator: "|").utf8))
            return AIWorkflowSourceSnapshot(fileID: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", number))!,
                displayName: "same-name-study.pdf", snapshot: AIHighlightTextSnapshot(fingerprint: fingerprint, pages: pages))
        }
    }

    private static func localID(_ id: AISegmentID) -> String { "\(id.page).\(id.block).\(id.sentence)" }

    private static func processMemory() -> MemorySample? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return MemorySample(residentBytes: info.resident_size, physicalFootprintBytes: info.phys_footprint)
    }
    private static func memoryDescription(_ sample: MemorySample?) -> String {
        sample.map { "rss:\($0.residentBytes),footprint:\($0.physicalFootprintBytes)" } ?? "unavailable"
    }

    private actor RealIndexStatistics {
        var hits = 0
        func record(hit: Bool) { if hit { hits += 1 } }
    }
    private actor CountedRealEmbedder: AITextEmbedding {
        let tokenizer: AIBertWordPieceTokenizer
        let base: AICoreMLEmbedder
        private var documents = 0
        private var queries = 0
        private var completedDocuments = 0
        init(base: AICoreMLEmbedder) { self.base = base; tokenizer = base.tokenizer }
        func embed(tokens: [Int32]) async throws -> [Float] {
            documents += 1
            let vector = try await base.embed(tokens: tokens)
            completedDocuments += 1
            return vector
        }
        func embedQuery(_ text: String) async throws -> [Float] {
            queries += 1
            return try await base.embedQuery(text)
        }
        func counts() -> (documents: Int, queries: Int, completedDocuments: Int) { (documents, queries, completedDocuments) }
    }

    private static func fixtures(count: Int) -> [AIWorkflowSourceSnapshot] {
        (1...count).map { number in
            let pages = (1...(number == 1 ? 24 : 6)).map { page in
                AITextPageSnapshot(pageNumber: page,
                    text: (1...9).map { sentence in
                        "The shared evidence result for source \(number) page \(page) sample \(sentence) reports a measured limitation."
                    }.joined(separator: " "), fingerprint: "source-\(number)-page-\(page)")
            }
            return AIWorkflowSourceSnapshot(fileID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!,
                displayName: "same-name.pdf", snapshot: AIHighlightTextSnapshot(fingerprint: "fixture-\(number)", pages: pages))
        }
    }
    private static func makeTokenizer() throws -> AIBertWordPieceTokenizer {
        var words = (0..<30_522).map { "reserved\($0)" }
        for (index, word) in [(0,"[PAD]"), (100,"[UNK]"), (101,"[CLS]"), (102,"[SEP]"), (103,"[MASK]")]
        { words[index] = word }
        for (offset, word) in "the shared evidence result for source page sample reports a measured limitation .".split(separator: " ").enumerated()
        { words[200 + offset] = String(word) }
        return try AIBertWordPieceTokenizer(vocabulary: words.joined(separator: "\n"))
    }
    private actor MockEmbedder: AITextEmbedding {
        let tokenizer: AIBertWordPieceTokenizer
        var documentCalls = 0
        var queryCalls = 0
        init(tokenizer: AIBertWordPieceTokenizer) { self.tokenizer = tokenizer }
        func embed(tokens: [Int32]) throws -> [Float] {
            try Task.checkCancellation()
            documentCalls += 1
            return vector(tokens)
        }
        func embedQuery(_ text: String) throws -> [Float] {
            try Task.checkCancellation()
            queryCalls += 1
            return vector(tokenizer.tokens(text))
        }
        private func vector(_ tokens: [Int32]) -> [Float] {
            var values = [Float](repeating: 0, count: 384)
            for token in tokens { values[Int(token) % 384] += 1 }
            if tokens.isEmpty { values[0] = 1 }
            let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
            return values.map { $0 / norm }
        }
    }
}
