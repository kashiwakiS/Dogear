import Darwin
import Foundation
import SQLite3

nonisolated struct AIEmbeddingCacheDescriptor: Equatable, Sendable {
    static let schemaVersion = 2
    static let chunkProfile = "\(AIRetrievalWindow.profile)|bert-target-254|lossless-split-510"

    let identity: String
    let sourceIdentity: String
    let modelPackageID: String
    let dimensions: Int
    let segmenterVersion: String
    let tokenizerVersion: String
    let chunkInputDigest: String
    let chunkCount: Int

    init(
        registry: AISegmentRegistry,
        packageID: String,
        dimensions: Int,
        chunks: [AIEmbeddingChunk]
    ) throws {
        guard !packageID.isEmpty, dimensions > 0, !registry.segmenterVersion.isEmpty else {
            throw AIRetrievalError.invalidModel
        }
        let sourceIdentity = Self.sourceIdentity(registry: registry)
        let segmenterVersion = AIRetrievalWindow.indexVersion(
            segmenterVersion: registry.segmenterVersion
        )
        let chunkInputDigest = Self.chunkInputDigest(chunks)
        let fields = [
            "dogear.dense-generation.v2",
            Self.field("source", sourceIdentity),
            Self.field("model", packageID),
            Self.field("dimensions", String(dimensions)),
            Self.field("segmenter", segmenterVersion),
            Self.field("tokenizer", AIBertWordPieceTokenizer.version),
            Self.field("chunk-profile", Self.chunkProfile),
            Self.field("chunk-input", chunkInputDigest),
            Self.field("schema", String(Self.schemaVersion))
        ].joined(separator: "|")
        self.identity = AIRetrievalHash.data(Data(fields.utf8))
        self.sourceIdentity = sourceIdentity
        self.modelPackageID = packageID
        self.dimensions = dimensions
        self.segmenterVersion = segmenterVersion
        self.tokenizerVersion = AIBertWordPieceTokenizer.version
        self.chunkInputDigest = chunkInputDigest
        self.chunkCount = chunks.count
    }

    func matches(chunks: [AIEmbeddingChunk]) -> Bool {
        chunkCount == chunks.count && chunkInputDigest == Self.chunkInputDigest(chunks)
    }

    private static func sourceIdentity(registry: AISegmentRegistry) -> String {
        if registry.sources.count == 1, let source = registry.sources.first {
            return source.fileID.uuidString.lowercased()
        }

        // Per-source canonical registries intentionally omit their descriptor,
        // but retain the semantic `UUID|snapshot` index identity. Only the
        // stable UUID is used as the source association; vector validity is
        // independently bound to the exact chunk/anchor/token digest below.
        let raw = registry.indexIdentity
        if raw.count > 36 {
            let prefix = String(raw.prefix(36))
            let separator = raw.index(raw.startIndex, offsetBy: 36)
            if raw[separator] == "|", let id = UUID(uuidString: prefix) {
                return id.uuidString.lowercased()
            }
        }
        return AIRetrievalHash.data(Data("dogear.dense-anonymous-source.v1|\(raw)".utf8))
    }

    private static func chunkInputDigest(_ chunks: [AIEmbeddingChunk]) -> String {
        var data = Data("dogear.dense-chunk-input.v2".utf8)
        data.appendLittleEndian(UInt64(chunks.count))
        for chunk in chunks {
            data.appendLittleEndian(Int64(chunk.anchorID.document))
            data.appendLittleEndian(Int64(chunk.anchorID.page))
            data.appendLittleEndian(Int64(chunk.anchorID.block))
            data.appendLittleEndian(Int64(chunk.anchorID.sentence))
            data.appendLittleEndian(UInt64(chunk.ids.count))
            for id in chunk.ids {
                data.appendLittleEndian(Int64(id.document))
                data.appendLittleEndian(Int64(id.page))
                data.appendLittleEndian(Int64(id.block))
                data.appendLittleEndian(Int64(id.sentence))
            }
            data.appendLittleEndian(UInt64(chunk.tokens.count))
            for token in chunk.tokens {
                data.appendLittleEndian(UInt32(bitPattern: token))
            }
        }
        return AIRetrievalHash.data(data)
    }

    private static func field(_ name: String, _ value: String) -> String {
        "\(name)=\(value.utf8.count):\(value)"
    }
}

