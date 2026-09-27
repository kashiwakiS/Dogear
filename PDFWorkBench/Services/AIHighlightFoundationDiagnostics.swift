import Foundation

nonisolated struct AIHighlightFoundationDiagnosticReport: Equatable, Sendable {
    let checkCount: Int
    let failures: [String]

    var succeeded: Bool { failures.isEmpty }
}

nonisolated enum AIHighlightFoundationDiagnostics {
    static func run() async -> AIHighlightFoundationDiagnosticReport {
        var checkCount = 0
        var failures: [String] = []

        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checkCount += 1
            if !condition() {
                failures.append(message)
            }
        }

        let pages = [
            AITextPageSnapshot(
                pageNumber: 1,
                text: "Dr. Chen reported 3.14 units. The result was stable!\n\n这是第一句。这是第二句！",
                fingerprint: "page-1"
            ),
            AITextPageSnapshot(
                pageNumber: 2,
                text: "結果を確認した。制限も記録した。 Repeated sentence. Repeated sentence.",
                fingerprint: "page-2"
            )
        ]
        let snapshot = AIHighlightTextSnapshot(
            fingerprint: "diagnostic-snapshot",
            pages: pages
        )

        do {
            let id = try AISegmentID(parsing: "D001.P002.B003.S004")
            check(id.description == "D001.P002.B003.S004", "Segment ID round-trip failed.")

            let registry = try AISegmentRegistry(snapshot: snapshot)
            check(registry.records.count == 8, "Unexpected punctuation segmentation count.")
            check(
                registry.records.first?.text == "Dr. Chen reported 3.14 units.",
                "Abbreviation or decimal segmentation failed."
            )
            check(
                registry.records.filter { $0.id.page == 2 }.count == 4,
                "Page boundaries or repeated sentences were not preserved."
            )

            let blockSnapshot = AIHighlightTextSnapshot(
                fingerprint: "block-diagnostic",
                pages: [AITextPageSnapshot(
                    pageNumber: 1,
                    text: "First block.\n\u{00A0}\nSecond block.",
                    fingerprint: "block-page"
                )]
            )
            let blockRegistry = try AISegmentRegistry(snapshot: blockSnapshot)
            check(
                blockRegistry.records.map(\.id.block) == [1, 2],
                "Blank-line block splitting rejected the nonbreaking-space form."
            )
            let citationSnapshot = AIHighlightTextSnapshot(
                fingerprint: "citation-diagnostic",
                pages: [AITextPageSnapshot(
                    pageNumber: 1,
                    text: "Evidence sentence.6 Citation sentence.",
                    fingerprint: "citation-page"
                )]
            )
            let citationRegistry = try AISegmentRegistry(snapshot: citationSnapshot)
            check(
                citationRegistry.records.count == 2,
                "A directly attached numeric citation merged adjacent sentences."
            )
            let technicalLabelSnapshot = AIHighlightTextSnapshot(
                fingerprint: "technical-label-diagnostic",
                pages: [AITextPageSnapshot(
                    pageNumber: 1,
                    text: "We compare model A. Results improve. See equation 2a. The result holds. U.S. policy remains stable.",
                    fingerprint: "technical-label-page"
                )]
            )
            let technicalLabelRegistry = try AISegmentRegistry(snapshot: technicalLabelSnapshot)
            check(
                technicalLabelRegistry.records.map(\.text) == [
                    "We compare model A.",
                    "Results improve.",
                    "See equation 2a.",
                    "The result holds.",
                    "U.S. policy remains stable."
                ],
                "Single-letter technical labels or dotted abbreviations changed sentence boundaries."
            )
            let personInitialSnapshot = AIHighlightTextSnapshot(
                fingerprint: "person-initial-diagnostic",
                pages: [AITextPageSnapshot(
                    pageNumber: 1,
                    text: "J. Smith reported the result. According to J. Smith it holds. Ada J. Smith confirmed it. J. R. Doe replicated it. We compare model A. Results improve. Model A. Results remain stable. See equation 2a. The result holds.",
                    fingerprint: "person-initial-page"
                )]
            )
            let personInitialRegistry = try AISegmentRegistry(snapshot: personInitialSnapshot)
            check(
                personInitialRegistry.records.map(\.text) == [
                    "J. Smith reported the result.",
                    "According to J. Smith it holds.",
                    "Ada J. Smith confirmed it.",
                    "J. R. Doe replicated it.",
                    "We compare model A.",
                    "Results improve.",
                    "Model A.",
                    "Results remain stable.",
                    "See equation 2a.",
                    "The result holds."
                ],
                "Personal initials or technical-label sentence boundaries regressed."
            )

            let searcher = AISimpleLexicalSearcher()
            let matches = searcher.search(
                AISegmentSearchRequest(query: "stable", topK: 4),
                in: registry
            )
            check(matches.first?.id.page == 1, "Lexical search did not find the expected page.")

            let overviewMatches = searcher.search(
                AISegmentSearchRequest(
                    query: "",
                    topK: 2,
                    strategy: .overviewSalience
                ),
                in: registry
            )
            check(
                Set(overviewMatches.map(\.id.page)) == [1, 2],
                "Overview candidates were not distributed across pages."
            )

            guard let selectedID = matches.first?.id else {
                return AIHighlightFoundationDiagnosticReport(
                    checkCount: checkCount,
                    failures: failures + ["No segment was available for tool diagnostics."]
                )
            }

            let executor = AIHighlightToolExecutor(registry: registry, intent: .overview)
            let readOutput = await executor.execute(
                .readSegments(AIReadSegmentsRequest(ids: [selectedID]))
            )
            if case .readResults(let readResults) = readOutput {
                check(
                    readResults.segments.count == 1,
                    "Read tool did not return the selected segment."
                )
            } else {
                check(false, "Read tool returned the wrong output type.")
            }
            let repeatedReadOutput = await executor.execute(
                .readSegments(AIReadSegmentsRequest(ids: [selectedID]))
            )
            if case .readResults(let repeated) = repeatedReadOutput {
                check(
                    repeated.segments.isEmpty
                        && repeated.alreadyReadIDs.contains(selectedID),
                    "Read tool resent passage text that was already returned."
                )
            } else {
                check(false, "Repeated read returned the wrong output type.")
            }

            let candidate = AIHighlightCandidate(
                candidateID: "diagnostic-1",
                segmentIDs: [selectedID],
                category: .evidence,
                importance: 4,
                note: nil
            )
            let stagedOutput = await executor.execute(
                .stageHighlights(
                    AIStageHighlightsRequest(
                        draftRevision: 0,
                        title: "Stable Result",
                        items: [candidate]
                    )
                )
            )
            if case .staged(let staged) = stagedOutput {
                check(staged.applied && staged.revision == 1, "Initial staging revision failed.")
                check(
                    staged.items.first?.code == .accepted,
                    "A read, contiguous native-text segment was not accepted."
                )
                let draft = await executor.currentDraft()
                check(
                    draft.title == "Stable Result",
                    "The staged draft did not retain its generated title."
                )
            } else {
                check(false, "Stage tool returned the wrong output type.")
            }

            let idempotentCandidate = AIHighlightCandidate(
                candidateID: "diagnostic-renamed",
                segmentIDs: [selectedID],
                category: .evidence,
                importance: 4,
                note: nil
            )
            let idempotentOutput = await executor.execute(
                .stageHighlights(
                    AIStageHighlightsRequest(
                        draftRevision: 1,
                        title: "Stable Result",
                        items: [idempotentCandidate]
                    )
                )
            )
            if case .staged(let idempotent) = idempotentOutput {
                check(
                    idempotent.applied
                        && idempotent.unchanged
                        && idempotent.revision == 1,
                    "A semantically identical draft advanced its revision."
                )
            } else {
                check(false, "Idempotent stage returned the wrong output type.")
            }

            let staleOutput = await executor.execute(
                .stageHighlights(
                    AIStageHighlightsRequest(
                        draftRevision: 0,
                        title: "Stale Result",
                        items: [candidate]
                    )
                )
            )
            if case .staged(let stale) = staleOutput {
                check(
                    !stale.applied && stale.error == .staleRevision,
                    "Stale draft revision was not rejected."
                )
            } else {
                check(false, "Stale stage call returned the wrong output type.")
            }

            let invalidCandidate = AIHighlightCandidate(
                candidateID: "diagnostic-invalid",
                segmentIDs: [selectedID],
                category: .directAnswer,
                importance: 4,
                note: nil
            )
            let invalidOutput = await executor.execute(
                .stageHighlights(
                    AIStageHighlightsRequest(
                        draftRevision: 1,
                        title: "Invalid Result",
                        items: [candidate, invalidCandidate]
                    )
                )
            )
            if case .staged(let invalid) = invalidOutput {
                check(
                    !invalid.applied
                        && invalid.revision == 1
                        && invalid.error == .invalidItems,
                    "An invalid item partially replaced the current draft."
                )
            } else {
                check(false, "Invalid batch returned the wrong output type.")
            }

            let published = await executor.execute(
                .publishAnswer(
                    AIPublishAnswerRequest(
                        completionStatus: .answered,
                        title: "Stable Result",
                        resultMarkdown: "The result was stable [p. 1].",
                        evidenceSegmentIDs: [selectedID],
                        finalDraftRevision: 1,
                        terminate: true
                    )
                )
            )
            if case .answerPublished(let result) = published {
                check(
                    result.accepted && result.publication?.terminate == true,
                    "A valid terminal answer was rejected."
                )
            } else {
                check(false, "Publish tool returned the wrong output type.")
            }

            let unreadExecutor = AIHighlightToolExecutor(
                registry: registry,
                intent: .question("What was stable?")
            )
            let unreadCandidate = AIHighlightCandidate(
                candidateID: "unread",
                segmentIDs: [selectedID],
                category: .directAnswer,
                importance: 5,
                note: nil
            )
            let unreadOutput = await unreadExecutor.execute(
                .stageHighlights(
                    AIStageHighlightsRequest(
                        draftRevision: 0,
                        title: "Unread",
                        items: [unreadCandidate]
                    )
                )
            )
            if case .staged(let unread) = unreadOutput {
                check(
                    unread.items.first?.code == .unread
                        && unread.items.first?.missingReadIDs == [selectedID],
                    "Unread repair did not return exact missing segment IDs."
                )
            } else {
                check(false, "Unread stage returned the wrong output type.")
            }

            for intent in [AIHighlightIntent.overview, .question("test")] {
                let policy = AIHighlightIntentPolicy.make(for: intent)
                let schemaCategories = stageCategories(
                    in: AIHighlightToolCodec.definitions(for: policy)
                )
                check(
                    schemaCategories == Set(policy.allowedCategories.map(\.rawValue)),
                    "Stage schema categories diverged from the active intent policy."
                )
            }
        } catch {
            failures.append(error.localizedDescription)
        }

        return AIHighlightFoundationDiagnosticReport(
            checkCount: checkCount,
            failures: failures
        )
    }

    private static func stageCategories(
        in definitions: [AIToolDefinition]
    ) -> Set<String> {
        guard let definition = definitions.first(where: {
            $0.name == AIHighlightToolName.stageHighlights
        }),
        let root = try? JSONSerialization.jsonObject(
            with: definition.strictInputSchema
        ) as? [String: Any],
        let properties = root["properties"] as? [String: Any],
        let items = properties["items"] as? [String: Any],
        let item = items["items"] as? [String: Any],
        let itemProperties = item["properties"] as? [String: Any],
        let category = itemProperties["category"] as? [String: Any],
        let values = category["enum"] as? [String]
        else {
            return []
        }
        return Set(values)
    }
}
