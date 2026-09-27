import CryptoKit
import Foundation

/// Complete, structured identity for one immutable per-file lexical generation.
/// Callers must pass these fields directly; no backend parses the legacy
/// `AISegmentRegistry.indexIdentity` concatenation.
nonisolated struct AIBM25IndexDescriptor: Codable, Equatable, Hashable, Sendable {
    static let identityVersion = "dogear.lexical-source-generation.v1"

    let fileID: UUID
    let contentVersion: String
    let snapshotFingerprint: String
    let segmenterVersion: String
    let tokenizerVersion: String
    let schemaVersion: Int

    init(
        fileID: UUID,
        contentVersion: String,
        snapshotFingerprint: String,
        segmenterVersion: String,
        tokenizerVersion: String = AILexicalTokenizer.currentVersion,
        schemaVersion: Int = AIBM25IndexData.currentSchemaVersion
    ) {
        self.fileID = fileID
        self.contentVersion = contentVersion
        self.snapshotFingerprint = snapshotFingerprint
        self.segmenterVersion = segmenterVersion
        self.tokenizerVersion = tokenizerVersion
        self.schemaVersion = schemaVersion
    }

    var canonicalPayload: String {
        [
            Self.identityVersion,
            Self.field("file-id", fileID.uuidString.lowercased()),
            Self.field("content-version", contentVersion),
            Self.field("snapshot", snapshotFingerprint),
            Self.field("segmenter", segmenterVersion),
            Self.field("tokenizer", tokenizerVersion),
            Self.field("schema", String(schemaVersion))
        ].joined(separator: "|")
    }

    var canonicalIdentity: String {
        SHA256.hash(data: Data(canonicalPayload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func field(_ name: String, _ value: String) -> String {
        "\(name)=\(value.utf8.count):\(value)"
    }
}

/// One authorized source for a request. Records may carry either their current
/// request ordinal or the canonical D001 ordinal; persistence always rewrites
/// them to D001 and the prepared request value maps them back to
/// `documentNumber` before scoring.
nonisolated struct AILexicalIndexSource: Sendable {
    let descriptor: AIBM25IndexDescriptor
    let documentNumber: Int
    let records: [AISegmentRecord]

    init(descriptor: AIBM25IndexDescriptor, documentNumber: Int, records: [AISegmentRecord]) {
        self.descriptor = descriptor
        self.documentNumber = documentNumber
        self.records = records
    }
}

nonisolated enum AILexicalIndexBackendKind: String, Codable, Equatable, Sendable {
    case memory
    case sqlite
}

nonisolated enum AILexicalIndexFallbackReason: String, Codable, Equatable, Sendable {
    case persistenceDisabled
    case unavailable
    case corrupt
    case incompatible
    case unwritable
    case storageFull
    case injectedFailure
}

nonisolated struct AILexicalIndexDatabaseMetrics: Equatable, Sendable {
    let databaseBytes: Int64
    let walBytes: Int64
    let sharedMemoryBytes: Int64

    var totalBytes: Int64 { databaseBytes + walBytes + sharedMemoryBytes }
}

nonisolated struct AILexicalIndexPreparationMetadata: Equatable, Sendable {
    let backend: AILexicalIndexBackendKind
    let cacheHits: Int
    let cacheMisses: Int
    let fallbackReason: AILexicalIndexFallbackReason?
    let preparationSeconds: Double
    let databaseMetrics: AILexicalIndexDatabaseMetrics?
}

/// One immutable canonical shard returned alongside the request-wide merged
/// index. Multi-source callers use these already prepared values without
/// invoking the backend once per source.
nonisolated struct AILexicalPreparedSource: Sendable {
    let documentNumber: Int
    let sourceIdentity: String
    let bm25: AIBM25PreparedIndex
}

/// Fully loaded immutable value. It owns no SQLite handle or lease, so deleting
/// or pruning the derived database after `prepare` cannot affect active search.
nonisolated struct AILexicalPreparedIndex: Sendable {
    let bm25: AIBM25PreparedIndex
    let sourceIdentities: [String]
    let preparedSources: [AILexicalPreparedSource]
    let metadata: AILexicalIndexPreparationMetadata

    var indexData: AIBM25IndexData { bm25.data }

    func search(_ request: AISegmentSearchRequest) -> [AISegmentSearchResult] {
        bm25.search(request)
    }

    func replacingMetadata(_ value: AILexicalIndexPreparationMetadata) -> Self {
        Self(
            bm25: bm25,
            sourceIdentities: sourceIdentities,
            preparedSources: preparedSources,
            metadata: value
        )
    }
}

nonisolated protocol AILexicalIndexBackend: Sendable {
    func prepare(sources: [AILexicalIndexSource]) async throws -> AILexicalPreparedIndex
}

extension AILexicalIndexBackend {
    func prepare(source: AILexicalIndexSource) async throws -> AILexicalPreparedIndex {
        try await prepare(sources: [source])
    }
}

nonisolated enum AILexicalIndexBackendError: LocalizedError, Equatable {
    case invalidDescriptor
    case invalidDocumentNumber(Int)
    case duplicateDocumentNumber(Int)
    case duplicateFileID(UUID)
    case mixedRecordDocuments
    case duplicateCanonicalSegment(AISegmentID)
    case tokenizerMismatch(expected: String, actual: String)
    case schemaMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .invalidDescriptor:
            "The lexical source descriptor is incomplete."
        case .invalidDocumentNumber(let value):
            "The lexical request document number is invalid: \(value)."
        case .duplicateDocumentNumber(let value):
            "The lexical request contains duplicate document number \(value)."
        case .duplicateFileID(let value):
            "The lexical request contains duplicate file identity \(value)."
        case .mixedRecordDocuments:
            "One lexical source contains records from multiple documents."
        case .duplicateCanonicalSegment(let id):
            "Canonical lexical segment identity is duplicated: \(id)."
        case .tokenizerMismatch(let expected, let actual):
            "The lexical descriptor tokenizer is incompatible (expected \(expected), found \(actual))."
        case .schemaMismatch(let expected, let actual):
            "The lexical descriptor schema is incompatible (expected \(expected), found \(actual))."
        }
    }
}

nonisolated struct AIInMemoryBM25IndexBackend: AILexicalIndexBackend {
    let tokenizer: AILexicalTokenizer
    let parameters: AIBM25Parameters

    init(
        tokenizer: AILexicalTokenizer = AILexicalTokenizer(),
        parameters: AIBM25Parameters = .frozen
    ) {
        self.tokenizer = tokenizer
        self.parameters = parameters
    }

    func prepare(sources: [AILexicalIndexSource]) async throws -> AILexicalPreparedIndex {
        let started = Date()
        try AILexicalIndexSupport.validate(sources: sources, tokenizer: tokenizer)
        var values: [(documentNumber: Int, data: AIBM25IndexData)] = []
        var preparedSources: [AILexicalPreparedSource] = []
        values.reserveCapacity(sources.count)
        preparedSources.reserveCapacity(sources.count)
        for source in sources.sorted(by: { $0.documentNumber < $1.documentNumber }) {
            try Task.checkCancellation()
            let data = try AILexicalIndexSupport.buildCanonicalData(source: source, tokenizer: tokenizer)
            values.append((source.documentNumber, data))
            preparedSources.append(AILexicalPreparedSource(
                documentNumber: source.documentNumber,
                sourceIdentity: source.descriptor.canonicalIdentity,
                bm25: try AIBM25PreparedIndex(
                    data: data,
                    tokenizer: tokenizer,
                    parameters: parameters
                )
            ))
        }
        let merged = try AILexicalIndexSupport.merge(values, tokenizer: tokenizer)
        let prepared = try AIBM25PreparedIndex(data: merged, tokenizer: tokenizer, parameters: parameters)
        try Task.checkCancellation()
        return AILexicalPreparedIndex(
            bm25: prepared,
            sourceIdentities: preparedSources.map(\.sourceIdentity),
            preparedSources: preparedSources,
            metadata: AILexicalIndexPreparationMetadata(
                backend: .memory,
                cacheHits: 0,
                cacheMisses: sources.count,
                fallbackReason: nil,
                preparationSeconds: Date().timeIntervalSince(started),
                databaseMetrics: nil
            )
        )
    }
}

nonisolated enum AISharedMemoryBM25DiagnosticFault: Equatable, Sendable {
    case cancellationBeforePublication
}

/// Process-wide, bounded reuse for the Scheme 1 product default. The cache owns
/// only immutable, text-free canonical D001 index values. Every request still
/// remaps and merges only its currently authorized sources, so a cached source
/// cannot leak statistics or candidates into another request.
actor AISharedMemoryBM25IndexBackend: AILexicalIndexBackend {
    static let shared = AISharedMemoryBM25IndexBackend()

    private struct Key: Hashable {
        let canonicalIdentity: String
        let registryDigest: String
    }

    private struct Entry {
        let data: AIBM25IndexData
        let cost: Int
        var lastAccess: UInt64
    }

    nonisolated let tokenizer: AILexicalTokenizer
    nonisolated let parameters: AIBM25Parameters
    private let maximumGenerations: Int
    private let maximumCost: Int
    private let diagnosticFault: AISharedMemoryBM25DiagnosticFault?
    private var entries: [Key: Entry] = [:]
    private var totalCost = 0
    private var accessCounter: UInt64 = 0
    private var totalHits = 0
    private var totalMisses = 0
    private var totalBuilds = 0

    init(
        tokenizer: AILexicalTokenizer = AILexicalTokenizer(),
        parameters: AIBM25Parameters = .frozen,
        maximumGenerations: Int = 64,
        maximumCost: Int = 2_000_000,
        diagnosticFault: AISharedMemoryBM25DiagnosticFault? = nil
    ) {
        self.tokenizer = tokenizer
        self.parameters = parameters
        self.maximumGenerations = max(0, maximumGenerations)
        self.maximumCost = max(0, maximumCost)
        self.diagnosticFault = diagnosticFault
    }

    func prepare(sources: [AILexicalIndexSource]) async throws -> AILexicalPreparedIndex {
        let started = Date()
        try AILexicalIndexSupport.validate(sources: sources, tokenizer: tokenizer)
        let ordered = sources.sorted { $0.documentNumber < $1.documentNumber }
        var values: [(documentNumber: Int, data: AIBM25IndexData)] = []
        var preparedSources: [AILexicalPreparedSource] = []
        var staged: [(key: Key, data: AIBM25IndexData, cost: Int)] = []
        var touched: [Key] = []
        var hits = 0
        var misses = 0
        values.reserveCapacity(ordered.count)
        preparedSources.reserveCapacity(ordered.count)
        staged.reserveCapacity(ordered.count)
        touched.reserveCapacity(ordered.count)

        for source in ordered {
            try Task.checkCancellation()
            let key = Key(
                canonicalIdentity: source.descriptor.canonicalIdentity,
                registryDigest: try AILexicalIndexSupport.registryDigest(source)
            )
            let data: AIBM25IndexData
            if let cached = entries[key] {
                data = cached.data
                touched.append(key)
                hits += 1
            } else {
                data = try AILexicalIndexSupport.buildCanonicalData(
                    source: source,
                    tokenizer: tokenizer
                )
                try Task.checkCancellation()
                staged.append((key, data, Self.cost(of: data)))
                misses += 1
            }
            values.append((source.documentNumber, data))
            preparedSources.append(AILexicalPreparedSource(
                documentNumber: source.documentNumber,
                sourceIdentity: source.descriptor.canonicalIdentity,
                bm25: try AIBM25PreparedIndex(
                    data: data,
                    tokenizer: tokenizer,
                    parameters: parameters
                )
            ))
        }

        // Recompute request-wide statistics only from the current authorization
        // set. Cache publication happens after the complete merged value exists
        // and cancellation has been checked, so a cancelled prepare cannot make
        // a partially accepted generation visible to the next request.
        let merged = try AILexicalIndexSupport.merge(values, tokenizer: tokenizer)
        let prepared = try AIBM25PreparedIndex(
            data: merged,
            tokenizer: tokenizer,
            parameters: parameters
        )
        if diagnosticFault == .cancellationBeforePublication {
            throw CancellationError()
        }
        try Task.checkCancellation()
        for key in touched { touch(key) }
        for value in staged { publish(value) }
        totalHits += hits
        totalMisses += misses
        totalBuilds += staged.count
        return AILexicalPreparedIndex(
            bm25: prepared,
            sourceIdentities: preparedSources.map(\.sourceIdentity),
            preparedSources: preparedSources,
            metadata: AILexicalIndexPreparationMetadata(
                backend: .memory,
                cacheHits: hits,
                cacheMisses: misses,
                fallbackReason: nil,
                preparationSeconds: Date().timeIntervalSince(started),
                databaseMetrics: nil
            )
        )
    }

    func resetForDiagnostics() {
        entries.removeAll(keepingCapacity: false)
        totalCost = 0
        accessCounter = 0
        totalHits = 0
        totalMisses = 0
        totalBuilds = 0
    }

    func snapshotForDiagnostics() -> (
        generations: Int,
        cost: Int,
        hits: Int,
        misses: Int,
        builds: Int
    ) {
        (entries.count, totalCost, totalHits, totalMisses, totalBuilds)
    }

    private func touch(_ key: Key) {
        guard var entry = entries[key] else { return }
        accessCounter &+= 1
        entry.lastAccess = accessCounter
        entries[key] = entry
    }

    private func publish(_ value: (key: Key, data: AIBM25IndexData, cost: Int)) {
        guard maximumGenerations > 0,
              maximumCost > 0,
              value.cost <= maximumCost else { return }
        // A descriptor denotes one semantic generation. A different digest for
        // that descriptor is a validation miss and replaces its older value.
        for key in entries.keys where key.canonicalIdentity == value.key.canonicalIdentity
            && key != value.key {
            remove(key)
        }
        if let old = entries[value.key] { totalCost -= old.cost }
        accessCounter &+= 1
        entries[value.key] = Entry(
            data: value.data,
            cost: value.cost,
            lastAccess: accessCounter
        )
        totalCost += value.cost
        while entries.count > maximumGenerations || totalCost > maximumCost {
            guard let oldest = entries.min(by: {
                if $0.value.lastAccess == $1.value.lastAccess {
                    if $0.key.canonicalIdentity == $1.key.canonicalIdentity {
                        return $0.key.registryDigest < $1.key.registryDigest
                    }
                    return $0.key.canonicalIdentity < $1.key.canonicalIdentity
                }
                return $0.value.lastAccess < $1.value.lastAccess
            })?.key else { break }
            remove(oldest)
        }
    }

    private func remove(_ key: Key) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        totalCost -= removed.cost
    }

    private nonisolated static func cost(of data: AIBM25IndexData) -> Int {
        var cost = data.segmentLengths.count + data.termStatistics.count
        for postings in data.postings.values {
            let sum = cost.addingReportingOverflow(postings.count)
            if sum.overflow { return .max }
            cost = sum.partialValue
        }
        return cost
    }
}

