import AppKit
import Combine
import Foundation
import PDFKit

@MainActor
final class AIHighlightGenerationStore: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progressPhase: AIHighlightProgressPhase?
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var providerTurnNumber = 0
    @Published private(set) var toolCallCount = 0
    @Published private(set) var readCharacterCount = 0
    @Published private(set) var inputTokenCount: Int?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastReport: String?
    @Published private(set) var currentAnswer: AIPublishedAnswer?
    @Published private(set) var isLocalOutline = false
    @Published var questionText = ""
    @Published var allowsAnnotations = true
    @Published private(set) var traceLocation = ""
    @Published private(set) var traceStatus: String?
    @Published var recordsDetailedTraceContent: Bool {
        didSet {
            UserDefaults.standard.set(
                recordsDetailedTraceContent,
                forKey: AIHighlightTraceRecorder.detailedContentDefaultsKey
            )
        }
    }

    let budget: AIWorkflowBudget

    private let configurationStore: AIConfigurationStore
    private let workflowService: AIHighlightWorkflowService
    private let traceRecorder: AIHighlightTraceRecorder
    private let captureRetrieval: () throws -> AIRetrievalSelection
    @Published private(set) var indexingProgress: String?
    private var runningTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var documentIdentity: ObjectIdentifier?
    private var activeJobID: UUID?
    private var documentValidityCheck: (() throws -> Void)?
    private var invalidDocumentJobID: UUID?
    private var jobDeadline: ContinuousClock.Instant?
    private var deadlineExpiredJobID: UUID?

    convenience init() {
        self.init(
            configurationStore: .shared,
            workflowService: AIHighlightWorkflowService(),
            traceRecorder: .shared,
            captureRetrieval: { try AIRetrievalSelection.capture(from: .standard) }
        )
    }

    init(
        configurationStore: AIConfigurationStore,
        workflowService: AIHighlightWorkflowService,
        traceRecorder: AIHighlightTraceRecorder = .shared,
        budget: AIWorkflowBudget = .highlightDefault,
        captureRetrieval: @escaping () throws -> AIRetrievalSelection = { .lexical }
    ) {
        self.configurationStore = configurationStore
        self.workflowService = workflowService
        self.traceRecorder = traceRecorder
        self.budget = budget
        self.captureRetrieval = captureRetrieval
        recordsDetailedTraceContent = UserDefaults.standard.bool(
            forKey: AIHighlightTraceRecorder.detailedContentDefaultsKey
        )
    }

    var canGenerate: Bool {
        configurationStore.configuration.isCloudAIEnabled
            && configurationStore.configuration.hasCloudConsent
            && configurationStore.isAPIKeyConfigured
            && !configurationStore.configuration.model.isEmpty
    }

    var progressDescription: String {
        if isLocalOutline {
            return L10n.string("Preparing a local structural outline…")
        }
        return progressPhase?.localizedDescription ?? L10n.string("Preparing the AI workflow…")
    }

    var progressDetail: String {
        if let indexingProgress, progressPhase == .indexingEvidence { return indexingProgress }
        if isLocalOutline {
            return L10n.string("On-device only · No provider requests")
        }
        var details = [
            L10n.string("Turn \(providerTurnNumber) of \(budget.maximumProviderTurns)"),
            L10n.string("\(toolCallCount) tool calls")
        ]
        if readCharacterCount > 0 {
            details.append(L10n.string("\(readCharacterCount) source characters"))
        }
        return details.joined(separator: " · ")
    }

    var providerDescription: String {
        if isLocalOutline {
            return L10n.string("Local structural outline only. No provider requests or PDF uploads.")
        }
        let configuration = configurationStore.configuration
        let model = configuration.model.isEmpty
            ? L10n.string("No model selected")
            : configuration.model
        return L10n.string(
            "Provider: \(configuration.name) · \(model). Ask sends selected text and retrieved passages, not the PDF file."
        )
    }

    func generateOverview(from store: PDFDocumentStore) {
        start(intent: .overview, from: store)
    }

    func generateForQuestion(
        from store: PDFDocumentStore,
        selectedContext: AIContextPackage? = nil
    ) {
        let question = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            errorMessage = L10n.string("Enter a question first.")
            return
        }
        start(
            intent: .question(question),
            selectedContext: selectedContext,
            from: store
        )
    }

    func cancel() {
        let wasRunning = isRunning
        runningTask?.cancel()
        elapsedTask?.cancel()
        runningTask = nil
        elapsedTask = nil
        activeJobID = nil
        jobDeadline = nil
        documentValidityCheck = nil
        isRunning = false
        progressPhase = nil
        elapsedTime = 0
        if wasRunning {
            errorMessage = cancellationMessage
        }
    }

    func documentDidChange(to document: PDFDocument?) {
        let identity = document.map(ObjectIdentifier.init)
        guard identity != documentIdentity else { return }
        documentIdentity = identity
        cancel()
        errorMessage = nil
        lastReport = nil
        currentAnswer = nil
        isLocalOutline = false
    }

    func revealTraceLog() {
        Task {
            await refreshTraceLocation()
            guard let traceURL = await traceRecorder.traceFileURL() else { return }
            if FileManager.default.fileExists(atPath: traceURL.path) {
                NSWorkspace.shared.activateFileViewerSelecting([traceURL])
            } else {
                errorMessage = L10n.string("No workflow log yet. Run an AI request first.")
            }
        }
    }

    func refreshTraceLocation() async {
        traceLocation = await traceRecorder.traceFileURL()?.path ?? ""
        traceStatus = await traceRecorder.lastError
    }

