import Foundation

nonisolated enum OpenAICompatibleToolProviderError: LocalizedError, Equatable {
    case workflowNotStarted
    case responseMismatch
    case malformedToolSchema(String)
    case malformedToolCall

    var errorDescription: String? {
        switch self {
        case .workflowNotStarted:
            return "The AI tool workflow has not been started."
        case .responseMismatch:
            return "The AI provider response does not match the active workflow."
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
            instructions: request.instructions,
            tools: tools,
            input: initialInput,
            latestResponseID: nil
        )
        let envelope = try await send(context: context)
        var updated = context
        updated.input.append(contentsOf: envelope.output)
        updated.latestResponseID = envelope.id
        let turn = try makeTurn(from: envelope)
        if turn.toolCalls.isEmpty {
            workflows.removeValue(forKey: request.workflowID)
        } else {
            workflows[request.workflowID] = updated
        }
        return turn
    }

    func continueToolWorkflow(
        _ request: AIToolWorkflowContinuationRequest
    ) async throws -> AIToolProviderTurn {
        guard var context = workflows[request.workflowID] else {
            throw OpenAICompatibleToolProviderError.workflowNotStarted
        }
        if let expected = request.previousResponseID,
           expected != context.latestResponseID
        {
            throw OpenAICompatibleToolProviderError.responseMismatch
        }

        context.input.append(contentsOf: request.toolOutputs.map { output in
            .object([
                "type": .string("function_call_output"),
                "call_id": .string(output.callID),
                "output": .string(String(decoding: output.output, as: UTF8.self))
            ])
        })
        let envelope = try await send(context: context)
        context.input.append(contentsOf: envelope.output)
        context.latestResponseID = envelope.id
        let turn = try makeTurn(from: envelope)
        if turn.toolCalls.isEmpty {
            workflows.removeValue(forKey: request.workflowID)
        } else {
            workflows[request.workflowID] = context
        }
        return turn
    }

    func discardWorkflow(_ workflowID: UUID) {
        workflows.removeValue(forKey: workflowID)
    }

    private func send(context: WorkflowContext) async throws -> ResponsesEnvelope {
        var request = URLRequest(url: endpoint(path: "responses"))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ResponsesRequestBody(
                model: configuration.model,
                instructions: context.instructions,
                input: context.input,
                tools: context.tools,
                store: false
            )
        )
        let (data, response) = try await session.data(for: request)
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

    private func makeTurn(from envelope: ResponsesEnvelope) throws -> AIToolProviderTurn {
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
        let instructions: String
        let tools: [FunctionTool]
        var input: [AIJSONValue]
        var latestResponseID: String?
    }

    private struct ResponsesRequestBody: Encodable {
        let model: String
        let instructions: String
        let input: [AIJSONValue]
        let tools: [FunctionTool]
        let store: Bool
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

        private enum CodingKeys: String, CodingKey {
            case id, output, usage
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
