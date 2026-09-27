import AppKit
import Combine
import Foundation
import ImageIO
import PDFKit

struct ResearchRequestProgress: Equatable {
    var requestID: UUID
    var phase: String
    var startedAt = Date()
    var providerTurns = 0
    var toolCalls = 0
    var readCharacters = 0
    var inputTokens: Int? = nil
    var preparedSources = 0
    var totalSources = 0
    var skippedSources: [String] = []
    var interimAnswer: String? = nil
}

enum ResearchRuntimeError: LocalizedError {
    case noSources, configureProvider, sourceOutsideScope, sourceChanged(String), imagesUnavailable
    case inputTooLarge, preparationTimedOut, requestTimedOut, persistenceFailed

    var errorDescription: String? {
        switch self {
        case .noSources: return L10n.string("Choose a research source or attach an image first.")
        case .configureProvider: return L10n.string("Configure and enable a cloud AI provider in Settings first.")
        case .sourceOutsideScope: return L10n.string("An input passage is outside this session’s sources. Add its source or remove the passage before sending.")
        case .sourceChanged(let name): return L10n.string("Source changed") + ": " + name
        case .imagesUnavailable: return L10n.string("Image support is not confirmed for this provider and model. Your attachments have been kept.")
        case .inputTooLarge: return L10n.string("The input exceeds the request limits. Remove some passages or images and try again.")
        case .preparationTimedOut: return L10n.string("Source preparation reached its time limit. Narrow the sources and try again.")
        case .requestTimedOut: return L10n.string("The research request reached its time limit. Your input has been kept.")
        case .persistenceFailed: return L10n.string("Research could not be saved. Retry saving before sending a request.")
        }
    }
}

/// Request ownership is application-level. A PDF view owns only a revocable
/// editing/view capability, never the research conversation or its task.
@MainActor
final class ResearchRuntime: ObservableObject {
    static let shared = ResearchRuntime()
    @Published private(set) var jobs: [UUID: ResearchRequestProgress] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private let storage: ResearchStore
    private let configuration: AIConfigurationStore
    private let service: AIHighlightWorkflowService
    private let trace: AIHighlightTraceRecorder
    private let commands: ResearchCommandService
    private let requestTimeout: Duration
    private let providerResolver: ((AIProviderRequestTicket) async throws -> any AIToolCallingProvider)?
    private let retrievalSelection: AIRetrievalSelection?
    private var requestTraces: [UUID: RequestTrace] = [:]

    /// MainActor ownership claims the terminal result synchronously. The start
    /// task orders terminal logging even when Cancel immediately follows Send.
    private final class RequestTrace {
        let requestID: UUID
        let started: Task<Void, Never>
        init(requestID: UUID, started: Task<Void, Never>) {
            self.requestID = requestID
            self.started = started
        }
    }

    init(storage: ResearchStore? = nil, configuration: AIConfigurationStore? = nil,
         service: AIHighlightWorkflowService? = nil,
         traceRecorder: AIHighlightTraceRecorder = .shared,
         commands: ResearchCommandService? = nil,
         requestTimeout: Duration = .seconds(420),
         retrievalSelection: AIRetrievalSelection? = nil,
         providerResolver: ((AIProviderRequestTicket) async throws -> any AIToolCallingProvider)? = nil) {
        self.storage = storage ?? .shared
        self.configuration = configuration ?? .shared
        self.service = service ?? AIHighlightWorkflowService(traceRecorder: traceRecorder)
        self.trace = traceRecorder
        self.commands = commands ?? .shared
        self.requestTimeout = requestTimeout
        self.providerResolver = providerResolver
        self.retrievalSelection = retrievalSelection
    }

    var cloudAvailable: Bool {
        let value = configuration.configuration
        return value.isCloudAIEnabled && value.hasCloudConsent
            && value.cloudConsentVersion == AIProviderConfiguration.currentCloudConsentVersion
            && configuration.isAPIKeyConfigured && !value.model.isEmpty
    }

    func setError(_ error: String?, sessionID: UUID) { errors[sessionID] = error }

