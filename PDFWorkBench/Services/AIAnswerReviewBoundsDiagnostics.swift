import Foundation

/// Offline fixtures exercise the production codec, composite, runner and service.
/// Nothing opens a user PDF, reads credentials, or sends a provider request.
nonisolated enum AIAnswerReviewBoundsDiagnostics {
    struct Report: Sendable { let checks: Int; let failures: [String] }

    static func run() async -> Report {
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearReviewBounds-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let codec = AIHighlightToolCodec()
            let definition = AIHighlightToolCodec.definitions.first { $0.name == AIHighlightToolName.publishAnswer }!
            let schema = try JSONSerialization.jsonObject(with: definition.strictInputSchema) as? [String: Any]
            let properties = schema?["properties"] as? [String: Any]
            check((properties?["result_markdown"] as? [String: Any])?["maxLength"] as? Int == 8_000,
                  "Publication schema does not advertise the answer bound")
            check(definition.description.contains("24000") && definition.schemaVersion == "4",
                  "Publication schema did not expose the citation bound or advance its version")

            let shortSnapshot = snapshot(lengths: [40])
            let shortRegistry = try AISegmentRegistry(snapshot: shortSnapshot)
            let shortID = shortRegistry.records[0].id
            for length in [8_000, 8_001] {
                let executor = AIHighlightToolExecutor(registry: shortRegistry, intent: .overview, verifiesAnswerEvidence: true)
                _ = await executor.execute(.readSegments(.init(ids: [shortID])))
                let terminal = try publication(id: "answer-\(length)", ids: [shortID], answerLength: length)
                let review = try await executor.reviewRequest(for: terminal.toolCalls[0])
                check((review != nil) == (length == 8_000), "Answer boundary \(length) was not enforced before review")
                check(await executor.evidenceReviewAttempts == (length == 8_000 ? 1 : 0),
                      "Size rejection consumed a paid review attempt")
                let output = try await executor.execute(terminal.toolCalls[0])
                let result = try codec.decodePublishResult(output.output)
                check(!result.accepted && result.publication == nil && output.disposition == .continueWorkflow,
                      "Unreviewed boundary answer was published or terminated the runner")
                check(result.error == (length == 8_000 ? .evidenceReviewRequired : .evidenceReviewSizeExceeded),
                      "Oversized answer did not return a repairable size error")
                let completed = await executor.completedAnswer()
                let draft = await executor.currentDraft()
                check(completed == nil && draft.revision == 0,
                      "Answer-size validation changed the publication or draft revision")
            }

            for length in [24_000, 24_001] {
                let registry = try AISegmentRegistry(snapshot: snapshot(lengths: [12_000, length - 12_000]))
                let ids = registry.records.map(\.id)
                check(registry.records.reduce(0) { $0 + $1.text.count } == length, "Fixture changed citation boundary")
                let executor = AIHighlightToolExecutor(registry: registry, intent: .overview, verifiesAnswerEvidence: true)
                _ = await executor.execute(.readSegments(.init(ids: ids)))
                let terminal = try publication(id: "evidence-\(length)", ids: ids)
                let review = try await executor.reviewRequest(for: terminal.toolCalls[0])
                check((review != nil) == (length == 24_000), "Evidence boundary \(length) was not enforced before review")
                if let review {
                    let body = try JSONSerialization.jsonObject(with: Data(review.input.utf8)) as? [String: Any]
                    let passages = body?["evidence"] as? [[String: Any]] ?? []
                    check(passages.compactMap { $0["text"] as? String }.reduce(0) { $0 + $1.count } == length,
                          "Exact-limit cited passages were truncated or omitted")
                } else {
                    let output = try await executor.execute(terminal.toolCalls[0])
                    let rejection = try codec.decodePublishResult(output.output)
                    check(rejection.error == .evidenceReviewSizeExceeded
                        && rejection.reviewIssues.contains(where: { $0.contains("24001") && $0.contains("24000") }),
                        "Citation rejection did not explain actual and allowed sizes")
                    check(rejection.reviewIssues.contains(where: { $0.contains(ids[1].description + "=12001") }),
                          "Citation rejection did not identify passage sizes for repair")
                    let attempts = await executor.evidenceReviewAttempts
                    let completed = await executor.completedAnswer()
                    check(attempts == 0 && completed == nil,
                          "Oversized evidence started a review or accepted an answer")
                }
            }

            // Both oversized prose and oversized citation sets are corrected
            // through the real service, without truncating either on the host.
            for oversizedEvidence in [false, true] {
                let source = oversizedEvidence ? snapshot(lengths: [12_000, 12_001]) : shortSnapshot
                let registry = try AISegmentRegistry(snapshot: source)
                let ids = registry.records.map(\.id)
                let first = ids[0]
                let turns = [try read(ids), try stage(first),
                    try publication(id: "too-large", ids: ids, answerLength: oversizedEvidence ? 40 : 8_001, revision: 1),
                    try publication(id: "corrected", ids: [first], revision: 1), try review(first)]
                let provider = Provider(turns)
                let accepted = Publications()
                let result = try await service(root: root).generateReadingResult(snapshot: source, intent: .overview,
                    provider: provider, verifiesAnswerEvidence: true, publication: { await accepted.append($0) })
                let observed = await provider.state()
                check(result.answer.resultMarkdown.count == 40 && result.highlights.count == 1,
                      "Corrected publication lost its reviewed answer or optional draft")
                check(result.usage.providerTurns == 5 && result.usage.toolCalls == 5 && result.usage.inputTokens == 50,
                      "Size correction escaped shared provider/tool/token budgets")
                check(observed.reviews.count == 1 && observed.continuations.count == 3 && observed.discards.count == 2,
                      "Size repair started a paid review early, leaked a continuation, or sent a terminal receipt")
                let publications = await accepted.values
                check(publications.count == 1 && publications.first == result.answer,
                      "Service exposed an unreviewed proposal through its publication callback")
                let repairOutput = observed.continuations[2].toolOutputs[0]
                let rejection = try codec.decodePublishResult(repairOutput.output)
                check(rejection.error == .evidenceReviewSizeExceeded && !rejection.accepted
                    && rejection.currentDraftRevision == 1 && !rejection.reviewIssues.isEmpty,
                    "Size feedback lost the complete draft revision or repair guidance")
                check(observed.initial?.instructions.contains("8000") == true
                    && observed.initial?.instructions.contains("24000") == true,
                    "Main workflow instructions did not disclose review limits before generation")
                let reviewInput = try JSONSerialization.jsonObject(with: Data(observed.reviews[0].input.utf8)) as? [String: Any]
                check((reviewInput?["candidate_answer"] as? String)?.count == 40,
                      "Reviewer received the rejected oversized proposal instead of the corrected answer")
                if oversizedEvidence {
                    let passages = reviewInput?["evidence"] as? [[String: Any]] ?? []
                    check(passages.count == 1 && (passages[0]["text"] as? String)?.count == 12_000,
                          "Noncited overflow was treated as mandatory or the cited passage was truncated")
                }
            }

            // Local size corrections must not consume the two substantive
            // evidence-review attempts, and cannot stand in for either review.
            let twice = Provider([try read([shortID]),
                try publication(id: "large", ids: [shortID], answerLength: 8_001),
                try publication(id: "short", ids: [shortID]), try review(shortID, supported: false),
                try publication(id: "corrected-claim", ids: [shortID], answerLength: 39), try review(shortID)])
            let correctedClaim = try await service(root: root).generateReadingResult(snapshot: shortSnapshot, intent: .overview,
                provider: twice, verifiesAnswerEvidence: true)
            check(correctedClaim.usage.providerTurns == 6 && correctedClaim.answer.resultMarkdown.count == 39,
                  "Size feedback consumed the allowance for correcting a substantive evidence failure")
            check(await twice.state().reviews.count == 2, "Corrected claim bypassed its second mandatory review")

            for metric: AIWorkflowBudgetMetric in [.providerTurns, .toolCalls] {
                var budget = AIWorkflowBudget.highlightDefault
                if metric == .providerTurns { budget.maximumProviderTurns = 4 }
                else { budget.maximumToolCalls = 4 }
                let exhausted = Provider([try read([shortID]), try stage(shortID),
                    try publication(id: "last-too-large", ids: [shortID], answerLength: 8_001, revision: 1)])
                let accepted = Publications()
                do {
                    _ = try await service(root: root).generateReadingResult(snapshot: shortSnapshot, intent: .overview,
                        provider: exhausted, budget: budget, verifiesAnswerEvidence: true,
                        publication: { await accepted.append($0) })
                    check(false, "Oversized publication completed after exhausting \(metric)")
                } catch {
                    check(error as? AIWorkflowFoundationError == .budgetExceeded(metric),
                          "Size correction escaped or misreported the exhausted \(metric) budget")
                }
                let observed = await exhausted.state()
                check(observed.calls == 3 && observed.reviews.isEmpty && observed.discards.count == 1,
                      "An exhausted correction started another paid request or left continuation state")
                check(await accepted.values.isEmpty, "An exhausted correction exposed an unreviewed answer or draft result")
            }

            // Correcting length alone is never enough: a reviewer must still
            // reject unsupported content, and a terminal must remain sole.
            let unsupported = Provider([try read([shortID]),
                try publication(id: "large", ids: [shortID], answerLength: 8_001),
                try publication(id: "unsupported-1", ids: [shortID]), try review(shortID, supported: false),
                try publication(id: "unsupported-2", ids: [shortID], answerLength: 39), try review(shortID, supported: false),
                try publication(id: "unsupported-3", ids: [shortID], answerLength: 38)])
            let noPublication = Publications()
            do {
                _ = try await service(root: root).generateReadingResult(snapshot: shortSnapshot, intent: .overview,
                    provider: unsupported, verifiesAnswerEvidence: true, publication: { await noPublication.append($0) })
                check(false, "Length correction bypassed repeated failed evidence reviews")
            } catch {
                check(error is AIAnswerEvidenceReviewError, "Unsupported corrected answer failed through an unexpected path")
            }
            let rejectedPublications = await noPublication.values
            let rejectedReviews = await unsupported.state().reviews
            check(rejectedPublications.isEmpty && rejectedReviews.count == 2,
                  "Size correction produced an unreviewed side effect or a third paid review")

            let mixedExecutor = AIHighlightToolExecutor(registry: shortRegistry, intent: .overview, verifiesAnswerEvidence: true)
            _ = await mixedExecutor.execute(.readSegments(.init(ids: [shortID])))
            let mixedCall = try publication(id: "mixed", ids: [shortID], answerLength: 8_001).toolCalls[0]
            let mixedOutput = try await mixedExecutor.execute(mixedCall, batchCount: 2)
            check(try codec.decodePublishResult(mixedOutput.output).error == .terminalMustBeSoleCall
                && mixedOutput.disposition == .continueWorkflow,
                "Oversized publication bypassed the sole-terminal requirement")
            let mixedAnswer = await mixedExecutor.completedAnswer()
            let mixedAttempts = await mixedExecutor.evidenceReviewAttempts
            check(mixedAnswer == nil && mixedAttempts == 0,
                  "Mixed terminal batch started an evidence review or accepted a result")
        } catch { check(false, "Review bounds fixture failed: \(error)") }
        return .init(checks: checks, failures: failures)
    }

    private static func snapshot(lengths: [Int]) -> AIHighlightTextSnapshot {
        .init(fingerprint: "review-bounds-\(lengths)", pages: lengths.enumerated().map {
            .init(pageNumber: $0.offset + 1, text: String(repeating: "x", count: $0.element),
                  fingerprint: "p\($0.offset)-\($0.element)")
        })
    }

    private static func service(root: URL) -> AIHighlightWorkflowService {
        .init(runner: AIToolWorkflowRunner(),
              traceRecorder: AIHighlightTraceRecorder(fileURL: root.appendingPathComponent("\(UUID()).jsonl")))
    }

    private static func read(_ ids: [AISegmentID]) throws -> AIToolProviderTurn {
        try turn(id: "read", name: AIHighlightToolName.readSegments,
                 arguments: ["ids": ids.map(\.description), "context_before": 0, "context_after": 0])
    }

    private static func stage(_ id: AISegmentID) throws -> AIToolProviderTurn {
        try turn(id: "stage", name: AIHighlightToolName.stageHighlights,
            arguments: ["draft_revision": 0, "title": "Fixture", "items": [["candidate_id": "one",
                "segment_ids": [id.description], "category": "method", "importance": 3, "note": NSNull()]]])
    }

    private static func publication(id: String, ids: [AISegmentID], answerLength: Int = 40,
                                    revision: Int = 0) throws -> AIToolProviderTurn {
        try turn(id: id, name: AIHighlightToolName.publishAnswer, arguments: [
            "completion_status": "answered", "title": "Fixture", "result_markdown": String(repeating: "a", count: answerLength),
            "evidence_segment_ids": ids.map(\.description), "evidence_image_ids": [],
            "final_draft_revision": revision, "terminate": true])
    }

    private static func review(_ id: AISegmentID, supported: Bool = true) throws -> AIToolProviderTurn {
        try turn(id: "review-\(UUID())", name: AIAnswerEvidenceReview.toolName, arguments: [
            "completion_status": "answered", "claims": [["claim": "Fixture claim", "status": supported ? "supported" : "contradicted",
                "evidence_ids": [id.description], "reason": "Fixture review outcome"]]])
    }

    private static func turn(id: String, name: String, arguments: [String: Any]) throws -> AIToolProviderTurn {
        .init(responseID: id, toolCalls: [.init(callID: id, name: name,
            arguments: try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))],
            structuredFinalResult: nil, inputTokens: 10)
    }

    private actor Publications {
        var values: [AIPublishedAnswer] = []
        func append(_ answer: AIPublishedAnswer) { values.append(answer) }
    }

    private actor Provider: AIToolCallingProvider {
        nonisolated let toolCapabilities = AIToolProviderCapabilities(supportsFunctionTools: true,
            supportsStrictToolSchemas: true, supportsResponseContinuation: true, supportsStructuredFinalResult: false)
        var turns: [AIToolProviderTurn]
        var calls = 0
        var initial: AIToolWorkflowProviderRequest?
        var reviews: [AIToolWorkflowProviderRequest] = []
        var continuations: [AIToolWorkflowContinuationRequest] = []
        var discards: [UUID] = []
        init(_ turns: [AIToolProviderTurn]) { self.turns = turns }
        func beginToolWorkflow(_ request: AIToolWorkflowProviderRequest) throws -> AIToolProviderTurn {
            if request.tools.map(\.name) == [AIAnswerEvidenceReview.toolName] { reviews.append(request) }
            else { initial = request }
            return try next()
        }
        func continueToolWorkflow(_ request: AIToolWorkflowContinuationRequest) throws -> AIToolProviderTurn {
            continuations.append(request)
            return try next()
        }
        func discardToolWorkflow(_ workflowID: UUID) { discards.append(workflowID) }
        func state() -> State { .init(calls: calls, initial: initial, reviews: reviews, continuations: continuations, discards: discards) }
        private func next() throws -> AIToolProviderTurn {
            try Task.checkCancellation()
            calls += 1
            guard !turns.isEmpty else { throw AIProviderError.emptyResponse }
            return turns.removeFirst()
        }
        struct State: Sendable {
            let calls: Int
            let initial: AIToolWorkflowProviderRequest?
            let reviews: [AIToolWorkflowProviderRequest]
            let continuations: [AIToolWorkflowContinuationRequest]
            let discards: [UUID]
        }
    }
}
