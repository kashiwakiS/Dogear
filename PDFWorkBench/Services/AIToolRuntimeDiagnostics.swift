import Foundation

/// Provider-neutral runtime fixtures. No configured provider, credentials,
/// document content, or network transport participates in these checks.
nonisolated enum AIToolRuntimeDiagnostics {
    struct Report: Sendable {
        let checks: Int
        let failures: [String]
    }

    static func run() async -> Report {
        var checks = 0
        var failures: [String] = []
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !value() { failures.append(message) }
        }
        let defaults = AIWorkflowBudget.highlightDefault
        check(defaults.maximumProviderTurns == 20, "Default logical provider-turn limit is not 20.")
        check(defaults.maximumToolCalls > 0 && defaults.maximumReadCharacters > 0
              && defaults.maximumInputTokens != nil && defaults.maximumDuration > .zero
              && defaults.maximumConsecutiveNonProgressTurns > 0,
              "An independent runtime limit disappeared.")
        check(defaults.exceededMetric(for: AIWorkflowUsage(
            providerTurns: defaults.maximumProviderTurns,
            toolCalls: defaults.maximumToolCalls,
            readCharacters: defaults.maximumReadCharacters,
            inputTokens: defaults.maximumInputTokens,
            elapsed: defaults.maximumDuration
        )) == nil, "Exact budget boundaries must remain inclusive.")
        check(defaults.exceededMetric(for: AIWorkflowUsage(inputTokens: nil)) == nil,
              "Unknown provider token usage was treated as an invented count.")

        let twentyTurns = (0..<20).map { index in
            Step.turn(turn(index, toolNames: [index == 19 ? "finish" : "read"]))
        }
        let exact = await runCase(steps: twentyTurns)
        check(exact.result?.usage.providerTurns == 20 && exact.requests == 20,
              "A terminal answer on logical turn 20 did not finish within the budget.")
        check(exact.executions == 20 && exact.discards == 1,
              "Exact-limit completion executed extra work or did not dispose its continuation.")
        checkDisposed(exact, label: "success") { check($0, $1) }

        let overflow = await runCase(steps: (0..<21).map {
            .turn(turn($0, toolNames: ["read"]))
        })
        check(overflow.error == .budgetExceeded(.providerTurns) && overflow.requests == 20,
              "The runner contacted the provider for logical turn 21.")
        checkDisposed(overflow, label: "budget failure") { check($0, $1) }

        var toolsBudget = defaults
        toolsBudget.maximumToolCalls = 1
        let tools = await runCase(steps: [.turn(turn(0, toolNames: ["read", "read"]))], budget: toolsBudget)
        check(tools.error == .budgetExceeded(.toolCalls) && tools.executions == 1 && tools.requests == 1,
              "The tool limit was not checked before the second local operation.")

        var readBudget = defaults
        readBudget.maximumReadCharacters = 3
        let read = await runCase(steps: [.turn(turn(0, toolNames: ["read"]))],
                                 budget: readBudget, readCharacters: 4)
        check(read.error == .budgetExceeded(.readCharacters) && read.executions == 1 && read.requests == 1,
              "Over-budget local text reached a provider continuation.")
        check(!read.events.contains { if case .toolFinished = $0 { true } else { false } },
              "Over-budget tool text was published before the read limit was checked.")

        var tokenBudget = defaults
        tokenBudget.maximumInputTokens = 20
        let tokens = await runCase(steps: [.turn(turn(0, toolNames: ["read"], inputTokens: 21))], budget: tokenBudget)
        check(tokens.error == .budgetExceeded(.inputTokens) && tokens.executions == 0 && tokens.requests == 1,
              "Reported token overflow did not stop subsequent tool work.")
        check(tokens.events.contains { event in
            if case .providerTurnFinished(_, _, 21, _, _) = event { true } else { false }
        }, "The turn whose reported tokens exceeded the limit was omitted from diagnostics.")
        let cumulativeTokens = await runCase(steps: [
            .turn(turn(0, toolNames: ["read"], inputTokens: 10)),
            .turn(turn(1, toolNames: ["read"], inputTokens: 11))
        ], budget: tokenBudget)
        check(cumulativeTokens.error == .budgetExceeded(.inputTokens) && cumulativeTokens.executions == 1,
              "Provider-reported input tokens were not accumulated across turns.")
        let unknownTokens = await runCase(steps: [.turn(turn(0, toolNames: ["finish"], inputTokens: nil))], budget: tokenBudget)
        check(unknownTokens.succeeded && unknownTokens.result?.usage.inputTokens == nil,
              "An omitted usage field prevented valid completion or fabricated token usage.")

        var zeroTime = defaults
        zeroTime.maximumDuration = .zero
        let expired = await runCase(steps: [.turn(turn(0, toolNames: ["finish"]))], budget: zeroTime)
        check(expired.error == .budgetExceeded(.elapsedTime) && expired.requests == 0,
              "An already-expired workflow contacted the provider.")
        var shortTime = defaults
        shortTime.maximumDuration = .milliseconds(40)
        let deadline = await runCase(steps: [.slowTurn(turn(0, toolNames: ["finish"]), .seconds(2))], budget: shortTime)
        check(deadline.error == .budgetExceeded(.elapsedTime) && deadline.duration < .milliseconds(800),
              "The elapsed-time limit did not cancel an in-flight cooperative provider request.")
        let delayedTool = await runCase(steps: [.turn(turn(0, toolNames: ["read"]))],
                                       budget: shortTime, progressDelay: .milliseconds(80))
        check(delayedTool.error == .budgetExceeded(.elapsedTime) && delayedTool.executions == 0,
              "A suspended tool-start callback let local execution begin after its deadline.")

        let quickRetry = AIWorkflowRetryPolicy(maximumAttempts: 2, initialDelay: .zero, maximumDelay: .zero)
        let retried = await runCase(steps: [.httpFailure(503), .turn(turn(0, toolNames: ["finish"]))], retryPolicy: quickRetry)
        check(retried.succeeded && retried.requests == 2 && retried.result?.usage.providerTurns == 1,
              "Transient retry was not bounded separately from logical provider turns.")
        check(retried.events.filter { if case .retryScheduled = $0 { true } else { false } }.count == 1,
              "Transient retry did not emit one retry event.")
        let exhausted = await runCase(steps: [.httpFailure(503), .httpFailure(503), .turn(turn(0, toolNames: ["finish"]))], retryPolicy: quickRetry)
        check(!exhausted.succeeded && exhausted.requests == 2 && exhausted.discards == 1,
              "Transport retry exceeded its independent attempt limit.")
        for status in [400, 401, 403, 404, 422, 600] {
            let permanent = await runCase(steps: [.httpFailure(status), .turn(turn(0, toolNames: ["finish"]))], retryPolicy: quickRetry)
            check(!permanent.succeeded && permanent.requests == 1,
                  "Non-transient HTTP \(status) was retried.")
        }
        for status in [429, 500, 502, 503, 599] {
            check(AIToolWorkflowRunner.isTransientError(AIProviderError.server(statusCode: status, message: "fixture")),
                  "Transient HTTP \(status) was not recognized.")
        }
        for code in [URLError.timedOut, .networkConnectionLost, .cannotConnectToHost] {
            check(AIToolWorkflowRunner.isTransientError(URLError(code)), "Transient URL error was not recognized.")
        }
        for error: Error in [URLError(.cancelled), URLError(.badURL), AIProviderError.invalidResponse, AIProviderError.missingAPIKey, CancellationError()] {
            check(!AIToolWorkflowRunner.isTransientError(error), "A permanent/cancellation error was classified as transient.")
        }
        let delayedRetry = await runCase(steps: [.httpFailure(503), .turn(turn(0, toolNames: ["finish"]))], budget: shortTime)
        check(delayedRetry.error == .budgetExceeded(.elapsedTime) && delayedRetry.requests == 1
              && delayedRetry.duration < .milliseconds(800),
              "Retry backoff waited beyond the remaining workflow time budget.")

        let firstArguments = Data("{\"query\":\"evidence\",\"top_k\":5}".utf8)
        let reorderedArguments = Data("{ \"top_k\" : 5, \"query\" : \"evidence\" }".utf8)
        let repeated = await runCase(steps: [
            .turn(turn(0, toolNames: ["read"], arguments: firstArguments)),
            .turn(turn(1, toolNames: ["read"], arguments: reorderedArguments)),
            .turn(turn(2, toolNames: ["read"], arguments: firstArguments))
        ])
        check(repeated.error == .noProgress && repeated.requests == 3 && repeated.executions == 2,
              "Canonical JSON/call-ID-independent no-progress detection failed.")
        check(repeated.events.contains(.noProgress), "No-progress termination was not traced.")

        do {
            let stageItems: [[String: Any]] = [
                ["candidate_id": "first", "segment_ids": ["D001.P001.B001.S001"],
                 "category": "directAnswer", "importance": 5, "note": "First note"],
                ["candidate_id": "second", "segment_ids": ["D001.P001.B001.S002"],
                 "category": "supportingEvidence", "importance": 4, "note": "Second note"]
            ]
            let stageArguments: [String: Any] = [
                "draft_revision": 1, "title": "Evidence", "items": stageItems
            ]
            func stageTurn(_ index: Int, arguments: [String: Any]) throws -> AIToolProviderTurn {
                turn(index, toolNames: ["stage_highlights"], arguments: try JSONSerialization.data(
                    withJSONObject: arguments, options: [.sortedKeys]
                ))
            }
            let firstStage = try stageTurn(0, arguments: stageArguments)
            let firstSignature = AIToolWorkflowRunner.signature(of: firstStage)
            let renamedStages = try (1...2).map { index in
                var arguments = stageArguments
                arguments["items"] = stageItems.enumerated().map { offset, item in
                    var renamed = item
                    renamed["candidate_id"] = "new-\(index)-\(offset)"
                    return renamed
                }
                return try stageTurn(index, arguments: arguments)
            }
            check(renamedStages.allSatisfy {
                AIToolWorkflowRunner.signature(of: $0) == firstSignature
            }, "Renamed transient candidate IDs changed a staging signature.")
            let renamedLoop = await runCase(steps: ([firstStage] + renamedStages).map(Step.turn))
            check(renamedLoop.error == .noProgress && renamedLoop.requests == 3 && renamedLoop.executions == 2,
                  "Renaming stage candidate IDs bypassed consecutive no-progress detection.")

            for (field, replacement): (String, Any) in [
                ("note", "Updated note"), ("category", "limitation"), ("importance", 3),
                ("segment_ids", ["D001.P001.B001.S003"])
            ] {
                var items = stageItems
                items[0][field] = replacement
                var arguments = stageArguments
                arguments["items"] = items
                let changed = try stageTurn(1, arguments: arguments)
                check(AIToolWorkflowRunner.signature(of: changed) != firstSignature,
                      "Staging signature ignored a meaningful \(field) change.")
            }
            for (field, replacement): (String, Any) in [("title", "Revised evidence"), ("draft_revision", 2)] {
                var arguments = stageArguments
                arguments[field] = replacement
                let changed = try stageTurn(1, arguments: arguments)
                check(AIToolWorkflowRunner.signature(of: changed) != firstSignature,
                      "Staging signature ignored \(field).")
            }
            var reorderedStage = stageArguments
            reorderedStage["items"] = Array(stageItems.reversed())
            let reorderedStageTurn = try stageTurn(1, arguments: reorderedStage)
            check(AIToolWorkflowRunner.signature(of: reorderedStageTurn) != firstSignature,
                  "Staging signature discarded item array order.")

            var orderedSegments = stageItems
            orderedSegments[0]["segment_ids"] = ["D001.P001.B001.S001", "D001.P001.B001.S002"]
            var orderedArguments = stageArguments
            orderedArguments["items"] = orderedSegments
            let orderedTurn = try stageTurn(0, arguments: orderedArguments)
            orderedSegments[0]["segment_ids"] = ["D001.P001.B001.S002", "D001.P001.B001.S001"]
            orderedArguments["items"] = orderedSegments
            let reversedSegmentsTurn = try stageTurn(1, arguments: orderedArguments)
            check(AIToolWorkflowRunner.signature(of: orderedTurn) != AIToolWorkflowRunner.signature(of: reversedSegmentsTurn),
                  "Staging signature discarded segment ID array order.")

            var rootCandidate = stageArguments
            rootCandidate["candidate_id"] = "outside-items"
            let rootCandidateTurn = try stageTurn(1, arguments: rootCandidate)
            check(AIToolWorkflowRunner.signature(of: rootCandidateTurn) != firstSignature,
                  "Candidate-ID normalization removed a field outside the staging items.")

            var updatedItems = stageItems
            updatedItems[0]["note"] = "An actual revised note"
            var updatedArguments = stageArguments
            updatedArguments["items"] = updatedItems
            let updatedTurn = try stageTurn(2, arguments: updatedArguments)
            let repairedLoop = await runCase(steps: [
                .turn(firstStage), .turn(renamedStages[0]), .turn(updatedTurn),
                .turn(turn(3, toolNames: ["finish"]))
            ])
            check(repairedLoop.succeeded && repairedLoop.requests == 4 && repairedLoop.executions == 4,
                  "A meaningful stage-note update did not reset the no-progress streak.")

            for name in ["read_segments", "search_segments", "other_tool"] {
                let original = turn(0, toolNames: [name], arguments: firstStage.toolCalls[0].arguments)
                let renamed = turn(1, toolNames: [name], arguments: renamedStages[0].toolCalls[0].arguments)
                check(AIToolWorkflowRunner.signature(of: original) != AIToolWorkflowRunner.signature(of: renamed),
                      "The candidate-ID exception leaked into \(name).")
            }
            let firstRead = turn(0, toolNames: ["read_segments"], arguments: Data(
                "{\"ids\":[\"D001.P001.B001.S001\"],\"context_before\":0,\"context_after\":0}".utf8
            ))
            let differentRead = turn(1, toolNames: ["read_segments"], arguments: Data(
                "{\"ids\":[\"D001.P001.B001.S002\"],\"context_before\":0,\"context_after\":0}".utf8
            ))
            check(AIToolWorkflowRunner.signature(of: firstRead) != AIToolWorkflowRunner.signature(of: differentRead),
                  "Read evidence IDs disappeared from the no-progress signature.")
        } catch {
            check(false, "Could not construct semantic staging signature fixtures: \(error.localizedDescription)")
        }

        for cancellation in [CancellationPoint.beforeStart, .toolStarted, .toolFinished, .emptyProviderFinished, .validatedDraft, .retryScheduled] {
            let steps: [Step] = switch cancellation {
            case .emptyProviderFinished, .validatedDraft: [.turn(turn(0, toolNames: []))]
            case .retryScheduled: [.httpFailure(503), .turn(turn(0, toolNames: ["finish"]))]
            default: [.turn(turn(0, toolNames: ["read", "read"])), .turn(turn(1, toolNames: ["finish"]))]
            }
            let canceled = await runCase(steps: steps, cancellation: cancellation)
            check(canceled.cancelled && !canceled.events.contains(.completed),
                  "Cancellation at \(cancellation) was reported as completed.")
            let expectedExecutions = cancellation == .toolFinished ? 1 : 0
            check(canceled.executions == expectedExecutions && canceled.requests <= 1,
                  "Cancellation at \(cancellation) executed a later tool/continuation.")
            checkDisposed(canceled, label: "cancellation at \(cancellation)") { check($0, $1) }
        }
        return Report(checks: checks, failures: failures)
    }

    private static func checkDisposed(_ outcome: Outcome, label: String, check: (Bool, String) -> Void) {
        let disposalEvents = outcome.events.filter { if case .continuationDisposed = $0 { true } else { false } }
        check(outcome.discards == 1 && disposalEvents.count == 1,
              "\(label) did not dispose and trace continuation disposal exactly once.")
    }

    private static func turn(_ index: Int, toolNames: [String], arguments: Data? = nil, inputTokens: Int? = 10) -> AIToolProviderTurn {
        AIToolProviderTurn(responseID: "response-\(index)", toolCalls: toolNames.enumerated().map { offset, name in
            AIToolInvocation(callID: "call-\(index)-\(offset)", name: name,
                             arguments: arguments ?? Data("{\"index\":\(index)}".utf8))
        }, structuredFinalResult: nil, inputTokens: inputTokens)
    }

    private enum Step: Sendable {
        case turn(AIToolProviderTurn)
        case httpFailure(Int)
        case slowTurn(AIToolProviderTurn, Duration)
    }

    private enum CancellationPoint: Equatable, Sendable {
        case beforeStart, toolStarted, toolFinished, emptyProviderFinished, validatedDraft, retryScheduled
    }

    private struct Outcome {
        let result: AIToolWorkflowRunResult?
        let error: AIWorkflowFoundationError?
        let cancelled: Bool
        let events: [AIWorkflowEvent]
        let requests: Int
        let executions: Int
        let discards: Int
        let duration: Duration
        var succeeded: Bool { result != nil }
    }

    private static func runCase(
        steps: [Step],
        budget: AIWorkflowBudget = .highlightDefault,
        retryPolicy: AIWorkflowRetryPolicy = .conservative,
        readCharacters: Int = 1,
        cancellation: CancellationPoint? = nil,
        progressDelay: Duration? = nil
    ) async -> Outcome {
        let provider = Provider(steps: steps)
        let executor = Executor(readCharacters: readCharacters)
        let trace = AIInMemoryWorkflowTraceSink()
        let request = AIToolWorkflowProviderRequest(workflowID: UUID(), instructions: "runtime fixture", input: "fixture", tools: [])
        let started = ContinuousClock.now
        let task = Task {
            if cancellation == .beforeStart { withUnsafeCurrentTask { $0?.cancel() } }
            return try await AIToolWorkflowRunner(traceSink: trace).run(
                request: request, provider: provider, executor: executor,
                budget: budget, retryPolicy: retryPolicy,
                progress: { event in
                    if case .toolStarted = event, let progressDelay {
                        try? await Task.sleep(for: progressDelay)
                    }
                    let shouldCancel: Bool = switch (cancellation, event) {
                    case (.toolStarted, .toolStarted), (.toolFinished, .toolFinished),
                         (.validatedDraft, .phaseChanged(.validatedDraft)),
                         (.emptyProviderFinished, .providerTurnFinished), (.retryScheduled, .retryScheduled): true
                    default: false
                    }
                    if shouldCancel { withUnsafeCurrentTask { $0?.cancel() } }
                }
            )
        }
        var result: AIToolWorkflowRunResult?
        var caught: AIWorkflowFoundationError?
        var cancelled = false
        do { result = try await task.value }
        catch is CancellationError { cancelled = true }
        catch { caught = error as? AIWorkflowFoundationError }
        return Outcome(result: result, error: caught, cancelled: cancelled,
                       events: await trace.events, requests: await provider.requests,
                       executions: await executor.executions, discards: await provider.discards,
                       duration: started.duration(to: .now))
    }

    private actor Provider: AIToolCallingProvider {
        nonisolated let toolCapabilities = AIToolProviderCapabilities(
            supportsFunctionTools: true, supportsStrictToolSchemas: true,
            supportsResponseContinuation: true, supportsStructuredFinalResult: false
        )
        private var steps: [Step]
        private(set) var requests = 0
        private(set) var discards = 0
        init(steps: [Step]) { self.steps = steps }
        func beginToolWorkflow(_ request: AIToolWorkflowProviderRequest) async throws -> AIToolProviderTurn { try await next() }
        func continueToolWorkflow(_ request: AIToolWorkflowContinuationRequest) async throws -> AIToolProviderTurn { try await next() }
        func discardToolWorkflow(_ workflowID: UUID) { discards += 1 }
        private func next() async throws -> AIToolProviderTurn {
            requests += 1
            guard !steps.isEmpty else { throw AIProviderError.emptyResponse }
            switch steps.removeFirst() {
            case .turn(let turn): return turn
            case .httpFailure(let status): throw AIProviderError.server(statusCode: status, message: "fixture")
            case .slowTurn(let turn, let delay):
                try await Task.sleep(for: delay)
                return turn
            }
        }
    }

    private actor Executor: AIToolExecuting {
        let readCharacters: Int
        private(set) var executions = 0
        init(readCharacters: Int) { self.readCharacters = readCharacters }
        func execute(_ invocation: AIToolInvocation) -> AIToolExecutionResult {
            executions += 1
            return AIToolExecutionResult(callID: invocation.callID, output: Data("{}".utf8),
                                         readCharacterCount: readCharacters,
                                         disposition: invocation.name == "finish" ? .requestTermination : .continueWorkflow)
        }
    }
}
