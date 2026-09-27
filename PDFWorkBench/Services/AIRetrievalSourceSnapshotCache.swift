import CryptoKit
import Foundation
import PDFKit
import SQLite3

nonisolated enum AIRetrievalSourceSnapshotCacheDisposition: String, Sendable {
    case exact
    case semantic
    case miss
    case unavailable
}

/// Versions the PDFKit text extraction and semantic fingerprint contract that
/// makes a persisted source snapshot reusable. This is intentionally separate
/// from the sentence segmenter and retrieval-window profiles: changing either
/// downstream profile can reuse the same canonical page-text snapshot.
nonisolated enum AINativeTextSnapshotProfile {
    static let current = "native-pdf-text-snapshot-v1"
}

struct AIRetrievalPreparedSource {
    let read: PDFSourceReadSnapshot
    let snapshot: AIHighlightTextSnapshot
    /// Canonical D001 sentence records. Request-local document numbers are
    /// assigned only when the multi-source registry is assembled.
    let records: [AISegmentRecord]
    let cacheDisposition: AIRetrievalSourceSnapshotCacheDisposition
}

nonisolated struct AIRetrievalSourceSnapshotCacheEntry: Sendable {
    let fastRevision: String?
    let contentVersion: String
    let snapshot: AIHighlightTextSnapshot
    let snapshotProfile: String
    let segmenterVersion: String
    let records: [AISegmentRecord]
}

private enum AIRetrievalSourceSnapshotCacheError: Error {
    case unavailable
    case invalidDatabase
    case invalidPayload
    case symbolicLink
    case sqlite(Int32, String)
}

