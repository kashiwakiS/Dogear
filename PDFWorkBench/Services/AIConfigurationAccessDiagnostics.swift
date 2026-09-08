import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// Uses only disposable configuration files, synthetic strings, and injected
/// readers. Creating a provider is tested; no provider method/network is called.
@MainActor
enum AIConfigurationAccessDiagnostics {
    struct Report {
        let checks: Int
        let failures: [String]
    }

    static func run() async -> Report {
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DogearCredentialDiagnostics-\(UUID().uuidString)")
        let defaultsName = "DogearCredentialDiagnostics.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            return Report(checks: 1, failures: ["Could not create isolated credential defaults."])
        }
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

            let plainReader = BlockingReader(values: ["unused-fixture"])
            defer { plainReader.releaseAll() }
            let plaintext = try makeStore(directory: directory, defaults: defaults,
                                          mode: .plaintextFile, reader: plainReader)
            let plainProbe = begin(plaintext)
            await plainProbe.task.value
            check(plainProbe.state.outcome == .created && plainReader.readCount == 0,
                  "Plaintext provider creation accessed the Keychain reader.")

            let reader = BlockingReader(values: ["late-fixture", "fresh-fixture"])
            defer { reader.releaseAll() }
            let store = try makeStore(directory: directory, defaults: defaults, reader: reader)
            let first = begin(store)
            check(await waitUntil { reader.readCount == 1 }, "Background credential read never started.")
            check(!reader.readOnMainThread, "Credential read ran on the UI thread.")
            var heartbeat = false
            let heartbeatTask = Task { @MainActor in heartbeat = true }
            await heartbeatTask.value
            check(heartbeat && first.state.outcome == nil,
                  "MainActor did not remain responsive while credential access was blocked.")
            first.task.cancel()
            first.task.cancel()
            check(await waitUntil { first.state.outcome != nil }, "Cancel waited for the system credential read to finish.")
            check(first.state.outcome == .cancelled && reader.returnCount == 0,
                  "Cancellation did not win before the blocked reader returned.")
            reader.release(0)
            check(await waitUntil { reader.returnCount == 1 }, "Canceled reader fixture did not finish after release.")
            check(first.state.outcome == .cancelled && store.isAPIKeyConfigured,
                  "A late canceled result changed the caller or configured-key state.")
            let second = begin(store)
            check(await waitUntil { reader.readCount == 2 }, "A new question reused an old in-memory key cache.")
            reader.release(1)
            await second.task.value
            check(second.state.outcome == .created, "Fresh credential resolution failed after a canceled read.")

            let queuedReader = BlockingReader(values: ["first-fixture", "must-not-read"])
            defer { queuedReader.releaseAll() }
            let queuedStore = try makeStore(directory: directory, defaults: defaults, reader: queuedReader)
            let active = begin(queuedStore)
            check(await waitUntil { queuedReader.readCount == 1 }, "Queue cancellation fixture did not begin.")
            let queued = begin(queuedStore)
            await Task.yield()
            queued.task.cancel()
            check(await waitUntil { queued.state.outcome == .cancelled }, "Queued credential cancellation did not finish promptly.")
            queuedReader.releaseAll()
            await active.task.value
            await queued.task.value
            check(queuedReader.readCount == 1 && active.state.outcome == .created,
                  "A canceled queued request entered the blocking credential reader.")

            for field in ["profile", "destination", "model", "cloud", "consent", "storage"] {
                let changingReader = BlockingReader(values: ["old-configuration-fixture"])
                defer { changingReader.releaseAll() }
                let changingStore = try makeStore(directory: directory, defaults: defaults, reader: changingReader)
                let pending = begin(changingStore)
                check(await waitUntil { changingReader.readCount == 1 }, "Configuration-change fixture did not begin.")
                switch field {
                case "profile": changingStore.configuration.id = UUID()
                case "destination": changingStore.configuration.baseURL = "https://changed.invalid/v1"
                case "model": changingStore.configuration.model = "changed-fixture"
                case "cloud": changingStore.configuration.isCloudAIEnabled = false
                case "consent": changingStore.configuration.hasCloudConsent = false
                default: changingStore.configuration.secretStorageMode = .plaintextFile
                }
                changingReader.releaseAll()
                await pending.task.value
                check(pending.state.outcome == .configurationChanged,
                      "A late key was accepted after the \(field) configuration changed.")
            }

