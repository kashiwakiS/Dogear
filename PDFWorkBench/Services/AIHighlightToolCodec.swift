import Foundation

nonisolated enum AIHighlightToolName {
    static let documentMap = "get_document_map"
    static let searchSegments = "search_segments"
    static let readSegments = "read_segments"
    static let stageHighlights = "stage_highlights"
    static let publishAnswer = "publish_answer"
}

nonisolated enum AIHighlightToolCodecError: LocalizedError, Equatable {
    case unknownTool(String)
    case invalidPageRange
    case invalidSegmentID(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "Unknown AI reading tool: \(name)."
        case .invalidPageRange: return "The requested page range is invalid."
        case .invalidSegmentID(let value): return "Invalid segment ID: \(value)."
        }
    }
}

nonisolated struct AIHighlightToolCodec: Sendable {
    static var definitions: [AIToolDefinition] {
        definitions(for: .make(for: .overview))
    }

    static func definitions(for policy: AIHighlightIntentPolicy) -> [AIToolDefinition] {
        [
            definition(
                name: AIHighlightToolName.documentMap,
                description: "Return the document hierarchy without returning source text.",
                schema: """
                {
                  "type": "object",
                  "properties": {
                    "page_start": {"type": "integer", "minimum": 1},
                    "page_end": {"type": "integer", "minimum": 1}
                  },
                  "required": ["page_start", "page_end"],
                  "additionalProperties": false
                }
                """
            ),
            definition(
                name: AIHighlightToolName.searchSegments,
                description: "Search segment IDs. Results contain IDs and scores, never source text. Use overviewSalience with an empty query for a page-distributed overview.",
                schema: """
                {
                  "type": "object",
                  "properties": {
                    "query": {"type": "string"},
                    "page_start": {"type": "integer", "minimum": 1},
                    "page_end": {"type": "integer", "minimum": 1},
                    "top_k": {"type": "integer", "minimum": 1, "maximum": 100},
                    "strategy": {"type": "string", "enum": ["fullText", "overviewSalience", "questionRelevance"]}
                  },
                  "required": ["query", "page_start", "page_end", "top_k", "strategy"],
                  "additionalProperties": false
                }
                """
            ),
            definition(
                name: AIHighlightToolName.readSegments,
                description: "Read exact source text for selected segment IDs and bounded neighboring context. Previously returned passages are not sent again.",
                schemaVersion: "2",
                schema: """
                {
                  "type": "object",
                  "properties": {
                    "ids": {
                      "type": "array",
                      "items": {"type": "string", "pattern": "^D[0-9]{3,}\\\\.P[0-9]{3,}\\\\.B[0-9]{3,}\\\\.S[0-9]{3,}$"},
                      "minItems": 1,
                      "maxItems": 24,
                      "uniqueItems": true
                    },
                    "context_before": {"type": "integer", "minimum": 0, "maximum": 3},
                    "context_after": {"type": "integer", "minimum": 0, "maximum": 3}
                  },
                  "required": ["ids", "context_before", "context_after"],
                  "additionalProperties": false
                }
                """
            ),
            definition(
                name: AIHighlightToolName.stageHighlights,
                description: "Atomically replace the complete optional highlight draft. Each highlight uses 1–3 ordered consecutive sentence IDs from one document, page, and block. Every ID must have been returned by read_segments. Repair by resubmitting the complete draft, not a patch.",
                schemaVersion: "3",
                schema: """
                {
                  "type": "object",
                  "properties": {
                    "draft_revision": {"type": "integer", "minimum": 0},
                    "title": {"type": "string", "minLength": 1, "maxLength": 60},
                    "items": {
                      "type": "array",
                      "maxItems": \(policy.maximumDraftItems),
                      "items": {
                        "type": "object",
                        "properties": {
                          "candidate_id": {"type": "string", "minLength": 1, "maxLength": 64},
                          "segment_ids": {
                            "type": "array",
                            "items": {"type": "string"},
                            "minItems": 1,
                            "maxItems": 3
                          },
                          "category": {"type": "string", "enum": [\(categoryJSON(for: policy))]},
                          "importance": {"type": "integer", "minimum": 1, "maximum": 5},
                          "note": {"type": ["string", "null"], "maxLength": 500}
                        },
                        "required": ["candidate_id", "segment_ids", "category", "importance", "note"],
                        "additionalProperties": false
                      }
                    }
                  },
                  "required": ["draft_revision", "title", "items"],
                  "additionalProperties": false
                }
                """
            ),
            definition(
                name: AIHighlightToolName.publishAnswer,
                description: "Publish evidence-grounded Markdown in Ask. Set terminate false for an interim update. Complete all searches, reads, and optional stage_highlights calls and inspect their results BEFORE finishing. The final provider turn must contain ONLY one publish_answer with terminate true. Mixed terminal batches are rejected before publication; accepted termination ends locally with no further provider request.",
                schemaVersion: "2",
                schema: """
                {
                  "type": "object",
                  "properties": {
                    "completion_status": {"type": "string", "enum": ["answered", "partial", "notFound"]},
                    "title": {"type": "string", "minLength": 1, "maxLength": 60},
                    "result_markdown": {"type": "string", "minLength": 1},
                    "evidence_segment_ids": {
                      "type": "array",
                      "items": {"type": "string"},
                      "maxItems": 48,
                      "uniqueItems": true
                    },
                    "final_draft_revision": {"type": "integer", "minimum": 0},
                    "terminate": {"type": "boolean"}
                  },
                  "required": ["completion_status", "title", "result_markdown", "evidence_segment_ids", "final_draft_revision", "terminate"],
                  "additionalProperties": false
                }
                """
            )
        ]
    }

    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init() {
        decoder = JSONDecoder()
        // Wire keys are explicit: convertFromSnakeCase turns `segment_ids` into
        // `segmentIds`, which cannot match Swift's `segmentIDs` properties.
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
    }

    func decode(_ invocation: AIToolInvocation) throws -> AIHighlightToolCall {
        switch invocation.name {
        case AIHighlightToolName.documentMap:
            let value = try decoder.decode(PageRangeArguments.self, from: invocation.arguments)
            return .getDocumentMap(scope: try scope(from: value))
        case AIHighlightToolName.searchSegments:
            let value = try decoder.decode(SearchArguments.self, from: invocation.arguments)
            return .searchSegments(
                AISegmentSearchRequest(
                    query: value.query,
                    scope: try scope(from: value.pageRange),
                    topK: value.topK,
                    strategy: value.strategy
                )
            )
        case AIHighlightToolName.readSegments:
            let value = try decoder.decode(ReadArguments.self, from: invocation.arguments)
            return .readSegments(
                AIReadSegmentsRequest(
                    ids: try value.ids.map(parseSegmentID),
                    contextBefore: value.contextBefore,
                    contextAfter: value.contextAfter
                )
            )
        case AIHighlightToolName.stageHighlights:
            let value = try decoder.decode(StageArguments.self, from: invocation.arguments)
            return .stageHighlights(
                AIStageHighlightsRequest(
                    draftRevision: value.draftRevision,
                    title: value.title,
                    items: try value.items.map { item in
                        AIHighlightCandidate(
                            candidateID: item.candidateID,
                            segmentIDs: try item.segmentIDs.map(parseSegmentID),
                            category: item.category,
                            importance: item.importance,
                            note: item.note
                        )
                    }
                )
            )
        case AIHighlightToolName.publishAnswer:
            let value = try decoder.decode(PublishAnswerArguments.self, from: invocation.arguments)
            return .publishAnswer(
                AIPublishAnswerRequest(
                    completionStatus: value.completionStatus,
                    title: value.title,
                    resultMarkdown: value.resultMarkdown,
                    evidenceSegmentIDs: try value.evidenceSegmentIDs.map(parseSegmentID),
                    finalDraftRevision: value.finalDraftRevision,
                    terminate: value.terminate
                )
            )
        default:
            throw AIHighlightToolCodecError.unknownTool(invocation.name)
        }
    }

    func encode(_ output: AIHighlightToolOutput) throws -> Data {
        switch output {
        case .documentMap(let value): return try encoder.encode(value)
        case .searchResults(let value): return try encoder.encode(value)
        case .readResults(let value): return try encoder.encode(ReadResult(value))
        case .staged(let value): return try encoder.encode(StageResult(value))
        case .answerPublished(let value): return try encoder.encode(PublishAnswerResult(value))
        }
    }

    func decodePublishResult(_ data: Data) throws -> AIPublishAnswerResult {
        let value = try decoder.decode(PublishAnswerResult.self, from: data)
        return AIPublishAnswerResult(
            accepted: value.accepted,
            error: value.error,
            currentDraftRevision: value.currentDraftRevision,
            missingReadIDs: value.missingReadIDs,
            publication: try value.publication.map { publication in
                AIPublishedAnswer(
                    completionStatus: publication.completionStatus,
                    title: publication.title,
                    resultMarkdown: publication.resultMarkdown,
                    evidenceSegmentIDs: try publication.evidenceSegmentIDs.map(parseSegmentID),
                    finalDraftRevision: publication.finalDraftRevision,
                    terminate: publication.terminate
                )
            },
            reviewIssues: value.reviewIssues ?? []
        )
    }

    func readCharacterCount(in output: AIHighlightToolOutput) -> Int {
        guard case .readResults(let value) = output else { return 0 }
        return value.segments.reduce(0) { $0 + $1.text.count }
    }

    private func scope(from value: PageRangeArguments) throws -> AISegmentScope {
        guard value.pageStart > 0, value.pageEnd >= value.pageStart else {
            throw AIHighlightToolCodecError.invalidPageRange
        }
        return AISegmentScope(pageRange: value.pageStart...value.pageEnd)
    }

    private func parseSegmentID(_ value: String) throws -> AISegmentID {
        guard let id = AISegmentID(value) else {
            throw AIHighlightToolCodecError.invalidSegmentID(value)
        }
        return id
    }

    private static func definition(
        name: String,
        description: String,
        schemaVersion: String = "1",
        schema: String
    ) -> AIToolDefinition {
        AIToolDefinition(
            name: name,
            description: description,
            schemaVersion: schemaVersion,
            strictInputSchema: Data(schema.utf8)
        )
    }

    private static func categoryJSON(for policy: AIHighlightIntentPolicy) -> String {
        policy.allowedCategories.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
    }

    private struct PageRangeArguments: Decodable {
        let pageStart: Int
        let pageEnd: Int

        enum CodingKeys: String, CodingKey {
            case pageStart = "page_start"
            case pageEnd = "page_end"
        }
    }

    private struct SearchArguments: Decodable {
        let query: String
        let pageStart: Int
        let pageEnd: Int
        let topK: Int
        let strategy: AISegmentSearchStrategy

        enum CodingKeys: String, CodingKey {
            case query, strategy
            case pageStart = "page_start"
            case pageEnd = "page_end"
            case topK = "top_k"
        }

        var pageRange: PageRangeArguments {
            PageRangeArguments(pageStart: pageStart, pageEnd: pageEnd)
        }
    }

    private struct ReadArguments: Decodable {
        let ids: [String]
        let contextBefore: Int
        let contextAfter: Int

        enum CodingKeys: String, CodingKey {
            case ids
            case contextBefore = "context_before"
            case contextAfter = "context_after"
        }
    }

    private struct StageArguments: Decodable {
        let draftRevision: Int
        let title: String
        let items: [StageItem]

        enum CodingKeys: String, CodingKey {
            case title, items
            case draftRevision = "draft_revision"
        }
    }

    private struct StageItem: Decodable {
        let candidateID: String
        let segmentIDs: [String]
        let category: AIHighlightCategory
        let importance: Int
        let note: String?

        enum CodingKeys: String, CodingKey {
            case category, importance, note
            case candidateID = "candidate_id"
            case segmentIDs = "segment_ids"
        }
    }

    private struct ReadResult: Encodable {
        let readIDs: [AISegmentID]
        let alreadyReadIDs: [AISegmentID]
        let segments: [AIReadSegment]
        let omittedIDs: [AISegmentID]
        let missingIDs: [AISegmentID]

        init(_ value: AIReadSegmentsResult) {
            readIDs = value.readIDs
            omittedIDs = value.omittedIDs
            missingIDs = value.missingIDs
            alreadyReadIDs = value.alreadyReadIDs
            segments = value.segments
        }

        enum CodingKeys: String, CodingKey {
            case segments
            case readIDs = "read_ids"
            case alreadyReadIDs = "already_read_ids"
            case omittedIDs = "omitted_ids"
            case missingIDs = "missing_ids"
        }
    }

    private struct StageResult: Encodable {
        let applied: Bool
        let revision: Int
        let items: [StageItemResult]
        let error: AIStageBatchErrorCode?
        let unchanged: Bool

        init(_ value: AIStageHighlightsResult) {
            applied = value.applied
            revision = value.revision
            items = value.items.map(StageItemResult.init)
            error = value.error
            unchanged = value.unchanged
        }
    }

    private struct StageItemResult: Encodable {
        let candidateID: String
        let code: AIStageItemStatusCode
        let missingReadIDs: [AISegmentID]?

        init(_ value: AIStageItemStatus) {
            candidateID = value.candidateID
            code = value.code
            missingReadIDs = value.missingReadIDs
        }

        enum CodingKeys: String, CodingKey {
            case code
            case candidateID = "candidate_id"
            case missingReadIDs = "missing_read_ids"
        }
    }

    private struct PublishAnswerArguments: Codable {
        let completionStatus: AIAnswerCompletionStatus
        let title: String
        let resultMarkdown: String
        let evidenceSegmentIDs: [String]
        let finalDraftRevision: Int
        let terminate: Bool

        init(_ value: AIPublishedAnswer) {
            completionStatus = value.completionStatus
            title = value.title
            resultMarkdown = value.resultMarkdown
            evidenceSegmentIDs = value.evidenceSegmentIDs.map(\.description)
            finalDraftRevision = value.finalDraftRevision
            terminate = value.terminate
        }

        enum CodingKeys: String, CodingKey {
            case title, terminate
            case completionStatus = "completion_status"
            case resultMarkdown = "result_markdown"
            case evidenceSegmentIDs = "evidence_segment_ids"
            case finalDraftRevision = "final_draft_revision"
        }
    }

    private struct PublishAnswerResult: Codable {
        let accepted: Bool
        let error: AIPublishAnswerErrorCode?
        let currentDraftRevision: Int
        let missingReadIDs: [AISegmentID]
        let publication: PublishAnswerArguments?
        var reviewIssues: [String]?

        init(_ value: AIPublishAnswerResult) {
            accepted = value.accepted
            error = value.error
            currentDraftRevision = value.currentDraftRevision
            missingReadIDs = value.missingReadIDs
            publication = value.publication.map(PublishAnswerArguments.init)
            reviewIssues = value.reviewIssues.isEmpty ? nil : value.reviewIssues
        }

        enum CodingKeys: String, CodingKey {
            case accepted, error, publication
            case currentDraftRevision = "current_draft_revision"
            case missingReadIDs = "missing_read_ids"
            case reviewIssues = "review_issues"
        }
    }
}