    func cancel(sessionID: UUID) {
        guard let progress = jobs[sessionID] else { return }
        finishFailure(CancellationError(), sessionID: sessionID, requestID: progress.requestID,
                      cause: "user_cancelled", cancelTask: true)
    }

    func shutdown() {
        for id in Array(jobs.keys) { cancel(sessionID: id) }
        storage.interruptActiveRequests()
        storage.retryFailedSaves()
    }

    func send(sessionID: UUID, library: LibraryStore, mainStore: PDFDocumentStore?,
              viewID: UUID, textOnly: Bool = false) {
        guard jobs[sessionID] == nil, let session = storage.session(id: sessionID),
              session.activeRequestID == nil else { return }
        errors[sessionID] = nil
        let draft = session.draft
        var sentDraft = draft
        if textOnly { sentDraft.blocks.removeAll { $0.kind == .image } }
        let annotationChoice = sessionAllowsAnnotations(sessionID)
        let question = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = !cloudAvailable && question.isEmpty && draft.blocks.isEmpty
        let members = session.sourceSelection.groupID.map { library.files(in: $0).map(\.id) } ?? []
        let sourceIDs = session.sourceSelection.expandedFileIDs(groupMembers: members)
        let sourceSet = Set(sourceIDs)
        let imageIDs = textOnly ? [] : draft.blocks.compactMap { $0.attachmentID ?? $0.evidence?.attachmentID }
        do {
            guard cloudAvailable || local else { throw ResearchRuntimeError.configureProvider }
            guard !sourceIDs.isEmpty || !imageIDs.isEmpty else { throw ResearchRuntimeError.noSources }
            guard sourceIDs.count <= 100 else { throw ResearchRuntimeError.inputTooLarge }
            guard draft.blocks.allSatisfy({ block in
                guard !block.kind.isDiscussionBackground,
                      let id = block.evidence?.source?.fileID ?? block.fileID else { return true }
                return sourceSet.contains(id)
            }) else { throw ResearchRuntimeError.sourceOutsideScope }
            guard imageIDs.isEmpty || configuration.configuration.imageCapability == .supported else {
                throw ResearchRuntimeError.imagesUnavailable
            }
            guard draft.text.count + draft.blocks.reduce(0, { $0 + $1.text.count + $1.explanation.count }) <= 24_000,
                  imageIDs.count <= ResearchInputLimits.maximumImages else { throw ResearchRuntimeError.inputTooLarge }
            let images = try loadImages(ids: imageIDs)
            let ticket = configuration.captureProviderRequest()
            let retrieval = local ? AIRetrievalSelection.lexical : try retrievalSelection ?? AIRetrievalSelection.capture(from: .standard)
            let resolved = sourceIDs.map { id in
                library.allFiles.first(where: { $0.id == id }).map { file in
                    CapturedFile(file: file, url: library.resolvedURL(for: file))
                }
            }
            let initialSources = zip(sourceIDs, resolved).map { id, value in
                ResearchSourceSnapshot(fileID: id, displayName: value?.file.displayName ?? L10n.string("Unavailable source"), fingerprint: "pending")
            }
            let history = ResearchHistorySelection.select(from: session)
            let contextSummary = ResearchContextSummary.capture(session: session, history: history,
                imageCount: images.count, excludedImageCount: textOnly ? draft.attachmentIDs.count : 0,
                isLocalOutline: local)
            guard let requestID = storage.beginRequest(sessionID: sessionID, question: question,
                sourceSnapshot: initialSources, input: sentDraft,
                contextSummary: contextSummary) else { throw ResearchRuntimeError.persistenceFailed }
            let commandExecutor = local ? nil : commands.makeExecutor(requestID: requestID,
                sessionID: sessionID, viewID: viewID, allowedSources: initialSources,
                question: question, targetNoteID: draft.blocks.last(where: { $0.kind == .note })?.evidence?.noteID)
            let permit = mainStore?.captureWritePermit(requestID: requestID)
            let mainFileID = mainStore.flatMap { library.file(for: $0.selectedPDFURL)?.id }
            jobs[sessionID] = ResearchRequestProgress(requestID: requestID,
                phase: L10n.string("Preparing research sources…"), totalSources: sourceIDs.count)
            let started = Task {
                await trace.record(workflowID: requestID, groupID: requestID,
                    event: .jobStarted(requestKind: question.isEmpty ? .overview : .question,
                        question: question.isEmpty ? nil : question,
                        providerName: local ? "Local outline" : ticket.configuration.name,
                        modelName: local ? "" : ticket.configuration.model))
            }
            requestTraces[sessionID] = RequestTrace(requestID: requestID, started: started)
            timeoutTasks[sessionID] = Task { [weak self] in
                do { try await Task.sleep(for: self?.requestTimeout ?? .seconds(420)) } catch { return }
                guard let self, self.jobs[sessionID]?.requestID == requestID else { return }
                self.finishFailure(ResearchRuntimeError.requestTimedOut, sessionID: sessionID,
                                   requestID: requestID, cause: "request_timeout", cancelTask: true)
            }
            tasks[sessionID] = Task {
                await started.value
                var requestContext = contextSummary
                defer {
                    commands.end(requestID: requestID)
                }
                do {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(180))
                    var sources: [PreparedSource] = []
                    var skipped: [String] = []
                    for (index, file) in resolved.enumerated() {
                        try ensureActive(sessionID, requestID)
                        if ContinuousClock.now >= deadline {
                            skipped += initialSources[index...].map { $0.displayName + ": " + L10n.string("Preparation time limit") }
                            requestContext.skippedSources += initialSources[index...].map {
                                ResearchSourceOmission(fileID: $0.fileID, reason: L10n.string("Preparation time limit"))
                            }
                            break
                        }
                        guard let file else {
                            skipped.append(initialSources[index].displayName + ": " + L10n.string("Removed from Library"))
                            requestContext.skippedSources.append(ResearchSourceOmission(fileID: initialSources[index].fileID,
                                reason: L10n.string("Removed from Library")))
                            continue
                        }
                        do {
                            let read: PDFSourceReadSnapshot
                            let snapshot: AIHighlightTextSnapshot
                            let preparedRecords: [AISegmentRecord]?
                            if local {
                                read = try DocumentAccessCoordinator.shared.readSnapshot(
                                    fileID: file.file.id,
                                    originalURL: file.url,
                                    workingCopyURL: file.file.workingCopyURL
                                )
                                snapshot = try await NativePDFTextSnapshotBuilder(document: read.document)
                                    .makeTextSnapshotCooperatively()
                                preparedRecords = nil
                            } else {
                                let prepared = try await AIRetrievalSourcePreparer().prepare(
                                    fileID: file.file.id,
                                    originalURL: file.url,
                                    workingCopyURL: file.file.workingCopyURL
                                )
                                read = prepared.read
                                snapshot = prepared.snapshot
                                preparedRecords = prepared.records
                            }
                            try ensureActive(sessionID, requestID)
                            let hasRegionImage = !textOnly && draft.blocks.contains { $0.kind == .image && $0.evidence?.source?.fileID == file.file.id }
                            if !local && !hasRegionImage && snapshot.pages.allSatisfy({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                                skipped.append(file.file.displayName + ": " + L10n.string("No native text; OCR is not enabled"))
                                requestContext.skippedSources.append(ResearchSourceOmission(fileID: file.file.id,
                                    reason: L10n.string("No native text; OCR is not enabled")))
                                continue
                            }
                            sources.append(PreparedSource(
                                file: file,
                                read: read,
                                snapshot: snapshot,
                                preparedRecords: preparedRecords
                            ))
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            skipped.append(file.file.displayName + ": " + AIHighlightFailureMessage.userMessage(for: error))
                            requestContext.skippedSources.append(ResearchSourceOmission(fileID: file.file.id,
                                reason: AIHighlightFailureMessage.userMessage(for: error)))
                        }
                        jobs[sessionID]?.preparedSources = sources.count
                        jobs[sessionID]?.skippedSources = skipped
                        await Task.yield()
                    }
                    try ensureActive(sessionID, requestID)
                    try validateInputVersions(draft: sentDraft, sources: sources)
                    let preparedByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.file.file.id, $0.researchSource) })
                    let persistedSources = initialSources.map { preparedByID[$0.fileID] ?? $0 }
                    requestContext.preparedFileIDs = sources.map { $0.file.file.id }
                    if var current = storage.session(id: sessionID),
                       let index = current.messages.firstIndex(where: { $0.requestID == requestID }) {
                        current.messages[index].sourceSnapshot = persistedSources
                        current.messages[index].operationResults = skipped
                        current.messages[index].contextSummary = requestContext
                        guard storage.updateSession(current) else { throw ResearchRuntimeError.persistenceFailed }
                    }
                    guard !sources.isEmpty || !images.isEmpty else { throw ResearchRuntimeError.noSources }
                    if local {
                        var output: [String] = []
                        for source in sources {
                            let outline = await DocumentOutlineService().outline(for: source.read.document)
                            output.append(try AILocalOutlineFallback.answer(documentName: source.file.file.displayName,
                                snapshot: source.snapshot, entries: outline).resultMarkdown)
                            try ensureActive(sessionID, requestID)
                        }
                        try validateSources(sources)
                        try ensureActive(sessionID, requestID)
                        let saved = storage.finishRequest(sessionID: sessionID, requestID: requestID,
                            answer: output.joined(separator: "\n\n"), status: .accepted,
                            origin: .localOutline, operationResults: coverageResults(total: sourceIDs.count, sources: sources, used: [], skipped: skipped),
                            contextSummary: requestContext)
                        finishTrace(sessionID: sessionID, requestID: requestID, status: .accepted,
                                    cause: "local_outline", saved: saved)
                    } else {
                        jobs[sessionID]?.phase = L10n.string("Preparing credentials; check for a macOS Keychain prompt…")
                        let provider: any AIToolCallingProvider
                        if let providerResolver { provider = try await providerResolver(ticket) }
                        else { provider = try await configuration.toolCallingProvider(for: ticket) }
                        try ensureActive(sessionID, requestID)
                        let mainNumber = mainFileID.flatMap { id in sources.firstIndex { $0.file.file.id == id }.map { $0 + 1 } }
                        let allows = annotationChoice && permit != nil && mainNumber != nil
                        let discussion = discussionContext(history: history, draft: draft, skipped: skipped,
                            requestedCount: sourceIDs.count, textOnly: textOnly)
                        guard discussion.count <= 40_000 else { throw ResearchRuntimeError.inputTooLarge }
                        guard let commandExecutor else { throw ResearchCommandError.inactiveRequest }
                        try commands.prepareSources(requestID: requestID,
                            sources: sources.map(\.researchSource))
                        let result = try await service.generateReadingResult(
                            sources: sources.map { AIWorkflowSourceSnapshot(fileID: $0.file.file.id,
                                displayName: $0.file.file.displayName,
                                snapshot: $0.snapshot,
                                version: $0.read.contentVersion,
                                preparedRecords: $0.preparedRecords) },
                            mainDocumentNumber: mainNumber,
                            intent: question.isEmpty ? .overview : .question(question),
                            discussionContext: discussion,
                            images: images,
                            additionalTools: commandExecutor.definitions, additionalExecutor: commandExecutor,
                            provider: provider, workflowID: requestID, retrieval: retrieval,
                            allowsAnnotations: allows, verifiesAnswerEvidence: true,
                            indexingProgress: { completed, total in
                                await self.indexProgress(sessionID, requestID, completed: completed, total: total)
                            },
                            progress: { event in await self.apply(event, sessionID: sessionID, requestID: requestID) },
                            publication: { answer in
                                await self.interim(answer, sessionID: sessionID, requestID: requestID)
                            }
                        )
                        try ensureActive(sessionID, requestID)
                        try validateSources(sources)
                        let evidence = makeEvidence(result: result, sources: sources, draft: draft)
                        let indexedIDs = Set(result.sourceCoverage.preparedFileIDs)
                        requestContext.retrievalFileIDs = result.sourceCoverage.preparedFileIDs
                        requestContext.skippedSources += result.sourceCoverage.skipped.map {
                            ResearchSourceOmission(fileID: $0.fileID, reason: $0.reason)
                        }
                        let indexSkipped = result.sourceCoverage.skipped.map { item in
                            (sources.first(where: { $0.file.file.id == item.fileID })?.file.file.displayName
                                ?? L10n.string("Unavailable source")) + ": " + item.reason
                        }
                        var operations = coverageResults(total: sourceIDs.count,
                            sources: sources.filter { indexedIDs.contains($0.file.file.id) },
                            used: Set(evidence.compactMap { $0.source?.fileID }), skipped: skipped + indexSkipped)
                        if !result.highlights.isEmpty {
                            do {
                                guard let mainStore, let permit else { throw DocumentAccessError.editorUnavailable }
                                try mainStore.validateWritePermit(permit)
                                guard let document = mainStore.document else { throw DocumentAccessError.editorUnavailable }
                                let anchors = try await AIHighlightNativeAnchorResolver().resolveCooperatively(
                                    result.highlights, registry: result.registry, in: document)
                                try ensureActive(sessionID, requestID)
                                try validateSources(sources)
                                let group = AIHighlightGroup(id: requestID, requestKind: question.isEmpty ? .overview : .question,
                                    title: result.answer.title, question: question.isEmpty ? nil : question,
                                    providerName: ticket.configuration.name, modelName: ticket.configuration.model,
                                    promptVersion: AIHighlightWorkflowService.promptVersion)
                                let count = try mainStore.applyAIHighlights(stagedHighlights: result.highlights,
                                    anchors: anchors, group: group, trigger: .pointer, writePermit: permit)
                                operations.append(L10n.string("Highlights added") + ": \(count)")
                            } catch is CancellationError { throw CancellationError() }
                            catch {
                                operations.append(AIHighlightFailureMessage.optionalHighlightsMessage(for: error))
                            }
                        }
                        try ensureActive(sessionID, requestID)
                        operations += commands.complete(requestID: requestID,
                            acceptedAnswer: result.answer.resultMarkdown, evidence: evidence)
                        let saved = storage.finishRequest(sessionID: sessionID, requestID: requestID,
                            answer: result.answer.resultMarkdown, evidence: evidence, status: .accepted,
                            operationResults: operations, contextSummary: requestContext)
                        finishTrace(sessionID: sessionID, requestID: requestID, status: .accepted,
                                    cause: "completed", saved: saved)
                    }
                } catch {
                    finishFailure(error, sessionID: sessionID, requestID: requestID)
                }
            }
        } catch { errors[sessionID] = AIHighlightFailureMessage.userMessage(for: error) }
    }

    private func finishFailure(_ error: Error, sessionID: UUID, requestID: UUID,
                               cause: String? = nil, cancelTask: Bool = false) {
        guard jobs[sessionID]?.requestID == requestID else { return }
        let cancelled = AIHighlightFailureMessage.kind(of: error) == .cancellation
        let status: ResearchRequestStatus = cancelled ? .cancelled : .failed
        let message = AIHighlightFailureMessage.userMessage(for: error)
        errors[sessionID] = message
        commands.cancel(requestID: requestID)
        let saved = storage.finishRequest(sessionID: sessionID, requestID: requestID,
                                          status: status, errorMessage: message)
        finishTrace(sessionID: sessionID, requestID: requestID, status: status,
                    cause: cause ?? AIHighlightFailureMessage.code(for: error), saved: saved,
                    cancelTask: cancelTask)
    }

    private func finishTrace(sessionID: UUID, requestID: UUID, status: ResearchRequestStatus,
                             cause: String, saved: Bool, cancelTask: Bool = false) {
        guard let lifecycle = requestTraces[sessionID], lifecycle.requestID == requestID else { return }
        requestTraces.removeValue(forKey: sessionID)
        jobs.removeValue(forKey: sessionID)
        let task = tasks.removeValue(forKey: sessionID)
        if cancelTask { task?.cancel() }
        timeoutTasks.removeValue(forKey: sessionID)?.cancel()
        Task {
            await lifecycle.started.value
            await trace.record(workflowID: requestID, groupID: requestID,
                event: .requestFinished(status: status.rawValue, cause: cause, saved: saved,
                                        cancellationRequested: cancelTask))
        }
    }

    /// Per-session preference; captured by send and never changed by a model tool.
    func sessionAllowsAnnotations(_ id: UUID) -> Bool {
        UserDefaults.standard.object(forKey: "PDFWorkBench.Research.AllowAnnotations.\(id.uuidString)") as? Bool ?? false
    }
    func setAllowsAnnotations(_ value: Bool, sessionID: UUID) {
        UserDefaults.standard.set(value, forKey: "PDFWorkBench.Research.AllowAnnotations.\(sessionID.uuidString)")
        objectWillChange.send()
    }

    private struct CapturedFile { let file: LibraryFile; let url: URL }
    private struct PreparedSource {
        let file: CapturedFile
        let read: PDFSourceReadSnapshot
        let snapshot: AIHighlightTextSnapshot
        let preparedRecords: [AISegmentRecord]?
        var researchSource: ResearchSourceSnapshot {
            ResearchSourceSnapshot(fileID: file.file.id, displayName: file.file.displayName, fingerprint: read.contentVersion)
        }
    }

    private func ensureActive(_ sessionID: UUID, _ requestID: UUID) throws {
        try Task.checkCancellation()
        guard jobs[sessionID]?.requestID == requestID,
              storage.session(id: sessionID)?.activeRequestID == requestID else { throw CancellationError() }
    }

    private func loadImages(ids: [UUID]) throws -> [AIToolInputImage] {
        var seen = Set<UUID>()
        let images = try ids.filter { seen.insert($0).inserted }.map { id in
            guard let attachment = storage.attachments.first(where: { $0.id == id }),
                  let url = storage.attachmentURL(id: id) else { throw ResearchStoreError.missingAttachment }
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch let error as CocoaError where [CocoaError.Code.fileNoSuchFile, .fileReadNoSuchFile, .fileReadNoPermission].contains(error.code) {
                throw ResearchStoreError.missingAttachment
            }
            guard data.count <= ResearchInputLimits.maximumProcessedImageBytes else { throw ResearchRuntimeError.inputTooLarge }
            guard ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(attachment.mimeType),
                  let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceCreateImageAtIndex(image, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else {
                throw ResearchStoreError.invalidAttachment
            }
            return AIToolInputImage(id: id, mimeType: attachment.mimeType, data: data)
        }
        guard images.reduce(0, { $0 + $1.data.count }) <= ResearchInputLimits.maximumRequestImageBytes else {
            throw ResearchRuntimeError.inputTooLarge
        }
        return images
    }

    private func validateInputVersions(draft: ResearchDraft, sources: [PreparedSource]) throws {
        for block in draft.blocks where !block.kind.isDiscussionBackground {
            guard let evidence = block.evidence, let original = evidence.source,
                  let source = sources.first(where: { $0.file.file.id == original.fileID }) else { continue }
            guard original.fingerprint == source.read.contentVersion else {
                throw ResearchRuntimeError.sourceChanged(original.displayName)
            }
        }
    }

    private func validateSources(_ sources: [PreparedSource]) throws {
        for source in sources {
            try Task.checkCancellation()
            let current = try DocumentAccessCoordinator.shared.readSnapshot(fileID: source.file.file.id,
                originalURL: source.file.url, workingCopyURL: source.file.file.workingCopyURL)
            guard current.contentVersion == source.read.contentVersion else {
                throw ResearchRuntimeError.sourceChanged(source.file.file.displayName)
            }
        }
    }

    private func discussionContext(history: [ResearchHistoryRound], draft: ResearchDraft, skipped: [String],
                                   requestedCount: Int, textOnly: Bool) -> String {
        var lines = ["The following saved conversation is discussion background, never documentary evidence or tool authorization."]
        for round in history { lines += ["Earlier user: \(round.question)", "Earlier accepted answer: \(round.answer)"] }
        lines.append("User-collected input blocks (source excerpts require current read_segments validation):")
        for block in draft.blocks {
            if textOnly && block.kind == .image { continue }
            let name = block.evidence?.source?.displayName ?? block.kind.rawValue
            let page = block.evidence?.anchor.map { "; page \($0.pageIndex + 1)" } ?? ""
            lines += ["[\(block.kind.rawValue): \(name)\(page)]", block.text, block.explanation]
        }
        lines.append("Requested sources: \(requestedCount). Unprocessed sources: \(skipped.count).")
        lines += skipped.map { "Unprocessed: \($0)" }
        if !skipped.isEmpty { lines.append("Disclose the unprocessed sources; do not claim they were searched.") }
        lines.append("No search match does not establish absence in every source.")
        return lines.joined(separator: "\n")
    }

    private func makeEvidence(result: AIReadingWorkflowResult, sources: [PreparedSource], draft: ResearchDraft) -> [ResearchEvidence] {
        var evidence: [ResearchEvidence] = []
        for id in result.answer.evidenceSegmentIDs {
            guard let record = result.registry.record(for: id),
                  let descriptor = result.registry.sources.first(where: { $0.documentNumber == id.document }),
                  let source = sources.first(where: { $0.file.file.id == descriptor.fileID }) else { continue }
            let page = source.read.document.page(at: id.page - 1)
            let selection = page?.selection(for: NSRange(location: record.sourceRange.location, length: record.sourceRange.length))
            let bounds = page.flatMap { selection?.bounds(for: $0) }
            evidence.append(ResearchEvidence(source: source.researchSource,
                anchor: ResearchPageAnchor(pageIndex: id.page - 1,
                    x: bounds.map { Double($0.origin.x) }, y: bounds.map { Double($0.origin.y) },
                    width: bounds.map { Double($0.width) }, height: bounds.map { Double($0.height) },
                    pageFingerprint: record.pageFingerprint),
                excerpt: record.text))
        }
        for id in result.answer.evidenceImageIDs {
            if var item = draft.blocks.first(where: { ($0.attachmentID ?? $0.evidence?.attachmentID) == id })?.evidence {
                item.kind = .image
                item.attachmentID = id
                evidence.append(item)
            } else {
                evidence.append(ResearchEvidence(source: nil, kind: .image, excerpt: L10n.string("User image"), attachmentID: id))
            }
        }
        return evidence
    }

    private func coverageResults(total: Int, sources: [PreparedSource], used: Set<UUID>, skipped: [String]) -> [String] {
        [L10n.string("Source coverage") + ": \(sources.count)/\(total); " + L10n.string("Cited files") + ": \(used.count)"]
            + skipped.map { L10n.string("Not processed") + ": " + $0 }
    }

    private func indexProgress(_ sessionID: UUID, _ requestID: UUID, completed: Int, total: Int) {
        guard jobs[sessionID]?.requestID == requestID else { return }
        jobs[sessionID]?.phase = L10n.string("Preparing evidence index…") + " \(completed)/\(total)"
    }

    private func interim(_ answer: AIPublishedAnswer, sessionID: UUID, requestID: UUID) {
        guard jobs[sessionID]?.requestID == requestID, !answer.terminate else { return }
        jobs[sessionID]?.interimAnswer = answer.resultMarkdown
    }

    private func apply(_ event: AIWorkflowEvent, sessionID: UUID, requestID: UUID) {
        guard jobs[sessionID]?.requestID == requestID else { return }
        switch event {
        case .providerTurnStarted(let index):
            jobs[sessionID]?.providerTurns = index + 1
            jobs[sessionID]?.phase = L10n.string("Waiting for the AI provider…")
        case .providerTurnFinished(_, _, let tokens, _, _):
            if let tokens { jobs[sessionID]?.inputTokens = (jobs[sessionID]?.inputTokens ?? 0) + tokens }
        case .toolStarted(_, let name, _):
            jobs[sessionID]?.toolCalls += 1
            jobs[sessionID]?.phase = AIHighlightProgressPhase.phase(forToolName: name).localizedDescription
        case .toolFinished(_, _, _, let count): jobs[sessionID]?.readCharacters += count
        case .evidenceReviewStarted: jobs[sessionID]?.phase = L10n.string("Reviewing answer evidence…")
        case .retryScheduled: jobs[sessionID]?.phase = L10n.string("Retrying provider request…")
        default: break
        }
    }
}
