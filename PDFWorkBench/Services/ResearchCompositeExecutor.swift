import Foundation

nonisolated enum ResearchCompositeExecutorError: LocalizedError, Equatable {
    case invalidRegistration
    case inactiveWorkflow
    case unregisteredTool(String)
    case additionalToolCannotTerminate

    var errorDescription: String? {
        switch self {
        case .invalidRegistration: "Research tools conflict with the evidence workflow or have no executor."
        case .inactiveWorkflow: "This research workflow is no longer accepting tool actions."
        case .unregisteredTool(let name): "Research tool is not registered for this request: \(name)."
        case .additionalToolCannotTerminate: "Only the verified publish_answer tool can complete this workflow."
        }
    }
}

/// Extra native commands participate in the same runner budgets, while only the
/// core executor owns text reads, drafts, terminal publication and evidence review.
actor ResearchCompositeExecutor: AIToolExecuting, AITerminalEvidenceReviewing {
    private let core: AIHighlightToolExecutor
    private let additional: (any AIToolExecuting)?
    private let additionalNames: Set<String>
    private let coreNames: Set<String>
    private var closed = false

    init(core: AIHighlightToolExecutor, coreDefinitions: [AIToolDefinition],
         additionalDefinitions: [AIToolDefinition], additionalExecutor: (any AIToolExecuting)?) throws {
        _ = try Self.combinedDefinitions(core: coreDefinitions, additional: additionalDefinitions,
                                         executor: additionalExecutor)
        self.core = core
        self.additional = additionalExecutor
        self.additionalNames = Set(additionalDefinitions.map(\.name))
        self.coreNames = Set(coreDefinitions.map(\.name))
    }

    nonisolated static func combinedDefinitions(core: [AIToolDefinition], additional: [AIToolDefinition],
                                                executor: (any AIToolExecuting)?) throws -> [AIToolDefinition] {
        let reserved = Set(AIHighlightToolCodec.definitions.map(\.name) + [AIAnswerEvidenceReview.toolName])
        let names = additional.map(\.name)
        guard (additional.isEmpty || executor != nil), Set(names).count == names.count,
              names.allSatisfy({ !$0.isEmpty && !reserved.contains($0) }),
              Set(core.map(\.name)).isDisjoint(with: names) else {
            throw ResearchCompositeExecutorError.invalidRegistration
        }
        return core + additional
    }

    var verifiesAnswerEvidence: Bool { get async { core.verifiesAnswerEvidence } }
    func close() { closed = true }

    func execute(_ invocation: AIToolInvocation) async throws -> AIToolExecutionResult {
        try await execute(invocation, batchCount: 1)
    }

    func execute(_ invocation: AIToolInvocation, batchCount: Int) async throws -> AIToolExecutionResult {
        try requireActive()
        let output: AIToolExecutionResult
        if coreNames.contains(invocation.name) {
            output = try await core.execute(invocation, batchCount: batchCount)
        } else if additionalNames.contains(invocation.name), let additional {
            output = try await additional.execute(invocation, batchCount: batchCount)
            guard output.disposition == .continueWorkflow else {
                closed = true
                throw ResearchCompositeExecutorError.additionalToolCannotTerminate
            }
        } else {
            throw ResearchCompositeExecutorError.unregisteredTool(invocation.name)
        }
        try requireActive()
        if output.disposition == .requestTermination { closed = true }
        return output
    }

    func reviewRequest(for invocation: AIToolInvocation) async throws -> AIToolWorkflowProviderRequest? {
        try requireActive()
        guard invocation.name == AIHighlightToolName.publishAnswer else { return nil }
        return try await core.reviewRequest(for: invocation)
    }

    func reviewRejection(_ turn: AIToolProviderTurn, for invocation: AIToolInvocation) async throws -> AIToolExecutionResult? {
        try requireActive()
        guard invocation.name == AIHighlightToolName.publishAnswer else {
            throw ResearchCompositeExecutorError.unregisteredTool(invocation.name)
        }
        return try await core.reviewRejection(turn, for: invocation)
    }

    private func requireActive() throws {
        try Task.checkCancellation()
        guard !closed else { throw ResearchCompositeExecutorError.inactiveWorkflow }
    }
}
