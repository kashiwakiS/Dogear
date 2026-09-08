import Foundation

nonisolated enum OpenAICompatibleToolProviderError: LocalizedError, Equatable {
    case workflowNotStarted
    case responseMismatch
    case missingResponseID
    case serverContinuationUnsupported
    case malformedToolSchema(String)
    case malformedToolCall

    var errorDescription: String? {
        switch self {
        case .workflowNotStarted:
            return "The AI tool workflow has not been started."
        case .responseMismatch:
            return "The AI provider response does not match the active workflow."
        case .missingResponseID:
            return "The AI provider did not return a response ID required to continue this request."
        case .serverContinuationUnsupported:
            return "The AI provider stopped storing responses after server continuation began. Dogear cannot safely reconstruct the missing conversation history."
        case .malformedToolSchema(let name):
            return "Tool \(name) has an invalid JSON schema."
        case .malformedToolCall:
            return "The AI provider returned a malformed tool call."
        }
    }
}

actor OpenAICompatibleToolCallingProvider: AIToolCallingProvider {
    nonisolated let toolCapabilities = AIToolProviderCapabilities(
        supportsFunctionTools: true,
        supportsStrictToolSchemas: true,
        supportsResponseContinuation: true,
        supportsStructuredFinalResult: false
    )

    private let configuration: AIProviderConfiguration
    private let apiKey: String
    private let session: URLSession
    private let baseURL: URL
    private var workflows: [UUID: WorkflowContext] = [:]

    init(
        configuration: AIProviderConfiguration,
        apiKey: String,
        session: URLSession? = nil
    ) throws {
        guard let url = URL(string: configuration.baseURL),
              let scheme = url.scheme,
              ["https", "http"].contains(scheme.lowercased())
        else {
            throw AIProviderError.invalidBaseURL
        }
        self.configuration = configuration
        self.apiKey = apiKey
        self.baseURL = url
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 90
            config.timeoutIntervalForResource = 600
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
    }

    func beginToolWorkflow(
        _ request: AIToolWorkflowProviderRequest
    ) async throws -> AIToolProviderTurn {
        try Task.checkCancellation()
        guard !configuration.model.isEmpty else {
            throw AIProviderError.missingModel
        }
        let tools = try request.tools.map(makeTool)
        let initialInput: [AIJSONValue] = [
            .object([
                "role": .string("user"),
                "content": .string(request.input)
            ])
        ]
        let context = WorkflowContext(
            generationID: UUID(),
            instructions: request.instructions,
            tools: tools,
            latestResponseID: nil,
            responseStored: nil,
            continuationMode: .serverCursor,
            turnRevision: 0
        )
        workflows[request.workflowID] = context
        do {
            let envelope = try await send(context: context, input: initialInput)
            try Task.checkCancellation()
            guard workflows[request.workflowID]?.generationID == context.generationID else {
                throw OpenAICompatibleToolProviderError.workflowNotStarted
            }
            let isStateless = envelope.store == false
            let turn = try makeTurn(from: envelope, requiresResponseID: !isStateless)
            var updated = context
            updated.latestResponseID = turn.responseID
            updated.responseStored = envelope.store
            updated.turnRevision += 1
            if isStateless {
                updated.continuationMode = .stateless(history: initialInput + envelope.output)
            }
            if turn.toolCalls.isEmpty {
                workflows.removeValue(forKey: request.workflowID)
            } else {
                workflows[request.workflowID] = updated
            }
            return turn
        } catch {
            discardIfCurrent(request.workflowID, context: context)
            throw error
        }
    }

    func continueToolWorkflow(
        _ request: AIToolWorkflowContinuationRequest
    ) async throws -> AIToolProviderTurn {
        try Task.checkCancellation()
        guard let context = workflows[request.workflowID] else {
            throw OpenAICompatibleToolProviderError.workflowNotStarted
        }
        guard request.previousResponseID == context.latestResponseID else {
            throw OpenAICompatibleToolProviderError.responseMismatch
        }
        if case .serverCursor = context.continuationMode {
            guard let expected = request.previousResponseID,
                  !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OpenAICompatibleToolProviderError.responseMismatch
            }
            // A server workflow has deliberately discarded earlier raw output.
            // It cannot switch to a partial local replay after losing storage.
            // An already-terminal call still finishes locally without this path.
            if context.responseStored == false {
                discardIfCurrent(request.workflowID, context: context)
                throw OpenAICompatibleToolProviderError.serverContinuationUnsupported
            }
        }

        let toolOutputs: [AIJSONValue] = request.toolOutputs.map { output in
            AIJSONValue.object([
                "type": .string("function_call_output"),
                "call_id": .string(output.callID),
                "output": .string(String(decoding: output.output, as: UTF8.self))
            ])
        }
        let input: [AIJSONValue]
        switch context.continuationMode {
        case .serverCursor:
            input = toolOutputs
        case .stateless(let history):
            // Build an immutable attempt payload. Advance history only after a
            // successful response, so transient retries never append twice.
            input = history + toolOutputs
        }
        do {
            let envelope = try await send(context: context, input: input,
                instructionsSupplement: request.instructionsSupplement,
                allowedToolNames: request.allowedToolNames)
            try Task.checkCancellation()
            guard let current = workflows[request.workflowID],
                  current.generationID == context.generationID else {
                throw OpenAICompatibleToolProviderError.workflowNotStarted
            }
            guard current.turnRevision == context.turnRevision else {
                throw OpenAICompatibleToolProviderError.responseMismatch
            }
            let turn = try makeTurn(
                from: envelope, requiresResponseID: context.continuationMode.usesServerCursor
            )
            var updated = context
            updated.latestResponseID = turn.responseID
            updated.responseStored = envelope.store
            updated.turnRevision += 1
            if case .stateless = context.continuationMode {
                // Keep the first-response choice until disposal even if a later
                // endpoint response claims storage is available again.
                updated.continuationMode = .stateless(history: input + envelope.output)
            }
            if turn.toolCalls.isEmpty {
                workflows.removeValue(forKey: request.workflowID)
            } else {
                workflows[request.workflowID] = updated
            }
            return turn
        } catch {
            // A bounded transport retry must reuse the same server cursor.
            // Terminal failures and cancellation must not retain a live workflow.
            if !AIToolWorkflowRunner.isTransientError(error) || Task.isCancelled {
                discardIfCurrent(request.workflowID, context: context)
            }
            throw error
        }
    }

    func discardToolWorkflow(_ workflowID: UUID) async {
        workflows.removeValue(forKey: workflowID)
    }

    // Metadata-only diagnostics: never expose retained prompt or response text.
    func diagnosticRetainedItemCount(for workflowID: UUID) async -> Int? {
        guard let context = workflows[workflowID] else { return nil }
        switch context.continuationMode {
        case .serverCursor: return 0
        case .stateless(let history): return history.count
        }
    }

    private func discardIfCurrent(_ workflowID: UUID, context: WorkflowContext) {
        guard let current = workflows[workflowID],
              current.generationID == context.generationID,
              current.turnRevision == context.turnRevision else { return }
        workflows.removeValue(forKey: workflowID)
    }

    private func send(
        context: WorkflowContext,
        input: [AIJSONValue],
        instructionsSupplement: String? = nil,
        allowedToolNames: [String]? = nil
    ) async throws -> ResponsesEnvelope {
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint(path: "responses"))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ResponsesRequestBody(
                model: configuration.model,
                instructions: context.instructions + (instructionsSupplement.map { "\n" + $0 } ?? ""),
                input: input,
                tools: allowedToolNames.map { allowed in context.tools.filter { allowed.contains($0.name) } } ?? context.tools,
                previousResponseID: context.continuationMode.usesServerCursor ? context.latestResponseID : nil,
                store: context.continuationMode.usesServerCursor
            )
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        try validate(response: response, data: data)
        return try JSONDecoder().decode(ResponsesEnvelope.self, from: data)
    }

    private func makeTool(_ definition: AIToolDefinition) throws -> FunctionTool {
        let parameters: AIJSONValue
        do {
            parameters = try JSONDecoder().decode(
                AIJSONValue.self,
                from: definition.strictInputSchema
            )
        } catch {
            throw OpenAICompatibleToolProviderError.malformedToolSchema(definition.name)
        }
        return FunctionTool(
            type: "function",
            name: definition.name,
            description: definition.description,
            parameters: parameters,
            strict: true
        )
    }

    private func makeTurn(
        from envelope: ResponsesEnvelope, requiresResponseID: Bool
    ) throws -> AIToolProviderTurn {
        let calls = try envelope.output.compactMap { item -> AIToolInvocation? in
            guard case .object(let object) = item,
                  object["type"]?.stringValue == "function_call"
            else {
                return nil
            }
            guard let callID = object["call_id"]?.stringValue,
                  let name = object["name"]?.stringValue,
                  let arguments = object["arguments"]?.stringValue,
                  let argumentData = arguments.data(using: .utf8)
            else {
                throw OpenAICompatibleToolProviderError.malformedToolCall
            }
            return AIToolInvocation(
                callID: callID,
                name: name,
                arguments: argumentData
            )
        }
        if requiresResponseID, !calls.isEmpty,
           envelope.id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw OpenAICompatibleToolProviderError.missingResponseID
        }
        return AIToolProviderTurn(
            responseID: envelope.id,
            toolCalls: calls,
            structuredFinalResult: nil,
            inputTokens: envelope.usage?.inputTokens
        )
    }

    private func endpoint(path: String) -> URL {
        if baseURL.lastPathComponent == path {
            return baseURL
        }
        return baseURL.appendingPathComponent(path)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
                ?? String(data: data.prefix(500), encoding: .utf8)
                ?? "Unknown provider error"
            throw AIProviderError.server(statusCode: response.statusCode, message: message)
        }
    }

    private struct WorkflowContext {
        let generationID: UUID
        let instructions: String
        let tools: [FunctionTool]
        var latestResponseID: String?
        var responseStored: Bool?
        var continuationMode: ContinuationMode
        var turnRevision: Int
    }

    private enum ContinuationMode {
        case serverCursor
        case stateless(history: [AIJSONValue])

        var usesServerCursor: Bool {
            if case .serverCursor = self { return true }
            return false
        }
    }

    private struct ResponsesRequestBody: Encodable {
        let model: String
        let instructions: String
        let input: [AIJSONValue]
        let tools: [FunctionTool]
        let previousResponseID: String?
        let store: Bool

        private enum CodingKeys: String, CodingKey {
            case model, instructions, input, tools, store
            case previousResponseID = "previous_response_id"
        }
    }

    private struct FunctionTool: Codable {
        let type: String
        let name: String
        let description: String
        let parameters: AIJSONValue
        let strict: Bool
    }

    private struct ResponsesEnvelope: Decodable {
        let id: String?
        let output: [AIJSONValue]
        let usage: Usage?
        let store: Bool?

        private enum CodingKeys: String, CodingKey {
            case id, output, usage, store
        }
    }

    private struct Usage: Decodable {
        let inputTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
        }
    }

    private struct ErrorEnvelope: Decodable {
        let error: ProviderError
    }

    private struct ProviderError: Decodable {
        let message: String
    }
}

nonisolated indirect enum AIJSONValue: Codable, Equatable, Sendable {
    case object([String: AIJSONValue])
    case array([AIJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: AIJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([AIJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}