nonisolated enum AIEmbeddingVectorBlobCodec {
    static func encode(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * MemoryLayout<UInt32>.size)
        for value in vector {
            data.appendLittleEndian(value.bitPattern)
        }
        return data
    }

    static func decode(_ data: Data, dimensions: Int) throws -> [Float] {
        guard dimensions > 0, data.count == dimensions * MemoryLayout<UInt32>.size else {
            throw AISQLiteEmbeddingCacheError.cacheValidation
        }
        return try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw AISQLiteEmbeddingCacheError.cacheValidation
            }
            var values: [Float] = []
            values.reserveCapacity(dimensions)
            for offset in stride(from: 0, to: data.count, by: 4) {
                let bits = UInt32(base[offset])
                    | (UInt32(base[offset + 1]) << 8)
                    | (UInt32(base[offset + 2]) << 16)
                    | (UInt32(base[offset + 3]) << 24)
                values.append(Float(bitPattern: bits))
            }
            return values
        }
    }
}

nonisolated enum AISQLiteEmbeddingCacheDiagnosticFault: Equatable, Sendable {
    case duringInitialization
    case afterGeneration
    case afterFirstChunk
    case afterFirstMapping
    case beforeCommit
    case cancellationBeforeCommit
}

private enum AISQLiteEmbeddingCacheError: Error {
    case sqlite(code: Int32, operation: String)
    case invalidDatabase
    case incompatibleDatabase
    case cacheValidation
    case symbolicLink
    case injectedFailure
}

