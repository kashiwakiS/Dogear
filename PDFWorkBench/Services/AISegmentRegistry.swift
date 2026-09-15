import Foundation

nonisolated enum AISegmentRegistryError: LocalizedError, Equatable {
    case duplicateSource(UUID)
    case invalidMainDocument
    case emptyFingerprint
    case invalidPage(Int)
    case duplicatePage(Int)
    case duplicateID(AISegmentID)
    case pageFingerprintMismatch(AISegmentID)

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
        }
    }
}

/// Immutable source data captured before a request; document ordinals are request-local.
nonisolated struct AIWorkflowSourceSnapshot: Equatable, Sendable {
    let fileID: UUID
    let displayName: String
    let snapshot: AIHighlightTextSnapshot
    let version: String

    init(fileID: UUID, displayName: String, snapshot: AIHighlightTextSnapshot, version: String? = nil) {
        self.fileID = fileID
        self.displayName = displayName
        self.snapshot = snapshot
        self.version = version ?? snapshot.fingerprint
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
            let part = try AISegmentRegistry(snapshot: source.snapshot, segmenter: segmenter,
                                            documentNumber: number)
            combined += part.records
            descriptors.append(AIWorkflowSourceDescriptor(documentNumber: number, fileID: source.fileID,
                displayName: source.displayName, version: source.version,
                snapshotFingerprint: source.snapshot.fingerprint, pageCount: source.snapshot.pages.count))
        }
        self.sources = descriptors
        self.indexIdentity = descriptors.map { "\($0.fileID)|\($0.version)|\($0.snapshotFingerprint)" }.joined(separator: "|")
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
            indexIdentity: source.map { "\($0.fileID)|\($0.version)|\($0.snapshotFingerprint)" } ?? indexIdentity)
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
    func search(
        _ request: AISegmentSearchRequest,
        in registry: AISegmentRegistry
    ) -> [AISegmentSearchResult] {
        let numbers = Set(registry.records(in: request.scope).map { $0.id.document }).sorted()
        if numbers.count > 1 {
            return AIMultiSourceEvidenceRetriever.balance(numbers.map { number in
                search(request, in: registry.registry(forDocument: number))
            }, limit: min(max(1, request.topK), 100))
        }
        let normalizedQuery = AISegmenter.normalizeForSearch(request.query)
        let terms = normalizedQuery.split(separator: " ").map(String.init)
        if request.strategy == .overviewSalience, terms.isEmpty {
            return overviewCandidates(request, in: registry)
        }
        guard !terms.isEmpty else { return [] }

        return registry.records(in: request.scope)
            .compactMap { record -> AISegmentSearchResult? in
                let phraseScore = record.normalizedText.contains(normalizedQuery) ? 4.0 : 0.0
                let termScore = terms.reduce(0.0) { score, term in
                    score + Double(record.normalizedText.components(separatedBy: term).count - 1)
                }
                let coverage = Double(
                    terms.filter { record.normalizedText.contains($0) }.count
                ) / Double(terms.count)
                let score = phraseScore + termScore + coverage
                guard score > 0 else { return nil }
                return AISegmentSearchResult(id: record.id, score: score)
            }
            .sorted {
                if $0.score == $1.score { return $0.id < $1.id }
                return $0.score > $1.score
            }
            .prefix(min(max(1, request.topK), 100))
            .map { $0 }
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
