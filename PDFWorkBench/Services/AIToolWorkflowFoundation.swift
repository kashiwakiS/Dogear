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

    static let highlightDefault = AIWorkflowBudget(
        maximumProviderTurns: 8,
        maximumToolCalls: 24,
        maximumReadCharacters: 60_000,
        maximumInputTokens: nil,
        maximumDuration: .seconds(180)
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
    case completed
    case cancelled
    case failed(code: String)
}

nonisolated protocol AIWorkflowTraceSink: Sendable {
    func record(_ event: AIWorkflowEvent) async
}

nonisolated struct AINullWorkflowTraceSink: AIWorkflowTraceSink {
    func record(_ event: AIWorkflowEvent) async {}
}

actor AIInMemoryWorkflowTraceSink: AIWorkflowTraceSink {
    private(set) var events: [AIWorkflowEvent] = []

    func record(_ event: AIWorkflowEvent) {
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
}

nonisolated protocol AIToolExecuting: Sendable {
    func execute(_ invocation: AIToolInvocation) async throws -> AIToolExecutionResult
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
        await traceSink.record(.started(workflowID: workflow.workflowID))
        return state
    }

    func validateBudget(
        _ budget: AIWorkflowBudget,
        usage: AIWorkflowUsage
    ) async throws {
        guard let exceeded = budget.exceededMetric(for: usage) else { return }
        await traceSink.record(.budgetExceeded(exceeded))
        throw AIWorkflowFoundationError.budgetExceeded(exceeded)
    }

    func run(
        request: AIToolWorkflowProviderRequest,
        provider: any AIToolCallingProvider,
        executor: any AIToolExecuting,
        budget: AIWorkflowBudget
    ) async throws -> AIToolWorkflowRunResult {
        guard provider.toolCapabilities.supportsFunctionTools else {
            throw AIWorkflowFoundationError.functionToolsUnsupported
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        var usage = AIWorkflowUsage()
        var turnIndex = 0
        var seenCallIDs: Set<String> = []

        await traceSink.record(.started(workflowID: request.workflowID))
        await traceSink.record(.phaseChanged(.runningTools))

        var turn = try await providerTurn(
            index: turnIndex,
            usage: &usage,
            budget: budget,
            startedAt: startedAt
        ) {
            try await provider.beginToolWorkflow(request)
        }

        while !turn.toolCalls.isEmpty {
            try Task.checkCancellation()
            var outputs: [AIToolExecutionResult] = []
            outputs.reserveCapacity(turn.toolCalls.count)

            for invocation in turn.toolCalls {
                try Task.checkCancellation()
                guard seenCallIDs.insert(invocation.callID).inserted else {
                    throw AIWorkflowFoundationError.duplicateToolCallID(invocation.callID)
                }

                usage.toolCalls += 1
                usage.elapsed = startedAt.duration(to: clock.now)
                try await validateBudget(budget, usage: usage)
                await traceSink.record(
                    .toolStarted(
                        callID: invocation.callID,
                        name: invocation.name,
                        arguments: invocation.arguments
                    )
                )
                let output = try await executor.execute(invocation)
                usage.readCharacters += output.readCharacterCount
                usage.elapsed = startedAt.duration(to: clock.now)
                try await validateBudget(budget, usage: usage)
                outputs.append(output)
                await traceSink.record(
                    .toolFinished(
                        callID: invocation.callID,
                        name: invocation.name,
                        output: output.output,
                        readCharacters: output.readCharacterCount
                    )
                )
            }

            turnIndex += 1
            let continuation = AIToolWorkflowContinuationRequest(
                workflowID: request.workflowID,
                previousResponseID: turn.responseID,
                toolOutputs: outputs
            )
            turn = try await providerTurn(
                index: turnIndex,
                usage: &usage,
                budget: budget,
                startedAt: startedAt
            ) {
                try await provider.continueToolWorkflow(continuation)
            }
        }

        usage.elapsed = startedAt.duration(to: clock.now)
        try await validateBudget(budget, usage: usage)
        await traceSink.record(.phaseChanged(.validatedDraft))
        await traceSink.record(.completed)
        return AIToolWorkflowRunResult(finalTurn: turn, usage: usage)
    }

    private func providerTurn(
        index: Int,
        usage: inout AIWorkflowUsage,
        budget: AIWorkflowBudget,
        startedAt: ContinuousClock.Instant,
        operation: () async throws -> AIToolProviderTurn
    ) async throws -> AIToolProviderTurn {
        try Task.checkCancellation()
        usage.providerTurns += 1
        usage.elapsed = startedAt.duration(to: ContinuousClock().now)
        try await validateBudget(budget, usage: usage)
        await traceSink.record(.providerTurnStarted(index: index))
        let turn = try await operation()
        if let inputTokens = turn.inputTokens {
            usage.inputTokens = (usage.inputTokens ?? 0) + inputTokens
        }
        usage.elapsed = startedAt.duration(to: ContinuousClock().now)
        try await validateBudget(budget, usage: usage)
        await traceSink.record(
            .providerTurnFinished(
                index: index,
                responseID: turn.responseID,
                inputTokens: turn.inputTokens,
                toolCallCount: turn.toolCalls.count,
                hasStructuredFinalResult: turn.structuredFinalResult != nil
            )
        )
        return turn
    }
}

nonisolated enum AIWorkflowFoundationError: LocalizedError, Equatable {
    case budgetExceeded(AIWorkflowBudgetMetric)
    case functionToolsUnsupported
    case duplicateToolCallID(String)

    var errorDescription: String? {
        switch self {
        case .budgetExceeded(let metric):
            return "AI workflow budget exceeded: \(metric.rawValue)."
        case .functionToolsUnsupported:
            return "The configured AI provider does not support function tools."
        case .duplicateToolCallID(let callID):
            return "The provider repeated tool call ID \(callID)."
        }
    }
}
