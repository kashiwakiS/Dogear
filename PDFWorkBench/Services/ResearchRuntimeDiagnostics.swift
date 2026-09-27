import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// Synthetic PDFs, private temporary stores, mock providers and isolated trace
/// files only. No user credentials, logs, retrieval settings or network calls.
@MainActor
enum ResearchRuntimeDiagnostics {
    static func run() async -> AIHighlightFoundationDiagnosticReport {
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ResearchRuntime-\(UUID().uuidString)")
        let suiteName = "ResearchRuntimeDiagnostics.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return .init(checkCount: 1, failures: ["Could not create isolated Research defaults."])
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = ResearchStore(rootURL: root.appendingPathComponent("research"))
            let commands = ResearchCommandService(store: store)
            let fileID = UUID(), viewID = UUID(), requestID = UUID()
            let sessionID = store.createSession(title: "Synthetic privacy fixture")
            let noteID = store.createNote(title: "SENTINEL_NOTE_TITLE", body: "SENTINEL_NOTE_BODY")
            let source = ResearchSourceSnapshot(fileID: fileID, displayName: "SENTINEL_FILE_NAME", fingerprint: "v1")
            let state = ResearchWorkspaceViewState(mainFileID: fileID, pageIndex: 2, zoomPercent: 150,
                wideAI: true, visibleGroupIDs: [], highlightGroups: [
                    ResearchHighlightGroupState(id: UUID(), title: "SENTINEL_GROUP_TITLE", visible: true)
                ], selectedText: "SENTINEL_SELECTION", selectedAnnotationText: "SENTINEL_ANNOTATION")
            commands.register(viewID: viewID, handlers: ResearchCommandHandlers(snapshot: { state },
                showSource: { _, _ in }, setZoom: { _ in }, setWideAI: { _ in },
                setGroupVisible: { _, _, _ in }, restore: { _ in }))
            let executor = commands.makeExecutor(requestID: requestID, sessionID: sessionID, viewID: viewID,
                allowedSources: [source], question: "Please revise the selected research note", targetNoteID: noteID)
            let output = try await executor.execute(AIToolInvocation(callID: "privacy-read", name: "read_research_workspace",
                arguments: Data("{}".utf8)))
            let raw = String(decoding: output.output, as: UTF8.self)
            let sentinels = ["SENTINEL_SELECTION", "SENTINEL_ANNOTATION", "SENTINEL_NOTE_BODY",
                             "SENTINEL_NOTE_TITLE", "SENTINEL_FILE_NAME", "SENTINEL_GROUP_TITLE"]
            check(sentinels.allSatisfy { raw.contains($0) }, "Privacy fixture did not exercise real Research workspace/note content.")
            let traceURL = root.appendingPathComponent("privacy.jsonl")
            let trace = AIHighlightTraceRecorder(fileURL: traceURL, defaults: defaults)
            await trace.record(workflowID: requestID, groupID: requestID,
                event: .workflow(.toolFinished(callID: "privacy-read", name: "read_research_workspace",
                                               output: output.output, readCharacters: output.readCharacterCount)))
            await trace.record(workflowID: requestID, groupID: requestID, event: .workflow(.toolStarted(
                callID: "note-stage", name: "create_research_note", arguments: Data(#"{"title":"SENTINEL_STAGED_TITLE"}"#.utf8))))
            let future = try JSONSerialization.data(withJSONObject: ["new_content": ["SENTINEL_UNKNOWN_KEY": "SENTINEL_UNKNOWN_VALUE"],
                "items": [["id": "SENTINEL_FAKE_ID", "count": "SENTINEL_FAKE_NUMBER"]], "message": "SENTINEL_ERROR_BODY"])
            await trace.record(workflowID: requestID, groupID: requestID, event: .workflow(.toolFinished(
                callID: "future", name: "future_tool", output: future, readCharacters: 0)))
            let redacted = try String(contentsOf: traceURL, encoding: .utf8)
            check(!redacted.contains("SENTINEL_"), "Default trace retained Research content, an unknown field/key or a forged metadata value.")
            check(redacted.contains(fileID.uuidString) && redacted.contains("pageIndex") && redacted.contains("read_characters"),
                  "Safe projection removed useful source identity, page or budget metadata.")
            defaults.set(true, forKey: AIHighlightTraceRecorder.detailedContentDefaultsKey)
            let detailedID = UUID()
            await trace.record(workflowID: detailedID, groupID: detailedID, event: .workflow(.toolFinished(
                callID: "detailed", name: "read_research_workspace", output: output.output, readCharacters: output.readCharacterCount)))
            let detailed = try String(contentsOf: traceURL, encoding: .utf8)
#if DEBUG
            check(sentinels.allSatisfy { detailed.contains($0) }, "Explicit Debug detailed trace omitted actual Research content.")
#else
            check(!detailed.contains("SENTINEL_"), "Release honored the detailed-content preference.")
#endif
            defaults.set(false, forKey: AIHighlightTraceRecorder.detailedContentDefaultsKey)
            commands.end(requestID: requestID)
            commands.unregister(viewID: viewID)

            let library = LibraryStore(userDefaults: defaults,
                storage: try LibraryJSONStore(stateURL: root.appendingPathComponent("library.json")))
            let document = try makePDF()
            let pdfURL = root.appendingPathComponent("Synthetic.pdf")
            guard document.write(to: pdfURL) else { throw CocoaError(.fileWriteUnknown) }
            let file = library.upsertOpenedURL(pdfURL, refreshBookmark: false)
            let snapshot = try await NativePDFTextSnapshotBuilder(document: document).makeTextSnapshotCooperatively()
            let segmentID = try AISegmentRegistry(snapshot: snapshot).records[0].id.description
            let offline = try configuration(root: root, defaults: defaults, enabled: false)
            let cloud = try configuration(root: root, defaults: defaults, enabled: true)

            // Exercise the actual Send -> loadImages boundary, not an injected
            // provider error. Missing/corrupt attachments must retain the draft
            // and stop before credential resolution or request creation.
            for name in ["missing-record", "missing-file", "corrupt-file"] {
                let imageStore = ResearchStore(rootURL: root.appendingPathComponent(name))
                let id = imageStore.createSession(title: name)
                let attachmentID: UUID
                if name == "missing-record" { attachmentID = UUID() }
                else {
                    let attachment = try imageStore.importAttachment(data: Data("invalid-image-fixture".utf8),
                        displayName: "Synthetic image", mimeType: "image/png", fileExtension: "png")
                    attachmentID = attachment.id
                    if name == "missing-file", let url = imageStore.attachmentURL(id: attachment.id) {
                        try FileManager.default.removeItem(at: url)
                    }
                }
                let draft = ResearchDraft(text: "Describe the attached image.", blocks: [
                    ResearchInputBlock(kind: .image, attachmentID: attachmentID)
                ])
                imageStore.saveDraft(draft, sessionID: id)
                var providerWasResolved = false
                let runtime = ResearchRuntime(storage: imageStore, configuration: cloud,
                    traceRecorder: AIHighlightTraceRecorder(fileURL: root.appendingPathComponent("\(name).jsonl"), defaults: defaults),
                    commands: ResearchCommandService(store: imageStore), retrievalSelection: .lexical,
                    providerResolver: { _ in providerWasResolved = true; return SuccessProvider(segmentID: segmentID) })
                runtime.send(sessionID: id, library: library, mainStore: nil, viewID: UUID())
                let expected: ResearchStoreError = name == "corrupt-file" ? .invalidAttachment : .missingAttachment
                check(runtime.errors[id] == AIHighlightFailureMessage.userMessage(for: expected),
                      "\(name): real attachment validation lost its missing/invalid classification.")
                check(imageStore.session(id: id)?.draft == draft && imageStore.session(id: id)?.messages.isEmpty == true,
                      "\(name): attachment validation consumed the draft or created an unsendable request.")
                check(runtime.jobs.isEmpty && !providerWasResolved,
                      "\(name): unavailable attachment reached credentials/provider execution.")
            }

            func exercise(_ name: String, configuration: AIConfigurationStore, question: String = "",
                          timeout: Duration = .seconds(10), cancelImmediately: Bool = false,
                          failSave: Bool = false,
                          provider: @escaping (AIProviderRequestTicket) async throws -> any AIToolCallingProvider) async throws -> (ResearchMessage?, [[String: Any]], String?, Int, Int) {
                var rejectFinalSave = false
                let caseStore = ResearchStore(rootURL: root.appendingPathComponent(name), atomicWriter: { data, url in
                    if rejectFinalSave { throw CocoaError(.fileWriteOutOfSpace) }
                    try data.write(to: url, options: .atomic)
                })
                let id = caseStore.createSession(title: name, sourceSelection: .init(fileIDs: [file.id]))
                var draft = ResearchDraft()
                draft.text = question
                caseStore.saveDraft(draft, sessionID: id)
                let log = root.appendingPathComponent("\(name).jsonl")
                let recorder = AIHighlightTraceRecorder(fileURL: log, defaults: defaults)
                let runtime = ResearchRuntime(storage: caseStore, configuration: configuration,
                    traceRecorder: recorder, commands: ResearchCommandService(store: caseStore), requestTimeout: timeout,
                    retrievalSelection: .lexical, providerResolver: { ticket in
                        let result = try await provider(ticket)
                        if failSave { rejectFinalSave = true }
                        return result
                    })
                runtime.send(sessionID: id, library: library, mainStore: nil, viewID: UUID())
                let capturedID = caseStore.session(id: id)?.messages.last?.requestID
                if cancelImmediately { runtime.cancel(sessionID: id); runtime.cancel(sessionID: id) }
                let completed = await waitUntil {
                    guard runtime.jobs[id] == nil, let data = try? Data(contentsOf: log),
                          let text = String(data: data, encoding: .utf8) else { return false }
                    return text.contains("request_finished")
                }
                check(completed, "\(name): request did not terminate promptly.")
                // Give a canceled provider/runtime its opportunity to report a
                // late implementation-layer CancellationError.
                for _ in 0..<12 { await Task.yield() }
                let records = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
                    try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
                }
                let events = records.compactMap { $0["event"] as? [String: Any] }
                check(events.filter { $0["kind"] as? String == "request_finished" }.count == 1,
                      "\(name): Research emitted duplicate/missing terminal events.")
                check(records.enumerated().allSatisfy { index, record in
                    record["sequence"] as? Int == index && record["workflow_id"] as? String == capturedID?.uuidString
                }, "\(name): Research sequence or workflow identity changed.")
                check(events.last?["kind"] as? String == "request_finished", "\(name): late events followed the request terminal state.")
                let active = await recorder.activeWorkflowCount
                let sequences = await recorder.trackedSequenceCount
                check(active == 0 && sequences == 0, "\(name): active/sequence bookkeeping leaked after termination.")
                if failSave {
                    check(!caseStore.saveFailures.isEmpty && caseStore.session(id: id)?.messages.last?.answer != nil,
                          "Accepted answer was lost when final persistence failed.")
                }
                return (caseStore.session(id: id)?.messages.last, events, runtime.errors[id], active, sequences)
            }

            let local = try await exercise("local", configuration: offline) { _ in
                throw AIProviderError.invalidResponse
            }
            check(local.0?.status == .accepted && local.0?.origin == .localOutline
                  && local.1.last?["termination_cause"] as? String == "local_outline", "Local outline lost its accepted request terminal.")
            for pendingSave in [false, true] {
                let success = try await exercise(pendingSave ? "pending-save" : "cloud-answer", configuration: cloud,
                    question: "Explain the synthetic finding.", failSave: pendingSave) { _ in
                    SuccessProvider(segmentID: segmentID)
                }
                check(success.0?.status == .accepted && success.1.last?["saved"] as? Bool == !pendingSave,
                      "Cloud answer-only completion confused accepted content and save status.")
            }
            let failureCases: [(String, Error, String)] = [
                ("http-401", AIProviderError.server(statusCode: 401, message: "SENTINEL_PROVIDER_BODY"), "authentication"),
                ("http-429", AIProviderError.server(statusCode: 429, message: "SENTINEL_PROVIDER_BODY"), "rate_limited"),
                ("http-503", AIProviderError.server(statusCode: 503, message: "SENTINEL_PROVIDER_BODY"), "service_unavailable"),
                ("budget", AIWorkflowFoundationError.budgetExceeded(.providerTurns), "internal_budget"),
                ("provider-timeout", URLError(.timedOut), "timeout"),
                ("source-changed", ResearchRuntimeError.sourceChanged("Synthetic.pdf"), "document_changed"),
                ("invalid-attachment", ResearchStoreError.invalidAttachment, "invalid_input"),
                ("missing-attachment", ResearchStoreError.missingAttachment, "source_unavailable")
            ]
            for (name, error, code) in failureCases {
                let result = try await exercise(name, configuration: cloud, question: "Synthetic question") { _ in throw error }
                check(result.0?.status == .failed && result.2 == AIHighlightFailureMessage.userMessage(for: error)
                      && result.1.last?["termination_cause"] as? String == code,
                      "\(name): Research bypassed its classified user message or stable error code.")
                check(result.2?.contains("SENTINEL_") == false, "Provider response body reached the Research error UI.")
            }
            let cancelled = try await exercise("cancelled", configuration: cloud, question: "Keep this draft",
                                               cancelImmediately: true) { _ in SuccessProvider(segmentID: segmentID) }
            check(cancelled.0?.status == .cancelled && cancelled.1.last?["termination_cause"] as? String == "user_cancelled",
                  "Immediate user cancellation lost its original termination cause.")
            let timedOut = try await exercise("watchdog", configuration: cloud, question: "Keep timeout draft",
                                               timeout: .milliseconds(25)) { _ in
                try await Task.sleep(for: .seconds(30))
                return SuccessProvider(segmentID: segmentID)
            }
            check(timedOut.0?.status == .failed && timedOut.1.last?["termination_cause"] as? String == "request_timeout"
                  && timedOut.1.last?["cancellation_requested"] as? Bool == true,
                  "Watchdog timeout was overwritten by implementation cancellation.")

            let lifecycleID = UUID()
            await trace.record(workflowID: lifecycleID, groupID: lifecycleID, event: .jobStarted(
                requestKind: .question, question: nil, providerName: "Fixture", modelName: "Fixture"))
            check(await trace.hasActiveWorkflows, "Trace did not protect its destination during an active request.")
#if DEBUG
            do {
                try await trace.chooseDebugDirectory(root.appendingPathComponent("active-destination"))
                check(false, "Trace allowed a destination switch during an active request.")
            } catch { check(true, "") }
#endif
            await trace.record(workflowID: lifecycleID, groupID: lifecycleID,
                event: .requestFinished(status: "accepted", cause: "completed", saved: true, cancellationRequested: false))
            await trace.record(workflowID: lifecycleID, groupID: lifecycleID, event: .workflow(.cancelled))
            await trace.record(workflowID: lifecycleID, groupID: lifecycleID,
                event: .requestFinished(status: "cancelled", cause: "late", saved: true, cancellationRequested: true))
            check(!(await trace.hasActiveWorkflows), "Finished Research kept the destination locked.")
            let finished = try String(contentsOf: traceURL, encoding: .utf8).split(separator: "\n").compactMap { line -> [String: Any]? in
                let item = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                return item["workflow_id"] as? String == lifecycleID.uuidString ? item : nil
            }
            check(finished.count == 2, "Duplicate terminal or late nested workflow event reopened finished Research.")
        } catch { failures.append("Research runtime fixture: \(error.localizedDescription)") }
        return .init(checkCount: checks, failures: failures)
    }

    private static func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    private static func configuration(root: URL, defaults: UserDefaults, enabled: Bool) throws -> AIConfigurationStore {
        var config = AIProviderConfiguration(id: UUID(), name: "Synthetic provider", baseURL: "https://fixture.invalid/v1",
            model: "fixture", isCloudAIEnabled: enabled, hasCloudConsent: enabled, secretStorageMode: .plaintextFile)
        config.imageCapability = .supported
        let object: [String: Any] = ["provider": try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)),
                                   "apiKey": "synthetic-unused-key", "hasStoredKeychainAPIKey": false]
        let url = root.appendingPathComponent("config-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return AIConfigurationStore(configurationURL: url, legacyUserDefaults: defaults, secretStore: EmptySecrets())
    }

    private final class EmptySecrets: AISecretStoring {
        func readSecret(profileID: UUID) -> String? { nil }
        func saveSecret(_ secret: String, profileID: UUID, configurationName: String) {}
        func removeSecret(profileID: UUID) {}
        func updateLabel(profileID: UUID, configurationName: String) {}
    }

    private static func makePDF() throws -> PDFDocument {
        let bytes = NSMutableData()
        guard let consumer = CGDataConsumer(data: bytes as CFMutableData) else { throw CocoaError(.fileWriteUnknown) }
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 72, y: 700)
        let text = NSAttributedString(string: "The synthetic finding is reproducible.",
            attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage()
        context.closePDF()
        guard let result = PDFDocument(data: bytes as Data) else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }

    private actor SuccessProvider: AIToolCallingProvider {
        nonisolated let toolCapabilities = AIToolProviderCapabilities(supportsFunctionTools: true, supportsStrictToolSchemas: true, supportsResponseContinuation: true, supportsStructuredFinalResult: false)
        let segmentID: String
        init(segmentID: String) { self.segmentID = segmentID }
        func beginToolWorkflow(_ request: AIToolWorkflowProviderRequest) async throws -> AIToolProviderTurn {
            if request.tools.contains(where: { $0.name == AIAnswerEvidenceReview.toolName }) {
                return turn(AIAnswerEvidenceReview.toolName, """
                {"completion_status":"answered","claims":[{"claim":"The synthetic finding is reproducible.","status":"supported","evidence_ids":["\(segmentID)"],"reason":"Supported by supplied evidence."}]}
                """)
            }
            return turn(AIHighlightToolName.readSegments,
                "{\"ids\":[\"\(segmentID)\"],\"context_before\":0,\"context_after\":0}")
        }
        func continueToolWorkflow(_ request: AIToolWorkflowContinuationRequest) async throws -> AIToolProviderTurn {
            turn(AIHighlightToolName.publishAnswer, """
            {"completion_status":"answered","title":"Synthetic finding","result_markdown":"The synthetic finding is reproducible.","evidence_segment_ids":["\(segmentID)"],"evidence_image_ids":[],"final_draft_revision":0,"terminate":true}
            """)
        }
        func discardToolWorkflow(_ workflowID: UUID) async {}
        private func turn(_ name: String, _ arguments: String) -> AIToolProviderTurn {
            .init(responseID: UUID().uuidString, toolCalls: [.init(callID: UUID().uuidString, name: name,
                arguments: Data(arguments.utf8))], structuredFinalResult: nil, inputTokens: 5)
        }
    }
}
