import Foundation

nonisolated enum AIHighlightToolWorkflowDiagnostics {
    struct Report: Equatable, Sendable {
        let checks: Int
        let failures: [String]
    }

    static func run() async -> Report {
        var checks = 0
        var failures: [String] = []

        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }

        for definition in AIHighlightToolCodec.definitions {
            check(
                (try? JSONSerialization.jsonObject(with: definition.strictInputSchema)) != nil,
                "Invalid JSON schema for \(definition.name)."
            )
        }

        let snapshot = AIHighlightTextSnapshot(
            fingerprint: "workflow-diagnostic",
            pages: [
                AITextPageSnapshot(
                    pageNumber: 1,
                    text: "The primary finding is reproducible. A limitation remains.",
                    fingerprint: "workflow-page-1"
                )
            ]
        )
        guard let registry = try? AISegmentRegistry(snapshot: snapshot),
              let first = registry.records.first
        else {
            return Report(
                checks: checks + 1,
                failures: failures + ["Diagnostic snapshot produced no segments."]
            )
        }

        let calls = scriptedCalls(segmentID: first.id)
        let provider = ScriptedToolProvider(turns: calls)
        let traceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DogearWorkflowDiagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: traceRoot) }
        let service = AIHighlightWorkflowService(
            runner: AIToolWorkflowRunner(),
            traceRecorder: AIHighlightTraceRecorder(
                fileURL: traceRoot.appendingPathComponent("trace.jsonl")
            )
        )
        do {
            let result = try await service.generateReadingResult(
                snapshot: snapshot,
                intent: .overview,
                provider: provider
            )
            check(result.answer.finalDraftRevision == 1, "The workflow did not produce revision 1.")
            check(result.answer.title == "Reproducible Finding", "The workflow title was not retained.")
            check(result.highlights.count == 1, "The workflow did not stage one highlight.")
            check(result.usage.toolCalls == 4, "Tool call usage was not counted.")
            check(result.usage.providerTurns == 4, "Provider turn usage was not counted.")
            check(result.usage.readCharacters > 0, "Read characters were not counted.")
            let conversation = await provider.recordedRequests()
            check(conversation.continuations.count == 3, "A receipt or extra request was sent after termination.")
            check(conversation.discarded.count == 1, "Terminal conversation state was not discarded.")
            check(conversation.instructions.contains("exactly ONE tool call"), "The final-only prompt contract is missing.")
        } catch {
            check(false, "Scripted workflow failed: \(error.localizedDescription)")
        }

        let boundedProvider = ScriptedToolProvider(turns: calls)
        do {
            _ = try await service.generateReadingResult(
                snapshot: snapshot,
                intent: .overview,
                provider: boundedProvider,
                budget: AIWorkflowBudget(
                    maximumProviderTurns: 1,
                    maximumToolCalls: 24,
                    maximumReadCharacters: 60_000,
                    maximumInputTokens: nil,
                    maximumDuration: .seconds(180)
                )
            )
            check(false, "The provider-turn budget was not enforced.")
        } catch AIWorkflowFoundationError.budgetExceeded(.providerTurns) {
            check(true, "")
            let remainingTurnCount = await boundedProvider.remainingTurnCount()
            check(
                remainingTurnCount == calls.count - 1,
                "The runner contacted the provider after exhausting its turn budget."
            )
        } catch {
            check(false, "The wrong budget error was returned: \(error.localizedDescription)")
        }

        // Terminal requests in mixed batches must never be accepted/published,
        // regardless of their position. Other tools can still repair the draft.
        for finalFirst in [true, false] {
            let terminal = calls[3].toolCalls[0]
            let stage = calls[2].toolCalls[0]
            let mixed = AIToolProviderTurn(
                responseID: "mixed", toolCalls: finalFirst ? [terminal, stage] : [stage, terminal],
                structuredFinalResult: nil, inputTokens: 10
            )
            let corrected = turn(
                id: "corrected", callID: "publish-corrected",
                name: terminal.name, arguments: terminal.arguments
            )
            let mixedProvider = ScriptedToolProvider(turns: [calls[0], calls[1], mixed, corrected])
            do {
                let result = try await service.generateReadingResult(
                    snapshot: snapshot, intent: .overview, provider: mixedProvider
                )
                let requests = await mixedProvider.recordedRequests()
                let outputs = requests.continuations.last?.toolOutputs ?? []
                let rejected = outputs.first { $0.callID == terminal.callID }
                let publication = try rejected.map { try AIHighlightToolCodec().decodePublishResult($0.output) }
                check(publication?.accepted == false && publication?.error == .terminalMustBeSoleCall,
                      "Mixed terminal batch was not rejected before publication (finalFirst=\(finalFirst)).")
                check(publication?.publication == nil, "Mixed terminal batch leaked an accepted answer.")
                check(result.answer.finalDraftRevision == 1 && result.highlights.count == 1,
                      "Mixed batch repair lost the confirmed draft.")
                check(requests.continuations.count == 3 && requests.discarded.count == 1,
                      "Corrected terminal publication made an extra provider request.")
            } catch { check(false, "Mixed terminal repair failed: \(error.localizedDescription)") }
        }

        // A failed companion stage cannot strand an already accepted terminal.
        let invalidStage = AIToolInvocation(
            callID: "invalid-stage", name: AIHighlightToolName.stageHighlights,
            arguments: Data("""
            {"draft_revision":99,"title":"Wrong revision","items":[]}
            """.utf8)
        )
        let invalidBatch = AIToolProviderTurn(
            responseID: "invalid-batch", toolCalls: [calls[3].toolCalls[0], invalidStage],
            structuredFinalResult: nil, inputTokens: 10
        )
        let repairedTerminal = turn(
            id: "repaired-terminal", callID: "repaired-terminal",
            name: AIHighlightToolName.publishAnswer, arguments: calls[3].toolCalls[0].arguments
        )
        let repairProvider = ScriptedToolProvider(turns: Array(calls.prefix(3)) + [invalidBatch, repairedTerminal])
        do {
            let result = try await service.generateReadingResult(
                snapshot: snapshot, intent: .overview, provider: repairProvider
            )
            let requests = await repairProvider.recordedRequests()
            let outputs = requests.continuations.last?.toolOutputs ?? []
            let stageOutput = outputs.first { $0.callID == "invalid-stage" }
            let stageJSON = try stageOutput.flatMap { try JSONSerialization.jsonObject(with: $0.output) as? [String: Any] }
            check(stageJSON?["applied"] as? Bool == false, "Invalid companion stage was not rejected.")
            check(result.highlights.count == 1 && result.answer.finalDraftRevision == 1,
                  "Failed companion output damaged the prior valid draft.")
            check(requests.continuations.count == 4, "Repair after a mixed-batch rejection did not stop at the corrected final.")
        } catch { check(false, "Failed companion repair workflow failed: \(error.localizedDescription)") }

        // A final answer on the last budgeted turn succeeds with no extra call.
        let exactLimitProvider = ScriptedToolProvider(turns: calls)
        do {
            var exactBudget = AIWorkflowBudget.highlightDefault
            exactBudget.maximumProviderTurns = calls.count
            _ = try await service.generateReadingResult(
                snapshot: snapshot, intent: .overview, provider: exactLimitProvider, budget: exactBudget
            )
            let requests = await exactLimitProvider.recordedRequests()
            check(requests.continuations.count == 3, "Final budgeted turn required an extra request.")
        } catch { check(false, "Final budgeted turn failed: \(error.localizedDescription)") }

        // No highlights are required; interim text must still continue normally.
        let interimArguments = Data("""
        {"completion_status":"notFound","title":"Evidence check","result_markdown":"Checking the available evidence.","evidence_segment_ids":[],"final_draft_revision":0,"terminate":false}
        """.utf8)
        let finalArguments = Data("""
        {"completion_status":"notFound","title":"Evidence check","result_markdown":"The document does not establish this claim.","evidence_segment_ids":[],"final_draft_revision":0,"terminate":true}
        """.utf8)
        let answerOnlyProvider = ScriptedToolProvider(turns: [
            turn(id: "interim", callID: "interim", name: AIHighlightToolName.publishAnswer, arguments: interimArguments),
            turn(id: "answer-only", callID: "answer-only", name: AIHighlightToolName.publishAnswer, arguments: finalArguments)
        ])
        do {
            let result = try await service.generateReadingResult(
                snapshot: snapshot, intent: .overview, provider: answerOnlyProvider
            )
            let requests = await answerOnlyProvider.recordedRequests()
            check(result.highlights.isEmpty && result.answer.terminate, "Answer-only termination failed.")
            check(requests.continuations.count == 1 && requests.continuations.first?.previousResponseID == "interim",
                  "Interim publication did not continue its provider conversation.")
        } catch { check(false, "Answer-only workflow failed: \(error.localizedDescription)") }

        return Report(checks: checks, failures: failures)
    }

    private static func scriptedCalls(segmentID: AISegmentID) -> [AIToolProviderTurn] {
        let search = Data(
            """
            {"query":"primary finding","page_start":1,"page_end":1,"top_k":5,"strategy":"overviewSalience"}
            """.utf8
        )
        let read = Data(
            """
            {"ids":["\(segmentID)"],"context_before":0,"context_after":0}
            """.utf8
        )
        let stage = Data(
            """
            {"draft_revision":0,"title":"Reproducible Finding","items":[{"candidate_id":"finding-1","segment_ids":["\(segmentID)"],"category":"keyFinding","importance":5,"note":"Core result"}]}
            """.utf8
        )
        let publish = Data(
            """
            {"completion_status":"answered","title":"Reproducible Finding","result_markdown":"The finding is reproducible [p. 1].","evidence_segment_ids":["\(segmentID)"],"final_draft_revision":1,"terminate":true}
            """.utf8
        )
        return [
            turn(id: "response-1", callID: "call-search", name: AIHighlightToolName.searchSegments, arguments: search),
            turn(id: "response-2", callID: "call-read", name: AIHighlightToolName.readSegments, arguments: read),
            turn(id: "response-3", callID: "call-stage", name: AIHighlightToolName.stageHighlights, arguments: stage),
            turn(id: "response-4", callID: "call-publish", name: AIHighlightToolName.publishAnswer, arguments: publish)
        ]
    }

    private static func turn(
        id: String,
        callID: String,
        name: String,
        arguments: Data
    ) -> AIToolProviderTurn {
        AIToolProviderTurn(
            responseID: id,
            toolCalls: [
                AIToolInvocation(callID: callID, name: name, arguments: arguments)
            ],
            structuredFinalResult: nil,
            inputTokens: 10
        )
    }
}

