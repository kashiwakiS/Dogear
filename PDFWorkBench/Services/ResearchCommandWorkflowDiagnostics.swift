import Foundation

nonisolated enum ResearchCommandWorkflowDiagnostics {
    struct Report: Sendable { let checks: Int; let failures: [String] }
    static let extraDefinition = AIToolDefinition(name: "native_probe", description: "Offline command fixture.",
        schemaVersion: "1", strictInputSchema: Data(#"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#.utf8))

    static func run() async -> Report {
        var checks = 0
        var failures: [String] = []
        func check(_ result: Bool, _ message: String) {
            checks += 1
            if !result { failures.append(message) }
        }
        let traceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DogearComposite-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: traceRoot) }
        do {
            let snapshot = AIHighlightTextSnapshot(fingerprint: "composite", pages: [
                AITextPageSnapshot(pageNumber: 1, text: "The finding is reproducible.", fingerprint: "page-1")
            ])
            let registry = try AISegmentRegistry(snapshot: snapshot)
            let id = registry.records[0].id
            let image = AIToolInputImage(id: UUID(), mimeType: "image/png", data: Data([1, 2, 3]))
            let commands = ProbeExecutor()
            let provider = ProbeProvider(segmentID: id, image: image)
            let service = AIHighlightWorkflowService(runner: AIToolWorkflowRunner(),
                traceRecorder: AIHighlightTraceRecorder(fileURL: traceRoot.appendingPathComponent("trace.jsonl")))
            let result = try await service.generateReadingResult(snapshot: snapshot, intent: .question("Explain the result"),
                images: [image], additionalTools: [extraDefinition], additionalExecutor: commands,
                provider: provider, allowsAnnotations: false, verifiesAnswerEvidence: true)
            check(result.answer.terminate && result.highlights.isEmpty, "Composite workflow failed to return the core accepted answer")
            check(result.usage.toolCalls == 4 && result.usage.providerTurns == 4,
                  "Additional command or independent review escaped shared budgets")
            check(result.usage.readCharacters == registry.records[0].text.count + 7,
                  "Additional command read characters escaped the common evidence budget")
            check(await commands.calls == 1, "Registered native command did not execute exactly once")
            let summary = await provider.summary()
            check(summary.begins == 1 && summary.reviews == 1 && summary.continuations == 2 && summary.discards == 2,
                  "Composite workflow bypassed review or sent a receipt after accepted termination")
            check(summary.mainImages == [image] && summary.reviewImages == [image],
                  "Runner/composite dropped actual image bytes from main request or independent review")
            check(summary.requiredCalls == [true, true],
                  "Publication and independent review did not require a function call")
            check(summary.mainToolNames.contains(extraDefinition.name)
                && summary.mainToolNames.contains(AIHighlightToolName.publishAnswer), "Extra definitions replaced core evidence tools")

            let core = AIHighlightToolExecutor(registry: registry, intent: .overview)
            let composite = try ResearchCompositeExecutor(core: core, coreDefinitions: AIHighlightToolCodec.definitions,
                additionalDefinitions: [extraDefinition], additionalExecutor: commands)
            let call = AIToolInvocation(callID: "late", name: extraDefinition.name, arguments: Data("{}".utf8))
            await composite.close()
            do { _ = try await composite.execute(call); check(false, "Closed composite executed a late native command") }
            catch { check(error as? ResearchCompositeExecutorError == .inactiveWorkflow, "Wrong late command rejection") }
            check(await commands.calls == 1, "Late command reached the native executor")
            for definitions in [[AIHighlightToolCodec.definitions.last!], [AIAnswerEvidenceReview.definition], [extraDefinition, extraDefinition]] {
                do {
                    _ = try ResearchCompositeExecutor.combinedDefinitions(core: AIHighlightToolCodec.definitions,
                        additional: definitions, executor: commands)
                    check(false, "Duplicate/reserved registration replaced a protected tool")
                } catch { check(error as? ResearchCompositeExecutorError == .invalidRegistration, "Wrong registration rejection") }
            }
            do {
                _ = try ResearchCompositeExecutor.combinedDefinitions(core: AIHighlightToolCodec.definitions,
                    additional: [extraDefinition], executor: nil)
                check(false, "Additional tool without executor was advertised")
            } catch { check(error as? ResearchCompositeExecutorError == .invalidRegistration, "Missing executor returned wrong error") }

            let cancellationCommands = ProbeExecutor()
            let cancellationComposite = try ResearchCompositeExecutor(core: core, coreDefinitions: AIHighlightToolCodec.definitions,
                additionalDefinitions: [extraDefinition], additionalExecutor: cancellationCommands)
            let task = Task { () throws -> AIToolExecutionResult in
                // Deliberately still enter the wrapper with a cancelled task.
                try? await Task.sleep(for: .seconds(10))
                return try await cancellationComposite.execute(call)
            }
            task.cancel()
            do { _ = try await task.value; check(false, "Cancelled command completed") }
            catch { check(error is CancellationError, "Command cancellation was not preserved") }
            await cancellationComposite.close()
            check(await cancellationCommands.calls == 0, "Cancelled command reached native execution")

            let malicious = ProbeExecutor(terminates: true)
            let malformedComposite = try ResearchCompositeExecutor(core: core, coreDefinitions: AIHighlightToolCodec.definitions,
                additionalDefinitions: [extraDefinition], additionalExecutor: malicious)
            do { _ = try await malformedComposite.execute(call); check(false, "Additional command could terminate the workflow") }
            catch { check(error as? ResearchCompositeExecutorError == .additionalToolCannotTerminate, "Wrong arbitrary terminal rejection") }
            check(await core.completedAnswer() == nil, "An additional terminal result became an accepted answer")

            // The same wrapper enforces the sole-call rule for mixed native/final batches.
            let mixedCore = AIHighlightToolExecutor(registry: registry, intent: .overview)
            let mixed = try ResearchCompositeExecutor(core: mixedCore, coreDefinitions: AIHighlightToolCodec.definitions,
                additionalDefinitions: [extraDefinition], additionalExecutor: commands)
            let terminal = AIToolInvocation(callID: "mixed-final", name: AIHighlightToolName.publishAnswer,
                arguments: Data(#"{"completion_status":"notFound","title":"Scope","result_markdown":"Insufficient evidence.","evidence_segment_ids":[],"final_draft_revision":0,"terminate":true}"#.utf8))
            let output = try await mixed.execute(terminal, batchCount: 2)
            check(try AIHighlightToolCodec().decodePublishResult(output.output).error == .terminalMustBeSoleCall,
                  "Wrapper lost the core mixed-terminal protection")
            _ = try await mixed.execute(terminal, batchCount: 1)
            do { _ = try await mixed.execute(call); check(false, "Accepted terminal left native commands open") }
            catch { check(error as? ResearchCompositeExecutorError == .inactiveWorkflow, "Accepted terminal returned wrong late-action error") }
        } catch { check(false, "Composite workflow diagnostics failed: \(error)") }
        return Report(checks: checks, failures: failures)
    }

    private actor ProbeExecutor: AIToolExecuting {
        var calls = 0
        let terminates: Bool
        init(terminates: Bool = false) { self.terminates = terminates }
        func execute(_ invocation: AIToolInvocation) async throws -> AIToolExecutionResult {
            try Task.checkCancellation()
            calls += 1
            return .init(callID: invocation.callID, output: Data("{\"ok\":true}".utf8), readCharacterCount: 7,
                         disposition: terminates ? .requestTermination : .continueWorkflow)
        }
    }
    private actor ProbeProvider: AIToolCallingProvider {
        nonisolated let toolCapabilities = AIToolProviderCapabilities(supportsFunctionTools: true,
            supportsStrictToolSchemas: true, supportsResponseContinuation: true, supportsStructuredFinalResult: false, supportsImages: true)
        let segmentID: AISegmentID
        let image: AIToolInputImage
        var begins = 0
        var reviews = 0
        var continuations = 0
        var discards = 0
        var mainImages: [AIToolInputImage] = []
        var reviewImages: [AIToolInputImage] = []
        var mainToolNames: [String] = []
        var requiredCalls: [Bool] = []
        init(segmentID: AISegmentID, image: AIToolInputImage) { self.segmentID = segmentID; self.image = image }
        func beginToolWorkflow(_ request: AIToolWorkflowProviderRequest) async throws -> AIToolProviderTurn {
            requiredCalls.append(request.requiresToolCall)
            if request.tools.map(\.name) == [AIAnswerEvidenceReview.toolName] {
                reviews += 1
                reviewImages = request.images
                return turn(name: AIAnswerEvidenceReview.toolName, arguments: """
                {"completion_status":"answered","claims":[{"claim":"The finding is reproducible.","status":"supported","evidence_ids":["\(segmentID)","\(image.id.uuidString)"],"reason":"Supported by the supplied evidence."}]}
                """)
            }
            begins += 1
            mainImages = request.images
            mainToolNames = request.tools.map(\.name)
            return turn(name: ResearchCommandWorkflowDiagnostics.extraDefinition.name, arguments: "{}")
        }
        func continueToolWorkflow(_ request: AIToolWorkflowContinuationRequest) async throws -> AIToolProviderTurn {
            continuations += 1
            if continuations == 1 {
                return turn(name: AIHighlightToolName.readSegments,
                    arguments: "{\"ids\":[\"\(segmentID)\"],\"context_before\":0,\"context_after\":0}")
            }
            guard continuations == 2 else { throw AIProviderError.invalidResponse }
            return turn(name: AIHighlightToolName.publishAnswer, arguments: """
            {"completion_status":"answered","title":"Result","result_markdown":"The finding is reproducible.","evidence_segment_ids":["\(segmentID)"],"evidence_image_ids":["\(image.id.uuidString)"],"final_draft_revision":0,"terminate":true}
            """)
        }
        func discardToolWorkflow(_ workflowID: UUID) async { discards += 1 }
        func summary() -> Summary {
            .init(begins: begins, reviews: reviews, continuations: continuations, discards: discards,
                mainImages: mainImages, reviewImages: reviewImages, mainToolNames: mainToolNames, requiredCalls: requiredCalls)
        }
        private func turn(name: String, arguments: String) -> AIToolProviderTurn {
            .init(responseID: UUID().uuidString, toolCalls: [.init(callID: UUID().uuidString, name: name,
                arguments: Data(arguments.utf8))], structuredFinalResult: nil, inputTokens: 10)
        }
        struct Summary: Sendable {
            let begins: Int; let reviews: Int; let continuations: Int; let discards: Int
            let mainImages: [AIToolInputImage]; let reviewImages: [AIToolInputImage]; let mainToolNames: [String]
            let requiredCalls: [Bool]
        }
    }
}
