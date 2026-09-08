import Foundation

nonisolated enum AIWorkflowPhase: String, Codable, Equatable, Sendable {
    case idle
    case preparingSnapshot
    case runningTools
    case validatedDraft
    case committingBatch
    case completed
    case cancelled
    case failed
}

nonisolated enum AIWorkflowBudgetMetric: String, Codable, Equatable, Sendable {
    case providerTurns
    case toolCalls
    case readCharacters
    case inputTokens
    case elapsedTime
}

nonisolated struct AIWorkflowBudget: Equatable, Sendable {
    var maximumProviderTurns: Int
    var maximumToolCalls: Int
    var maximumReadCharacters: Int
    var maximumInputTokens: Int?
    var maximumDuration: Duration
    var maximumConsecutiveNonProgressTurns: Int = 3

    static let highlightDefault = AIWorkflowBudget(
        maximumProviderTurns: 20,
        maximumToolCalls: 24,
        maximumReadCharacters: 60_000,
        maximumInputTokens: 300_000,
        maximumDuration: .seconds(180),
        maximumConsecutiveNonProgressTurns: 3
    )

    func exceededMetric(for usage: AIWorkflowUsage) -> AIWorkflowBudgetMetric? {
        if usage.providerTurns > maximumProviderTurns { return .providerTurns }
        if usage.toolCalls > maximumToolCalls { return .toolCalls }
        if usage.readCharacters > maximumReadCharacters { return .readCharacters }
        if let maximumInputTokens,
           let inputTokens = usage.inputTokens,
           inputTokens > maximumInputTokens
        {
            return .inputTokens
        }
        if usage.elapsed > maximumDuration { return .elapsedTime }
        return nil
    }
}

nonisolated struct AIWorkflowToolCallSignature: Equatable, Sendable {
    let name: String
    let arguments: Data
}

nonisolated struct AIWorkflowUsage: Equatable, Sendable {
    var providerTurns = 0
    var toolCalls = 0
    var readCharacters = 0
    var inputTokens: Int?
    var elapsed: Duration = .zero
}

nonisolated struct AIWorkflowRetryPolicy: Equatable, Sendable {
    var maximumAttempts: Int
    var initialDelay: Duration
    var maximumDelay: Duration

    static let conservative = AIWorkflowRetryPolicy(
        maximumAttempts: 2,
        initialDelay: .seconds(1),
        maximumDelay: .seconds(4)
    )

    func delay(afterAttempt attempt: Int) -> Duration? {
        guard attempt > 0, attempt < maximumAttempts else { return nil }
        let multiplier = 1 << min(attempt - 1, 16)
        return min(initialDelay * multiplier, maximumDelay)
    }
}

nonisolated enum AIWorkflowEvent: Equatable, Sendable {
    case started(workflowID: UUID)
    case phaseChanged(AIWorkflowPhase)
    case providerTurnStarted(index: Int)
    case providerTurnFinished(
        index: Int,
        responseID: String?,
        inputTokens: Int?,
        toolCallCount: Int,
        hasStructuredFinalResult: Bool
    )
    case toolStarted(callID: String, name: String, arguments: Data)
    case toolFinished(
        callID: String,
        name: String,
        output: Data,
        readCharacters: Int
    )
    case retryScheduled(attempt: Int)
    case budgetExceeded(AIWorkflowBudgetMetric)
    case noProgress
    case evidenceReviewStarted
    case continuationDisposed
    case completed
    case cancelled
    case failed(code: String)
}

nonisolated protocol AIWorkflowTraceSink: Sendable {
    func record(_ event: AIWorkflowEvent, workflowID: UUID?) async
}

nonisolated struct AINullWorkflowTraceSink: AIWorkflowTraceSink {
    func record(_ event: AIWorkflowEvent, workflowID: UUID?) async {}
}

