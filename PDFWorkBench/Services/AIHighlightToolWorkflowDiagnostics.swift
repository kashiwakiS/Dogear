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
        let service = AIHighlightWorkflowService()
        do {
            let result = try await service.generateDraft(
                snapshot: snapshot,
                intent: .overview,
                provider: provider
            )
            check(result.revision == 1, "The workflow did not produce revision 1.")
            check(result.title == "Reproducible Finding", "The workflow title was not retained.")
            check(result.highlights.count == 1, "The workflow did not stage one highlight.")
            check(result.usage.toolCalls == 3, "Tool call usage was not counted.")
            check(result.usage.providerTurns == 4, "Provider turn usage was not counted.")
            check(result.usage.readCharacters > 0, "Read characters were not counted.")
        } catch {
            check(false, "Scripted workflow failed: \(error.localizedDescription)")
        }

        let boundedProvider = ScriptedToolProvider(turns: calls)
        do {
            _ = try await service.generateDraft(
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
        return [
            turn(id: "response-1", callID: "call-search", name: AIHighlightToolName.searchSegments, arguments: search),
            turn(id: "response-2", callID: "call-read", name: AIHighlightToolName.readSegments, arguments: read),
            turn(id: "response-3", callID: "call-stage", name: AIHighlightToolName.stageHighlights, arguments: stage),
            AIToolProviderTurn(
                responseID: "response-4",
                toolCalls: [],
                structuredFinalResult: nil,
                inputTokens: 10
            )
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

    init(turns: [AIToolProviderTurn]) {
        self.turns = turns
    }

    func beginToolWorkflow(
        _ request: AIToolWorkflowProviderRequest
    ) throws -> AIToolProviderTurn {
        try nextTurn()
    }

    func continueToolWorkflow(
        _ request: AIToolWorkflowContinuationRequest
    ) throws -> AIToolProviderTurn {
        try nextTurn()
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
