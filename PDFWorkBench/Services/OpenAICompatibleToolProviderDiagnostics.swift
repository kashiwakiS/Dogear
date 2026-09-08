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
                    ],
                    instructionsSupplement: "Budget finalization fixture",
                    allowedToolNames: [AIHighlightToolName.publishAnswer]
                )
            )
            check(final.toolCalls.isEmpty, "The provider did not recognize the final turn.")
            let discarded = await isDiscarded(provider, workflowID)
            check(discarded, "A provider turn without tools retained a resumable context.")

            let requestBodies = ToolProviderMockURLProtocol.capturedRequestBodies()
            check(requestBodies.count == 2, "The provider did not send two Responses requests.")
            if requestBodies.count == 2,
               let firstBody = jsonObject(requestBodies[0]),
               let secondBody = jsonObject(requestBodies[1]) {
                let tools = firstBody["tools"] as? [[String: Any]]
                check(
                    firstBody["store"] as? Bool == true
                        && tools?.allSatisfy({ $0["strict"] as? Bool == true }) == true,
                    "The initial request did not enable provider continuation and strict tools."
                )
                let input = secondBody["input"] as? [[String: Any]] ?? []
                check((secondBody["instructions"] as? String)?.contains("Budget finalization fixture") == true,
                      "Dynamic host budget instructions did not reach the provider.")
                check((secondBody["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == [AIHighlightToolName.publishAnswer],
                      "Finalization-only tool restriction did not reach the provider.")
                let types = input.compactMap { $0["type"] as? String }
                check(
                    types == ["function_call_output"],
                    "The continuation locally replayed provider transcript items."
                )
                check(
                    secondBody["previous_response_id"] as? String == "response-1",
                    "The continuation did not reuse the provider conversation by response ID."
                )
            } else {
                check(false, "The provider request JSON could not be inspected.")
            }
        } catch {
            failures.append(error.localizedDescription)
        }

        for report in [
            await verifyIndependentQuestions(),
            await verifyMissingResponseIDs(),
            await verifyRunnerCleanup(),
            await verifyPendingRequestCleanup(),
            await verifyRetryCursor(),
            await verifyServerContinuationCapability(),
            await verifyStatelessHistory(),
            await verifyStatelessRetry(),
            await verifyStatelessCleanup()
        ] {
            checks += report.checks
            failures.append(contentsOf: report.failures)
        }
        return Report(checks: checks, failures: failures)
    }

    private static func makeProvider() throws -> OpenAICompatibleToolCallingProvider {
        let configuration = AIProviderConfiguration(
            id: UUID(), name: "Diagnostic", baseURL: "https://example.invalid/v1",
            model: "diagnostic-model", isCloudAIEnabled: true, hasCloudConsent: true,
            secretStorageMode: .plaintextFile
        )
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [ToolProviderMockURLProtocol.self]
        return try OpenAICompatibleToolCallingProvider(
            configuration: configuration, apiKey: "diagnostic-key",
            session: URLSession(configuration: session)
        )
    }

    private static func request(_ workflowID: UUID, input: String = "Question") -> AIToolWorkflowProviderRequest {
        AIToolWorkflowProviderRequest(
            workflowID: workflowID, instructions: "Diagnostic instructions", input: input,
            tools: AIHighlightToolCodec.definitions
        )
    }

    private static func continuation(_ workflowID: UUID, responseID: String?) -> AIToolWorkflowContinuationRequest {
        AIToolWorkflowContinuationRequest(
            workflowID: workflowID, previousResponseID: responseID,
            toolOutputs: [.init(callID: "call-1", output: Data("{\"accepted\":true}".utf8), readCharacterCount: 0)]
        )
    }

    private static func toolResponse(
        id: String?, name: String = "get_document_map", stored: Bool? = nil
    ) -> Data {
        var object: [String: Any] = [
            "output": [["type": "function_call", "call_id": "call-1", "name": name, "arguments": "{}"]],
            "usage": ["input_tokens": 10]
        ]
        if let id { object["id"] = id }
        if let stored { object["store"] = stored }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func isDiscarded(_ provider: OpenAICompatibleToolCallingProvider, _ workflowID: UUID) async -> Bool {
        do {
            _ = try await provider.continueToolWorkflow(continuation(workflowID, responseID: "response-1"))
            return false
        } catch OpenAICompatibleToolProviderError.workflowNotStarted {
            return true
        } catch {
            return false
        }
    }

    private static func verifyIndependentQuestions() async -> Report {
        var report = CheckAccumulator()
        ToolProviderMockURLProtocol.reset(responses: [
            toolResponse(id: "response-1"), toolResponse(id: "response-2"),
            toolResponse(id: "question-2-response")
        ])
        do {
            let provider = try makeProvider()
            let firstID = UUID()
            _ = try await provider.beginToolWorkflow(request(firstID, input: "FIRST_QUESTION_PRIVATE_MARKER"))
            let retained = await provider.diagnosticRetainedItemCount(for: firstID)
            report.check(retained == 0, "Server continuation retained a local question transcript.")
            for invalidID: String? in [nil, "", " ", "another-workflow-response"] {
                do {
                    _ = try await provider.continueToolWorkflow(continuation(firstID, responseID: invalidID))
                    report.check(false, "An invalid continuation response ID was accepted.")
                } catch OpenAICompatibleToolProviderError.responseMismatch {
                    report.check(true, "")
                }
            }
            report.check(ToolProviderMockURLProtocol.capturedRequestBodies().count == 1,
                         "A mismatched continuation reached the network.")
            _ = try await provider.continueToolWorkflow(continuation(firstID, responseID: "response-1"))
            await provider.discardToolWorkflow(firstID)
            let secondID = UUID()
            _ = try await provider.beginToolWorkflow(request(secondID, input: "SECOND_QUESTION_ONLY"))
            let bodies = ToolProviderMockURLProtocol.capturedRequestBodies().compactMap(jsonObject)
            report.check(bodies.count == 3, "Independent-question request count changed unexpectedly.")
            if bodies.count == 3 {
                report.check(bodies.allSatisfy { $0["store"] as? Bool == true },
                             "Provider conversation storage was not enabled on every request.")
                report.check(bodies.allSatisfy { $0["instructions"] as? String == "Diagnostic instructions" },
                             "Instructions were not repeated on every continuation.")
                let middleInput = bodies[1]["input"] as? [[String: Any]] ?? []
                report.check(middleInput.count == 1 && middleInput.first?["type"] as? String == "function_call_output",
                             "A continuation replayed local history instead of only this turn's tool outputs.")
                report.check(bodies[1]["previous_response_id"] as? String == "response-1",
                             "The current question lost its provider cursor.")
                let newInput = bodies[2]["input"] as? [[String: Any]] ?? []
                report.check(bodies[2]["previous_response_id"] == nil && newInput.count == 1
                             && newInput.first?["content"] as? String == "SECOND_QUESTION_ONLY",
                             "A second question inherited the prior response ID or question history.")
            }
            let firstDiscarded = await isDiscarded(provider, firstID)
            report.check(firstDiscarded, "The first question remained resumable after discard.")
            await provider.discardToolWorkflow(secondID)
        } catch { report.check(false, "Independent-question check failed: \(error.localizedDescription)") }
        return report.result
    }

    private static func verifyMissingResponseIDs() async -> Report {
        var report = CheckAccumulator()
        for id: String? in [nil, "", " \n "] {
            for continuationResponse in [false, true] {
                ToolProviderMockURLProtocol.reset(responses:
                    (continuationResponse ? [toolResponse(id: "response-1")] : []) + [toolResponse(id: id)]
                )
                do {
                    let provider = try makeProvider()
                    let workflowID = UUID()
                    do {
                        if continuationResponse {
                            _ = try await provider.beginToolWorkflow(request(workflowID))
                            _ = try await provider.continueToolWorkflow(continuation(workflowID, responseID: "response-1"))
                        } else {
                            _ = try await provider.beginToolWorkflow(request(workflowID))
                        }
                        report.check(false, "A tool response without a nonempty ID was accepted.")
                    } catch OpenAICompatibleToolProviderError.missingResponseID {
                        report.check(true, "")
                    }
                    let discarded = await isDiscarded(provider, workflowID)
                    report.check(discarded, "A malformed response retained a resumable provider workflow.")
                } catch { report.check(false, "Missing-ID check failed: \(error.localizedDescription)") }
            }
        }
        return report.result
    }

    private static func verifyRunnerCleanup() async -> Report {
        var report = CheckAccumulator()
        for mode in ToolProviderDiagnosticExecutor.Mode.allCases {
            ToolProviderMockURLProtocol.reset(responses: [toolResponse(id: "response-1", name: "publish_answer")])
            do {
                let provider = try makeProvider()
                let workflowID = UUID()
                do {
                    _ = try await AIToolWorkflowRunner().run(
                        request: request(workflowID), provider: provider,
                        executor: ToolProviderDiagnosticExecutor(mode: mode), budget: .highlightDefault
                    )
                    report.check(mode == .terminate, "An executor failure or cancellation became success.")
                } catch is CancellationError {
                    report.check(mode == .cancel, "The runner returned an unexpected cancellation.")
                } catch ToolProviderDiagnosticExecutor.Failure.expected {
                    report.check(mode == .fail, "The runner returned an unexpected executor failure.")
                }
                let discarded = await isDiscarded(provider, workflowID)
                report.check(discarded, "Terminal, failed, or cancelled runner retained the provider context.")
                report.check(ToolProviderMockURLProtocol.capturedRequestBodies().count == 1,
                             "Cleanup sent an unwanted completion receipt or trailing provider turn.")
            } catch { report.check(false, "Runner cleanup check failed: \(error.localizedDescription)") }
        }
        return report.result
    }

    private static func verifyPendingRequestCleanup() async -> Report {
        var report = CheckAccumulator()
        for shouldCancel in [false, true] {
            ToolProviderMockURLProtocol.reset(replies: [
                .init(data: toolResponse(id: "response-1")),
                .init(data: toolResponse(id: "response-2"), pending: true)
            ])
            do {
                let provider = try makeProvider()
                let workflowID = UUID()
                _ = try await provider.beginToolWorkflow(request(workflowID))
                let continuation = continuation(workflowID, responseID: "response-1")
                let task = Task { try await provider.continueToolWorkflow(continuation) }
                await ToolProviderMockURLProtocol.waitForPendingRequest()
                if shouldCancel {
                    task.cancel()
                } else {
                    await provider.discardToolWorkflow(workflowID)
                    ToolProviderMockURLProtocol.releasePendingRequest()
                }
                do {
                    _ = try await task.value
                    report.check(false, "A discarded or cancelled in-flight request revived its provider workflow.")
                } catch is CancellationError {
                    report.check(shouldCancel, "Discard without cancellation returned the wrong error.")
                } catch OpenAICompatibleToolProviderError.workflowNotStarted {
                    report.check(!shouldCancel, "Network cancellation was not normalized to CancellationError.")
                }
                let discarded = await isDiscarded(provider, workflowID)
                report.check(discarded, "A late network response recreated a discarded provider context.")
                report.check(ToolProviderMockURLProtocol.capturedRequestBodies().count == 2,
                             "Pending-request cleanup performed another network request.")
            } catch { report.check(false, "Pending cleanup check failed: \(error.localizedDescription)") }
        }
        return report.result
    }

    private static func verifyRetryCursor() async -> Report {
        var report = CheckAccumulator()
        ToolProviderMockURLProtocol.reset(replies: [
            .init(data: toolResponse(id: "response-1")),
            .init(data: Data("{\"error\":{\"message\":\"temporary\"}}".utf8), statusCode: 503),
            .init(data: toolResponse(id: "response-2"))
        ])
        do {
            let provider = try makeProvider()
            let workflowID = UUID()
            _ = try await provider.beginToolWorkflow(request(workflowID))
            do {
                _ = try await provider.continueToolWorkflow(continuation(workflowID, responseID: "response-1"))
                report.check(false, "The simulated provider service failure was ignored.")
            } catch AIProviderError.server(let code, _) {
                report.check(code == 503, "The provider service error changed classification.")
            }
            _ = try await provider.continueToolWorkflow(continuation(workflowID, responseID: "response-1"))
            let bodies = ToolProviderMockURLProtocol.capturedRequestBodies()
            let decoded = bodies.compactMap { try? JSONDecoder().decode(AIJSONValue.self, from: $0) }
            report.check(decoded.count == 3 && decoded[1] == decoded[2],
                         "Transient retry changed the cursor, duplicated output history, or lost its context.")
            await provider.discardToolWorkflow(workflowID)
        } catch { report.check(false, "Retry cursor check failed: \(error.localizedDescription)") }
        return report.result
    }

    private static func verifyServerContinuationCapability() async -> Report {
        var report = CheckAccumulator()
        // This mirrors a stateless Responses endpoint's successful search turn,
        // including its explicit store:false acknowledgement. No real provider
        // credentials, source passages, or network transport are used.
        let statelessSearch = Data(
            """
            {"id":"stateless-response","object":"response","created_at":1788318000,"status":"completed","error":null,"incomplete_details":null,"model":"deepseek-v4-pro","store":false,"output":[{"id":"reasoning-fixture","type":"reasoning","summary":[]},{"id":"function-fixture","type":"function_call","call_id":"stateless-search-call","name":"search_segments","arguments":"{\\"query\\":\\"method\\",\\"page_start\\":1,\\"page_end\\":3,\\"top_k\\":5,\\"strategy\\":\\"lexical\\"}","status":"completed"}],"usage":{"input_tokens":120,"output_tokens":20,"total_tokens":140}}
            """.utf8
        )
        for initiallyStored: Bool? in [nil, true] {
            ToolProviderMockURLProtocol.reset(responses:
                [toolResponse(id: "response-1", stored: initiallyStored), statelessSearch]
            )
            do {
                let provider = try makeProvider()
                let workflowID = UUID()
                let trace = AIInMemoryWorkflowTraceSink()
                do {
                    _ = try await AIToolWorkflowRunner(traceSink: trace).run(
                        request: request(workflowID), provider: provider,
                        executor: ToolProviderContinuationExecutor(), budget: .highlightDefault,
                        retryPolicy: AIWorkflowRetryPolicy(
                            maximumAttempts: 3, initialDelay: .zero, maximumDelay: .zero
                        )
                    )
                    report.check(false, "A server workflow silently switched to incomplete local history.")
                } catch OpenAICompatibleToolProviderError.serverContinuationUnsupported {
                    report.check(true, "")
                }
                let events = await trace.events
                report.check(!events.contains { if case .retryScheduled = $0 { return true }; return false },
                             "An explicit server-continuation refusal triggered a transport retry.")
                report.check(!AIToolWorkflowRunner.isTransientError(
                    OpenAICompatibleToolProviderError.serverContinuationUnsupported
                ), "Server-continuation incompatibility was classified as a transient failure.")
                let discarded = await isDiscarded(provider, workflowID)
                report.check(discarded, "An explicitly unsupported response retained its server cursor.")
                report.check(ToolProviderMockURLProtocol.capturedRequestBodies().count == 2,
                             "Dogear sent incomplete local history after server storage disappeared.")
            } catch { report.check(false, "Server-continuation capability check failed: \(error.localizedDescription)") }
        }

        // Omission is unknown, not refusal; an explicit true is also supported.
        for stored: Bool? in [nil, true] {
            ToolProviderMockURLProtocol.reset(responses: [
                toolResponse(id: "response-1", stored: stored),
                Data("{\"id\":\"finished\",\"output\":[],\"store\":false}".utf8)
            ])
            do {
                let provider = try makeProvider()
                let workflowID = UUID()
                _ = try await provider.beginToolWorkflow(request(workflowID))
                let retained = await provider.diagnosticRetainedItemCount(for: workflowID)
                report.check(retained == 0, "A supported or unknown server response retained local history.")
                let result = try await provider.continueToolWorkflow(continuation(workflowID, responseID: "response-1"))
                report.check(result.toolCalls.isEmpty, "Missing or true store capability rejected valid continuation.")
                let discarded = await isDiscarded(provider, workflowID)
                report.check(discarded, "A no-tools response with store:false did not clean up normally.")
                report.check(ToolProviderMockURLProtocol.capturedRequestBodies().count == 2,
                             "Storage capability handling changed the supported request count.")
            } catch { report.check(false, "Supported or omitted store check failed: \(error.localizedDescription)") }
        }

        ToolProviderMockURLProtocol.reset(responses: [
            toolResponse(id: "terminal-without-storage", name: "publish_answer", stored: false)
        ])
        do {
            let provider = try makeProvider()
            let workflowID = UUID()
            let result = try await AIToolWorkflowRunner().run(
                request: request(workflowID), provider: provider,
                executor: ToolProviderDiagnosticExecutor(mode: .terminate), budget: .highlightDefault
            )
            report.check(result.usage.providerTurns == 1,
                         "An already-terminal publication unnecessarily required server storage.")
            let discarded = await isDiscarded(provider, workflowID)
            report.check(discarded, "Terminal store:false publication retained a provider cursor.")
            report.check(ToolProviderMockURLProtocol.capturedRequestBodies().count == 1,
                         "A terminal store:false publication sent a receipt or continuation.")
        } catch { report.check(false, "Terminal unstored response check failed: \(error.localizedDescription)") }
        return report.result
    }

    private static func statelessFixture(
        id: String?, stored: Bool?, tag: String, multipleCalls: Bool = false
    ) -> Data {
        var output: [AIJSONValue] = [
            .object([
                "type": .string("reasoning"), "id": .string("\(tag)-reasoning"),
                "summary": .array([]), "encrypted_content": .string("\(tag)-opaque-reasoning"),
                "provider_extension": .object(["preserve": .bool(true)])
            ]),
            .object([
                "type": .string("function_call"), "id": .string("\(tag)-function-1"),
                "call_id": .string("\(tag)-call-1"), "name": .string("search_segments"),
                "arguments": .string("{\"query\":\"method\"}"), "status": .string("completed")
            ])
        ]
        if multipleCalls {
            output.append(.object([
                "type": .string("function_call"), "id": .string("\(tag)-function-2"),
                "call_id": .string("\(tag)-call-2"), "name": .string("get_document_map"),
                "arguments": .string("{}"), "status": .string("completed")
            ]))
        }
        output.append(.object([
            "type": .string("message"), "id": .string("\(tag)-message"),
            "role": .string("assistant"),
            "content": .array([.object(["type": .string("output_text"), "text": .string("\(tag)-interim")])])
        ]))
        var response: [String: AIJSONValue] = [
            "object": .string("response"), "output": .array(output),
            "status": .string("completed"), "usage": .object(["input_tokens": .number(10)])
        ]
        if let id { response["id"] = .string(id) }
        if let stored { response["store"] = .bool(stored) }
        return try! JSONEncoder().encode(AIJSONValue.object(response))
    }

    private static func items(_ data: Data, key: String) -> [AIJSONValue] {
        guard let decoded = try? JSONDecoder().decode(AIJSONValue.self, from: data),
              case .object(let object) = decoded,
              case .array(let items) = object[key] else { return [] }
        return items
    }

    private static func outputs(for turn: AIToolProviderTurn) -> [AIToolExecutionResult] {
        turn.toolCalls.map {
            AIToolExecutionResult(callID: $0.callID, output: Data("{\"accepted\":true}".utf8), readCharacterCount: 0)
        }
    }

    private static func wireOutputs(_ outputs: [AIToolExecutionResult]) -> [AIJSONValue] {
        outputs.map { .object([
            "type": .string("function_call_output"), "call_id": .string($0.callID),
            "output": .string(String(decoding: $0.output, as: UTF8.self))
        ]) }
    }

    private static func verifyStatelessHistory() async -> Report {
        var report = CheckAccumulator()
        let firstResponse = statelessFixture(id: "stateless-1", stored: false, tag: "first", multipleCalls: true)
        let secondResponse = statelessFixture(id: "stateless-2", stored: true, tag: "second")
        ToolProviderMockURLProtocol.reset(responses: [
            firstResponse, secondResponse,
            Data("{\"id\":\"done\",\"output\":[],\"store\":true}".utf8),
            Data("{\"id\":\"new-question\",\"output\":[],\"store\":false}".utf8)
        ])
        do {
            let provider = try makeProvider()
            let workflowID = UUID()
            let first = try await provider.beginToolWorkflow(request(workflowID, input: "FIRST_PRIVATE_QUESTION"))
            let firstCount = await provider.diagnosticRetainedItemCount(for: workflowID)
            report.check(firstCount == 1 + items(firstResponse, key: "output").count,
                         "Stateless bootstrap did not retain the complete original response in memory.")
            let firstOutputs = outputs(for: first)
            let second = try await provider.continueToolWorkflow(.init(
                workflowID: workflowID, previousResponseID: first.responseID, toolOutputs: firstOutputs
            ))
            let secondOutputs = outputs(for: second)
            _ = try await provider.continueToolWorkflow(.init(
                workflowID: workflowID, previousResponseID: second.responseID, toolOutputs: secondOutputs
            ))
            let cleared = await provider.diagnosticRetainedItemCount(for: workflowID)
            report.check(cleared == nil, "A completed stateless question retained its in-memory transcript.")
            let nextWorkflow = UUID()
            _ = try await provider.beginToolWorkflow(request(nextWorkflow, input: "SECOND_QUESTION_ONLY"))
            let bodies = ToolProviderMockURLProtocol.capturedRequestBodies()
            report.check(bodies.count == 4, "Stateless continuation changed the expected request count.")
            if bodies.count == 4 {
                let bootstrap = items(bodies[0], key: "input")
                let expectedSecond = bootstrap + items(firstResponse, key: "output") + wireOutputs(firstOutputs)
                let expectedThird = expectedSecond + items(secondResponse, key: "output") + wireOutputs(secondOutputs)
                report.check(items(bodies[1], key: "input") == expectedSecond,
                             "Stateless continuation lost or reordered raw reasoning, messages, functions, or batched outputs.")
                report.check(items(bodies[2], key: "input") == expectedThird,
                             "A later stateless turn duplicated outputs or omitted necessary conversation items.")
                for body in bodies[1...2].compactMap(jsonObject) {
                    report.check(body["store"] as? Bool == false && body["previous_response_id"] == nil,
                                 "Stateless mode switched back to server continuation or requested provider storage.")
                    report.check(body["instructions"] as? String == "Diagnostic instructions",
                                 "Stateless continuation omitted repeated instructions.")
                }
                let next = jsonObject(bodies[3])
                let nextInput = next?["input"] as? [[String: Any]] ?? []
                report.check(next?["previous_response_id"] == nil && nextInput.count == 1
                             && nextInput.first?["content"] as? String == "SECOND_QUESTION_ONLY",
                             "A new question leaked earlier stateless question/answer/reasoning context.")
            }
            let nextCleared = await provider.diagnosticRetainedItemCount(for: nextWorkflow)
            report.check(nextCleared == nil, "An initial no-tools stateless response retained a transcript.")
        } catch { report.check(false, "Stateless history check failed: \(error.localizedDescription)") }

        // A response ID is not used on the stateless wire; missing IDs remain
        // errors only for server continuation (covered by the existing fixtures).
        ToolProviderMockURLProtocol.reset(responses: [
            statelessFixture(id: nil, stored: false, tag: "no-id"),
            Data("{\"output\":[],\"store\":false}".utf8)
        ])
        do {
            let provider = try makeProvider()
            let workflowID = UUID()
            let first = try await provider.beginToolWorkflow(request(workflowID))
            _ = try await provider.continueToolWorkflow(.init(
                workflowID: workflowID, previousResponseID: nil, toolOutputs: outputs(for: first)
            ))
            let cleared = await provider.diagnosticRetainedItemCount(for: workflowID)
            report.check(first.responseID == nil && cleared == nil,
                         "Stateless execution unnecessarily required response IDs or failed to clean up.")
        } catch { report.check(false, "Stateless missing-ID check failed: \(error.localizedDescription)") }
        return report.result
    }

    private static func verifyStatelessRetry() async -> Report {
        var report = CheckAccumulator()
        let firstResponse = statelessFixture(id: "stateless-first", stored: false, tag: "retry", multipleCalls: true)
        ToolProviderMockURLProtocol.reset(replies: [
            .init(data: firstResponse),
            .init(data: Data("{\"error\":{\"message\":\"temporary\"}}".utf8), statusCode: 503),
            .init(data: Data("{\"output\":[],\"store\":false}".utf8))
        ])
        do {
            let provider = try makeProvider()
            let workflowID = UUID()
            let first = try await provider.beginToolWorkflow(request(workflowID))
            let next = AIToolWorkflowContinuationRequest(
                workflowID: workflowID, previousResponseID: first.responseID, toolOutputs: outputs(for: first)
            )
            do {
                _ = try await provider.continueToolWorkflow(next)
                report.check(false, "Stateless retry fixture ignored its service failure.")
            } catch AIProviderError.server(let code, _) {
                report.check(code == 503, "Stateless transient failure changed classification.")
            }
            let retained = await provider.diagnosticRetainedItemCount(for: workflowID)
            report.check(retained == 1 + items(firstResponse, key: "output").count,
                         "A failed stateless attempt appended its outputs to history prematurely.")
            _ = try await provider.continueToolWorkflow(next)
            let bodies = ToolProviderMockURLProtocol.capturedRequestBodies()
            let decoded = bodies.compactMap { try? JSONDecoder().decode(AIJSONValue.self, from: $0) }
            report.check(decoded.count == 3 && decoded[1] == decoded[2],
                         "Stateless retries did not send the same complete payload exactly once per attempt.")
            let cleared = await provider.diagnosticRetainedItemCount(for: workflowID)
            report.check(cleared == nil, "Successful stateless retry left history behind after no-tools completion.")
        } catch { report.check(false, "Stateless retry check failed: \(error.localizedDescription)") }
        return report.result
    }

    private static func verifyStatelessCleanup() async -> Report {
        var report = CheckAccumulator()
        for mode in ToolProviderDiagnosticExecutor.Mode.allCases {
            ToolProviderMockURLProtocol.reset(responses: [
                toolResponse(id: "stateless-final", name: "publish_answer", stored: false)
            ])
            do {
                let provider = try makeProvider()
                let workflowID = UUID()
                do {
                    _ = try await AIToolWorkflowRunner().run(
                        request: request(workflowID), provider: provider,
                        executor: ToolProviderDiagnosticExecutor(mode: mode), budget: .highlightDefault
                    )
                    report.check(mode == .terminate, "Stateless failure/cancellation became success.")
                } catch is CancellationError {
                    report.check(mode == .cancel, "Stateless cleanup returned the wrong cancellation.")
                } catch ToolProviderDiagnosticExecutor.Failure.expected {
                    report.check(mode == .fail, "Stateless cleanup returned the wrong failure.")
                }
                let cleared = await provider.diagnosticRetainedItemCount(for: workflowID)
                report.check(cleared == nil, "Terminal/failed/cancelled stateless workflow retained question history.")
                report.check(ToolProviderMockURLProtocol.capturedRequestBodies().count == 1,
                             "Stateless terminal cleanup sent an unwanted receipt or request.")
            } catch { report.check(false, "Stateless runner cleanup failed: \(error.localizedDescription)") }
        }
        for shouldCancel in [false, true] {
            ToolProviderMockURLProtocol.reset(replies: [
                .init(data: statelessFixture(id: nil, stored: false, tag: "pending-first")),
                .init(data: statelessFixture(id: nil, stored: false, tag: "pending-next"), pending: true)
            ])
            do {
                let provider = try makeProvider()
                let workflowID = UUID()
                let first = try await provider.beginToolWorkflow(request(workflowID))
                let next = AIToolWorkflowContinuationRequest(
                    workflowID: workflowID, previousResponseID: nil, toolOutputs: outputs(for: first)
                )
                let task = Task { try await provider.continueToolWorkflow(next) }
                await ToolProviderMockURLProtocol.waitForPendingRequest()
                if shouldCancel {
                    task.cancel()
                } else {
                    await provider.discardToolWorkflow(workflowID)
                    ToolProviderMockURLProtocol.releasePendingRequest()
                }
                do {
                    _ = try await task.value
                    report.check(false, "A stateless response revived disposed question history.")
                } catch is CancellationError {
                    report.check(shouldCancel, "Stateless discard produced an unexpected cancellation.")
                } catch OpenAICompatibleToolProviderError.workflowNotStarted {
                    report.check(!shouldCancel, "Stateless cancellation returned an unexpected discard error.")
                }
                let cleared = await provider.diagnosticRetainedItemCount(for: workflowID)
                report.check(cleared == nil, "A cancelled or late stateless response retained conversation items.")
                report.check(ToolProviderMockURLProtocol.capturedRequestBodies().count == 2,
                             "Stateless pending cleanup sent another request.")
            } catch { report.check(false, "Stateless pending cleanup failed: \(error.localizedDescription)") }
        }
        return report.result
    }

    private struct CheckAccumulator {
        var checks = 0
        var failures: [String] = []
        mutating func check(_ value: Bool, _ failure: String) {
            checks += 1
            if !value { failures.append(failure) }
        }
        var result: Report { Report(checks: checks, failures: failures) }
    }

    private static func jsonObject(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private nonisolated struct ToolProviderDiagnosticExecutor: AIToolExecuting {
    enum Mode: CaseIterable { case terminate, cancel, fail }
    enum Failure: Error { case expected }
    let mode: Mode

    func execute(_ invocation: AIToolInvocation) async throws -> AIToolExecutionResult {
        switch mode {
        case .cancel: throw CancellationError()
        case .fail: throw Failure.expected
        case .terminate:
            return AIToolExecutionResult(
                callID: invocation.callID, output: Data("{\"accepted\":true}".utf8),
                readCharacterCount: 0, disposition: .requestTermination
            )
        }
    }
}

private nonisolated struct ToolProviderContinuationExecutor: AIToolExecuting {
    func execute(_ invocation: AIToolInvocation) async throws -> AIToolExecutionResult {
        AIToolExecutionResult(
            callID: invocation.callID, output: Data("{\"accepted\":true}".utf8), readCharacterCount: 0
        )
    }
}

private final class ToolProviderMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        let data: Data
        var statusCode = 200
        var pending = false
    }
    private nonisolated(unsafe) static var responses: [Reply] = []
    private nonisolated(unsafe) static var requestBodies: [Data] = []
    private nonisolated(unsafe) static var pendingRequest: (ToolProviderMockURLProtocol, Reply)?
    private nonisolated(unsafe) static var pendingWaiter: CheckedContinuation<Void, Never>?
    private static let lock = NSLock()

    static func reset(responses: [Data]) {
        reset(replies: responses.map { Reply(data: $0) })
    }

    static func reset(replies: [Reply]) {
        lock.lock()
        self.responses = replies
        requestBodies = []
        pendingRequest = nil
        lock.unlock()
    }

    static func waitForPendingRequest() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if pendingRequest != nil {
                lock.unlock()
                continuation.resume()
            } else {
                pendingWaiter = continuation
                lock.unlock()
            }
        }
    }

    static func releasePendingRequest() {
        lock.lock()
        let pending = pendingRequest
        pendingRequest = nil
        lock.unlock()
        if let (request, reply) = pending { request.respond(reply) }
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
        let reply = Self.responses.isEmpty ? Reply(data: Data(), statusCode: 500) : Self.responses.removeFirst()
        if reply.pending {
            Self.pendingRequest = (self, reply)
            let waiter = Self.pendingWaiter
            Self.pendingWaiter = nil
            Self.lock.unlock()
            waiter?.resume()
            return
        }
        Self.lock.unlock()

        respond(reply)
    }

    private func respond(_ reply: Reply) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.lock.lock()
        if Self.pendingRequest?.0 === self { Self.pendingRequest = nil }
        Self.lock.unlock()
    }

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