actor AIInMemoryWorkflowTraceSink: AIWorkflowTraceSink {
    private(set) var events: [AIWorkflowEvent] = []

    func record(_ event: AIWorkflowEvent, workflowID: UUID?) {
        events.append(event)
    }
}

nonisolated struct AIToolDefinition: Equatable, Sendable {
    let name: String
    let description: String
    let schemaVersion: String
    let strictInputSchema: Data
}

nonisolated struct AIToolInvocation: Equatable, Sendable {
    let callID: String
    let name: String
    let arguments: Data
}

nonisolated struct AIToolExecutionResult: Equatable, Sendable {
    let callID: String
    let output: Data
    let readCharacterCount: Int
    let disposition: AIToolExecutionDisposition

    init(
        callID: String,
        output: Data,
        readCharacterCount: Int,
        disposition: AIToolExecutionDisposition = .continueWorkflow
    ) {
        self.callID = callID
        self.output = output
        self.readCharacterCount = readCharacterCount
        self.disposition = disposition
    }
}

nonisolated enum AIToolExecutionDisposition: Equatable, Sendable {
    case continueWorkflow
    case requestTermination
}

nonisolated protocol AIToolExecuting: Sendable {
    func execute(_ invocation: AIToolInvocation) async throws -> AIToolExecutionResult
    func execute(_ invocation: AIToolInvocation, batchCount: Int) async throws -> AIToolExecutionResult
}

extension AIToolExecuting {
    func execute(_ invocation: AIToolInvocation, batchCount: Int) async throws -> AIToolExecutionResult {
        try await execute(invocation)
    }
}

nonisolated protocol AITerminalEvidenceReviewing: Sendable {
    var verifiesAnswerEvidence: Bool { get async }
    func reviewRequest(for invocation: AIToolInvocation) async throws -> AIToolWorkflowProviderRequest?
    func reviewRejection(_ turn: AIToolProviderTurn, for invocation: AIToolInvocation) async throws -> AIToolExecutionResult?
}

nonisolated struct AIToolProviderCapabilities: Equatable, Sendable {
    var supportsFunctionTools: Bool
    var supportsStrictToolSchemas: Bool
    var supportsResponseContinuation: Bool
    var supportsStructuredFinalResult: Bool
}

nonisolated struct AIToolWorkflowProviderRequest: Equatable, Sendable {
    let workflowID: UUID
    let instructions: String
    let input: String
    let tools: [AIToolDefinition]
}

nonisolated struct AIToolWorkflowContinuationRequest: Equatable, Sendable {
    let workflowID: UUID
    let previousResponseID: String?
    let toolOutputs: [AIToolExecutionResult]
    var instructionsSupplement: String? = nil
    var allowedToolNames: [String]? = nil
}

nonisolated struct AIToolProviderTurn: Equatable, Sendable {
    let responseID: String?
    let toolCalls: [AIToolInvocation]
    let structuredFinalResult: Data?
    let inputTokens: Int?
}

nonisolated protocol AIToolCallingProvider: Sendable {
    var toolCapabilities: AIToolProviderCapabilities { get }

    func beginToolWorkflow(
        _ request: AIToolWorkflowProviderRequest
    ) async throws -> AIToolProviderTurn

    func continueToolWorkflow(
        _ request: AIToolWorkflowContinuationRequest
    ) async throws -> AIToolProviderTurn

    func discardToolWorkflow(_ workflowID: UUID) async
}

extension AIToolCallingProvider {
    func discardToolWorkflow(_ workflowID: UUID) async {}
}

nonisolated protocol AIToolWorkflowDefinition: Sendable {
    associatedtype Intent: Sendable
    associatedtype State: Sendable
    associatedtype Result: Sendable

    var workflowID: UUID { get }
    var tools: [AIToolDefinition] { get }
    var budget: AIWorkflowBudget { get }
    var retryPolicy: AIWorkflowRetryPolicy { get }

    func initialState(for intent: Intent) -> State
    func reduce(state: inout State, event: AIWorkflowEvent) throws
    func result(from state: State) throws -> Result
}

