import Foundation

/// Exercises the provider-facing JSON boundary, not only typed executor calls.
/// In particular, Foundation's automatic snake-case conversion cannot infer ID
/// acronyms, so typed-only fixtures would miss broken stage/publication calls.
nonisolated enum AIHighlightCodecDiagnostics {
    struct Report: Equatable, Sendable {
        let checks: Int
        let failures: [String]

        var succeeded: Bool { failures.isEmpty }
    }

    static func runWireContractChecks() -> Report {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }
        let codec = AIHighlightToolCodec()
        let id = AISegmentID(document: 1, page: 1, block: 1, sentence: 1)

        do {
            let map = try codec.decode(invocation(
                AIHighlightToolName.documentMap,
                ["page_start": 2, "page_end": 4]
            ))
            check(
                map == .getDocumentMap(scope: AISegmentScope(pageRange: 2...4)),
                "Map page-range wire keys did not decode."
            )
            let search = try codec.decode(invocation(
                AIHighlightToolName.searchSegments,
                [
                    "query": "neural network", "page_start": 1, "page_end": 3,
                    "top_k": 7, "strategy": "questionRelevance"
                ]
            ))
            check(
                search == .searchSegments(AISegmentSearchRequest(
                    query: "neural network", scope: AISegmentScope(pageRange: 1...3),
                    topK: 7, strategy: .questionRelevance
                )),
                "Search page range, top_k, query, or strategy did not decode."
            )
            let read = try codec.decode(invocation(
                AIHighlightToolName.readSegments,
                ["ids": [id.description], "context_before": 1, "context_after": 2]
            ))
            check(
                read == .readSegments(AIReadSegmentsRequest(
                    ids: [id], contextBefore: 1, contextAfter: 2
                )),
                "Read IDs or context bounds did not decode."
            )
            let stage = try codec.decode(invocation(
                AIHighlightToolName.stageHighlights, stageArguments(id: id)
            ))
            check(
                stage == .stageHighlights(AIStageHighlightsRequest(
                    draftRevision: 0,
                    title: "Network design",
                    items: [AIHighlightCandidate(
                        candidateID: "network-1", segmentIDs: [id],
                        category: .directAnswer, importance: 5, note: nil
                    )]
                )),
                "Stage candidate_id, segment_ids, or nullable note did not decode."
            )

            for terminate in [false, true] {
                let decoded = try codec.decode(invocation(
                    AIHighlightToolName.publishAnswer,
                    publishArguments(id: id, revision: 0, terminate: terminate)
                ))
                check(
                    decoded == .publishAnswer(AIPublishAnswerRequest(
                        completionStatus: .answered, title: "Network design",
                        resultMarkdown: "The network uses two layers [p. 1].",
                        evidenceSegmentIDs: [id], finalDraftRevision: 0,
                        terminate: terminate
                    )),
                    "Publish wire keys or terminate=\(terminate) did not decode."
                )

                let result = AIPublishAnswerResult(
                    accepted: true, error: nil, currentDraftRevision: 0,
                    missingReadIDs: [],
                    publication: AIPublishedAnswer(
                        completionStatus: .answered, title: "Network design",
                        resultMarkdown: "The network uses two layers [p. 1].",
                        evidenceSegmentIDs: [id], finalDraftRevision: 0,
                        terminate: terminate
                    )
                )
                let encoded = try codec.encode(.answerPublished(result))
                let decodedResult = try codec.decodePublishResult(encoded)
                check(decodedResult == result, "Publication result did not round-trip.")
                let root = try object(encoded)
                let publication = root["publication"] as? [String: Any]
                check(
                    publication?["evidence_segment_ids"] as? [String] == [id.description]
                        && root["missing_read_ids"] as? [String] == [],
                    "Publication output did not retain canonical snake_case ID keys."
                )
            }

            let rejected = AIPublishAnswerResult(
                accepted: false, error: .unreadEvidence, currentDraftRevision: 2,
                missingReadIDs: [id], publication: nil
            )
            let rejectedData = try codec.encode(.answerPublished(rejected))
            let rejectedRoundTrip = try codec.decodePublishResult(rejectedData)
            check(
                rejectedRoundTrip == rejected,
                "Rejected publication missing_read_ids or absent publication did not round-trip."
            )
        } catch {
            check(false, "Wire decoding/encoding failed: \(error.localizedDescription)")
        }

        do {
            _ = try codec.decode(invocation(
                AIHighlightToolName.readSegments,
                ["ids": ["not-a-segment"], "context_before": 0, "context_after": 0]
            ))
            check(false, "Malformed read segment ID passed decoding.")
        } catch AIHighlightToolCodecError.invalidSegmentID("not-a-segment") {
            check(true, "")
        } catch {
            check(false, "Malformed read ID returned the wrong codec error.")
        }

        for intent in [AIHighlightIntent.overview, .question("network design")] {
            let policy = AIHighlightIntentPolicy.make(for: intent)
            let definitions = AIHighlightToolCodec.definitions(for: policy)
            check(
                Set(definitions.map(\.name)).count == 5 && definitions.count == 5,
                "The active intent does not expose five uniquely named tools."
            )
            do {
                for definition in definitions {
                    let root = try object(definition.strictInputSchema)
                    let properties = root["properties"] as? [String: Any] ?? [:]
                    check(
                        root["additionalProperties"] as? Bool == false
                            && Set(root["required"] as? [String] ?? []) == Set(properties.keys),
                        "\(definition.name) has an incomplete strict input schema."
                    )
                    if definition.name == AIHighlightToolName.stageHighlights {
                        let items = properties["items"] as? [String: Any] ?? [:]
                        let item = items["items"] as? [String: Any] ?? [:]
                        let itemProperties = item["properties"] as? [String: Any] ?? [:]
                        let category = itemProperties["category"] as? [String: Any] ?? [:]
                        check(
                            Set(category["enum"] as? [String] ?? [])
                                == Set(policy.allowedCategories.map(\.rawValue)),
                            "Stage categories diverged from the intent policy."
                        )
                        check(
                            items["maxItems"] as? Int == policy.maximumDraftItems,
                            "Stage item limit diverged from the intent policy."
                        )
                        check(
                            item["additionalProperties"] as? Bool == false
                                && Set(item["required"] as? [String] ?? [])
                                    == Set(itemProperties.keys),
                            "Nested stage items are not strict."
                        )
                    }
                }
            } catch {
                check(false, "Intent schema is not valid JSON: \(error.localizedDescription)")
            }
        }
        return Report(checks: checks, failures: failures)
    }

    static func run() async -> Report {
        let wireReport = runWireContractChecks()
        var checks = wireReport.checks
        var failures = wireReport.failures
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }
        do {
            let registry = try AISegmentRegistry(snapshot: AIHighlightTextSnapshot(
                fingerprint: "codec-diagnostic",
                pages: [AITextPageSnapshot(
                    pageNumber: 1, text: "The network uses two layers. A limitation remains.",
                    fingerprint: "codec-page-1"
                )]
            ))
            guard let id = registry.records.first?.id else {
                return Report(checks: checks + 1, failures: failures + ["Missing codec fixture ID."])
            }
            let executor = AIHighlightToolExecutor(registry: registry, intent: .question("network"))
            let codec = AIHighlightToolCodec()
            let search = try await executor.execute(invocation(
                AIHighlightToolName.searchSegments,
                [
                    "query": "network", "page_start": 1, "page_end": 1,
                    "top_k": 4, "strategy": "questionRelevance"
                ]
            ))
            let matches = try JSONSerialization.jsonObject(with: search.output) as? [[String: Any]]
            check(matches?.first?["id"] as? String == id.description, "Wire search missed fixture ID.")
            let unread = try await executor.execute(invocation(
                AIHighlightToolName.stageHighlights, stageArguments(id: id)
            ))
            let unreadRoot = try object(unread.output)
            let unreadItems = unreadRoot["items"] as? [[String: Any]]
            check(
                unreadRoot["applied"] as? Bool == false
                    && unreadItems?.first?["candidate_id"] as? String == "network-1"
                    && unreadItems?.first?["missing_read_ids"] as? [String] == [id.description],
                "Unread stage wire result did not retain candidate_id and missing_read_ids."
            )
            let readCall = try invocation(
                AIHighlightToolName.readSegments,
                ["ids": [id.description], "context_before": 0, "context_after": 0]
            )
            let read = try await executor.execute(readCall)
            let readRoot = try object(read.output)
            let segments = readRoot["segments"] as? [[String: Any]]
            check(
                readRoot["read_ids"] as? [String] == [id.description]
                    && readRoot["already_read_ids"] as? [String] == [],
                "Read ledger keys were not encoded as read_ids/already_read_ids."
            )
            check(
                segments?.first?["text"] as? String == registry.records.first?.text
                    && read.readCharacterCount == registry.records.first?.text.count,
                "Wire read text or character count was incorrect."
            )
            let repeatedRead = try await executor.execute(readCall)
            let repeatedRoot = try object(repeatedRead.output)
            check(
                repeatedRoot["read_ids"] as? [String] == []
                    && repeatedRoot["already_read_ids"] as? [String] == [id.description]
                    && repeatedRead.readCharacterCount == 0,
                "Repeated wire read did not preserve the compact ID ledger."
            )

            let interim = try await executor.execute(invocation(
                AIHighlightToolName.publishAnswer,
                publishArguments(id: id, revision: 0, terminate: false)
            ))
            let interimResult = try codec.decodePublishResult(interim.output)
            check(
                interimResult.accepted && interimResult.publication?.terminate == false,
                "Interim zero-highlight publication did not cross the wire boundary."
            )
            check(
                interim.disposition == .continueWorkflow,
                "Interim wire publication requested termination."
            )

            let stage = try await executor.execute(invocation(
                AIHighlightToolName.stageHighlights, stageArguments(id: id)
            ))
            let stageRoot = try object(stage.output)
            check(
                stageRoot["applied"] as? Bool == true && stageRoot["revision"] as? Int == 1,
                "Read-before-stage wire flow did not accept revision 1."
            )
            let terminal = try await executor.execute(invocation(
                AIHighlightToolName.publishAnswer,
                publishArguments(id: id, revision: 1, terminate: true)
            ))
            let terminalResult = try codec.decodePublishResult(terminal.output)
            check(
                terminalResult.accepted && terminalResult.publication?.terminate == true
                    && terminalResult.publication?.evidenceSegmentIDs == [id],
                "Terminal publication lost its evidence IDs while decoding wire output."
            )
            check(
                terminal.disposition == .requestTermination,
                "Terminal publication did not restrict following calls to output tools."
            )
        } catch {
            check(false, "Executor wire diagnostic failed: \(error.localizedDescription)")
        }
        return Report(checks: checks, failures: failures)
    }

    private static func invocation(_ name: String, _ arguments: [String: Any]) throws -> AIToolInvocation {
        AIToolInvocation(
            callID: "codec-\(name)", name: name,
            arguments: try JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys)
        )
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIHighlightToolCodecError.unknownTool("non-object diagnostic output")
        }
        return object
    }

    private static func stageArguments(id: AISegmentID) -> [String: Any] {
        [
            "draft_revision": 0, "title": "Network design",
            "items": [[
                "candidate_id": "network-1", "segment_ids": [id.description],
                "category": "directAnswer", "importance": 5, "note": NSNull()
            ]]
        ]
    }

    private static func publishArguments(
        id: AISegmentID, revision: Int, terminate: Bool
    ) -> [String: Any] {
        [
            "completion_status": "answered", "title": "Network design",
            "result_markdown": "The network uses two layers [p. 1].",
            "evidence_segment_ids": [id.description], "final_draft_revision": revision,
            "terminate": terminate
        ]
    }
}
