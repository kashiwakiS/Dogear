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
        toolSchemaVersions: [String: String],
        retrievalMode: String = "scheme1",
        embeddingPackage: String? = nil,
        lexicalBackend: AILexicalIndexBackendKind? = .memory,
        verifiesAnswerEvidence: Bool = false
    )
    case workflow(AIWorkflowEvent)
    case retrievalIndex(mode: String, package: String?, phase: String, chunks: Int, cacheHit: Bool, seconds: Double)
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
    case answerCompleted(status: AIAnswerCompletionStatus, evidenceCount: Int, highlightCount: Int, revision: Int)
    case commitCompleted(appliedCount: Int, skippedDuplicates: Int)
    /// The Research request owns a wider lifecycle than optional PDF writes.
    case requestFinished(status: String, cause: String, saved: Bool, cancellationRequested: Bool)
    case cancelled
    case failed(code: String, message: String)
}

actor AIHighlightTraceRecorder {
    static let shared = AIHighlightTraceRecorder()

    static let detailedContentDefaultsKey = "PDFWorkBench.AIHighlightDetailedTrace"
    static let debugDirectoryBookmarkKey = "PDFWorkBench.DebugTraceDirectoryBookmark"

    private let fileManager: FileManager
    private var fileURL: URL?
    private var scopedDirectory: URL?
    private var activeWorkflows: Set<UUID> = []
    private(set) var lastError: String?
    private let maximumFileBytes: Int
    private let defaults: UserDefaults
    private var nextSequenceByWorkflowID: [UUID: Int] = [:]
    private var finishedResearchRequests: Set<UUID> = []
    private var finishedResearchOrder: [UUID] = []

    var hasActiveWorkflows: Bool { !activeWorkflows.isEmpty }
    var activeWorkflowCount: Int { activeWorkflows.count }
    var trackedSequenceCount: Int { nextSequenceByWorkflowID.count }

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
#if DEBUG
        if fileURL == nil, let bookmark = defaults.data(forKey: Self.debugDirectoryBookmarkKey) {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                  bookmarkDataIsStale: &stale)
                guard !stale, url.startAccessingSecurityScopedResource() else {
                    throw CocoaError(.fileReadNoPermission)
                }
                scopedDirectory = url
                self.fileURL = Self.debugFileURL(in: url)
            } catch {
                lastError = "Debug log folder is unavailable. Using Application Support; choose the folder again."
            }
        }
#endif
    }

    deinit { scopedDirectory?.stopAccessingSecurityScopedResource() }

    nonisolated static func debugFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("DogearDiagnostics", isDirectory: true)
            .appendingPathComponent("trace-v1.jsonl")
    }

#if DEBUG
    func chooseDebugDirectory(_ directory: URL) throws {
        guard activeWorkflows.isEmpty else { throw CocoaError(.fileWriteFileExists) }
        let accessed = directory.startAccessingSecurityScopedResource()
        do {
            let bookmark = try directory.bookmarkData(options: [.withSecurityScope],
                includingResourceValuesForKeys: nil, relativeTo: nil)
            let destination = Self.debugFileURL(in: directory)
            try prepareFile(at: destination)
            scopedDirectory?.stopAccessingSecurityScopedResource()
            scopedDirectory = accessed ? directory : nil
            fileURL = destination
            defaults.set(bookmark, forKey: Self.debugDirectoryBookmarkKey)
            lastError = nil
        } catch {
            if accessed { directory.stopAccessingSecurityScopedResource() }
            throw error
        }
    }