/// App-private, rebuildable extracted-text cache shared by Scheme 1 and
/// Scheme 2. It is deliberately separate from both lexical postings and dense
/// vectors: either retrieval backend can be disabled or rebuilt without
/// coupling the lifetime of the stable sentence/evidence registry to it.
actor AIRetrievalSourceSnapshotCache {
    static let shared = AIRetrievalSourceSnapshotCache()

    private static let applicationID: Int32 = 0x44535243 // "DSRC"
    private static let userVersion: Int32 = 2
    private static let maximumPayloadBytes = 256 * 1_024 * 1_024

    nonisolated let databaseURL: URL
    private let persistenceEnabled: Bool
    private let diagnosticInitializationFailure: Bool
    private var database: OpaquePointer?

    init(
        databaseURL: URL? = nil,
        persistenceEnabled: Bool = true,
        diagnosticInitializationFailure: Bool = false
    ) {
        self.databaseURL = databaseURL
            ?? AILocalEmbeddingModels.root
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("source-snapshots-v2.sqlite3")
        self.persistenceEnabled = persistenceEnabled
        self.diagnosticInitializationFailure = diagnosticInitializationFailure
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    func exact(
        fileID: UUID,
        fastRevision: String,
        snapshotProfile: String = AINativeTextSnapshotProfile.current,
        segmenterVersion: String
    ) -> AIRetrievalSourceSnapshotCacheEntry? {
        load(
            whereClause: "file_id = ? AND fast_revision = ? AND snapshot_profile = ? AND segmenter_version = ?",
            bindings: [fileID.uuidString.lowercased(), fastRevision, snapshotProfile, segmenterVersion]
        )
    }

    func semantic(
        fileID: UUID,
        snapshotFingerprint: String,
        snapshotProfile: String = AINativeTextSnapshotProfile.current,
        segmenterVersion: String
    ) -> AIRetrievalSourceSnapshotCacheEntry? {
        load(
            whereClause: "file_id = ? AND snapshot_fingerprint = ? AND snapshot_profile = ? AND segmenter_version = ?",
            bindings: [fileID.uuidString.lowercased(), snapshotFingerprint, snapshotProfile, segmenterVersion]
        )
    }

    func store(fileID: UUID, entry: AIRetrievalSourceSnapshotCacheEntry) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard persistenceEnabled,
              let payload = try? encoder.encode(Payload(snapshot: entry.snapshot, records: entry.records)),
              payload.count <= Self.maximumPayloadBytes,
              Self.validate(entry: entry),
              !Task.isCancelled
        else { return }
        do {
            try openIfNeeded()
            try execute("BEGIN IMMEDIATE")
            do {
                try withStatement(
                    """
                    INSERT OR REPLACE INTO source_generation(
                        file_id, fast_revision, content_version,
                        snapshot_fingerprint, snapshot_profile, segmenter_version,
                        page_count, segment_count, payload_digest, payload,
                        created_at, last_accessed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                ) { statement in
                    try bind(fileID.uuidString.lowercased(), at: 1, to: statement)
                    try bind(entry.fastRevision, at: 2, to: statement)
                    try bind(entry.contentVersion, at: 3, to: statement)
                    try bind(entry.snapshot.fingerprint, at: 4, to: statement)
                    try bind(entry.snapshotProfile, at: 5, to: statement)
                    try bind(entry.segmenterVersion, at: 6, to: statement)
                    try bind(Int64(entry.snapshot.pages.count), at: 7, to: statement)
                    try bind(Int64(entry.records.count), at: 8, to: statement)
                    try bind(Self.sha256(payload), at: 9, to: statement)
                    try bind(payload, at: 10, to: statement)
                    let now = Date().timeIntervalSince1970
                    try bind(now, at: 11, to: statement)
                    try bind(now, at: 12, to: statement)
                    try expectDone(statement)
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
            try secureFiles()
        } catch {
            recover(after: error)
        }
    }

    func clearDerivedCache() {
        close()
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? manager.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
        }
    }

    func generationCount() -> Int {
        do {
            try openIfNeeded()
            return try withStatement("SELECT COUNT(*) FROM source_generation") { statement in
                guard try step(statement, allowingRow: true) == SQLITE_ROW else { return 0 }
                return Int(sqlite3_column_int64(statement, 0))
            }
        } catch {
            recover(after: error)
            return 0
        }
    }

    /// Closes the actor-owned connection so offline diagnostics can exercise
    /// reopen and on-disk corruption paths. Product code does not need this.
    func closeForDiagnostics() {
        close()
    }

    private struct Payload: Codable {
        let snapshot: AIHighlightTextSnapshot
        let records: [AISegmentRecord]
    }

    private func load(whereClause: String, bindings: [String]) -> AIRetrievalSourceSnapshotCacheEntry? {
        guard persistenceEnabled, !Task.isCancelled else { return nil }
        do {
            try openIfNeeded()
            let entry = try withStatement(
                """
                SELECT fast_revision, content_version, snapshot_fingerprint,
                       snapshot_profile, segmenter_version, page_count, segment_count,
                       payload_digest, payload
                FROM source_generation WHERE \(whereClause) LIMIT 1
                """
            ) { statement -> AIRetrievalSourceSnapshotCacheEntry? in
                for (offset, value) in bindings.enumerated() {
                    try bind(value, at: Int32(offset + 1), to: statement)
                }
                guard try step(statement, allowingRow: true) == SQLITE_ROW else { return nil }
                let fastRevision = optionalColumnText(statement, 0)
                let contentVersion = try columnText(statement, 1)
                let snapshotFingerprint = try columnText(statement, 2)
                let snapshotProfile = try columnText(statement, 3)
                let segmenterVersion = try columnText(statement, 4)
                let pageCount = Int(sqlite3_column_int64(statement, 5))
                let segmentCount = Int(sqlite3_column_int64(statement, 6))
                let digest = try columnText(statement, 7)
                let payloadData = try columnData(statement, 8)
                guard payloadData.count <= Self.maximumPayloadBytes,
                      Self.sha256(payloadData) == digest,
                      let payload = try? JSONDecoder().decode(Payload.self, from: payloadData),
                      payload.snapshot.fingerprint == snapshotFingerprint,
                      payload.snapshot.pages.count == pageCount,
                      payload.records.count == segmentCount
                else { throw AIRetrievalSourceSnapshotCacheError.invalidPayload }
                let entry = AIRetrievalSourceSnapshotCacheEntry(
                    fastRevision: fastRevision,
                    contentVersion: contentVersion,
                    snapshot: payload.snapshot,
                    snapshotProfile: snapshotProfile,
                    segmenterVersion: segmenterVersion,
                    records: payload.records
                )
                guard Self.validate(entry: entry) else {
                    throw AIRetrievalSourceSnapshotCacheError.invalidPayload
                }
                return entry
            }
            if entry != nil {
                try? withStatement(
                    "UPDATE source_generation SET last_accessed_at = ? WHERE \(whereClause)"
                ) { statement in
                    try bind(Date().timeIntervalSince1970, at: 1, to: statement)
                    for (offset, value) in bindings.enumerated() {
                        try bind(value, at: Int32(offset + 2), to: statement)
                    }
                    try expectDone(statement)
                }
            }
            return entry
        } catch {
            recover(after: error)
            return nil
        }
    }

    private static func validate(entry: AIRetrievalSourceSnapshotCacheEntry) -> Bool {
        guard !entry.contentVersion.isEmpty,
              !entry.snapshot.fingerprint.isEmpty,
              !entry.snapshotProfile.isEmpty,
              !entry.segmenterVersion.isEmpty,
              entry.snapshot.pages.count <= 20_000,
              entry.records.count <= 250_000
        else { return false }
        var pages: [Int: AITextPageSnapshot] = [:]
        for page in entry.snapshot.pages {
            guard page.pageNumber > 0,
                  !page.fingerprint.isEmpty,
                  pages.updateValue(page, forKey: page.pageNumber) == nil
            else { return false }
        }
        var seen = Set<AISegmentID>()
        for record in entry.records {
            guard record.id.document == 1,
                  seen.insert(record.id).inserted,
                  let page = pages[record.id.page],
                  page.fingerprint == record.pageFingerprint,
                  page.sourceKind == record.sourceKind,
                  page.sourceConfidence == record.sourceConfidence,
                  record.normalizedText == AISegmenter.normalizeForSearch(record.text),
                  record.sourceRange.location >= 0,
                  record.sourceRange.length >= 0,
                  record.sourceRange.upperBound <= (page.text as NSString).length,
                  (page.text as NSString).substring(
                    with: NSRange(location: record.sourceRange.location, length: record.sourceRange.length)
                  ) == record.text
            else { return false }
        }
        return true
    }

    private func openIfNeeded() throws {
        guard persistenceEnabled else { throw AIRetrievalSourceSnapshotCacheError.unavailable }
        if database != nil { return }
        let manager = FileManager.default
        let directory = databaseURL.deletingLastPathComponent()
        if manager.fileExists(atPath: directory.path) {
            guard try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
                  try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
            else { throw AIRetrievalSourceSnapshotCacheError.symbolicLink }
        } else {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
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
        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(directoryValues)
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
                | SQLITE_OPEN_NOFOLLOW,
            nil
        )
        guard code == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw AIRetrievalSourceSnapshotCacheError.sqlite(code, "open")
        }
        database = handle
        do {
            try execute("PRAGMA busy_timeout = 5000")
            let applicationID = try scalarInt32("PRAGMA application_id")
            let version = try scalarInt32("PRAGMA user_version")
            if reservation.createdHere {
                guard applicationID == 0, version == 0 else {
                    throw AIRetrievalSourceSnapshotCacheError.invalidDatabase
                }
                try execute("PRAGMA application_id = \(Self.applicationID)")
                try execute("PRAGMA user_version = \(Self.userVersion)")
                if diagnosticInitializationFailure {
                    throw AIRetrievalSourceSnapshotCacheError.unavailable
                }
            } else if applicationID != Self.applicationID || version != Self.userVersion {
                throw AIRetrievalSourceSnapshotCacheError.invalidDatabase
            } else {
                try validateExistingSchema()
            }
            try execute("PRAGMA foreign_keys = ON")
            try execute(
                """
                CREATE TABLE IF NOT EXISTS source_generation(
                    file_id TEXT PRIMARY KEY NOT NULL,
                    fast_revision TEXT,
                    content_version TEXT NOT NULL,
                    snapshot_fingerprint TEXT NOT NULL,
                    snapshot_profile TEXT NOT NULL,
                    segmenter_version TEXT NOT NULL,
                    page_count INTEGER NOT NULL,
                    segment_count INTEGER NOT NULL,
                    payload_digest TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    created_at REAL NOT NULL,
                    last_accessed_at REAL NOT NULL
                ) WITHOUT ROWID
                """
            )
            try execute(
                "CREATE INDEX IF NOT EXISTS source_generation_semantic ON source_generation(file_id, snapshot_fingerprint, snapshot_profile, segmenter_version)"
            )
            initializationCompleted = true
            // Persistent pragmas are applied only after an exclusively
            // created database has a complete schema, or an existing Dogear
            // identity and schema have both been accepted.
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try secureFiles()
        } catch {
            close()
            if !initializationCompleted {
                reservation.removeIfStillOwned()
            }
            throw error
        }
    }

    private func validateExistingSchema() throws {
        let tableCount = try scalarInt32(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'source_generation'"
        )
        guard tableCount == 1 else {
            throw AIRetrievalSourceSnapshotCacheError.invalidDatabase
        }
        let required = Set([
            "file_id", "fast_revision", "content_version", "snapshot_fingerprint",
            "snapshot_profile", "segmenter_version", "page_count", "segment_count",
            "payload_digest", "payload", "created_at", "last_accessed_at"
        ])
        let columns = try withStatement("PRAGMA table_info(source_generation)") { statement in
            var values = Set<String>()
            while try step(statement, allowingRow: true) == SQLITE_ROW {
                values.insert(try columnText(statement, 1))
            }
            return values
        }
        guard required.isSubset(of: columns) else {
            throw AIRetrievalSourceSnapshotCacheError.invalidDatabase
        }
    }

    private func recover(after error: Error) {
        close()
        guard let cacheError = error as? AIRetrievalSourceSnapshotCacheError else { return }
        switch cacheError {
        case .invalidPayload:
            // A corrupt row is a safe miss. Keep the file in place: the next
            // successful store can atomically replace that source generation,
            // while an identity-forged foreign file is never deleted here.
            return
        case .invalidDatabase:
            // Do not delete an unknown or incompatible file merely because it
            // occupies the cache path. Fall back to fresh in-memory data.
            return
        case .sqlite, .unavailable, .symbolicLink:
            return
        }
    }

    private func close() {
        if let database { sqlite3_close_v2(database) }
        database = nil
    }

    private func secureFiles() throws {
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: databaseURL.deletingLastPathComponent().path)
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            if manager.fileExists(atPath: url.path) {
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw AIRetrievalSourceSnapshotCacheError.unavailable }
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(database, sql, nil, nil, &message)
        if let message { sqlite3_free(message) }
        guard code == SQLITE_OK else {
            throw AIRetrievalSourceSnapshotCacheError.sqlite(code, sql)
        }
    }

    private func scalarInt32(_ sql: String) throws -> Int32 {
        try withStatement(sql) { statement in
            guard try step(statement, allowingRow: true) == SQLITE_ROW else {
                throw AIRetrievalSourceSnapshotCacheError.invalidDatabase
            }
            return sqlite3_column_int(statement, 0)
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let database else { throw AIRetrievalSourceSnapshotCacheError.unavailable }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw AIRetrievalSourceSnapshotCacheError.sqlite(code, "prepare")
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func step(_ statement: OpaquePointer, allowingRow: Bool) throws -> Int32 {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || allowingRow && code == SQLITE_ROW else {
            throw AIRetrievalSourceSnapshotCacheError.sqlite(code, "step")
        }
        return code
    }

    private func expectDone(_ statement: OpaquePointer) throws {
        _ = try step(statement, allowingRow: false)
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        let code: Int32
        if let value {
            code = value.withCString { pointer in
                sqlite3_bind_text(
                    statement,
                    index,
                    pointer,
                    -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
        } else {
            code = sqlite3_bind_null(statement, index)
        }
        guard code == SQLITE_OK else {
            throw AIRetrievalSourceSnapshotCacheError.sqlite(code, "bind text")
        }
    }

    private func bind(_ value: Int64, at index: Int32, to statement: OpaquePointer) throws {
        let code = sqlite3_bind_int64(statement, index, value)
        guard code == SQLITE_OK else {
            throw AIRetrievalSourceSnapshotCacheError.sqlite(code, "bind integer")
        }
    }

    private func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) throws {
        let code = sqlite3_bind_double(statement, index, value)
        guard code == SQLITE_OK else {
            throw AIRetrievalSourceSnapshotCacheError.sqlite(code, "bind real")
        }
    }

    private func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) throws {
        let code = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard code == SQLITE_OK else {
            throw AIRetrievalSourceSnapshotCacheError.sqlite(code, "bind blob")
        }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) throws -> String {
        guard let pointer = sqlite3_column_text(statement, index) else {
            throw AIRetrievalSourceSnapshotCacheError.invalidPayload
        }
        return String(cString: pointer)
    }

    private func optionalColumnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func columnData(_ statement: OpaquePointer, _ index: Int32) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        let pointer = sqlite3_column_blob(statement, index)
        guard count >= 0, count <= Self.maximumPayloadBytes,
              count == 0 || pointer != nil
        else { throw AIRetrievalSourceSnapshotCacheError.invalidPayload }
        guard count > 0 else { return Data() }
        return Data(bytes: pointer!, count: count)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
struct AIRetrievalSourcePreparer {
    let cache: AIRetrievalSourceSnapshotCache
    let segmenter: AISegmenter

    init(
        cache: AIRetrievalSourceSnapshotCache = .shared,
        segmenter: AISegmenter = AISegmenter()
    ) {
        self.cache = cache
        self.segmenter = segmenter
    }

    func prepare(
        fileID: UUID,
        originalURL: URL,
        workingCopyURL: URL?
    ) async throws -> AIRetrievalPreparedSource {
        try Task.checkCancellation()
        let coordinator = DocumentAccessCoordinator.shared
        let candidate = try coordinator.retrievalCandidate(
            fileID: fileID,
            originalURL: originalURL,
            workingCopyURL: workingCopyURL
        )
        if let revision = candidate.fastRevision,
           let cached = await cache.exact(
               fileID: fileID,
               fastRevision: revision,
               snapshotProfile: AINativeTextSnapshotProfile.current,
               segmenterVersion: segmenter.version
           ) {
            try Task.checkCancellation()
            return AIRetrievalPreparedSource(
                read: PDFSourceReadSnapshot(
                    fileID: fileID,
                    originalURL: candidate.originalURL,
                    contentVersion: cached.contentVersion,
                    document: candidate.document
                ),
                snapshot: cached.snapshot,
                records: cached.records,
                cacheDisposition: .exact
            )
        }

        let snapshot = try await NativePDFTextSnapshotBuilder(document: candidate.document)
            .makeTextSnapshotCooperatively()
        try Task.checkCancellation()
        let contentVersion = coordinator.retrievalContentVersion(for: candidate)
        let semantic = await cache.semantic(
            fileID: fileID,
            snapshotFingerprint: snapshot.fingerprint,
            snapshotProfile: AINativeTextSnapshotProfile.current,
            segmenterVersion: segmenter.version
        )
        let records: [AISegmentRecord]
        let disposition: AIRetrievalSourceSnapshotCacheDisposition
        if let semantic {
            records = semantic.records
            disposition = .semantic
        } else {
            records = segmenter.segments(from: snapshot, documentNumber: 1)
            disposition = .miss
        }
        let entry = AIRetrievalSourceSnapshotCacheEntry(
            fastRevision: candidate.fastRevision,
            contentVersion: contentVersion,
            snapshot: snapshot,
            snapshotProfile: AINativeTextSnapshotProfile.current,
            segmenterVersion: segmenter.version,
            records: records
        )
        await cache.store(fileID: fileID, entry: entry)
        try Task.checkCancellation()
        return AIRetrievalPreparedSource(
            read: PDFSourceReadSnapshot(
                fileID: fileID,
                originalURL: candidate.originalURL,
                contentVersion: contentVersion,
                document: candidate.document
            ),
            snapshot: snapshot,
            records: records,
            cacheDisposition: disposition
        )
    }
}