            let staleNilReader = BlockingReader(values: [nil])
            defer { staleNilReader.releaseAll() }
            let keyStore = try makeStore(directory: directory, defaults: defaults, reader: staleNilReader)
            let oldTicket = keyStore.captureProviderRequest()
            let missingOldKey = begin(keyStore, ticket: oldTicket)
            check(await waitUntil { staleNilReader.readCount == 1 }, "Stale-key fixture did not begin.")
            try keyStore.saveAPIKey("replacement-fixture-never-sent")
            let updatedTicket = keyStore.captureProviderRequest()
            check(oldTicket.configuration == updatedTicket.configuration && oldTicket != updatedTicket,
                  "A same-configuration key change did not invalidate the request ticket.")
            staleNilReader.releaseAll()
            await missingOldKey.task.value
            check(missingOldKey.state.outcome == .configurationChanged
                  && keyStore.isAPIKeyConfigured && keyStore.hasKeychainAPIKey,
                  "An old nil result marked the replacement key as missing.")
            let beforeRead = staleNilReader.readCount
            let staleAtSend = begin(keyStore, ticket: oldTicket)
            await staleAtSend.task.value
            check(staleAtSend.state.outcome == .configurationChanged && staleNilReader.readCount == beforeRead,
                  "A key changed during PDF preparation was read/used with the old Send ticket.")

            let missingReader = BlockingReader(values: [nil])
            defer { missingReader.releaseAll() }
            let missingStore = try makeStore(directory: directory, defaults: defaults, reader: missingReader)
            missingReader.releaseAll()
            let missing = begin(missingStore)
            await missing.task.value
            check(missing.state.outcome == .missingKey && !missingStore.isAPIKeyConfigured && !missingStore.hasKeychainAPIKey,
                  "A current missing-key result did not update only its own configured state.")

            let disabledReader = BlockingReader(values: ["connection-test-fixture"])
            defer { disabledReader.releaseAll() }
            let disabledStore = try makeStore(directory: directory, defaults: defaults, reader: disabledReader)
            disabledStore.configuration.isCloudAIEnabled = false
            disabledStore.configuration.hasCloudConsent = false
            let disabled = begin(disabledStore)
            await disabled.task.value
            check(disabled.state.outcome == .cloudUnavailable && disabledReader.readCount == 0,
                  "Cloud-disabled Ask accessed credentials or created a provider.")
            disabledReader.releaseAll()
            _ = try await disabledStore.provider(for: disabledStore.captureProviderRequest())
            check(disabledReader.readCount == 1,
                  "Connection-test provider creation incorrectly required document-sharing consent.")

            let absentReaderStore = try makeStore(directory: directory, defaults: defaults, reader: nil)
            let absent = begin(absentReaderStore)
            await absent.task.value
            check(absent.state.outcome == .readerUnavailable,
                  "An injected configuration without an async reader fell back to real Security access.")

            for iteration in 0..<8 {
                let racingReader = BlockingReader(values: ["race-fixture"])
                defer { racingReader.releaseAll() }
                let racingStore = try makeStore(directory: directory, defaults: defaults, reader: racingReader)
                let racing = begin(racingStore)
                _ = await waitUntil { racingReader.readCount == 1 }
                if iteration.isMultiple(of: 2) { racingReader.releaseAll() }
                racing.task.cancel()
                racingReader.releaseAll()
                await racing.task.value
                check(racing.state.outcome == .cancelled,
                      "Credential completion/cancellation race accepted a canceled request.")
            }

