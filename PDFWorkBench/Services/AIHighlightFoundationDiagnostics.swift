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
                check(readResults.count == 1, "Read tool did not return the selected segment.")
            } else {
                check(false, "Read tool returned the wrong output type.")
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
        } catch {
            failures.append(error.localizedDescription)
        }

        return AIHighlightFoundationDiagnosticReport(
            checkCount: checkCount,
            failures: failures
        )
    }
}
