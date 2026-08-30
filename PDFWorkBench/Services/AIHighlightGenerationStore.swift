import AppKit
import Combine
import Foundation
import PDFKit

@MainActor
final class AIHighlightGenerationStore: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progressDescription = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastReport: String?
    @Published var questionText = ""
    @Published var recordsDetailedTraceContent: Bool {
        didSet {
            UserDefaults.standard.set(
                recordsDetailedTraceContent,
                forKey: AIHighlightTraceRecorder.detailedContentDefaultsKey
            )
        }
    }

    private let configurationStore: AIConfigurationStore
    private let workflowService: AIHighlightWorkflowService
    private let traceRecorder: AIHighlightTraceRecorder
    private var runningTask: Task<Void, Never>?
    private var documentIdentity: ObjectIdentifier?
    private var activeJobID: UUID?

    convenience init() {
        self.init(
            configurationStore: .shared,
            workflowService: AIHighlightWorkflowService(),
            traceRecorder: .shared
        )
    }

    init(
        configurationStore: AIConfigurationStore,
        workflowService: AIHighlightWorkflowService,
        traceRecorder: AIHighlightTraceRecorder = .shared
    ) {
        self.configurationStore = configurationStore
        self.workflowService = workflowService
        self.traceRecorder = traceRecorder
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

    var providerDescription: String {
        let configuration = configurationStore.configuration
        let model = configuration.model.isEmpty ? "no model selected" : configuration.model
        return "Provider: \(configuration.name) · \(model). Only native-text passages returned by targeted read tools are sent; the PDF file is not attached."
    }

    func generateOverview(from store: PDFDocumentStore) {
        start(intent: .overview, from: store)
    }

    func generateForQuestion(from store: PDFDocumentStore) {
        let question = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            errorMessage = "Enter a question to highlight its evidence."
            return
        }
        start(intent: .question(question), from: store)
    }

    func cancel() {
        runningTask?.cancel()
        runningTask = nil
        activeJobID = nil
        if isRunning {
            errorMessage = "AI highlight generation canceled. No new annotations were applied."
        }
        isRunning = false
        progressDescription = ""
    }

    func documentDidChange(to document: PDFDocument?) {
        let identity = document.map(ObjectIdentifier.init)
        guard identity != documentIdentity else { return }
        documentIdentity = identity
        cancel()
        errorMessage = nil
        lastReport = nil
    }

    func revealTraceLog() {
        Task {
            guard let traceURL = await traceRecorder.traceFileURL() else { return }
            if FileManager.default.fileExists(atPath: traceURL.path) {
                NSWorkspace.shared.activateFileViewerSelecting([traceURL])
            } else {
                NSWorkspace.shared.open(traceURL.deletingLastPathComponent())
            }
        }
    }

    private func start(intent: AIHighlightIntent, from store: PDFDocumentStore) {
        guard !isRunning else { return }
        guard canGenerate else {
            errorMessage = "Configure and enable a cloud AI provider in Settings first."
            return
        }
        guard let document = store.document else {
            errorMessage = "Open a PDF first."
            return
        }

        let jobID = UUID()
        let configuration = configurationStore.configuration
        let groupRequestKind: AIHighlightGroupRequestKind
        let groupQuestion: String?
        switch intent {
        case .overview:
            groupRequestKind = .overview
            groupQuestion = nil
        case .question(let question):
            groupRequestKind = .question
            groupQuestion = question
        }
        do {
            let snapshot = try NativePDFTextSnapshotBuilder(document: document)
                .makeTextSnapshot()
            guard snapshot.pages.contains(where: {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                Task {
                    await traceRecorder.record(
                        workflowID: jobID,
                        groupID: jobID,
                        event: .jobStarted(
                            requestKind: groupRequestKind,
                            question: groupQuestion,
                            providerName: configuration.name,
                            modelName: configuration.model
                        )
                    )
                    await traceRecorder.record(
                        workflowID: jobID,
                        groupID: jobID,
                        event: .snapshotPrepared(
                            documentFingerprint: snapshot.fingerprint,
                            pageCount: snapshot.pages.count,
                            nativeTextCharacters: 0
                        )
                    )
                    await traceRecorder.record(
                        workflowID: jobID,
                        groupID: jobID,
                        event: .failed(
                            code: "no_usable_native_text",
                            message: "This PDF has no usable native text."
                        )
                    )
                }
                errorMessage = "This PDF has no usable native text. OCR is not enabled in this version."
                return
            }
            isRunning = true
            errorMessage = nil
            lastReport = nil
            progressDescription = "Searching and verifying native PDF text…"
            let capturedDocument = document
            activeJobID = jobID

            runningTask = Task {
                await traceRecorder.record(
                    workflowID: jobID,
                    groupID: jobID,
                    event: .jobStarted(
                        requestKind: groupRequestKind,
                        question: groupQuestion,
                        providerName: configuration.name,
                        modelName: configuration.model
                    )
                )
                await traceRecorder.record(
                    workflowID: jobID,
                    groupID: jobID,
                    event: .snapshotPrepared(
                        documentFingerprint: snapshot.fingerprint,
                        pageCount: snapshot.pages.count,
                        nativeTextCharacters: snapshot.pages.reduce(0) {
                            $0 + $1.text.count
                        }
                    )
                )
                defer {
                    if activeJobID == jobID {
                        isRunning = false
                        progressDescription = ""
                        runningTask = nil
                        activeJobID = nil
                    }
                }
                do {
                    let provider = try configurationStore.toolCallingProvider()
                    let result = try await workflowService.generateDraft(
                        snapshot: snapshot,
                        intent: intent,
                        provider: provider,
                        workflowID: jobID
                    )
                    try Task.checkCancellation()
                    guard activeJobID == jobID else { throw CancellationError() }
                    guard store.document === capturedDocument else {
                        throw AIHighlightGenerationError.documentChanged
                    }

                    progressDescription = "Revalidating anchors and applying one annotation batch…"
                    let anchors = try AIHighlightNativeAnchorResolver().resolve(
                        result.highlights,
                        registry: result.registry,
                        in: capturedDocument
                    )
                    await traceRecorder.record(
                        workflowID: jobID,
                        groupID: jobID,
                        event: .anchorsResolved(count: anchors.count)
                    )
                    try Task.checkCancellation()
                    guard activeJobID == jobID else { throw CancellationError() }
                    let group = AIHighlightGroup(
                        id: jobID,
                        requestKind: groupRequestKind,
                        title: result.title,
                        question: groupQuestion,
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
                    await traceRecorder.record(
                        workflowID: jobID,
                        groupID: jobID,
                        event: .commitCompleted(
                            appliedCount: appliedCount,
                            skippedDuplicates: skippedDuplicates
                        )
                    )
                    lastReport = report(
                        appliedCount: appliedCount,
                        skippedDuplicates: skippedDuplicates,
                        usage: result.usage
                    )
                    if case .question = intent {
                        questionText = ""
                    }
                } catch is CancellationError {
                    await traceRecorder.record(
                        workflowID: jobID,
                        groupID: jobID,
                        event: .cancelled
                    )
                    if activeJobID == jobID {
                        errorMessage = "AI highlight generation canceled. No new annotations were applied."
                    }
                } catch {
                    await traceRecorder.record(
                        workflowID: jobID,
                        groupID: jobID,
                        event: .failed(
                            code: String(describing: type(of: error)),
                            message: error.localizedDescription
                        )
                    )
                    if activeJobID == jobID {
                        errorMessage = Task.isCancelled
                            ? "AI highlight generation canceled. No new annotations were applied."
                            : error.localizedDescription
                    }
                }
            }
        } catch {
            Task {
                await traceRecorder.record(
                    workflowID: jobID,
                    groupID: jobID,
                    event: .jobStarted(
                        requestKind: groupRequestKind,
                        question: groupQuestion,
                        providerName: configuration.name,
                        modelName: configuration.model
                    )
                )
                await traceRecorder.record(
                    workflowID: jobID,
                    groupID: jobID,
                    event: .failed(
                        code: String(describing: type(of: error)),
                        message: error.localizedDescription
                    )
                )
            }
            errorMessage = error.localizedDescription
        }
    }

    private func report(
        appliedCount: Int,
        skippedDuplicates: Int,
        usage: AIWorkflowUsage
    ) -> String {
        var parts = ["Applied \(appliedCount) verified AI highlight(s) as one undoable operation."]
        if skippedDuplicates > 0 {
            parts.append("Skipped \(skippedDuplicates) duplicate(s).")
        }
        parts.append(
            "Provider turns: \(usage.providerTurns); tool calls: \(usage.toolCalls); source characters read: \(usage.readCharacters)."
        )
        return parts.joined(separator: " ")
    }
}

nonisolated enum AIHighlightGenerationError: LocalizedError, Equatable {
    case documentChanged

    var errorDescription: String? {
        switch self {
        case .documentChanged:
            return "The PDF changed while AI highlights were being prepared. No annotations were applied."
        }
    }
}