            // Whole-Ask integration: a real in-memory native-text snapshot and
            // a blocked injected reader. The URL cannot construct a network
            // provider even if a cancellation regression reaches that boundary.
            let pdfStore = PDFDocumentStore(feedbackCenter: OperationFeedbackCenter(userDefaults: defaults))
            pdfStore.document = try makeTextPDF()
            let uiReader = BlockingReader(values: ["ui-fixture-never-sent"])
            defer { uiReader.releaseAll() }
            let uiStore = try makeStore(directory: directory, defaults: defaults, reader: uiReader,
                                        baseURL: "diagnostic-no-network://invalid")
            let uiTrace = AIHighlightTraceRecorder(fileURL: directory.appendingPathComponent("credential-ui-trace.jsonl"), defaults: defaults)
            let generation = AIHighlightGenerationStore(configurationStore: uiStore,
                workflowService: AIHighlightWorkflowService(), traceRecorder: uiTrace)
            generation.generateOverview(from: pdfStore)
            check(await waitUntil { uiReader.readCount == 1 }, "Ask did not reach the injected credential wait.")
            let elapsedBefore = generation.elapsedTime
            try await Task.sleep(for: .milliseconds(150))
            check(generation.isRunning && generation.progressPhase == .waitingForCredentials
                  && generation.elapsedTime > elapsedBefore && uiReader.returnCount == 0,
                  "Ask's phase/timer stopped while waiting for system credentials.")
            generation.cancel()
            check(!generation.isRunning && uiReader.returnCount == 0,
                  "Ask Cancel waited for the blocked credential reader.")
            uiReader.releaseAll()
            _ = await waitUntil { uiReader.returnCount == 1 }
            await Task.yield()
            check(generation.currentAnswer == nil && generation.providerTurnNumber == 0
                  && pdfStore.document?.page(at: 0)?.annotations.isEmpty == true,
                  "Late credentials restarted a canceled Ask or modified its PDF.")

