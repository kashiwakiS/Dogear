import Combine
import Foundation

@MainActor
final class AIReadingStore: ObservableObject {
    @Published private(set) var summaryMarkdown = ""
    @Published private(set) var conversation: [AIConversationTurn] = []
    @Published private(set) var pendingRequest: AIPendingRequest?
    @Published private(set) var isPreparing = false
    @Published private(set) var isRunning = false
    @Published private(set) var progressDescription = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var capturedSelection: AIContextPackage?
    @Published private(set) var activeTaskKind: AIReadingTaskKind?
    @Published private(set) var activeQuestion: String?
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published var questionText = ""

    private let configurationStore: AIConfigurationStore
    private let contextBuilder: AIContextBuilding
    private let resultStore: AIResultStoring
    private var runningTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var documentIdentity: String?

    convenience init() {
        self.init(
            configurationStore: .shared,
            contextBuilder: AIContextBuilder(),
            resultStore: InMemoryAIResultStore()
        )
    }

    init(
        configurationStore: AIConfigurationStore,
        contextBuilder: AIContextBuilding,
        resultStore: AIResultStoring
    ) {
        self.configurationStore = configurationStore
        self.contextBuilder = contextBuilder
        self.resultStore = resultStore
    }

    var canUseCloudProvider: Bool {
        configurationStore.configuration.isCloudAIEnabled
            && configurationStore.configuration.hasCloudConsent
            && configurationStore.isAPIKeyConfigured
            && !configurationStore.configuration.model.isEmpty
    }

