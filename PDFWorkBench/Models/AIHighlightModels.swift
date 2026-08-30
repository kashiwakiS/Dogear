import Foundation

nonisolated enum AIHighlightIntent: Equatable, Sendable {
    case overview
    case question(String)
}

nonisolated enum AITextSourceKind: String, Codable, Equatable, Hashable, Sendable {
    case nativeText
    case ocrText
    case visualText
}

nonisolated struct AIHighlightTextSnapshot: Equatable, Sendable {
    let fingerprint: String
    let pages: [AITextPageSnapshot]
}

nonisolated struct AITextPageSnapshot: Equatable, Sendable {
    let pageNumber: Int
    let text: String
    let fingerprint: String
    let sourceKind: AITextSourceKind
    let sourceConfidence: Double?

    init(
        pageNumber: Int,
        text: String,
        fingerprint: String,
        sourceKind: AITextSourceKind = .nativeText,
        sourceConfidence: Double? = nil
    ) {
        self.pageNumber = pageNumber
        self.text = text
        self.fingerprint = fingerprint
        self.sourceKind = sourceKind
        self.sourceConfidence = sourceConfidence
    }
}

nonisolated struct AISourceTextRange: Codable, Equatable, Hashable, Sendable {
    let location: Int
    let length: Int

    var upperBound: Int { location + length }
}

nonisolated enum AISegmentIDError: LocalizedError, Equatable {
    case invalidFormat
    case invalidComponent(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Segment IDs must use D###.P###.B###.S### format."
        case .invalidComponent(let component):
            return "Invalid segment ID component: \(component)"
        }
    }
}

