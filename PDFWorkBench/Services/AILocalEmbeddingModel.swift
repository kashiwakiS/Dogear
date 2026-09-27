import CoreML
import Foundation

nonisolated struct AIEmbeddingManifest: Codable, Sendable {
    let schema: Int
    let model: String
    let revision: String
    let dimensions: Int
    let maximumTokens: Int
    let tokenizer: String
    let pooling: String
    let precision: String
    let queryPrefix: String
    let files: [String: String]

    func validate() throws {
        guard schema == 1, model == "BAAI/bge-small-en-v1.5",
              revision == "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a",
              dimensions == 384, maximumTokens == 512,
              tokenizer == AIBertWordPieceTokenizer.version, pooling == "cls-l2", precision == "float16",
              queryPrefix == "Represent this sentence for searching relevant passages: ",
              files["vocab.txt"] != nil, files.keys.contains(where: { $0.hasPrefix("embedding.mlmodelc/") }),
              files.count < 100 else { throw AIRetrievalError.invalidModel }
    }
}

/// No downloader in the app. Users explicitly import a developer-converted package.
/// Content hashes detect corruption; they are not a publisher signature.
actor AILocalEmbeddingModels {
    static let shared = AILocalEmbeddingModels()
    nonisolated static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFWorkBench/EvidenceRAG", isDirectory: true)
    }

    nonisolated static func packageURL(_ id: String) throws -> URL {
        guard id.count == 64, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw AIRetrievalError.invalidSelection
        }
        return root.appendingPathComponent("Models/\(id)", isDirectory: true)
    }

    func install(from source: URL) async throws -> String {
        let (manifest, id) = try Self.validatePackage(at: source)
        let destination = try Self.packageURL(id)
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        if manager.fileExists(atPath: destination.path) {
            _ = try Self.validatePackage(at: destination, expectedID: id)
            return id
        }
        let temporary = parent.appendingPathComponent("import-\(UUID().uuidString)")
        defer { if manager.fileExists(atPath: temporary.path) { try? manager.removeItem(at: temporary) } }
        try Self.copyPackage(from: source, manifest: manifest, to: temporary)
        // Validate the copied bytes too: a source can change during import.
        _ = try Self.validatePackage(at: temporary, expectedID: id)
        let smokeModel = try AICoreMLEmbedder(packageURL: temporary, packageID: id)
        _ = try await smokeModel.embedQuery("document evidence")
        try Self.restrictPermissions(at: temporary)
        try Task.checkCancellation()
        if manager.fileExists(atPath: destination.path) {
            _ = try Self.validatePackage(at: destination, expectedID: id)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
        return id
    }

    /// Copy only verified assets. Finder may add .DS_Store while the user browses
    /// a package; that metadata is neither model input nor part of its identity.
    nonisolated static func copyPackage(from source: URL, manifest: AIEmbeddingManifest, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        for path in ["manifest.json"] + manifest.files.keys.sorted() {
            try Task.checkCancellation()
            let target = destination.appendingPathComponent(path)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.copyItem(at: source.appendingPathComponent(path), to: target)
        }
    }

    private nonisolated static func restrictPermissions(at root: URL) throws {
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        if let entries = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in entries {
                let directory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                try manager.setAttributes([.posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: url.path)
            }
        }
    }

    nonisolated static func validatePackage(at root: URL, expectedID: String? = nil) throws -> (AIEmbeddingManifest, String) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { throw AIRetrievalError.modelMissing }
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw AIRetrievalError.invalidModel
        }
        let manifestURL = root.appendingPathComponent("manifest.json")
        let size = try manifestURL.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard size.isSymbolicLink != true, (size.fileSize ?? Int.max) < 100_000 else {
            throw AIRetrievalError.invalidModel
        }
        let data = try Data(contentsOf: manifestURL)
        let id = AIRetrievalHash.data(data)
        if let expectedID, id != expectedID { throw AIRetrievalError.invalidModel }
        let manifest = try JSONDecoder().decode(AIEmbeddingManifest.self, from: data)
        try manifest.validate()
        var actualFiles = Set<String>()
        var total = 0
        guard let entries = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
            throw AIRetrievalError.invalidModel
        }
        for case let url as URL in entries {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw AIRetrievalError.invalidModel }
            guard values.isRegularFile == true else { continue }
            if url.lastPathComponent == ".DS_Store" { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if relative == "manifest.json" { continue }
            total += values.fileSize ?? 0
            guard total <= 300_000_000, let hash = manifest.files[relative],
                  hash.count == 64, try AIRetrievalHash.file(url) == hash else { throw AIRetrievalError.invalidModel }
            actualFiles.insert(relative)
        }
        guard actualFiles == Set(manifest.files.keys) else { throw AIRetrievalError.invalidModel }
        return (manifest, id)
    }
}