    func prepareDocumentSummary(from store: PDFDocumentStore) {
        cancel()
        isPreparing = true
        errorMessage = nil

        runningTask = Task {
            defer { isPreparing = false }
            do {
                if canUseCloudProvider {
                    progressDescription = "Preparing the complete PDF..."
                    let context = try await contextBuilder.documentContext(from: store)
                    pendingRequest = AIPendingRequest(
                        id: UUID(),
                        kind: .summarizeDocument,
                        context: context,
                        question: nil,
                        previewText: "The complete PDF file will be uploaded.",
                        estimatedRequestCount: 1
                    )
                } else {
                    let context = AIContextPackage(
                        title: store.selectedDocumentName,
                        text: "",
                        pageNumbers: (0..<store.pageCount).map { $0 + 1 }
                    )
                    summaryMarkdown = localOutlineFallback(from: store, context: context)
                    resultStore.summaryMarkdown = summaryMarkdown
                    errorMessage = "Cloud AI is not configured. Showing a local structural outline instead."
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func sendQuestion(from store: PDFDocumentStore) {
        let question = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            errorMessage = "Enter a question first."
            return
        }
        guard canUseCloudProvider else {
            errorMessage = "Configure and enable a cloud AI provider in Settings first."
            return
        }

        do {
            let context: AIContextPackage
            if let capturedSelection {
                context = capturedSelection
            } else {
                context = try contextBuilder.selectionContext(from: store)
                capturedSelection = context
            }

            startQuestion(question, context: context)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func useNewSelection(from store: PDFDocumentStore) {
        do {
            capturedSelection = try contextBuilder.selectionContext(from: store)
            conversation = []
            resultStore.conversation = []
            pendingRequest = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendPendingRequest() {
        guard let pendingRequest, !isRunning else { return }
        self.pendingRequest = nil
        isRunning = true
        activeTaskKind = pendingRequest.kind
        errorMessage = nil
        startElapsedTimer()

        runningTask = Task {
            defer {
                isRunning = false
                activeTaskKind = nil
                activeQuestion = nil
                progressDescription = ""
                stopElapsedTimer()
            }
            do {
                let provider = try configurationStore.provider()
                switch pendingRequest.kind {
                case .summarizeDocument:
                    summaryMarkdown = try await summarize(
                        pendingRequest.context,
                        provider: provider
                    )
                    resultStore.summaryMarkdown = summaryMarkdown
                case .askSelection:
                    guard let question = pendingRequest.question else { return }
                    let startedAt = Date()
                    let result = try await ask(
                        question,
                        context: pendingRequest.context,
                        provider: provider
                    )
                    let turn = AIConversationTurn(
                        id: UUID(),
                        question: question,
                        answer: result.text,
                        selectionText: pendingRequest.context.text,
                        pageNumbers: pendingRequest.context.pageNumbers,
                        reasoningSummary: result.reasoningSummary,
                        duration: Date().timeIntervalSince(startedAt)
                    )
                    conversation.append(turn)
                    if conversation.count > 8 {
                        conversation.removeFirst(conversation.count - 8)
                    }
                    resultStore.conversation = conversation
                    questionText = ""
                }
            } catch is CancellationError {
                errorMessage = "AI request canceled."
            } catch {
                errorMessage = Task.isCancelled ? "AI request canceled." : error.localizedDescription
            }
        }
    }

    func cancelPendingRequest() {
        pendingRequest = nil
    }

    func cancel() {
        runningTask?.cancel()
        elapsedTask?.cancel()
        runningTask = nil
        if isRunning || isPreparing {
            errorMessage = "AI operation canceled."
        }
        isRunning = false
        isPreparing = false
        progressDescription = ""
        activeTaskKind = nil
        activeQuestion = nil
        elapsedTime = 0
    }

    func documentDidChange(to identity: String?) {
        guard documentIdentity != identity else { return }
        documentIdentity = identity
        cancel()
        pendingRequest = nil
        capturedSelection = nil
        resultStore.clear()
        summaryMarkdown = ""
        conversation = []
        questionText = ""
        errorMessage = nil
    }

    private func summarize(
        _ context: AIContextPackage,
        provider: AIProvider
    ) async throws -> String {
        guard let file = context.file else {
            throw AIContextError.cannotPreparePDF
        }
        try Task.checkCancellation()
        progressDescription = "Uploading and summarizing the complete PDF..."
        return try await provider.respond(
            to: AIResponseRequest(
                instructions: "Summarize the attached complete PDF faithfully in well-structured Markdown. Preserve important claims and include useful [p. N] page references. Do not invent facts. Use the predominant language of the document.",
                input: "Create one coherent summary of the complete document: \(context.title)",
                file: file
            )
        ).text
    }

    private func ask(
        _ question: String,
        context: AIContextPackage,
        provider: AIProvider
    ) async throws -> AIResponseResult {
        progressDescription = "Asking about the selected text..."
        return try await provider.respond(
            to: AIResponseRequest(
                instructions: "Answer only from the selected PDF text and conversation. If the answer is not supported, say so. Cite the supplied page numbers. Reply in the language of the user's question.",
                input: questionInput(question, context: context)
            )
        )
    }

    private func startQuestion(_ question: String, context: AIContextPackage) {
        guard !isRunning else { return }
        pendingRequest = nil
        isRunning = true
        activeTaskKind = .askSelection
        activeQuestion = question
        errorMessage = nil
        questionText = ""
        startElapsedTimer()

        runningTask = Task {
            let startedAt = Date()
            defer {
                isRunning = false
                activeTaskKind = nil
                activeQuestion = nil
                progressDescription = ""
                stopElapsedTimer()
            }
            do {
                let provider = try configurationStore.provider()
                let result = try await ask(question, context: context, provider: provider)
                let turn = AIConversationTurn(
                    id: UUID(),
                    question: question,
                    answer: result.text,
                    selectionText: context.text,
                    pageNumbers: context.pageNumbers,
                    reasoningSummary: result.reasoningSummary,
                    duration: Date().timeIntervalSince(startedAt)
                )
                conversation.append(turn)
                if conversation.count > 8 {
                    conversation.removeFirst(conversation.count - 8)
                }
                resultStore.conversation = conversation
            } catch is CancellationError {
                errorMessage = "AI request canceled."
            } catch {
                if Task.isCancelled {
                    errorMessage = "AI request canceled."
                } else {
                    errorMessage = error.localizedDescription
                    questionText = question
                }
            }
        }
    }

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTime = 0
        let startedAt = Date()
        elapsedTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                elapsedTime = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = nil
    }

    private func questionInput(_ question: String, context: AIContextPackage) -> String {
        let history = conversation.suffix(8).map {
            "User: \($0.question)\nAssistant: \($0.answer)"
        }.joined(separator: "\n\n")
        let pages = context.pageNumbers.map(String.init).joined(separator: ", ")
        return """
        Document: \(context.title)
        Source pages: \(pages)
        Selected text:
        \(context.text)

        Previous conversation:
        \(history.isEmpty ? "(none)" : history)

        Question: \(question)
        """
    }

    private func localOutlineFallback(
        from store: PDFDocumentStore,
        context: AIContextPackage
    ) -> String {
        var lines = [
            "# \(context.title) — Local Outline",
            "",
            "_Generated locally without an AI provider._",
            ""
        ]
        if store.outlineEntries.isEmpty {
            lines.append("- Extractable pages: \(context.pageNumbers.count)")
            lines.append("- Characters: \(context.characterCount)")
        } else {
            for entry in store.outlineEntries {
                let prefix = String(repeating: "  ", count: entry.level) + "-"
                lines.append("\(prefix) \(entry.title) [p. \(entry.pageNumber)]")
            }
        }
        return lines.joined(separator: "\n")
    }
}