/// Storage choice is platform policy; tokenizer, BM25, schema, identity, and
/// query semantics remain in the shared implementation.
nonisolated struct AILexicalIndexStoragePolicy: Equatable, Sendable {
    let persistenceEnabled: Bool
    /// The narrow app-private directory allowed to contain `databaseURL`.
    /// Backends reject paths outside it and reject symbolic links in every
    /// existing path component before creating, opening, or deleting files.
    let controlledRootURL: URL?
    let databaseURL: URL?
    let maximumBytes: Int64
    let busyTimeoutMilliseconds: Int32
    let backgroundBuildBudgetSeconds: Double
    let releasesLoadedValuesOnMemoryPressure: Bool

    init(
        persistenceEnabled: Bool,
        controlledRootURL: URL?,
        databaseURL: URL?,
        maximumBytes: Int64,
        busyTimeoutMilliseconds: Int32 = 2_000,
        backgroundBuildBudgetSeconds: Double = 30,
        releasesLoadedValuesOnMemoryPressure: Bool = true
    ) {
        self.persistenceEnabled = persistenceEnabled
        self.controlledRootURL = controlledRootURL
        self.databaseURL = databaseURL
        self.maximumBytes = max(0, maximumBytes)
        self.busyTimeoutMilliseconds = max(0, busyTimeoutMilliseconds)
        self.backgroundBuildBudgetSeconds = max(0, backgroundBuildBudgetSeconds)
        self.releasesLoadedValuesOnMemoryPressure = releasesLoadedValuesOnMemoryPressure
    }

    static var memoryOnly: Self {
        Self(
            persistenceEnabled: false,
            controlledRootURL: nil,
            databaseURL: nil,
            maximumBytes: 0
        )
    }

    static func platformDefault(fileManager: FileManager = .default) throws -> Self {
        #if os(macOS)
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let maximum: Int64 = 512 * 1_024 * 1_024
        let budget = 60.0
        #else
        let base = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let maximum: Int64 = 192 * 1_024 * 1_024
        let budget = 15.0
        #endif
        // Resolve only the system-provided container root (for example the
        // `/var` compatibility alias) before appending any app-controlled
        // components. Later path validation still observes and rejects a
        // symbolic link introduced anywhere under this canonical base.
        let controlledRoot = base.resolvingSymlinksInPath()
            .appendingPathComponent("PDFWorkBench", isDirectory: true)
            .appendingPathComponent("EvidenceRAG", isDirectory: true)
            .appendingPathComponent("Lexical", isDirectory: true)
        let database = controlledRoot
            .appendingPathComponent("index-v1.sqlite3", isDirectory: false)
        return Self(
            persistenceEnabled: true,
            controlledRootURL: controlledRoot,
            databaseURL: database,
            maximumBytes: maximum,
            backgroundBuildBudgetSeconds: budget
        )
    }
}

