import Foundation
import SQLite3
import Darwin

nonisolated enum AISQLiteBM25TransactionStage: String, CaseIterable, Sendable {
    case generation
    case segments
    case terms
    case termStatistics
    case postings
    case beforeCommit
}

nonisolated enum AISQLiteBM25DiagnosticFault: Equatable, Sendable {
    case failure(AISQLiteBM25TransactionStage)
    case cancellation(AISQLiteBM25TransactionStage)
    case storageFull(AISQLiteBM25TransactionStage)
    case warmLoadCancellation(AISQLiteBM25WarmLoadStage, afterRows: Int)
    case batchTouchCancellation(afterRows: Int)
    case batchTouchIdentityMismatch
    case initializationFailure(AISQLiteBM25InitializationStage)
    case initializationStorageFull(AISQLiteBM25InitializationStage)
    case cleanupFailure(AISQLiteBM25CleanupStage)
    case publishedTargetRemoval
}

nonisolated enum AISQLiteBM25WarmLoadStage: String, CaseIterable, Sendable {
    case segments
    case termStatistics
    case postings
}

nonisolated enum AISQLiteBM25InitializationStage: String, CaseIterable, Sendable {
    case temporaryFile
    case ownershipAttribute
    case sqliteInitialized
    case atomicPublish
}

nonisolated enum AISQLiteBM25CleanupStage: String, CaseIterable, Hashable, Sendable {
    case walRemoved
    case sharedMemoryRemoved
}

private enum AISQLiteBM25IndexError: Error {
    case sqlite(code: Int32, operation: String)
    case invalidDatabase
    case incompatibleDatabase
    case cacheValidation
    case symbolicLink
    case pathOutsideControlledRoot
    case missingOwnershipAttribute
    case unownedCache
    case injectedFailure
}

