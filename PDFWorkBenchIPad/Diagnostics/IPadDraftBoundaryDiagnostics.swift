#if os(iOS)
import Foundation
import PDFKit
import UIKit

@MainActor
enum IPadDraftBoundaryDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0, failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            checks += 1; if !condition { failures.append(message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearDraftBoundary-\(UUID())")
        let suite = "DogearDraftBoundary.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("authored.pdf")
            let bytes = fixture(pages: 3); try bytes.write(to: source)
            let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
            let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("queue"))
            let feedback = OperationFeedbackCenter(userDefaults: defaults)
            let fileID = UUID()
            func makeStore() -> PDFDocumentStore {
                PDFDocumentStore(feedbackCenter: feedback,
                    metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("\(UUID()).json")),
                    aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("\(UUID()).json")),
                    workingCopyStore: copies, saveQueue: queue, accessCoordinator: DocumentAccessCoordinator(saveQueue: queue),
                    exportPresenter: IPadDocumentExportPresenter())
            }
            var store = makeStore(); defer { store.releaseEditorAccess() }
            expect(store.openPDF(from: source) && store.bindLibraryFile(fileID), "Boundary fixture opens an isolated actual writer.")
            store.documentSearchText = "Authored"; store.refreshDocumentSearchResults()
            let oldMatch = try required(store.documentSearchResults.first)
            expect(store.selectDocumentSearchResult(oldMatch), "A current native search hit is selectable.")
            store.selectPreviousDocumentSearchResult()
            expect(store.selectedDocumentSearchResult?.pageIndex == 2, "Previous search match wraps to the last hit.")
            store.selectNextDocumentSearchResult()
            expect(store.selectedDocumentSearchResult?.pageIndex == 0, "Next search match wraps back to the first hit.")
            store.documentSearchText = "page"; store.refreshDocumentSearchResults()
            expect(store.documentSearchResults.first?.id == oldMatch.id && !store.selectDocumentSearchResult(oldMatch),
                "A changed query rejects an old selection even when its numeric result ID is reused.")
            let cancelledMatch = try required(store.documentSearchResults.first)
            store.documentSearchText = ""; store.refreshDocumentSearchResults()
            expect(!store.selectDocumentSearchResult(cancelledMatch), "Cancelled search cannot navigate a retained old hit.")
            let directory = root.appendingPathComponent("notes")
            let recovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: directory)
            recovery.bind(fileID: fileID)
            let draft = try required(store.newFreeTextDraft())
            let editor = IPadInlineNoteEditingSession(draft: draft)
            recovery.track(editor); editor.values.text = "First unfinished draft"
            recovery.track(nil)
            let url = try required(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
            let firstBytes = try Data(contentsOf: url)
            var second = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: firstBytes)
            second.values.text = "Second newer draft"; second.updatedAt = Date().addingTimeInterval(100)
            let secondURL = directory.appendingPathComponent("\(UUID())-\(fileID).json")
            try AnnotationDraftFiles.write(second, to: secondURL)
            let secondBytes = try Data(contentsOf: secondURL)
            let conflict = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: directory)
            conflict.bind(fileID: fileID)
            expect(conflict.restore() == nil && conflict.candidates.count == 2 && conflict.lastError != nil,
                "FreeText refuses the newer of two unfinished records and enumerates both.")
            expect(try conflict.captureDiscardPermit() == nil && Data(contentsOf: url) == firstBytes && Data(contentsOf: secondURL) == secondBytes,
                "Ambiguous recovery cannot bulk-discard or rewrite either record.")
            let chosen = try required(conflict.candidates.first { $0.url == url })
            expect(conflict.selectCandidate(chosen), "An explicit unchanged candidate can be selected without merging.")
            let resumed = try required(conflict.restore())
            expect(resumed.id == draft.id && resumed.values.text == editor.values.text && resumed.draft.annotation.page == nil,
                "Cold editor recovery retains the durable draft UUID and remains detached.")
            conflict.track(resumed); resumed.values.text += " revised"
            expect(try Data(contentsOf: secondURL) == secondBytes, "Editing a chosen record leaves the competing draft byte-identical.")
            expect(resumed.discard(), "Explicit discard completes only the chosen draft.")
            conflict.track(nil)
            expect(try !FileManager.default.fileExists(atPath: url.path) && Data(contentsOf: secondURL) == secondBytes && conflict.hasUnresolvedRecord,
                "The remaining draft is still reachable and blocks a new conflicting editor.")

            let futureDirectory = root.appendingPathComponent("future-schema")
            var future = second; future.schema = 99; future.completed = true
            let futureURL = futureDirectory.appendingPathComponent("\(UUID())-\(fileID).json")
            try AnnotationDraftFiles.write(future, to: futureURL)
            let futureBytes = try Data(contentsOf: futureURL)
            let unknown = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: futureDirectory)
            unknown.bind(fileID: fileID)
            expect(try unknown.restore() == nil && unknown.lastError != nil && Data(contentsOf: futureURL) == futureBytes,
                "Unknown schema completion is not authority to ignore or automatically delete a record.")

            let corruptDirectory = root.appendingPathComponent("corrupt")
            let corruptURL = corruptDirectory.appendingPathComponent("\(UUID())-\(fileID).json")
            try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
            try Data("broken JSON with retained text".utf8).write(to: corruptURL)
            let corrupt = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: corruptDirectory)
            corrupt.bind(fileID: fileID)
            expect(corrupt.restore() == nil && corrupt.lastError != nil && corrupt.candidates.count == 1,
                "An unreadable record from another workspace is not silently ignored.")
            let stale = try required(corrupt.captureDiscardPermit())
            try Data("changed retained text".utf8).write(to: corruptURL)
            expect(!corrupt.discardSavedDraft(using: stale) && FileManager.default.fileExists(atPath: corruptURL.path),
                "A changed malformed record invalidates its old discard confirmation.")

            let page = try required(store.document?.page(at: 0))
            let highlight = PDFAnnotation(bounds: CGRect(x: 50, y: 200, width: 100, height: 18), forType: .highlight, withProperties: nil)
            highlight.color = .yellow; page.addAnnotation(highlight)
            let highlights = root.appendingPathComponent("highlights")
            let highlightRecovery = IPadHighlightDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: highlights)
            highlightRecovery.bind(fileID: fileID)
            let highlightEditor = IPadHighlightEditingSession(draft: .init(document: try required(store.document), annotation: highlight,
                quote: "fixture", color: highlight.color, comment: ""))
            highlightRecovery.track(highlightEditor); highlightEditor.values.comment = "First comment"; highlightRecovery.track(nil)
            let highlightURL = try required(FileManager.default.contentsOfDirectory(at: highlights, includingPropertiesForKeys: nil).first)
            let highlightBytes = try Data(contentsOf: highlightURL)
            let duplicateURL = highlights.appendingPathComponent("\(UUID())-\(fileID).json")
            try highlightBytes.write(to: duplicateURL)
            let highlightConflict = IPadHighlightDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: highlights)
            highlightConflict.bind(fileID: fileID)
            expect(highlightConflict.restore() == nil && highlightConflict.candidates.count == 2 && highlightConflict.captureDiscardPermit() == nil,
                "Highlight uses the same non-destructive conflict enumeration as FreeText.")
            expect(highlightConflict.selectCandidate(try required(highlightConflict.candidates.first)), "Highlight permits explicit candidate selection.")
            let restoredHighlight = try required(highlightConflict.restore()); highlightConflict.track(restoredHighlight)
            expect(restoredHighlight.id == highlightEditor.id && restoredHighlight.values.comment == "First comment", "Highlight selection restores original draft identity and values.")
            expect(restoredHighlight.discard(), "Chosen Highlight discard is durable.")
            expect(try FileManager.default.contentsOfDirectory(at: highlights, includingPropertiesForKeys: nil).count == 1,
                "Discarding one Highlight conflict retains the other.")

            // Cold recovery -> explicit Save -> document Undo -> completion marker
            // failure, with an older note at exactly the same position.
            let bounds = CGRect(x: 90, y: 360, width: 220, height: 100)
            let older = try required(store.newFreeTextDraft(page: page, bounds: bounds))
            var olderValues = older.values; olderValues.text = "Older same-position note"
            expect(store.saveFreeText(older, values: olderValues), "Seed an older standard same-position note through the Store.")
            await queue.drain(); await settle()
            let copy = try required(store.currentWorkingCopyURL)
            let combinedDirectory = root.appendingPathComponent("combined")
            var combined: IPadInlineNoteDraftRecovery? = .init(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: combinedDirectory)
            combined?.bind(fileID: fileID)
            let unfinished = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft(page: page, bounds: bounds)))
            combined?.track(unfinished); unfinished.values.text = "Cold recovered then undone"
            combined?.track(nil); combined = nil
            store.releaseEditorAccess(); store = makeStore()
            expect(store.openPDF(from: source, workingCopyURL: copy) && store.bindLibraryFile(fileID), "Reopen with a genuinely new Store/document, not a same-file fast path.")
            let undo = UndoManager(); undo.groupsByEvent = false; store.setUndoManager(undo)
            let cold = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: combinedDirectory)
            cold.bind(fileID: fileID)
            let coldEditor = try required(cold.restore()); cold.track(coldEditor)
            expect(coldEditor.id == unfinished.id, "Combined cold fixture retains the sidecar draft identity.")
            undo.beginUndoGrouping(); let saved = coldEditor.save(in: store, canCommit: { true }); undo.endUndoGrouping()
            cold.track(nil)
            expect(try saved && cold.prepareDocumentUndo(in: required(store.document)), "Save and write-ahead Undo intent succeed before the injected completion failure.")
            store.undoDocumentChange()
            let backup = root.appendingPathComponent("combined-backup")
            try FileManager.default.moveItem(at: combinedDirectory, to: backup)
            try Data("block completion marker".utf8).write(to: combinedDirectory)
            cold.didUndoDocument(in: try required(store.document))
            expect(cold.lastError != nil && coldEditor.draft.annotation.page == nil, "Failed completion does not report success or undo the actual document Undo.")
            let retainedURL = try required(FileManager.default.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil).first)
            let retained = try Data(contentsOf: retainedURL)
            let intent = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: retained)
            expect(intent.pendingSave && intent.pendingUndo && !intent.completed && intent.values.text == unfinished.values.text,
                "The failed completion retains durable Undo intent and all editor values.")
            await queue.drain(); await settle()
            try FileManager.default.removeItem(at: combinedDirectory)
            try FileManager.default.moveItem(at: backup, to: combinedDirectory)
            store.releaseEditorAccess(); store = makeStore()
            expect(store.openPDF(from: source, workingCopyURL: copy) && store.bindLibraryFile(fileID), "Cold reopen reads the actually persisted Undo result.")
            let afterUndo = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: combinedDirectory)
            afterUndo.bind(fileID: fileID)
            expect(afterUndo.restore() == nil && afterUndo.lastError != nil,
                "Cold Undo with a same-bounds older note stays conservatively unresolved, never resurrecting the undone editor.")
            expect(try Data(contentsOf: combinedDirectory.appendingPathComponent(retainedURL.lastPathComponent)) == retained
                && store.document?.page(at: 0)?.annotations.filter { $0.type == "FreeText" }.map(\.contents) == [olderValues.text]
                && Data(contentsOf: source) == bytes,
                "Combined fault retains its sole sidecar, exact older note, and original PDF bytes.")

            for (name, pages, density) in [("ordinary", 3, 0), ("large", 500, 0), ("dense", 60, 60)] {
                let performanceURL = root.appendingPathComponent("\(name).pdf")
                try fixture(pages: pages).write(to: performanceURL)
                let originalPerformanceBytes = try Data(contentsOf: performanceURL)
                store.releaseEditorAccess(); store = makeStore()
                expect(store.openPDF(from: performanceURL) && store.bindLibraryFile(UUID()), "Performance \(name) opens authored fixture.")
                if density > 0, let document = store.document {
                    for index in 0..<document.pageCount {
                        for note in 0..<density {
                            let annotation = FreeTextAnnotationFactory.make(bounds: CGRect(x: 10 + note, y: 100, width: 40, height: 30))
                            annotation.contents = "Fixture \(index)-\(note)"; document.page(at: index)?.addAnnotation(annotation)
                        }
                    }
                }
                let performanceRecovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback,
                    directoryURL: root.appendingPathComponent("perf-\(name)"))
                performanceRecovery.bind(fileID: try required(store.captureWritePermit(requestID: UUID())?.fileID))
                let start = CFAbsoluteTimeGetCurrent()
                let session = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft()))
                performanceRecovery.track(session); session.values.text = "Performance draft"
                let first = (CFAbsoluteTimeGetCurrent() - start) * 1000
                var times: [Double] = []
                for index in 0..<30 {
                    let tick = CFAbsoluteTimeGetCurrent(); session.values.text += "\(index)中"
                    times.append((CFAbsoluteTimeGetCurrent() - tick) * 1000)
                }
                let style = CFAbsoluteTimeGetCurrent(); session.values.fontSize = 18
                let styleMS = (CFAbsoluteTimeGetCurrent() - style) * 1000
                let flush = CFAbsoluteTimeGetCurrent(); let flushed = performanceRecovery.flush()
                let flushMS = (CFAbsoluteTimeGetCurrent() - flush) * 1000
                times.sort()
                expect(flushed && !store.hasUnsavedChanges, "Measured checkpoints remain synchronous/durable without committing the PDF; strings are not OS IME evidence.")
                performanceRecovery.track(nil)
                let restoring = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback,
                    directoryURL: root.appendingPathComponent("perf-\(name)"))
                restoring.bind(fileID: try required(store.captureWritePermit(requestID: UUID())?.fileID))
                let restoreStart = CFAbsoluteTimeGetCurrent()
                let recovered = try required(restoring.restore())
                let restoreMS = (CFAbsoluteTimeGetCurrent() - restoreStart) * 1000
                restoring.track(recovered)
                // The previous timing baseline had no attached UndoManager.
                // Keep Save's real Undo registration; begin outside its timer.
                let performanceUndo = UndoManager(); performanceUndo.groupsByEvent = false
                store.setUndoManager(performanceUndo); performanceUndo.beginUndoGrouping()
                let saveStart = CFAbsoluteTimeGetCurrent()
                let accepted = recovered.save(in: store, canCommit: { true })
                let acceptMS = (CFAbsoluteTimeGetCurrent() - saveStart) * 1000
                performanceUndo.endUndoGrouping()
                await queue.drain()
                for _ in 0..<400 where store.hasUnsavedChanges { await Task.yield() }
                let saveMS = (CFAbsoluteTimeGetCurrent() - saveStart) * 1000
                print("DRAFT-PERF \(name) pages=\(pages) annotations=\(pages*density) first_ms=\(first) input_p50_ms=\(times[15]) input_p95_ms=\(times[28]) style_ms=\(styleMS) flush_ms=\(flushMS) restore_ms=\(restoreMS) save_accept_ms=\(acceptMS) save_drained_ms=\(saveMS)")
                expect(accepted && !store.hasUnsavedChanges && store.workingCopySaveError == nil
                    && store.document?.page(at: 0)?.annotations.contains { $0.contents == recovered.values.text } == true,
                    "Measured recovery and explicit Save reach the actual working-copy completion.")

                // All cold reads and subsequent mutations stay outside Save's
                // accepted/drained measurements and use the actual queue/Store.
                let insertedAnnotation = recovered.draft.annotation
                let insertedPageIndex = try required(store.document).index(for: recovered.draft.page)
                let insertedBounds = insertedAnnotation.bounds
                let insertedText = try required(insertedAnnotation.contents)
                let insertedFont = try required(insertedAnnotation.font)
                let insertedFontName = insertedFont.fontName, insertedFontSize = insertedFont.pointSize
                let insertedColor = try required(FreeTextAnnotationEditing.textColorComponents(of: insertedAnnotation.fontColor ?? .black))
                func verifyColdCopy(_ newNotePresent: Bool, phase: String) throws {
                    let copyURL = try required(store.currentWorkingCopyURL)
                    let cold = try required(PDFDocument(url: copyURL))
                    var pageFactsMatch = true, totalAnnotations = 0, insertedCount = 0
                    var insertedStyleMatches = true
                    var firstMismatchPage: Int?
                    for pageIndex in 0..<pages {
                        guard let coldPage = cold.page(at: pageIndex) else {
                            pageFactsMatch = false; firstMismatchPage = firstMismatchPage ?? pageIndex
                            continue
                        }
                        let annotations = coldPage.annotations
                        totalAnnotations += annotations.count
                        var expectedTexts = (0..<density).map { "Fixture \(pageIndex)-\($0)" }
                        if newNotePresent && pageIndex == insertedPageIndex { expectedTexts.append(insertedText) }
                        let actualTexts = annotations.map { $0.contents ?? "" }
                        let notesByText = Dictionary(grouping: annotations, by: { $0.contents ?? "" })
                        var oldBoundsMatch = true
                        for note in 0..<density {
                            let expectedBounds = CGRect(x: 10 + note, y: 100, width: 40, height: 30)
                            if notesByText["Fixture \(pageIndex)-\(note)"]?.first?.bounds != expectedBounds { oldBoundsMatch = false }
                        }
                        if annotations.count != expectedTexts.count || actualTexts.sorted() != expectedTexts.sorted()
                            || !oldBoundsMatch || !annotations.allSatisfy({ $0.type == "FreeText" && $0.shouldDisplay }) {
                            pageFactsMatch = false; firstMismatchPage = firstMismatchPage ?? pageIndex
                        }
                        for annotation in annotations where annotation.contents == insertedText {
                            insertedCount += 1
                            insertedStyleMatches = insertedStyleMatches && pageIndex == insertedPageIndex
                                && annotation.bounds == insertedBounds && annotation.font?.fontName == insertedFontName
                                && annotation.font?.pointSize == insertedFontSize
                                && FreeTextAnnotationEditing.matchesTextColor(insertedColor, annotation: annotation)
                        }
                    }
                    expect(cold !== store.document && cold.pageCount == pages && pageFactsMatch
                        && totalAnnotations == pages * density + (newNotePresent ? 1 : 0),
                        "Performance \(name) \(phase) cold PDF preserves every page's exact Fixture p-n multiset, bounds and standard visible notes. [pages=\(cold.pageCount), total=\(totalAnnotations), firstMismatchPage=\(String(describing: firstMismatchPage))]")
                    expect(insertedCount == (newNotePresent ? 1 : 0) && insertedStyleMatches,
                        "Performance \(name) \(phase) cold PDF contains exactly the expected new-note presence with its frozen page, bounds, text, native face, size and color.")
                    let sourceAfter = try Data(contentsOf: performanceURL)
                    expect(!store.hasUnsavedChanges && store.workingCopySaveError == nil && sourceAfter == originalPerformanceBytes,
                        "Performance \(name) \(phase) completes the actual working-copy write and leaves the original authored PDF bytes unchanged.")
                }
                try verifyColdCopy(true, phase: "saved")
                let undoDocument = try required(store.document)
                let canUndo = store.canUndoDocumentChange && !store.canRedoDocumentChange
                    && restoring.prepareDocumentUndo(in: undoDocument)
                expect(canUndo, "Performance \(name) has the actual new-note document Undo and accepts its durable recovery boundary.")
                guard canUndo else { throw CocoaError(.fileWriteUnknown) }
                store.undoDocumentChange(); restoring.didUndoDocument(in: undoDocument)
                await queue.drain(); await settle()
                try verifyColdCopy(false, phase: "undone")
                let canRedo = store.canRedoDocumentChange && !store.canUndoDocumentChange
                expect(canRedo, "Performance \(name) retains exactly the inverse document Redo after removing the one newly saved note.")
                guard canRedo else { throw CocoaError(.fileWriteUnknown) }
                store.redoDocumentChange()
                await queue.drain(); await settle()
                try verifyColdCopy(true, phase: "redone")
            }
        } catch { expect(false, "Draft boundary fixture: \(error)") }
        for highlight in [false, true] {
            for variant in ["single", "multiple", "malformed"] {
                do {
                    try await verifyRemainingSaveConflict(root: root.appendingPathComponent("remaining-\(highlight)-\(variant)"),
                        defaults: defaults, highlight: highlight, variant: variant, expect: expect)
                } catch { expect(false, "Remaining draft fixture [highlight=\(highlight), variant=\(variant)]: \(error)") }
            }
        }
        return (checks, failures)
    }

    private static func verifyRemainingSaveConflict(root: URL, defaults: UserDefaults, highlight: Bool,
                                                    variant: String, expect: (Bool, String) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.pdf"), originalBytes = fixture(pages: 3)
        try originalBytes.write(to: source)
        let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
        let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("queue"))
        let feedback = OperationFeedbackCenter(userDefaults: defaults), access = DocumentAccessCoordinator(saveQueue: queue)
        let store = PDFDocumentStore(feedbackCenter: feedback,
            metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("metadata.json")),
            aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("groups.json")),
            workingCopyStore: copies, saveQueue: queue, accessCoordinator: access,
            exportPresenter: IPadDocumentExportPresenter())
        defer { store.releaseEditorAccess() }
        let directory = root.appendingPathComponent("chosen-drafts"), fileID = UUID()
        let workspace = IPadGroupWorkspace(id: UUID(), groupID: UUID(), documentStore: store,
            feedbackCenter: feedback, accessCoordinator: access,
            noteDraftDirectoryURL: highlight ? root.appendingPathComponent("unused-notes") : directory,
            highlightDraftDirectoryURL: highlight ? directory : root.appendingPathComponent("unused-highlights"))
        workspace.state.undoManager.groupsByEvent = false
        expect(store.openPDF(from: source) && store.bindLibraryFile(fileID),
            "Remaining \(highlight ? "Highlight" : "FreeText") \(variant) opens a real isolated workspace writer.")
        let document = try required(store.document)
        var seeded = true
        if highlight {
            workspace.state.undoManager.beginUndoGrouping()
            for index in 0..<3 {
                let selection = try required(document.findString("Authored page \(index + 1)", withOptions: []).first)
                seeded = store.addHighlights(from: selection, in: document) && seeded
            }
            workspace.state.undoManager.endUndoGrouping()
            await queue.drain(); await settle()
        }
        expect(seeded && !store.hasUnsavedChanges && store.workingCopySaveError == nil
            && store.annotations.filter { $0.kind == .highlight }.count == (highlight ? 3 : 0),
            "Conflict drafts start from a clean actual PDF; Highlight uses separate standard annotations on three pages.")

        func produce(index: Int, text: String, in folder: URL) throws -> (id: UUID, url: URL, bytes: Data) {
            let id: UUID
            if highlight {
                let item = try required(store.annotations.first { $0.kind == .highlight && $0.pageIndex == index })
                let editor = IPadHighlightEditingSession(draft: try required(store.highlightEditDraft(for: item)))
                let producer = IPadHighlightDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: folder)
                producer.bind(fileID: fileID); producer.track(editor); editor.values.comment = text
                guard producer.flush() else { throw CocoaError(.fileWriteUnknown) }
                producer.track(nil); id = editor.id
            } else {
                let page = try required(document.page(at: index))
                let bounds = CGRect(x: 60 + index * 140, y: 400, width: 120, height: 70)
                let editor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft(page: page, bounds: bounds)))
                let producer = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: folder)
                producer.bind(fileID: fileID); producer.track(editor); editor.values.text = text
                guard producer.flush() else { throw CocoaError(.fileWriteUnknown) }
                producer.track(nil); id = editor.id
            }
            let url = try required(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
            return (id, url, try Data(contentsOf: url))
        }
        let chosenText = "Chosen conflict A 中文", remainingText = "Remaining conflict B 中文"
        let chosen = try produce(index: 0, text: chosenText, in: directory)
        let remaining = try produce(index: 1, text: remainingText, in: root.appendingPathComponent("producer-B"))
        let remainingURL = directory.appendingPathComponent(remaining.url.lastPathComponent)
        try FileManager.default.moveItem(at: remaining.url, to: remainingURL)
        var extra: (url: URL, bytes: Data)?
        if variant == "multiple" {
            let third = try produce(index: 2, text: "Another actual conflict C 中文", in: root.appendingPathComponent("producer-C"))
            let thirdURL = directory.appendingPathComponent(third.url.lastPathComponent)
            try FileManager.default.moveItem(at: third.url, to: thirdURL); extra = (thirdURL, third.bytes)
        } else if variant == "malformed" {
            let malformedURL = directory.appendingPathComponent("\(UUID())-\(fileID).json")
            let malformedBytes = Data("Unfinished malformed conflict retained 中文".utf8)
            try malformedBytes.write(to: malformedURL); extra = (malformedURL, malformedBytes)
        }
        func extraUnchanged() -> Bool {
            guard let extra else { return true }
            return (try? Data(contentsOf: extra.url)) == extra.bytes
        }
        let noteRecovery = workspace.noteDraftRecovery, highlightRecovery = workspace.highlightDraftRecovery
        if highlight { highlightRecovery.bind(fileID: fileID) } else { noteRecovery.bind(fileID: fileID) }
        let noAutomaticChoice = highlight ? highlightRecovery.restore() == nil : noteRecovery.restore() == nil
        let candidates = highlight ? highlightRecovery.candidates : noteRecovery.candidates
        let initialB = try Data(contentsOf: remainingURL)
        expect(chosen.id != remaining.id && noAutomaticChoice && candidates.count == (extra == nil ? 2 : 3)
            && initialB == remaining.bytes && extraUnchanged()
            && (highlight ? !workspace.canBeginHighlight : !workspace.canBeginInlineNote),
            "Actual different-UUID A/B producers require explicit conflict selection and do not rewrite the remaining payload.")
        let selected = try required(candidates.first { $0.url == chosen.url })
        let selectedA = highlight ? highlightRecovery.selectCandidate(selected) : noteRecovery.selectCandidate(selected)
        if highlight { workspace.restoreHighlightIfNeeded() } else { workspace.restoreInlineNoteIfNeeded() }
        let selectedID = highlight ? workspace.highlightEditingSession?.id : workspace.inlineNoteSession?.id
        let selectedText = highlight ? workspace.highlightEditingSession?.values.comment : workspace.inlineNoteSession?.values.text
        expect(selectedA && selectedID == chosen.id && selectedText == chosenText && !store.hasUnsavedChanges,
            "The actual workspace restores only the explicitly selected A without committing any draft.")

        workspace.state.undoManager.beginUndoGrouping()
        let saved: Bool
        if highlight {
            saved = try required(workspace.highlightEditingSession).save(in: store, canCommit: { true })
        } else {
            saved = try required(workspace.inlineNoteSession).save(in: store, canCommit: { true })
        }
        workspace.state.undoManager.endUndoGrouping()
        if highlight { workspace.highlightEditingSession = nil } else { workspace.inlineNoteSession = nil }
        let pendingBytes = try Data(contentsOf: chosen.url), beforeDrainB = try Data(contentsOf: remainingURL)
        let pendingA = highlight
            ? try JSONDecoder().decode(IPadHighlightDraftRecovery.Record.self, from: pendingBytes).pendingSave
            : try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: pendingBytes).pendingSave
        expect(saved && pendingA && store.hasUnsavedChanges && beforeDrainB == remaining.bytes && extraUnchanged(),
            "A's real Save leaves pending intent and B byte-identical when the Reader-equivalent session setter immediately clears its live editor.")
        await queue.drain(); await settle()
        let exposedB = try Data(contentsOf: remainingURL)
        let unresolved = highlight ? highlightRecovery.hasUnresolvedRecord : noteRecovery.hasUnresolvedRecord
        let blocked = highlight ? !workspace.canBeginHighlight : !workspace.canBeginInlineNote
        let error = highlight ? highlightRecovery.lastError : noteRecovery.lastError
        let remainingCandidates = highlight ? highlightRecovery.candidates : noteRecovery.candidates
        expect(!store.hasUnsavedChanges && store.workingCopySaveError == nil && !FileManager.default.fileExists(atPath: chosen.url.path)
            && exposedB == remaining.bytes && extraUnchanged() && unresolved && blocked && error != nil
            && (extra == nil || remainingCandidates.count == 2),
            "Actual queue completion removes only A, reveals every remaining valid/malformed conflict and keeps new-draft entry blocked.")
        let copy = try required(store.currentWorkingCopyURL), copyBeforeRetry = try Data(contentsOf: copy)
        let cold = try required(PDFDocument(data: copyBeforeRetry))
        let nativeIDs = (0..<document.pageCount).flatMap { document.page(at: $0)?.annotations ?? [] }.map(ObjectIdentifier.init)
        let savedAnnotations = (0..<cold.pageCount).flatMap { cold.page(at: $0)?.annotations ?? [] }
        let sourceAfterSave = try Data(contentsOf: source)
        expect(savedAnnotations.filter { $0.contents == chosenText }.count == 1
            && !savedAnnotations.contains { $0.contents == remainingText }
            && savedAnnotations.filter { $0.type == (highlight ? "Highlight" : "FreeText") }.count == (highlight ? 3 : 1)
            && sourceAfterSave == originalBytes,
            "The real working copy contains A exactly once and no committed B; its original PDF remains byte-identical.")

        if variant == "malformed", let extra {
            let bad = try required(remainingCandidates.first { $0.url == extra.url })
            let selectedBad = highlight ? highlightRecovery.selectCandidate(bad) : noteRecovery.selectCandidate(bad)
            let permitExists = highlight ? highlightRecovery.captureDiscardPermit() != nil : noteRecovery.captureDiscardPermit() != nil
            expect(!selectedBad && permitExists && extraUnchanged(),
                "Explicitly selecting the malformed conflict leaves its real bytes intact and offers a byte-bound discard permit.")
            let discarded: Bool
            if highlight {
                discarded = highlightRecovery.discardSavedDraft(using: try required(highlightRecovery.captureDiscardPermit()))
            } else {
                discarded = noteRecovery.discardSavedDraft(using: try required(noteRecovery.captureDiscardPermit()))
            }
            let afterBadDiscardB = try Data(contentsOf: remainingURL)
            expect(discarded && !FileManager.default.fileExists(atPath: extra.url.path) && afterBadDiscardB == remaining.bytes
                && (highlight ? highlightRecovery.hasUnresolvedRecord && !workspace.canBeginHighlight && highlightRecovery.lastError != nil
                    : noteRecovery.hasUnresolvedRecord && !workspace.canBeginInlineNote && noteRecovery.lastError != nil),
                "Successful direct malformed-file discard still reveals valid B and preserves its payload instead of silently allowing a new C.")
        }
        let selectionB: Bool
        if variant == "multiple" {
            let choices = highlight ? highlightRecovery.candidates : noteRecovery.candidates
            let candidateB = try required(choices.first { $0.url == remainingURL })
            selectionB = highlight ? highlightRecovery.selectCandidate(candidateB) : noteRecovery.selectCandidate(candidateB)
        } else { selectionB = true }
        let restoredNote = highlight ? nil : noteRecovery.restore()
        let restoredHighlight = highlight ? highlightRecovery.restore() : nil
        let restoredID = restoredHighlight?.id ?? restoredNote?.id
        let restoredText = restoredHighlight?.values.comment ?? restoredNote?.values.text
        let retryB = try Data(contentsOf: remainingURL), copyAfterRetry = try Data(contentsOf: copy), sourceAfterRetry = try Data(contentsOf: source)
        let afterIDs = (0..<document.pageCount).flatMap { document.page(at: $0)?.annotations ?? [] }.map(ObjectIdentifier.init)
        let nativeBaselineIntact = highlight ? restoredHighlight?.draft.annotation.contents == nil : restoredNote?.draft.annotation.page == nil
        expect(selectionB && restoredID == remaining.id && restoredText == remainingText && nativeBaselineIntact
            && retryB == remaining.bytes && afterIDs == nativeIDs && copyAfterRetry == copyBeforeRetry
            && sourceAfterRetry == originalBytes && !store.hasUnsavedChanges
            && (highlight ? highlightRecovery.lastError == nil : noteRecovery.lastError == nil),
            "Explicit Retry restores B's original UUID/Chinese values without auto-commit, PDF write or sidecar rewrite; unrelated candidates stay separate.")
        if let restoredHighlight { workspace.highlightEditingSession = restoredHighlight }
        if let restoredNote { workspace.inlineNoteSession = restoredNote }
        let finalCopy = try Data(contentsOf: copy), finalSource = try Data(contentsOf: source)
        expect(store.document === document && access.owns(store, url: source)
            && (highlight ? workspace.highlightEditingSession?.id == remaining.id && !workspace.canBeginHighlight
                : workspace.inlineNoteSession?.id == remaining.id && !workspace.canBeginInlineNote)
            && (variant != "multiple" || extraUnchanged()) && !store.hasUnsavedChanges
            && finalCopy == copyBeforeRetry && finalSource == originalBytes,
            "Installing recovered B retains the actual workspace/Store writer and blocks a replacement editor without mutating either PDF.")
    }

    private static func settle() async { for _ in 0..<8 { await Task.yield() }; try? await Task.sleep(nanoseconds: 100_000_000) }
    private static func required<T>(_ value: T?) throws -> T { guard let value else { throw CocoaError(.fileReadUnknown) }; return value }
    private static func fixture(pages: Int) -> Data {
        let rect = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: rect).pdfData { renderer in
            for index in 0..<pages { renderer.beginPage(); ("Authored page \(index + 1)" as NSString).draw(at: CGPoint(x: 60, y: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 18)]) }
        }
    }
}
#endif