/// Shared canonicalization and merging used by both backends. SQLite stores one
/// D001 shard per file; merging maps each shard to its request-local ordinal and
/// recomputes corpus statistics only over the currently authorized sources.
nonisolated enum AILexicalIndexSupport {
    static func validate(
        sources: [AILexicalIndexSource],
        tokenizer: AILexicalTokenizer,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        try checkCancellation()
        var documentNumbers = Set<Int>()
        var fileIDs = Set<UUID>()
        for (offset, source) in sources.enumerated() {
            if offset.isMultiple(of: 64) { try checkCancellation() }
            guard source.documentNumber > 0 else {
                throw AILexicalIndexBackendError.invalidDocumentNumber(source.documentNumber)
            }
            guard documentNumbers.insert(source.documentNumber).inserted else {
                throw AILexicalIndexBackendError.duplicateDocumentNumber(source.documentNumber)
            }
            guard fileIDs.insert(source.descriptor.fileID).inserted else {
                throw AILexicalIndexBackendError.duplicateFileID(source.descriptor.fileID)
            }
            let descriptor = source.descriptor
            guard !descriptor.contentVersion.isEmpty,
                  !descriptor.snapshotFingerprint.isEmpty,
                  !descriptor.segmenterVersion.isEmpty,
                  !descriptor.tokenizerVersion.isEmpty
            else { throw AILexicalIndexBackendError.invalidDescriptor }
            guard descriptor.tokenizerVersion == tokenizer.version else {
                throw AILexicalIndexBackendError.tokenizerMismatch(
                    expected: tokenizer.version,
                    actual: descriptor.tokenizerVersion
                )
            }
            guard descriptor.schemaVersion == AIBM25IndexData.currentSchemaVersion else {
                throw AILexicalIndexBackendError.schemaMismatch(
                    expected: AIBM25IndexData.currentSchemaVersion,
                    actual: descriptor.schemaVersion
                )
            }
            let documents = Set(source.records.map(\.id.document))
            guard documents.count <= 1 else { throw AILexicalIndexBackendError.mixedRecordDocuments }
            _ = try canonicalRecords(source, checkCancellation: checkCancellation)
        }
        try checkCancellation()
    }

    static func canonicalRecords(
        _ source: AILexicalIndexSource,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [AISegmentRecord] {
        try checkCancellation()
        var seen = Set<AISegmentID>()
        var result: [AISegmentRecord] = []
        result.reserveCapacity(source.records.count)
        for (offset, record) in source.records.sorted(by: { $0.id < $1.id }).enumerated() {
            if offset.isMultiple(of: 64) { try checkCancellation() }
            let id = AISegmentID(
                document: 1,
                page: record.id.page,
                block: record.id.block,
                sentence: record.id.sentence
            )
            guard seen.insert(id).inserted else {
                throw AILexicalIndexBackendError.duplicateCanonicalSegment(id)
            }
            result.append(AISegmentRecord(
                id: id,
                text: record.text,
                normalizedText: record.normalizedText,
                sourceRange: record.sourceRange,
                pageFingerprint: record.pageFingerprint,
                sourceKind: record.sourceKind,
                sourceConfidence: record.sourceConfidence
            ))
        }
        try checkCancellation()
        return result
    }

    static func registryDigest(
        _ source: AILexicalIndexSource,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> String {
        let records = try canonicalRecords(source, checkCancellation: checkCancellation)
        var hash = SHA256()
        update(&hash, "registry-v1")
        update(&hash, String(records.count))
        for (offset, record) in records.enumerated() {
            if offset.isMultiple(of: 64) { try checkCancellation() }
            update(&hash, record.id.description)
            update(&hash, String(record.sourceRange.location))
            update(&hash, String(record.sourceRange.length))
            update(&hash, record.pageFingerprint)
            update(&hash, record.sourceKind.rawValue)
            update(&hash, record.sourceConfidence.map { String($0.bitPattern, radix: 16) } ?? "nil")
            // Hash exact source text to validate a warm hit without tokenizing
            // it or persisting it in the derived database.
            update(&hash, record.text)
        }
        try checkCancellation()
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func buildCanonicalData(
        source: AILexicalIndexSource,
        tokenizer: AILexicalTokenizer
    ) throws -> AIBM25IndexData {
        var builder = AIBM25IndexBuilder(tokenizer: tokenizer)
        for record in try canonicalRecords(source) {
            try Task.checkCancellation()
            builder.upsert(record)
        }
        try Task.checkCancellation()
        return builder.build()
    }

    static func merge(
        _ sources: [(documentNumber: Int, data: AIBM25IndexData)],
        tokenizer: AILexicalTokenizer,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> AIBM25IndexData {
        try checkCancellation()
        var segmentLengths: [AISegmentID: Int] = [:]
        var postings: [String: [AIBM25Posting]] = [:]
        for (sourceOffset, source) in sources.sorted(by: { $0.documentNumber < $1.documentNumber }).enumerated() {
            if sourceOffset.isMultiple(of: 16) { try checkCancellation() }
            guard source.data.schemaVersion == AIBM25IndexData.currentSchemaVersion else {
                throw AIBM25IndexError.incompatibleSchema(
                    expected: AIBM25IndexData.currentSchemaVersion,
                    actual: source.data.schemaVersion
                )
            }
            guard source.data.tokenizerVersion == tokenizer.version else {
                throw AIBM25IndexError.incompatibleTokenizer(
                    expected: tokenizer.version,
                    actual: source.data.tokenizerVersion
                )
            }
            for (offset, entry) in source.data.segmentLengths.enumerated() {
                if offset.isMultiple(of: 64) { try checkCancellation() }
                let (canonicalID, length) = entry
                let requestID = AISegmentID(
                    document: source.documentNumber,
                    page: canonicalID.page,
                    block: canonicalID.block,
                    sentence: canonicalID.sentence
                )
                guard segmentLengths.updateValue(length, forKey: requestID) == nil else {
                    throw AILexicalIndexBackendError.duplicateCanonicalSegment(requestID)
                }
            }
            for (termOffset, entry) in source.data.postings.enumerated() {
                if termOffset.isMultiple(of: 64) { try checkCancellation() }
                let (term, values) = entry
                var remapped: [AIBM25Posting] = []
                remapped.reserveCapacity(values.count)
                for (postingOffset, posting) in values.enumerated() {
                    if postingOffset.isMultiple(of: 64) { try checkCancellation() }
                    remapped.append(AIBM25Posting(
                        segmentID: AISegmentID(
                            document: source.documentNumber,
                            page: posting.segmentID.page,
                            block: posting.segmentID.block,
                            sentence: posting.segmentID.sentence
                        ),
                        termFrequency: posting.termFrequency
                    ))
                }
                postings[term, default: []].append(contentsOf: remapped)
            }
        }
        for (offset, term) in postings.keys.enumerated() {
            if offset.isMultiple(of: 64) { try checkCancellation() }
            postings[term]?.sort { $0.segmentID < $1.segmentID }
        }
        var statistics: [String: AIBM25TermStatistics] = [:]
        statistics.reserveCapacity(postings.count)
        for (offset, entry) in postings.enumerated() {
            if offset.isMultiple(of: 64) { try checkCancellation() }
            let (term, values) = entry
            var collectionFrequency = 0
            for posting in values {
                let sum = collectionFrequency.addingReportingOverflow(posting.termFrequency)
                guard !sum.overflow else { throw AIBM25IndexError.invalidIndexData }
                collectionFrequency = sum.partialValue
            }
            statistics[term] = AIBM25TermStatistics(
                documentFrequency: values.count,
                collectionFrequency: collectionFrequency
            )
        }
        var totalSegmentLength = 0
        for length in segmentLengths.values {
            let sum = totalSegmentLength.addingReportingOverflow(length)
            guard !sum.overflow else { throw AIBM25IndexError.invalidIndexData }
            totalSegmentLength = sum.partialValue
        }
        try checkCancellation()
        return AIBM25IndexData(
            schemaVersion: AIBM25IndexData.currentSchemaVersion,
            tokenizerVersion: tokenizer.version,
            segmentLengths: segmentLengths,
            termStatistics: statistics,
            postings: postings,
            totalSegmentLength: totalSegmentLength
        )
    }

    private static func update(_ hash: inout SHA256, _ value: String) {
        let data = Data(value.utf8)
        hash.update(data: Data("\(data.count):".utf8))
        hash.update(data: data)
    }
}