actor AICoreMLEmbedder: AITextEmbedding {
    let manifest: AIEmbeddingManifest
    let tokenizer: AIBertWordPieceTokenizer
    private let model: MLModel

    init(packageURL: URL, packageID: String) throws {
        let (manifest, _) = try AILocalEmbeddingModels.validatePackage(at: packageURL, expectedID: packageID)
        self.manifest = manifest
        tokenizer = try AIBertWordPieceTokenizer(vocabulary: String(contentsOf: packageURL.appendingPathComponent("vocab.txt"), encoding: .utf8))
        let configuration = MLModelConfiguration()
        // Explicit CPU baseline first; device/ANE tuning needs separate measurements.
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: packageURL.appendingPathComponent("embedding.mlmodelc"), configuration: configuration)
    }

    func embedQuery(_ text: String) throws -> [Float] {
        try embed(tokens: tokenizer.tokens(manifest.queryPrefix + text))
    }

    func embed(tokens: [Int32]) throws -> [Float] {
        try Task.checkCancellation()
        guard tokens.count + 2 <= manifest.maximumTokens else { throw AIRetrievalError.inputTooLong }
        let values: [Int32] = [101] + tokens + [102]
        let ids = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
        for index in values.indices { ids[index] = NSNumber(value: values[index]); mask[index] = 1 }
        let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "attention_mask": mask])
        let output = try model.prediction(from: input)
        try Task.checkCancellation()
        guard let array = output.featureValue(for: "embedding")?.multiArrayValue,
              array.count == manifest.dimensions else { throw AIRetrievalError.invalidVector }
        let vector = (0..<array.count).map { array[$0].floatValue }
        guard vector.allSatisfy(\.isFinite) else { throw AIRetrievalError.invalidVector }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0.0001 else { throw AIRetrievalError.invalidVector }
        return vector.map { $0 / norm }
    }
}