            let deadlineReader = BlockingReader(values: ["deadline-fixture-never-sent"])
            defer { deadlineReader.releaseAll() }
            let deadlineStore = try makeStore(directory: directory, defaults: defaults, reader: deadlineReader,
                                              baseURL: "diagnostic-no-network://invalid")
            var shortBudget = AIWorkflowBudget.highlightDefault
            shortBudget.maximumDuration = .milliseconds(240)
            let deadlineTrace = AIHighlightTraceRecorder(fileURL: directory.appendingPathComponent("credential-deadline-trace.jsonl"), defaults: defaults)
            let deadlineGeneration = AIHighlightGenerationStore(configurationStore: deadlineStore,
                workflowService: AIHighlightWorkflowService(), traceRecorder: deadlineTrace, budget: shortBudget)
            deadlineGeneration.generateOverview(from: pdfStore)
            check(await waitUntil { deadlineReader.readCount == 1 }, "Deadline Ask did not reach the credential wait.")
            check(await waitUntil { !deadlineGeneration.isRunning }, "Ask deadline did not cancel a blocked credential wait.")
            check(deadlineGeneration.errorMessage == AIHighlightFailureMessage.userMessage(for: AIWorkflowFoundationError.budgetExceeded(.elapsedTime))
                  && deadlineGeneration.providerTurnNumber == 0 && deadlineReader.returnCount == 0,
                  "Credential-wait deadline was misreported or contacted the provider.")
            deadlineReader.releaseAll()
            _ = await waitUntil { deadlineReader.returnCount == 1 }
            await Task.yield()
            check(deadlineGeneration.currentAnswer == nil && deadlineGeneration.providerTurnNumber == 0
                  && pdfStore.document?.page(at: 0)?.annotations.isEmpty == true,
                  "Late credentials restarted a timed-out Ask.")
        } catch {
            check(false, "Credential diagnostic failed: \(error.localizedDescription)")
        }
        return Report(checks: checks, failures: failures)
    }

    private enum Outcome: Equatable { case created, cancelled, configurationChanged, missingKey, cloudUnavailable, readerUnavailable, otherError }
    private final class Probe { var outcome: Outcome? }

    private static func begin(_ store: AIConfigurationStore, ticket: AIProviderRequestTicket? = nil) -> (task: Task<Void, Never>, state: Probe) {
        let probe = Probe()
        let captured = ticket ?? store.captureProviderRequest()
        let task = Task { @MainActor in
            do {
                _ = try await store.toolCallingProvider(for: captured)
                probe.outcome = .created
            } catch is CancellationError { probe.outcome = .cancelled }
            catch AIConfigurationError.configurationChanged { probe.outcome = .configurationChanged }
            catch AIConfigurationError.cloudAIUnavailable { probe.outcome = .cloudUnavailable }
            catch AIConfigurationError.asynchronousCredentialReaderUnavailable { probe.outcome = .readerUnavailable }
            catch AIProviderError.missingAPIKey { probe.outcome = .missingKey }
            catch { probe.outcome = .otherError }
        }
        return (task, probe)
    }

    private static func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return condition()
    }

    private static func makeStore(directory: URL, defaults: UserDefaults, mode: AISecretStorageMode = .keychain,
                                  reader: (any AISecretReading)?, baseURL: String = "https://fixture.invalid/v1") throws -> AIConfigurationStore {
        let configuration = AIProviderConfiguration(id: UUID(), name: "Credential fixture", baseURL: baseURL,
            model: "fixture", isCloudAIEnabled: true, hasCloudConsent: true, secretStorageMode: mode)
        let url = directory.appendingPathComponent("\(UUID().uuidString).json")
        let providerJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration))
        let object: [String: Any] = ["provider": providerJSON, "apiKey": mode == .plaintextFile ? "plaintext-fixture" : "",
                                   "hasStoredKeychainAPIKey": mode == .keychain]
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        return AIConfigurationStore(configurationURL: url, legacyUserDefaults: defaults,
                                    secretStore: MemorySecretStore(), secretReader: reader)
    }

    private static func makeTextPDF() throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw CocoaError(.fileWriteUnknown) }
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 72, y: 700)
        let text = NSAttributedString(string: "Credential wait diagnostic evidence.",
                                      attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else { throw CocoaError(.fileReadCorruptFile) }
        return document
    }

    private final class MemorySecretStore: AISecretStoring {
        private var value: String?
        func readSecret(profileID: UUID) -> String? { value }
        func saveSecret(_ secret: String, profileID: UUID, configurationName: String) { value = secret }
        func removeSecret(profileID: UUID) { value = nil }
        func updateLabel(profileID: UUID, configurationName: String) {}
    }

    nonisolated private final class BlockingReader: AISecretReading, @unchecked Sendable {
        private let lock = NSLock()
        private let values: [String?]
        private let gates: [DispatchSemaphore]
        private var reads = 0
        private var returns = 0
        private var onMain = false
        init(values: [String?]) {
            self.values = values
            gates = values.map { _ in DispatchSemaphore(value: 0) }
        }
        var readCount: Int { lock.withLock { reads } }
        var returnCount: Int { lock.withLock { returns } }
        var readOnMainThread: Bool { lock.withLock { onMain } }
        func readSecret(profileID: UUID) throws -> String? {
            let index = lock.withLock {
                let index = reads
                reads += 1
                onMain = onMain || Thread.isMainThread
                return index
            }
            guard gates.indices.contains(index), gates[index].wait(timeout: .now() + 3) == .success else {
                throw FixtureError.unreleasedRead
            }
            lock.withLock { returns += 1 }
            return values[index]
        }
        func release(_ index: Int) { gates[index].signal() }
        func releaseAll() { for gate in gates { gate.signal() } }
        private enum FixtureError: Error { case unreleasedRead }
    }
}
