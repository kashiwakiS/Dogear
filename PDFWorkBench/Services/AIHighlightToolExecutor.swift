import Foundation

nonisolated enum AIHighlightToolCall: Equatable, Sendable {
    case getDocumentMap(scope: AISegmentScope)
    case searchSegments(AISegmentSearchRequest)
    case readSegments(AIReadSegmentsRequest)
    case stageHighlights(AIStageHighlightsRequest)
    case publishAnswer(AIPublishAnswerRequest)
}

nonisolated enum AIHighlightToolOutput: Equatable, Sendable {
    case documentMap(AIDocumentMap)
    case searchResults([AISegmentSearchResult])
    case readResults(AIReadSegmentsResult)
    case staged(AIStageHighlightsResult)
    case answerPublished(AIPublishAnswerResult)
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
    let policy: AIHighlightIntentPolicy

    private let searcher: any AISegmentSearching
    private let evidenceRetriever: (any AIEvidenceRetrieving)?
    private let limits: AIHighlightToolLimits
    private var readSegmentIDs: Set<AISegmentID> = []
    private var draftRevision = 0
    private var draftTitle: String?
    private var draft: [StagedAIHighlight] = []
    private var latestPublication: AIPublishedAnswer?
    let verifiesAnswerEvidence: Bool
    var evidenceReviewAttempts = 0
    var reviewedEvidenceIDs: Set<String> = []
    var approvedTerminalRequest: AIPublishAnswerRequest?
    private var cachedSearches: [(AISegmentSearchRequest, [AISegmentSearchResult])] = []

    init(
        registry: AISegmentRegistry,
        intent: AIHighlightIntent,
        policy: AIHighlightIntentPolicy? = nil,
        searcher: any AISegmentSearching = AISimpleLexicalSearcher(),
        limits: AIHighlightToolLimits = AIHighlightToolLimits(),
        evidenceRetriever: (any AIEvidenceRetrieving)? = nil,
        verifiesAnswerEvidence: Bool = false
    ) {
        self.registry = registry
        self.intent = intent
        self.policy = policy ?? .make(for: intent)
        self.searcher = searcher
        self.limits = limits
        self.evidenceRetriever = evidenceRetriever
        self.verifiesAnswerEvidence = verifiesAnswerEvidence
    }

    /// The async production boundary supports local model inference. Existing
    /// synchronous fixtures retain their deterministic lexical executor.
    func executeForWorkflow(_ call: AIHighlightToolCall) async throws -> AIHighlightToolOutput {
        if case .searchSegments(let request) = call, let evidenceRetriever {
            let bounded = AISegmentSearchRequest(query: request.query, scope: request.scope,
                topK: min(max(1, request.topK), limits.maximumSearchResults), strategy: request.strategy)
            if let cached = cachedSearches.first(where: { $0.0 == bounded }) { return .searchResults(cached.1) }
            let results = try await evidenceRetriever.search(bounded)
            try Task.checkCancellation()
            cachedSearches.append((bounded, results))
            return .searchResults(results)
        }
        return execute(call)
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
        case .publishAnswer(let request):
            return .answerPublished(publish(request))
        }
    }

    func currentDraft() -> (revision: Int, title: String?, items: [StagedAIHighlight]) {
        (draftRevision, draftTitle, draft)
    }

    func reviewRecords() -> [AISegmentRecord] {
        registry.records.filter { readSegmentIDs.contains($0.id) }
    }

    func completedAnswer() -> AIPublishedAnswer? {
        guard let latestPublication,
              latestPublication.terminate,
              latestPublication.finalDraftRevision == draftRevision
        else {
            return nil
        }
        return latestPublication
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

    private func read(_ request: AIReadSegmentsRequest) -> AIReadSegmentsResult {
        var seenSelectors: Set<AISegmentID> = []
        let uniqueIDs = request.ids.filter { seenSelectors.insert($0).inserted }
        let selectedIDs = Array(uniqueIDs.prefix(limits.maximumReadSelectors))
        let records = registry.neighboringRecords(
            around: selectedIDs,
            before: min(max(0, request.contextBefore), limits.maximumReadContext),
            after: min(max(0, request.contextAfter), limits.maximumReadContext)
        )
        let requested = Set(selectedIDs)
        let alreadyReadIDs = records.map(\.id).filter(readSegmentIDs.contains)
        let newRecords = records.filter { !readSegmentIDs.contains($0.id) }
        readSegmentIDs.formUnion(newRecords.map(\.id))
        return AIReadSegmentsResult(
            readIDs: newRecords.map(\.id),
            alreadyReadIDs: alreadyReadIDs,
            segments: newRecords.map {
            AIReadSegment(
                id: $0.id,
                text: $0.text,
                sourceKind: $0.sourceKind,
                sourceConfidence: $0.sourceConfidence,
                explicitlyRequested: requested.contains($0.id)
            )
            },
            omittedIDs: Array(uniqueIDs.dropFirst(limits.maximumReadSelectors)),
            missingIDs: selectedIDs.filter { registry.record(for: $0) == nil }
        )
    }

    private func stage(_ request: AIStageHighlightsRequest) -> AIStageHighlightsResult {
        guard policy.allowsAnnotations || request.items.isEmpty else {
            return AIStageHighlightsResult(applied: false, revision: draftRevision,
                items: [], error: .annotationsForbidden)
        }
        guard request.draftRevision == draftRevision else {
            return AIStageHighlightsResult(
                applied: false,
                revision: draftRevision,
                items: [],
                error: .staleRevision
            )
        }

        guard request.items.count <= min(
            limits.maximumDraftItems,
            policy.maximumDraftItems
        ) else {
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
            let status = validate(
                candidate,
                candidateIDs: &candidateIDs,
                claimedSegments: &claimedSegments
            )
            statuses.append(status)
            guard status.code == .accepted,
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

        let normalizedTitle = AIHighlightGroupTitle.normalized(request.title)
        if normalizedTitle == draftTitle,
           semanticallyEqual(accepted, draft)
        {
            return AIStageHighlightsResult(
                applied: true,
                revision: draftRevision,
                items: statuses,
                error: nil,
                unchanged: true
            )
        }

        draftTitle = normalizedTitle
        draft = accepted
        draftRevision += 1
        return AIStageHighlightsResult(
            applied: true,
            revision: draftRevision,
            items: statuses,
            error: nil
        )
    }

    private func semanticallyEqual(
        _ lhs: [StagedAIHighlight],
        _ rhs: [StagedAIHighlight]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.candidate.segmentIDs == right.candidate.segmentIDs
                && left.candidate.category == right.candidate.category
                && left.candidate.importance == right.candidate.importance
                && left.candidate.note?.trimmingCharacters(in: .whitespacesAndNewlines)
                    == right.candidate.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func validate(
        _ candidate: AIHighlightCandidate,
        candidateIDs: inout Set<String>,
        claimedSegments: inout Set<AISegmentID>
    ) -> AIStageItemStatus {
        func status(
            _ code: AIStageItemStatusCode,
            missingReadIDs: [AISegmentID]? = nil
        ) -> AIStageItemStatus {
            AIStageItemStatus(
                candidateID: candidate.candidateID,
                code: code,
                missingReadIDs: missingReadIDs
            )
        }
        let trimmedCandidateID = candidate.candidateID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedCandidateID.isEmpty,
              trimmedCandidateID.count <= limits.maximumCandidateIDLength,
              candidateIDs.insert(trimmedCandidateID).inserted
        else {
            return status(.invalidCandidateID)
        }
        guard (1...limits.maximumSegmentsPerHighlight).contains(candidate.segmentIDs.count),
              isContiguous(candidate.segmentIDs)
        else {
            return status(.invalidSequence)
        }
        let records = candidate.segmentIDs.compactMap { registry.record(for: $0) }
        guard records.count == candidate.segmentIDs.count else {
            return status(.notFound)
        }
        let missingReadIDs = candidate.segmentIDs.filter { !readSegmentIDs.contains($0) }
        guard missingReadIDs.isEmpty else {
            return status(.unread, missingReadIDs: missingReadIDs)
        }
        guard records.allSatisfy({ $0.sourceKind != .visualText }) else {
            return status(.unsupportedSource)
        }
        guard records.allSatisfy({ record in
            record.sourceKind != .ocrText
                || (record.sourceConfidence ?? 0) >= limits.minimumOCRConfidence
        }) else {
            return status(.lowOCRConfidence)
        }
        guard Set(candidate.segmentIDs).isDisjoint(with: claimedSegments) else {
            return status(.duplicate)
        }
        guard policy.allowedCategories.contains(candidate.category) else {
            return status(.invalidCategory)
        }
        guard (1...5).contains(candidate.importance) else {
            return status(.invalidImportance)
        }
        guard candidate.note?.count ?? 0 <= limits.maximumNoteLength else {
            return status(.noteTooLong)
        }

        claimedSegments.formUnion(candidate.segmentIDs)
        return status(.accepted)
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

    func publish(_ request: AIPublishAnswerRequest, validateOnly: Bool = false) -> AIPublishAnswerResult {
        if verifiesAnswerEvidence && request.terminate && !validateOnly && approvedTerminalRequest != request {
            return publicationFailure(.evidenceReviewRequired)
        }
        guard let title = AIHighlightGroupTitle.normalized(request.title) else {
            return publicationFailure(.emptyTitle)
        }
        let markdown = request.resultMarkdown.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !markdown.isEmpty else {
            return publicationFailure(.emptyResult)
        }
        guard request.finalDraftRevision == draftRevision else {
            return publicationFailure(.staleDraftRevision)
        }
        let missingEvidence = request.evidenceSegmentIDs.filter {
            registry.record(for: $0) == nil
        }
        guard missingEvidence.isEmpty else {
            return publicationFailure(.missingEvidence, missingReadIDs: missingEvidence)
        }
        let unreadEvidence = request.evidenceSegmentIDs.filter {
            !readSegmentIDs.contains($0)
        }
        guard unreadEvidence.isEmpty else {
            return publicationFailure(.unreadEvidence, missingReadIDs: unreadEvidence)
        }
        if request.completionStatus != .notFound,
           request.evidenceSegmentIDs.isEmpty
        {
            return publicationFailure(.missingEvidence)
        }
        let highlightedIDs = Set(draft.flatMap { $0.candidate.segmentIDs })
        guard highlightedIDs.isSubset(of: Set(request.evidenceSegmentIDs)) else {
            return publicationFailure(.highlightsNotCoveredByEvidence)
        }

        let publication = AIPublishedAnswer(
            completionStatus: request.completionStatus,
            title: title,
            resultMarkdown: markdown,
            evidenceSegmentIDs: request.evidenceSegmentIDs,
            finalDraftRevision: request.finalDraftRevision,
            terminate: request.terminate
        )
        if !validateOnly { latestPublication = publication }
        return AIPublishAnswerResult(
            accepted: true,
            error: nil,
            currentDraftRevision: draftRevision,
            missingReadIDs: [],
            publication: publication
        )
    }

    func publicationFailure(
        _ error: AIPublishAnswerErrorCode,
        missingReadIDs: [AISegmentID] = []
    ) -> AIPublishAnswerResult {
        AIPublishAnswerResult(
            accepted: false,
            error: error,
            currentDraftRevision: draftRevision,
            missingReadIDs: missingReadIDs,
            publication: nil
        )
    }
}
