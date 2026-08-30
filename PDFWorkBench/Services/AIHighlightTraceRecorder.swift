import Foundation

nonisolated enum AIHighlightTraceEvent: Sendable {
    case jobStarted(
        requestKind: AIHighlightGroupRequestKind,
        question: String?,
        providerName: String,
        modelName: String
    )
    case snapshotPrepared(
        documentFingerprint: String,
        pageCount: Int,
        nativeTextCharacters: Int
    )
    case workflowPrepared(
        promptVersion: String,
        instructions: String,
        input: String,
        toolSchemaVersions: [String: String]
    )
    case workflow(AIWorkflowEvent)
    case draftCompleted(
        revision: Int,
        title: String?,
        stagedCount: Int,
        providerTurns: Int,
        toolCalls: Int,
        readCharacters: Int,
        inputTokens: Int?
    )
    case anchorsResolved(count: Int)
    case commitCompleted(appliedCount: Int, skippedDuplicates: Int)
    case cancelled
    case failed(code: String, message: String)
}

actor AIHighlightTraceRecorder {
    static let shared = AIHighlightTraceRecorder()

    static let detailedContentDefaultsKey = "PDFWorkBench.AIHighlightDetailedTrace"

    private let fileManager: FileManager
    private let fileURL: URL?
    private let maximumFileBytes: Int
    private let defaults: UserDefaults
    private var nextSequenceByWorkflowID: [UUID: Int] = [:]

    init(
        fileManager: FileManager = .default,
        fileURL: URL? = nil,
        maximumFileBytes: Int = 20 * 1_024 * 1_024,
        defaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.maximumFileBytes = maximumFileBytes
        self.defaults = defaults

        if let fileURL {
            self.fileURL = fileURL
        } else if let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            self.fileURL = applicationSupportURL
                .appendingPathComponent("PDFWorkBench", isDirectory: true)
                .appendingPathComponent("Diagnostics", isDirectory: true)
                .appendingPathComponent("AIHighlight", isDirectory: true)
                .appendingPathComponent("trace-v1.jsonl")
        } else {
            self.fileURL = nil
        }
    }

    func record(
        workflowID: UUID,
        groupID: UUID,
        event: AIHighlightTraceEvent
    ) {
        guard let fileURL else { return }
        do {
            try prepareFile(at: fileURL)
            try rotateIfNeeded(fileURL)

            let sequence = nextSequenceByWorkflowID[workflowID, default: 0]
            nextSequenceByWorkflowID[workflowID] = sequence + 1
            let detailedContent = Self.detailedContentEnabled(in: defaults)
            let record: [String: Any] = [
                "schema_version": 1,
                "recorded_at": Self.timestampFormatter.string(from: Date()),
                "workflow_id": workflowID.uuidString,
                "group_id": groupID.uuidString,
                "sequence": sequence,
                "event": eventJSONObject(event, detailedContent: detailedContent)
            ]
            var data = try JSONSerialization.data(
                withJSONObject: record,
                options: [.sortedKeys]
            )
            data.append(0x0A)

            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            assertionFailure("Failed to append AI highlight trace: \(error)")
        }
    }

    func traceFileURL() -> URL? {
        fileURL
    }

    private func prepareFile(at fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func rotateIfNeeded(_ fileURL: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size >= maximumFileBytes else { return }

        let archivedURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("previous.jsonl")
        if fileManager.fileExists(atPath: archivedURL.path) {
            try fileManager.removeItem(at: archivedURL)
        }
        try fileManager.moveItem(at: fileURL, to: archivedURL)
        fileManager.createFile(
            atPath: fileURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
    }

    private func eventJSONObject(
        _ event: AIHighlightTraceEvent,
        detailedContent: Bool
    ) -> [String: Any] {
        switch event {
        case .jobStarted(let requestKind, let question, let providerName, let modelName):
            return compact([
                "kind": "job_started",
                "request_kind": requestKind.rawValue,
                "question": detailedContent ? question : nil,
                "question_characters": question?.count,
                "provider": providerName,
                "model": modelName
            ])
        case .snapshotPrepared(let fingerprint, let pageCount, let characterCount):
            return [
                "kind": "snapshot_prepared",
                "document_fingerprint": fingerprint,
                "page_count": pageCount,
                "native_text_characters": characterCount
            ]
        case .workflowPrepared(let promptVersion, let instructions, let input, let versions):
            return [
                "kind": "workflow_prepared",
                "prompt_version": promptVersion,
                "instructions": detailedContent ? instructions : "<redacted>",
                "input": detailedContent ? input : "<redacted>",
                "tool_schema_versions": versions
            ]
        case .workflow(let workflowEvent):
            return workflowEventJSONObject(
                workflowEvent,
                detailedContent: detailedContent
            )
        case .draftCompleted(
            let revision,
            let title,
            let stagedCount,
            let providerTurns,
            let toolCalls,
            let readCharacters,
            let inputTokens
        ):
            return compact([
                "kind": "draft_completed",
                "revision": revision,
                "title": title,
                "staged_count": stagedCount,
                "provider_turns": providerTurns,
                "tool_calls": toolCalls,
                "read_characters": readCharacters,
                "input_tokens": inputTokens
            ])
        case .anchorsResolved(let count):
            return ["kind": "anchors_resolved", "count": count]
        case .commitCompleted(let appliedCount, let skippedDuplicates):
            return [
                "kind": "commit_completed",
                "applied_count": appliedCount,
                "skipped_duplicates": skippedDuplicates
            ]
        case .cancelled:
            return ["kind": "cancelled"]
        case .failed(let code, let message):
            return [
                "kind": "failed",
                "code": code,
                "message": detailedContent ? message : "<redacted>"
            ]
        }
    }

    private func workflowEventJSONObject(
        _ event: AIWorkflowEvent,
        detailedContent: Bool
    ) -> [String: Any] {
        switch event {
        case .started(let workflowID):
            return ["kind": "workflow_started", "reported_workflow_id": workflowID.uuidString]
        case .phaseChanged(let phase):
            return ["kind": "phase_changed", "phase": String(describing: phase)]
        case .providerTurnStarted(let index):
            return ["kind": "provider_turn_started", "index": index]
        case .providerTurnFinished(
            let index,
            let responseID,
            let inputTokens,
            let toolCallCount,
            let hasStructuredFinalResult
        ):
            return compact([
                "kind": "provider_turn_finished",
                "index": index,
                "response_id": responseID,
                "input_tokens": inputTokens,
                "tool_call_count": toolCallCount,
                "has_structured_final_result": hasStructuredFinalResult
            ])
        case .toolStarted(let callID, let name, let arguments):
            return compact([
                "kind": "tool_started",
                "call_id": callID,
                "name": name,
                "arguments": jsonPayload(
                    arguments,
                    detailedContent: detailedContent
                )
            ])
        case .toolFinished(let callID, let name, let output, let readCharacters):
            return compact([
                "kind": "tool_finished",
                "call_id": callID,
                "name": name,
                "output": jsonPayload(output, detailedContent: detailedContent),
                "output_bytes": output.count,
                "read_characters": readCharacters
            ])
        case .retryScheduled(let attempt):
            return ["kind": "retry_scheduled", "attempt": attempt]
        case .budgetExceeded(let metric):
            return ["kind": "budget_exceeded", "metric": String(describing: metric)]
        case .completed:
            return ["kind": "workflow_completed"]
        case .cancelled:
            return ["kind": "workflow_cancelled"]
        case .failed(let code):
            return ["kind": "workflow_failed", "code": code]
        }
    }

    private func jsonPayload(
        _ data: Data,
        detailedContent: Bool
    ) -> Any? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return detailedContent
                ? String(data: data, encoding: .utf8)
                : "<unparseable payload>"
        }
        return detailedContent ? object : redactContent(in: object)
    }

    private func redactContent(in value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, pair in
                let key = pair.key
                if Self.contentKeys.contains(key.lowercased()) {
                    result[key] = "<redacted>"
                } else {
                    result[key] = redactContent(in: pair.value)
                }
            }
        }
        if let array = value as? [Any] {
            return array.map(redactContent(in:))
        }
        return value
    }

    private func compact(_ dictionary: [String: Any?]) -> [String: Any] {
        dictionary.reduce(into: [:]) { result, pair in
            if let value = pair.value {
                result[pair.key] = value
            }
        }
    }

    private static let contentKeys: Set<String> = [
        "text",
        "note",
        "query",
        "contents",
        "result_markdown",
        "instructions",
        "input"
    ]

    private static func detailedContentEnabled(in defaults: UserDefaults) -> Bool {
#if DEBUG
        defaults.bool(forKey: detailedContentDefaultsKey)
#else
        false
#endif
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

actor AIHighlightJSONLWorkflowTraceSink: AIWorkflowTraceSink {
    private let recorder: AIHighlightTraceRecorder
    private var activeWorkflowID: UUID?

    init(recorder: AIHighlightTraceRecorder = .shared) {
        self.recorder = recorder
    }

    func record(_ event: AIWorkflowEvent) async {
        if case .started(let workflowID) = event {
            activeWorkflowID = workflowID
        }
        guard let activeWorkflowID else { return }
        await recorder.record(
            workflowID: activeWorkflowID,
            groupID: activeWorkflowID,
            event: .workflow(event)
        )
    }
}
