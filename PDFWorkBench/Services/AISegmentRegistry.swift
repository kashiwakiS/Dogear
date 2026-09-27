import Foundation

nonisolated enum AISegmentRegistryError: LocalizedError, Equatable {
    case duplicateSource(UUID)
    case invalidMainDocument
    case emptyFingerprint
    case invalidPage(Int)
    case duplicatePage(Int)
    case duplicateID(AISegmentID)
    case pageFingerprintMismatch(AISegmentID)
    case invalidPreparedRecord(AISegmentID)

    var errorDescription: String? {
        switch self {
        case .duplicateSource(let id):
            return "The request contains duplicate source identity: \(id)."
        case .invalidMainDocument:
            return "The main document is outside the prepared source scope."
        case .emptyFingerprint:
            return "The text snapshot fingerprint is empty."
        case .invalidPage(let pageNumber):
            return "The text snapshot contains an invalid page: \(pageNumber)."
        case .duplicatePage(let pageNumber):
            return "The text snapshot contains a duplicate page: \(pageNumber)."
        case .duplicateID(let id):
            return "The segment registry contains a duplicate ID: \(id)."
        case .pageFingerprintMismatch(let id):
            return "The segment source does not match its page snapshot: \(id)."
        case .invalidPreparedRecord(let id):
            return "The prepared segment does not match its cached text snapshot: \(id)."
        }
    }
}

/// Immutable source data captured before a request; document ordinals are request-local.
nonisolated struct AIWorkflowSourceSnapshot: Equatable, Sendable {
    let fileID: UUID
    let displayName: String
    let snapshot: AIHighlightTextSnapshot
    let version: String
    /// Canonical D001 records from the derived source cache. They are optional
    /// so callers that only have a text snapshot keep the normal segmenter path.
    let preparedRecords: [AISegmentRecord]?

    init(
        fileID: UUID,
        displayName: String,
        snapshot: AIHighlightTextSnapshot,
        version: String? = nil,
        preparedRecords: [AISegmentRecord]? = nil
    ) {
        self.fileID = fileID
        self.displayName = displayName
        self.snapshot = snapshot
        self.version = version ?? snapshot.fingerprint
        self.preparedRecords = preparedRecords
    }
}

nonisolated struct AIWorkflowSourceDescriptor: Codable, Equatable, Sendable {
    let documentNumber: Int
    let fileID: UUID
    let displayName: String
    let version: String
    let snapshotFingerprint: String
    let pageCount: Int
}

