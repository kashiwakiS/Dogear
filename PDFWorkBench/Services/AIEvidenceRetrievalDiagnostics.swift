import Foundation

nonisolated enum AIEvidenceRetrievalDiagnostics {
    struct Report: Sendable { let checks: Int; let failures: [String] }

    static func run() async -> Report {
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        let suite = "Dogear-Retrieval-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check((try? AIRetrievalSelection.capture(from: defaults).mode) == .scheme1Lexical, "Upgrade default must remain lexical")
        defaults.set("unknown", forKey: AIRetrievalMode.defaultsKey)
        do { _ = try AIRetrievalSelection.capture(from: defaults); check(false, "Unknown mode must fail closed") }
        catch { check(error as? AIRetrievalError == .invalidSelection, "Wrong unknown-mode error") }
        defaults.set(AIRetrievalMode.scheme2EvidenceRAG.rawValue, forKey: AIRetrievalMode.defaultsKey)
        do { _ = try AIRetrievalSelection.capture(from: defaults); check(false, "Missing model must not silently use lexical") }
        catch { check(error as? AIRetrievalError == .modelMissing, "Wrong missing-model error") }
        defaults.set(String(repeating: "a", count: 64), forKey: AIRetrievalSelection.packageDefaultsKey)
        let captured = try? AIRetrievalSelection.capture(from: defaults)
        defaults.set(AIRetrievalMode.scheme1Lexical.rawValue, forKey: AIRetrievalMode.defaultsKey)
        check(captured?.mode == .scheme2EvidenceRAG, "A settings change mutated the captured request")
        do { _ = try AILocalEmbeddingModels.packageURL("../escape"); check(false, "Package path traversal accepted") }
        catch { check(true, "Traversal rejected") }

        let snapshot = AIHighlightTextSnapshot(fingerprint: "rag-fixture", pages: [
            AITextPageSnapshot(pageNumber: 1, text: "A convolutional neural network recognizes handwritten characters from grayscale images. Layers extract visual features.", fingerprint: "p1"),
            AITextPageSnapshot(pageNumber: 2, text: "Training minimizes cross entropy with gradient descent. Evaluation uses a held out dataset.", fingerprint: "p2"),
            AITextPageSnapshot(pageNumber: 3, text: "The printer uses toner and paper. Bibliography lists references.", fingerprint: "p3")
        ])
        do {
            let packageFixture = FileManager.default.temporaryDirectory.appendingPathComponent("DogearPackageTests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: packageFixture) }
            let source = packageFixture.appendingPathComponent("source", isDirectory: true)
            let compiled = source.appendingPathComponent("embedding.mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
            let asset = Data("fixture-only-not-a-real-model".utf8)
            try asset.write(to: source.appendingPathComponent("vocab.txt"))
            try asset.write(to: compiled.appendingPathComponent("model.mil"))
            let manifest = AIEmbeddingManifest(schema: 1, model: "BAAI/bge-small-en-v1.5",
                revision: "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a", dimensions: 384, maximumTokens: 512,
                tokenizer: AIBertWordPieceTokenizer.version, pooling: "cls-l2", precision: "float16",
                queryPrefix: "Represent this sentence for searching relevant passages: ",
                files: ["vocab.txt": AIRetrievalHash.data(asset), "embedding.mlmodelc/model.mil": AIRetrievalHash.data(asset)])
            try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("manifest.json"))
            let (_, fixtureID) = try AILocalEmbeddingModels.validatePackage(at: source)
            check(fixtureID.count == 64, "Valid package manifest rejected")
            let metadata = source.appendingPathComponent(".DS_Store")
            try Data("Finder metadata".utf8).write(to: metadata)
            try Data("Nested Finder metadata".utf8).write(to: compiled.appendingPathComponent(".DS_Store"))
            check((try AILocalEmbeddingModels.validatePackage(at: source).1) == fixtureID, "Finder metadata changed model identity")
            let copied = packageFixture.appendingPathComponent("copied", isDirectory: true)
            try AILocalEmbeddingModels.copyPackage(from: source, manifest: manifest, to: copied)
            check((try AILocalEmbeddingModels.validatePackage(at: copied).1) == fixtureID, "Staging changed verified assets")
            check(!FileManager.default.fileExists(atPath: copied.appendingPathComponent(".DS_Store").path)
                && !FileManager.default.fileExists(atPath: copied.appendingPathComponent("embedding.mlmodelc/.DS_Store").path),
                "Unverified Finder metadata was imported")
            let extra = source.appendingPathComponent("unexpected.bin")
            try asset.write(to: extra)
            check((try? AILocalEmbeddingModels.validatePackage(at: source)) == nil, "Unlisted model asset accepted")
            try FileManager.default.removeItem(at: extra)
            try FileManager.default.removeItem(at: metadata)
            try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: source.appendingPathComponent("vocab.txt"))
            check((try? AILocalEmbeddingModels.validatePackage(at: source)) == nil, "Metadata symlink bypassed validation")
            try FileManager.default.removeItem(at: metadata)
            try Data("corrupt".utf8).write(to: source.appendingPathComponent("vocab.txt"))
            check((try? AILocalEmbeddingModels.validatePackage(at: source)) == nil, "Corrupt model asset accepted")

            let registry = try AISegmentRegistry(snapshot: snapshot)
            let lexical = try AILexicalEvidenceRetriever(registry: registry)
            let query = AISegmentSearchRequest(query: "convolutional", topK: 2)
            let original = AISimpleLexicalSearcher().search(query, in: registry)
            let wrapped = try await lexical.search(query)
            check(original == wrapped, "Scheme 1 wrapper changed results")
            let ids = registry.records.map(\.id)
            let fused = AIHybridEvidenceRetriever.fuse(lexical: [ids[0], ids[1], ids[0]], dense: [ids[1], ids[2]])
            check(fused.map(\.id) == [ids[1], ids[2]], "Frozen 1/0 RRF did not preserve dense ranking")
            check(Set(fused.map(\.id)).count == fused.count, "RRF duplicated IDs")
            check(abs((fused.first?.score ?? 0) - (1.0 / 61)) < 0.000001,
                  "Weighted RRF changed its frozen rank-only formula")
            let replacement = FixtureRetriever(id: ids.last!)
            let executor = AIHighlightToolExecutor(registry: registry, intent: .overview, evidenceRetriever: replacement)
            let output = try await executor.executeForWorkflow(.searchSegments(query))
            if case .searchResults(let values) = output { check(values.first?.id == ids.last, "Async executor ignored injected retriever") }
            else { check(false, "Unexpected search result") }
            let invocation = AIToolInvocation(callID: "rag-search", name: AIHighlightToolName.searchSegments,
                arguments: Data(#"{"query":"convolutional","page_start":1,"page_end":3,"top_k":2,"strategy":"questionRelevance"}"#.utf8))
            let wire = try await executor.execute(invocation)
            check(String(decoding: wire.output, as: UTF8.self).contains(ids.last!.description), "Wire executor bypassed semantic retrieval")
            let stage = await executor.currentDraft()
            check(stage.revision == 0 && stage.items.isEmpty, "Searching modified the draft")

            var words = (0..<30_522).map { "reserved\($0)" }
            for (index, word) in [(0,"[PAD]"), (100,"[UNK]"), (101,"[CLS]"), (102,"[SEP]"), (103,"[MASK]"),
                                  (200,"hello"), (201,"world"), (202,"!"), (203,"cafe"), (204,"play"), (205,"##ing")] { words[index] = word }
            let tokenizer = try AIBertWordPieceTokenizer(vocabulary: words.joined(separator: "\n"))
            check(tokenizer.tokens("HELLO world!") == [200,201,202], "Lowercase/punctuation mismatch")
            check(tokenizer.tokens("Café") == [203], "Accent stripping mismatch")
            check(tokenizer.tokens("playing") == [204,205], "WordPiece suffix mismatch")
            check(tokenizer.tokens("[CLS] HELLO [MASK]") == [101,200,103], "Special-token handling mismatch")
            check(tokenizer.tokens(String(repeating: "a", count: 101)) == [100], "Overlong word must become UNK")

            let scheme2Backend = CountingLexicalBackend()
            let scheme2Cache = FileManager.default.temporaryDirectory.appendingPathComponent(
                "DogearDenseOnly-\(UUID().uuidString)"
            )
            defer { try? FileManager.default.removeItem(at: scheme2Cache) }
            let scheme2Selection = AIRetrievalSelection(
                mode: .scheme2EvidenceRAG,
                packageID: String(repeating: "d", count: 64)
            )
            let scheme2Embedder = FixtureTextEmbedder(tokenizer: tokenizer)
            let secondarySnapshot = AIHighlightTextSnapshot(
                fingerprint: "rag-fixture-secondary",
                pages: [
                    AITextPageSnapshot(
                        pageNumber: 1,
                        text: "A second source states its opening result. A follow-up sentence gives supporting evidence.",
                        fingerprint: "secondary-p1"
                    ),
                    AITextPageSnapshot(
                        pageNumber: 2,
                        text: "The second page describes the method. Another sentence records its limitations.",
                        fingerprint: "secondary-p2"
                    ),
                    AITextPageSnapshot(
                        pageNumber: 3,
                        text: "The final page gives a conclusion. A final detail closes the source.",
                        fingerprint: "secondary-p3"
                    )
                ]
            )
            let scheme2Registry = try AISegmentRegistry(sources: [
                AIWorkflowSourceSnapshot(
                    fileID: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
                    displayName: "dense-only-a.pdf",
                    snapshot: snapshot
                ),
                AIWorkflowSourceSnapshot(
                    fileID: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
                    displayName: "dense-only-b.pdf",
                    snapshot: secondarySnapshot
                )
            ])
            let scheme2 = try await AIEvidenceRetrievalFactory.makeSources(
                selection: scheme2Selection,
                registry: scheme2Registry,
                sharedEmbedder: scheme2Embedder,
                cacheRoot: scheme2Cache.appendingPathComponent("populated"),
                lexicalBackend: scheme2Backend
            )
            let ordinaryRequest = AISegmentSearchRequest(
                query: "stable dense ranking",
                topK: 4,
                strategy: .questionRelevance
            )
            let ordinaryResults = try await scheme2.retriever.search(ordinaryRequest)
            let repeatedOrdinaryResults = try await scheme2.retriever.search(ordinaryRequest)
            check(
                ordinaryResults == repeatedOrdinaryResults,
                "Scheme 2 multi-source dense ranking was not stable."
            )
            check(
                ordinaryResults.map(\.id.document) == [1, 2, 1, 2],
                "Scheme 2 ordinary search lost source balance."
            )
            let overviewResults = try await scheme2.retriever.search(AISegmentSearchRequest(
                query: "",
                topK: 4,
                strategy: .overviewSalience
            ))
            let overviewByDocument = Dictionary(
                grouping: overviewResults,
                by: { $0.id.document }
            )
            check(
                overviewResults.map(\.id.document) == [1, 2, 1, 2],
                "Scheme 2 overview lost source balance."
            )
            check(
                overviewByDocument.count == 2
                    && overviewByDocument.values.allSatisfy {
                        $0.count == 2 && Set($0.map(\.id.page)).count == 2
                    },
                "Scheme 2 global dense ranking erased per-source overview page distribution."
            )
            let populatedPrepareCalls = await scheme2Backend.prepareCallCount
            check(
                populatedPrepareCalls == 0,
                "Scheme 2 prepared a lexical backend."
            )

            let emptyRegistry = try AISegmentRegistry(snapshot: AIHighlightTextSnapshot(
                fingerprint: "dense-empty-registry",
                pages: []
            ))
            let emptyScheme2 = try await AIEvidenceRetrievalFactory.makeSources(
                selection: scheme2Selection,
                registry: emptyRegistry,
                sharedEmbedder: RejectingTextEmbedder(tokenizer: tokenizer),
                cacheRoot: scheme2Cache.appendingPathComponent("empty-registry"),
                lexicalBackend: scheme2Backend
            )
            let emptyResults = try await emptyScheme2.retriever.search(query)
            check(
                emptyResults.isEmpty,
                "Empty Scheme 2 registry returned evidence."
            )
            let noTextSource = AIWorkflowSourceSnapshot(
                fileID: UUID(),
                displayName: "no-text.pdf",
                snapshot: AIHighlightTextSnapshot(
                    fingerprint: "dense-no-text-source",
                    pages: [AITextPageSnapshot(
                        pageNumber: 1,
                        text: "",
                        fingerprint: "dense-no-text-page"
                    )]
                )
            )
            let noTextRegistry = try AISegmentRegistry(sources: [noTextSource])
            let noTextScheme2 = try await AIEvidenceRetrievalFactory.makeSources(
                selection: scheme2Selection,
                registry: noTextRegistry,
                sharedEmbedder: RejectingTextEmbedder(tokenizer: tokenizer),
                cacheRoot: scheme2Cache.appendingPathComponent("no-text"),
                lexicalBackend: scheme2Backend
            )
            let noTextResults = try await noTextScheme2.retriever.search(query)
            let finalPrepareCalls = await scheme2Backend.prepareCallCount
            check(
                noTextScheme2.coverage.preparedFileIDs.isEmpty
                    && noTextScheme2.coverage.skipped.map(\.fileID) == [noTextSource.fileID]
                    && noTextResults.isEmpty
                    && finalPrepareCalls == 0,
                "Empty-text Scheme 2 performed retrieval work or overstated coverage."
            )

            let windowSnapshot = AIHighlightTextSnapshot(
                fingerprint: "retrieval-window-fixture",
                pages: [AITextPageSnapshot(
                    pageNumber: 9,
                    text: "Opening background. Prior observations. The mechanism uses alpha. Beta completes the reaction. Limitations remain. Closing note.",
                    fingerprint: "retrieval-window-page"
                )]
            )
            let windowRegistry = try AISegmentRegistry(snapshot: windowSnapshot)
            let windows = AIRetrievalWindow.make(records: windowRegistry.records)
            check(
                windows.map { $0.anchorID.sentence } == [2, 4, 6]
                    && windows.map { $0.segmentIDs.map(\.sentence) }
                        == [[1, 2, 3], [3, 4, 5], [5, 6]],
                "Retrieval windows changed their deterministic max-three/stride-two topology."
            )
            check(
                zip(windows, windows.dropFirst()).allSatisfy { pair in
                    Set(pair.0.segmentIDs).intersection(pair.1.segmentIDs).count <= 1
                },
                "Adjacent retrieval windows can crowd top-K with duplicate context."
            )
            check(
                windows.allSatisfy { window in
                    window.records.count <= 3
                        && Set(window.records.map(\.id.document)).count == 1
                        && Set(window.records.map(\.id.page)).count == 1
                        && Set(window.records.map(\.id.block)).count == 1
                        && windowRegistry.record(for: window.anchorID) != nil
                },
                "A retrieval window crossed source scope or lost its canonical sentence anchor."
            )
            let windowLexical = try AILexicalEvidenceRetriever(registry: windowRegistry)
            let crossSentence = try await windowLexical.search(AISegmentSearchRequest(
                query: "alpha beta",
                topK: 10,
                strategy: .questionRelevance
            ))
            check(
                crossSentence.first?.id == windows[1].anchorID
                    && Set(crossSentence.map(\.id)).isSubset(of: Set(windows.map(\.anchorID))),
                "BM25 did not rank cross-sentence window evidence through stable anchors."
            )
            let windowChunks = try AIEmbeddingChunk.make(
                registry: windowRegistry,
                tokenizer: tokenizer
            )
            check(
                windowChunks.count == windows.count
                    && windowChunks.map(\.anchorID) == windows.map(\.anchorID)
                    && windowChunks.map(\.ids) == windows.map(\.segmentIDs),
                "Dense chunks did not reuse the BM25 retrieval-window topology."
            )

            let chunks = try AIEmbeddingChunk.make(registry: registry, tokenizer: tokenizer)
            check(chunks.flatMap(\.ids) == ids, "Chunking dropped or reordered sentence IDs")
            check(chunks.allSatisfy {
                Set($0.ids.map(\.document)).count == 1
                    && Set($0.ids.map(\.page)).count == 1
                    && Set($0.ids.map(\.block)).count == 1
                    && registry.record(for: $0.anchorID) != nil
            }, "Chunk crosses source scope or returns a noncanonical anchor")
            for count in [510, 511, 1_020, 1_021] {
                let text = String(repeating: "hello ", count: count - 1) + "world"
                let longRegistry = try AISegmentRegistry(snapshot: AIHighlightTextSnapshot(fingerprint: "long-\(count)",
                    pages: [AITextPageSnapshot(pageNumber: 7, text: text, fingerprint: "long-page-\(count)")]))
                let split = try AIEmbeddingChunk.make(registry: longRegistry, tokenizer: tokenizer)
                check(longRegistry.records.count == 1, "Oversized fixture did not remain one source sentence")
                check(split.count == (count + 509) / 510 && split.allSatisfy { $0.tokens.count <= 510 },
                      "Boundary \(count): oversized sentence exceeded model capacity or lost a subchunk")
                check(split.flatMap(\.tokens) == tokenizer.tokens(text), "Boundary \(count): token splitting truncated, duplicated, or reordered text")
                check(split.allSatisfy { $0.ids == [longRegistry.records[0].id] }
                    && longRegistry.records[0].text == text && longRegistry.records[0].id.page == 7,
                      "Boundary \(count): splitting changed canonical evidence text or page locator")
                do {
                    _ = try AIEmbeddingChunk.make(registry: longRegistry, tokenizer: tokenizer, maximumChunks: split.count - 1)
                    check(false, "Boundary \(count): subchunks escaped the index budget")
                } catch { check(error as? AIRetrievalError == .indexTooLarge, "Boundary \(count): wrong chunk-budget failure") }
            }
            // Over 100 matching subchunks of one sentence must leave room for another
            // sentence in both the local RRF pool and cross-file cosine candidate pool.
            let repeatedChunks = (0..<110).map { _ in AIEmbeddingChunk(ids: [ids[0]], tokens: [200]) }
                + [AIEmbeddingChunk(ids: [ids[1]], tokens: [201])]
            let repeatedRetriever = try AIHybridEvidenceRetriever(registry: registry, embedder: FixtureQueryEmbedder(),
                chunks: repeatedChunks, vectors: (0..<110).map { _ in [Float(1), 0] } + [[0.8, 0.6]])
            let noLexicalMatch = AISegmentSearchRequest(query: "zxq-unmatched", topK: 2)
            let uniqueDense = try await repeatedRetriever.denseCandidates(noLexicalMatch)
            check(uniqueDense.map(\.id) == [ids[0], ids[1]], "Split sentence crowded other evidence out of dense top-K")
            let uniqueHybrid = try await repeatedRetriever.search(noLexicalMatch)
            check(uniqueHybrid.map(\.id) == [ids[0], ids[1]], "Split sentence crowded other evidence out of local fusion")
            let negativeRetriever = try AIHybridEvidenceRetriever(registry: registry, embedder: FixtureQueryEmbedder(),
                chunks: [AIEmbeddingChunk(ids: [ids[0]], tokens: [200]), AIEmbeddingChunk(ids: [ids[0]], tokens: [201])],
                vectors: [[-0.8, 0.6], [-0.6, 0.8]])
            let negativeDense = try await negativeRetriever.denseCandidates(noLexicalMatch)
            check(abs((negativeDense.first?.score ?? 0) + 0.6) < 0.00001,
                  "Split segment score must preserve the best negative cosine rather than zero or a sum")
            let descriptor = try AIEmbeddingCacheDescriptor(
                registry: registry,
                packageID: "model-a",
                dimensions: 2,
                chunks: chunks
            )
            let other = try AIEmbeddingCacheDescriptor(
                registry: registry,
                packageID: "model-b",
                dimensions: 2,
                chunks: chunks
            )
            check(descriptor.identity != other.identity, "Different models shared an index key")
            check(descriptor.matches(chunks: chunks), "Valid dense generation descriptor rejected")
            check(
                !descriptor.matches(chunks: chunks + [chunks[0]]),
                "Changed dense chunk input reused an index key"
            )
            let cancellation = Task { () throws -> [AISegmentSearchResult] in
                try await Task.sleep(for: .seconds(1)); return try await lexical.search(query)
            }
            cancellation.cancel()
            do { _ = try await cancellation.value; check(false, "Cancelled search ran") }
            catch { check(error is CancellationError, "Cancellation was hidden") }

            if let path = ProcessInfo.processInfo.environment["DOGEAR_RAG_MODEL_PACKAGE"] {
                let root: URL
                if path == "installed" {
                    guard let id = UserDefaults.standard.string(forKey: AIRetrievalSelection.packageDefaultsKey) else {
                        throw AIRetrievalError.modelMissing
                    }
                    root = try AILocalEmbeddingModels.packageURL(id)
                } else {
                    root = URL(fileURLWithPath: path, isDirectory: true)
                }
                let (_, packageID) = try AILocalEmbeddingModels.validatePackage(at: root)
                let embedder = try AICoreMLEmbedder(packageURL: root, packageID: packageID)
                let fixtures = try JSONDecoder().decode([Parity].self, from: Data(contentsOf: root.appendingPathComponent("parity.json")))
                for (index, fixture) in fixtures.enumerated() {
                    let tokens = Array(embedder.tokenizer.tokens(fixture.text).prefix(510))
                    check([101] + tokens + [102] == fixture.ids, "Upstream tokenizer parity failed at sample \(index)")
                    let vector = try await embedder.embed(tokens: tokens)
                    let dot = zip(vector, fixture.embedding).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                    check(dot.isFinite && dot > 0.999, "Swift Core ML parity failed at sample \(index)")
                }
                let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DogearRAGTests-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: cacheRoot) }
                let selection = AIRetrievalSelection(mode: .scheme2EvidenceRAG, packageID: packageID)
                let started = ContinuousClock.now
                let retriever = try await AIEvidenceRetrievalFactory.make(selection: selection, registry: registry, packageURL: root, cacheRoot: cacheRoot)
                let built = ContinuousClock.now
                let results = try await retriever.search(AISegmentSearchRequest(query: "How are handwritten symbols classified?", topK: 2))
                check(results.first?.id.page == 1, "English paraphrase did not retrieve architecture evidence")
                let scoped = try await retriever.search(AISegmentSearchRequest(query: "neural network", scope: AISegmentScope(pageRange: 2...2), topK: 100))
                check(!scoped.isEmpty && scoped.allSatisfy { $0.id.page == 2 }, "Semantic search escaped page scope")
                let overview = try await retriever.search(AISegmentSearchRequest(query: "", topK: 3, strategy: .overviewSalience))
                check(Set(overview.map { $0.id.page }).count == 3, "Overview lost page diversity")
                let cached = try await AIEvidenceRetrievalFactory.make(selection: selection, registry: registry, packageURL: root, cacheRoot: cacheRoot)
                let repeated = try await cached.search(AISegmentSearchRequest(query: "How are handwritten symbols classified?", topK: 2))
                check(repeated == results, "Cached index changed ranking")
                let database = AISQLiteEmbeddingIndexCache.databaseURL(cacheRoot: cacheRoot)
                check(FileManager.default.fileExists(atPath: database.path), "Dense SQLite cache was not created")
                let mode = try FileManager.default.attributesOfItem(atPath: database.path)[.posixPermissions] as? NSNumber
                check(mode?.intValue == 0o600, "Dense SQLite cache is not private")
                print("RAG REAL MODEL: build \(started.duration(to: built)); total \(started.duration(to: .now)); \(registry.records.count) segments")
            }
        } catch { check(false, "Retrieval diagnostics failed: \(error)") }
        return Report(checks: checks, failures: failures)
    }

    private struct FixtureRetriever: AIEvidenceRetrieving {
        let id: AISegmentID
        func search(_ request: AISegmentSearchRequest) async throws -> [AISegmentSearchResult] {
            [AISegmentSearchResult(id: id, score: 1)]
        }
    }
    private struct FixtureQueryEmbedder: AIQueryEmbedding {
        func embedQuery(_ text: String) async throws -> [Float] { [1, 0] }
    }
    private struct FixtureTextEmbedder: AITextEmbedding {
        let tokenizer: AIBertWordPieceTokenizer
        func embed(tokens: [Int32]) async throws -> [Float] { Self.vector }
        func embedQuery(_ text: String) async throws -> [Float] { Self.vector }
        private static let vector: [Float] = [1] + Array(repeating: 0, count: 383)
    }
    private struct RejectingTextEmbedder: AITextEmbedding {
        let tokenizer: AIBertWordPieceTokenizer
        func embed(tokens: [Int32]) async throws -> [Float] {
            throw AIRetrievalError.invalidVector
        }
        func embedQuery(_ text: String) async throws -> [Float] {
            throw AIRetrievalError.invalidVector
        }
    }
    private actor CountingLexicalBackend: AILexicalIndexBackend {
        private(set) var prepareCallCount = 0
        func prepare(sources: [AILexicalIndexSource]) async throws -> AILexicalPreparedIndex {
            prepareCallCount += 1
            return try await AIInMemoryBM25IndexBackend().prepare(sources: sources)
        }
    }
    private struct Parity: Decodable {
        let text: String
        let ids: [Int32]
        let embedding: [Float]
    }
}
