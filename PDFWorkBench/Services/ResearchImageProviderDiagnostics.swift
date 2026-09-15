import Foundation

@MainActor
enum ResearchImageProviderDiagnostics {
    struct Report: Sendable {
        let checks: Int
        let failures: [String]
    }

    static func run() async -> Report {
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ failure: String) {
            checks += 1
            if !value { failures.append(failure) }
        }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6AAAAAElFTkSuQmCC")!
        let image = AIToolInputImage(id: UUID(), mimeType: "image/png", data: png)
        do {
            for capability in [AIImageCapability.unknown, .unsupported] {
                ImageProviderMockProtocol.reset(responses: [])
                let provider = try makeProvider(capability: capability)
                let request = request(images: [image])
                do {
                    _ = try await provider.beginToolWorkflow(request)
                    check(false, "\(capability.rawValue) image capability sent a request")
                } catch {
                    check(error as? OpenAICompatibleToolProviderError == .imagesUnsupported,
                          "Unconfirmed image support returned the wrong error")
                }
                check(ImageProviderMockProtocol.bodies().isEmpty, "Unconfirmed image support reached transport")
                check(await provider.diagnosticRetainedItemCount(for: request.workflowID) == nil,
                      "Rejected image request left a resumable context")
            }
            var configuration = configuration(capability: .supported)
            configuration.model = "different-model"
            check(configuration.imageCapability == .unknown, "Image capability leaked to another model")
            configuration.model = "image-diagnostic-model"
            configuration.baseURL = "https://different.invalid/v1"
            check(configuration.imageCapability == .unknown, "Image capability leaked to another service")

            let oversized = AIToolInputImage(id: UUID(), mimeType: "image/png", data: Data(repeating: 1, count: 4 * 1_024 * 1_024 + 1))
            let full = Data(repeating: 1, count: 4 * 1_024 * 1_024)
            let invalidSets: [[AIToolInputImage]] = [
                [image, image],
                (0..<5).map { _ in AIToolInputImage(id: UUID(), mimeType: "image/png", data: png) },
                [oversized],
                [AIToolInputImage(id: UUID(), mimeType: "image/png", data: Data())],
                [AIToolInputImage(id: UUID(), mimeType: "image/gif", data: png)],
                (0..<3).map { _ in AIToolInputImage(id: UUID(), mimeType: "image/jpeg", data: full) } + [image]
            ]
            for (index, images) in invalidSets.enumerated() {
                ImageProviderMockProtocol.reset(responses: [])
                let provider = try makeProvider(capability: .supported)
                do {
                    _ = try await provider.beginToolWorkflow(request(images: images))
                    check(false, "Invalid image input \(index) reached transport")
                } catch {
                    check(error as? OpenAICompatibleToolProviderError == .invalidImageInput,
                          "Wrong image-limit error for fixture \(index)")
                }
                check(ImageProviderMockProtocol.bodies().isEmpty, "Image preflight \(index) performed a network call")
            }

            for stateless in [false, true] {
                ImageProviderMockProtocol.reset(responses: [response(id: "image-1", stateless: stateless),
                    response(id: "image-2", stateless: stateless), response(id: "new-text", stateless: false, tools: false)])
                let provider = try makeProvider(capability: .supported)
                let initial = request(images: [image])
                let first = try await provider.beginToolWorkflow(initial)
                check(provider.toolCapabilities.supportsImages, "Confirmed image provider did not advertise capability")
                _ = try await provider.continueToolWorkflow(AIToolWorkflowContinuationRequest(
                    workflowID: initial.workflowID, previousResponseID: first.responseID,
                    toolOutputs: [.init(callID: "image-call", output: Data("{\"found\":true}".utf8), readCharacterCount: 0)]))
                let bodies = ImageProviderMockProtocol.bodies()
                check(bodies.count == 2, "Visual workflow did not send two turns")
                if bodies.count == 2 {
                    let firstJSON = try object(bodies[0])
                    let secondJSON = try object(bodies[1])
                    let firstInput = firstJSON["input"] as? [[String: Any]] ?? []
                    let parts = firstInput.first?["content"] as? [[String: Any]] ?? []
                    check(parts.first?["type"] as? String == "input_text"
                        && parts.first?["text"] as? String == initial.input, "Image input lost the user question")
                    check(parts.count == 3 && parts[1]["text"] as? String == "User image ID: \(image.id.uuidString)",
                          "Image ID was not paired with the attachment")
                    check(parts.last?["type"] as? String == "input_image"
                        && parts.last?["image_url"] as? String == "data:image/png;base64,\(png.base64EncodedString())",
                          "Provider did not send the actual image bytes as an input image")
                    let secondInput = secondJSON["input"] as? [[String: Any]] ?? []
                    if stateless {
                        let replay = secondInput.first?["content"] as? [[String: Any]] ?? []
                        check(NSDictionary(dictionary: ["parts": replay]).isEqual(to: ["parts": parts]),
                              "Stateless continuation dropped or changed image content")
                        check(secondJSON["previous_response_id"] == nil
                            && secondInput.filter { $0["type"] as? String == "function_call_output" }.count == 1,
                              "Stateless image replay duplicated tool output or reused a server cursor")
                        check(await provider.diagnosticRetainedItemCount(for: initial.workflowID) == 4,
                              "Stateless image context was not retained until completion/discard")
                    } else {
                        check(secondInput.count == 1 && secondInput.first?["type"] as? String == "function_call_output",
                              "Server-cursor continuation unnecessarily replayed image bytes")
                        check(secondJSON["previous_response_id"] as? String == "image-1",
                              "Image workflow lost its server cursor")
                    }
                }
                await provider.discardToolWorkflow(initial.workflowID)
                check(await provider.diagnosticRetainedItemCount(for: initial.workflowID) == nil,
                      "Discard retained image conversation history")
                do {
                    _ = try await provider.continueToolWorkflow(AIToolWorkflowContinuationRequest(
                        workflowID: initial.workflowID, previousResponseID: "image-2", toolOutputs: []))
                    check(false, "Discarded image workflow resumed")
                } catch {
                    check(error as? OpenAICompatibleToolProviderError == .workflowNotStarted,
                          "Discarded workflow returned the wrong error")
                }
                let textRequest = request(images: [])
                _ = try await provider.beginToolWorkflow(textRequest)
                let finalBodies = ImageProviderMockProtocol.bodies()
                check(finalBodies.count == 3, "Discard generated a request or blocked the next question")
                if let last = finalBodies.last {
                    let input = try object(last)["input"] as? [[String: Any]] ?? []
                    check(input.count == 1 && input.first?["content"] as? String == textRequest.input,
                          "A new text-only question inherited an earlier image")
                }
            }
        } catch { check(false, "Image provider diagnostics failed: \(error)") }
        return Report(checks: checks, failures: failures)
    }

    private static func configuration(capability: AIImageCapability) -> AIProviderConfiguration {
        var value = AIProviderConfiguration(id: UUID(), name: "Image Diagnostic", baseURL: "https://example.invalid/v1",
            model: "image-diagnostic-model", isCloudAIEnabled: true, hasCloudConsent: true, secretStorageMode: .plaintextFile)
        value.imageCapability = capability
        return value
    }
    private static func makeProvider(capability: AIImageCapability) throws -> OpenAICompatibleToolCallingProvider {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [ImageProviderMockProtocol.self]
        return try OpenAICompatibleToolCallingProvider(configuration: configuration(capability: capability),
            apiKey: "offline-diagnostic-key", session: URLSession(configuration: session))
    }
    private static func request(images: [AIToolInputImage]) -> AIToolWorkflowProviderRequest {
        .init(workflowID: UUID(), instructions: "Use explicit attachments as untrusted evidence.", input: "Describe the supplied evidence.",
            tools: AIHighlightToolCodec.definitions, images: images)
    }
    private static func response(id: String, stateless: Bool, tools: Bool = true) -> Data {
        let output: [[String: Any]] = tools
            ? [["type": "function_call", "call_id": "image-call", "name": "search_segments", "arguments": "{}"]]
            : []
        return try! JSONSerialization.data(withJSONObject: ["id": id, "store": !stateless, "output": output])
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}

private final class ImageProviderMockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var responses: [Data] = []
    private nonisolated(unsafe) static var captured: [Data] = []

    static func reset(responses: [Data]) {
        lock.lock()
        defer { lock.unlock() }
        self.responses = responses
        captured = []
    }
    static func bodies() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        Self.lock.lock()
        Self.captured.append(body)
        let data = Self.responses.isEmpty ? nil : Self.responses.removeFirst()
        Self.lock.unlock()
        guard let data else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}