/// A deletable, app-private cache for document embeddings. SQLite persists
/// generations and canonical segment mappings only; ranking still loads exact
/// Float32 values into Swift and uses the existing vDSP cosine implementation.
actor AISQLiteEmbeddingIndexCache {
    private static let applicationID: Int32 = 0x44454E53 // "DENS"
    private static let databaseUserVersion = 1
    private static let requiredTables = [
        "dense_generation", "dense_chunk", "dense_chunk_segment"
    ]

    nonisolated let databaseURL: URL
    private var database: OpaquePointer?
    private var diagnosticFault: AISQLiteEmbeddingCacheDiagnosticFault?

    init(
        databaseURL: URL,
        diagnosticFault: AISQLiteEmbeddingCacheDiagnosticFault? = nil
    ) {
        self.databaseURL = databaseURL
        self.diagnosticFault = diagnosticFault
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    nonisolated static func databaseURL(cacheRoot: URL? = nil) -> URL {
        let root: URL
        if let cacheRoot {
            root = cacheRoot
        } else {
            #if os(macOS)
            root = AILocalEmbeddingModels.root
                .appendingPathComponent("Dense", isDirectory: true)
            #else
            root = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            )[0]
                .appendingPathComponent("PDFWorkBench", isDirectory: true)
                .appendingPathComponent("EvidenceRAG", isDirectory: true)
                .appendingPathComponent("Dense", isDirectory: true)
            #endif
        }
        return root.appendingPathComponent("embeddings-v1.sqlite3", isDirectory: false)
    }

    func close() {
        closeDatabase()
    }

    func loadBestEffort(
        descriptor: AIEmbeddingCacheDescriptor,
        chunks: [AIEmbeddingChunk]
    ) async throws -> [[Float]]? {
        do {
            return try load(descriptor: descriptor, chunks: chunks)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            closeDatabase()
            return nil
        }
    }

    @discardableResult
    func storeBestEffort(
        descriptor: AIEmbeddingCacheDescriptor,
        chunks: [AIEmbeddingChunk],
        vectors: [[Float]]
    ) async throws -> Bool {
        do {
            try store(descriptor: descriptor, chunks: chunks, vectors: vectors)
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            closeDatabase()
            return false
        }
    }

    func diagnosticRowCounts() throws -> (generations: Int, chunks: Int, mappings: Int) {
        try openIfNeeded()
        return (
            Int(try scalarInt("SELECT COUNT(*) FROM dense_generation")),
            Int(try scalarInt("SELECT COUNT(*) FROM dense_chunk")),
            Int(try scalarInt("SELECT COUNT(*) FROM dense_chunk_segment"))
        )
    }

    private struct StoredGeneration {
        let id: Int64
        let sourceIdentity: String
        let modelPackageID: String
        let dimensions: Int
        let segmenterVersion: String
        let tokenizerVersion: String
        let chunkProfile: String
        let chunkInputDigest: String
        let chunkCount: Int
    }

    private func load(
        descriptor: AIEmbeddingCacheDescriptor,
        chunks: [AIEmbeddingChunk]
    ) throws -> [[Float]]? {
        try Task.checkCancellation()
        guard descriptor.matches(chunks: chunks) else {
            throw AISQLiteEmbeddingCacheError.cacheValidation
        }
        try openIfNeeded()
        guard let generation = try matchingGeneration(descriptor) else { return nil }
        guard generation.sourceIdentity == descriptor.sourceIdentity,
              generation.modelPackageID == descriptor.modelPackageID,
              generation.dimensions == descriptor.dimensions,
              generation.segmenterVersion == descriptor.segmenterVersion,
              generation.tokenizerVersion == descriptor.tokenizerVersion,
              generation.chunkProfile == AIEmbeddingCacheDescriptor.chunkProfile,
              generation.chunkInputDigest == descriptor.chunkInputDigest,
              generation.chunkCount == descriptor.chunkCount else {
            throw AISQLiteEmbeddingCacheError.cacheValidation
        }

        let vectors = try loadVectors(generation: generation)
        let storedIDs = try loadSegmentMappings(generation: generation)
        guard vectors.count == chunks.count,
              storedIDs == chunks.map(\.ids) else {
            throw AISQLiteEmbeddingCacheError.cacheValidation
        }
        try? touch(generationID: generation.id)
        return vectors
    }

    private func matchingGeneration(
        _ descriptor: AIEmbeddingCacheDescriptor
    ) throws -> StoredGeneration? {
        let statement = try prepare(
            """
            SELECT id, source_identity, model_package_id, dimension,
                   segmenter_version, tokenizer_version, chunk_profile,
                   chunk_input_digest, chunk_count
            FROM dense_generation WHERE identity = ?1
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(descriptor.identity, at: 1, to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else {
            throw sqliteError(status, operation: "select-generation")
        }
        let value = StoredGeneration(
            id: sqlite3_column_int64(statement, 0),
            sourceIdentity: try columnText(statement, 1),
            modelPackageID: try columnText(statement, 2),
            dimensions: Int(sqlite3_column_int64(statement, 3)),
            segmenterVersion: try columnText(statement, 4),
            tokenizerVersion: try columnText(statement, 5),
            chunkProfile: try columnText(statement, 6),
            chunkInputDigest: try columnText(statement, 7),
            chunkCount: Int(sqlite3_column_int64(statement, 8))
        )
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AISQLiteEmbeddingCacheError.cacheValidation
        }
        return value
    }

    private func loadVectors(generation: StoredGeneration) throws -> [[Float]] {
        let statement = try prepare(
            """
            SELECT ordinal, vector_blob, vector_digest
            FROM dense_chunk WHERE generation_id = ?1 ORDER BY ordinal
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(generation.id, at: 1, to: statement)
        var vectors: [[Float]] = []
        vectors.reserveCapacity(generation.chunkCount)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW,
                  Int(sqlite3_column_int64(statement, 0)) == vectors.count,
                  let bytes = sqlite3_column_blob(statement, 1) else {
                throw AISQLiteEmbeddingCacheError.cacheValidation
            }
            if vectors.count.isMultiple(of: 64) { try Task.checkCancellation() }
            let byteCount = Int(sqlite3_column_bytes(statement, 1))
            let data = Data(bytes: bytes, count: byteCount)
            guard AIRetrievalHash.data(data) == (try columnText(statement, 2)) else {
                throw AISQLiteEmbeddingCacheError.cacheValidation
            }
            let vector = try AIEmbeddingVectorBlobCodec.decode(
                data,
                dimensions: generation.dimensions
            )
            guard Self.isValid(vector: vector, dimensions: generation.dimensions) else {
                throw AISQLiteEmbeddingCacheError.cacheValidation
            }
            vectors.append(vector)
        }
        guard vectors.count == generation.chunkCount else {
            throw AISQLiteEmbeddingCacheError.cacheValidation
        }
        return vectors
    }

    private func loadSegmentMappings(
        generation: StoredGeneration
    ) throws -> [[AISegmentID]] {
        let statement = try prepare(
            """
            SELECT chunk_ordinal, position, document_number, page_number,
                   block_number, sentence_number
            FROM dense_chunk_segment
            WHERE generation_id = ?1
            ORDER BY chunk_ordinal, position
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(generation.id, at: 1, to: statement)
        var result = Array(repeating: [AISegmentID](), count: generation.chunkCount)
        var rows = 0
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw sqliteError(status, operation: "select-chunk-segments")
            }
            if rows.isMultiple(of: 128) { try Task.checkCancellation() }
            let ordinal = Int(sqlite3_column_int64(statement, 0))
            let position = Int(sqlite3_column_int64(statement, 1))
            guard result.indices.contains(ordinal), position == result[ordinal].count else {
                throw AISQLiteEmbeddingCacheError.cacheValidation
            }
            result[ordinal].append(AISegmentID(
                document: Int(sqlite3_column_int64(statement, 2)),
                page: Int(sqlite3_column_int64(statement, 3)),
                block: Int(sqlite3_column_int64(statement, 4)),
                sentence: Int(sqlite3_column_int64(statement, 5))
            ))
            rows += 1
        }
        guard result.allSatisfy({ !$0.isEmpty }) else {
            throw AISQLiteEmbeddingCacheError.cacheValidation
        }
        return result
    }

    private func store(
        descriptor: AIEmbeddingCacheDescriptor,
        chunks: [AIEmbeddingChunk],
        vectors: [[Float]]
    ) throws {
        try Task.checkCancellation()
        guard descriptor.matches(chunks: chunks),
              chunks.allSatisfy({ !$0.ids.isEmpty }),
              vectors.count == chunks.count,
              vectors.allSatisfy({ Self.isValid(vector: $0, dimensions: descriptor.dimensions) }) else {
            throw AISQLiteEmbeddingCacheError.cacheValidation
        }
        try openIfNeeded()
        try execute("BEGIN IMMEDIATE")
        var transactionOpen = true
        defer {
            if transactionOpen { try? execute("ROLLBACK") }
        }

        // Retain at most one generation for the same source/model/profile. This
        // is bounded replacement, not global cache eviction.
        let removeOld = try prepare(
            """
            DELETE FROM dense_generation
            WHERE source_identity = ?1 AND model_package_id = ?2
              AND chunk_profile = ?3 AND identity <> ?4
            """
        )
        defer { sqlite3_finalize(removeOld) }
        try bind(descriptor.sourceIdentity, at: 1, to: removeOld)
        try bind(descriptor.modelPackageID, at: 2, to: removeOld)
        try bind(AIEmbeddingCacheDescriptor.chunkProfile, at: 3, to: removeOld)
        try bind(descriptor.identity, at: 4, to: removeOld)
        try stepDone(removeOld, operation: "delete-old-generations")

        let removeSame = try prepare("DELETE FROM dense_generation WHERE identity = ?1")
        defer { sqlite3_finalize(removeSame) }
        try bind(descriptor.identity, at: 1, to: removeSame)
        try stepDone(removeSame, operation: "delete-generation")

        let now = Date().timeIntervalSince1970
        let generationStatement = try prepare(
            """
            INSERT INTO dense_generation(
                identity, source_identity, model_package_id, dimension,
                segmenter_version, tokenizer_version, chunk_profile,
                chunk_input_digest, chunk_count, created_at, last_accessed_at
            ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
            """
        )
        defer { sqlite3_finalize(generationStatement) }
        try bind(descriptor.identity, at: 1, to: generationStatement)
        try bind(descriptor.sourceIdentity, at: 2, to: generationStatement)
        try bind(descriptor.modelPackageID, at: 3, to: generationStatement)
        try bind(Int64(descriptor.dimensions), at: 4, to: generationStatement)
        try bind(descriptor.segmenterVersion, at: 5, to: generationStatement)
        try bind(descriptor.tokenizerVersion, at: 6, to: generationStatement)
        try bind(AIEmbeddingCacheDescriptor.chunkProfile, at: 7, to: generationStatement)
        try bind(descriptor.chunkInputDigest, at: 8, to: generationStatement)
        try bind(Int64(descriptor.chunkCount), at: 9, to: generationStatement)
        try bind(now, at: 10, to: generationStatement)
        try bind(now, at: 11, to: generationStatement)
        try stepDone(generationStatement, operation: "insert-generation")
        let generationID = try lastInsertedRowID()
        try diagnosticCheckpoint(.afterGeneration)

        let chunkStatement = try prepare(
            """
            INSERT INTO dense_chunk(generation_id, ordinal, vector_blob, vector_digest)
            VALUES(?1, ?2, ?3, ?4)
            """
        )
        defer { sqlite3_finalize(chunkStatement) }
        let mappingStatement = try prepare(
            """
            INSERT INTO dense_chunk_segment(
                generation_id, chunk_ordinal, position, document_number,
                page_number, block_number, sentence_number
            ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
            """
        )
        defer { sqlite3_finalize(mappingStatement) }

        for (ordinal, pair) in zip(chunks, vectors).enumerated() {
            if ordinal.isMultiple(of: 32) { try Task.checkCancellation() }
            let (chunk, vector) = pair
            let blob = AIEmbeddingVectorBlobCodec.encode(vector)
            sqlite3_reset(chunkStatement)
            sqlite3_clear_bindings(chunkStatement)
            try bind(generationID, at: 1, to: chunkStatement)
            try bind(Int64(ordinal), at: 2, to: chunkStatement)
            try bind(blob, at: 3, to: chunkStatement)
            try bind(AIRetrievalHash.data(blob), at: 4, to: chunkStatement)
            try stepDone(chunkStatement, operation: "insert-chunk")
            if ordinal == 0 { try diagnosticCheckpoint(.afterFirstChunk) }

            for (position, id) in chunk.ids.enumerated() {
                sqlite3_reset(mappingStatement)
                sqlite3_clear_bindings(mappingStatement)
                try bind(generationID, at: 1, to: mappingStatement)
                try bind(Int64(ordinal), at: 2, to: mappingStatement)
                try bind(Int64(position), at: 3, to: mappingStatement)
                try bind(Int64(id.document), at: 4, to: mappingStatement)
                try bind(Int64(id.page), at: 5, to: mappingStatement)
                try bind(Int64(id.block), at: 6, to: mappingStatement)
                try bind(Int64(id.sentence), at: 7, to: mappingStatement)
                try stepDone(mappingStatement, operation: "insert-chunk-segment")
                if ordinal == 0 && position == 0 {
                    try diagnosticCheckpoint(.afterFirstMapping)
                }
            }
        }
        try diagnosticCheckpoint(.beforeCommit)
        try diagnosticCheckpoint(.cancellationBeforeCommit)
        try Task.checkCancellation()
        try execute("COMMIT")
        transactionOpen = false
        try secureFiles()
    }

    private func touch(generationID: Int64) throws {
        let statement = try prepare(
            "UPDATE dense_generation SET last_accessed_at = ?1 WHERE id = ?2"
        )
        defer { sqlite3_finalize(statement) }
        try bind(Date().timeIntervalSince1970, at: 1, to: statement)
        try bind(generationID, at: 2, to: statement)
        try stepDone(statement, operation: "touch-generation")
    }

    private static func isValid(vector: [Float], dimensions: Int) -> Bool {
        guard vector.count == dimensions, vector.allSatisfy(\.isFinite) else { return false }
        let normSquared = vector.reduce(0.0) { partial, value in
            partial + Double(value) * Double(value)
        }
        return normSquared.isFinite && abs(normSquared - 1) < 0.01
    }

    private func openIfNeeded() throws {
        if database != nil { return }
        try Task.checkCancellation()
        let manager = FileManager.default
        let root = databaseURL.deletingLastPathComponent()
        try manager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw AISQLiteEmbeddingCacheError.symbolicLink
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        var excludedRoot = root
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        try? excludedRoot.setResourceValues(excluded)

        let reservation = try AIDerivedCacheFileReservation.reserveIfAbsent(databaseURL)
        var initializationCompleted = !reservation.createdHere
        if reservation.createdHere {
            do {
                try AIDerivedCacheFileReservation.requireAbsent(paths: [
                    databaseURL.path + "-journal",
                    databaseURL.path + "-wal",
                    databaseURL.path + "-shm"
                ])
            } catch {
                reservation.removeIfStillOwned()
                throw error
            }
        }

        var opened: OpaquePointer?
        let status = sqlite3_open_v2(
            databaseURL.path,
            &opened,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
            nil
        )
        guard status == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw AISQLiteEmbeddingCacheError.sqlite(code: status, operation: "open")
        }
        database = opened
        do {
            sqlite3_extended_result_codes(opened, 1)
            let timeout = sqlite3_busy_timeout(opened, 2_000)
            guard timeout == SQLITE_OK else {
                throw AISQLiteEmbeddingCacheError.sqlite(code: timeout, operation: "busy-timeout")
            }
            let applicationID = try scalarInt("PRAGMA application_id")
            let userVersion = try scalarInt("PRAGMA user_version")
            let tableCount = try scalarInt(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            )
            if reservation.createdHere {
                guard applicationID == 0, userVersion == 0, tableCount == 0 else {
                    throw AISQLiteEmbeddingCacheError.incompatibleDatabase
                }
                try initializeSchema()
                initializationCompleted = true
            } else {
                guard applicationID == Int64(Self.applicationID),
                      userVersion == Int64(Self.databaseUserVersion) else {
                    throw AISQLiteEmbeddingCacheError.incompatibleDatabase
                }
            }
            // Validate an existing Dogear identity before journal-mode, chmod,
            // schema repair, or any other persistent operation. Unknown empty
            // SQLite files remain byte-for-byte and permission-for-permission
            // untouched.
            try execute("PRAGMA foreign_keys = ON")
            try validateSchema()
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try secureFiles()
        } catch {
            closeDatabase()
            if !initializationCompleted {
                reservation.removeIfStillOwned()
            }
            throw error
        }
    }

    private func initializeSchema() throws {
        try execute("BEGIN IMMEDIATE")
        var transactionOpen = true
        defer {
            if transactionOpen { try? execute("ROLLBACK") }
        }
        try execute("PRAGMA application_id = \(Self.applicationID)")
        try execute("PRAGMA user_version = \(Self.databaseUserVersion)")
        try diagnosticCheckpoint(.duringInitialization)
        try execute(
            """
            CREATE TABLE dense_generation(
                id INTEGER PRIMARY KEY,
                identity TEXT NOT NULL UNIQUE,
                source_identity TEXT NOT NULL,
                model_package_id TEXT NOT NULL,
                dimension INTEGER NOT NULL CHECK(dimension > 0),
                segmenter_version TEXT NOT NULL,
                tokenizer_version TEXT NOT NULL,
                chunk_profile TEXT NOT NULL,
                chunk_input_digest TEXT NOT NULL,
                chunk_count INTEGER NOT NULL CHECK(chunk_count >= 0),
                created_at REAL NOT NULL,
                last_accessed_at REAL NOT NULL
            );
            CREATE INDEX dense_generation_source
                ON dense_generation(source_identity, model_package_id, chunk_profile);
            CREATE TABLE dense_chunk(
                generation_id INTEGER NOT NULL REFERENCES dense_generation(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
                vector_blob BLOB NOT NULL,
                vector_digest TEXT NOT NULL,
                PRIMARY KEY(generation_id, ordinal)
            ) WITHOUT ROWID;
            CREATE TABLE dense_chunk_segment(
                generation_id INTEGER NOT NULL,
                chunk_ordinal INTEGER NOT NULL,
                position INTEGER NOT NULL CHECK(position >= 0),
                document_number INTEGER NOT NULL,
                page_number INTEGER NOT NULL,
                block_number INTEGER NOT NULL,
                sentence_number INTEGER NOT NULL,
                PRIMARY KEY(generation_id, chunk_ordinal, position),
                FOREIGN KEY(generation_id, chunk_ordinal)
                    REFERENCES dense_chunk(generation_id, ordinal) ON DELETE CASCADE
            ) WITHOUT ROWID;
            """
        )
        try execute("COMMIT")
        transactionOpen = false
    }

    private func validateSchema() throws {
        for table in Self.requiredTables {
            let statement = try prepare(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1"
            )
            defer { sqlite3_finalize(statement) }
            try bind(table, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  sqlite3_column_int64(statement, 0) == 1,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw AISQLiteEmbeddingCacheError.invalidDatabase
            }
        }
    }

    private func closeDatabase() {
        guard let database else { return }
        sqlite3_close_v2(database)
        self.database = nil
    }

    private func secureFiles() throws {
        let manager = FileManager.default
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: databaseURL.deletingLastPathComponent().path
        )
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            if manager.fileExists(atPath: url.path) {
                try manager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
            }
        }
    }

    private func diagnosticCheckpoint(
        _ stage: AISQLiteEmbeddingCacheDiagnosticFault
    ) throws {
        if diagnosticFault == stage {
            if stage == .cancellationBeforeCommit {
                throw CancellationError()
            }
            throw AISQLiteEmbeddingCacheError.injectedFailure
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw AISQLiteEmbeddingCacheError.invalidDatabase }
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &message)
        if let message { sqlite3_free(message) }
        guard status == SQLITE_OK else {
            throw sqliteError(status, operation: "execute")
        }
    }

    private func scalarInt(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw AISQLiteEmbeddingCacheError.invalidDatabase
        }
        let value = sqlite3_column_int64(statement, 0)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AISQLiteEmbeddingCacheError.invalidDatabase
        }
        return value
    }

    private func lastInsertedRowID() throws -> Int64 {
        guard let database else { throw AISQLiteEmbeddingCacheError.invalidDatabase }
        return sqlite3_last_insert_rowid(database)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw AISQLiteEmbeddingCacheError.invalidDatabase }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw sqliteError(status, operation: "prepare")
        }
        return statement
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
        guard status == SQLITE_OK else { throw sqliteError(status, operation: "bind-text") }
    }

    private func bind(_ value: Int64, at index: Int32, to statement: OpaquePointer) throws {
        let status = sqlite3_bind_int64(statement, index, value)
        guard status == SQLITE_OK else { throw sqliteError(status, operation: "bind-int") }
    }

    private func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) throws {
        let status = sqlite3_bind_double(statement, index, value)
        guard status == SQLITE_OK else { throw sqliteError(status, operation: "bind-double") }
    }

    private func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) throws {
        let status = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard status == SQLITE_OK else { throw sqliteError(status, operation: "bind-blob") }
    }

    private func stepDone(_ statement: OpaquePointer, operation: String) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { throw sqliteError(status, operation: operation) }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) throws -> String {
        guard let value = sqlite3_column_text(statement, index) else {
            throw AISQLiteEmbeddingCacheError.cacheValidation
        }
        return String(cString: value)
    }

    private func sqliteError(_ code: Int32, operation: String) -> Error {
        AISQLiteEmbeddingCacheError.sqlite(code: code, operation: operation)
    }
}

private extension Data {
    nonisolated mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