#if DEBUG
    func chooseDebugLogFolder() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.string("Choose Log Folder")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                do {
                    try await self.traceRecorder.chooseDebugDirectory(url)
                    await self.refreshTraceLocation()
                } catch {
                    self.traceStatus = L10n.string("Could not select the log folder. Finish active requests and choose a writable folder.")
                }
            }
        }
    }
#endif

    private func start(
        intent: AIHighlightIntent,
        selectedContext: AIContextPackage? = nil,
        from store: PDFDocumentStore
    ) {
        guard !isRunning else { return }
        let usesLocalOutline = !canGenerate && intent == .overview
        guard canGenerate || usesLocalOutline else {
            errorMessage = L10n.string(
                "Configure and enable a cloud AI provider in Settings first."
            )
            return
        }
        guard let document = store.document else {
            errorMessage = L10n.string("Open a PDF first.")
            return
        }

        let jobID = UUID()
        let annotationPermission = AIHighlightIntentPolicy.make(
            for: intent, allowsAnnotations: allowsAnnotations
        ).allowsAnnotations
        let retrieval: AIRetrievalSelection
        do { retrieval = usesLocalOutline ? .lexical : try captureRetrieval() }
        catch { errorMessage = AIHighlightFailureMessage.userMessage(for: error); return }
        let providerTicket = configurationStore.captureProviderRequest()
        let configuration = providerTicket.configuration
        let request = requestMetadata(for: intent)
        let capturedDocument = document
        let documentName = store.selectedDocumentName
        let existingOutline = store.outlineEntries
        activeJobID = jobID
        invalidDocumentJobID = nil
        deadlineExpiredJobID = nil
        jobDeadline = usesLocalOutline ? nil : ContinuousClock().now.advanced(by: budget.maximumDuration)
        resetProgress()
        isRunning = true
        errorMessage = nil
        lastReport = nil
        currentAnswer = nil
        isLocalOutline = usesLocalOutline
        progressPhase = .preparingSnapshot
        startElapsedTimer()

        runningTask = Task {
            await traceRecorder.record(
                workflowID: jobID,
                groupID: jobID,
                event: .jobStarted(
                    requestKind: request.kind,
                    question: request.question,
                    providerName: usesLocalOutline ? "Local structural outline" : configuration.name,
                    modelName: usesLocalOutline ? "" : configuration.model
                )
            )
            defer { finish(jobID: jobID) }
            do {
                try checkActiveJob(jobID)
                let layout = try NativePDFDocumentLayoutSnapshot(document: capturedDocument)
                documentValidityCheck = {
                    guard store.document === capturedDocument else {
                        throw AIHighlightGenerationError.documentChanged
                    }
                    do {
                        try layout.validate(in: capturedDocument)
                    } catch {
                        throw AIHighlightGenerationError.documentChanged
                    }
                }
                let snapshot = try await NativePDFTextSnapshotBuilder(document: capturedDocument)
                    .makeTextSnapshotCooperatively()
                try checkActiveJob(jobID)
                let characterCount = snapshot.pages.reduce(0) { $0 + $1.text.count }
                await traceRecorder.record(
                    workflowID: jobID,
                    groupID: jobID,
                    event: .snapshotPrepared(
                        documentFingerprint: snapshot.fingerprint,
                        pageCount: snapshot.pages.count,
                        nativeTextCharacters: characterCount
                    )
                )
                try checkActiveJob(jobID)
                if usesLocalOutline {
                    // Reuse the reader's bookmark/heading outline, without PDF
                    // upload preparation or a provider connection. A scanned
                    // PDF may still have bookmarks and always has page counts.
                    let entries = existingOutline.isEmpty
                        ? await DocumentOutlineService().outline(for: capturedDocument)
                        : existingOutline
                    try checkActiveJob(jobID)
                    let answer = try AILocalOutlineFallback.answer(
                        documentName: documentName,
                        snapshot: snapshot,
                        entries: entries
                    )
                    try await validateSnapshot(
                        snapshot.fingerprint,
                        document: capturedDocument,
                        jobID: jobID
                    )
                    currentAnswer = answer
                    lastReport = L10n.string(
                        "Local structural outline ready. No AI provider was contacted and no annotations were created."
                    )
                    finish(jobID: jobID)
                    await traceRecorder.record(
                        workflowID: jobID,
                        groupID: jobID,
                        event: .commitCompleted(appliedCount: 0, skippedDuplicates: 0)
                    )
                    return
                }
                guard characterCount > 0 else {
                    throw AIHighlightGenerationError.noUsableNativeText
                }

                progressPhase = .waitingForCredentials
                let provider = try await configurationStore.toolCallingProvider(for: providerTicket)
                // A system authorization dialog may outlive Cancel. Its late
                // result must not initiate a provider request for an ended job.
                try checkActiveJob(jobID)
                progressPhase = .mappingDocument
                var remainingBudget = budget
                if let jobDeadline {
                    remainingBudget.maximumDuration = ContinuousClock().now.duration(to: jobDeadline)
                }
                let result = try await workflowService.generateReadingResult(
                    snapshot: snapshot,
                    intent: intent,
                    selectedContext: selectedContext,
                    provider: provider,
                    workflowID: jobID,
                    budget: remainingBudget,
                    retrieval: retrieval,
                    allowsAnnotations: annotationPermission,
                    verifiesAnswerEvidence: true,
                    indexingProgress: { completed, total in
                        await self.applyIndexProgress(completed: completed, total: total, jobID: jobID)
                    },
                    progress: { event in
                        await self.apply(event, for: jobID)
                    },
                    publication: { answer in
                        await self.acceptPublishedAnswer(answer, for: jobID)
                    }
                )
                try checkActiveJob(jobID)

                guard annotationPermission || result.highlights.isEmpty else {
                    throw AIHighlightWorkflowError.annotationsForbidden
                }
                guard !result.highlights.isEmpty else {
                    try await validateSnapshot(
                        result.registry.snapshotFingerprint,
                        document: capturedDocument,
                        jobID: jobID
                    )
                    currentAnswer = result.answer
                    lastReport = report(
                        appliedCount: 0,
                        skippedDuplicates: 0,
                        usage: result.usage
                    )
                    if case .question = intent { questionText = "" }
                    finish(jobID: jobID)
                    await traceRecorder.record(
                        workflowID: jobID,
                        groupID: jobID,
                        event: .commitCompleted(
                            appliedCount: 0,
                            skippedDuplicates: 0
                        )
                    )
                    return
                }

                progressPhase = .resolvingAnchors
                let anchors: [ResolvedAIHighlightAnchor]
                do {
                    anchors = try await AIHighlightNativeAnchorResolver()
                        .resolveCooperatively(
                            result.highlights,
                            registry: result.registry,
                            in: capturedDocument
                        )
                } catch is CancellationError {
                    throw CancellationError()
                } catch AIHighlightNativePDFBridgeError.documentFingerprintChanged {
                    throw AIHighlightGenerationError.documentChanged
                } catch AIHighlightNativePDFBridgeError.pageFingerprintChanged {
                    throw AIHighlightGenerationError.documentChanged
                } catch {
                    // A geometry failure is optional only while its answer's
                    // document remains current. Cancellation/staleness wins.
                    try await validateSnapshot(
                        result.registry.snapshotFingerprint,
                        document: capturedDocument,
                        jobID: jobID
                    )
                    currentAnswer = result.answer
                    errorMessage = L10n.string(
                        "The answer is ready, but Dogear could not apply its optional highlights."
                    )
                    lastReport = report(
                        appliedCount: 0,
                        skippedDuplicates: 0,
                        usage: result.usage
                    )
                    if case .question = intent { questionText = "" }
                    finish(jobID: jobID)
                    await traceRecorder.record(
                        workflowID: jobID,
                        groupID: jobID,
                        event: .failed(
                            code: "optional_highlight_anchors",
                            message: error.localizedDescription
                        )
                    )
                    return
                }
                try checkActiveJob(jobID)

                progressPhase = .committingBatch
                let group = AIHighlightGroup(
                    id: jobID,
                    requestKind: request.kind,
                    title: result.answer.title,
                    question: request.question,
                    providerName: configuration.name,
                    modelName: configuration.model,
                    promptVersion: AIHighlightWorkflowService.promptVersion
                )
                let appliedCount = try store.applyAIHighlights(
                    stagedHighlights: result.highlights,
                    anchors: anchors,
                    group: group,
                    trigger: .pointer
                )
                let skippedDuplicates = result.highlights.count - appliedCount
                currentAnswer = result.answer
                lastReport = report(
                    appliedCount: appliedCount,
                    skippedDuplicates: skippedDuplicates,
                    usage: result.usage
                )
                if case .question = intent {
                    questionText = ""
                }
                // Commit and visible completion are one uninterrupted MainActor
                // operation: Cancel must not claim rollback after native writes.
                finish(jobID: jobID)
                await traceRecorder.record(
                    workflowID: jobID,
                    groupID: jobID,
                    event: .anchorsResolved(count: anchors.count)
                )
                await traceRecorder.record(
                    workflowID: jobID,
                    groupID: jobID,
                    event: .commitCompleted(
                        appliedCount: appliedCount,
                        skippedDuplicates: skippedDuplicates
                    )
                )
            } catch {
                var failure: Error = deadlineExpiredJobID == jobID
                    ? AIWorkflowFoundationError.budgetExceeded(.elapsedTime) : error
                if activeJobID == jobID {
                    do {
                        try documentValidityCheck?()
                    } catch {
                        failure = AIHighlightGenerationError.documentChanged
                    }
                }
                if invalidDocumentJobID == jobID || Self.isStaleDocumentError(failure) {
                    failure = AIHighlightGenerationError.documentChanged
                }
                if activeJobID == jobID {
                    if AIHighlightFailureMessage.kind(of: failure) == .documentChanged {
                        currentAnswer = nil
                    }
                    errorMessage = failure is CancellationError
                        ? cancellationMessage
                        : AIHighlightFailureMessage.userMessage(for: failure)
                    finish(jobID: jobID)
                }
                if failure is CancellationError {
                    await traceRecorder.record(
                        workflowID: jobID,
                        groupID: jobID,
                        event: .cancelled
                    )
                } else {
                    await traceRecorder.record(
                        workflowID: jobID,
                        groupID: jobID,
                        event: .failed(
                            code: AIHighlightFailureMessage.code(for: failure),
                            message: failure.localizedDescription
                        )
                    )
                }
            }
        }
    }

    private func applyIndexProgress(completed: Int, total: Int, jobID: UUID) {
        guard activeJobID == jobID, isRunning else { return }
        progressPhase = .indexingEvidence
        indexingProgress = total == 0 ? L10n.string("Loading the local embedding model…") : "\(completed) / \(total)"
    }

    private func requestMetadata(
        for intent: AIHighlightIntent
    ) -> (kind: AIHighlightGroupRequestKind, question: String?) {
        switch intent {
        case .overview:
            return (.overview, nil)
        case .question(let question):
            return (.question, question)
        }
    }

    private var cancellationMessage: String {
        isLocalOutline
            ? L10n.string("Local outline canceled. No changes were made.")
            : L10n.string("AI request canceled. No new annotations were applied.")
    }

    private func apply(_ event: AIWorkflowEvent, for jobID: UUID) {
        guard activeJobID == jobID else { return }
        switch event {
        case .evidenceReviewStarted:
            progressPhase = .reviewingEvidence
        case .providerTurnStarted(let index):
            providerTurnNumber = index + 1
            progressPhase = .waitingForProvider
        case .providerTurnFinished(_, _, let tokens, _, _):
            if let tokens {
                inputTokenCount = (inputTokenCount ?? 0) + tokens
            }
        case .toolStarted(_, let name, _):
            toolCallCount += 1
            progressPhase = .phase(forToolName: name)
        case .toolFinished(_, _, _, let readCharacters):
            readCharacterCount += readCharacters
        case .retryScheduled:
            progressPhase = .retrying
        case .phaseChanged(.validatedDraft):
            progressPhase = .validatingDraft
        default:
            break
        }
    }

    private func acceptPublishedAnswer(
        _ answer: AIPublishedAnswer,
        for jobID: UUID
    ) {
        guard activeJobID == jobID else { return }
        do {
            try checkActiveJob(jobID)
        } catch {
            if Self.isStaleDocumentError(error) {
                currentAnswer = nil
                invalidDocumentJobID = jobID
                runningTask?.cancel()
            }
            return
        }
        // A terminal publication still has pending batch/anchor work. It only
        // replaces interim text after the fresh snapshot and commit checks.
        if !answer.terminate { currentAnswer = answer }
        progressPhase = answer.terminate ? .resolvingAnchors : .generatingAnswer
    }

    private func checkActiveJob(_ jobID: UUID) throws {
        guard activeJobID == jobID else { throw CancellationError() }
        if invalidDocumentJobID == jobID {
            throw AIHighlightGenerationError.documentChanged
        }
        try documentValidityCheck?()
        if deadlineExpiredJobID == jobID || jobDeadline.map({ ContinuousClock().now >= $0 }) == true {
            throw AIWorkflowFoundationError.budgetExceeded(.elapsedTime)
        }
        try Task.checkCancellation()
    }

    private func validateSnapshot(
        _ fingerprint: String,
        document: PDFDocument,
        jobID: UUID
    ) async throws {
        try checkActiveJob(jobID)
        try await AIHighlightNativeAnchorResolver().validateSnapshotCooperatively(
            fingerprint: fingerprint,
            in: document
        )
        try checkActiveJob(jobID)
    }

    private static func isStaleDocumentError(_ error: Error) -> Bool {
        if error as? AIHighlightGenerationError == .documentChanged { return true }
        guard let bridgeError = error as? AIHighlightNativePDFBridgeError else { return false }
        switch bridgeError {
        case .documentFingerprintChanged, .pageFingerprintChanged, .missingPage, .emptyDocument:
            return true
        default:
            return false
        }
    }

    private func resetProgress() {
        elapsedTask?.cancel()
        elapsedTime = 0
        providerTurnNumber = 0
        toolCallCount = 0
        readCharacterCount = 0
        inputTokenCount = nil
        indexingProgress = nil
    }

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        let startedAt = ContinuousClock().now
        elapsedTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                let elapsed = startedAt.duration(to: ContinuousClock().now).components
                elapsedTime = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                if let jobDeadline, ContinuousClock().now >= jobDeadline, let activeJobID {
                    deadlineExpiredJobID = activeJobID
                    runningTask?.cancel()
                    return
                }
            }
        }
    }

    private func finish(jobID: UUID) {
        guard activeJobID == jobID else { return }
        elapsedTask?.cancel()
        elapsedTask = nil
        runningTask = nil
        activeJobID = nil
        jobDeadline = nil
        documentValidityCheck = nil
        isRunning = false
        progressPhase = nil
    }

    private func report(
        appliedCount: Int,
        skippedDuplicates: Int,
        usage: AIWorkflowUsage
    ) -> String {
        var parts = [appliedCount > 0
            ? L10n.string("This request originally added \(appliedCount) highlight(s). Undo or later edits may change the current annotations.")
            : L10n.string("The answer is ready. No highlights were added.")]
        if skippedDuplicates > 0 {
            parts.append(L10n.string("Skipped \(skippedDuplicates) duplicate(s)."))
        }
        parts.append(
            L10n.string(
                "Provider turns: \(usage.providerTurns); tool calls: \(usage.toolCalls); source characters read: \(usage.readCharacters)."
            )
        )
        return parts.joined(separator: " ")
    }
}

nonisolated enum AIHighlightGenerationError: LocalizedError, Equatable {
    case documentChanged
    case noUsableNativeText

    var errorDescription: String? {
        switch self {
        case .documentChanged:
            return "The PDF changed while the AI request was running."
        case .noUsableNativeText:
            return "This PDF has no usable native text. OCR is not enabled in this version."
        }
    }
}
