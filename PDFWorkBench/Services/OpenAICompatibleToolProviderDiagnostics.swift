import Foundation

@MainActor
enum OpenAICompatibleToolProviderDiagnostics {
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

        ToolProviderMockURLProtocol.reset(
            responses: [
                Data(
                    """
                    {"id":"response-1","output":[{"id":"reasoning-1","type":"reasoning","summary":[]},{"id":"function-1","type":"function_call","call_id":"call-1","name":"get_document_map","arguments":"{\\"page_start\\":1,\\"page_end\\":1}"}],"usage":{"input_tokens":12}}
                    """.utf8
                ),
                Data(
                    """
                    {"id":"response-2","output":[{"id":"message-1","type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}],"usage":{"input_tokens":18}}
                    """.utf8
                )
            ]
        )

        do {
            let configuration = AIProviderConfiguration(
                id: UUID(),
                name: "Diagnostic",
                baseURL: "https://example.invalid/v1",
                model: "diagnostic-model",
                isCloudAIEnabled: true,
                hasCloudConsent: true,
                secretStorageMode: .plaintextFile
            )
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.protocolClasses = [ToolProviderMockURLProtocol.self]
            let provider = try OpenAICompatibleToolCallingProvider(
                configuration: configuration,
                apiKey: "diagnostic-key",
                session: URLSession(configuration: sessionConfiguration)
            )
            let workflowID = UUID()
            let first = try await provider.beginToolWorkflow(
                AIToolWorkflowProviderRequest(
                    workflowID: workflowID,
                    instructions: "Diagnostic instructions",
                    input: "Diagnostic input",
                    tools: AIHighlightToolCodec.definitions
                )
            )
            check(
                first.toolCalls.first?.callID == "call-1"
                    && first.toolCalls.first?.name == AIHighlightToolName.documentMap,
                "The provider did not decode the function call."
            )
            check(first.inputTokens == 12, "The provider did not decode input-token usage.")

            let final = try await provider.continueToolWorkflow(
                AIToolWorkflowContinuationRequest(
                    workflowID: workflowID,
                    previousResponseID: first.responseID,
                    toolOutputs: [
                        AIToolExecutionResult(
                            callID: "call-1",
                            output: Data("{\"pages\":[]}".utf8),
                            readCharacterCount: 0
                        )
                    ]
                )
            )
            check(final.toolCalls.isEmpty, "The provider did not recognize the final turn.")

            let requestBodies = ToolProviderMockURLProtocol.capturedRequestBodies()
            check(requestBodies.count == 2, "The provider did not send two Responses requests.")
            if requestBodies.count == 2,
               let firstBody = jsonObject(requestBodies[0]),
               let secondBody = jsonObject(requestBodies[1]) {
                let tools = firstBody["tools"] as? [[String: Any]]
                check(
                    firstBody["store"] as? Bool == false
                        && tools?.allSatisfy({ $0["strict"] as? Bool == true }) == true,
                    "The initial request did not use store:false and strict tools."
                )
                let input = secondBody["input"] as? [[String: Any]] ?? []
                let types = input.compactMap { $0["type"] as? String }
                check(
                    types.contains("reasoning")
                        && types.contains("function_call")
                        && types.contains("function_call_output"),
                    "The continuation did not preserve reasoning/function items and tool output."
                )
                check(
                    secondBody["previous_response_id"] == nil,
                    "The privacy-preserving local continuation unexpectedly relied on server state."
                )
            } else {
                check(false, "The provider request JSON could not be inspected.")
            }
        } catch {
            failures.append(error.localizedDescription)
        }

        return Report(checks: checks, failures: failures)
    }

    private static func jsonObject(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private final class ToolProviderMockURLProtocol: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var responses: [Data] = []
    private nonisolated(unsafe) static var requestBodies: [Data] = []
    private static let lock = NSLock()

    static func reset(responses: [Data]) {
        lock.lock()
        self.responses = responses
        requestBodies = []
        lock.unlock()
    }

    static func capturedRequestBodies() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return requestBodies
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        Self.lock.lock()
        Self.requestBodies.append(body)
        let data = Self.responses.isEmpty ? Data() : Self.responses.removeFirst()
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBodyStream(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
