import Foundation

nonisolated enum AIHighlightToolCall: Equatable, Sendable {
    case getDocumentMap(scope: AISegmentScope)
    case searchSegments(AISegmentSearchRequest)
    case readSegments(AIReadSegmentsRequest)
    case stageHighlights(AIStageHighlightsRequest)
}

nonisolated enum AIHighlightToolOutput: Equatable, Sendable {
    case documentMap(AIDocumentMap)
    case searchResults([AISegmentSearchResult])
    case readResults([AIReadSegment])
    case staged(AIStageHighlightsResult)
}

nonisolated struct AIHighlightToolLimits: Equatable, Sendable {
    var maximumSearchResults = 100
    var maximumReadSelectors = 24
    var maximumReadContext = 3
    var maximumDraftItems = 15
    var maximumSegmentsPerHighlight = 3
    var maximumCandidateIDLength = 64
    var maximumNoteLength = 500
    var minimumOCRConfidence = 0.85
}

actor AIHighlightToolExecutor {
    let registry: AISegmentRegistry
    let intent: AIHighlightIntent

    private let searcher: any AISegmentSearching
    private let limits: AIHighlightToolLimits
    private var readSegmentIDs: Set<AISegmentID> = []
    private var draftRevision = 0
    private var draftTitle: String?
    private var draft: [StagedAIHighlight] = []

    init(
        registry: AISegmentRegistry,
        intent: AIHighlightIntent,
        searcher: any AISegmentSearching = AISimpleLexicalSearcher(),
        limits: AIHighlightToolLimits = AIHighlightToolLimits()
    ) {
        self.registry = registry
        self.intent = intent
        self.searcher = searcher
        self.limits = limits
    }

    func execute(_ call: AIHighlightToolCall) -> AIHighlightToolOutput {
        switch call {
        case .getDocumentMap(let scope):
            return .documentMap(registry.documentMap(scope: scope))
        case .searchSegments(let request):
            return .searchResults(search(request))
        case .readSegments(let request):
            return .readResults(read(request))
        case .stageHighlights(let request):
            return .staged(stage(request))
        }
    }

    func currentDraft() -> (revision: Int, title: String?, items: [StagedAIHighlight]) {
        (draftRevision, draftTitle, draft)
    }

    private func search(_ request: AISegmentSearchRequest) -> [AISegmentSearchResult] {
        let bounded = AISegmentSearchRequest(
            query: request.query,
            scope: request.scope,
            topK: min(max(1, request.topK), limits.maximumSearchResults),
            strategy: request.strategy
        )
        return searcher.search(bounded, in: registry)
    }

    private func read(_ request: AIReadSegmentsRequest) -> [AIReadSegment] {
        let selectedIDs = Array(request.ids.prefix(limits.maximumReadSelectors))
        let records = registry.neighboringRecords(
            around: selectedIDs,
            before: min(max(0, request.contextBefore), limits.maximumReadContext),
            after: min(max(0, request.contextAfter), limits.maximumReadContext)
        )
        let requested = Set(selectedIDs)
        readSegmentIDs.formUnion(records.map(\.id))
        return records.map {
            AIReadSegment(
                id: $0.id,
                text: $0.text,
                sourceKind: $0.sourceKind,
                sourceConfidence: $0.sourceConfidence,
                explicitlyRequested: requested.contains($0.id)
            )
        }
    }

    private func stage(_ request: AIStageHighlightsRequest) -> AIStageHighlightsResult {
        guard request.draftRevision == draftRevision else {
            return AIStageHighlightsResult(
                applied: false,
                revision: draftRevision,
                items: [],
                error: .staleRevision
            )
        }

        guard request.items.count <= limits.maximumDraftItems else {
            return AIStageHighlightsResult(
                applied: false,
                revision: draftRevision,
                items: request.items.map {
                    AIStageItemStatus(candidateID: $0.candidateID, code: .limitExceeded)
                },
                error: nil
            )
        }

        var candidateIDs: Set<String> = []
        var claimedSegments: Set<AISegmentID> = []
        var accepted: [StagedAIHighlight] = []
        var statuses: [AIStageItemStatus] = []

        for candidate in request.items {
            let code = validate(
                candidate,
                candidateIDs: &candidateIDs,
                claimedSegments: &claimedSegments
            )
            statuses.append(AIStageItemStatus(candidateID: candidate.candidateID, code: code))
            guard code == .accepted,
                  let first = candidate.segmentIDs.first,
                  let record = registry.record(for: first)
            else {
                continue
            }
            accepted.append(
                StagedAIHighlight(
                    candidate: candidate,
                    pageNumber: first.page,
                    sourceKind: record.sourceKind
                )
            )
        }

        guard statuses.allSatisfy({ $0.code == .accepted }) else {
            return AIStageHighlightsResult(
                applied: false,
                revision: draftRevision,
                items: statuses,
                error: .invalidItems
            )
        }

        draftTitle = AIHighlightGroupTitle.normalized(request.title)
        draft = accepted
        draftRevision += 1
        return AIStageHighlightsResult(
            applied: true,
            revision: draftRevision,
            items: statuses,
            error: nil
        )
    }

    private func validate(
        _ candidate: AIHighlightCandidate,
        candidateIDs: inout Set<String>,
        claimedSegments: inout Set<AISegmentID>
    ) -> AIStageItemStatusCode {
        let trimmedCandidateID = candidate.candidateID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedCandidateID.isEmpty,
              trimmedCandidateID.count <= limits.maximumCandidateIDLength,
              candidateIDs.insert(trimmedCandidateID).inserted
        else {
            return .invalidCandidateID
        }
        guard (1...limits.maximumSegmentsPerHighlight).contains(candidate.segmentIDs.count),
              isContiguous(candidate.segmentIDs)
        else {
            return .invalidSequence
        }
        let records = candidate.segmentIDs.compactMap { registry.record(for: $0) }
        guard records.count == candidate.segmentIDs.count else {
            return .notFound
        }
        guard candidate.segmentIDs.allSatisfy(readSegmentIDs.contains) else {
            return .unread
        }
        guard records.allSatisfy({ $0.sourceKind != .visualText }) else {
            return .unsupportedSource
        }
        guard records.allSatisfy({ record in
            record.sourceKind != .ocrText
                || (record.sourceConfidence ?? 0) >= limits.minimumOCRConfidence
        }) else {
            return .lowOCRConfidence
        }
        guard Set(candidate.segmentIDs).isDisjoint(with: claimedSegments) else {
            return .duplicate
        }
        guard categories(for: intent).contains(candidate.category) else {
            return .invalidCategory
        }
        guard (1...5).contains(candidate.importance) else {
            return .invalidImportance
        }
        guard candidate.note?.count ?? 0 <= limits.maximumNoteLength else {
            return .noteTooLong
        }

        claimedSegments.formUnion(candidate.segmentIDs)
        return .accepted
    }

    private func isContiguous(_ ids: [AISegmentID]) -> Bool {
        guard let first = ids.first else { return false }
        for (offset, id) in ids.enumerated() {
            guard id.document == first.document,
                  id.page == first.page,
                  id.block == first.block,
                  id.sentence == first.sentence + offset
            else {
                return false
            }
        }
        return true
    }

    private func categories(for intent: AIHighlightIntent) -> Set<AIHighlightCategory> {
        switch intent {
        case .overview:
            return [
                .keyFinding, .definition, .method, .evidence, .conclusion,
                .limitation, .caveat
            ]
        case .question:
            return [
                .directAnswer, .supportingEvidence, .counterEvidence, .definition,
                .limitation
            ]
        }
    }
}