nonisolated struct AIWorkflowRuntimeState<FeatureState: Sendable>: Sendable {
    var phase: AIWorkflowPhase
    var featureState: FeatureState
    var usage: AIWorkflowUsage
    var latestResponseID: String?
}

nonisolated struct AIToolWorkflowRunResult: Equatable, Sendable {
    let finalTurn: AIToolProviderTurn
    let usage: AIWorkflowUsage
}

private enum AIWorkflowDeadlineError: Error {
    case elapsedTime
}

actor AIToolWorkflowRunner {
    private let traceSink: any AIWorkflowTraceSink

    init(traceSink: any AIWorkflowTraceSink = AINullWorkflowTraceSink()) {
        self.traceSink = traceSink
    }

    func makeInitialState<Workflow: AIToolWorkflowDefinition>(
        for workflow: Workflow,
        intent: Workflow.Intent
    ) async -> AIWorkflowRuntimeState<Workflow.State> {
        let state = AIWorkflowRuntimeState(
            phase: .idle,
            featureState: workflow.initialState(for: intent),
            usage: AIWorkflowUsage(),
            latestResponseID: nil
        )
        await traceSink.record(
            .started(workflowID: workflow.workflowID),
            workflowID: workflow.workflowID
        )
        return state
    }

    func validateBudget(
        _ budget: AIWorkflowBudget,
        usage: AIWorkflowUsage,
        emit: (@Sendable (AIWorkflowEvent) async -> Void)? = nil
    ) async throws {
        guard let exceeded = budget.exceededMetric(for: usage) else { return }
        if let emit {
            await emit(.budgetExceeded(exceeded))
        } else {
            await traceSink.record(.budgetExceeded(exceeded), workflowID: nil)
        }
        throw AIWorkflowFoundationError.budgetExceeded(exceeded)
    }

    func run(
        request: AIToolWorkflowProviderRequest,
        provider: any AIToolCallingProvider,
        executor: any AIToolExecuting,
        budget: AIWorkflowBudget,
        retryPolicy: AIWorkflowRetryPolicy = .conservative,
        terminalToolName: String? = nil,
        progress: (@Sendable (AIWorkflowEvent) async -> Void)? = nil
    ) async throws -> AIToolWorkflowRunResult {
        guard provider.toolCapabilities.supportsFunctionTools else {
            throw AIWorkflowFoundationError.functionToolsUnsupported
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        var usage = AIWorkflowUsage()
        var turnIndex = 0
        var seenCallIDs: Set<String> = []
        var previousSignature: [AIWorkflowToolCallSignature] = []
        var consecutiveIdenticalTurns = 0
        let reviewReserve = await (executor as? any AITerminalEvidenceReviewing)?.verifiesAnswerEvidence == true ? 1 : 0
        var finalizationOnly = terminalToolName != nil
            && (budget.maximumToolCalls <= 1 + reviewReserve || budget.maximumProviderTurns <= 1 + reviewReserve)

        let traceSink = self.traceSink
        let emit: @Sendable (AIWorkflowEvent) async -> Void = { event in
            await traceSink.record(event, workflowID: request.workflowID)
            await progress?(event)
        }

        await emit(.started(workflowID: request.workflowID))
        await emit(.phaseChanged(.runningTools))

        do {
            guard budget.maximumToolCalls > 0 else {
                await emit(.budgetExceeded(.toolCalls))
                throw AIWorkflowFoundationError.budgetExceeded(.toolCalls)
            }
            if reviewReserve > 0 {
                guard budget.maximumProviderTurns >= 2 else {
                    await emit(.budgetExceeded(.providerTurns))
                    throw AIWorkflowFoundationError.budgetExceeded(.providerTurns)
                }
                guard budget.maximumToolCalls >= 2 else {
                    await emit(.budgetExceeded(.toolCalls))
                    throw AIWorkflowFoundationError.budgetExceeded(.toolCalls)
                }
            }
            let initialRequest = AIToolWorkflowProviderRequest(
                workflowID: request.workflowID,
                instructions: request.instructions + "\n" + Self.budgetGuidance(
                    budget, usage: usage, finalizationOnly: finalizationOnly, terminalToolName: terminalToolName
                ),
                input: request.input,
                tools: finalizationOnly ? request.tools.filter { $0.name == terminalToolName } : request.tools
            )
            var turn = try await providerTurn(
            index: turnIndex,
            usage: &usage,
            budget: budget,
            retryPolicy: retryPolicy,
            startedAt: startedAt,
            emit: emit
        ) {
            try await provider.beginToolWorkflow(initialRequest)
        }
            previousSignature = Self.signature(of: turn)
            consecutiveIdenticalTurns = previousSignature.isEmpty ? 0 : 1

            while !turn.toolCalls.isEmpty {
            try Task.checkCancellation()
            var outputs: [AIToolExecutionResult] = []
            outputs.reserveCapacity(turn.toolCalls.count)
            var terminationRequest: AIToolExecutionDisposition?

            for invocation in turn.toolCalls {
                try Task.checkCancellation()
                if finalizationOnly, invocation.name != terminalToolName {
                    let metric: AIWorkflowBudgetMetric = budget.maximumProviderTurns - usage.providerTurns <= 1 ? .providerTurns : .toolCalls
                    await emit(.budgetExceeded(metric))
                    throw AIWorkflowFoundationError.budgetExceeded(metric)
                }
                guard seenCallIDs.insert(invocation.callID).inserted else {
                    throw AIWorkflowFoundationError.duplicateToolCallID(invocation.callID)
                }

                usage.toolCalls += 1
                usage.elapsed = startedAt.duration(to: clock.now)
                try await validateBudget(budget, usage: usage, emit: emit)
                await emit(
                    .toolStarted(
                        callID: invocation.callID,
                        name: invocation.name,
                        arguments: invocation.arguments
                    )
                )
                // Trace/progress callbacks can suspend and deliver Cancel.
                // Never enter the local tool after such a cancellation.
                try Task.checkCancellation()
                usage.elapsed = startedAt.duration(to: clock.now)
                try await validateBudget(budget, usage: usage, emit: emit)
                var rejection: AIToolExecutionResult?
                if turn.toolCalls.count == 1,
                   let reviewer = executor as? any AITerminalEvidenceReviewing,
                   let reviewRequest = try await reviewer.reviewRequest(for: invocation) {
                    // The review has no retrieval or annotation tools and shares
                    // every hard budget with the parent, including its one tool.
                    guard usage.toolCalls < budget.maximumToolCalls else {
                        await emit(.budgetExceeded(.toolCalls))
                        throw AIWorkflowFoundationError.budgetExceeded(.toolCalls)
                    }
                    turnIndex += 1
                    do {
                        let review = try await providerTurn(index: turnIndex, usage: &usage,
                            budget: budget, retryPolicy: retryPolicy, startedAt: startedAt, emit: emit) {
                            await emit(.evidenceReviewStarted)
                            return try await provider.beginToolWorkflow(reviewRequest)
                        }
                        guard review.toolCalls.count == 1 else { throw AIProviderError.invalidResponse }
                        let call = review.toolCalls[0]
                        usage.toolCalls += 1
                        await emit(.toolStarted(callID: call.callID, name: call.name, arguments: call.arguments))
                        try Task.checkCancellation()
                        rejection = try await reviewer.reviewRejection(review, for: invocation)
                        await emit(.toolFinished(callID: call.callID, name: call.name,
                            output: Data((rejection == nil ? "{\"accepted\":true}" : "{\"accepted\":false}").utf8), readCharacters: 0))
                        await provider.discardToolWorkflow(reviewRequest.workflowID)
                    } catch {
                        await provider.discardToolWorkflow(reviewRequest.workflowID)
                        throw error
                    }
                }
                let output: AIToolExecutionResult
                try Task.checkCancellation()
                usage.elapsed = startedAt.duration(to: clock.now)
                try await validateBudget(budget, usage: usage, emit: emit)
                if let rejection { output = rejection }
                else { output = try await executor.execute(invocation, batchCount: turn.toolCalls.count) }
                try Task.checkCancellation()
                if case .requestTermination = output.disposition {
                    terminationRequest = output.disposition
                }
                usage.readCharacters += output.readCharacterCount
                usage.elapsed = startedAt.duration(to: clock.now)
                try await validateBudget(budget, usage: usage, emit: emit)
                outputs.append(output)
                await emit(
                    .toolFinished(
                        callID: invocation.callID,
                        name: invocation.name,
                        output: output.output,
                        readCharacters: output.readCharacterCount
                    )
                )
            }

            if terminationRequest != nil {
                // The terminal publication is the sole call in its batch. Its
                // result is consumed locally; no receipt or trailing turn is sent.
                try Task.checkCancellation()
                usage.elapsed = startedAt.duration(to: clock.now)
                try await validateBudget(budget, usage: usage, emit: emit)
                await emit(.phaseChanged(.validatedDraft))
                try Task.checkCancellation()
                usage.elapsed = startedAt.duration(to: clock.now)
                try await validateBudget(budget, usage: usage, emit: emit)
                await emit(.completed)
                await provider.discardToolWorkflow(request.workflowID)
                await emit(.continuationDisposed)
                return AIToolWorkflowRunResult(finalTurn: turn, usage: usage)
            }

            // No paid request when no local tool operation can still succeed.
            guard usage.toolCalls < budget.maximumToolCalls else {
                await emit(.budgetExceeded(.toolCalls))
                throw AIWorkflowFoundationError.budgetExceeded(.toolCalls)
            }
            if reviewReserve > 0 {
                guard budget.maximumProviderTurns - usage.providerTurns >= 2 else {
                    await emit(.budgetExceeded(.providerTurns))
                    throw AIWorkflowFoundationError.budgetExceeded(.providerTurns)
                }
                guard budget.maximumToolCalls - usage.toolCalls >= 2 else {
                    await emit(.budgetExceeded(.toolCalls))
                    throw AIWorkflowFoundationError.budgetExceeded(.toolCalls)
                }
            }
            finalizationOnly = terminalToolName != nil && (
                budget.maximumToolCalls - usage.toolCalls <= 1 + reviewReserve
                    || budget.maximumProviderTurns - usage.providerTurns <= 1 + reviewReserve
            )
            turnIndex += 1
            let continuation = AIToolWorkflowContinuationRequest(
                workflowID: request.workflowID,
                previousResponseID: turn.responseID,
                toolOutputs: outputs,
                instructionsSupplement: Self.budgetGuidance(
                    budget, usage: usage, finalizationOnly: finalizationOnly, terminalToolName: terminalToolName
                ),
                allowedToolNames: finalizationOnly ? terminalToolName.map { [$0] } : nil
            )
            turn = try await providerTurn(
                index: turnIndex,
                usage: &usage,
                budget: budget,
                retryPolicy: retryPolicy,
                startedAt: startedAt,
                emit: emit
            ) {
                try await provider.continueToolWorkflow(continuation)
            }

            let signature = Self.signature(of: turn)
            if !signature.isEmpty, signature == previousSignature {
                consecutiveIdenticalTurns += 1
            } else {
                consecutiveIdenticalTurns = signature.isEmpty ? 0 : 1
            }
            if consecutiveIdenticalTurns >= budget.maximumConsecutiveNonProgressTurns {
                await emit(.noProgress)
                throw AIWorkflowFoundationError.noProgress
            }
            previousSignature = signature
            }

            try Task.checkCancellation()
            usage.elapsed = startedAt.duration(to: clock.now)
            try await validateBudget(budget, usage: usage, emit: emit)
            await emit(.phaseChanged(.validatedDraft))
            try Task.checkCancellation()
            usage.elapsed = startedAt.duration(to: clock.now)
            try await validateBudget(budget, usage: usage, emit: emit)
            await emit(.completed)
            await provider.discardToolWorkflow(request.workflowID)
            await emit(.continuationDisposed)
            return AIToolWorkflowRunResult(finalTurn: turn, usage: usage)
        } catch is CancellationError {
            await provider.discardToolWorkflow(request.workflowID)
            await emit(.continuationDisposed)
            await emit(.cancelled)
            throw CancellationError()
        } catch {
            await provider.discardToolWorkflow(request.workflowID)
            await emit(.continuationDisposed)
            await emit(.failed(code: String(describing: type(of: error))))
            throw error
        }
    }

    nonisolated static func budgetGuidance(
        _ budget: AIWorkflowBudget, usage: AIWorkflowUsage,
        finalizationOnly: Bool, terminalToolName: String?
    ) -> String {
        let tokenRemainder = budget.maximumInputTokens.map { String(max(0, $0 - (usage.inputTokens ?? 0))) } ?? "unspecified"
        return """
        Host workflow budget (not API account quota): remaining provider turns \(max(0, budget.maximumProviderTurns - usage.providerTurns)); tool calls \(max(0, budget.maximumToolCalls - usage.toolCalls)); source characters \(max(0, budget.maximumReadCharacters - usage.readCharacters)); reported-input-token allowance \(tokenRemainder). These are hard independent limits. Batch focused reads (at most 24 selectors per call); omitted_ids were NOT read, already_read_ids are already in this conversation. Stop searching when evidence answers the question; do not exhaust the budget collecting redundant citations.
        \(finalizationOnly ? "FINALIZATION ONLY: call only " + (terminalToolName ?? "the terminal tool") + " once with terminate true. Use available evidence, state limitations or notFound, and the confirmed draft revision. No more retrieval or staging is permitted." : "Reserve at least one tool call and one provider turn for a sole terminal publication. Prefer a concise answer with representative evidence over exhaustive summaries.")
        """
    }

    private func providerTurn(
        index: Int,
        usage: inout AIWorkflowUsage,
        budget: AIWorkflowBudget,
        retryPolicy: AIWorkflowRetryPolicy,
        startedAt: ContinuousClock.Instant,
        emit: @escaping @Sendable (AIWorkflowEvent) async -> Void,
        operation: @escaping @Sendable () async throws -> AIToolProviderTurn
    ) async throws -> AIToolProviderTurn {
        try Task.checkCancellation()
        usage.providerTurns += 1
        usage.elapsed = startedAt.duration(to: ContinuousClock().now)
        try await validateBudget(budget, usage: usage, emit: emit)
        await emit(.providerTurnStarted(index: index))

        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let remaining = ContinuousClock().now.duration(
                    to: startedAt.advanced(by: budget.maximumDuration)
                )
                guard remaining > .zero else {
                    await emit(.budgetExceeded(.elapsedTime))
                    throw AIWorkflowFoundationError.budgetExceeded(.elapsedTime)
                }
                let turn: AIToolProviderTurn
                do {
                    turn = try await withThrowingTaskGroup(
                        of: AIToolProviderTurn.self
                    ) { group in
                        group.addTask { try await operation() }
                        group.addTask {
                            try await Task.sleep(for: remaining)
                            throw AIWorkflowDeadlineError.elapsedTime
                        }
                        defer { group.cancelAll() }
                        guard let first = try await group.next() else {
                            throw AIProviderError.emptyResponse
                        }
                        return first
                    }
                } catch AIWorkflowDeadlineError.elapsedTime {
                    await emit(.budgetExceeded(.elapsedTime))
                    throw AIWorkflowFoundationError.budgetExceeded(.elapsedTime)
                }
                if let inputTokens = turn.inputTokens {
                    usage.inputTokens = (usage.inputTokens ?? 0) + inputTokens
                }
                // The provider operation already happened, including any
                // reported token usage. Record it even when its usage causes
                // the local workflow to stop; no tool output is sent here.
                await emit(
                    .providerTurnFinished(
                        index: index,
                        responseID: turn.responseID,
                        inputTokens: turn.inputTokens,
                        toolCallCount: turn.toolCalls.count,
                        hasStructuredFinalResult: turn.structuredFinalResult != nil
                    )
                )
                try Task.checkCancellation()
                usage.elapsed = startedAt.duration(to: ContinuousClock().now)
                try await validateBudget(budget, usage: usage, emit: emit)
                return turn
            } catch {
                try Task.checkCancellation()
                guard attempt < retryPolicy.maximumAttempts - 1,
                      Self.isTransientError(error)
                else {
                    throw error
                }
                attempt += 1
                usage.elapsed = startedAt.duration(to: ContinuousClock().now)
                try await validateBudget(budget, usage: usage, emit: emit)
                guard let delay = retryPolicy.delay(afterAttempt: attempt) else {
                    throw error
                }
                await emit(.retryScheduled(attempt: attempt))
                let remaining = ContinuousClock().now.duration(
                    to: startedAt.advanced(by: budget.maximumDuration)
                )
                guard remaining > .zero else {
                    await emit(.budgetExceeded(.elapsedTime))
                    throw AIWorkflowFoundationError.budgetExceeded(.elapsedTime)
                }
                try await Task.sleep(for: min(delay, remaining))
                usage.elapsed = startedAt.duration(to: ContinuousClock().now)
                try await validateBudget(budget, usage: usage, emit: emit)
            }
        }
    }

    nonisolated static func isTransientError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return switch urlError.code {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed,
                 .notConnectedToInternet,
                 .resourceUnavailable:
                true
            default:
                false
            }
        }
        if let providerError = error as? AIProviderError,
           case .server(let statusCode, _) = providerError
        {
            return statusCode == 429 || (500..<600).contains(statusCode)
        }
        return false
    }

    nonisolated static func signature(
        of turn: AIToolProviderTurn
    ) -> [AIWorkflowToolCallSignature] {
        turn.toolCalls.map {
            AIWorkflowToolCallSignature(
                name: $0.name,
                arguments: canonicalJSON($0.arguments, toolName: $0.name)
            )
        }
    }

    nonisolated private static func canonicalJSON(_ data: Data, toolName: String) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: data) else { return data }
        // Staging IDs label one submission; they are not annotation identity
        // or evidence. Renaming them alone leaves the accepted draft unchanged.
        // Keep this exception tool/field-specific: evidence IDs, draft revision,
        // content, and array ordering still distinguish meaningful requests.
        if toolName == "stage_highlights",
           var arguments = object as? [String: Any],
           let items = arguments["items"] as? [[String: Any]] {
            arguments["items"] = items.map { item in
                var semanticItem = item
                semanticItem.removeValue(forKey: "candidate_id")
                return semanticItem
            }
            object = arguments
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? data
    }
}

nonisolated enum AIWorkflowFoundationError: LocalizedError, Equatable {
    case budgetExceeded(AIWorkflowBudgetMetric)
    case functionToolsUnsupported
    case duplicateToolCallID(String)
    case noProgress

    var errorDescription: String? {
        switch self {
        case .budgetExceeded(let metric):
            return "AI workflow budget exceeded: \(metric.rawValue)."
        case .functionToolsUnsupported:
            return "The configured AI provider does not support function tools."
        case .duplicateToolCallID(let callID):
            return "The provider repeated tool call ID \(callID)."
        case .noProgress:
            return "The AI provider repeated the same request without making progress."
        }
    }
}