private actor ScriptedToolProvider: AIToolCallingProvider {
    nonisolated let toolCapabilities = AIToolProviderCapabilities(
        supportsFunctionTools: true,
        supportsStrictToolSchemas: true,
        supportsResponseContinuation: true,
        supportsStructuredFinalResult: false
    )

    private var turns: [AIToolProviderTurn]
    private var continuations: [AIToolWorkflowContinuationRequest] = []
    private var discarded: [UUID] = []
    private var instructions = ""

    init(turns: [AIToolProviderTurn]) {
        self.turns = turns
    }

    func beginToolWorkflow(
        _ request: AIToolWorkflowProviderRequest
    ) throws -> AIToolProviderTurn {
        instructions = request.instructions
        return try nextTurn()
    }

    func continueToolWorkflow(
        _ request: AIToolWorkflowContinuationRequest
    ) throws -> AIToolProviderTurn {
        continuations.append(request)
        return try nextTurn()
    }

    func discardToolWorkflow(_ workflowID: UUID) { discarded.append(workflowID) }

    func recordedRequests() -> (continuations: [AIToolWorkflowContinuationRequest], discarded: [UUID], instructions: String) {
        (continuations, discarded, instructions)
    }

    private func nextTurn() throws -> AIToolProviderTurn {
        guard !turns.isEmpty else {
            throw AIProviderError.emptyResponse
        }
        return turns.removeFirst()
    }

    func remainingTurnCount() -> Int {
        turns.count
    }
}