nonisolated struct AISegmentID: Codable, Hashable, Comparable, Sendable,
    CustomStringConvertible, LosslessStringConvertible
{
    let document: Int
    let page: Int
    let block: Int
    let sentence: Int

    init(document: Int, page: Int, block: Int, sentence: Int) {
        precondition(document > 0 && page > 0 && block > 0 && sentence > 0)
        self.document = document
        self.page = page
        self.block = block
        self.sentence = sentence
    }

    init(parsing value: String) throws {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else {
            throw AISegmentIDError.invalidFormat
        }

        document = try Self.parse(components[0], prefix: "D")
        page = try Self.parse(components[1], prefix: "P")
        block = try Self.parse(components[2], prefix: "B")
        sentence = try Self.parse(components[3], prefix: "S")
    }

    init?(_ description: String) {
        guard let parsed = try? AISegmentID(parsing: description) else {
            return nil
        }
        self = parsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            self = try AISegmentID(parsing: value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: error.localizedDescription
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    var description: String {
        [
            Self.format(document, prefix: "D"),
            Self.format(page, prefix: "P"),
            Self.format(block, prefix: "B"),
            Self.format(sentence, prefix: "S")
        ].joined(separator: ".")
    }

    static func < (lhs: AISegmentID, rhs: AISegmentID) -> Bool {
        (lhs.document, lhs.page, lhs.block, lhs.sentence)
            < (rhs.document, rhs.page, rhs.block, rhs.sentence)
    }

    private static func parse(_ component: Substring, prefix: Character) throws -> Int {
        guard component.first == prefix else {
            throw AISegmentIDError.invalidComponent(String(component))
        }
        let digits = component.dropFirst()
        guard digits.count >= 3,
              digits.allSatisfy(\.isNumber),
              let value = Int(digits),
              value > 0
        else {
            throw AISegmentIDError.invalidComponent(String(component))
        }
        return value
    }

    private static func format(_ value: Int, prefix: Character) -> String {
        "\(prefix)\(String(format: "%03d", value))"
    }
}

nonisolated struct AISegmentRecord: Equatable, Sendable {
    let id: AISegmentID
    let text: String
    let normalizedText: String
    let sourceRange: AISourceTextRange
    let pageFingerprint: String
    let sourceKind: AITextSourceKind
    let sourceConfidence: Double?
}

nonisolated struct AISegmentScope: Equatable, Sendable {
    let pageRange: ClosedRange<Int>?
    let blockIDs: Set<AISegmentID>

    init(pageRange: ClosedRange<Int>? = nil, blockIDs: Set<AISegmentID> = []) {
        self.pageRange = pageRange
        self.blockIDs = blockIDs
    }

    func includes(_ id: AISegmentID) -> Bool {
        if let pageRange, !pageRange.contains(id.page) {
            return false
        }
        guard !blockIDs.isEmpty else { return true }
        return blockIDs.contains {
            $0.document == id.document && $0.page == id.page && $0.block == id.block
        }
    }
}

nonisolated enum AISegmentSearchStrategy: String, Codable, Equatable, Sendable {
    case fullText
    case overviewSalience
    case questionRelevance
}

nonisolated struct AISegmentSearchRequest: Equatable, Sendable {
    let query: String
    let scope: AISegmentScope
    let topK: Int
    let strategy: AISegmentSearchStrategy

    init(
        query: String,
        scope: AISegmentScope = AISegmentScope(),
        topK: Int = 12,
        strategy: AISegmentSearchStrategy = .fullText
    ) {
        self.query = query
        self.scope = scope
        self.topK = topK
        self.strategy = strategy
    }
}

nonisolated struct AISegmentSearchResult: Codable, Equatable, Sendable {
    let id: AISegmentID
    let score: Double
}

nonisolated struct AIDocumentMapBlock: Codable, Equatable, Sendable {
    let id: AISegmentID
    let sentenceCount: Int
    let sourceKinds: Set<AITextSourceKind>
}

nonisolated struct AIDocumentMapPage: Codable, Equatable, Sendable {
    let pageNumber: Int
    let blocks: [AIDocumentMapBlock]
}

nonisolated struct AIDocumentMap: Codable, Equatable, Sendable {
    let snapshotFingerprint: String
    let segmenterVersion: String
    let pages: [AIDocumentMapPage]
}

nonisolated struct AIReadSegmentsRequest: Equatable, Sendable {
    let ids: [AISegmentID]
    let contextBefore: Int
    let contextAfter: Int

    init(ids: [AISegmentID], contextBefore: Int = 0, contextAfter: Int = 0) {
        self.ids = ids
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
    }
}

nonisolated struct AIReadSegment: Codable, Equatable, Sendable {
    let id: AISegmentID
    let text: String
    let sourceKind: AITextSourceKind
    let sourceConfidence: Double?
    let explicitlyRequested: Bool
}

nonisolated enum AIHighlightCategory: String, Codable, CaseIterable, Equatable,
    Hashable, Sendable
{
    case keyFinding
    case definition
    case method
    case evidence
    case conclusion
    case limitation
    case caveat
    case directAnswer
    case supportingEvidence
    case counterEvidence

    @MainActor var displayTitle: String {
        switch self {
        case .keyFinding: return L10n.string("Key Finding")
        case .definition: return L10n.string("Definition")
        case .method: return L10n.string("Method")
        case .evidence: return L10n.string("Evidence")
        case .conclusion: return L10n.string("Conclusion")
        case .limitation: return L10n.string("Limitation")
        case .caveat: return L10n.string("Important Note")
        case .directAnswer: return L10n.string("Direct Answer")
        case .supportingEvidence: return L10n.string("Supporting Evidence")
        case .counterEvidence: return L10n.string("Counter Evidence")
        }
    }
}

nonisolated struct AIHighlightCandidate: Codable, Equatable, Sendable {
    let candidateID: String
    let segmentIDs: [AISegmentID]
    let category: AIHighlightCategory
    let importance: Int
    let note: String?
}

nonisolated struct AIStageHighlightsRequest: Equatable, Sendable {
    let draftRevision: Int
    let title: String
    let items: [AIHighlightCandidate]
}

nonisolated enum AIStageItemStatusCode: String, Codable, Equatable, Sendable {
    case accepted
    case invalidCandidateID
    case invalidSequence
    case notFound
    case unread
    case unsupportedSource
    case lowOCRConfidence
    case duplicate
    case invalidCategory
    case invalidImportance
    case noteTooLong
    case limitExceeded
}

nonisolated struct AIStageItemStatus: Codable, Equatable, Sendable {
    let candidateID: String
    let code: AIStageItemStatusCode
}

nonisolated enum AIStageBatchErrorCode: String, Codable, Equatable, Sendable {
    case staleRevision
    case invalidItems
}

nonisolated struct AIStageHighlightsResult: Codable, Equatable, Sendable {
    let applied: Bool
    let revision: Int
    let items: [AIStageItemStatus]
    let error: AIStageBatchErrorCode?
}

nonisolated struct StagedAIHighlight: Equatable, Sendable {
    let candidate: AIHighlightCandidate
    let pageNumber: Int
    let sourceKind: AITextSourceKind
}