/// Basic-SQLite postings cache. The actor is the sole owner of its connection;
/// every returned index is detached `AIBM25IndexData` and scored by the same
/// Swift `AIBM25PreparedIndex` used by the memory backend.
actor AISQLiteBM25IndexBackend: AILexicalIndexBackend {
    private static let applicationID: Int32 = 0x444F4745 // "DOGE"
    private static let databaseUserVersion = 1
    private static let ownershipAttributeVersion = 1
    private static let ownershipAttributeName = "com.dogear.derived-lexical-cache"
    private static let requiredTables = [
        "index_metadata", "source_generation", "segment", "term",
        "source_term_stat", "posting"
    ]
    private static let requiredSourceTermIndex = "source_term_stat_by_term"

    nonisolated let storagePolicy: AILexicalIndexStoragePolicy
    private let tokenizer: AILexicalTokenizer
    private let parameters: AIBM25Parameters
    private let memoryBackend: AIInMemoryBM25IndexBackend
    private var database: OpaquePointer?
    private var diagnosticFault: AISQLiteBM25DiagnosticFault?
    private var completedBatchTouchTransactions = 0

    private struct CacheFileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private struct OwnershipAttribute {
        let nonce: UUID
    }

    init(
        storagePolicy: AILexicalIndexStoragePolicy,
        tokenizer: AILexicalTokenizer = AILexicalTokenizer(),
        parameters: AIBM25Parameters = .frozen,
        diagnosticFault: AISQLiteBM25DiagnosticFault? = nil
    ) {
        self.storagePolicy = storagePolicy
        self.tokenizer = tokenizer
        self.parameters = parameters
        self.memoryBackend = AIInMemoryBM25IndexBackend(tokenizer: tokenizer, parameters: parameters)
        self.diagnosticFault = diagnosticFault
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    func setDiagnosticFault(_ value: AISQLiteBM25DiagnosticFault?) {
        diagnosticFault = value
    }

    func close() {
        closeDatabase()
    }

    func diagnosticCompletedBatchTouchTransactionCount() -> Int {
        completedBatchTouchTransactions
    }

    func prepare(sources: [AILexicalIndexSource]) async throws -> AILexicalPreparedIndex {
        let started = Date()
        try AILexicalIndexSupport.validate(sources: sources, tokenizer: tokenizer)
        guard storagePolicy.persistenceEnabled, storagePolicy.databaseURL != nil else {
            return try await memoryFallback(
                sources: sources,
                reason: .persistenceDisabled,
                started: started
            )
        }

        do {
            try openIfNeeded()
            var values: [(documentNumber: Int, data: AIBM25IndexData)] = []
            var generationsToTouch: [GenerationTouchReference] = []
            var hits = 0
            var misses = 0
            let ordered = sources.sorted { $0.documentNumber < $1.documentNumber }
            values.reserveCapacity(ordered.count)
            for source in ordered {
                try Task.checkCancellation()
                let digest = try AILexicalIndexSupport.registryDigest(source)
                if let generation = try matchingGeneration(source: source, registryDigest: digest) {
                    let data = try loadGeneration(generation: generation, source: source)
                    generationsToTouch.append(GenerationTouchReference(
                        id: generation.id,
                        canonicalIdentity: source.descriptor.canonicalIdentity
                    ))
                    values.append((source.documentNumber, data))
                    hits += 1
                } else {
                    let data = try AILexicalIndexSupport.buildCanonicalData(source: source, tokenizer: tokenizer)
                    try storeGeneration(source: source, registryDigest: digest, data: data)
                    values.append((source.documentNumber, data))
                    misses += 1
                }
            }
            try touchGenerations(generationsToTouch)
            var preparedSources: [AILexicalPreparedSource] = []
            preparedSources.reserveCapacity(ordered.count)
            for (source, value) in zip(ordered, values) {
                guard source.documentNumber == value.documentNumber else {
                    throw AIBM25IndexError.invalidIndexData
                }
                preparedSources.append(AILexicalPreparedSource(
                    documentNumber: source.documentNumber,
                    sourceIdentity: source.descriptor.canonicalIdentity,
                    bm25: try AIBM25PreparedIndex(
                        data: value.data,
                        tokenizer: tokenizer,
                        parameters: parameters
                    )
                ))
            }
            let merged = try AILexicalIndexSupport.merge(values, tokenizer: tokenizer)
            let prepared = try AIBM25PreparedIndex(data: merged, tokenizer: tokenizer, parameters: parameters)
            try Task.checkCancellation()
            let identities = ordered.map(\.descriptor.canonicalIdentity)
            try pruneIfNeeded(retaining: Set(identities), maximumBytes: storagePolicy.maximumBytes)
            try secureDatabaseFiles()
            try Task.checkCancellation()
            return AILexicalPreparedIndex(
                bm25: prepared,
                sourceIdentities: identities,
                preparedSources: preparedSources,
                metadata: AILexicalIndexPreparationMetadata(
                    backend: .sqlite,
                    cacheHits: hits,
                    cacheMisses: misses,
                    fallbackReason: nil,
                    preparationSeconds: Date().timeIntervalSince(started),
                    databaseMetrics: databaseMetrics()
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let reason = fallbackReason(for: error)
            if reason == .corrupt || reason == .incompatible {
                closeDatabase()
                try? removeDatabaseFiles()
            }
            return try await memoryFallback(sources: sources, reason: reason, started: started)
        }
    }

    func generationCount() throws -> Int {
        guard storagePolicy.persistenceEnabled, storagePolicy.databaseURL != nil else { return 0 }
        try openIfNeeded()
        return Int(try scalarInt64("SELECT COUNT(*) FROM source_generation"))
    }

    func containsGeneration(identity: String) throws -> Bool {
        guard storagePolicy.persistenceEnabled, storagePolicy.databaseURL != nil else { return false }
        try openIfNeeded()
        return try withStatement("SELECT 1 FROM source_generation WHERE identity = ? LIMIT 1") { statement in
            try bind(identity, at: 1, to: statement)
            return try step(statement, allowingRow: true) == SQLITE_ROW
        }
    }

    func removeGeneration(identity: String) throws {
        guard storagePolicy.persistenceEnabled, storagePolicy.databaseURL != nil else { return }
        try openIfNeeded()
        try transaction {
            try withStatement("DELETE FROM source_generation WHERE identity = ?") { statement in
                try bind(identity, at: 1, to: statement)
                try expectDone(statement)
            }
            try deleteAllOrphanTerms()
        }
        try checkpointAndVacuum()
        try secureDatabaseFiles()
    }

    /// Prepared indexes contain complete value data, so LRU deletion is safe
    /// even while a caller is querying a value returned by an earlier prepare.
    func prune(maximumBytes: Int64, retaining identities: Set<String> = []) throws {
        guard storagePolicy.persistenceEnabled, storagePolicy.databaseURL != nil else { return }
        try openIfNeeded()
        try pruneIfNeeded(retaining: identities, maximumBytes: max(0, maximumBytes))
        try secureDatabaseFiles()
    }

    func clearDerivedCache() throws {
        closeDatabase()
        try removeDatabaseFiles()
    }

    func currentDatabaseMetrics() -> AILexicalIndexDatabaseMetrics? {
        databaseMetrics()
    }

    // MARK: - Persistent preparation

    private struct GenerationRow {
        let id: Int64
        let descriptor: AIBM25IndexDescriptor
        let registryDigest: String
        let segmentCount: Int
        let totalTokenCount: Int
    }

    /// Both values are required when updating access metadata. A generation
    /// can be deleted by another connection after it has been loaded, and
    /// SQLite may reuse its rowid for an unrelated source generation.
    private struct GenerationTouchReference {
        let id: Int64
        let canonicalIdentity: String
    }

    private func matchingGeneration(
        source: AILexicalIndexSource,
        registryDigest: String
    ) throws -> GenerationRow? {
        let identity = source.descriptor.canonicalIdentity
        let row = try withStatement(
            """
            SELECT id, file_id, content_version, snapshot_fingerprint,
                   segmenter_version, tokenizer_profile, schema_version,
                   registry_digest, segment_count, total_token_count
            FROM source_generation WHERE identity = ?
            """
        ) { statement -> GenerationRow? in
            try bind(identity, at: 1, to: statement)
            guard try step(statement, allowingRow: true) == SQLITE_ROW else { return nil }
            guard let fileID = UUID(uuidString: try columnText(statement, 1)) else {
                throw AISQLiteBM25IndexError.cacheValidation
            }
            let descriptor = AIBM25IndexDescriptor(
                fileID: fileID,
                contentVersion: try columnText(statement, 2),
                snapshotFingerprint: try columnText(statement, 3),
                segmenterVersion: try columnText(statement, 4),
                tokenizerVersion: try columnText(statement, 5),
                schemaVersion: Int(sqlite3_column_int64(statement, 6))
            )
            return GenerationRow(
                id: sqlite3_column_int64(statement, 0),
                descriptor: descriptor,
                registryDigest: try columnText(statement, 7),
                segmentCount: Int(sqlite3_column_int64(statement, 8)),
                totalTokenCount: Int(sqlite3_column_int64(statement, 9))
            )
        }
        guard let row else { return nil }
        let canonicalRecords = try AILexicalIndexSupport.canonicalRecords(source)
        guard row.descriptor == source.descriptor,
              row.descriptor.canonicalIdentity == identity,
              row.registryDigest == registryDigest,
              row.segmentCount == canonicalRecords.count,
              row.totalTokenCount >= 0
        else {
            return nil
        }
        return row
    }

    private func loadGeneration(
        generation: GenerationRow,
        source: AILexicalIndexSource
    ) throws -> AIBM25IndexData {
        let expectedRecords = Dictionary(
            uniqueKeysWithValues: try AILexicalIndexSupport.canonicalRecords(source).map { ($0.id, $0) }
        )
        try Task.checkCancellation()
        var segmentLengths: [AISegmentID: Int] = [:]
        var rowIDs: [Int64: AISegmentID] = [:]
        var loadedSegmentRows = 0
        try withStatement(
            """
            SELECT id, canonical_segment_id, page, block, sentence,
                   source_range_location, source_range_length, page_fingerprint,
                   source_kind, source_confidence, token_count
            FROM segment WHERE source_generation_id = ?
            ORDER BY page, block, sentence
            """
        ) { statement in
            try bind(generation.id, at: 1, to: statement)
            while try step(statement, allowingRow: true) == SQLITE_ROW {
                try checkWarmLoadCancellation(.segments, completedRows: loadedSegmentRows)
                let rowID = sqlite3_column_int64(statement, 0)
                guard let id = AISegmentID(try columnText(statement, 1)),
                      id.document == 1,
                      let expected = expectedRecords[id]
                else { throw AISQLiteBM25IndexError.cacheValidation }
                let confidence: Double? = sqlite3_column_type(statement, 9) == SQLITE_NULL
                    ? nil : sqlite3_column_double(statement, 9)
                guard Int(sqlite3_column_int64(statement, 2)) == id.page,
                      Int(sqlite3_column_int64(statement, 3)) == id.block,
                      Int(sqlite3_column_int64(statement, 4)) == id.sentence,
                      Int(sqlite3_column_int64(statement, 5)) == expected.sourceRange.location,
                      Int(sqlite3_column_int64(statement, 6)) == expected.sourceRange.length,
                      try columnText(statement, 7) == expected.pageFingerprint,
                      try columnText(statement, 8) == expected.sourceKind.rawValue,
                      confidence == expected.sourceConfidence
                else { throw AISQLiteBM25IndexError.cacheValidation }
                guard rowIDs.updateValue(id, forKey: rowID) == nil,
                      segmentLengths.updateValue(Int(sqlite3_column_int64(statement, 10)), forKey: id) == nil
                else { throw AISQLiteBM25IndexError.cacheValidation }
                loadedSegmentRows += 1
            }
        }
        guard segmentLengths.count == expectedRecords.count else {
            throw AISQLiteBM25IndexError.cacheValidation
        }

        var statistics: [String: AIBM25TermStatistics] = [:]
        var loadedStatisticRows = 0
        try withStatement(
            """
            SELECT term.token, source_term_stat.document_frequency,
                   source_term_stat.collection_frequency
            FROM source_term_stat
            JOIN term ON term.id = source_term_stat.term_id
            WHERE source_term_stat.source_generation_id = ?
            ORDER BY term.token
            """
        ) { statement in
            try bind(generation.id, at: 1, to: statement)
            while try step(statement, allowingRow: true) == SQLITE_ROW {
                try checkWarmLoadCancellation(.termStatistics, completedRows: loadedStatisticRows)
                let token = try columnText(statement, 0)
                guard statistics.updateValue(
                    AIBM25TermStatistics(
                        documentFrequency: Int(sqlite3_column_int64(statement, 1)),
                        collectionFrequency: Int(sqlite3_column_int64(statement, 2))
                    ),
                    forKey: token
                ) == nil else { throw AISQLiteBM25IndexError.cacheValidation }
                loadedStatisticRows += 1
            }
        }

        var postings: [String: [AIBM25Posting]] = [:]
        var loadedPostingRows = 0
        try withStatement(
            """
            SELECT term.token, posting.segment_row_id, posting.term_frequency
            FROM posting
            JOIN term ON term.id = posting.term_id
            JOIN segment ON segment.id = posting.segment_row_id
            WHERE posting.source_generation_id = ?
            ORDER BY term.token, segment.page, segment.block, segment.sentence
            """
        ) { statement in
            try bind(generation.id, at: 1, to: statement)
            while try step(statement, allowingRow: true) == SQLITE_ROW {
                try checkWarmLoadCancellation(.postings, completedRows: loadedPostingRows)
                let token = try columnText(statement, 0)
                guard let id = rowIDs[sqlite3_column_int64(statement, 1)] else {
                    throw AISQLiteBM25IndexError.cacheValidation
                }
                postings[token, default: []].append(AIBM25Posting(
                    segmentID: id,
                    termFrequency: Int(sqlite3_column_int64(statement, 2))
                ))
                loadedPostingRows += 1
            }
        }
        try Task.checkCancellation()
        var totalSegmentLength = 0
        for length in segmentLengths.values {
            let sum = totalSegmentLength.addingReportingOverflow(length)
            guard !sum.overflow else { throw AISQLiteBM25IndexError.cacheValidation }
            totalSegmentLength = sum.partialValue
        }
        guard totalSegmentLength == generation.totalTokenCount else {
            throw AISQLiteBM25IndexError.cacheValidation
        }
        let data = AIBM25IndexData(
            schemaVersion: AIBM25IndexData.currentSchemaVersion,
            tokenizerVersion: tokenizer.version,
            segmentLengths: segmentLengths,
            termStatistics: statistics,
            postings: postings,
            totalSegmentLength: totalSegmentLength
        )
        do {
            _ = try AIBM25PreparedIndex(
                data: data,
                tokenizer: tokenizer,
                parameters: parameters
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AISQLiteBM25IndexError.cacheValidation
        }
        try Task.checkCancellation()
        return data
    }

    private func storeGeneration(
        source: AILexicalIndexSource,
        registryDigest: String,
        data: AIBM25IndexData
    ) throws {
        let records = Dictionary(
            uniqueKeysWithValues: try AILexicalIndexSupport.canonicalRecords(source).map { ($0.id, $0) }
        )
        try transaction {
            // Capture only terms referenced by generations this source can
            // replace. Deleting against this bounded candidate set keeps the
            // replacement crash-atomic without scanning the entire term table
            // once for every source in a cold multi-source build.
            let orphanCandidates = try replacementTermIDs(for: source.descriptor)
            try withStatement("DELETE FROM source_generation WHERE identity = ?") { statement in
                try bind(source.descriptor.canonicalIdentity, at: 1, to: statement)
                try expectDone(statement)
            }
            try withStatement(
                """
                INSERT INTO source_generation(
                    identity, file_id, content_version, snapshot_fingerprint,
                    segmenter_version, tokenizer_profile, schema_version,
                    registry_digest, segment_count, total_token_count,
                    created_at, last_accessed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            ) { statement in
                let descriptor = source.descriptor
                try bind(descriptor.canonicalIdentity, at: 1, to: statement)
                try bind(descriptor.fileID.uuidString.lowercased(), at: 2, to: statement)
                try bind(descriptor.contentVersion, at: 3, to: statement)
                try bind(descriptor.snapshotFingerprint, at: 4, to: statement)
                try bind(descriptor.segmenterVersion, at: 5, to: statement)
                try bind(descriptor.tokenizerVersion, at: 6, to: statement)
                try bind(Int64(descriptor.schemaVersion), at: 7, to: statement)
                try bind(registryDigest, at: 8, to: statement)
                try bind(Int64(data.segmentCount), at: 9, to: statement)
                try bind(Int64(data.totalSegmentLength), at: 10, to: statement)
                let now = Date().timeIntervalSince1970
                try bind(now, at: 11, to: statement)
                try bind(now, at: 12, to: statement)
                try expectDone(statement)
            }
            let generationID = sqlite3_last_insert_rowid(database)
            // Replacing a file version is atomic. Prepared callers already own
            // complete values, so old generations require no live lease.
            try withStatement(
                "DELETE FROM source_generation WHERE file_id = ? AND id <> ?"
            ) { statement in
                try bind(source.descriptor.fileID.uuidString.lowercased(), at: 1, to: statement)
                try bind(generationID, at: 2, to: statement)
                try expectDone(statement)
            }
            try diagnosticCheckpoint(.generation)

            var segmentRows: [AISegmentID: Int64] = [:]
            try withStatement(
                """
                INSERT INTO segment(
                    source_generation_id, canonical_segment_id, page, block,
                    sentence, source_range_location, source_range_length,
                    page_fingerprint, source_kind, source_confidence, token_count
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            ) { statement in
                for id in data.segmentLengths.keys.sorted() {
                    try Task.checkCancellation()
                    guard let record = records[id] else {
                        throw AISQLiteBM25IndexError.cacheValidation
                    }
                    sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                    try bind(generationID, at: 1, to: statement)
                    try bind(id.description, at: 2, to: statement)
                    try bind(Int64(id.page), at: 3, to: statement)
                    try bind(Int64(id.block), at: 4, to: statement)
                    try bind(Int64(id.sentence), at: 5, to: statement)
                    try bind(Int64(record.sourceRange.location), at: 6, to: statement)
                    try bind(Int64(record.sourceRange.length), at: 7, to: statement)
                    try bind(record.pageFingerprint, at: 8, to: statement)
                    try bind(record.sourceKind.rawValue, at: 9, to: statement)
                    if let confidence = record.sourceConfidence {
                        try bind(confidence, at: 10, to: statement)
                    } else {
                        try bindNull(at: 10, to: statement)
                    }
                    try bind(Int64(data.segmentLengths[id, default: 0]), at: 11, to: statement)
                    try expectDone(statement)
                    segmentRows[id] = sqlite3_last_insert_rowid(database)
                }
            }
            try diagnosticCheckpoint(.segments)

            var termIDs: [String: Int64] = [:]
            try withStatement("INSERT OR IGNORE INTO term(token) VALUES (?)") { insert in
                try withStatement("SELECT id FROM term WHERE token = ?") { select in
                    for term in data.termStatistics.keys.sorted() {
                        try Task.checkCancellation()
                        sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                        try bind(term, at: 1, to: insert)
                        try expectDone(insert)
                        sqlite3_reset(select); sqlite3_clear_bindings(select)
                        try bind(term, at: 1, to: select)
                        guard try step(select, allowingRow: true) == SQLITE_ROW else {
                            throw AISQLiteBM25IndexError.cacheValidation
                        }
                        termIDs[term] = sqlite3_column_int64(select, 0)
                    }
                }
            }
            try diagnosticCheckpoint(.terms)

            try withStatement(
                """
                INSERT INTO source_term_stat(
                    source_generation_id, term_id, document_frequency,
                    collection_frequency
                ) VALUES (?, ?, ?, ?)
                """
            ) { statement in
                for term in data.termStatistics.keys.sorted() {
                    try Task.checkCancellation()
                    guard let termID = termIDs[term], let statistics = data.termStatistics[term] else {
                        throw AISQLiteBM25IndexError.cacheValidation
                    }
                    sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                    try bind(generationID, at: 1, to: statement)
                    try bind(termID, at: 2, to: statement)
                    try bind(Int64(statistics.documentFrequency), at: 3, to: statement)
                    try bind(Int64(statistics.collectionFrequency), at: 4, to: statement)
                    try expectDone(statement)
                }
            }
            try diagnosticCheckpoint(.termStatistics)

            try withStatement(
                """
                INSERT INTO posting(
                    source_generation_id, term_id, segment_row_id,
                    term_frequency
                ) VALUES (?, ?, ?, ?)
                """
            ) { statement in
                for term in data.postings.keys.sorted() {
                    guard let termID = termIDs[term] else {
                        throw AISQLiteBM25IndexError.cacheValidation
                    }
                    for posting in data.postings[term, default: []] {
                        try Task.checkCancellation()
                        guard let segmentRow = segmentRows[posting.segmentID] else {
                            throw AISQLiteBM25IndexError.cacheValidation
                        }
                        sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                        try bind(generationID, at: 1, to: statement)
                        try bind(termID, at: 2, to: statement)
                        try bind(segmentRow, at: 3, to: statement)
                        try bind(Int64(posting.termFrequency), at: 4, to: statement)
                        try expectDone(statement)
                    }
                }
            }
            try diagnosticCheckpoint(.postings)
            try deleteOrphanTerms(candidateIDs: orphanCandidates)
            try diagnosticCheckpoint(.beforeCommit)
        }
        try Task.checkCancellation()
    }

    // MARK: - Database lifecycle

    private func openIfNeeded() throws {
        guard database == nil, let url = storagePolicy.databaseURL else { return }
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try validateStoragePath()
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try validateStoragePath()
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try excludeFromBackup(directory)
        try cleanupOwnedTemporaryDatabases(in: directory)

        let databaseExisted = manager.fileExists(atPath: url.path)
        let sidecarExisted = databaseSidecarURLs(for: url).contains {
            manager.fileExists(atPath: $0.path)
        }
        let ownership: OwnershipAttribute
        if databaseExisted {
            ownership = try validateOwnershipAttribute(at: url)
            try validateExistingDatabaseOwnership(at: url, ownership: ownership)
        } else if sidecarExisted {
            throw AISQLiteBM25IndexError.unownedCache
        } else {
            ownership = try installInitializedDatabase(at: url)
        }

        if !databaseExisted, diagnosticFault == .publishedTargetRemoval {
            try unlinkRegularFile(at: url)
        }
        let preopenIdentity = try databaseFileIdentity(at: url)
        let preopenOwnership = try validateOwnershipAttribute(at: url)
        guard preopenOwnership.nonce == ownership.nonce,
              try databaseFileIdentity(at: url) == preopenIdentity
        else { throw AISQLiteBM25IndexError.unownedCache }

        var opened: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path,
            &opened,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw AISQLiteBM25IndexError.sqlite(code: status, operation: "open")
        }
        database = opened
        do {
            sqlite3_extended_result_codes(opened, 1)
            let timeoutStatus = sqlite3_busy_timeout(opened, storagePolicy.busyTimeoutMilliseconds)
            guard timeoutStatus == SQLITE_OK else {
                throw AISQLiteBM25IndexError.sqlite(code: timeoutStatus, operation: "busy-timeout")
            }
            let appID = Int32(try scalarInt64("PRAGMA application_id"))
            let userVersion = Int(try scalarInt64("PRAGMA user_version"))
            guard appID == Self.applicationID else {
                throw AISQLiteBM25IndexError.incompatibleDatabase
            }
            guard userVersion == Self.databaseUserVersion else {
                throw AISQLiteBM25IndexError.incompatibleDatabase
            }
            try validateSchema(ownerNonce: ownership.nonce)
            guard try scalarText("PRAGMA quick_check(1)") == "ok" else {
                throw AISQLiteBM25IndexError.invalidDatabase
            }
            // Only enable write-affecting connection pragmas after the opened
            // database has independently matched the inode xattr and SQLite
            // ownership metadata.
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
            try secureDatabaseFiles()
        } catch {
            closeDatabase()
            throw error
        }
    }

    private func createSchema(ownerNonce: UUID) throws {
        try execute(
            """
            BEGIN IMMEDIATE;
            CREATE TABLE index_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE source_generation (
                id INTEGER PRIMARY KEY,
                identity TEXT NOT NULL UNIQUE,
                file_id TEXT NOT NULL,
                content_version TEXT NOT NULL,
                snapshot_fingerprint TEXT NOT NULL,
                segmenter_version TEXT NOT NULL,
                tokenizer_profile TEXT NOT NULL,
                schema_version INTEGER NOT NULL,
                registry_digest TEXT NOT NULL,
                segment_count INTEGER NOT NULL CHECK(segment_count >= 0),
                total_token_count INTEGER NOT NULL CHECK(total_token_count >= 0),
                created_at REAL NOT NULL,
                last_accessed_at REAL NOT NULL
            );
            CREATE INDEX source_generation_by_file_access
                ON source_generation(file_id, last_accessed_at);
            CREATE TABLE segment (
                id INTEGER PRIMARY KEY,
                source_generation_id INTEGER NOT NULL
                    REFERENCES source_generation(id) ON DELETE CASCADE,
                canonical_segment_id TEXT NOT NULL,
                page INTEGER NOT NULL CHECK(page > 0),
                block INTEGER NOT NULL CHECK(block > 0),
                sentence INTEGER NOT NULL CHECK(sentence > 0),
                source_range_location INTEGER NOT NULL CHECK(source_range_location >= 0),
                source_range_length INTEGER NOT NULL CHECK(source_range_length >= 0),
                page_fingerprint TEXT NOT NULL,
                source_kind TEXT NOT NULL,
                source_confidence REAL,
                token_count INTEGER NOT NULL CHECK(token_count >= 0),
                UNIQUE(source_generation_id, canonical_segment_id),
                UNIQUE(id, source_generation_id)
            );
            CREATE INDEX segment_by_source_page_block
                ON segment(source_generation_id, page, block);
            CREATE TABLE term (
                id INTEGER PRIMARY KEY,
                token TEXT NOT NULL UNIQUE
            );
            CREATE TABLE source_term_stat (
                source_generation_id INTEGER NOT NULL
                    REFERENCES source_generation(id) ON DELETE CASCADE,
                term_id INTEGER NOT NULL REFERENCES term(id),
                document_frequency INTEGER NOT NULL CHECK(document_frequency > 0),
                collection_frequency INTEGER NOT NULL CHECK(collection_frequency > 0),
                PRIMARY KEY(source_generation_id, term_id)
            );
            CREATE INDEX source_term_stat_by_term
                ON source_term_stat(term_id, source_generation_id);
            CREATE TABLE posting (
                source_generation_id INTEGER NOT NULL,
                term_id INTEGER NOT NULL REFERENCES term(id),
                segment_row_id INTEGER NOT NULL,
                term_frequency INTEGER NOT NULL CHECK(term_frequency > 0),
                PRIMARY KEY(source_generation_id, term_id, segment_row_id),
                FOREIGN KEY(source_generation_id)
                    REFERENCES source_generation(id) ON DELETE CASCADE,
                FOREIGN KEY(segment_row_id, source_generation_id)
                    REFERENCES segment(id, source_generation_id) ON DELETE CASCADE
            );
            CREATE INDEX posting_by_term_source
                ON posting(term_id, source_generation_id);
            INSERT INTO index_metadata(key, value)
                VALUES ('semantic_profile', 'swift-bm25-postings-v1');
            INSERT INTO index_metadata(key, value)
                VALUES ('owner_nonce', '\(ownerNonce.uuidString)');
            PRAGMA application_id = 1146046277;
            PRAGMA user_version = 1;
            COMMIT;
            """
        )
    }

    private func validateSchema(ownerNonce: UUID) throws {
        for table in Self.requiredTables {
            let count = try withStatement(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?"
            ) { statement -> Int64 in
                try bind(table, at: 1, to: statement)
                guard try step(statement, allowingRow: true) == SQLITE_ROW else { return 0 }
                return sqlite3_column_int64(statement, 0)
            }
            guard count == 1 else { throw AISQLiteBM25IndexError.invalidDatabase }
        }
        guard try scalarText(
            "SELECT value FROM index_metadata WHERE key = 'semantic_profile'"
        ) == "swift-bm25-postings-v1" else {
            throw AISQLiteBM25IndexError.incompatibleDatabase
        }
        guard try scalarText(
            "SELECT value FROM index_metadata WHERE key = 'owner_nonce'"
        ) == ownerNonce.uuidString else {
            throw AISQLiteBM25IndexError.unownedCache
        }
        let indexCount = try withStatement(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?"
        ) { statement -> Int64 in
            try bind(Self.requiredSourceTermIndex, at: 1, to: statement)
            guard try step(statement, allowingRow: true) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(statement, 0)
        }
        guard indexCount == 1 else {
            // This is a disposable derived cache from an older schema shape.
            // Rebuilding on the next prepare avoids an unbounded, synchronous
            // CREATE INDEX on the current request path.
            throw AISQLiteBM25IndexError.incompatibleDatabase
        }
        let indexedColumns = try withStatement(
            "PRAGMA index_info(source_term_stat_by_term)"
        ) { statement -> [String] in
            var result: [String] = []
            while try step(statement, allowingRow: true) == SQLITE_ROW {
                result.append(try columnText(statement, 2))
            }
            return result
        }
        guard indexedColumns == ["term_id", "source_generation_id"] else {
            throw AISQLiteBM25IndexError.incompatibleDatabase
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func closeDatabase() {
        if let database {
            sqlite3_close_v2(database)
            self.database = nil
        }
    }

    private func removeDatabaseFiles() throws {
        guard let url = storagePolicy.databaseURL else { return }
        let manager = FileManager.default
        try validateStoragePath()
        let sidecars = databaseSidecarURLs(for: url)
        guard manager.fileExists(atPath: url.path) else {
            // The database is deliberately removed last. Without its inode
            // attribute, no remaining sidecar is safe to claim.
            return
        }
        let initialIdentity = try databaseFileIdentity(at: url)
        let ownership = try validateOwnershipAttribute(at: url)
        guard try databaseFileIdentity(at: url) == initialIdentity else {
            throw AISQLiteBM25IndexError.unownedCache
        }
        do {
            try validateExistingDatabaseOwnership(at: url, ownership: ownership)
        } catch AISQLiteBM25IndexError.cacheValidation {
            // An incomplete WAL pair is a corrupt state on an inode whose
            // xattr already proves ownership; cleanup remains retryable.
        }

        for (offset, sidecar) in sidecars.enumerated()
            where manager.fileExists(atPath: sidecar.path) {
            try unlinkRegularFile(at: sidecar)
            if offset == 0 { try diagnosticCleanupCheckpoint(.walRemoved) }
            if offset == 1 { try diagnosticCleanupCheckpoint(.sharedMemoryRemoved) }
        }
        let finalOwnership = try validateOwnershipAttribute(at: url)
        guard finalOwnership.nonce == ownership.nonce,
              try databaseFileIdentity(at: url) == initialIdentity
        else {
            throw AISQLiteBM25IndexError.unownedCache
        }
        try unlinkRegularFile(at: url)
        try fsyncDirectory(at: url.deletingLastPathComponent())
    }

    private func secureDatabaseFiles() throws {
        guard let url = storagePolicy.databaseURL else { return }
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try validateStoragePath()
        if manager.fileExists(atPath: directory.path) {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try excludeFromBackup(directory)
        }
        for candidate in [url] + databaseSidecarURLs(for: url) {
            if manager.fileExists(atPath: candidate.path) {
                try requireRegularFile(at: candidate)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate.path)
                try excludeFromBackup(candidate)
            }
        }
    }

    /// Validate the configured path lexically before touching it, then reject
    /// every existing symbolic-link component from the filesystem root through
    /// the database parent. The policy root itself is intentionally narrow and
    /// must be an ancestor of the database path.
    private func validateStoragePath() throws {
        guard let configuredRoot = storagePolicy.controlledRootURL,
              let configuredDatabase = storagePolicy.databaseURL,
              configuredRoot.isFileURL,
              configuredDatabase.isFileURL
        else { throw AISQLiteBM25IndexError.pathOutsideControlledRoot }
        let root = configuredRoot.standardizedFileURL
        let databaseURL = configuredDatabase.standardizedFileURL
        let rootComponents = root.pathComponents
        let databaseComponents = databaseURL.pathComponents
        guard databaseComponents.count > rootComponents.count,
              Array(databaseComponents.prefix(rootComponents.count)) == rootComponents
        else { throw AISQLiteBM25IndexError.pathOutsideControlledRoot }
        try rejectSymbolicLinkComponents(through: databaseURL.deletingLastPathComponent())
        for candidate in [databaseURL] + databaseSidecarURLs(for: databaseURL) {
            try rejectSymbolicLink(at: candidate)
        }
    }

    private func rejectSymbolicLinkComponents(through url: URL) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw AISQLiteBM25IndexError.symbolicLink
            }
        }
    }

    private func rejectSymbolicLink(at url: URL) throws {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw AISQLiteBM25IndexError.symbolicLink
        }
    }

    private func requireRegularFile(at url: URL) throws {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else { throw posixError() }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw AISQLiteBM25IndexError.unownedCache
        }
    }

    private func unlinkRegularFile(at url: URL) throws {
        try requireRegularFile(at: url)
        guard Darwin.unlink(url.path) == 0 else { throw posixError() }
    }

    private func databaseSidecarURLs(for url: URL) -> [URL] {
        [URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
    }

    private func ownershipAttributeData(nonce: UUID) -> Data {
        Data(
            "dogear-derived-lexical-cache\nattribute-version=\(Self.ownershipAttributeVersion)\n"
                .appending("application-id=\(Self.applicationID)\n")
                .appending("nonce=\(nonce.uuidString)\n")
                .utf8
        )
    }

    private func validateOwnershipAttribute(at url: URL) throws -> OwnershipAttribute {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AISQLiteBM25IndexError.unownedCache }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG
        else { throw AISQLiteBM25IndexError.unownedCache }
        return try validateOwnershipAttribute(on: descriptor)
    }

    private func validateOwnershipAttribute(on descriptor: Int32) throws -> OwnershipAttribute {
        let size = Self.ownershipAttributeName.withCString { name in
            Darwin.fgetxattr(descriptor, name, nil, 0, 0, 0)
        }
        guard size >= 0 else {
            if errno == ENOATTR { throw AISQLiteBM25IndexError.missingOwnershipAttribute }
            throw AISQLiteBM25IndexError.unownedCache
        }
        guard size <= 1_024 else { throw AISQLiteBM25IndexError.unownedCache }
        var bytes = [UInt8](repeating: 0, count: size)
        let readCount = bytes.withUnsafeMutableBytes { buffer in
            Self.ownershipAttributeName.withCString { name in
                Darwin.fgetxattr(descriptor, name, buffer.baseAddress, buffer.count, 0, 0)
            }
        }
        guard readCount == size else { throw AISQLiteBM25IndexError.unownedCache }
        let data = Data(bytes)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AISQLiteBM25IndexError.unownedCache
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count == 4,
              lines[0] == "dogear-derived-lexical-cache",
              lines[1] == "attribute-version=\(Self.ownershipAttributeVersion)",
              lines[2] == "application-id=\(Self.applicationID)",
              lines[3].hasPrefix("nonce="),
              let nonce = UUID(uuidString: String(lines[3].dropFirst("nonce=".count)))
        else { throw AISQLiteBM25IndexError.unownedCache }
        guard data == ownershipAttributeData(nonce: nonce) else {
            throw AISQLiteBM25IndexError.unownedCache
        }
        return OwnershipAttribute(nonce: nonce)
    }

    private func setOwnershipAttribute(
        on descriptor: Int32,
        ownership: OwnershipAttribute
    ) throws {
        let data = ownershipAttributeData(nonce: ownership.nonce)
        let status = data.withUnsafeBytes { bytes in
            Self.ownershipAttributeName.withCString { name in
                Darwin.fsetxattr(
                    descriptor,
                    name,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    XATTR_CREATE
                )
            }
        }
        guard status == 0, Darwin.fsync(descriptor) == 0 else { throw posixError() }
    }

    private func installInitializedDatabase(at finalURL: URL) throws -> OwnershipAttribute {
        let directory = finalURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".dogear-lexical-init-\(UUID().uuidString).sqlite3"
        )
        let ownership = OwnershipAttribute(nonce: UUID())
        var createdIdentity: CacheFileIdentity?
        var published = false
        do {
            let descriptor = Darwin.open(
                temporaryURL.path,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else { throw posixError() }
            do {
                var information = stat()
                guard Darwin.fstat(descriptor, &information) == 0,
                      information.st_mode & S_IFMT == S_IFREG
                else { throw posixError() }
                createdIdentity = CacheFileIdentity(
                    device: UInt64(bitPattern: Int64(information.st_dev)),
                    inode: UInt64(information.st_ino)
                )
                try diagnosticInitializationCheckpoint(.temporaryFile)
                try setOwnershipAttribute(on: descriptor, ownership: ownership)
                try diagnosticInitializationCheckpoint(.ownershipAttribute)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            guard Darwin.close(descriptor) == 0 else { throw posixError() }
            guard let createdIdentity,
                  try databaseFileIdentity(at: temporaryURL) == createdIdentity
            else { throw AISQLiteBM25IndexError.unownedCache }

            try initializeTemporaryDatabase(at: temporaryURL, ownership: ownership)
            try fsyncRegularFile(at: temporaryURL)
            try fsyncDirectory(at: directory)
            try diagnosticInitializationCheckpoint(.sqliteInitialized)
            let initializedOwnership = try validateOwnershipAttribute(at: temporaryURL)
            guard initializedOwnership.nonce == ownership.nonce,
                  try databaseFileIdentity(at: temporaryURL) == createdIdentity
            else { throw AISQLiteBM25IndexError.unownedCache }

            let renameStatus = Darwin.renameatx_np(
                AT_FDCWD,
                temporaryURL.path,
                AT_FDCWD,
                finalURL.path,
                UInt32(RENAME_EXCL)
            )
            guard renameStatus == 0 else { throw posixError() }
            published = true
            try fsyncDirectory(at: directory)
            try diagnosticInitializationCheckpoint(.atomicPublish)
            let validated = try validateOwnershipAttribute(at: finalURL)
            guard validated.nonce == ownership.nonce else {
                throw AISQLiteBM25IndexError.unownedCache
            }
            return validated
        } catch {
            if !published, let createdIdentity {
                safelyRemoveTemporaryDatabase(at: temporaryURL, identity: createdIdentity)
            }
            throw error
        }
    }

    private func initializeTemporaryDatabase(
        at url: URL,
        ownership: OwnershipAttribute
    ) throws {
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path,
            &opened,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw AISQLiteBM25IndexError.sqlite(code: status, operation: "initialize-open")
        }
        database = opened
        do {
            sqlite3_extended_result_codes(opened, 1)
            let timeoutStatus = sqlite3_busy_timeout(opened, storagePolicy.busyTimeoutMilliseconds)
            guard timeoutStatus == SQLITE_OK else {
                throw AISQLiteBM25IndexError.sqlite(
                    code: timeoutStatus,
                    operation: "initialize-busy-timeout"
                )
            }
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = DELETE")
            try execute("PRAGMA synchronous = FULL")
            try createSchema(ownerNonce: ownership.nonce)
            guard try scalarText("PRAGMA quick_check(1)") == "ok" else {
                throw AISQLiteBM25IndexError.invalidDatabase
            }
            closeDatabase()
        } catch {
            closeDatabase()
            throw error
        }
    }

    private func fsyncRegularFile(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              Darwin.fsync(descriptor) == 0
        else { throw posixError() }
    }

    private func fsyncDirectory(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
    }

    private func safelyRemoveTemporaryDatabase(
        at url: URL,
        identity: CacheFileIdentity
    ) {
        guard (try? databaseFileIdentity(at: url)) == identity else { return }
        for sidecar in temporarySidecarURLs(for: url) {
            try? unlinkRegularFile(at: sidecar)
        }
        guard (try? databaseFileIdentity(at: url)) == identity else { return }
        try? unlinkRegularFile(at: url)
        try? fsyncDirectory(at: url.deletingLastPathComponent())
    }

    private func cleanupOwnedTemporaryDatabases(in directory: URL) throws {
        let manager = FileManager.default
        let prefix = ".dogear-lexical-init-"
        let suffix = ".sqlite3"
        let entries = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { $0.lastPathComponent.hasPrefix(prefix) }
        guard !entries.isEmpty else { return }

        let databases = entries.filter { candidate in
            let name = candidate.lastPathComponent
            guard name.hasSuffix(suffix) else { return false }
            let start = name.index(name.startIndex, offsetBy: prefix.count)
            let end = name.index(name.endIndex, offsetBy: -suffix.count)
            let identifier = String(name[start..<end])
            return UUID(uuidString: identifier)?.uuidString == identifier
        }

        for databaseURL in databases {
            guard let identity = try? databaseFileIdentity(at: databaseURL),
                  let ownership = try? validateOwnershipAttribute(at: databaseURL),
                  (try? databaseFileIdentity(at: databaseURL)) == identity
            else {
                // A crash before fsetxattr, malformed xattr, or an unrelated
                // lookalike is not ours to remove and must not block a new
                // independently named initialization attempt.
                continue
            }
            for sidecar in temporarySidecarURLs(for: databaseURL)
                where manager.fileExists(atPath: sidecar.path) {
                try unlinkRegularFile(at: sidecar)
            }
            let finalOwnership = try validateOwnershipAttribute(at: databaseURL)
            guard finalOwnership.nonce == ownership.nonce,
                  try databaseFileIdentity(at: databaseURL) == identity
            else { throw AISQLiteBM25IndexError.unownedCache }
            try unlinkRegularFile(at: databaseURL)
        }
        try fsyncDirectory(at: directory)
    }

    private func temporarySidecarURLs(for url: URL) -> [URL] {
        databaseSidecarURLs(for: url) + [URL(fileURLWithPath: url.path + "-journal")]
    }

    private func databaseFileIdentity(at url: URL) throws -> CacheFileIdentity {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AISQLiteBM25IndexError.unownedCache }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG
        else { throw AISQLiteBM25IndexError.unownedCache }
        return CacheFileIdentity(
            device: UInt64(bitPattern: Int64(information.st_dev)),
            inode: UInt64(information.st_ino)
        )
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    /// Valid SQLite files are identified through a read-only connection. WAL
    /// crash artifacts may keep the app ID and metadata outside the main header,
    /// so the effective view must validate all three ownership fields.
    private func validateExistingDatabaseOwnership(
        at url: URL,
        ownership: OwnershipAttribute
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 72) ?? Data()
        let sqliteHeader = Data("SQLite format 3\0".utf8)
        guard prefix.count >= sqliteHeader.count,
              prefix.prefix(sqliteHeader.count) == sqliteHeader
        else { return }
        guard prefix.count >= 72 else { return }
        let bytes = [UInt8](prefix[68..<72])
        let headerApplicationID = Int32(bitPattern:
            UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        guard headerApplicationID == 0 || headerApplicationID == Self.applicationID else {
            throw AISQLiteBM25IndexError.unownedCache
        }

        // Every database published by the xattr lifecycle has its immutable
        // DOGE schema and owner nonce in the main file before WAL is enabled.
        // Validate that base identity without consulting adjacent sidecars;
        // this also makes cleanup retryable when a prior unlink left one
        // sidecar behind. Header-zero handling below remains only for an older
        // partially initialized owned inode.
        try validateMainDatabaseIdentityIgnoringSidecars(
            at: url,
            ownership: ownership,
            headerApplicationID: headerApplicationID
        )
        if headerApplicationID == Self.applicationID { return }

        if headerApplicationID == 0 {
            let sidecars = databaseSidecarURLs(for: url)
            let existing = sidecars.filter { FileManager.default.fileExists(atPath: $0.path) }
            for sidecar in existing {
                try rejectSymbolicLink(at: sidecar)
                let attributes = try FileManager.default.attributesOfItem(atPath: sidecar.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0
                else { throw AISQLiteBM25IndexError.unownedCache }
            }
            // A lone sidecar cannot provide SQLite's effective committed view;
            // the inode xattr proves ownership, so classify the incomplete WAL
            // state as corrupt and let cleanup remove sidecars before the DB.
            if !existing.isEmpty, existing.count != sidecars.count {
                throw AISQLiteBM25IndexError.cacheValidation
            }
        }

        var readOnlyDatabase: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            url.path,
            &readOnlyDatabase,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let readOnlyDatabase else {
            if let readOnlyDatabase { sqlite3_close_v2(readOnlyDatabase) }
            if openStatus & 0xFF == SQLITE_CORRUPT || openStatus & 0xFF == SQLITE_NOTADB {
                return
            }
            throw AISQLiteBM25IndexError.unownedCache
        }
        defer { sqlite3_close_v2(readOnlyDatabase) }
        guard sqlite3_db_readonly(readOnlyDatabase, "main") == 1 else {
            throw AISQLiteBM25IndexError.unownedCache
        }
        do {
            let effectiveApplicationID = try readOnlyScalarInt64(
                "PRAGMA application_id",
                database: readOnlyDatabase
            )
            if effectiveApplicationID == 0, headerApplicationID == 0 {
                let tableCount = try readOnlyScalarInt64(
                    "SELECT COUNT(*) FROM sqlite_master "
                        + "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
                    database: readOnlyDatabase
                )
                guard tableCount == 0 else {
                    throw AISQLiteBM25IndexError.unownedCache
                }
                return
            }
            guard effectiveApplicationID == Int64(Self.applicationID),
                  try readOnlyScalarText(
                    "SELECT value FROM index_metadata WHERE key = 'semantic_profile'",
                    database: readOnlyDatabase
                  ) == "swift-bm25-postings-v1",
                  try readOnlyScalarText(
                    "SELECT value FROM index_metadata WHERE key = 'owner_nonce'",
                    database: readOnlyDatabase
                  ) == ownership.nonce.uuidString
            else { throw AISQLiteBM25IndexError.unownedCache }
        } catch let error as AISQLiteBM25IndexError {
            if case .sqlite(let code, _) = error {
                switch code & 0xFF {
                case SQLITE_CORRUPT, SQLITE_NOTADB:
                    return
                default:
                    break
                }
            }
            throw error
        }
    }

    private func validateMainDatabaseIdentityIgnoringSidecars(
        at url: URL,
        ownership: OwnershipAttribute,
        headerApplicationID: Int32
    ) throws {
        var readOnlyDatabase: OpaquePointer?
        let uri = url.absoluteString + "?immutable=1"
        let openStatus = sqlite3_open_v2(
            uri,
            &readOnlyDatabase,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let readOnlyDatabase else {
            if let readOnlyDatabase { sqlite3_close_v2(readOnlyDatabase) }
            if openStatus & 0xFF == SQLITE_CORRUPT || openStatus & 0xFF == SQLITE_NOTADB {
                return
            }
            throw AISQLiteBM25IndexError.unownedCache
        }
        defer { sqlite3_close_v2(readOnlyDatabase) }
        guard sqlite3_db_readonly(readOnlyDatabase, "main") == 1 else {
            throw AISQLiteBM25IndexError.unownedCache
        }
        do {
            let applicationID = try readOnlyScalarInt64(
                "PRAGMA application_id",
                database: readOnlyDatabase
            )
            if applicationID == 0, headerApplicationID == 0 {
                let tableCount = try readOnlyScalarInt64(
                    "SELECT COUNT(*) FROM sqlite_master "
                        + "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
                    database: readOnlyDatabase
                )
                guard tableCount == 0 else {
                    throw AISQLiteBM25IndexError.unownedCache
                }
                return
            }
            guard applicationID == Int64(Self.applicationID),
                  try readOnlyScalarText(
                    "SELECT value FROM index_metadata WHERE key = 'semantic_profile'",
                    database: readOnlyDatabase
                  ) == "swift-bm25-postings-v1",
                  try readOnlyScalarText(
                    "SELECT value FROM index_metadata WHERE key = 'owner_nonce'",
                    database: readOnlyDatabase
                  ) == ownership.nonce.uuidString
            else { throw AISQLiteBM25IndexError.unownedCache }
        } catch let error as AISQLiteBM25IndexError {
            if case .sqlite(let code, _) = error {
                switch code & 0xFF {
                case SQLITE_CORRUPT, SQLITE_NOTADB:
                    return
                default:
                    break
                }
            }
            throw error
        }
    }

    private func readOnlyScalarInt64(
        _ sql: String,
        database: OpaquePointer
    ) throws -> Int64 {
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw AISQLiteBM25IndexError.sqlite(
                code: prepareStatus,
                operation: "read-only-prepare"
            )
        }
        defer { sqlite3_finalize(statement) }
        let stepStatus = sqlite3_step(statement)
        guard stepStatus == SQLITE_ROW else {
            throw AISQLiteBM25IndexError.sqlite(code: stepStatus, operation: "read-only-step")
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func readOnlyScalarText(
        _ sql: String,
        database: OpaquePointer
    ) throws -> String {
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw AISQLiteBM25IndexError.sqlite(
                code: prepareStatus,
                operation: "read-only-prepare"
            )
        }
        defer { sqlite3_finalize(statement) }
        let stepStatus = sqlite3_step(statement)
        guard stepStatus == SQLITE_ROW, let rawValue = sqlite3_column_text(statement, 0) else {
            throw AISQLiteBM25IndexError.sqlite(code: stepStatus, operation: "read-only-step")
        }
        return String(cString: rawValue)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(values)
    }

    // MARK: - Cleanup and fallback

    private func pruneIfNeeded(retaining identities: Set<String>, maximumBytes: Int64) throws {
        guard maximumBytes > 0 else { return }
        while (databaseMetrics()?.totalBytes ?? 0) > maximumBytes {
            let candidate = try withStatement(
                "SELECT identity FROM source_generation ORDER BY last_accessed_at ASC, identity ASC"
            ) { statement -> String? in
                while try step(statement, allowingRow: true) == SQLITE_ROW {
                    let value = try columnText(statement, 0)
                    if !identities.contains(value) { return value }
                }
                return nil
            }
            guard let candidate else { break }
            try transaction {
                try withStatement("DELETE FROM source_generation WHERE identity = ?") { statement in
                    try bind(candidate, at: 1, to: statement)
                    try expectDone(statement)
                }
                try deleteAllOrphanTerms()
            }
            try checkpointAndVacuum()
        }
    }

    private func checkpointAndVacuum() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try execute("VACUUM")
    }

    private func deleteAllOrphanTerms() throws {
        try execute(
            """
            DELETE FROM term
            WHERE NOT EXISTS (SELECT 1 FROM source_term_stat WHERE source_term_stat.term_id = term.id)
              AND NOT EXISTS (SELECT 1 FROM posting WHERE posting.term_id = term.id)
            """
        )
    }

    private func replacementTermIDs(for descriptor: AIBM25IndexDescriptor) throws -> [Int64] {
        try withStatement(
            """
            SELECT source_term_stat.term_id
            FROM source_term_stat
            JOIN source_generation
              ON source_generation.id = source_term_stat.source_generation_id
            WHERE source_generation.file_id = ? OR source_generation.identity = ?
            UNION
            SELECT posting.term_id
            FROM posting
            JOIN source_generation
              ON source_generation.id = posting.source_generation_id
            WHERE source_generation.file_id = ? OR source_generation.identity = ?
            ORDER BY 1
            """
        ) { statement in
            let fileID = descriptor.fileID.uuidString.lowercased()
            try bind(fileID, at: 1, to: statement)
            try bind(descriptor.canonicalIdentity, at: 2, to: statement)
            try bind(fileID, at: 3, to: statement)
            try bind(descriptor.canonicalIdentity, at: 4, to: statement)
            var result: [Int64] = []
            while try step(statement, allowingRow: true) == SQLITE_ROW {
                try Task.checkCancellation()
                result.append(sqlite3_column_int64(statement, 0))
            }
            return result
        }
    }

    private func deleteOrphanTerms(candidateIDs: [Int64]) throws {
        guard !candidateIDs.isEmpty else { return }
        try withStatement(
            """
            DELETE FROM term
            WHERE id = ?
              AND NOT EXISTS (
                    SELECT 1 FROM source_term_stat
                    WHERE source_term_stat.term_id = term.id
              )
              AND NOT EXISTS (
                    SELECT 1 FROM posting
                    WHERE posting.term_id = term.id
              )
            """
        ) { statement in
            for termID in candidateIDs {
                try Task.checkCancellation()
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(termID, at: 1, to: statement)
                try expectDone(statement)
            }
        }
    }

    private func touchGenerations(_ generations: [GenerationTouchReference]) throws {
        guard !generations.isEmpty else { return }
        let accessedAt = Date().timeIntervalSince1970
        try transaction {
            try withStatement(
                """
                UPDATE source_generation SET last_accessed_at = ?
                WHERE id = ? AND identity = ?
                """
            ) { statement in
                for (offset, generation) in generations.enumerated() {
                    try checkBatchTouchCancellation(completedRows: offset)
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind(accessedAt, at: 1, to: statement)
                    try bind(generation.id, at: 2, to: statement)
                    let identity = diagnosticFault == .batchTouchIdentityMismatch
                        ? "diagnostic-mismatch:\(generation.canonicalIdentity)"
                        : generation.canonicalIdentity
                    try bind(identity, at: 3, to: statement)
                    try expectDone(statement)
                }
                try checkBatchTouchCancellation(completedRows: generations.count)
            }
        }
        completedBatchTouchTransactions += 1
    }

    private func memoryFallback(
        sources: [AILexicalIndexSource],
        reason: AILexicalIndexFallbackReason,
        started: Date
    ) async throws -> AILexicalPreparedIndex {
        let memory = try await memoryBackend.prepare(sources: sources)
        return memory.replacingMetadata(AILexicalIndexPreparationMetadata(
            backend: .memory,
            cacheHits: 0,
            cacheMisses: sources.count,
            fallbackReason: reason,
            preparationSeconds: Date().timeIntervalSince(started),
            databaseMetrics: databaseMetrics()
        ))
    }

    private func fallbackReason(for error: Error) -> AILexicalIndexFallbackReason {
        guard let sqliteError = error as? AISQLiteBM25IndexError else {
            let external = error as NSError
            if external.domain == NSPOSIXErrorDomain {
                if external.code == Int(ENOSPC) || external.code == Int(EDQUOT) {
                    return .storageFull
                }
                return .unwritable
            }
            if external.domain == NSCocoaErrorDomain {
                if external.code == CocoaError.Code.fileWriteOutOfSpace.rawValue {
                    return .storageFull
                }
                return .unwritable
            }
            return .unavailable
        }
        switch sqliteError {
        case .invalidDatabase:
            return .corrupt
        case .incompatibleDatabase:
            return .incompatible
        case .cacheValidation:
            return .corrupt
        case .symbolicLink, .pathOutsideControlledRoot,
             .missingOwnershipAttribute, .unownedCache:
            return .unavailable
        case .injectedFailure:
            return .injectedFailure
        case .sqlite(let extendedCode, _):
            switch extendedCode & 0xFF {
            case SQLITE_FULL:
                return .storageFull
            case SQLITE_CORRUPT, SQLITE_NOTADB:
                return .corrupt
            case SQLITE_READONLY, SQLITE_PERM:
                return .unwritable
            default:
                return .unavailable
            }
        }
    }

    private func databaseMetrics() -> AILexicalIndexDatabaseMetrics? {
        guard let url = storagePolicy.databaseURL else { return nil }
        func size(_ candidate: URL) -> Int64 {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
                  let value = attributes[.size] as? NSNumber
            else { return 0 }
            return value.int64Value
        }
        return AILexicalIndexDatabaseMetrics(
            databaseBytes: size(url),
            walBytes: size(URL(fileURLWithPath: url.path + "-wal")),
            sharedMemoryBytes: size(URL(fileURLWithPath: url.path + "-shm"))
        )
    }

    private func diagnosticCheckpoint(_ stage: AISQLiteBM25TransactionStage) throws {
        try Task.checkCancellation()
        switch diagnosticFault {
        case .failure(let point) where point == stage:
            throw AISQLiteBM25IndexError.injectedFailure
        case .cancellation(let point) where point == stage:
            throw CancellationError()
        case .storageFull(let point) where point == stage:
            throw AISQLiteBM25IndexError.sqlite(code: SQLITE_FULL, operation: "diagnostic-full")
        default:
            break
        }
    }

    private func diagnosticInitializationCheckpoint(
        _ stage: AISQLiteBM25InitializationStage
    ) throws {
        try Task.checkCancellation()
        if case .initializationFailure(let point) = diagnosticFault, point == stage {
            throw AISQLiteBM25IndexError.injectedFailure
        }
        if case .initializationStorageFull(let point) = diagnosticFault, point == stage {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        }
    }

    private func diagnosticCleanupCheckpoint(_ stage: AISQLiteBM25CleanupStage) throws {
        try Task.checkCancellation()
        if case .cleanupFailure(let point) = diagnosticFault, point == stage {
            throw AISQLiteBM25IndexError.injectedFailure
        }
    }

    private func checkWarmLoadCancellation(
        _ stage: AISQLiteBM25WarmLoadStage,
        completedRows: Int
    ) throws {
        if completedRows.isMultiple(of: 64) {
            try Task.checkCancellation()
        }
        if case .warmLoadCancellation(let target, let afterRows) = diagnosticFault,
           target == stage,
           completedRows >= max(0, afterRows) {
            throw CancellationError()
        }
    }

    private func checkBatchTouchCancellation(completedRows: Int) throws {
        try Task.checkCancellation()
        if case .batchTouchCancellation(let afterRows) = diagnosticFault,
           completedRows >= max(0, afterRows) {
            throw CancellationError()
        }
    }

    // MARK: - SQLite helpers

    private func execute(_ sql: String) throws {
        guard let database else { throw AISQLiteBM25IndexError.invalidDatabase }
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &message)
        if let message { sqlite3_free(message) }
        guard status == SQLITE_OK else {
            throw AISQLiteBM25IndexError.sqlite(code: status, operation: "execute")
        }
    }

    private func scalarInt64(_ sql: String) throws -> Int64 {
        try withStatement(sql) { statement in
            guard try step(statement, allowingRow: true) == SQLITE_ROW else {
                throw AISQLiteBM25IndexError.cacheValidation
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    private func scalarText(_ sql: String) throws -> String {
        try withStatement(sql) { statement in
            guard try step(statement, allowingRow: true) == SQLITE_ROW else {
                throw AISQLiteBM25IndexError.cacheValidation
            }
            return try columnText(statement, 0)
        }
    }

    private func withStatement<T>(
        _ sql: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let database else { throw AISQLiteBM25IndexError.invalidDatabase }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw AISQLiteBM25IndexError.sqlite(code: status, operation: "prepare")
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        let status = value.withCString { pointer in
            sqlite3_bind_text(
                statement,
                index,
                pointer,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard status == SQLITE_OK else {
            throw AISQLiteBM25IndexError.sqlite(code: status, operation: "bind-text")
        }
    }

    private func bind(_ value: Int64, at index: Int32, to statement: OpaquePointer) throws {
        let status = sqlite3_bind_int64(statement, index, value)
        guard status == SQLITE_OK else {
            throw AISQLiteBM25IndexError.sqlite(code: status, operation: "bind-int")
        }
    }

    private func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) throws {
        let status = sqlite3_bind_double(statement, index, value)
        guard status == SQLITE_OK else {
            throw AISQLiteBM25IndexError.sqlite(code: status, operation: "bind-double")
        }
    }

    private func bindNull(at index: Int32, to statement: OpaquePointer) throws {
        let status = sqlite3_bind_null(statement, index)
        guard status == SQLITE_OK else {
            throw AISQLiteBM25IndexError.sqlite(code: status, operation: "bind-null")
        }
    }

    private func step(_ statement: OpaquePointer, allowingRow: Bool) throws -> Int32 {
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE || allowingRow && status == SQLITE_ROW { return status }
        throw AISQLiteBM25IndexError.sqlite(code: status, operation: "step")
    }

    private func expectDone(_ statement: OpaquePointer) throws {
        guard try step(statement, allowingRow: false) == SQLITE_DONE else {
            throw AISQLiteBM25IndexError.cacheValidation
        }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) throws -> String {
        guard let value = sqlite3_column_text(statement, index) else {
            throw AISQLiteBM25IndexError.cacheValidation
        }
        return String(cString: value)
    }
}
