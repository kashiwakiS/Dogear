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
            let lexical = AILexicalEvidenceRetriever(registry: registry)
            let query = AISegmentSearchRequest(query: "convolutional", topK: 2)
            let original = AISimpleLexicalSearcher().search(query, in: registry)
            let wrapped = try await lexical.search(query)
            check(original == wrapped, "Scheme 1 wrapper changed results")
            let ids = registry.records.map(\.id)
            let fused = AIHybridEvidenceRetriever.fuse(lexical: [ids[0], ids[1], ids[0]], dense: [ids[1], ids[2]])
            check(fused.first?.id == ids[1], "RRF should prefer shared evidence")
            check(Set(fused.map(\.id)).count == fused.count, "RRF duplicated IDs")
            check(abs((fused.first?.score ?? 0) - (1.0 / 61 + 1.0 / 62)) < 0.000001, "RRF added incompatible raw scores")
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
            let chunks = try AIEmbeddingChunk.make(registry: registry, tokenizer: tokenizer)
            check(chunks.flatMap(\.ids) == ids, "Chunking dropped or reordered sentence IDs")
            check(chunks.allSatisfy { Set($0.ids.map(\.page)).count == 1 }, "Chunk crosses a page")
            let key = try AIEmbeddingIndexCache.key(registry: registry, packageID: "model-a", chunks: chunks)
            let other = try AIEmbeddingIndexCache.key(registry: registry, packageID: "model-b", chunks: chunks)
            check(key != other, "Different models shared an index key")
            let valid = AIEmbeddingIndexCache(key: key, ids: chunks.map(\.ids), vectors: chunks.map { _ in [1,0] })
            check(valid.isValid(key: key, chunks: chunks, dimensions: 2), "Valid cache rejected")
            check(!valid.isValid(key: other, chunks: chunks, dimensions: 2), "Stale cache accepted")
            check(!valid.isValid(key: key, chunks: chunks, dimensions: 384), "Wrong vector dimension accepted")
            let invalid = AIEmbeddingIndexCache(key: key, ids: chunks.map(\.ids), vectors: chunks.map { _ in [.nan,0] })
            check(!invalid.isValid(key: key, chunks: chunks, dimensions: 2), "NaN cache accepted")
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
                let cacheFiles = try FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)
                check(cacheFiles.count == 1, "Index cache left partial/duplicate files")
                if let file = cacheFiles.first {
                    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
                    check(mode?.intValue == 0o600, "Index file is not private")
                }
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
    private struct Parity: Decodable {
        let text: String
        let ids: [Int32]
        let embedding: [Float]
    }
}
