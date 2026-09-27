import CryptoKit
import Foundation
import PDFKit

/// Explicit, paid, public-fixture acceptance only. Never called by the offline
/// diagnostic suite or ordinary app launch. The actual ResearchRuntime owns
/// source preparation, provider resolution, tools, review and persistence.
@MainActor
enum ResearchLiveAcceptance {
    private static let manifestSHA256 = "fd8c9fa749e2360b91a96c015bfd42b43b99fbe1877d2812dd8696d373b0e017"
    private static let supportedCases: Set<String> = ["RA-01", "RA-02", "RA-03", "RA-04", "RA-05", "RA-06", "RA-07", "RA-09"]

    /// Invoke before constructing PDFWorkBenchApp or its persisted Library.
    /// 0 = execution collected (human grading still required), 1 = failed,
    /// 2 = blocked/preflight rejected. No automatic retry of a failed case.
    static func run(arguments: [String]) async -> Int32 {
        var stage = "arguments"
        do {
            let options = try Options(arguments: arguments)
            stage = options.stdinFixtures ? "read_public_fixture_stdin" : "read_manifest"
            let payload = options.stdinFixtures ? try readFixturePayload() : nil
            let manifestData: Data
            if let payload {
                guard let bytes = Data(base64Encoded: payload.manifest_base64) else { throw Preflight.invalidManifest }
                manifestData = bytes
            } else { manifestData = try Data(contentsOf: options.manifest) }
            stage = "verify_manifest"
            guard digest(manifestData) == manifestSHA256 else { throw Preflight.invalidManifest }
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
            guard manifest.schema_version == 1,
                  manifest.suite_id == "dogear-research-acceptance-v1" else { throw Preflight.invalidManifest }
            let sources = manifest.sources.filter { $0.kind == "pdf" }
            if let payload, Set(payload.pdfs.keys) != Set(sources.map(\.id)) { throw Preflight.invalidFixture }
            let verified = try sources.map { source -> (Source, Data) in
                stage = "verify_pdf_\(source.id)"
                if let payload {
                    guard let encoded = payload.pdfs[source.id], let bytes = Data(base64Encoded: encoded) else {
                        throw Preflight.invalidFixture
                    }
                    return (source, try verifiedPDF(bytes, source: source))
                }
                let url = options.fixtureRoot.appendingPathComponent("source").appendingPathComponent(source.filename!)
                return (source, try verifiedPDF(at: url, source: source))
            }
            let runID = UUID().uuidString
            let outputRoot = options.stdinFixtures
                ? FileManager.default.temporaryDirectory.appendingPathComponent("Dogear-Research-Live-Acceptance", isDirectory: true)
                : options.output
            let runRoot = outputRoot.appendingPathComponent("run-\(runID)", isDirectory: true)
            stage = "create_output"
            guard !FileManager.default.fileExists(atPath: runRoot.path) else { throw Preflight.outputExists }
            try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let sourceRoot = runRoot.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            // Only verified public bytes enter the isolated Library. No bookmark,
            // existing Library, working copy or user Group is consulted.
            for (source, bytes) in verified {
                stage = "copy_pdf_\(source.id)"
                try write(bytes, to: sourceRoot.appendingPathComponent(source.filename!))
            }
            if options.preflightOnly {
                stage = "write_preflight_result"
                let result: [String: Any] = ["execution": "preflight_only", "network_started": false,
                    "configuration_loaded": false, "manifest_sha256": manifestSHA256,
                    "source_ids": sources.map(\.id), "selected_cases": options.caseIDs]
                try write(JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
                          to: runRoot.appendingPathComponent("preflight.json"))
                print("Research live acceptance preflight passed: \(runRoot.path); no configuration or credentials loaded, no network request.")
                return 0
            }
            stage = "initialize_isolated_storage"
            let domain = "Dogear.ResearchLiveAcceptance.\(runID)"
            guard let defaults = UserDefaults(suiteName: domain) else { throw Preflight.storageUnavailable }
            defer { defaults.removePersistentDomain(forName: domain) }
            defaults.set(false, forKey: AIHighlightTraceRecorder.detailedContentDefaultsKey)
            let library = LibraryStore(userDefaults: defaults,
                storage: try LibraryJSONStore(stateURL: runRoot.appendingPathComponent("library.json")))
            var fileIDs: [String: UUID] = [:]
            for (source, _) in verified {
                fileIDs[source.id] = library.upsertOpenedURL(sourceRoot.appendingPathComponent(source.filename!),
                                                            refreshBookmark: false).id
            }
            let storage = ResearchStore(rootURL: runRoot.appendingPathComponent("research", isDirectory: true))
            let traceURL = runRoot.appendingPathComponent("trace.jsonl")
            let trace = AIHighlightTraceRecorder(fileURL: traceURL, defaults: defaults)
            // Credentials are obtained only through the product's existing
            // store after explicit opt-in and fixture validation. Never export
            // the configuration object, endpoint, key or raw provider errors.
            stage = "load_existing_configuration"
            let configuration = AIConfigurationStore(persistsMissingCredentialStatus: false)
            let runtime = ResearchRuntime(storage: storage, configuration: configuration,
                traceRecorder: trace, commands: ResearchCommandService(store: storage),
                requestTimeout: .seconds(options.timeoutSeconds), retrievalSelection: .lexical)
            defer { runtime.shutdown() }
            var report = Report(runID: runID, executable: CommandLine.arguments.first ?? "unknown",
                model: configuration.configuration.model, cloudAvailable: runtime.cloudAvailable,
                selectedCases: options.caseIDs, sourceSHA256: Dictionary(uniqueKeysWithValues:
                    sources.map { ($0.id, $0.sha256!) }), fileIDs: fileIDs,
                manifestSHA256: manifestSHA256, promptVersion: AIHighlightWorkflowService.promptVersion)
            report.inputTransport = options.stdinFixtures ? "verified_stdin_bytes" : "paths"
            stage = "write_initial_report"
            try save(report, at: runRoot, exportToStdout: options.stdinFixtures)
            print("Research live acceptance output: \(runRoot.path)")

            for caseID in options.caseIDs {
                guard let test = manifest.cases.first(where: { $0.id == caseID }) else { throw Preflight.invalidCases }
                var sessionID: UUID?
                for (index, step) in test.steps.enumerated() {
                    stage = "case_\(caseID)_step_\(index + 1)"
                    guard let prompt = step.prompt else { continue }
                    var row = Row(caseID: caseID, step: index + 1, prompt: prompt,
                        expectedCompletionStatus: test.expected_completion_status,
                        expectedHistoryRounds: step.expected_history_rounds,
                        sourceIDs: step.source_ids ?? test.source_ids)
                    guard runtime.cloudAvailable else {
                        row.execution = "blocked"
                        row.failureCode = "configuration_unavailable"
                        report.rows.append(row)
                        try save(report, at: runRoot, exportToStdout: options.stdinFixtures)
                        continue
                    }
                    let selectedIDs = try row.sourceIDs.map { id in
                        guard let value = fileIDs[id] else { throw Preflight.invalidManifest }
                        return value
                    }
                    if sessionID == nil || step.new_session == true {
                        sessionID = storage.createSession(title: "\(caseID) public acceptance")
                    }
                    guard let currentID = sessionID, var session = storage.session(id: currentID) else {
                        throw Preflight.storageUnavailable
                    }
                    session.sourceSelection = ResearchSourceSelection(fileIDs: selectedIDs)
                    session.draft = ResearchDraft(text: prompt)
                    guard storage.updateSession(session) else { throw Preflight.storageUnavailable }
                    let previousRequestIDs = Set(session.messages.map(\.requestID))
                    row.sessionID = currentID
                    row.startedAt = Date()
                    let started = ContinuousClock.now
                    let deadline = started.advanced(by: .seconds(options.timeoutSeconds + 5))
                    var lastProgress: ResearchRequestProgress?
                    print("Research live acceptance \(caseID)/\(index + 1): started")
                    runtime.send(sessionID: currentID, library: library, mainStore: nil, viewID: UUID())
                    // No editable document is registered, and no per-session
                    // annotation preference is written to standard defaults.
                    while let progress = runtime.jobs[currentID], ContinuousClock.now < deadline {
                        lastProgress = progress
                        if row.firstInterimSeconds == nil, progress.interimAnswer != nil {
                            row.firstInterimSeconds = seconds(started.duration(to: .now))
                        }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    if runtime.jobs[currentID] != nil {
                        runtime.cancel(sessionID: currentID)
                        row.failureCode = "harness_deadline"
                    }
                    row.finishedSeconds = seconds(started.duration(to: .now))
                    row.lastPhase = lastProgress?.phase
                    row.providerTurns = lastProgress?.providerTurns
                    row.toolCalls = lastProgress?.toolCalls
                    row.inputTokens = lastProgress?.inputTokens
                    row.message = storage.session(id: currentID)?.messages.last(where: {
                        !previousRequestIDs.contains($0.requestID)
                    })
                    row.requestID = row.message?.requestID
                    // The runtime's request terminal is queued separately. Wait
                    // briefly for metadata, without extending the provider budget.
                    let traceDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                    while await trace.hasActiveWorkflows, ContinuousClock.now < traceDeadline {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    let metadata = try terminalMetadata(at: traceURL, requestID: row.requestID)
                    row.completionStatus = metadata.completion
                    row.providerTurnsStarted = metadata.providerTurnsStarted
                    row.failureCode = row.failureCode ?? metadata.failure
                    row.providerTurns = metadata.providerTurns ?? row.providerTurns
                    row.toolCalls = metadata.toolCalls ?? row.toolCalls
                    row.inputTokens = metadata.inputTokens ?? row.inputTokens
                    row.message?.errorMessage = nil
                    row.execution = row.message?.status == .accepted ? "collected" : "failed"
                    if row.execution == "failed", row.failureCode == nil {
                        row.failureCode = row.message?.status.rawValue ?? "request_not_started"
                    }
                    row.structuralIssues = structuralIssues(row, fileIDs: fileIDs)
                    if !row.structuralIssues.isEmpty { row.execution = "failed" }
                    report.rows.append(row)
                    try save(report, at: runRoot, exportToStdout: options.stdinFixtures)
                    print("Research live acceptance \(caseID)/\(index + 1): \(row.execution)")
                }
            }
            stage = "verify_final_source_bytes"
            report.sourceBytesUnchanged = try sources.allSatisfy { source in
                let original = options.fixtureRoot.appendingPathComponent("source").appendingPathComponent(source.filename!)
                let copied = sourceRoot.appendingPathComponent(source.filename!)
                let originalDigest = options.stdinFixtures ? source.sha256 : digest(try Data(contentsOf: original))
                let copiedDigest = digest(try Data(contentsOf: copied))
                return originalDigest == source.sha256 && copiedDigest == source.sha256
            }
            report.finishedAt = Date()
            stage = "write_final_report"
            try save(report, at: runRoot, exportToStdout: options.stdinFixtures)
            if report.rows.contains(where: { $0.execution == "failed" }) || report.sourceBytesUnchanged == false { return 1 }
            return report.rows.contains(where: { $0.execution == "blocked" }) ? 2 : 0
        } catch let error as Preflight {
            print("Research live acceptance blocked: stage=\(stage), code=\(error.rawValue)")
            return 2
        } catch {
            // Local I/O errors previously collapsed to "unknown". Domain and
            // numeric code identify sandbox/permission/parse failures without
            // exporting URLs, userInfo, localizedDescription or provider bodies.
            let cocoa = error as NSError
            print("Research live acceptance stopped: stage=\(stage), classification=\(AIHighlightFailureMessage.code(for: error)), domain=\(cocoa.domain), code=\(cocoa.code)")
            return 1
        }
    }

    private static func structuralIssues(_ row: Row, fileIDs: [String: UUID]) -> [String] {
        guard let message = row.message, message.status == .accepted else { return [] }
        var issues: [String] = []
        if row.completionStatus != row.expectedCompletionStatus { issues.append("completion_status_mismatch") }
        if let expected = row.expectedHistoryRounds,
           message.contextSummary?.historyMessageIDs.count != expected { issues.append("history_round_count_mismatch") }
        let allowed = Set(row.sourceIDs.compactMap { fileIDs[$0] })
        if message.evidence.contains(where: { $0.source.map { !allowed.contains($0.fileID) } ?? false }) {
            issues.append("evidence_outside_current_sources")
        }
        if message.contextSummary?.preparedFileIDs?.count != allowed.count { issues.append("source_preparation_incomplete") }
        return issues
    }

    private static func terminalMetadata(at url: URL, requestID: UUID?) throws -> TerminalMetadata {
        var result = TerminalMetadata()
        guard let requestID, FileManager.default.fileExists(atPath: url.path) else { return result }
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["workflow_id"] as? String == requestID.uuidString,
                  let event = record["event"] as? [String: Any] else { continue }
            if event["kind"] as? String == "answer_completed" { result.completion = event["completion_status"] as? String }
            if event["kind"] as? String == "provider_turn_started" { result.providerTurnsStarted += 1 }
            if event["kind"] as? String == "request_finished",
               event["status"] as? String != "accepted" { result.failure = event["termination_cause"] as? String }
            if event["kind"] as? String == "draft_completed" {
                result.providerTurns = event["provider_turns"] as? Int
                result.toolCalls = event["tool_calls"] as? Int
                result.inputTokens = event["input_tokens"] as? Int
            }
        }
        return result
    }

    private static func verifiedPDF(at url: URL, source: Source) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Preflight.invalidFixture }
        return try verifiedPDF(Data(contentsOf: url), source: source)
    }

    private static func verifiedPDF(_ data: Data, source: Source) throws -> Data {
        guard data.count == source.byte_count, digest(data) == source.sha256,
              let document = PDFDocument(data: data), document.pageCount == source.page_count else {
            throw Preflight.invalidFixture
        }
        return data
    }

    private static func readFixturePayload() throws -> FixturePayload {
        var data = Data()
        while let part = try FileHandle.standardInput.read(upToCount: 65_536), !part.isEmpty {
            guard data.count + part.count <= 4_000_000 else { throw Preflight.invalidFixture }
            data.append(part)
        }
        return try JSONDecoder().decode(FixturePayload.self, from: data)
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func save(_ report: Report, at root: URL, exportToStdout: Bool) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(report)
        try write(json, to: root.appendingPathComponent("results.json"))
        var text = "# Research live acceptance \(report.runID)\n\n"
        text += "Execution records only; semantic grading and clickable UI citations remain unverified.\n\n"
        text += "Retrieval: lexical. Detailed trace: disabled. Model label: \(report.model).\n\n"
        text += "RA-08 requires native editor/Undo acceptance. RA-10 requires an inspected F10 image and native attachment acceptance. Neither ran here.\n\n"
        for row in report.rows {
            text += "## \(row.caseID) / step \(row.step)\n\n\(row.prompt)\n\n"
            text += "Execution: \(row.execution); semantic verdict: not_run; failure: \(row.failureCode ?? "none").\n\n"
            text += "Completion: \(row.completionStatus ?? "unknown"); expected: \(row.expectedCompletionStatus).\n\n"
            text += "Structural issues: \(row.structuralIssues.isEmpty ? "none observed" : row.structuralIssues.joined(separator: ", ")).\n\n"
            if let message = row.message {
                text += (message.answer ?? "No accepted answer.") + "\n\n"
                for evidence in message.evidence {
                    let page = evidence.anchor.map { String($0.pageIndex + 1) } ?? "unknown"
                    text += "- \(evidence.source?.displayName ?? "unknown source"), physical PDF page \(page): \(evidence.excerpt)\n\n"
                }
                text += "History rounds: \(message.contextSummary.map { String($0.historyMessageIDs.count) } ?? "unknown").\n\n"
            }
        }
        text += "Verified public input/copied source bytes unchanged: \(report.sourceBytesUnchanged.map { $0 ? "true" : "false" } ?? "not checked yet"). Host source files are independently rechecked by the wrapper.\n"
        let markdown = Data(text.utf8)
        try write(markdown, to: root.appendingPathComponent("results.md"))
        if exportToStdout {
            // Only these public reports can leave the sandbox. No arbitrary
            // file reads, container paths or configuration exports.
            let envelope = try JSONSerialization.data(withJSONObject: ["run_id": report.runID,
                "files": ["results.json": json.base64EncodedString(), "results.md": markdown.base64EncodedString()]],
                options: [.sortedKeys])
            let line = "DOGEAR_ACCEPTANCE_EXPORT " + envelope.base64EncodedString() + "\n"
            try FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
        }
    }

    private enum Preflight: String, Error {
        case explicitNetworkOptInRequired = "explicit_network_opt_in_required"
        case invalidArguments = "invalid_arguments", invalidCases = "unsupported_or_duplicate_cases"
        case invalidManifest = "manifest_hash_mismatch", invalidFixture = "fixture_hash_or_pages_mismatch"
        case outputExists = "output_already_exists", storageUnavailable = "isolated_storage_unavailable"
    }
    private struct Options {
        var manifest: URL
        var fixtureRoot: URL
        var output: URL
        var caseIDs: [String]
        var timeoutSeconds: Int
        var preflightOnly: Bool
        var stdinFixtures: Bool
        init(arguments: [String]) throws {
            preflightOnly = arguments.contains("--preflight-only")
            stdinFixtures = arguments.contains("--public-fixtures-stdin")
            guard preflightOnly || arguments.contains("--allow-network") else { throw Preflight.explicitNetworkOptInRequired }
            var values: [String: String] = [:]
            let flags: Set<String> = ["--manifest", "--fixture-root", "--output", "--cases", "--timeout-seconds"]
            var index = 1
            while index < arguments.count {
                let key = arguments[index]
                if ["--run-research-acceptance", "--allow-network", "--preflight-only", "--public-fixtures-stdin"].contains(key) { index += 1; continue }
                guard flags.contains(key), values[key] == nil, index + 1 < arguments.count else { throw Preflight.invalidArguments }
                values[key] = arguments[index + 1]
                index += 2
            }
            guard let manifest = values["--manifest"], let fixtureRoot = values["--fixture-root"],
                  let output = values["--output"], let cases = values["--cases"],
                  [manifest, fixtureRoot, output].allSatisfy({ $0.hasPrefix("/") }) else { throw Preflight.invalidArguments }
            caseIDs = cases.split(separator: ",").map(String.init)
            guard !caseIDs.isEmpty, Set(caseIDs).count == caseIDs.count,
                  caseIDs.allSatisfy({ supportedCases.contains($0) }) else { throw Preflight.invalidCases }
            guard let timeout = Int(values["--timeout-seconds"] ?? "420"), (30...420).contains(timeout) else { throw Preflight.invalidArguments }
            timeoutSeconds = timeout
            self.manifest = URL(fileURLWithPath: manifest)
            self.fixtureRoot = URL(fileURLWithPath: fixtureRoot)
            self.output = URL(fileURLWithPath: output)
        }
    }
    private struct Manifest: Decodable {
        let schema_version: Int
        let suite_id: String
        let sources: [Source]
        let cases: [Case]
    }
    private struct Source: Decodable {
        let id: String
        let kind: String
        let filename: String?
        let sha256: String?
        let byte_count: Int?
        let page_count: Int?
    }
    private struct FixturePayload: Decodable {
        let manifest_base64: String
        let pdfs: [String: String]
    }
    private struct Case: Decodable {
        let id: String
        let source_ids: [String]
        let steps: [Step]
        let expected_completion_status: String
    }
    private struct Step: Decodable {
        let prompt: String?
        let source_ids: [String]?
        let new_session: Bool?
        let expected_history_rounds: Int?
    }
    private struct TerminalMetadata {
        var providerTurnsStarted = 0
        var completion: String?
        var failure: String?
        var providerTurns: Int?
        var toolCalls: Int?
        var inputTokens: Int?
    }
    private struct Report: Encodable {
        let runID: String
        let executable: String
        let model: String
        let cloudAvailable: Bool
        let selectedCases: [String]
        let sourceSHA256: [String: String]
        let fileIDs: [String: UUID]
        let manifestSHA256: String
        let promptVersion: String
        let retrieval = "scheme1Lexical"
        let semanticVerdict = "not_run"
        let manualOnlyCases = ["RA-08", "RA-10"]
        var inputTransport = "paths"
        var rows: [Row] = []
        var sourceBytesUnchanged: Bool?
        var finishedAt: Date?
    }
    private struct Row: Encodable {
        let caseID: String
        let step: Int
        let prompt: String
        let expectedCompletionStatus: String
        let expectedHistoryRounds: Int?
        let sourceIDs: [String]
        let semanticVerdict = "not_run"
        var execution = "not_run"
        var failureCode: String?
        var structuralIssues: [String] = []
        var sessionID: UUID?
        var requestID: UUID?
        var startedAt: Date?
        var firstInterimSeconds: Double?
        var finishedSeconds: Double?
        var providerTurns: Int?
        var toolCalls: Int?
        var inputTokens: Int?
        var completionStatus: String?
        var lastPhase: String?
        var providerTurnsStarted: Int?
        var message: ResearchMessage?
    }
}
