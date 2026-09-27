import Foundation
import SQLite3

nonisolated enum AIDenseEmbeddingCacheDiagnostics {
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

        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "DogearDenseSQLiteDiagnostics-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? manager.removeItem(at: root) }

        do {
            let defaultDatabase = AISQLiteEmbeddingIndexCache.databaseURL()
            check(
                defaultDatabase.lastPathComponent == "embeddings-v1.sqlite3"
                    && defaultDatabase.deletingLastPathComponent().lastPathComponent == "Dense",
                "Dense vectors did not use their own physical SQLite database."
            )

            let codecFixture: [Float] = [1, -2, 0.5, -0.25]
            let encoded = AIEmbeddingVectorBlobCodec.encode(codecFixture)
            check(
                Array(encoded.prefix(8)) == [0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x00, 0xc0],
                "Dense vector BLOB is not explicit little-endian IEEE Float32."
            )
            let decoded = try AIEmbeddingVectorBlobCodec.decode(
                encoded,
                dimensions: codecFixture.count
            )
            check(
                zip(decoded, codecFixture).allSatisfy { $0.bitPattern == $1.bitPattern },
                "Dense Float32 BLOB round trip changed vector bits."
            )
            do {
                _ = try AIEmbeddingVectorBlobCodec.decode(encoded.dropLast(), dimensions: 4)
                check(false, "A truncated dense vector BLOB was accepted.")
            } catch {
                check(true, "A truncated dense vector BLOB was rejected.")
            }

            let sourceID = UUID(uuidString: "00000000-0000-0000-0000-00000000D301")!
            let snapshot = AIHighlightTextSnapshot(
                fingerprint: "dense-cache-snapshot-v1",
                pages: [AITextPageSnapshot(
                    pageNumber: 1,
                    text: "Alpha evidence is first. Beta evidence is second.",
                    fingerprint: "dense-cache-page-v1"
                )]
            )
            let combined = try AISegmentRegistry(sources: [AIWorkflowSourceSnapshot(
                fileID: sourceID,
                displayName: "dense-cache.pdf",
                snapshot: snapshot,
                version: "content-version-with-annotation-state"
            )])
            let registry = combined.registry(forDocument: 1, canonicalIDs: true)
            let ids = registry.records.map(\.id)
            guard ids.count >= 2 else {
                throw AIRetrievalError.invalidModel
            }
            let chunks = [
                AIEmbeddingChunk(ids: [ids[0]], tokens: [101, 201, 102]),
                AIEmbeddingChunk(ids: [ids[1]], tokens: [101, 202, 102])
            ]
            let vectors: [[Float]] = [
                [1, 0, 0, 0],
                [0, 1, 0, 0]
            ]
            let packageID = String(repeating: "a", count: 64)
            let descriptor = try AIEmbeddingCacheDescriptor(
                registry: registry,
                packageID: packageID,
                dimensions: 4,
                chunks: chunks
            )
            let modelChanged = try AIEmbeddingCacheDescriptor(
                registry: registry,
                packageID: String(repeating: "b", count: 64),
                dimensions: 4,
                chunks: chunks
            )
            let changedChunks = [
                AIEmbeddingChunk(ids: [ids[0]], tokens: [101, 999, 102]),
                chunks[1]
            ]
            let inputChanged = try AIEmbeddingCacheDescriptor(
                registry: registry,
                packageID: packageID,
                dimensions: 4,
                chunks: changedChunks
            )
            let anchorChanged = try AIEmbeddingCacheDescriptor(
                registry: registry,
                packageID: packageID,
                dimensions: 4,
                chunks: [
                    AIEmbeddingChunk(
                        anchorID: ids[1],
                        ids: chunks[0].ids,
                        tokens: chunks[0].tokens
                    ),
                    chunks[1]
                ]
            )
            check(descriptor.identity != modelChanged.identity, "Dense generations ignored model identity.")
            check(descriptor.identity != inputChanged.identity, "Dense generations ignored chunk/token input.")
            check(descriptor.identity != anchorChanged.identity, "Dense generations ignored window anchor mapping.")
            check(
                descriptor.segmenterVersion.contains(AIRetrievalWindow.profile)
                    && AIEmbeddingCacheDescriptor.chunkProfile.contains(AIRetrievalWindow.profile),
                "Dense generation identity omitted the retrieval-window profile."
            )

            let initializationRoot = root.appendingPathComponent("initialization-retry")
            let initializationURL = AISQLiteEmbeddingIndexCache.databaseURL(
                cacheRoot: initializationRoot
            )
            let failedInitialization = AISQLiteEmbeddingIndexCache(
                databaseURL: initializationURL,
                diagnosticFault: .duringInitialization
            )
            check(
                try await failedInitialization.loadBestEffort(
                    descriptor: descriptor,
                    chunks: chunks
                ) == nil,
                "An injected first-open failure did not degrade to a dense cache miss."
            )
            await failedInitialization.close()
            check(
                ["", "-journal", "-wal", "-shm"].allSatisfy {
                    !manager.fileExists(atPath: initializationURL.path + $0)
                },
                "A failed first initialization left an unclaimable dense database or sidecar."
            )
            let initializationRetry = AISQLiteEmbeddingIndexCache(databaseURL: initializationURL)
            check(
                try await initializationRetry.storeBestEffort(
                    descriptor: descriptor,
                    chunks: chunks,
                    vectors: vectors
                ),
                "Dense cache initialization could not retry after its first-open failure."
            )
            await initializationRetry.close()

            let orphanRoot = root.appendingPathComponent("orphan-sidecar", isDirectory: true)
            try manager.createDirectory(at: orphanRoot, withIntermediateDirectories: true)
            let orphanURL = orphanRoot.appendingPathComponent("embeddings.sqlite3")
            let orphanWAL = URL(fileURLWithPath: orphanURL.path + "-wal")
            let orphanSentinel = Data("unknown-orphan-wal".utf8)
            try orphanSentinel.write(to: orphanWAL)
            try manager.setAttributes([.posixPermissions: 0o640], ofItemAtPath: orphanWAL.path)
            let orphanMode = try fileMode(orphanWAL)
            let orphanCache = AISQLiteEmbeddingIndexCache(databaseURL: orphanURL)
            let orphanLoad = try await orphanCache.loadBestEffort(
                descriptor: descriptor,
                chunks: chunks
            )
            await orphanCache.close()
            let orphanBytesAfter = try Data(contentsOf: orphanWAL)
            let orphanModeAfter = try fileMode(orphanWAL)
            check(
                orphanLoad == nil
                    && !manager.fileExists(atPath: orphanURL.path)
                    && orphanBytesAfter == orphanSentinel
                    && orphanModeAfter == orphanMode,
                "An orphan dense sidecar was deleted, rewritten, or chmodded."
            )

            for fixture in ["foreign-nonempty", "foreign-empty"] {
                let foreignRoot = root.appendingPathComponent(fixture, isDirectory: true)
                try manager.createDirectory(at: foreignRoot, withIntermediateDirectories: true)
                let foreignURL = foreignRoot.appendingPathComponent("embeddings.sqlite3")
                try executeSQLite(
                    at: foreignURL,
                    sql: fixture == "foreign-nonempty"
                        ? "CREATE TABLE foreign_data(value TEXT)"
                        : "VACUUM"
                )
                try manager.setAttributes([.posixPermissions: 0o640], ofItemAtPath: foreignURL.path)
                let beforeBytes = try Data(contentsOf: foreignURL)
                let beforeMode = try fileMode(foreignURL)
                let foreign = AISQLiteEmbeddingIndexCache(databaseURL: foreignURL)
                let loaded = try await foreign.loadBestEffort(
                    descriptor: descriptor,
                    chunks: chunks
                )
                await foreign.close()
                let afterBytes = try Data(contentsOf: foreignURL)
                let afterMode = try fileMode(foreignURL)
                let afterApplicationID = try sqliteScalar(
                    at: foreignURL,
                    sql: "PRAGMA application_id"
                )
                check(
                    loaded == nil
                        && afterBytes == beforeBytes
                        && afterMode == beforeMode
                        && afterApplicationID == 0,
                    "A \(fixture) SQLite file was claimed, rewritten, or chmodded by the dense cache."
                )
            }

            let linkRoot = root.appendingPathComponent("foreign-symlink", isDirectory: true)
            try manager.createDirectory(at: linkRoot, withIntermediateDirectories: true)
            let linkTarget = linkRoot.appendingPathComponent("target.sqlite3")
            try executeSQLite(at: linkTarget, sql: "CREATE TABLE foreign_data(value TEXT)")
            try manager.setAttributes([.posixPermissions: 0o640], ofItemAtPath: linkTarget.path)
            let targetBytes = try Data(contentsOf: linkTarget)
            let targetMode = try fileMode(linkTarget)
            let linkURL = linkRoot.appendingPathComponent("embeddings.sqlite3")
            try manager.createSymbolicLink(at: linkURL, withDestinationURL: linkTarget)
            let linked = AISQLiteEmbeddingIndexCache(databaseURL: linkURL)
            let linkedLoad = try await linked.loadBestEffort(
                descriptor: descriptor,
                chunks: chunks
            )
            await linked.close()
            let linkValues = try linkURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            let targetBytesAfter = try Data(contentsOf: linkTarget)
            let targetModeAfter = try fileMode(linkTarget)
            check(
                linkedLoad == nil
                    && linkValues.isSymbolicLink == true
                    && targetBytesAfter == targetBytes
                    && targetModeAfter == targetMode,
                "A dense-cache symlink target was followed, rewritten, or chmodded."
            )

            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            let legacyJSON = root.appendingPathComponent("\(descriptor.identity).json")
            try Data("legacy-json-must-not-be-read".utf8).write(to: legacyJSON)
            let databaseURL = AISQLiteEmbeddingIndexCache.databaseURL(cacheRoot: root)
            let cache = AISQLiteEmbeddingIndexCache(databaseURL: databaseURL)
            check(
                try await cache.loadBestEffort(descriptor: descriptor, chunks: chunks) == nil,
                "A legacy JSON artifact was treated as a SQLite cache hit."
            )
            check(
                try await cache.storeBestEffort(
                    descriptor: descriptor,
                    chunks: chunks,
                    vectors: vectors
                ),
                "A valid dense generation was not stored."
            )
            check(
                try await cache.loadBestEffort(descriptor: descriptor, chunks: chunks) == vectors,
                "Same-process dense cache hit changed Float32 vectors."
            )
            let counts = try await cache.diagnosticRowCounts()
            check(
                counts.generations == 1 && counts.chunks == 2 && counts.mappings == 2,
                "Dense generation/chunk/chunk-segment rows were incomplete."
            )
            let permissions = try manager.attributesOfItem(atPath: databaseURL.path)[.posixPermissions] as? NSNumber
            check(permissions?.intValue == 0o600, "Dense SQLite database permissions were not 0600.")
            let sidecarsArePrivate = ["-wal", "-shm"].allSatisfy { suffix in
                let path = databaseURL.path + suffix
                guard manager.fileExists(atPath: path) else { return true }
                let attributes = try? manager.attributesOfItem(atPath: path)
                let mode = attributes?[.posixPermissions] as? NSNumber
                return mode?.intValue == 0o600
            }
            check(sidecarsArePrivate, "Dense SQLite WAL/SHM permissions were not 0600.")
            check(manager.fileExists(atPath: legacyJSON.path), "Legacy JSON was destructively removed.")
            await cache.close()

            let reopened = AISQLiteEmbeddingIndexCache(databaseURL: databaseURL)
            let reopenedVectors = try await reopened.loadBestEffort(
                descriptor: descriptor,
                chunks: chunks
            )
            check(reopenedVectors == vectors, "Restarted dense cache changed Float32 vectors.")
            if let reopenedVectors {
                let before = try AIHybridEvidenceRetriever(
                    registry: registry,
                    embedder: FixtureQueryEmbedder(),
                    chunks: chunks,
                    vectors: vectors
                )
                let after = try AIHybridEvidenceRetriever(
                    registry: registry,
                    embedder: FixtureQueryEmbedder(),
                    chunks: chunks,
                    vectors: reopenedVectors
                )
                let request = AISegmentSearchRequest(query: "alpha", topK: 2)
                check(
                    try await before.search(request) == after.search(request),
                    "SQLite persistence changed exact dense cosine ranking."
                )
            } else {
                check(false, "Restarted dense cache unexpectedly missed.")
            }
            await reopened.close()

            let replacementVectors: [[Float]] = [
                [0, 1, 0, 0],
                [1, 0, 0, 0]
            ]
            for fault in [
                AISQLiteEmbeddingCacheDiagnosticFault.afterGeneration,
                .afterFirstChunk,
                .afterFirstMapping,
                .beforeCommit
            ] {
                let faulty = AISQLiteEmbeddingIndexCache(
                    databaseURL: databaseURL,
                    diagnosticFault: fault
                )
                check(
                    !(try await faulty.storeBestEffort(
                        descriptor: descriptor,
                        chunks: chunks,
                        vectors: replacementVectors
                    )),
                    "Injected dense transaction failure \(fault) was reported as persisted."
                )
                await faulty.close()
                let verification = AISQLiteEmbeddingIndexCache(databaseURL: databaseURL)
                check(
                    try await verification.loadBestEffort(
                        descriptor: descriptor,
                        chunks: chunks
                    ) == vectors,
                    "Dense failure \(fault) exposed a partial replacement."
                )
                let rollbackCounts = try await verification.diagnosticRowCounts()
                check(
                    rollbackCounts.generations == 1
                        && rollbackCounts.chunks == 2
                        && rollbackCounts.mappings == 2,
                    "Dense failure \(fault) left partial generation rows."
                )
                await verification.close()
            }

            let cancelledStore = AISQLiteEmbeddingIndexCache(
                databaseURL: databaseURL,
                diagnosticFault: .cancellationBeforeCommit
            )
            do {
                _ = try await cancelledStore.storeBestEffort(
                    descriptor: descriptor,
                    chunks: chunks,
                    vectors: replacementVectors
                )
                check(false, "Injected dense cancellation completed as a successful store.")
            } catch is CancellationError {
                check(true, "")
            } catch {
                check(false, "Dense cancellation did not propagate CancellationError.")
            }
            await cancelledStore.close()
            let cancellationVerification = AISQLiteEmbeddingIndexCache(databaseURL: databaseURL)
            check(
                try await cancellationVerification.loadBestEffort(
                    descriptor: descriptor,
                    chunks: chunks
                ) == vectors,
                "Cancelled dense transaction exposed a partial replacement."
            )
            let cancellationCounts = try await cancellationVerification.diagnosticRowCounts()
            check(
                cancellationCounts.generations == 1
                    && cancellationCounts.chunks == 2
                    && cancellationCounts.mappings == 2,
                "Cancelled dense transaction left partial generation rows."
            )
            await cancellationVerification.close()

            let afterRollback = AISQLiteEmbeddingIndexCache(databaseURL: databaseURL)
            check(
                !(try await afterRollback.storeBestEffort(
                    descriptor: descriptor,
                    chunks: chunks,
                    vectors: [[.nan, 0, 0, 0], vectors[1]]
                )),
                "A non-finite dense vector was persisted."
            )
            check(
                try await afterRollback.loadBestEffort(
                    descriptor: descriptor,
                    chunks: chunks
                ) == vectors,
                "Rejected dense vectors damaged the prior generation."
            )

            check(
                try await afterRollback.storeBestEffort(
                    descriptor: inputChanged,
                    chunks: changedChunks,
                    vectors: replacementVectors
                ),
                "Updated dense source generation was not stored."
            )
            let replacementCounts = try await afterRollback.diagnosticRowCounts()
            check(
                replacementCounts.generations == 1
                    && replacementCounts.chunks == 2
                    && replacementCounts.mappings == 2,
                "Source-local dense generation replacement retained stale rows."
            )
            check(
                try await afterRollback.loadBestEffort(
                    descriptor: descriptor,
                    chunks: chunks
                ) == nil,
                "Superseded dense generation remained queryable."
            )
            check(
                try await afterRollback.loadBestEffort(
                    descriptor: inputChanged,
                    chunks: changedChunks
                ) == replacementVectors,
                "Updated dense generation did not survive source-local replacement."
            )
            await afterRollback.close()

            // A corrupt derived database must become a miss, not a retrieval
            // error. It is left in place because an unowned file is never
            // deleted merely because its contents are unreadable.
            try? manager.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
            try? manager.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-shm"))
            try Data("not-a-sqlite-database".utf8).write(to: databaseURL, options: .atomic)
            let corrupt = AISQLiteEmbeddingIndexCache(databaseURL: databaseURL)
            check(
                try await corrupt.loadBestEffort(
                    descriptor: inputChanged,
                    chunks: changedChunks
                ) == nil,
                "Corrupt dense SQLite database did not fall back to a cache miss."
            )
            await corrupt.close()

            let factoryRoot = manager.temporaryDirectory.appendingPathComponent(
                "DogearDenseSQLiteFactory-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? manager.removeItem(at: factoryRoot) }
            let tokenizer = try fixtureTokenizer()
            let embedder = CountingTextEmbedder(tokenizer: tokenizer)
            let selection = AIRetrievalSelection(
                mode: .scheme2EvidenceRAG,
                packageID: String(repeating: "c", count: 64)
            )
            let cold = try await AIEvidenceRetrievalFactory.make(
                selection: selection,
                registry: registry,
                cacheRoot: factoryRoot,
                sharedEmbedder: embedder
            )
            let coldCount = await embedder.documentEmbeddingCount
            let coldRanking = try await cold.search(
                AISegmentSearchRequest(query: "alpha evidence", topK: 2)
            )
            let warm = try await AIEvidenceRetrievalFactory.make(
                selection: selection,
                registry: registry,
                cacheRoot: factoryRoot,
                sharedEmbedder: embedder
            )
            let warmCount = await embedder.documentEmbeddingCount
            let warmRanking = try await warm.search(
                AISegmentSearchRequest(query: "alpha evidence", topK: 2)
            )
            check(coldCount > 0 && warmCount == coldCount, "Warm SQLite hit recomputed document embeddings.")
            check(warmRanking == coldRanking, "Warm SQLite hit changed product dense ranking.")

            let blockedRoot = manager.temporaryDirectory.appendingPathComponent(
                "DogearDenseSQLiteBlocked-\(UUID().uuidString)"
            )
            defer { try? manager.removeItem(at: blockedRoot) }
            try Data("regular-file-blocks-cache-directory".utf8).write(to: blockedRoot)
            let fallbackEmbedder = CountingTextEmbedder(tokenizer: tokenizer)
            let fallback = try await AIEvidenceRetrievalFactory.make(
                selection: selection,
                registry: registry,
                cacheRoot: blockedRoot,
                sharedEmbedder: fallbackEmbedder
            )
            let fallbackRanking = try await fallback.search(
                AISegmentSearchRequest(query: "alpha evidence", topK: 2)
            )
            check(
                await fallbackEmbedder.documentEmbeddingCount > 0 && !fallbackRanking.isEmpty,
                "Unwritable dense cache discarded newly computed in-memory vectors."
            )
        } catch {
            check(false, "Dense SQLite diagnostics failed: \(error)")
        }

        return Report(checks: checks, failures: failures)
    }

    private static func fixtureTokenizer() throws -> AIBertWordPieceTokenizer {
        var words = (0..<30_522).map { "dense_reserved_\($0)" }
        for (index, word) in [
            (0, "[PAD]"), (100, "[UNK]"), (101, "[CLS]"),
            (102, "[SEP]"), (103, "[MASK]"), (200, "alpha"),
            (201, "evidence"), (202, "beta"), (203, "is"),
            (204, "first"), (205, "second"), (206, ".")
        ] {
            words[index] = word
        }
        return try AIBertWordPieceTokenizer(vocabulary: words.joined(separator: "\n"))
    }

    private static func executeSQLite(at url: URL, sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close_v2(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func sqliteScalar(at url: URL, sql: String) throws -> Int64 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
        return sqlite3_column_int64(statement, 0)
    }

    private static func fileMode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return permissions.intValue & 0o777
    }

    private struct FixtureQueryEmbedder: AIQueryEmbedding {
        func embedQuery(_ text: String) async throws -> [Float] {
            [1, 0, 0, 0]
        }
    }

    private actor CountingTextEmbedder: AITextEmbedding {
        nonisolated let tokenizer: AIBertWordPieceTokenizer
        private(set) var documentEmbeddingCount = 0

        init(tokenizer: AIBertWordPieceTokenizer) {
            self.tokenizer = tokenizer
        }

        func embed(tokens: [Int32]) async throws -> [Float] {
            documentEmbeddingCount += 1
            return [1] + Array(repeating: 0, count: 383)
        }

        func embedQuery(_ text: String) async throws -> [Float] {
            [1] + Array(repeating: 0, count: 383)
        }
    }
}
