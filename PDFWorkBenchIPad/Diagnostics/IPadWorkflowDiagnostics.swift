#if os(iOS)
import PDFKit
import UIKit

/// Executes the actual shared application services against disposable files.
/// Only native presentation, provider and credential endpoints are test doubles.
@MainActor
enum IPadWorkflowDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        func merge(_ name: String, _ result: (checks: Int, failures: [String])) {
            checks += result.checks
            failures += result.failures.map { "\(name): \($0)" }
        }
        merge("UIKit reader", await PDFReaderUIKitDiagnostics.run())
        merge("UIKit input", await PDFReaderUIKitInputDiagnostics.run())
        merge("Workspace identity and input lifecycle", await IPadWorkspaceInputDiagnostics.run())
        merge("Research native text", await IPadResearchTextEditorDiagnostics.run())
        merge("Research presentation", await IPadResearchPresentationDiagnostics.run())
        merge("Window tabs", await IPadWindowTabsDiagnostics.run())
        merge("Research composer", await IPadResearchComposerDiagnostics.run())
        merge("Inline note editor", await IPadInlineNoteEditorDiagnostics.run())
        merge("Inline note draft recovery", await IPadInlineNoteDraftRecoveryDiagnostics.run())
        merge("Highlight draft recovery", await IPadHighlightDraftRecoveryDiagnostics.run())
        merge("Draft conflicts, cold Undo and performance", await IPadDraftBoundaryDiagnostics.run())
        merge("Export and background lifecycle", await IPadExportLifecycleDiagnostics.run())
        let importReport = await LibraryImportDiagnostics.run()
        merge("Library import", (importReport.checkCount, importReport.failures))
        merge("BM25 retrieval", await AILexicalPlatformDiagnostics.run())
        merge("Saved note evidence", ResearchNoteEvidenceContextDiagnostics.run())
        do { merge("Managed copy relocation", try WorkingCopyRelocationDiagnostics.run()) }
        catch { expect(false, "Managed copy relocation fixture failed: \(error)") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearIPadWorkflow-\(UUID())")
        let suiteName = "DogearIPadWorkflow.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return (checks + 1, failures + ["Could not create isolated defaults."])
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            let firstURL = root.appendingPathComponent("first/same.pdf")
            let secondURL = root.appendingPathComponent("second/same.pdf")
            for url in [firstURL, secondURL] {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fixtureData().write(to: url)
            }
            let originalBytes = try Data(contentsOf: firstURL)
            let secondOriginalBytes = try Data(contentsOf: secondURL)
            let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
            let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("recovery"))
            let access = DocumentAccessCoordinator(saveQueue: queue)
            let persistence = try LibraryJSONStore(stateURL: root.appendingPathComponent("library.json"))
            let library = LibraryStore(userDefaults: defaults, storage: persistence, workingCopyStore: copies)
            let group = try required(library.createGroup(named: "Synthetic Group"))
            let files = library.upsertOpenedURLs([firstURL, secondURL], refreshBookmark: false, groupID: group.id)
            expect(files.count == 2 && files[0].id != files[1].id,
                   "Same-name documents retain distinct Library identities.")
            expect(library.files(in: group.id).map(\.id) == files.map(\.id),
                   "Import preserves source order and Group membership.")
            let presenter = CapturingExportPresenter()
            let store = PDFDocumentStore(feedbackCenter: OperationFeedbackCenter(userDefaults: defaults),
                metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("metadata.json")),
                aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("groups.json")),
                workingCopyStore: copies, saveQueue: queue, accessCoordinator: access, exportPresenter: presenter)
            defer { store.releaseEditorAccess() }
            let undo = UndoManager()
            undo.groupsByEvent = false
            store.setUndoManager(undo)
            expect(store.openPDF(from: firstURL) && store.bindLibraryFile(files[0].id),
                   "The shared store opens and binds an imported source.")
            expect(store.currentWorkingCopyURL == nil && !store.hasUnsavedChanges,
                   "Opening creates no working copy or dirty state.")
            let document = try required(store.document)
            let selection = try required(document.findString("Orchard findings", withOptions: []).first)
            store.recordTextSelection(PDFTextSelectionService.snapshot(of: selection, in: document))
            expect(store.currentTextSelection?.pageNumbers == [1],
                   "The shared store accepts native selection context for Research.")
            undo.beginUndoGrouping()
            let highlighted = store.addHighlights(from: selection, in: document)
            undo.endUndoGrouping()
            expect(highlighted && store.annotations.filter { $0.kind == .highlight }.count == 1,
                   "A manual highlight is committed through the shared owner.")
            let highlight = try required(document.page(at: 0)?.annotations.first { $0.type == "Highlight" })
            expect(highlight.quadrilateralPoints?.isEmpty == false && highlight.contents == nil,
                   "The highlight is a standard quadrilateral annotation with no invented note.")
            undo.undo()
            expect(highlight.page == nil && store.annotations.isEmpty,
                   "One Undo removes the exact native highlight.")
            undo.redo()
            expect(highlight.page === document.page(at: 0), "Redo restores the same native annotation identity.")
            let foreign = try required(PDFDocument(data: originalBytes))
            let foreignSelection = try required(foreign.findString("Orchard findings", withOptions: []).first)
            expect(!store.addHighlights(from: foreignSelection, in: document),
                   "A foreign selection cannot mutate the active document.")
            await queue.drain()
            await deliverCompletions()
            let workingCopy = try required(store.currentWorkingCopyURL)
            expect(!queue.hasUnrecoverablePendingWrites && queue.pendingDestinations.isEmpty && !store.hasUnsavedChanges,
                   "Async drain completes the working-copy save and clears dirty state.")
            expect(try Data(contentsOf: firstURL) == originalBytes, "Highlight saving preserves original PDF bytes.")
            library.updateWorkingCopyURL(workingCopy, for: files[0])

            let draft = try required(store.newFreeTextDraft())
            expect(draft.isNew && draft.annotation.page == nil,
                   "A new note remains detached while its form is open.")
            var values = draft.values
            values.text = "Synthetic iPad note"
            undo.beginUndoGrouping()
            let savedNote = store.saveFreeText(draft, values: values)
            undo.endUndoGrouping()
            expect(savedNote && draft.annotation.page === document.page(at: 0),
                   "Explicit note Save commits a standard FreeText annotation.")
            expect(draft.annotation.shouldDisplay, "A standard note is visible in the native UIKit reader.")
            undo.undo()
            expect(draft.annotation.page == nil, "Undo removes the new note.")
            undo.redo()
            expect(draft.annotation.page === document.page(at: 0), "Redo restores the same FreeText note.")
            let existingNote = try required(store.annotations.first { $0.kind == .note })
            let edit = try required(store.freeTextEditDraft(for: existingNote))
            var editedValues = edit.values
            editedValues.text = "Edited synthetic iPad note"
            undo.beginUndoGrouping()
            expect(store.saveFreeText(edit, values: editedValues), "The existing note uses the same validated Save boundary.")
            undo.endUndoGrouping()
            undo.undo()
            expect(draft.annotation.contents == values.text, "Note edit Undo restores the previous text.")
            undo.redo()
            expect(draft.annotation.contents == editedValues.text, "Note edit Redo restores the changed text.")

            store.currentPageIndex = 1
            store.deleteCurrentPageFromWorkingCopy()
            expect(store.pendingConfirmation != nil && store.pageCount == 3,
                   "Page deletion waits for explicit confirmation.")
            store.pendingConfirmation = nil
            expect(store.pageCount == 3, "Cancelling page deletion preserves every page.")
            store.deleteCurrentPageFromWorkingCopy()
            let confirmation = try required(store.pendingConfirmation)
            store.pendingConfirmation = nil
            undo.beginUndoGrouping()
            confirmation.onConfirm()
            undo.endUndoGrouping()
            expect(store.pageCount == 2, "Confirmed deletion updates only the working document.")
            confirmation.onConfirm()
            expect(store.pageCount == 2, "A consumed confirmation cannot repeat its deletion.")
            undo.undo()
            expect(store.pageCount == 3, "Undo restores the deleted page.")
            undo.redo()
            expect(store.pageCount == 2, "Redo preserves the confirmed deletion as one operation.")
            undo.undo()
            await queue.drain()
            await deliverCompletions()

            merge("Page region capture", IPadResearchRegionCaptureDiagnostics.run(
                library: library, store: store, access: access, root: root))

            store.exportAnnotatedCopy()
            let exported = try required(presenter.requests.last)
            let immutableBytes = exported.data
            expect(exported.protectedOriginalURL == firstURL, "A delayed export protects its captured original URL.")
            do {
                try exported.write(to: firstURL)
                expect(false, "Export accepted its protected original as the destination.")
            } catch SafeDocumentExportError.originalDestination { expect(true, "") }
            let target = root.appendingPathComponent("annotated.pdf")
            try exported.write(to: target)
            let roundTrip = try required(PDFDocument(url: target))
            expect(roundTrip.pageCount == 3 && AnnotationExtractor.annotationItems(in: roundTrip).count == 2,
                   "Export round-trips the selected standard highlight and edited note.")
            expect(roundTrip.page(at: 0)?.annotations.first { $0.type == "FreeText" }?.shouldDisplay == true,
                   "Export preserves visible standard note appearance.")
            store.exportAnnotationsMarkdown(scope: .all)
            let markdown = String(decoding: try required(presenter.requests.last).data, as: UTF8.self)
            expect(markdown.contains("Orchard findings") && markdown.contains(editedValues.text),
                   "Markdown exports both the highlight quote and note.")
            presenter.cancelAll()
            expect(store.openPDF(from: secondURL) && store.bindLibraryFile(files[1].id),
                   "A second imported document can become the active editing source.")
            expect(exported.data == immutableBytes && exported.protectedOriginalURL == firstURL,
                   "Switching documents cannot redirect prepared export bytes or original protection.")
            expect(!store.saveFreeText(draft, values: values) && !store.addHighlights(from: selection, in: document),
                   "An old editor draft or selection cannot mutate the replacement PDF.")
            expect(try Data(contentsOf: firstURL) == originalBytes && Data(contentsOf: secondURL) == secondOriginalBytes,
                   "All shared mutations and exports preserve both originals.")
            library.updateLastPage(for: firstURL, pageIndex: 2)
            try library.updateTags(["fixture"], for: [files[0].id])
            expect(library.flushPendingPersistence(), "Library transactions and reading position drain successfully.")
            let reloaded = LibraryStore(userDefaults: defaults, storage: persistence, workingCopyStore: copies)
            expect(reloaded.files(in: group.id).map(\.id) == files.map(\.id), "Group membership and ordering survive reload.")
            expect(reloaded.file(for: firstURL)?.lastPageIndex == 2 && reloaded.file(for: firstURL)?.tags == ["fixture"],
                   "Reading position and tags survive reload.")
            let restoredCopy = reloaded.file(for: firstURL)?.workingCopyURL
            expect(restoredCopy?.resolvingSymlinksInPath().standardizedFileURL.path ==
                   workingCopy.resolvingSymlinksInPath().standardizedFileURL.path &&
                   restoredCopy.flatMap { PDFDocument(url: $0) }?.pageCount == 3,
                   "Library reload retains the active app-managed working-copy path and readable PDF: restored=\(restoredCopy?.path ?? "nil"), expected=\(workingCopy.path).")
            expect(store.openPDF(from: firstURL, workingCopyURL: workingCopy), "The first source reopens its saved working copy.")
            expect(store.annotations.count == 2 && store.pageCount == 3,
                   "Reopening restores annotations and the final undone page operation.")
            await exerciseResearch(root: root, defaults: defaults, library: reloaded,
                files: files, expect: expect)
            await queue.drain()
            await deliverCompletions()
            expect(!access.hasUnrecoverableChanges, "The workflow leaves no unrecoverable PDF save state.")
        } catch {
            expect(false, "Shared workflow fixture could not complete: \(error.localizedDescription)")
        }
        return (checks, failures)
    }

    private static func exerciseResearch(root: URL, defaults: UserDefaults, library: LibraryStore,
                                         files: [LibraryFile], expect: (Bool, String) -> Void) async {
        do {
            let researchRoot = root.appendingPathComponent("research")
            let storage = ResearchStore(rootURL: researchRoot)
            try exerciseImageExport(root: root, storage: storage, expect: expect)
            let configuration = AIConfigurationStore(configurationURL: root.appendingPathComponent("synthetic-ai.json"),
                legacyUserDefaults: defaults, secretStore: EmptySecrets())
            var configured = configuration.configuration
            configured.name = "Synthetic fixture"
            configured.baseURL = "https://fixture.invalid/v1"
            configured.model = "fixture"
            configured.hasCloudConsent = true
            configured.isCloudAIEnabled = true
            configured.secretStorageMode = .plaintextFile
            configuration.configuration = configured
            try configuration.saveAPIKey("synthetic-unused-key")
            let sourceDocument = try required(PDFDocument(url: files[0].url))
            let snapshot = try NativePDFTextSnapshotBuilder(document: sourceDocument).makeTextSnapshot()
            let registry = try AISegmentRegistry(snapshot: snapshot)
            let segment = try required(registry.records.first?.id.description)
            let provider = SyntheticResearchProvider(segmentID: segment)
            let trace = AIHighlightTraceRecorder(fileURL: root.appendingPathComponent("trace.jsonl"), defaults: defaults)
            let runtime = ResearchRuntime(storage: storage, configuration: configuration, traceRecorder: trace,
                commands: ResearchCommandService(store: storage), retrievalSelection: .lexical,
                providerResolver: { _ in provider })
            defer { runtime.shutdown() }
            let sessionID = storage.createSession(title: "Compare fixed sources",
                sourceSelection: ResearchSourceSelection(fileIDs: files.map(\.id)))
            _ = storage.saveDraft(ResearchDraft(text: "Explain the synthetic orchard finding."), sessionID: sessionID)
            runtime.send(sessionID: sessionID, library: library, mainStore: nil, viewID: UUID())
            // The request must retain its original catalog if the visible
            // session's future source selection changes during preparation.
            if var session = storage.session(id: sessionID) {
                session.sourceSelection.fileIDs.reverse()
                _ = storage.updateSession(session)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(12))
            while runtime.jobs[sessionID] != nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            expect(runtime.jobs[sessionID] == nil, "The synthetic provider finishes within the bounded fixture timeout.")
            let message = storage.session(id: sessionID)?.messages.last
            expect(message?.status == .accepted, "Research accepts a verified answer from the injected synthetic provider.")
            expect(message?.sourceSnapshot.map(\.fileID) == files.map(\.id),
                   "A request freezes its multi-document source order before later source edits.")
            expect(message?.evidence.first?.source?.fileID == files[0].id,
                   "Verified evidence keeps its exact Library source identity.")
            let reload = ResearchStore(rootURL: researchRoot)
            // Research-v1 stores millisecond timestamps as JSON numbers. A
            // multiply/divide round trip can lose a submillisecond floating-point
            // bit; all business fields must still compare exactly.
            expect(persistedMessagesMatch(reload.session(id: sessionID)?.messages,
                   storage.session(id: sessionID)?.messages),
                   "Accepted Research history and source catalog survive a durable reload.")
            expect(reload.session(id: sessionID)?.sourceSelection.fileIDs == files.reversed().map(\.id),
                   "The session's future source selection persists separately from the completed request.")
            if let message, let answer = message.answer {
                let noteID = storage.createNote(title: "Saved finding", body: answer, provenance: [
                    ResearchNoteProvenance(origin: message.origin, sessionID: sessionID,
                        messageID: message.id, evidence: message.evidence)
                ])
                expect(ResearchStore(rootURL: researchRoot).note(id: noteID)?.body == answer,
                       "An accepted answer becomes a durable editable Research note.")
                let markdown = try storage.sessionMarkdown(id: sessionID)
                expect(markdown.contains(answer), "Research Markdown export retains the accepted answer.")
            }
            expect(await provider.beginCount > 0, "The fixture exercises the real provider adapter boundary.")
            expect(EmptySecrets.reads == 0, "The isolated plaintext fixture never resolves a Keychain secret.")
        } catch { expect(false, "Research fixture failed: \(error.localizedDescription)") }
    }

    private static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }

    private static func persistedMessagesMatch(_ actual: [ResearchMessage]?, _ expected: [ResearchMessage]?) -> Bool {
        guard let actual, var expected, actual.count == expected.count else { return false }
        for index in actual.indices {
            guard abs(actual[index].createdAt.timeIntervalSince(expected[index].createdAt)) < 0.001 else { return false }
            switch (actual[index].completedAt, expected[index].completedAt) {
            case let (actual?, expected?):
                guard abs(actual.timeIntervalSince(expected)) < 0.001 else { return false }
            case (nil, nil): break
            default: return false
            }
            expected[index].createdAt = actual[index].createdAt
            expected[index].completedAt = actual[index].completedAt
        }
        return actual == expected
    }

    private static func exerciseImageExport(root: URL, storage: ResearchStore, expect: (Bool, String) -> Void) throws {
        let id = storage.createSession(title: "Synthetic image fixture")
        let imageURL = root.appendingPathComponent("synthetic.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        try required(image.pngData()).write(to: imageURL)
        try ResearchImageImportRequest(sessionID: id).importURL(imageURL, store: storage)
        let session = try required(storage.session(id: id))
        let attachmentID = try required(session.draft.attachmentIDs.first)
        expect(session.draft.blocks.last?.attachmentID == attachmentID,
               "Native image import creates a durable attachment-backed draft block.")
        let attachmentURL = try required(storage.attachmentURL(id: attachmentID))
        let bytes = try Data(contentsOf: attachmentURL)
        let reloaded = ResearchStore(rootURL: try required(storage.rootURL))
        expect(reloaded.session(id: id)?.draft == session.draft && reloaded.attachmentURL(id: attachmentID) != nil,
               "Image input and its attachment survive Research reload.")
        let sessionExport = try IPadResearchTextExport.session(id: id, storage: storage, protectedOriginalURL: imageURL)
        let sessionText = String(decoding: sessionExport.data, as: UTF8.self)
        expect(!sessionText.contains("](attachments/") && sessionText.contains(attachmentID.uuidString),
               "Session text export identifies its image without a dangling relative image link.")
        expect(sessionExport.protectedOriginalURL == imageURL,
               "Text export retains its captured original protection.")
        let noteID = storage.createNote(title: "Image-backed note", body: "Synthetic image observation", attachmentIDs: [attachmentID])
        let noteExport = try IPadResearchTextExport.note(id: noteID, storage: storage)
        let frozenNoteBytes = noteExport.data
        let noteText = String(decoding: frozenNoteBytes, as: UTF8.self)
        expect(!noteText.contains("](attachments/") && noteText.contains(attachmentID.uuidString),
               "Note text export keeps an image identity without a broken package link.")
        if var note = storage.note(id: noteID) {
            note.body = "Later edit"
            _ = storage.updateNote(note)
        }
        expect(noteExport.data == frozenNoteBytes && !noteText.contains("Later edit"),
               "A delayed text export cannot observe a later Research-note edit.")
        expect(try Data(contentsOf: attachmentURL) == bytes && storage.attachmentURL(id: attachmentID) != nil,
               "Text exports preserve the full app-owned image attachment.")
    }

    private static func deliverCompletions() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private static func fixtureData() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            for page in 1...3 {
                context.beginPage()
                ("Orchard findings confirm apple roots. Page \(page)." as NSString).draw(at: CGPoint(x: 72, y: 72),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
    }

    private final class CapturingExportPresenter: DocumentExportPresenting {
        var requests: [DocumentExportRequest] = []
        var completions: [@MainActor (Result<URL?, Error>) -> Void] = []
        func export(_ request: DocumentExportRequest, completion: @escaping @MainActor (Result<URL?, Error>) -> Void) {
            requests.append(request)
            completions.append(completion)
        }
        func cancelAll() {
            let pending = completions
            completions.removeAll()
            pending.forEach { $0(.success(nil)) }
        }
    }

    private final class EmptySecrets: AISecretStoring {
        static var reads = 0
        func readSecret(profileID: UUID) -> String? { Self.reads += 1; return nil }
        func saveSecret(_ secret: String, profileID: UUID, configurationName: String) {}
        func removeSecret(profileID: UUID) {}
        func updateLabel(profileID: UUID, configurationName: String) {}
    }

    private actor SyntheticResearchProvider: AIToolCallingProvider {
        nonisolated let toolCapabilities = AIToolProviderCapabilities(supportsFunctionTools: true,
            supportsStrictToolSchemas: true, supportsResponseContinuation: true, supportsStructuredFinalResult: false)
        let segmentID: String
        var beginCount = 0
        init(segmentID: String) { self.segmentID = segmentID }
        func beginToolWorkflow(_ request: AIToolWorkflowProviderRequest) async throws -> AIToolProviderTurn {
            beginCount += 1
            if request.tools.contains(where: { $0.name == AIAnswerEvidenceReview.toolName }) {
                return turn(AIAnswerEvidenceReview.toolName, """
                {"completion_status":"answered","claims":[{"claim":"Orchard findings confirm apple roots.","status":"supported","evidence_ids":["\(segmentID)"],"reason":"Matches the supplied text."}]}
                """)
            }
            return turn(AIHighlightToolName.readSegments,
                "{\"ids\":[\"\(segmentID)\"],\"context_before\":0,\"context_after\":0}")
        }
        func continueToolWorkflow(_ request: AIToolWorkflowContinuationRequest) async throws -> AIToolProviderTurn {
            turn(AIHighlightToolName.publishAnswer, """
            {"completion_status":"answered","title":"Orchard finding","result_markdown":"Orchard findings confirm apple roots.","evidence_segment_ids":["\(segmentID)"],"evidence_image_ids":[],"final_draft_revision":0,"terminate":true}
            """)
        }
        func discardToolWorkflow(_ workflowID: UUID) async {}
        private func turn(_ name: String, _ arguments: String) -> AIToolProviderTurn {
            .init(responseID: UUID().uuidString, toolCalls: [.init(callID: UUID().uuidString, name: name,
                arguments: Data(arguments.utf8))], structuredFinalResult: nil, inputTokens: 5)
        }
    }
}
#endif