#endif

    func record(
        workflowID: UUID,
        groupID: UUID,
        event: AIHighlightTraceEvent
    ) {
        // Cancellation can finish the owning request before a cooperative tool
        // unwinds. Late nested events must not reopen its sequence or lifecycle.
        guard !finishedResearchRequests.contains(workflowID) else { return }
        if case .jobStarted = event { activeWorkflows.insert(workflowID) }
        let isTerminal: Bool
        switch event {
        case .commitCompleted, .failed, .cancelled, .requestFinished:
            activeWorkflows.remove(workflowID)
            isTerminal = true
        default: isTerminal = false
        }
        defer {
            if isTerminal { nextSequenceByWorkflowID.removeValue(forKey: workflowID) }
        }
        if case .requestFinished = event {
            finishedResearchRequests.insert(workflowID)
            finishedResearchOrder.append(workflowID)
            // Retain only recent tombstones; normal requests have fresh UUIDs.
            if finishedResearchOrder.count > 512 {
                finishedResearchRequests.remove(finishedResearchOrder.removeFirst())
            }
        }
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
            // Diagnostics must never crash a successful or cancelled workflow.
            lastError = "Could not write workflow log: \(error.localizedDescription)"
        }
    }

    func traceFileURL() -> URL? {
        fileURL
    }

    private func prepareFile(at fileURL: URL) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        for url in [directoryURL, fileURL] {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }
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
                "model": modelName,
                "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ])
        case .snapshotPrepared(let fingerprint, let pageCount, let characterCount):
            return [
                "kind": "snapshot_prepared",
                "document_fingerprint": fingerprint,
                "page_count": pageCount,
                "native_text_characters": characterCount
            ]
        case .workflowPrepared(let promptVersion, let instructions, let input, let versions, let retrievalMode, let embeddingPackage, let lexicalBackend, let verifiesAnswerEvidence):
            let bm25Identity = AIBM25Parameters.configurationIdentity
            let bm25Hash = AIRetrievalHash.data(Data(bm25Identity.utf8))
            let fusion = AIRetrievalFusionConfiguration.frozen
            let usesLexicalRetrieval = lexicalBackend != nil
            let usesDenseRetrieval = embeddingPackage != nil
            let retrievalComponents: String
            switch (usesDenseRetrieval, usesLexicalRetrieval) {
            case (false, true): retrievalComponents = "bm25"
            case (true, false): retrievalComponents = "bge-small-en-dense+weighted-rrf"
            case (true, true): retrievalComponents = "bge-small-en-dense+bm25+weighted-rrf"
            case (false, false): retrievalComponents = "none"
            }
            return compact([
                "kind": "workflow_prepared",
                "retrieval_mode": retrievalMode,
                "answer_evidence_review": verifiesAnswerEvidence,
                "embedding_package": embeddingPackage ?? "none",
                "retrieval_components": retrievalComponents,
                "retrieval_window_profile": usesDenseRetrieval || usesLexicalRetrieval
                    ? AIRetrievalWindow.profile
                    : nil,
                "lexical_backend": lexicalBackend?.rawValue ?? "none",
                "bm25_configuration_identity": usesLexicalRetrieval ? bm25Identity : nil,
                "bm25_configuration_sha256": usesLexicalRetrieval ? bm25Hash : nil,
                "bm25_tokenizer_version": usesLexicalRetrieval ? AILexicalTokenizer.currentVersion : nil,
                "bm25_index_schema_version": usesLexicalRetrieval ? AIBM25IndexData.currentSchemaVersion : nil,
                "weighted_rrf_configuration_identity": embeddingPackage == nil
                    ? nil
                    : fusion.canonicalIdentity,
                "weighted_rrf_configuration_sha256": embeddingPackage == nil
                    ? nil
                    : fusion.canonicalHash,
                "prompt_version": promptVersion,
                "instructions": detailedContent ? instructions : "<redacted>",
                "input": detailedContent ? input : "<redacted>",
                "tool_schema_versions": versions
            ])
        case .workflow(let workflowEvent):
            return workflowEventJSONObject(
                workflowEvent,
                detailedContent: detailedContent
            )
        case .retrievalIndex(let mode, let package, let phase, let chunks, let cacheHit, let seconds):
            return ["kind": "retrieval_index", "retrieval_mode": mode,
                    "embedding_package": package ?? "none", "phase": phase,
                    "chunks": chunks, "cache_hit": cacheHit, "seconds": seconds]
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
                "title": detailedContent ? title : title.map { _ in "<redacted>" },
                "staged_count": stagedCount,
                "provider_turns": providerTurns,
                "tool_calls": toolCalls,
                "read_characters": readCharacters,
                "input_tokens": inputTokens
            ])
        case .anchorsResolved(let count):
            return ["kind": "anchors_resolved", "count": count]
        case .answerCompleted(let status, let evidenceCount, let highlightCount, let revision):
            return [
                "kind": "answer_completed",
                "completion_status": status.rawValue,
                "answer_evidence_count": evidenceCount,
                "highlight_count": highlightCount,
                "draft_revision": revision
            ]
        case .commitCompleted(let appliedCount, let skippedDuplicates):
            return [
                "kind": "commit_completed",
                "applied_count": appliedCount,
                "skipped_duplicates": skippedDuplicates
            ]
        case .requestFinished(let status, let cause, let saved, let cancellationRequested):
            return ["kind": "request_finished", "status": status,
                    "termination_cause": cause, "saved": saved,
                    "cancellation_requested": cancellationRequested]
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
        case .noProgress:
            return ["kind": "no_progress"]
        case .evidenceReviewStarted:
            return ["kind": "evidence_review_started"]
        case .completed:
            return ["kind": "workflow_completed"]
        case .continuationDisposed:
            return ["kind": "continuation_disposed", "local_transcript_retained": false]
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
        return detailedContent ? object : projectPayload(object)
    }

    /// Explicitly project diagnostic metadata, rather than attempting to name
    /// every possible content field. New tool fields default to private.
    private func projectPayload(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, pair in
                let key = pair.key
                if Self.privatePayloadKeys.contains(key) {
                    result[key] = "<redacted>"
                } else if Self.containerPayloadKeys.contains(key) {
                    result[key] = projectPayload(pair.value)
                } else if Self.numericPayloadKeys.contains(key), pair.value is NSNumber {
                    result[key] = pair.value
                } else if Self.identifierPayloadKeys.contains(key) {
                    result[key] = projectIdentifiers(pair.value)
                } else if let allowed = Self.enumPayloadValues[key],
                          let string = pair.value as? String, allowed.contains(string) {
                    result[key] = string
                } else {
                    // Do not echo an unknown key: untrusted JSON can put
                    // passages in keys as well as in values.
                    result["_redacted_fields"] = (result["_redacted_fields"] as? Int ?? 0) + 1
                }
            }
        }
        if let array = value as? [Any] {
            return array.map(projectPayload)
        }
        return value is NSNull ? NSNull() : "<redacted>"
    }

    private func projectIdentifiers(_ value: Any) -> Any {
        if let array = value as? [Any] { return array.map(projectIdentifiers) }
        guard let string = value as? String else { return value is NSNull ? NSNull() : "<redacted>" }
        let isSegmentID = string.range(of: #"^D[0-9]{3,}(\.P[0-9]{3,})?(\.B[0-9]{3,})?(\.S[0-9]{3,})?$"#,
                                       options: .regularExpression) != nil
        return UUID(uuidString: string) != nil || isSegmentID ? string : "<redacted>"
    }

    private func compact(_ dictionary: [String: Any?]) -> [String: Any] {
        dictionary.reduce(into: [:]) { result, pair in
            if let value = pair.value {
                result[pair.key] = value
            }
        }
    }

    private static let privatePayloadKeys: Set<String> = [
        "text", "note", "query", "contents", "result_markdown", "instructions", "input",
        "claim", "reason", "review_issues", "candidate_answer", "annotation_notes",
        "selectedText", "selectedAnnotationText", "body", "title", "name", "displayName",
        "display_name", "message", "error", "explanation", "excerpt"
    ]
    private static let containerPayloadKeys: Set<String> = [
        "workspace", "allowed_sources", "selected_note", "items", "matches", "segments",
        "pages", "blocks", "sentences", "results", "publication", "draft", "highlights",
        "highlightGroups", "claims", "coverage", "sources"
    ]
    private static let numericPayloadKeys: Set<String> = [
        "ok", "accepted", "terminate", "navigation_available", "body_complete", "visible",
        "wide_ai", "wideAI", "zoom_percent", "zoomPercent", "pageIndex", "page_number",
        "referencePageIndex", "pageOffsetX", "pageOffsetY", "selectionWasClipped", "highlightGroupsWereClipped",
        "revision", "draft_revision", "final_draft_revision", "page_count", "count", "total", "limit",
        "offset", "context_before", "context_after", "read_characters", "input_tokens", "score",
        "character_count", "returned_count", "staged_count", "highlight_count", "evidence_count"
    ]
    private static let identifierPayloadKeys: Set<String> = [
        "id", "ids", "file_id", "group_id", "note_id", "mainFileID", "referenceFileID",
        "visibleGroupIDs", "segment_id", "segment_ids", "evidence_segment_ids", "evidence_image_ids", "evidence_ids"
    ]
    private static let enumPayloadValues: [String: Set<String>] = [
        "completion_status": ["answered", "not_found", "notFound", "needs_clarification"],
        "status": ["supported", "unsupported", "contradicted", "insufficient", "accepted", "rejected"],
        "content_role": ["untrusted_source", "untrusted_discussion_background", "discussion_background"],
        "zoom": ["fit", "percent", "unchanged"], "zoomMode": ["fit", "custom"]
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

    init(recorder: AIHighlightTraceRecorder = .shared) {
        self.recorder = recorder
    }

    func record(_ event: AIWorkflowEvent, workflowID: UUID?) async {
        guard let workflowID else { return }
        await recorder.record(
            workflowID: workflowID,
            groupID: workflowID,
            event: .workflow(event)
        )
    }
}
