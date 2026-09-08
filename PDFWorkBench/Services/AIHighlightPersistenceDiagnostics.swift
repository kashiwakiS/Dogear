import Foundation

@MainActor
enum AIHighlightPersistenceDiagnostics {
    static func run() async -> AIHighlightFoundationDiagnosticReport {
        var checks = 0
        var failures: [String] = []

        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }

        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("AIHighlightPersistenceDiagnostics-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: rootURL) }

        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            let stateURL = rootURL.appendingPathComponent("groups.json")
            let documentID = UUID()
            let groupID = UUID()
            let group = AIHighlightGroup(
                id: groupID,
                requestKind: .question,
                title: "Conclusion Evidence",
                question: "What supports the conclusion?",
                providerName: "Diagnostic Provider",
                modelName: "diagnostic-model",
                promptVersion: "diagnostic-v1",
                annotationUniqueNames: [
                    "dogear.ai.v2.\(groupID.uuidString).\(UUID().uuidString)"
                ],
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let groupStore = AIHighlightGroupStore(stateURL: stateURL)
            groupStore.replaceDocumentState(
                AIHighlightDocumentGroupState(
                    documentID: documentID,
                    groups: [group],
                    visibleGroupIDs: [groupID]
                )
            )
            let reloadedStore = AIHighlightGroupStore(stateURL: stateURL)
            let reloaded = reloadedStore.documentState(for: documentID)
            check(reloaded?.groups == [group], "AI highlight groups did not survive reload.")
            check(
                reloaded?.visibleGroupIDs == [groupID],
                "Visible AI highlight group IDs did not survive reload."
            )

            let stateAttributes = try fileManager.attributesOfItem(
                atPath: stateURL.path
            )
            check(
                (stateAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                "AI highlight group metadata did not use 0600 permissions."
            )
            let stateDirectoryAttributes = try fileManager.attributesOfItem(
                atPath: stateURL.deletingLastPathComponent().path
            )
            check(
                (stateDirectoryAttributes[.posixPermissions] as? NSNumber)?.intValue
                    == 0o700,
                "AI highlight group metadata directory did not use 0700 permissions."
            )

            let defaultsName = "AIHighlightPersistenceDiagnostics-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: defaultsName)!
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            defaults.set(
                false,
                forKey: AIHighlightTraceRecorder.detailedContentDefaultsKey
            )
            let traceURL = rootURL.appendingPathComponent("trace-v1.jsonl")
            let recorder = AIHighlightTraceRecorder(
                fileURL: traceURL,
                maximumFileBytes: 1_000_000,
                defaults: defaults
            )
            await recorder.record(
                workflowID: groupID,
                groupID: groupID,
                event: .workflow(
                    .toolFinished(
                        callID: "read-1",
                        name: "read_segments",
                        output: Data(
                            #"{"items":[{"id":"D001.P001.B001.S001","text":"private passage"}]}"#.utf8
                        ),
                        readCharacters: 15
                    )
                )
            )
            await recorder.record(
                workflowID: groupID,
                groupID: groupID,
                event: .draftCompleted(
                    revision: 1,
                    title: "Conclusion Evidence",
                    stagedCount: 1,
                    providerTurns: 3,
                    toolCalls: 4,
                    readCharacters: 128,
                    inputTokens: 256
                )
            )
            await recorder.record(
                workflowID: groupID,
                groupID: groupID,
                event: .workflowPrepared(
                    promptVersion: "fixture-v1", instructions: "private instructions",
                    input: "private question", toolSchemaVersions: [:]
                )
            )
            await recorder.record(
                workflowID: groupID,
                groupID: groupID,
                event: .workflow(.toolFinished(
                    callID: "answer-1", name: "publish_answer",
                    output: Data(#"{"accepted":true,"publication":{"result_markdown":"private answer","note":"private note","query":"private query"}}"#.utf8),
                    readCharacters: 0
                ))
            )
            await recorder.record(
                workflowID: groupID,
                groupID: groupID,
                event: .answerCompleted(status: .answered, evidenceCount: 2, highlightCount: 0, revision: 0)
            )
            await recorder.record(
                workflowID: groupID,
                groupID: groupID,
                event: .workflow(.continuationDisposed)
            )
            await recorder.record(
                workflowID: groupID,
                groupID: groupID,
                event: .failed(
                    code: "diagnostic_error",
                    message: "private provider payload"
                )
            )
            let redactedTrace = try String(contentsOf: traceURL, encoding: .utf8)
            check(redactedTrace.contains(groupID.uuidString), "Trace omitted its group ID.")
            check(
                redactedTrace.contains("Conclusion Evidence"),
                "Trace omitted the generated workflow title."
            )
            check(
                redactedTrace.contains("<redacted>")
                    && !redactedTrace.contains("private passage")
                    && !redactedTrace.contains("private provider payload")
                    && !redactedTrace.contains("private instructions")
                    && !redactedTrace.contains("private question")
                    && !redactedTrace.contains("private answer")
                    && !redactedTrace.contains("private note")
                    && !redactedTrace.contains("private query"),
                "Default trace did not redact source passage content."
            )
            let records = try redactedTrace.split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
            check(records.enumerated().allSatisfy { index, record in
                record["sequence"] as? Int == index
                    && record["workflow_id"] as? String == groupID.uuidString
            }, "Workflow trace sequence or workflow identity is inconsistent.")
            let events = records.compactMap { $0["event"] as? [String: Any] }
            check(events.contains { $0["retrieval_mode"] as? String == "scheme1" },
                  "Trace omitted the active lexical retrieval mode.")
            check(events.contains {
                $0["kind"] as? String == "answer_completed"
                    && $0["answer_evidence_count"] as? Int == 2
                    && $0["highlight_count"] as? Int == 0
            }, "Trace omitted answer-only completion counts.")
            check(events.contains {
                $0["kind"] as? String == "continuation_disposed"
                    && $0["local_transcript_retained"] as? Bool == false
            }, "Trace omitted local continuation cleanup.")

            defaults.set(
                true,
                forKey: AIHighlightTraceRecorder.detailedContentDefaultsKey
            )
            await recorder.record(
                workflowID: groupID,
                groupID: groupID,
                event: .workflow(
                    .toolFinished(
                        callID: "read-2",
                        name: "read_segments",
                        output: Data(
                            #"{"items":[{"id":"D001.P001.B001.S002","text":"captured passage"}]}"#.utf8
                        ),
                        readCharacters: 16
                    )
                )
            )
            let detailedTrace = try String(contentsOf: traceURL, encoding: .utf8)
#if DEBUG
            check(
                detailedTrace.contains("captured passage"),
                "Detailed trace did not retain explicitly enabled passage content."
            )
#else
            check(
                !detailedTrace.contains("captured passage"),
                "A non-Debug build retained detailed passage content."
            )
#endif

            let traceAttributes = try fileManager.attributesOfItem(
                atPath: traceURL.path
            )
            check(
                (traceAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                "AI highlight trace did not use 0600 permissions."
            )
            let traceDirectoryAttributes = try fileManager.attributesOfItem(
                atPath: traceURL.deletingLastPathComponent().path
            )
            check(
                (traceDirectoryAttributes[.posixPermissions] as? NSNumber)?.intValue
                    == 0o700,
                "AI highlight trace directory did not use 0700 permissions."
            )
        } catch {
            failures.append(error.localizedDescription)
        }

        return AIHighlightFoundationDiagnosticReport(
            checkCount: checks,
            failures: failures
        )
    }
}