nonisolated struct AISegmentRegistry: Sendable {
    let snapshotFingerprint: String
    let sources: [AIWorkflowSourceDescriptor]
    let indexIdentity: String
    let segmenterVersion: String
    let records: [AISegmentRecord]

    private let recordsByID: [AISegmentID: AISegmentRecord]
    private let recordsByDocument: [Int: [AISegmentRecord]]

    init(
        snapshot: AIHighlightTextSnapshot,
        segmenter: AISegmenter = AISegmenter(),
        documentNumber: Int = 1
    ) throws {
        guard !snapshot.fingerprint.isEmpty else {
            throw AISegmentRegistryError.emptyFingerprint
        }

        var pageFingerprints: [Int: String] = [:]
        for page in snapshot.pages {
            guard page.pageNumber > 0, !page.fingerprint.isEmpty else {
                throw AISegmentRegistryError.invalidPage(page.pageNumber)
            }
            guard pageFingerprints[page.pageNumber] == nil else {
                throw AISegmentRegistryError.duplicatePage(page.pageNumber)
            }
            pageFingerprints[page.pageNumber] = page.fingerprint
        }

        let records = segmenter.segments(from: snapshot, documentNumber: documentNumber)
            .sorted { $0.id < $1.id }
        var recordsByID: [AISegmentID: AISegmentRecord] = [:]
        for record in records {
            guard recordsByID[record.id] == nil else {
                throw AISegmentRegistryError.duplicateID(record.id)
            }
            guard pageFingerprints[record.id.page] == record.pageFingerprint else {
                throw AISegmentRegistryError.pageFingerprintMismatch(record.id)
            }
            recordsByID[record.id] = record
        }

        sources = []
        indexIdentity = snapshot.fingerprint
        snapshotFingerprint = snapshot.fingerprint
        segmenterVersion = segmenter.version
        self.records = records
        self.recordsByDocument = Dictionary(grouping: records, by: { $0.id.document })
        self.recordsByID = recordsByID
    }

    init(sources: [AIWorkflowSourceSnapshot], segmenter: AISegmenter = AISegmenter(),
         mainDocumentNumber: Int? = nil) throws {
        if let mainDocumentNumber, mainDocumentNumber <= 0 || !sources.indices.contains(mainDocumentNumber - 1) {
            throw AISegmentRegistryError.invalidMainDocument
        }
        var seen = Set<UUID>()
        var descriptors: [AIWorkflowSourceDescriptor] = []
        var combined: [AISegmentRecord] = []
        for (offset, source) in sources.enumerated() {
            try Task.checkCancellation()
            guard seen.insert(source.fileID).inserted else {
                throw AISegmentRegistryError.duplicateSource(source.fileID)
            }
            let number = offset + 1
            if let prepared = source.preparedRecords {
                combined += try Self.validatePreparedRecords(
                    prepared,
                    snapshot: source.snapshot,
                    documentNumber: number
                )
            } else {
                let part = try AISegmentRegistry(snapshot: source.snapshot, segmenter: segmenter,
                                                documentNumber: number)
                combined += part.records
            }
            descriptors.append(AIWorkflowSourceDescriptor(documentNumber: number, fileID: source.fileID,
                displayName: source.displayName, version: source.version,
                snapshotFingerprint: source.snapshot.fingerprint, pageCount: source.snapshot.pages.count))
        }
        self.sources = descriptors
        // Retrieval caches follow the actual text/segmentation input. The
        // broader source version still travels with the descriptor for final
        // source validation, but annotation-only changes do not invalidate an
        // otherwise identical retrieval index.
        self.indexIdentity = descriptors.map { "\($0.fileID)|\($0.snapshotFingerprint)" }.joined(separator: "|")
        self.snapshotFingerprint = sources.isEmpty ? "empty-sources" : sources[(mainDocumentNumber ?? 1) - 1].snapshot.fingerprint
        self.segmenterVersion = segmenter.version
        self.records = combined
        self.recordsByDocument = Dictionary(grouping: combined, by: { $0.id.document })
        self.recordsByID = Dictionary(uniqueKeysWithValues: combined.map { ($0.id, $0) })
    }

    /// Reuse already segmented records when preparing per-file retrieval components.
    func registry(forDocument number: Int, canonicalIDs: Bool = false) -> AISegmentRegistry {
        let selected = recordsByDocument[number, default: []].map { record in
            guard canonicalIDs else { return record }
            return AISegmentRecord(id: AISegmentID(document: 1, page: record.id.page,
                block: record.id.block, sentence: record.id.sentence), text: record.text,
                normalizedText: record.normalizedText, sourceRange: record.sourceRange,
                pageFingerprint: record.pageFingerprint, sourceKind: record.sourceKind,
                sourceConfidence: record.sourceConfidence)
        }
        let source = sources.first { $0.documentNumber == number }
        return AISegmentRegistry(snapshotFingerprint: source?.snapshotFingerprint ?? snapshotFingerprint,
            segmenterVersion: segmenterVersion, records: selected,
            indexIdentity: source.map { "\($0.fileID)|\($0.snapshotFingerprint)" } ?? indexIdentity)
    }

    private init(snapshotFingerprint: String, segmenterVersion: String, records: [AISegmentRecord], indexIdentity: String) {
        self.indexIdentity = indexIdentity
        self.snapshotFingerprint = snapshotFingerprint
        self.segmenterVersion = segmenterVersion
        self.sources = []
        self.records = records
        self.recordsByDocument = Dictionary(grouping: records, by: { $0.id.document })
        self.recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    private static func validatePreparedRecords(
        _ records: [AISegmentRecord],
        snapshot: AIHighlightTextSnapshot,
        documentNumber: Int
    ) throws -> [AISegmentRecord] {
        var pages: [Int: AITextPageSnapshot] = [:]
        for page in snapshot.pages {
            guard page.pageNumber > 0 else {
                throw AISegmentRegistryError.invalidPage(page.pageNumber)
            }
            guard pages.updateValue(page, forKey: page.pageNumber) == nil else {
                throw AISegmentRegistryError.duplicatePage(page.pageNumber)
            }
        }
        var seen = Set<AISegmentID>()
        var result: [AISegmentRecord] = []
        result.reserveCapacity(records.count)
        for record in records.sorted(by: { $0.id < $1.id }) {
            try Task.checkCancellation()
            guard record.id.document == 1,
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
            else {
                throw AISegmentRegistryError.invalidPreparedRecord(record.id)
            }
            let id = AISegmentID(
                document: documentNumber,
                page: record.id.page,
                block: record.id.block,
                sentence: record.id.sentence
            )
            guard seen.insert(id).inserted else {
                throw AISegmentRegistryError.duplicateID(id)
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
        return result
    }

    func record(for id: AISegmentID) -> AISegmentRecord? {
        recordsByID[id]
    }

    func records(in scope: AISegmentScope = AISegmentScope()) -> [AISegmentRecord] {
        records.filter { scope.includes($0.id) }
    }

    func neighboringRecords(
        around ids: [AISegmentID],
        before: Int,
        after: Int
    ) -> [AISegmentRecord] {
        guard !ids.isEmpty else { return [] }
        let requested = Set(ids)
        var included = requested

        for id in ids {
            if before > 0 {
                for offset in 1...before where id.sentence - offset > 0 {
                    included.insert(
                        AISegmentID(
                            document: id.document,
                            page: id.page,
                            block: id.block,
                            sentence: id.sentence - offset
                        )
                    )
                }
            }
            if after > 0 {
                for offset in 1...after {
                    included.insert(
                        AISegmentID(
                            document: id.document,
                            page: id.page,
                            block: id.block,
                            sentence: id.sentence + offset
                        )
                    )
                }
            }
        }
        return included.compactMap { recordsByID[$0] }.sorted { $0.id < $1.id }
    }

    func documentMap(scope: AISegmentScope = AISegmentScope()) -> AIDocumentMap {
        let documents = Dictionary(grouping: records(in: scope), by: { $0.id.document })
        let pages = documents.keys.sorted().flatMap { number -> [AIDocumentMapPage] in
            let groupedPages = Dictionary(grouping: documents[number, default: []], by: { $0.id.page })
            return groupedPages.keys.sorted().map { pageNumber in
                let groupedBlocks = Dictionary(grouping: groupedPages[pageNumber, default: []], by: { $0.id.block })
                let blocks = groupedBlocks.keys.sorted().map { blockNumber in
                    let blockRecords = groupedBlocks[blockNumber, default: []]
                    return AIDocumentMapBlock(id: AISegmentID(document: number, page: pageNumber,
                        block: blockNumber, sentence: 1), sentenceCount: blockRecords.count,
                        sourceKinds: Set(blockRecords.map(\.sourceKind)))
                }
                return AIDocumentMapPage(pageNumber: pageNumber, blocks: blocks, documentNumber: number)
            }
        }
        return AIDocumentMap(
            snapshotFingerprint: snapshotFingerprint,
            segmenterVersion: segmenterVersion,
            pages: pages
        )
    }
}

nonisolated protocol AISegmentSearching: Sendable {
    func search(
        _ request: AISegmentSearchRequest,
        in registry: AISegmentRegistry
    ) -> [AISegmentSearchResult]
}

nonisolated struct AISimpleLexicalSearcher: AISegmentSearching {
    private let preparedIndex: AIBM25PreparedIndex?

    init(preparedIndex: AIBM25PreparedIndex? = nil) {
        self.preparedIndex = preparedIndex
    }

    init(registry: AISegmentRegistry) {
        self.preparedIndex = try? AIBM25PreparedIndex(
            records: AIRetrievalWindow.indexRecords(from: registry.records)
        )
    }

    func search(
        _ request: AISegmentSearchRequest,
        in registry: AISegmentRegistry
    ) -> [AISegmentSearchResult] {
        let limit = min(max(1, request.topK), 100)
        let global = rankedCandidates(
            AISegmentSearchRequest(
                query: request.query,
                scope: request.scope,
                topK: 100,
                strategy: request.strategy
            ),
            in: registry
        )
        let numbers = Set(global.map { $0.id.document })
        guard numbers.count > 1 else { return Array(global.prefix(limit)) }

        // BM25 statistics and ranking are global over the authorized scope.
        // Preserve the existing product contract by balancing sources only
        // after that global ranking has been established.
        var order: [Int] = []
        var grouped: [Int: [AISegmentSearchResult]] = [:]
        for candidate in global {
            if grouped[candidate.id.document] == nil { order.append(candidate.id.document) }
            grouped[candidate.id.document, default: []].append(candidate)
        }
        return AIMultiSourceEvidenceRetriever.balance(
            order.compactMap { grouped[$0] },
            limit: limit
        )
    }

    /// Returns the channel's global rank without the product's final
    /// round-robin source distribution. Hybrid fusion must consume this order.
    func rankedCandidates(
        _ request: AISegmentSearchRequest,
        in registry: AISegmentRegistry
    ) -> [AISegmentSearchResult] {
        let queryTokens = AILexicalTokenizer().tokens(request.query)
        if request.strategy == .overviewSalience, queryTokens.isEmpty {
            return overviewCandidates(request, in: registry)
        }
        guard !queryTokens.isEmpty else { return [] }
        guard let index = preparedIndex ?? (try? AIBM25PreparedIndex(
            records: AIRetrievalWindow.indexRecords(from: registry.records)
        )) else {
            return []
        }
        return index.search(AISegmentSearchRequest(
            query: request.query,
            scope: request.scope,
            topK: min(max(1, request.topK), 100),
            strategy: request.strategy
        ))
    }

    private func overviewCandidates(
        _ request: AISegmentSearchRequest,
        in registry: AISegmentRegistry
    ) -> [AISegmentSearchResult] {
        let records = registry.records(in: request.scope)
        let groupedPages = Dictionary(grouping: records, by: { $0.id.page })
        let perPage = groupedPages.keys.sorted().map { pageNumber in
            groupedPages[pageNumber, default: []]
                .map { record in
                    AISegmentSearchResult(
                        id: record.id,
                        score: overviewScore(record)
                    )
                }
                .sorted {
                    if $0.score == $1.score { return $0.id < $1.id }
                    return $0.score > $1.score
                }
        }

        var distributed: [AISegmentSearchResult] = []
        var rank = 0
        let limit = min(max(1, request.topK), 100)
        while distributed.count < limit {
            var added = false
            for page in perPage where rank < page.count {
                distributed.append(page[rank])
                added = true
                if distributed.count == limit { break }
            }
            guard added else { break }
            rank += 1
        }
        return distributed
    }

    private func overviewScore(_ record: AISegmentRecord) -> Double {
        var score = record.id.sentence == 1 ? 2.0 : 0.0
        let length = record.text.count
        if (40...420).contains(length) {
            score += 1.0
        } else if length < 12 || length > 900 {
            score -= 1.0
        }

        let cueTerms = [
            "conclusion", "define", "evidence", "finding", "important", "limitation",
            "method", "propose", "result", "show", "therefore",
            "结论", "定义", "方法", "结果", "研究", "表明", "限制",
            "結論", "定義", "手法", "結果", "研究", "示す", "限界"
        ]
        score += Double(cueTerms.filter { record.normalizedText.contains($0) }.count) * 0.75
        return score
    }
}

@MainActor
protocol AIHighlightTextSnapshotBuilding {
    func makeTextSnapshot() throws -> AIHighlightTextSnapshot
}

nonisolated protocol AITextSourceProviding: Sendable {
    var sourceKind: AITextSourceKind { get }
    func pages() async throws -> [AITextPageSnapshot]
}
