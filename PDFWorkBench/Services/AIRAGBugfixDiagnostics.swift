import Foundation
import PDFKit

@MainActor
enum AIRAGBugfixDiagnostics {
    static func run() async -> AIHighlightFoundationDiagnosticReport {
        var count = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            count += 1
            if !value { failures.append(message) }
        }
        let vetoes = ["Do not add annotations.", "Don't create any highlights.",
                      "Without annotations, summarize the results.", "只回答文字，不创建高亮或注释。", "不要高亮。"]
        for text in vetoes {
            check(!AIHighlightIntentPolicy.make(for: .question(text)).allowsAnnotations, "Annotation veto ignored: \(text)")
        }
        for text in ["Explain the architecture.", "Don't remove existing highlights.", "不要删除高亮。"] {
            check(AIHighlightIntentPolicy.make(for: .question(text)).allowsAnnotations, "Unrelated wording misclassified: \(text)")
        }
        check(!AIHighlightIntentPolicy.make(for: .overview, allowsAnnotations: false).allowsAnnotations,
              "Explicit UI permission did not restrict an overview.")
        do {
            let snapshot = AIHighlightTextSnapshot(fingerprint: "bugfix-fixture", pages: [
                AITextPageSnapshot(pageNumber: 1, text: "Weights differ between layers. Weights are shared across positions.", fingerprint: "p1")
            ])
            let registry = try AISegmentRegistry(snapshot: snapshot)
            let id = registry.records[0].id
            let second = registry.records[1].id
            let executor = AIHighlightToolExecutor(registry: registry, intent: .question(vetoes[0]))
            _ = await executor.execute(.readSegments(.init(ids: [id])))
            let stage = await executor.execute(.stageHighlights(.init(draftRevision: 0, title: "Wrongly requested",
                items: [.init(candidateID: "one", segmentIDs: [id], category: .supportingEvidence, importance: 3, note: "note")])) )
            if case .staged(let value) = stage {
                check(!value.applied && value.error == .annotationsForbidden && value.revision == 0, "Forbidden stage mutated the draft.")
            } else { check(false, "Wrong stage output.") }
            check(await executor.currentDraft().items.isEmpty, "Forbidden annotation survived in draft.")
            let empty = await executor.execute(.stageHighlights(.init(draftRevision: 0, title: "No annotations", items: [])))
            if case .staged(let value) = empty { check(value.applied, "Forbidden mode prevented an empty draft.") }

            var limits = AIHighlightToolLimits()
            limits.maximumReadSelectors = 1
            let reader = AIHighlightToolExecutor(registry: registry, intent: .overview, limits: limits)
            if case .readResults(let result) = await reader.execute(.readSegments(.init(ids: [id, second]))) {
                check(result.omittedIDs == [second] && result.readIDs == [id], "Read selector truncation remained silent.")
                let wire = try AIHighlightToolCodec().encode(.readResults(result))
                let object = try JSONSerialization.jsonObject(with: wire) as? [String: Any]
                check(object?["omitted_ids"] != nil && object?["missing_ids"] != nil, "Omitted selectors absent from wire output.")
            }
            let missing = try AISegmentID(parsing: "D001.P099.B001.S001")
            if case .readResults(let result) = await reader.execute(.readSegments(.init(ids: [missing]))) {
                check(result.missingIDs == [missing], "Unknown read selectors not explained.")
            }

            let proposal = AIPublishAnswerRequest(completionStatus: .answered, title: "Weights", resultMarkdown: "Weights differ between layers [p. 1].",
                evidenceSegmentIDs: [id], finalDraftRevision: 0, terminate: true)
            let supported = try reviewData(id: id, status: "supported")
            let contradicted = try reviewData(id: id, status: "contradicted")
            let gated = AIHighlightToolExecutor(registry: registry, intent: .overview, verifiesAnswerEvidence: true)
            _ = await gated.execute(.readSegments(.init(ids: [id])))
            if case .answerPublished(let result) = await gated.execute(.publishAnswer(proposal)) {
                check(!result.accepted && result.error == .evidenceReviewRequired,
                      "Direct terminal execution bypassed required review.")
            }
            let mismatch = try JSONSerialization.data(withJSONObject: ["completion_status": "notFound", "claims": [
                ["claim": "No requested result established.", "status": "supported", "evidence_ids": [id.description], "reason": "Question unsupported."]]])
            check(try !AIAnswerEvidenceReview.issues(in: mismatch, proposal: proposal, allowedIDs: [id.description]).isEmpty,
                  "Unsupported question retained answered status despite review.")
            check(try AIAnswerEvidenceReview.issues(in: supported, proposal: proposal, allowedIDs: [id.description]).isEmpty,
                  "Supported review rejected.")
            check(try !AIAnswerEvidenceReview.issues(in: contradicted, proposal: proposal, allowedIDs: [id.description]).isEmpty,
                  "Contradicted claim accepted.")
            for status in ["partiallySupported", "insufficient"] {
                check(try !AIAnswerEvidenceReview.issues(in: reviewData(id: id, status: status), proposal: proposal,
                    allowedIDs: [id.description]).isEmpty, "Incomplete support was accepted.")
            }
            do {
                _ = try AIAnswerEvidenceReview.issues(in: supported, proposal: proposal, allowedIDs: [])
                check(false, "Reviewer invented an unseen evidence ID.")
            } catch { check(true, "") }
            do {
                _ = try AIAnswerEvidenceReview.issues(in: Data("{\"completion_status\":\"answered\",\"claims\":[]}".utf8), proposal: proposal, allowedIDs: [])
                check(false, "Empty review bypassed checking.")
            } catch { check(true, "") }

            for repair in [false, true] {
                let final = try publication(id: id, callID: "publish-1")
                let turns = [try call("read", name: AIHighlightToolName.readSegments,
                                     arguments: ["ids": [id.description], "context_before": 0, "context_after": 0]), final,
                             reviewTurn(repair ? contradicted : supported, id: "review-1")]
                    + (repair ? [try publication(id: id, callID: "publish-2"), reviewTurn(supported, id: "review-2")] : [])
                let provider = Provider(turns)
                let reviewedExecutor = AIHighlightToolExecutor(registry: registry, intent: .question("Explain weights. Do not add annotations."), verifiesAnswerEvidence: true)
                let trace = AIInMemoryWorkflowTraceSink()
                let outcome = try await AIToolWorkflowRunner(traceSink: trace).run(
                    request: request(), provider: provider, executor: reviewedExecutor, budget: .highlightDefault,
                    terminalToolName: AIHighlightToolName.publishAnswer)
                check(outcome.usage.providerTurns == (repair ? 5 : 3), "Review provider turns not charged to shared budget.")
                check(outcome.usage.toolCalls == (repair ? 5 : 3), "Review tool calls not charged to shared budget.")
                check(outcome.usage.inputTokens == (repair ? 50 : 30), "Review tokens not charged to shared budget.")
                check(await reviewedExecutor.completedAnswer() != nil, "Reviewed answer did not complete.")
                check(await provider.discards.count == (repair ? 3 : 2), "Review or parent continuation leaked.")
                check(await provider.continuations.count == (repair ? 2 : 1), "Receipt sent after accepted termination.")
                check(await trace.events.contains(.evidenceReviewStarted), "Review stage not traced.")
                if repair {
                    let outputs = await provider.continuations.last!.toolOutputs
                    let result = try AIHighlightToolCodec().decodePublishResult(outputs[0].output)
                    check(!result.accepted && result.error == .evidenceReviewFailed && !result.reviewIssues.isEmpty,
                          "Failed review not returned for bounded correction.")
                }
            }

            var budget = AIWorkflowBudget.highlightDefault
            budget.maximumProviderTurns = 1
            let noPaidReview = Provider([try publication(id: id, callID: "not-sent")])
            do {
                _ = try await AIToolWorkflowRunner().run(request: request(), provider: noPaidReview, executor: gated,
                    budget: budget, terminalToolName: AIHighlightToolName.publishAnswer)
                check(false, "Review workflow started without enough completion headroom.")
            } catch { check(await noPaidReview.calls == 0, "Paid provider request started despite insufficient review headroom.") }
            budget = .highlightDefault
            budget.maximumToolCalls = 1
            let exhausted = Provider([try call("read", name: AIHighlightToolName.readSegments,
                arguments: ["ids": [id.description], "context_before": 0, "context_after": 0])])
            do {
                _ = try await AIToolWorkflowRunner().run(request: request(), provider: exhausted,
                    executor: AIHighlightToolExecutor(registry: registry, intent: .overview), budget: budget)
                check(false, "Exhausted tool budget continued.")
            } catch { check(await exhausted.calls == 1, "A paid request followed tool budget exhaustion.") }

            budget.maximumToolCalls = 24
            budget.maximumProviderTurns = 2
            let noReviewBudget = Provider([try publication(id: id, callID: "p")])
            let waiting = AIHighlightToolExecutor(registry: registry, intent: .overview, verifiesAnswerEvidence: true)
            _ = await waiting.execute(.readSegments(.init(ids: [id])))
            // Cancellation immediately before a review must leave no accepted answer.
            let task = Task {
                try await AIToolWorkflowRunner().run(request: request(), provider: noReviewBudget,
                    executor: waiting, budget: budget, terminalToolName: AIHighlightToolName.publishAnswer,
                    progress: { event in if case .evidenceReviewStarted = event { withUnsafeCurrentTask { $0?.cancel() } } })
            }
            do { _ = try await task.value; check(false, "Cancelled review completed.") }
            catch { check(await waiting.completedAnswer() == nil, "Cancellation accepted an unreviewed answer.") }

            let view = HighlightingPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 700))
            let document = PDFDocument()
            document.insert(PDFPage(), at: 0)
            view.document = document
            for action: PDFZoomAction in [.fitWidth, .fitPage] {
                view.applyZoomCommand(action)
                view.beginUserMagnification()
                view.scaleFactor = 1.37
                view.updateActiveFitScaleIfNeeded()
                check(view.currentZoomState.mode == .custom && abs(view.scaleFactor - 1.37) < 0.001,
                      "Fit reclaimed the scale after user magnification.")
            }

            let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearBugfix-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let blocker = root.appendingPathComponent("not-a-directory")
            try Data().write(to: blocker)
            let recorder = AIHighlightTraceRecorder(fileURL: blocker.appendingPathComponent("trace.jsonl"))
            await recorder.record(workflowID: UUID(), groupID: UUID(), event: .cancelled)
            check(await recorder.lastError != nil, "Logging failure was not surfaced safely.")
            check(AIHighlightTraceRecorder.debugFileURL(in: root).deletingLastPathComponent().lastPathComponent == "DogearDiagnostics",
                  "Debug logging would modify the chosen directory itself.")
        } catch { check(false, "Bugfix fixture failed: \(error)") }
        return .init(checkCount: count, failures: failures)
    }

    private static func request() -> AIToolWorkflowProviderRequest {
        .init(workflowID: UUID(), instructions: "fixture", input: "fixture", tools: AIHighlightToolCodec.definitions)
    }
    private static func reviewData(id: AISegmentID, status: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["completion_status": "answered", "claims": [
            ["claim": "Weights differ between layers.", "status": status, "evidence_ids": [id.description], "reason": "Compare the cited scope."]
        ]])
    }
    private static func publication(id: AISegmentID, callID: String) throws -> AIToolProviderTurn {
        try call(callID, name: AIHighlightToolName.publishAnswer, arguments: ["completion_status": "answered", "title": "Weights",
            "result_markdown": "Weights differ between layers [p. 1].", "evidence_segment_ids": [id.description], "final_draft_revision": 0, "terminate": true])
    }
    private static func call(_ id: String, name: String, arguments: [String: Any]) throws -> AIToolProviderTurn {
        .init(responseID: id, toolCalls: [.init(callID: id, name: name, arguments: try JSONSerialization.data(withJSONObject: arguments))],
              structuredFinalResult: nil, inputTokens: 10)
    }
    private static func reviewTurn(_ data: Data, id: String) -> AIToolProviderTurn {
        .init(responseID: id, toolCalls: [.init(callID: id, name: AIAnswerEvidenceReview.toolName, arguments: data)], structuredFinalResult: nil, inputTokens: 10)
    }
    private actor Provider: AIToolCallingProvider {
        nonisolated let toolCapabilities = AIToolProviderCapabilities(supportsFunctionTools: true, supportsStrictToolSchemas: true,
            supportsResponseContinuation: true, supportsStructuredFinalResult: false)
        var turns: [AIToolProviderTurn]
        var calls = 0
        var discards: [UUID] = []
        var continuations: [AIToolWorkflowContinuationRequest] = []
        init(_ turns: [AIToolProviderTurn]) { self.turns = turns }
        func beginToolWorkflow(_ request: AIToolWorkflowProviderRequest) throws -> AIToolProviderTurn { try next() }
        func continueToolWorkflow(_ request: AIToolWorkflowContinuationRequest) throws -> AIToolProviderTurn {
            continuations.append(request); return try next()
        }
        func discardToolWorkflow(_ id: UUID) { discards.append(id) }
        func next() throws -> AIToolProviderTurn {
            try Task.checkCancellation()
            calls += 1
            guard !turns.isEmpty else { throw AIProviderError.emptyResponse }
            return turns.removeFirst()
        }
    }
}
