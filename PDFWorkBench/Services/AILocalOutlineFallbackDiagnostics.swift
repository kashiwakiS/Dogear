import Foundation
import PDFKit

@MainActor
enum AILocalOutlineFallbackDiagnostics {
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
        let snapshot = AIHighlightTextSnapshot(
            fingerprint: "local-outline-fixture",
            pages: [
                AITextPageSnapshot(pageNumber: 1, text: "First page.", fingerprint: "p1"),
                AITextPageSnapshot(pageNumber: 2, text: "", fingerprint: "p2")
            ]
        )
        do {
            let empty = try AILocalOutlineFallback.answer(
                documentName: "Network.pdf", snapshot: snapshot, entries: []
            )
            check(
                empty.title == L10n.string("Local structural outline")
                    && empty.resultMarkdown.contains(L10n.string(
                        "Generated on this device from PDF bookmarks or detected headings. This is not an AI summary; no document content was sent to a provider."
                    )),
                "The local fallback is not clearly distinguished from an AI summary."
            )
            check(
                empty.resultMarkdown.contains(L10n.string("Pages: \(2)"))
                    && empty.resultMarkdown.contains(L10n.string("Selectable-text pages: \(1)"))
                    && empty.resultMarkdown.contains(L10n.string("Native-text characters: \(11)")),
                "Local fallback page/text counts are not derived from the snapshot."
            )
            check(
                empty.evidenceSegmentIDs.isEmpty && empty.finalDraftRevision == 0 && empty.terminate,
                "Local fallback claimed model evidence or a staged highlight draft."
            )
            let entries = [
                entry(title: "Overview", page: 1, level: 0),
                entry(title: "Model [design]", page: 2, level: 1),
                entry(title: "Invalid page", page: 3, level: 0)
            ]
            let outlined = try AILocalOutlineFallback.answer(
                documentName: "Network.pdf", snapshot: snapshot, entries: entries
            )
            check(
                outlined.resultMarkdown.contains("- Overview [p. 1]")
                    && outlined.resultMarkdown.contains("  - Model \\[design\\] [p. 2]")
                    && !outlined.resultMarkdown.contains("Invalid page"),
                "Local outline order, hierarchy, literal titles, or page bounds changed."
            )
            let cancelled = Task { @MainActor in
                try AILocalOutlineFallback.answer(
                    documentName: "Cancelled", snapshot: snapshot, entries: entries
                )
            }
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                check(false, "Cancelled local outline generation returned an answer.")
            } catch is CancellationError {
                check(true, "")
            }

            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DogearLocalOutlineDiagnostics-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: temporaryDirectory, withIntermediateDirectories: false
            )
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
            let defaultsName = "DogearLocalOutlineDiagnostics.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: defaultsName) else {
                throw CocoaError(.fileReadUnknown)
            }
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let secrets = UnusedSecretStore()
            let configuration = AIConfigurationStore(
                configurationURL: temporaryDirectory.appendingPathComponent("config.json"),
                legacyUserDefaults: defaults, secretStore: secrets
            )
            let trace = AIHighlightTraceRecorder(
                fileURL: temporaryDirectory.appendingPathComponent("trace.jsonl"),
                defaults: defaults
            )
            var zeroDurationBudget = AIWorkflowBudget.highlightDefault
            zeroDurationBudget.maximumDuration = .zero
            let generation = AIHighlightGenerationStore(
                configurationStore: configuration,
                workflowService: AIHighlightWorkflowService(), traceRecorder: trace,
                budget: zeroDurationBudget
            )
            let store = PDFDocumentStore(
                feedbackCenter: OperationFeedbackCenter(userDefaults: defaults)
            )
            let document = PDFDocument()
            document.insert(PDFPage(), at: 0)
            document.insert(PDFPage(), at: 1)
            store.document = document
            check(!generation.canGenerate, "No-provider fixture unexpectedly has a provider.")
            generation.generateOverview(from: store)
            check(generation.isRunning && generation.isLocalOutline, "Empty Ask did not start a local outline.")
            await waitForCompletion(generation)
            check(
                !generation.isRunning && generation.currentAnswer != nil && generation.errorMessage == nil,
                "No-provider overview did not complete with no native text and a zero cloud time budget."
            )
            check(
                generation.providerTurnNumber == 0 && generation.toolCallCount == 0
                    && generation.inputTokenCount == nil && secrets.accessCount == 0,
                "Local outline used provider workflow or secret-store access."
            )
            check(
                document.page(at: 0)?.annotations.isEmpty == true
                    && document.page(at: 1)?.annotations.isEmpty == true,
                "Local outline mutated the PDF annotations."
            )
            generation.questionText = "What network was designed?"
            generation.generateForQuestion(from: store)
            check(
                !generation.isRunning
                    && generation.errorMessage == L10n.string(
                        "Configure and enable a cloud AI provider in Settings first."
                    ),
                "No-provider question did not explain the required provider configuration."
            )

            generation.generateOverview(from: store)
            generation.cancel()
            await Task.yield()
            check(
                !generation.isRunning && generation.currentAnswer == nil
                    && generation.errorMessage == L10n.string("Local outline canceled. No changes were made."),
                "Cancelled local overview published an answer or misleading cancellation text."
            )

            generation.generateOverview(from: store)
            let replacement = PDFDocument()
            replacement.insert(PDFPage(), at: 0)
            store.document = replacement
            await waitForCompletion(generation)
            check(
                !generation.isRunning && generation.currentAnswer == nil && generation.errorMessage != nil,
                "Local overview published against a replaced active document."
            )
            check(secrets.accessCount == 0, "A local fallback error path accessed provider credentials.")

            // A persisted keychain-presence flag makes the cloud path ready,
            // but credential resolution remains observable in our fake store.
            // The non-HTTP URL independently prevents URLSession creation if a
            // future regression accidentally reaches provider construction.
            let cloudURL = temporaryDirectory.appendingPathComponent("cloud-config.json")
            let cloudProvider = AIProviderConfiguration(
                id: UUID(), name: "Deadline fixture",
                baseURL: "diagnostic-no-network://invalid", model: "fixture-only",
                isCloudAIEnabled: true, hasCloudConsent: true, secretStorageMode: .keychain
            )
            let encodedProvider = try JSONEncoder().encode(cloudProvider)
            let cloudJSON: [String: Any] = [
                "provider": try JSONSerialization.jsonObject(with: encodedProvider),
                "apiKey": "", "hasStoredKeychainAPIKey": true
            ]
            try JSONSerialization.data(withJSONObject: cloudJSON).write(to: cloudURL, options: .atomic)
            let cloudSecrets = UnusedSecretStore(secret: "fake-diagnostic-key-never-sent")
            let cloudConfiguration = AIConfigurationStore(
                configurationURL: cloudURL, legacyUserDefaults: defaults, secretStore: cloudSecrets
            )
            let cloudTraceURL = temporaryDirectory.appendingPathComponent("deadline-trace.jsonl")
            let cloudTrace = AIHighlightTraceRecorder(fileURL: cloudTraceURL, defaults: defaults)
            let deadlineGeneration = AIHighlightGenerationStore(
                configurationStore: cloudConfiguration,
                workflowService: AIHighlightWorkflowService(), traceRecorder: cloudTrace,
                budget: zeroDurationBudget
            )
            check(
                deadlineGeneration.canGenerate && cloudSecrets.accessCount == 0,
                "The zero-deadline fixture did not enter a ready cloud configuration without reading a secret."
            )
            deadlineGeneration.generateOverview(from: store)
            check(
                deadlineGeneration.isRunning && !deadlineGeneration.isLocalOutline,
                "The zero-deadline fixture incorrectly selected the local fallback."
            )
            await waitForCompletion(deadlineGeneration)
            let elapsedBudgetError = AIWorkflowFoundationError.budgetExceeded(.elapsedTime)
            check(
                !deadlineGeneration.isRunning
                    && deadlineGeneration.errorMessage == AIHighlightFailureMessage.userMessage(for: elapsedBudgetError),
                "A zero cloud deadline did not report the internal elapsed-time budget."
            )
            check(
                deadlineGeneration.providerTurnNumber == 0 && deadlineGeneration.toolCallCount == 0
                    && deadlineGeneration.inputTokenCount == nil && cloudSecrets.accessCount == 0,
                "The expired cloud deadline reached provider setup, a tool, or credential resolution."
            )
            check(
                deadlineGeneration.currentAnswer == nil && deadlineGeneration.lastReport == nil
                    && replacement.page(at: 0)?.annotations.isEmpty == true,
                "An expired cloud request published an answer or modified annotations."
            )
            let deadlineEvents = await waitForTerminalEvents(at: cloudTraceURL)
            check(
                deadlineEvents.contains {
                    $0["kind"] as? String == "failed"
                        && $0["code"] as? String == AIHighlightFailureMessage.code(for: elapsedBudgetError)
                },
                "The zero deadline trace did not identify the internal elapsed-time failure."
            )
            check(
                !deadlineEvents.contains {
                    ["snapshot_prepared", "provider_turn_started", "tool_started"].contains($0["kind"] as? String ?? "")
                },
                "The zero deadline performed preparation/provider work before stopping."
            )

            let cancelTraceURL = temporaryDirectory.appendingPathComponent("cancel-trace.jsonl")
            let cancellationGeneration = AIHighlightGenerationStore(
                configurationStore: cloudConfiguration,
                workflowService: AIHighlightWorkflowService(),
                traceRecorder: AIHighlightTraceRecorder(fileURL: cancelTraceURL, defaults: defaults)
            )
            cancellationGeneration.generateOverview(from: store)
            cancellationGeneration.cancel()
            let cancellationEvents = await waitForTerminalEvents(at: cancelTraceURL)
            check(
                !cancellationGeneration.isRunning
                    && cancellationGeneration.errorMessage == L10n.string(
                        "AI request canceled. No new annotations were applied."
                    )
                    && cancellationGeneration.errorMessage != deadlineGeneration.errorMessage,
                "Explicit user cancellation was misreported as a deadline expiry."
            )
            check(
                cancellationEvents.contains { $0["kind"] as? String == "cancelled" }
                    && !cancellationEvents.contains { $0["kind"] as? String == "failed" },
                "Explicit user cancellation did not retain its separate terminal trace state."
            )
            check(
                cancellationGeneration.currentAnswer == nil
                    && cancellationGeneration.providerTurnNumber == 0
                    && replacement.page(at: 0)?.annotations.isEmpty == true
                    && cloudSecrets.accessCount == 0,
                "Cancelled cloud preparation returned output, changed annotations, or accessed a provider."
            )
        } catch {
            check(false, "Local outline diagnostics failed: \(error.localizedDescription)")
        }
        return Report(checks: checks, failures: failures)
    }

    private static func entry(title: String, page: Int, level: Int) -> DocumentOutlineEntry {
        DocumentOutlineEntry(
            id: title, title: title, level: level,
            target: PDFNavigationTarget(pageIndex: page - 1, point: nil, relativePagePosition: nil),
            source: .pdfBookmark
        )
    }

    private static func waitForCompletion(_ store: AIHighlightGenerationStore) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func waitForTerminalEvents(at url: URL) async -> [[String: Any]] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: url),
               let contents = String(data: data, encoding: .utf8) {
                let events = contents.split(separator: "\n").compactMap { line -> [String: Any]? in
                    guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                        as? [String: Any] else { return nil }
                    return record["event"] as? [String: Any]
                }
                if events.contains(where: {
                    ["failed", "cancelled"].contains($0["kind"] as? String ?? "")
                }) { return events }
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return []
    }

    private final class UnusedSecretStore: AISecretStoring {
        var accessCount = 0
        private let secret: String?
        init(secret: String? = nil) { self.secret = secret }
        func readSecret(profileID: UUID) throws -> String? { accessCount += 1; return secret }
        func saveSecret(_ secret: String, profileID: UUID, configurationName: String) throws {
            accessCount += 1
        }
        func removeSecret(profileID: UUID) throws { accessCount += 1 }
        func updateLabel(profileID: UUID, configurationName: String) throws { accessCount += 1 }
    }
}