extension AIHighlightToolExecutor: AIToolExecuting {
    func execute(_ invocation: AIToolInvocation, batchCount: Int) async throws -> AIToolExecutionResult {
        let codec = AIHighlightToolCodec()
        if batchCount > 1,
           case .publishAnswer(let request) = try codec.decode(invocation),
           request.terminate
        {
            return AIToolExecutionResult(
                callID: invocation.callID,
                output: try codec.encode(.answerPublished(AIPublishAnswerResult(
                    accepted: false,
                    error: .terminalMustBeSoleCall,
                    currentDraftRevision: currentDraft().revision,
                    missingReadIDs: [],
                    publication: nil
                ))),
                readCharacterCount: 0
            )
        }
        return try await execute(invocation)
    }

    func execute(_ invocation: AIToolInvocation) async throws -> AIToolExecutionResult {
        let codec = AIHighlightToolCodec()
        let call = try codec.decode(invocation)
        let result = try await executeForWorkflow(call)
        let disposition: AIToolExecutionDisposition
        if case .answerPublished(let value) = result,
           value.accepted,
           value.publication?.terminate == true
        {
            disposition = .requestTermination
        } else {
            disposition = .continueWorkflow
        }
        return AIToolExecutionResult(
            callID: invocation.callID,
            output: try codec.encode(result),
            readCharacterCount: codec.readCharacterCount(in: result),
            disposition: disposition
        )
    }
}