nonisolated enum AIEvidenceRetrievalFactory {
    static func makeSources(
        selection: AIRetrievalSelection,
        registry: AISegmentRegistry,
        progress: (@Sendable (Int, Int) async -> Void)? = nil,
        indexed: (@Sendable (Int, Bool, Double) async -> Void)? = nil,
        sharedEmbedder: (any AITextEmbedding)? = nil,
        cacheRoot: URL? = nil,
        maximumRequestChunks: Int = 20_000,
        lexicalBackend: (any AILexicalIndexBackend)? = nil,
        lexicalPreparationBudget: Duration = .seconds(180)
    ) async throws -> AIMultiSourceRetrievalPreparation {
        // Memory remains the Scheme 1 product default until representative
        // local libraries establish a material warm benefit. Scheme 2 never
        // constructs or prepares a lexical backend.
        let lexicalIndexBackend: (any AILexicalIndexBackend)?
        let embeddingCache: AISQLiteEmbeddingIndexCache?
        let started = ContinuousClock.now
        if selection.mode == .scheme1Lexical {
            lexicalIndexBackend = lexicalBackend ?? AISharedMemoryBM25IndexBackend.shared
            embeddingCache = nil
        } else {
            lexicalIndexBackend = nil
            embeddingCache = AISQLiteEmbeddingIndexCache(
                databaseURL: AISQLiteEmbeddingIndexCache.databaseURL(cacheRoot: cacheRoot)
            )
        }
        if registry.sources.isEmpty {
            let lexicalPrepared: AILexicalPreparedIndex?
            if let lexicalIndexBackend {
                let lexicalSource = singleRegistryLexicalSource(registry)
                try checkLexicalPreparationStatus(
                    started: started,
                    preparationBudget: lexicalPreparationBudget
                )
                let prepared = try await lexicalIndexBackend.prepare(
                    source: lexicalSource
                )
                try checkLexicalPreparationStatus(
                    started: started,
                    preparationBudget: lexicalPreparationBudget
                )
                _ = try validateLexicalPreparedIndex(
                    prepared,
                    sources: [lexicalSource]
                )
                lexicalPrepared = prepared
            } else {
                lexicalPrepared = nil
            }
            if registry.records.isEmpty {
                let retriever: any AIEvidenceRetrieving
                if let lexicalPrepared {
                    retriever = try AILexicalEvidenceRetriever(
                        registry: registry,
                        preparedIndex: lexicalPrepared.bm25
                    )
                } else {
                    // No authorized text means there is no dense work to do.
                    // Return an empty Scheme 2 adapter without loading a model,
                    // writing a vector cache, or embedding the later query.
                    retriever = try AIMultiSourceEvidenceRetriever(
                        sources: [],
                        mode: .scheme2EvidenceRAG,
                        registry: registry
                    )
                }
                return AIMultiSourceRetrievalPreparation(
                    retriever: retriever,
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
                lexicalPreparedIndex: lexicalPrepared?.bm25,
                embeddingCache: embeddingCache
            )
            return AIMultiSourceRetrievalPreparation(
                retriever: retriever,
                coverage: AIMultiSourceCoverage()
            )
        }
        if registry.records.isEmpty {
            let retriever: any AIEvidenceRetrieving
            if let lexicalIndexBackend {
                try checkLexicalPreparationStatus(
                    started: started,
                    preparationBudget: lexicalPreparationBudget
                )
                let lexicalPrepared = try await lexicalIndexBackend.prepare(sources: [])
                try checkLexicalPreparationStatus(
                    started: started,
                    preparationBudget: lexicalPreparationBudget
                )
                _ = try validateLexicalPreparedIndex(lexicalPrepared, sources: [])
                retriever = try AILexicalEvidenceRetriever(
                    registry: registry,
                    preparedIndex: lexicalPrepared.bm25
                )
            } else {
                retriever = try AIMultiSourceEvidenceRetriever(
                    sources: [],
                    mode: .scheme2EvidenceRAG,
                    registry: registry
                )
            }
            return AIMultiSourceRetrievalPreparation(retriever: retriever,
                coverage: AIMultiSourceCoverage(requestedCount: registry.sources.count, preparedFileIDs: [],
                    skipped: registry.sources.map { .init(documentNumber: $0.documentNumber, fileID: $0.fileID,
                        reason: "No extractable text; no OCR was performed.") }, usedFileIDs: []))
        }
        if selection.mode == .scheme1Lexical {
            guard let lexicalIndexBackend else {
                throw AIRetrievalError.invalidSelection
            }
            return try await makeLexicalSources(
                registry: registry,
                backend: lexicalIndexBackend,
                started: started,
                preparationBudget: lexicalPreparationBudget
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
        let uuidText = [
            String(prefix.prefix(8)),
            String(prefix.dropFirst(8).prefix(4)),
            String(prefix.dropFirst(12).prefix(4)),
            String(prefix.dropFirst(16).prefix(4)),
            String(prefix.dropFirst(20).prefix(12))
        ].joined(separator: "-")
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

/// Retain at most one loaded, hash-validated model; immutable request actors keep
/// their reference when a user switches the configured package.
actor AIEmbeddingModelPool {
    static let shared = AIEmbeddingModelPool()
    private var retained: (key: String, model: AICoreMLEmbedder)?
    func model(packageURL: URL, packageID: String) throws -> AICoreMLEmbedder {
        try Task.checkCancellation()
        let key = packageURL.standardizedFileURL.path + "|" + packageID
        if let retained, retained.key == key { return retained.model }
        let model = try AICoreMLEmbedder(packageURL: packageURL, packageID: packageID)
        retained = (key, model)
        return model
    }
}
