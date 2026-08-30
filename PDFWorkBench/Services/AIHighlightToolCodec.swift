import Foundation

nonisolated enum AIHighlightToolName {
    static let documentMap = "get_document_map"
    static let searchSegments = "search_segments"
    static let readSegments = "read_segments"
    static let stageHighlights = "stage_highlights"
}

nonisolated enum AIHighlightToolCodecError: LocalizedError, Equatable {
    case unknownTool(String)
    case invalidPageRange
    case invalidSegmentID(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown AI highlight tool: \(name)."
        case .invalidPageRange:
            return "The requested page range is invalid."
        case .invalidSegmentID(let value):
            return "Invalid segment ID: \(value)."
        }
    }
}

nonisolated struct AIHighlightToolCodec: Sendable {
    static let definitions: [AIToolDefinition] = [
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
            description: "Search segment IDs. For an overview, use strategy overviewSalience with an empty query to obtain locally ranked, page-distributed candidates. Results contain IDs and scores, not source text.",
            schema: """
            {
              "type": "object",
              "properties": {
                "query": {"type": "string"},
                "page_start": {"type": "integer", "minimum": 1},
                "page_end": {"type": "integer", "minimum": 1},
                "top_k": {"type": "integer", "minimum": 1, "maximum": 100},
                "strategy": {
                  "type": "string",
                  "enum": ["fullText", "overviewSalience", "questionRelevance"]
                }
              },
              "required": ["query", "page_start", "page_end", "top_k", "strategy"],
              "additionalProperties": false
            }
            """
        ),
        definition(
            name: AIHighlightToolName.readSegments,
            description: "Read exact source text for selected segment IDs and bounded neighboring context.",
            schema: """
            {
              "type": "object",
              "properties": {
                "ids": {
                  "type": "array",
                  "items": {"type": "string", "pattern": "^D[0-9]{3,}\\\\.P[0-9]{3,}\\\\.B[0-9]{3,}\\\\.S[0-9]{3,}$"},
                  "minItems": 1,
                  "maxItems": 24
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
            description: "Atomically replace the verified draft and assign it a concise title. Every segment must have been returned by read_segments.",
            schemaVersion: "2",
            schema: """
            {
              "type": "object",
              "properties": {
                "draft_revision": {"type": "integer", "minimum": 0},
                "title": {"type": "string", "minLength": 1, "maxLength": 60},
                "items": {
                  "type": "array",
                  "maxItems": 15,
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
                      "category": {
                        "type": "string",
                        "enum": ["keyFinding", "definition", "method", "evidence", "conclusion", "limitation", "caveat", "directAnswer", "supportingEvidence", "counterEvidence"]
                      },
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
        )
    ]

    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init() {
        decoder = JSONDecoder()
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
    }

    func decode(_ invocation: AIToolInvocation) throws -> AIHighlightToolCall {
        switch invocation.name {
        case AIHighlightToolName.documentMap:
            let arguments = try decoder.decode(PageRangeArguments.self, from: invocation.arguments)
            return .getDocumentMap(scope: try scope(from: arguments))
        case AIHighlightToolName.searchSegments:
            let arguments = try decoder.decode(SearchArguments.self, from: invocation.arguments)
            return .searchSegments(
                AISegmentSearchRequest(
                    query: arguments.query,
                    scope: try scope(from: arguments.pageRange),
                    topK: arguments.topK,
                    strategy: arguments.strategy
                )
            )
        case AIHighlightToolName.readSegments:
            let arguments = try decoder.decode(ReadArguments.self, from: invocation.arguments)
            return .readSegments(
                AIReadSegmentsRequest(
                    ids: try arguments.ids.map(parseSegmentID),
                    contextBefore: arguments.contextBefore,
                    contextAfter: arguments.contextAfter
                )
            )
        case AIHighlightToolName.stageHighlights:
            let arguments = try decoder.decode(StageArguments.self, from: invocation.arguments)
            let candidates = try arguments.items.map { item in
                AIHighlightCandidate(
                    candidateID: item.candidateID,
                    segmentIDs: try item.segmentIDs.map(parseSegmentID),
                    category: item.category,
                    importance: item.importance,
                    note: item.note
                )
            }
            return .stageHighlights(
                AIStageHighlightsRequest(
                    draftRevision: arguments.draftRevision,
                    title: arguments.title,
                    items: candidates
                )
            )
        default:
            throw AIHighlightToolCodecError.unknownTool(invocation.name)
        }
    }

    func encode(_ output: AIHighlightToolOutput) throws -> Data {
        switch output {
        case .documentMap(let value):
            return try encoder.encode(value)
        case .searchResults(let value):
            return try encoder.encode(value)
        case .readResults(let value):
            return try encoder.encode(value)
        case .staged(let value):
            return try encoder.encode(value)
        }
    }

    func readCharacterCount(in output: AIHighlightToolOutput) -> Int {
        guard case .readResults(let records) = output else { return 0 }
        return records.reduce(0) { $0 + $1.text.count }
    }

    private func scope(from arguments: PageRangeArguments) throws -> AISegmentScope {
        guard arguments.pageStart > 0, arguments.pageEnd >= arguments.pageStart else {
            throw AIHighlightToolCodecError.invalidPageRange
        }
        return AISegmentScope(pageRange: arguments.pageStart...arguments.pageEnd)
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

    private struct PageRangeArguments: Decodable {
        let pageStart: Int
        let pageEnd: Int

        private enum CodingKeys: String, CodingKey {
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

        var pageRange: PageRangeArguments {
            PageRangeArguments(pageStart: pageStart, pageEnd: pageEnd)
        }

        private enum CodingKeys: String, CodingKey {
            case query, strategy
            case pageStart = "page_start"
            case pageEnd = "page_end"
            case topK = "top_k"
        }
    }

    private struct ReadArguments: Decodable {
        let ids: [String]
        let contextBefore: Int
        let contextAfter: Int

        private enum CodingKeys: String, CodingKey {
            case ids
            case contextBefore = "context_before"
            case contextAfter = "context_after"
        }
    }

    private struct StageArguments: Decodable {
        let draftRevision: Int
        let title: String
        let items: [StageItem]

        private enum CodingKeys: String, CodingKey {
            case draftRevision = "draft_revision"
            case title
            case items
        }
    }

    private struct StageItem: Decodable {
        let candidateID: String
        let segmentIDs: [String]
        let category: AIHighlightCategory
        let importance: Int
        let note: String?

        private enum CodingKeys: String, CodingKey {
            case candidateID = "candidate_id"
            case segmentIDs = "segment_ids"
            case category, importance, note
        }
    }
}

extension AIHighlightToolExecutor: AIToolExecuting {
    func execute(_ invocation: AIToolInvocation) async throws -> AIToolExecutionResult {
        let codec = AIHighlightToolCodec()
        let call = try codec.decode(invocation)
        let result = execute(call)
        return AIToolExecutionResult(
            callID: invocation.callID,
            output: try codec.encode(result),
            readCharacterCount: codec.readCharacterCount(in: result)
        )
    }
}
