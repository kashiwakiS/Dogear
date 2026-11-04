#if os(iOS)
import Combine
import Foundation
import PDFKit
import UIKit

@MainActor
enum IPadInlineNoteDraftRecoveryDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0, failures: [String] = []
        func expect(_ value: Bool, _ message: String) {
            checks += 1; if !value { failures.append(message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearInlineRecovery-\(UUID())")
        let suite = "DogearInlineRecovery.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { return (1, ["Could not isolate recovery defaults."]) }
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let a = root.appendingPathComponent("A.pdf"), b = root.appendingPathComponent("B.pdf")
            let original = fixture(color: .red), replacement = fixture(color: .blue)
            try original.write(to: a); try fixture(color: .green).write(to: b)
            let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
            let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("queue"))
            var access = DocumentAccessCoordinator(saveQueue: queue)
            let feedback = OperationFeedbackCenter(userDefaults: defaults)
            func makeStore() -> PDFDocumentStore {
                let name = UUID().uuidString
                return PDFDocumentStore(feedbackCenter: feedback,
                    metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("\(name)-metadata.json")),
                    aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("\(name)-groups.json")),
                    workingCopyStore: copies, saveQueue: queue, accessCoordinator: access,
                    exportPresenter: IPadDocumentExportPresenter())
            }
            var store = makeStore(); defer { store.releaseEditorAccess() }
            let aID = UUID(), bID = UUID(), workspaceID = UUID()
            let directory = root.appendingPathComponent("drafts")
            let undo = UndoManager(); undo.groupsByEvent = false; store.setUndoManager(undo)
            expect(store.openPDF(from: a) && store.bindLibraryFile(aID), "An isolated writer opens the textless scan fixture.")
            guard let page = store.document?.page(at: 0), let draft = store.newFreeTextDraft(page: page,
                bounds: CGRect(x: 90, y: 400, width: 240, height: 120)) else { throw FixtureError.missingDraft }
            let recovery = IPadInlineNoteDraftRecovery(workspaceID: workspaceID, store: store, feedback: feedback, directoryURL: directory)
            recovery.bind(fileID: aID)
            let editor = IPadInlineNoteEditingSession(draft: draft); recovery.track(editor)
            editor.values.text = "未保存的中文便笺"; recovery.flush()
            expect(page.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                && page.annotations.isEmpty && !store.hasUnsavedChanges,
                "Persisting an unfinished note leaves the textless PDF and document Undo untouched.")
            let aRecordURL = try required(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
            let aBytes = try Data(contentsOf: aRecordURL)
            recovery.track(nil)
            let originalNativeDocument = store.document
            store.releaseEditorAccess(); access = DocumentAccessCoordinator(saveQueue: queue)
            store = makeStore(); store.setUndoManager(undo)
            expect(store.openPDF(from: a) && store.bindLibraryFile(aID) && store.document !== originalNativeDocument,
                "A fresh Store/coordinator opens a new native document under the same Library identity.")
            let afterScene = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: directory)
            afterScene.bind(fileID: aID)
            let restored = try required(afterScene.restore()); afterScene.track(restored)
            expect(restored.values.text == editor.values.text && restored.draft.originalBounds == draft.originalBounds
                && restored.draft.document === store.document && restored.draft.annotation.page == nil,
                "Another scene/workspace restores the exact detached text and PDF bounds without committing it.")
            expect(try Data(contentsOf: a) == original, "Draft checkpoint and fresh native restore preserve the original bytes.")
            afterScene.track(nil)
            try replacement.write(to: a)
            let beforeExternalReplacement = store.document
            store.releaseEditorAccess(); access = DocumentAccessCoordinator(saveQueue: queue)
            store = makeStore(); store.setUndoManager(undo)
            expect(store.openPDF(from: a) && store.bindLibraryFile(aID) && store.document !== beforeExternalReplacement,
                "Another fresh Store loads the externally replaced same-size textless scan.")
            let changed = IPadInlineNoteDraftRecovery(workspaceID: workspaceID, store: store, feedback: feedback, directoryURL: directory)
            changed.bind(fileID: aID)
            expect(changed.restore() == nil && changed.lastError != nil && FileManager.default.fileExists(atPath: aRecordURL.path),
                "A changed scan cannot reuse the old note anchor; the failed recovery retains its sidecar.")
            let retainedABytes = try Data(contentsOf: aRecordURL)
            let staleDiscard = try required(changed.captureDiscardPermit())
            expect(store.openPDF(from: b) && store.bindLibraryFile(bID), "A mismatched draft does not prevent reading another PDF.")
            changed.bind(fileID: bID)
            let bEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft()))
            changed.track(bEditor); bEditor.values.text = "Independent B draft"; changed.flush()
            expect(try Data(contentsOf: aRecordURL) == retainedABytes
                && FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 2,
                "The same workspace's B draft cannot overwrite A's retained mismatch record.")
            changed.track(nil)
            expect(try !changed.discardSavedDraft(using: staleDiscard)
                && FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 2,
                "A's stale discard confirmation cannot remove the later B draft.")
            changed.track(bEditor)
            expect(bEditor.discard(), "Explicit discard completes after its durable intent is recorded.")
            changed.track(nil)
            expect(try FileManager.default.fileExists(atPath: aRecordURL.path)
                && FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 1,
                "Discarding B removes only its sidecar and preserves the unrelated A draft.")
            expect(store.openPDF(from: a) && store.bindLibraryFile(aID), "The changed A document can still be opened.")
            changed.bind(fileID: aID); _ = changed.restore()
            let discardA = try required(changed.captureDiscardPermit())
            expect(changed.discardSavedDraft(using: discardA) && !FileManager.default.fileExists(atPath: aRecordURL.path),
                "An explicit unresolved-draft discard releases its recovery record without changing the PDF.")

            let saved = IPadInlineNoteDraftRecovery(workspaceID: workspaceID, store: store, feedback: feedback, directoryURL: directory)
            saved.bind(fileID: aID)
            let savedEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft()))
            saved.track(savedEditor); savedEditor.values.text = "Explicit saved 中文"
            undo.beginUndoGrouping(); let accepted = savedEditor.save(in: store, canCommit: { true }); undo.endUndoGrouping()
            expect(try accepted && store.hasUnsavedChanges
                && FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 1,
                "An accepted PDF mutation retains its draft sidecar while the working-copy write is pending.")
            saved.track(nil)
            let pendingCopy = try required(store.currentWorkingCopyURL)
            expect(store.openPDF(from: b) && store.bindLibraryFile(bID), "A new saved note's writer can switch to B while persistence is pending.")
            saved.bind(fileID: bID)
            expect(store.openPDF(from: a, workingCopyURL: pendingCopy) && store.bindLibraryFile(aID), "The retained A writer reopens before its queued save completes.")
            saved.bind(fileID: aID)
            expect(try saved.restore() == nil && store.hasUnsavedChanges
                && FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 1,
                "An already-applied new note retains its sidecar while the actual working-copy write is still pending.")
            await queue.drain(); await settle()
            expect(try !store.hasUnsavedChanges && store.workingCopySaveError == nil
                && FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty,
                "Only successful working-copy persistence completes the saved draft's recovery record. \(recoveryFields(saved, store: store, directory: directory))")
            let copy = try required(store.currentWorkingCopyURL)
            let reopened = try required(PDFDocument(url: copy))
            expect(try reopened.page(at: 0)?.annotations.contains { $0.type == "FreeText" && $0.contents == savedEditor.values.text } == true
                && Data(contentsOf: a) == replacement,
                "The actual copy contains a standard Chinese FreeText; the externally replaced original remains untouched.")

            let existingPage = try required(store.document?.page(at: 0))
            let existingAnnotation = try required(existingPage.annotations.first { $0.type == "FreeText" })
            let existingRecovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: directory)
            existingRecovery.bind(fileID: aID)
            let existingEditor = IPadInlineNoteEditingSession(draft: FreeTextEditDraft(document: try required(store.document),
                page: existingPage, annotation: existingAnnotation))
            existingRecovery.track(existingEditor); existingEditor.values.text = "Changed existing 中文"
            undo.beginUndoGrouping(); let savedExisting = existingEditor.save(in: store, canCommit: { true }); undo.endUndoGrouping()
            existingRecovery.track(nil)
            expect(savedExisting && store.hasUnsavedChanges && store.openPDF(from: b) && store.bindLibraryFile(bID),
                "An existing note is accepted and the writer switches to B before A's save callback.")
            existingRecovery.bind(fileID: bID)
            expect(store.openPDF(from: a, workingCopyURL: copy) && store.bindLibraryFile(aID), "An existing note's retained A writer can also reopen before its pending save.")
            existingRecovery.bind(fileID: aID)
            expect(try existingRecovery.restore() == nil && store.hasUnsavedChanges
                && FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 1,
                "An already-applied existing note cannot clear its sidecar from an unpersisted native document. \(recoveryFields(existingRecovery, store: store, directory: directory))")
            await queue.drain(); await settle()
            expect(PDFDocument(url: copy)?.page(at: 0)?.annotations.contains { $0.type == "FreeText" && $0.contents == existingEditor.values.text } == true,
                "A's late save actually persists the changed standard note after its writer revisits A.")
            expect(store.openPDF(from: a, workingCopyURL: copy) && store.bindLibraryFile(aID), "A reopens its saved note after the document switch.")
            let existingReload = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: directory)
            existingReload.bind(fileID: aID)
            expect(try existingReload.restore() == nil && existingReload.lastError == nil
                && FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty,
                "The exact already-applied note completes its pending sidecar instead of restoring stale editor values. \(recoveryFields(existingReload, store: store, directory: directory))")

            for editsExisting in [false, true] {
                let undoPage = try required(store.document?.page(at: 0))
                let undoAnnotation = try required(undoPage.annotations.first { $0.type == "FreeText" })
                let beforeText = undoAnnotation.contents
                let undoDraft = editsExisting
                    ? FreeTextEditDraft(document: try required(store.document), page: undoPage, annotation: undoAnnotation)
                    : try required(store.newFreeTextDraft())
                let undoRecovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: directory)
                undoRecovery.bind(fileID: aID)
                let undoEditor = IPadInlineNoteEditingSession(draft: undoDraft)
                undoRecovery.track(undoEditor); undoEditor.values.text = "Undo must revoke \(editsExisting) 中文"
                undo.beginUndoGrouping(); let savedForUndo = undoEditor.save(in: store, canCommit: { true }); undo.endUndoGrouping()
                undoRecovery.track(nil)
                expect(try savedForUndo && undoRecovery.prepareDocumentUndo(in: required(store.document)),
                    "Explicit document Undo can durably revoke an accepted note's unfinished recovery intent.")
                store.undoDocumentChange()
                undoRecovery.didUndoDocument(in: try required(store.document))
                expect(editsExisting ? undoAnnotation.contents == beforeText : undoDraft.annotation.page == nil,
                    "The shared document Undo restores the original standard annotation state.")
                expect(store.openPDF(from: b) && store.bindLibraryFile(bID), "The undone writer can switch to B without waiting for persistence.")
                undoRecovery.bind(fileID: bID)
                expect(store.openPDF(from: a, workingCopyURL: copy) && store.bindLibraryFile(aID), "The undone A writer can immediately reopen.")
                undoRecovery.bind(fileID: aID)
                expect(try undoRecovery.restore() == nil && undoRecovery.lastError == nil
                    && FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty,
                    "A new/existing note undone before save completion cannot resurrect an editor draft on revisit. [existing=\(editsExisting)] \(recoveryFields(undoRecovery, store: store, directory: directory))")
                await queue.drain(); await settle()
            }

            let unrelatedRecovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: directory)
            unrelatedRecovery.bind(fileID: aID)
            let unrelatedEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft()))
            unrelatedRecovery.track(unrelatedEditor); unrelatedEditor.values.text = "Keep note while Undo rotates page"
            undo.beginUndoGrouping(); let beforeOtherUndo = unrelatedEditor.save(in: store, canCommit: { true }); undo.endUndoGrouping()
            unrelatedRecovery.track(nil)
            undo.beginUndoGrouping(); store.movePages(fromOffsets: IndexSet(integer: 0), toOffset: 2); undo.endUndoGrouping()
            undo.beginUndoGrouping(); store.rotatePages(at: IndexSet(integer: 0), clockwise: true); undo.endUndoGrouping()
            expect(try beforeOtherUndo && unrelatedRecovery.prepareDocumentUndo(in: required(store.document)),
                "A document Undo intent retains the recovery text until its actual affected annotation is known.")
            store.undoDocumentChange(); unrelatedRecovery.didUndoDocument(in: try required(store.document))
            expect(try unrelatedEditor.draft.annotation.page === store.document?.page(at: 1)
                && unrelatedEditor.draft.annotation.contents == unrelatedEditor.values.text
                && FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 1,
                "Undoing another page's rotation preserves the moved note's only pending sidecar. \(recoveryFields(unrelatedRecovery, store: store, directory: directory))")
            expect(unrelatedRecovery.prepareDocumentUndo(in: try required(store.document)), "Undo can restore the moved page without revoking its note.")
            store.undoDocumentChange(); unrelatedRecovery.didUndoDocument(in: try required(store.document))
            expect(try unrelatedEditor.draft.annotation.page === store.document?.page(at: 0)
                && FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 1,
                "Undoing the page move retains its still-applied standard note and recovery values. \(recoveryFields(unrelatedRecovery, store: store, directory: directory))")
            expect(unrelatedRecovery.prepareDocumentUndo(in: try required(store.document)), "The next Undo can target the saved note itself.")
            store.undoDocumentChange(); unrelatedRecovery.didUndoDocument(in: try required(store.document))
            expect(try unrelatedEditor.draft.annotation.page == nil
                && FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty,
                "Only the Undo that actually removes the new note completes its detached-editor recovery intent. \(recoveryFields(unrelatedRecovery, store: store, directory: directory))")
            await queue.drain(); await settle()

            let mismatchDirectory = root.appendingPathComponent("mismatch-pending-drafts")
            let pendingMismatch = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: mismatchDirectory)
            pendingMismatch.bind(fileID: aID)
            let mismatchEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft()))
            pendingMismatch.track(mismatchEditor); mismatchEditor.values.text = "Keep pending note after source mismatch"
            undo.beginUndoGrouping(); let acceptedMismatch = mismatchEditor.save(in: store, canCommit: { true }); undo.endUndoGrouping()
            pendingMismatch.track(nil)
            let mismatchURL = try required(FileManager.default.contentsOfDirectory(at: mismatchDirectory, includingPropertiesForKeys: nil).first)
            let mismatchBytes = try Data(contentsOf: mismatchURL)
            try original.write(to: a) // Authored disposable original replacement only.
            let mismatchReload = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: mismatchDirectory)
            mismatchReload.bind(fileID: aID)
            expect(acceptedMismatch && mismatchReload.restore() == nil && mismatchReload.lastError != nil,
                "A naturally changed original leaves an accepted-note sidecar unresolved in another recovery host.")
            undo.beginUndoGrouping(); store.rotatePages(at: IndexSet(integer: 1), clockwise: true); undo.endUndoGrouping()
            expect(mismatchReload.prepareDocumentUndo(in: try required(store.document)),
                "Ordinary document Undo remains available when a recovery record lacks validated document authority.")
            store.undoDocumentChange(); mismatchReload.didUndoDocument(in: try required(store.document))
            expect(try Data(contentsOf: mismatchURL) == mismatchBytes && mismatchEditor.draft.annotation.page != nil,
                "An unrelated Undo cannot rewrite or complete the exact retained mismatch record.")
            let mismatchPermit = try required(mismatchReload.captureDiscardPermit())
            expect(mismatchReload.discardSavedDraft(using: mismatchPermit), "Only explicit discard clears the unresolved mismatch record.")
            try replacement.write(to: a)
            await queue.drain(); await settle()

            let duplicateDirectory = root.appendingPathComponent("duplicate-baseline-drafts")
            let duplicateDocument = try required(store.document)
            let duplicatePage = try required(duplicateDocument.page(at: 0)), otherPage = try required(duplicateDocument.page(at: 1))
            let duplicateBounds = CGRect(x: 72, y: 200, width: 220, height: 100)
            let editedAnnotation = PDFAnnotation(bounds: duplicateBounds, forType: .freeText, withProperties: nil)
            editedAnnotation.contents = "TODO"; editedAnnotation.font = .systemFont(ofSize: 14); duplicatePage.addAnnotation(editedAnnotation)
            let otherAnnotation = PDFAnnotation(bounds: duplicateBounds, forType: .freeText, withProperties: nil)
            otherAnnotation.contents = "TODO"; otherAnnotation.font = .systemFont(ofSize: 14); otherPage.addAnnotation(otherAnnotation)
            let duplicateRecovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: duplicateDirectory)
            duplicateRecovery.bind(fileID: aID)
            let duplicateEditor = IPadInlineNoteEditingSession(draft: FreeTextEditDraft(document: duplicateDocument,
                page: duplicatePage, annotation: editedAnnotation))
            duplicateRecovery.track(duplicateEditor); duplicateEditor.values.text = "DONE"
            undo.beginUndoGrouping(); let savedDuplicate = duplicateEditor.save(in: store, canCommit: { true }); undo.endUndoGrouping()
            duplicateRecovery.track(nil)
            undo.beginUndoGrouping(); store.rotatePages(at: IndexSet(integer: 1), clockwise: true); undo.endUndoGrouping()
            expect(savedDuplicate && editedAnnotation.value(forAnnotationKey: .name) == nil
                && otherAnnotation.value(forAnnotationKey: .name) == nil && duplicateRecovery.prepareDocumentUndo(in: duplicateDocument),
                "Two real legacy notes without /NM can share a baseline before an unrelated page Undo.")
            store.undoDocumentChange(); duplicateRecovery.didUndoDocument(in: duplicateDocument)
            expect(try editedAnnotation.contents == "DONE" && otherAnnotation.contents == "TODO"
                && FileManager.default.contentsOfDirectory(at: duplicateDirectory, includingPropertiesForKeys: nil).count == 1,
                "Another page's matching legacy note cannot falsely complete the exact edited annotation's recovery intent.")
            expect(duplicateRecovery.prepareDocumentUndo(in: duplicateDocument), "The next Undo targets the exact legacy note.")
            store.undoDocumentChange(); duplicateRecovery.didUndoDocument(in: duplicateDocument)
            expect(try editedAnnotation.contents == "TODO" && otherAnnotation.contents == "TODO"
                && FileManager.default.contentsOfDirectory(at: duplicateDirectory, includingPropertiesForKeys: nil).isEmpty,
                "Undo on the captured legacy annotation completes its record only after that exact object returns to baseline.")
            await queue.drain(); await settle()

            let faultDirectory = root.appendingPathComponent("fault-drafts"), backup = root.appendingPathComponent("fault-backup")
            let fault = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: faultDirectory)
            fault.bind(fileID: aID)
            let faultEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft()))
            fault.track(faultEditor); faultEditor.values.text = "Keep after failed discard 中文"
            try FileManager.default.moveItem(at: faultDirectory, to: backup)
            try Data("block directory creation".utf8).write(to: faultDirectory)
            expect(!faultEditor.discard() && faultEditor.completion == nil && faultEditor.isDirty
                && faultEditor.error != nil,
                "A real completion-write failure refuses discard and keeps the live text available for retry.")
            let faultRecord = try required(FileManager.default.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil).first)
            let decoded = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: Data(contentsOf: faultRecord))
            expect(!decoded.completed && decoded.values.text == faultEditor.values.text,
                "Failed discard keeps the durable unfinished record, not a false completed flag.")
            try FileManager.default.removeItem(at: faultDirectory); try FileManager.default.moveItem(at: backup, to: faultDirectory)
            expect(try faultEditor.discard() && faultEditor.completion == .discarded
                && FileManager.default.contentsOfDirectory(at: faultDirectory, includingPropertiesForKeys: nil).isEmpty,
                "Retry after restoring storage durably discards the exact retained draft.")
            expect(try aBytes != Data() && Data(contentsOf: a) == replacement,
                "All recovery and failure paths preserve the authored PDF's latest original bytes.")

            let missingDirectory = root.appendingPathComponent("missing-original-drafts")
            let missing = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: missingDirectory)
            missing.bind(fileID: aID)
            try FileManager.default.removeItem(at: a) // Authored disposable fixture only.
            let missingEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft()))
            missing.track(missingEditor); missingEditor.values.text = "Missing original keeps 中文 draft"; missing.flush()
            let missingURL = try required(FileManager.default.contentsOfDirectory(at: missingDirectory, includingPropertiesForKeys: nil).first)
            let missingRecord = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: Data(contentsOf: missingURL))
            expect(missingRecord.sourceDigest == nil && missingRecord.pageDigest != nil
                && missingRecord.values.text == missingEditor.values.text && missing.lastError == nil,
                "Unavailable original hashing cannot prevent checkpointing a working-copy note's text and page fingerprint.")
            missing.track(nil); let beforeMissingReload = store.document
            store.releaseEditorAccess(); access = DocumentAccessCoordinator(saveQueue: queue)
            store = makeStore(); store.setUndoManager(undo)
            expect(store.openPDF(from: a, workingCopyURL: copy) && store.bindLibraryFile(aID)
                && store.document !== beforeMissingReload,
                "A fresh writer reopens the actual working copy while its original is missing.")
            let missingReload = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: missingDirectory)
            missingReload.bind(fileID: aID)
            let missingResult = missingReload.restore()
            if missingResult == nil { print("Inline missing-original restore: \(recoveryFields(missingReload, store: store, directory: missingDirectory))") }
            let missingRestored = try required(missingResult); missingReload.track(missingRestored)
            expect(missingRestored.values.text == missingEditor.values.text && missingRestored.draft.annotation.page == nil
                && missingRestored.draft.document === store.document,
                "Working-copy page content and Library identity restore the exact unfinished draft without its original.")
            expect(missingRestored.discard(), "The restored missing-original draft still has an explicit safe discard.")
            try await exerciseTextColor(root: root.appendingPathComponent("text-color"), defaults: defaults, expect: expect)
            try await exerciseFontFace(root: root.appendingPathComponent("font-face"), defaults: defaults, expect: expect)
        } catch { expect(false, "Inline recovery fixture failed: \(error)") }
        return (checks, failures)
    }

    private static func exerciseTextColor(root: URL, defaults: UserDefaults,
                                          expect: (Bool, String) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("original.pdf"), sourceBytes = fixture(color: .gray)
        try sourceBytes.write(to: source)
        let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
        let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("queue"))
        var access = DocumentAccessCoordinator(saveQueue: queue)
        let feedback = OperationFeedbackCenter(userDefaults: defaults), fileID = UUID(), workspaceID = UUID()
        func makeStore() -> PDFDocumentStore {
            let id = UUID().uuidString
            return PDFDocumentStore(feedbackCenter: feedback,
                metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("\(id)-metadata.json")),
                aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("\(id)-groups.json")),
                workingCopyStore: copies, saveQueue: queue, accessCoordinator: access,
                exportPresenter: IPadDocumentExportPresenter())
        }
        var store = makeStore(); defer { store.releaseEditorAccess() }
        let blue = PDFColorComponents(red: 0.125, green: 0.25, blue: 0.75, alpha: 1)
        let green = PDFColorComponents(red: 0.125, green: 0.625, blue: 0.25, alpha: 1)
        let red = PDFColorComponents(red: 0.75, green: 0.125, blue: 0.125, alpha: 1)
        expect(store.openPDF(from: source) && store.bindLibraryFile(fileID), "Color recovery opens an isolated actual Store.")
        let seed = try required(store.newFreeTextDraft(page: try required(store.document?.page(at: 0)),
            bounds: CGRect(x: 90, y: 400, width: 240, height: 120)))
        var seedValues = seed.values; seedValues.text = "Standard color note 中文"; seedValues.fontColor = blue
        expect(store.saveFreeText(seed, values: seedValues), "Color recovery seeds a standard PDF FreeText through the actual Store.")
        await settleSave(store, queue: queue)
        let copy = try required(store.currentWorkingCopyURL), seedDocument = try required(store.document)
        expect(!store.hasUnsavedChanges && store.workingCopySaveError == nil,
               "The seeded standard color note reaches the actual Store save completion.")
        store.releaseEditorAccess(); access = DocumentAccessCoordinator(saveQueue: queue); store = makeStore()
        expect(store.openPDF(from: source, workingCopyURL: copy) && store.bindLibraryFile(fileID)
            && store.document !== seedDocument, "Color recovery reconstructs a new Store and native PDF document from the working copy.")
        let document = try required(store.document), page = try required(document.page(at: 0))
        let annotation = try required(page.annotations.first { $0.type == "FreeText" })
        expect(FreeTextAnnotationEditing.matchesTextColor(blue, annotation: annotation)
            && annotation.contents == seedValues.text, "The serialized seed retains its exact standard font color and text.")
        let directory = root.appendingPathComponent("drafts")
        let recovery = IPadInlineNoteDraftRecovery(workspaceID: workspaceID, store: store, feedback: feedback, directoryURL: directory)
        recovery.bind(fileID: fileID)
        let editor = IPadInlineNoteEditingSession(draft: FreeTextEditDraft(document: document, page: page, annotation: annotation))
        recovery.track(editor); editor.values.fontColor = green; recovery.flush()
        let recordURL = try required(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let unfinishedBytes = try Data(contentsOf: recordURL)
        let unfinished = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: unfinishedBytes)
        expect(unfinished.values.fontColor == green && unfinished.baseline.fontColor == editor.draft.originalFontColor
            && unfinished.baseline.fontColor != nil && !unfinished.pendingSave
            && FreeTextAnnotationEditing.matchesTextColor(blue, annotation: annotation) && !store.hasUnsavedChanges,
            "A color-only unfinished draft durably captures the initial color without changing the standard annotation.")
        recovery.track(nil); store.releaseEditorAccess(); access = DocumentAccessCoordinator(saveQueue: queue); store = makeStore()
        expect(store.openPDF(from: source, workingCopyURL: copy) && store.bindLibraryFile(fileID)
            && store.document !== document, "A second new Store reopens the color-only sidecar's exact working copy.")
        let restoredDocument = try required(store.document), restoredPage = try required(restoredDocument.page(at: 0))
        let restoredAnnotation = try required(restoredPage.annotations.first { $0.type == "FreeText" })
        let restoredRecovery = IPadInlineNoteDraftRecovery(workspaceID: workspaceID, store: store, feedback: feedback, directoryURL: directory)
        restoredRecovery.bind(fileID: fileID)
        let restoredEditor = try required(restoredRecovery.restore())
        expect(restoredEditor.values.fontColor == green && restoredEditor.values.text == seedValues.text
            && restoredEditor.draft.annotation === restoredAnnotation
            && FreeTextAnnotationEditing.matchesTextColor(blue, annotation: restoredAnnotation) && !store.hasUnsavedChanges,
            "Fresh native recovery restores the selected color as unfinished input while leaving the PDF at its blue baseline.")

        func installRecord(_ bytes: Data, in name: String) throws -> (URL, URL) {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(recordURL.lastPathComponent); try bytes.write(to: url)
            return (folder, url)
        }
        // An accepted intent may be durable while its copy is still at baseline.
        // Same text/geometry/font must not mistake a different color for completion.
        var pending = unfinished; pending.pendingSave = true
        let pendingBytes = try JSONEncoder().encode(pending)
        let (pendingDirectory, pendingURL) = try installRecord(pendingBytes, in: "pending-color")
        let pendingRecovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: pendingDirectory)
        pendingRecovery.bind(fileID: fileID)
        let retryEditor = pendingRecovery.restore()
        let retainedPendingBytes = try Data(contentsOf: pendingURL)
        expect(retryEditor?.values.fontColor == green && retryEditor?.draft.annotation === restoredAnnotation
            && retainedPendingBytes == pendingBytes && !store.hasUnsavedChanges,
            "A pending color-only save whose PDF still has baseline blue retains the exact retry draft instead of clearing it.")

        let (changedDirectory, changedURL) = try installRecord(unfinishedBytes, in: "changed-baseline-color")
        restoredAnnotation.fontColor = PDFPlatformStyle.color(red)
        let changed = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: changedDirectory)
        changed.bind(fileID: fileID)
        let rejectedBaseline = changed.restore(), retainedChangedBytes = try Data(contentsOf: changedURL)
        expect(rejectedBaseline == nil && changed.lastError != nil && retainedChangedBytes == unfinishedBytes,
            "An external baseline-color change alone rejects recovery and preserves the unfinished sidecar.")
        restoredAnnotation.fontColor = PDFPlatformStyle.color(blue)

        var legacyJSON = try required(JSONSerialization.jsonObject(with: unfinishedBytes) as? [String: Any])
        var legacyValues = try required(legacyJSON["values"] as? [String: Any])
        var legacyBaseline = try required(legacyJSON["baseline"] as? [String: Any])
        legacyValues.removeValue(forKey: "fontColor"); legacyBaseline.removeValue(forKey: "fontColor")
        legacyValues["text"] = "Legacy unfinished text 中文"; legacyJSON["values"] = legacyValues; legacyJSON["baseline"] = legacyBaseline
        let legacyBytes = try JSONSerialization.data(withJSONObject: legacyJSON)
        let legacyRecord = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: legacyBytes)
        let (legacyDirectory, _) = try installRecord(legacyBytes, in: "legacy-color")
        let legacy = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: legacyDirectory)
        legacy.bind(fileID: fileID)
        let legacyEditor = legacy.restore()
        expect(legacyRecord.values.fontColor == nil && legacyRecord.baseline.fontColor == nil
            && legacyEditor?.values.fontColor == nil && legacyEditor?.values.text == "Legacy unfinished text 中文"
            && legacyEditor?.draft.annotation === restoredAnnotation
            && FreeTextAnnotationEditing.matchesTextColor(blue, annotation: restoredAnnotation) && !store.hasUnsavedChanges,
            "Legacy JSON with both optional color fields absent decodes and restores while preserving the actual native color.")

        var invalidValues = restoredEditor.values; invalidValues.fontColor = .init(red: 0.5, green: 0.5, blue: 0.5, alpha: .infinity)
        expect(!store.saveFreeText(restoredEditor.draft, values: invalidValues)
            && FreeTextAnnotationEditing.matchesTextColor(blue, annotation: restoredAnnotation) && !store.hasUnsavedChanges,
            "The actual iPad Store rejects a nonfinite explicit color without changing its native annotation or save state.")

        let undo = UndoManager(); undo.groupsByEvent = false; store.setUndoManager(undo)
        restoredRecovery.track(restoredEditor)
        undo.beginUndoGrouping(); let saved = restoredEditor.save(in: store, canCommit: { true }); undo.endUndoGrouping()
        expect(saved && FreeTextAnnotationEditing.matchesTextColor(green, annotation: restoredAnnotation)
            && restoredAnnotation.contents == seedValues.text && restoredAnnotation.bounds == editor.draft.originalBounds,
            "The restored color-only native editor saves its selected color through the production Store.")
        await settleSave(store, queue: queue)
        expect(!store.hasUnsavedChanges && store.workingCopySaveError == nil
            && !FileManager.default.fileExists(atPath: recordURL.path),
            "Only the actual successful working-copy completion clears the saved color sidecar.")
        store.undoDocumentChange()
        expect(FreeTextAnnotationEditing.matchesTextColor(blue, annotation: restoredAnnotation) && !undo.canUndo && undo.canRedo,
            "One actual document Undo restores the original standard blue font color.")
        store.redoDocumentChange()
        expect(FreeTextAnnotationEditing.matchesTextColor(green, annotation: restoredAnnotation)
            && restoredAnnotation.contents == seedValues.text, "Actual document Redo restores green without changing note text.")
        await settleSave(store, queue: queue)
        let savedDocument = try required(PDFDocument(url: copy))
        let savedAnnotation = try required(savedDocument.page(at: 0)?.annotations.first { $0.type == "FreeText" })
        expect(FreeTextAnnotationEditing.matchesTextColor(green, annotation: savedAnnotation)
            && savedAnnotation.contents == seedValues.text && !store.hasUnsavedChanges,
            "The actual working-copy PDF reloads the exact selected standard FreeText color after Save/Undo/Redo.")

        // Capture a real new-note accepted sidecar before MainActor save completion,
        // then replay that crash-window record against the clean native document.
        let namedDirectory = root.appendingPathComponent("named-color")
        var namedRecovery: IPadInlineNoteDraftRecovery? = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store,
            feedback: feedback, directoryURL: namedDirectory)
        namedRecovery?.bind(fileID: fileID)
        let namedEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft(page: try required(restoredDocument.page(at: 1)),
            bounds: CGRect(x: 90, y: 400, width: 240, height: 120))))
        namedRecovery?.track(namedEditor); namedEditor.values.text = "Named accepted color 中文"; namedEditor.values.fontColor = green
        undo.beginUndoGrouping(); let namedSaved = namedEditor.save(in: store, canCommit: { true }); undo.endUndoGrouping()
        let namedURL = try required(FileManager.default.contentsOfDirectory(at: namedDirectory, includingPropertiesForKeys: nil).first)
        let namedBytes = try Data(contentsOf: namedURL)
        let namedRecord = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: namedBytes)
        let namedAnnotation = namedEditor.draft.annotation
        expect(namedSaved && namedRecord.isNew && namedRecord.pendingSave && namedRecord.values.fontColor == green
            && namedRecord.annotationName != nil && namedAnnotation.page === namedEditor.draft.page,
            "The same-name color test captures a real accepted new-note pending intent and its installed standard annotation.")
        namedRecovery?.track(nil); namedRecovery = nil
        await settleSave(store, queue: queue)
        try namedBytes.write(to: namedURL, options: .atomic)
        namedAnnotation.fontColor = PDFPlatformStyle.color(red)
        let wrongName = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: namedDirectory)
        wrongName.bind(fileID: fileID)
        let rejectedName = wrongName.restore(), retainedNamedBytes = try Data(contentsOf: namedURL)
        expect(rejectedName == nil && wrongName.lastError != nil
            && retainedNamedBytes == namedBytes && !store.hasUnsavedChanges,
            "A saved new note with the exact recorded name/text/geometry/font but wrong color cannot falsely clear its pending sidecar.")
        namedAnnotation.fontColor = PDFPlatformStyle.color(green)
        let correctName = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: namedDirectory)
        correctName.bind(fileID: fileID)
        expect(correctName.restore() == nil && correctName.lastError == nil
            && !FileManager.default.fileExists(atPath: namedURL.path),
            "The positive control clears the same accepted named record only when its exact final color also matches.")
        try exerciseCheckpointErrorRecovery(root: root.appendingPathComponent("checkpoint-errors"),
            store: store, fileID: fileID, feedback: feedback, expect: expect)
        let finalSourceBytes = try Data(contentsOf: source)
        expect(finalSourceBytes == sourceBytes, "All color save, recovery, rejection, Undo and serialization paths preserve original PDF bytes.")
    }

    private static func exerciseCheckpointErrorRecovery(root: URL, store: PDFDocumentStore,
                                                          fileID: UUID, feedback: OperationFeedbackCenter,
                                                          expect: (Bool, String) -> Void) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent("drafts"), backup = root.appendingPathComponent("retained-drafts")
        let obstruction = Data("A regular file blocks the actual sidecar directory.".utf8)
        try obstruction.write(to: directory)
        let document = try required(store.document), page = try required(document.page(at: 0))
        let originalURL = try required(store.selectedPDFURL), copyURL = try required(store.currentWorkingCopyURL)
        let originalBefore = try Data(contentsOf: originalURL), copyBefore = try Data(contentsOf: copyURL)
        let annotationIDs = page.annotations.map(ObjectIdentifier.init)
        let couldUndo = store.canUndoDocumentChange, couldRedo = store.canRedoDocumentChange
        let recovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: directory)
        recovery.bind(fileID: fileID)
        let editor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft(page: page,
            bounds: CGRect(x: 120, y: 360, width: 240, height: 120))))
        recovery.track(editor)
        var values = editor.values; values.text = "Retry the stored draft 中文"
        values.fontColor = .init(red: 0.125, green: 0.625, blue: 0.25, alpha: 1)
        editor.values = values
        let blockedBytes = try Data(contentsOf: directory)
        expect(blockedBytes == obstruction && recovery.lastError != nil && editor.error == recovery.lastError
            && editor.values == values && editor.draft.annotation.page == nil && !store.hasUnsavedChanges,
            "A real regular-file directory obstruction fails the native values checkpoint and exposes its exact storage error without committing the draft.")
        try FileManager.default.removeItem(at: directory)
        recovery.flush()
        let recordURL = try required(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let saved = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: Data(contentsOf: recordURL))
        let originalAfterRepair = try Data(contentsOf: originalURL), copyAfterRepair = try Data(contentsOf: copyURL)
        expect(editor.error == nil && recovery.lastError == nil && saved.values.editValues == values
            && !saved.completed && !saved.pendingSave && editor.draft.annotation.page == nil
            && page.annotations.map(ObjectIdentifier.init) == annotationIDs && !store.hasUnsavedChanges
            && store.canUndoDocumentChange == couldUndo && store.canRedoDocumentChange == couldRedo
            && originalAfterRepair == originalBefore && copyAfterRepair == copyBefore,
            "A repaired directory and actual flush clear the checkpoint storage error, persist exact draft values and preserve both PDF files and document Undo.")

        try FileManager.default.moveItem(at: directory, to: backup)
        try obstruction.write(to: directory)
        var invalidValues = values; invalidValues.text = "  \n"
        editor.values = invalidValues
        let storageError = recovery.lastError
        let validationError = try required(FreeTextAnnotationEditing.validationMessage(invalidValues, draft: editor.draft))
        let failedAgain = storageError != nil && editor.error == storageError
        let validationRejected = !editor.save(in: store, canCommit: { true })
        let blockedAgain = try Data(contentsOf: directory)
        expect(failedAgain && blockedAgain == obstruction && storageError != validationError && validationRejected
            && editor.error == validationError && editor.completion == nil && editor.values == invalidValues && !store.hasUnsavedChanges,
            "A second actual checkpoint failure precedes a distinct blank-text Save validation error on the same retained native editor.")
        try FileManager.default.removeItem(at: directory); try FileManager.default.moveItem(at: backup, to: directory)
        recovery.flush()
        let retried = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: Data(contentsOf: recordURL))
        let finalOriginal = try Data(contentsOf: originalURL), finalCopy = try Data(contentsOf: copyURL)
        expect(recovery.lastError == nil && editor.error == validationError && retried.values.editValues == invalidValues
            && !retried.completed && !retried.pendingSave && editor.draft.annotation.page == nil
            && page.annotations.map(ObjectIdentifier.init) == annotationIDs && !store.hasUnsavedChanges
            && store.canUndoDocumentChange == couldUndo && store.canRedoDocumentChange == couldRedo
            && finalOriginal == originalBefore && finalCopy == copyBefore,
            "Successful storage retry clears only its own error and keeps the independent validation error, exact sidecar values and unchanged PDFs/Undo.")
        recovery.track(nil)
    }

    private static func exerciseFontFace(root: URL, defaults: UserDefaults,
        expect: (Bool, String) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalURL = root.appendingPathComponent("original.pdf"), originalBytes = fixture(color: .gray, identicalPages: true)
        try originalBytes.write(to: originalURL)
        let originalFont = try required(UIFont(name: "Helvetica", size: 14)), selectedFont = try required(UIFont(name: "Georgia", size: 14))
        let originalName = originalFont.fontName, selectedName = selectedFont.fontName
        expect(originalName != selectedName, "Font recovery requires two distinct available native canonical faces.")
        let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
        let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("queue"))
        var access = DocumentAccessCoordinator(saveQueue: queue)
        let feedback = OperationFeedbackCenter(userDefaults: defaults), fileID = UUID(), workspaceID = UUID()
        func makeStore() -> PDFDocumentStore {
            let id = UUID().uuidString
            return PDFDocumentStore(feedbackCenter: feedback,
                metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("\(id)-metadata.json")),
                aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("\(id)-groups.json")),
                workingCopyStore: copies, saveQueue: queue, accessCoordinator: access,
                exportPresenter: IPadDocumentExportPresenter())
        }
        var store = makeStore(); defer { store.releaseEditorAccess() }
        expect(store.openPDF(from: originalURL) && store.bindLibraryFile(fileID), "Font recovery opens an isolated actual PDF Store.")
        let seed = try required(store.newFreeTextDraft(page: try required(store.document?.page(at: 0)),
            bounds: CGRect(x: 90, y: 400, width: 240, height: 120)))
        var seedValues = seed.values; seedValues.text = "Standard font face note 中文"; seedValues.fontName = originalName
        let seedColor = PDFColorComponents(red: 0.125, green: 0.25, blue: 0.75, alpha: 1)
        seedValues.fontColor = seedColor
        expect(store.saveFreeText(seed, values: seedValues), "Font recovery seeds an actual standard note with a canonical native Helvetica face.")
        await settleSave(store, queue: queue)
        let copyURL = try required(store.currentWorkingCopyURL), seedDocument = try required(store.document)
        let seededPDF = try required(PDFDocument(url: copyURL))
        expect(!store.hasUnsavedChanges && store.workingCopySaveError == nil
            && seededPDF.page(at: 0)?.annotations.first { $0.type == "FreeText" }?.font?.fontName == originalName,
            "The actual seeded working copy completes and reloads the exact original canonical font face.")
        store.releaseEditorAccess(); access = DocumentAccessCoordinator(saveQueue: queue); store = makeStore()
        expect(store.openPDF(from: originalURL, workingCopyURL: copyURL) && store.bindLibraryFile(fileID)
            && store.document !== seedDocument, "A new writer and native PDF reopen the standard font-face fixture.")
        let document = try required(store.document), page = try required(document.page(at: 0))
        let annotation = try required(page.annotations.first { $0.type == "FreeText" })
        let editor = IPadInlineNoteEditingSession(draft: FreeTextEditDraft(document: document, page: page, annotation: annotation))
        let directory = root.appendingPathComponent("drafts")
        let recovery = IPadInlineNoteDraftRecovery(workspaceID: workspaceID, store: store, feedback: feedback, directoryURL: directory)
        recovery.bind(fileID: fileID); recovery.track(editor); editor.values.fontName = selectedName
        let recordURL = try required(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let unfinishedBytes = try Data(contentsOf: recordURL)
        let unfinished = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: unfinishedBytes)
        expect(editor.draft.values.fontName == nil && editor.draft.originalFontName == originalName
            && unfinished.baseline.fontName == originalName && unfinished.values.fontName == selectedName
            && annotation.font?.fontName == originalName && !store.hasUnsavedChanges,
            "A font-only draft checkpoints its exact original and selected canonical faces without changing the PDF.")
        recovery.track(nil); store.releaseEditorAccess(); access = DocumentAccessCoordinator(saveQueue: queue); store = makeStore()
        expect(store.openPDF(from: originalURL, workingCopyURL: copyURL) && store.bindLibraryFile(fileID)
            && store.document !== document, "A second new writer reconstructs the unfinished font-face draft's native PDF.")
        let restoredDocument = try required(store.document), restoredPage = try required(restoredDocument.page(at: 0))
        let restoredAnnotation = try required(restoredPage.annotations.first { $0.type == "FreeText" })
        let restoredRecovery = IPadInlineNoteDraftRecovery(workspaceID: workspaceID, store: store, feedback: feedback, directoryURL: directory)
        restoredRecovery.bind(fileID: fileID)
        let restoredEditor = try required(restoredRecovery.restore())
        expect(restoredEditor.values.fontName == selectedName && restoredEditor.draft.annotation === restoredAnnotation
            && restoredAnnotation.font?.fontName == originalName && !store.hasUnsavedChanges,
            "Fresh native recovery keeps the selected canonical face in the editor while the standard PDF retains its original face.")
        func install(_ bytes: Data, name: String) throws -> (URL, URL) {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(recordURL.lastPathComponent); try bytes.write(to: url)
            return (folder, url)
        }
        var legacyJSON = try required(JSONSerialization.jsonObject(with: unfinishedBytes) as? [String: Any])
        var legacyValues = try required(legacyJSON["values"] as? [String: Any]), legacyBaseline = try required(legacyJSON["baseline"] as? [String: Any])
        legacyValues.removeValue(forKey: "fontName"); legacyBaseline.removeValue(forKey: "fontName")
        legacyValues["text"] = "Legacy font draft 中文"; legacyJSON["values"] = legacyValues; legacyJSON["baseline"] = legacyBaseline
        let legacyBytes = try JSONSerialization.data(withJSONObject: legacyJSON)
        let legacyRecord = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: legacyBytes)
        let (legacyDirectory, _) = try install(legacyBytes, name: "legacy-font")
        let legacyRecovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: legacyDirectory)
        legacyRecovery.bind(fileID: fileID)
        let legacyEditor = legacyRecovery.restore()
        expect(legacyRecord.baseline.fontName == nil && legacyRecord.values.fontName == nil
            && legacyEditor?.values.fontName == nil && legacyEditor?.values.text == "Legacy font draft 中文"
            && legacyEditor?.draft.annotation === restoredAnnotation && restoredAnnotation.font?.fontName == originalName,
            "Legacy JSON missing both font-name fields restores with an unknown baseline face and keeps the current native font.")
        let (changedDirectory, changedURL) = try install(unfinishedBytes, name: "changed-baseline-font")
        restoredAnnotation.font = selectedFont
        let changedRecovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: changedDirectory)
        changedRecovery.bind(fileID: fileID)
        let rejectedBaseline = changedRecovery.restore(), retainedBaselineBytes = try Data(contentsOf: changedURL)
        expect(rejectedBaseline == nil && changedRecovery.lastError != nil && retainedBaselineBytes == unfinishedBytes,
            "An external font-face-only baseline change rejects recovery and retains the exact sidecar.")
        restoredAnnotation.font = originalFont
        var pendingRecord = unfinished; pendingRecord.pendingSave = true
        let pendingBytes = try JSONEncoder().encode(pendingRecord)
        let (pendingDirectory, pendingURL) = try install(pendingBytes, name: "pending-font")
        let pendingRecovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: pendingDirectory)
        pendingRecovery.bind(fileID: fileID)
        let pendingEditor = pendingRecovery.restore(), retainedPendingBytes = try Data(contentsOf: pendingURL)
        expect(pendingEditor?.values.fontName == selectedName && pendingEditor?.draft.annotation === restoredAnnotation
            && retainedPendingBytes == pendingBytes && !store.hasUnsavedChanges,
            "A pending save with equal text/geometry/size/color but the original font face retains the exact retry editor instead of clearing its sidecar.")
        let missingName = "Dogear-Unavailable-Font-\(UUID())"
        var invalid = restoredEditor.values; invalid.fontName = missingName
        expect(UIFont(name: missingName, size: 14) == nil && !store.saveFreeText(restoredEditor.draft, values: invalid)
            && restoredAnnotation.font?.fontName == originalName && !store.hasUnsavedChanges,
            "The actual iPad Store rejects an unavailable explicit font without mutating its standard annotation.")
        let undo = UndoManager(); undo.groupsByEvent = false; store.setUndoManager(undo)
        restoredRecovery.track(restoredEditor)
        undo.beginUndoGrouping(); let saved = restoredEditor.save(in: store, canCommit: { true }); undo.endUndoGrouping()
        expect(saved && restoredAnnotation.font?.fontName == selectedName && restoredAnnotation.font?.pointSize == 14
            && restoredAnnotation.contents == seedValues.text && restoredAnnotation.bounds == seed.originalBounds
            && FreeTextAnnotationEditing.matchesTextColor(seedColor, annotation: restoredAnnotation),
            "A restored native font-only editor saves the exact canonical face and preserves text/geometry/size/color.")
        await settleSave(store, queue: queue)
        expect(!store.hasUnsavedChanges && store.workingCopySaveError == nil && !FileManager.default.fileExists(atPath: recordURL.path),
            "Only actual working-copy completion clears the saved canonical font-face sidecar.")
        let pendingPositive = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: pendingDirectory)
        pendingPositive.bind(fileID: fileID)
        expect(pendingPositive.restore() == nil && pendingPositive.lastError == nil && !FileManager.default.fileExists(atPath: pendingURL.path),
            "The same pending record completes only after the actual standard PDF has the exact selected canonical face.")
        store.undoDocumentChange()
        expect(restoredAnnotation.font?.fontName == originalName && restoredAnnotation.font?.pointSize == 14 && !undo.canUndo && undo.canRedo,
            "One actual document Undo restores the exact original canonical face.")
        store.redoDocumentChange()
        expect(restoredAnnotation.font?.fontName == selectedName && restoredAnnotation.contents == seedValues.text,
            "Actual document Redo restores the exact selected canonical face without changing text.")
        await settleSave(store, queue: queue)
        let reloadedPDF = try required(PDFDocument(url: copyURL))
        let reloadedNote = try required(reloadedPDF.page(at: 0)?.annotations.first { $0.type == "FreeText" })
        expect(reloadedNote.font?.fontName == selectedName && reloadedNote.font?.pointSize == 14
            && reloadedNote.contents == seedValues.text && reloadedNote.value(forAnnotationKey: .defaultAppearance) is String,
            "The actual working-copy disk readback retains the exact canonical font face and standard /DA.")
        let namedDirectory = root.appendingPathComponent("named-font")
        var namedRecovery: IPadInlineNoteDraftRecovery? = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store,
            feedback: feedback, directoryURL: namedDirectory)
        namedRecovery?.bind(fileID: fileID)
        let namedEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft(page: try required(restoredDocument.page(at: 1)),
            bounds: CGRect(x: 90, y: 400, width: 240, height: 120))))
        namedRecovery?.track(namedEditor); namedEditor.values.text = "Named font pending 中文"; namedEditor.values.fontName = selectedName
        undo.beginUndoGrouping(); let namedSaved = namedEditor.save(in: store, canCommit: { true }); undo.endUndoGrouping()
        let namedURL = try required(FileManager.default.contentsOfDirectory(at: namedDirectory, includingPropertiesForKeys: nil).first)
        let namedBytes = try Data(contentsOf: namedURL)
        let namedRecord = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: namedBytes)
        expect(namedSaved && namedRecord.isNew && namedRecord.pendingSave && namedRecord.annotationName != nil
            && namedRecord.values.fontName == selectedName && namedEditor.draft.annotation.font?.fontName == selectedName,
            "The named font test captures an actual accepted new-note pending intent with its exact selected face.")
        namedRecovery?.track(nil); namedRecovery = nil; await settleSave(store, queue: queue)
        try namedBytes.write(to: namedURL, options: .atomic)
        namedEditor.draft.annotation.font = originalFont
        let wrongName = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: namedDirectory)
        wrongName.bind(fileID: fileID)
        let rejectedName = wrongName.restore(), retainedNamedBytes = try Data(contentsOf: namedURL)
        expect(rejectedName == nil && wrongName.lastError != nil && retainedNamedBytes == namedBytes && !store.hasUnsavedChanges,
            "The exact saved name/text/geometry/size/color with a different font face cannot falsely clear a pending new-note sidecar.")
        namedEditor.draft.annotation.font = selectedFont
        let correctName = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: namedDirectory)
        correctName.bind(fileID: fileID)
        expect(correctName.restore() == nil && correctName.lastError == nil && !FileManager.default.fileExists(atPath: namedURL.path),
            "The positive named-record control completes only when the canonical final font face matches exactly.")

        let defaultDirectory = root.appendingPathComponent("default-font")
        var defaultRecovery: IPadInlineNoteDraftRecovery? = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store,
            feedback: feedback, directoryURL: defaultDirectory)
        defaultRecovery?.bind(fileID: fileID)
        let defaultEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft(page: try required(store.document?.page(at: 1)),
            bounds: CGRect(x: 320, y: 200, width: 200, height: 100))))
        let defaultFaceBefore = try required(defaultEditor.draft.annotation.font?.fontName)
        defaultRecovery?.track(defaultEditor); defaultEditor.values.text = "Default font recovery 中文"
        undo.beginUndoGrouping(); let defaultSaved = defaultEditor.save(in: store, canCommit: { true }); undo.endUndoGrouping()
        let defaultURL = try required(FileManager.default.contentsOfDirectory(at: defaultDirectory, includingPropertiesForKeys: nil).first)
        let defaultBytes = try Data(contentsOf: defaultURL)
        let defaultRecord = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: defaultBytes)
        expect(defaultSaved && defaultRecord.pendingSave && defaultRecord.values.fontName == nil
            && defaultRecord.baseline.fontName == defaultFaceBefore && defaultRecord.annotationName != nil,
            "An actual default-font note captures its original native face and a nil explicit-font pending intent.")
        defaultRecovery?.track(nil); defaultRecovery = nil; await settleSave(store, queue: queue)
        let beforeDefaultReload = store.document
        store.releaseEditorAccess(); access = DocumentAccessCoordinator(saveQueue: queue); store = makeStore()
        expect(store.openPDF(from: originalURL, workingCopyURL: copyURL) && store.bindLibraryFile(fileID)
            && store.document !== beforeDefaultReload, "Default-font recovery reconstructs a new writer from the actual saved working copy.")
        let defaultReload = try required(store.document?.page(at: 1)?.annotations.first {
            $0.type == "FreeText" && $0.contents == defaultEditor.values.text
        })
        let defaultFaceAfter = defaultReload.font?.fontName
        let rawDefaultName = defaultReload.value(forAnnotationKey: .name)
        let actualDefaultName = rawDefaultName as? String
        let actualDefaultColor = FreeTextAnnotationEditing.textColorComponents(of: defaultReload.fontColor ?? .black)
        let expectedDefaultColor = try required(defaultRecord.values.fontColor ?? defaultRecord.baseline.fontColor)
        let defaultFields = "[" + [
            "fontBefore=\(defaultFaceBefore), fontAfter=\(defaultFaceAfter ?? "nil")",
            "expectedNM=\(defaultRecord.annotationName ?? "nil"), actualNM=\(actualDefaultName ?? "nil")",
            "rawNM=\(String(reflecting: rawDefaultName)), rawNMType=\(rawDefaultName.map { String(reflecting: type(of: $0)) } ?? "nil")",
            "expectedText=\(String(reflecting: defaultRecord.values.text)), actualText=\(String(reflecting: defaultReload.contents))",
            "expectedBounds=\(defaultEditor.bounds), actualBounds=\(defaultReload.bounds)",
            "expectedSize=\(defaultRecord.values.fontSize), actualSize=\(String(describing: defaultReload.font?.pointSize))",
            "expectedColor=\(expectedDefaultColor), actualColor=\(String(describing: actualDefaultColor))",
            "isNew=\(defaultRecord.isNew), pendingSave=\(defaultRecord.pendingSave), pendingUndo=\(defaultRecord.pendingUndo)",
            "baselineSemanticMatchCount=\(String(describing: defaultRecord.baselineSemanticMatchCount))",
            "alignment=\(defaultReload.alignment.rawValue), userName=\(String(describing: defaultReload.userName)), print=\(defaultReload.shouldPrint)",
            "borderWidth=\(String(describing: defaultReload.border?.lineWidth)), borderStyle=\(String(describing: defaultReload.border?.style)), dash=\(String(describing: defaultReload.border?.dashPattern))",
            "interiorColor=\(String(describing: defaultReload.interiorColor)), popup=\(defaultReload.popup != nil), action=\(defaultReload.action != nil)",
            "rawRC=\(String(reflecting: defaultReload.value(forAnnotationKey: FreeTextAnnotationEditing.richTextKey)))",
            "rawSubj=\(String(reflecting: defaultReload.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Subj"))))",
            "rawURI=\(String(reflecting: defaultReload.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/URI"))))",
            "rawA=\(String(reflecting: defaultReload.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/A"))))",
            "completed=\(defaultRecord.completed), dirty=\(store.hasUnsavedChanges), saveError=\(String(describing: store.workingCopySaveError))"
        ].joined(separator: ", ") + "]"
        expect(defaultFaceAfter == defaultFaceBefore,
            "Default native font changed during actual disk readback. \(defaultFields)")
        expect(defaultReload.userName == "",
            "The actual SDK working-copy reload represents the Factory's absent author as exactly the empty string. \(defaultFields)")
        if rawDefaultName == nil {
            expect(defaultRecord.baselineSemanticMatchCount == 0,
                "The actual missing-NM writer case requires a known zero pre-save semantic baseline. \(defaultFields)")
        } else {
            expect(actualDefaultName == defaultRecord.annotationName,
                "A present native annotation name must equal the exact saved identity. \(defaultFields)")
        }
        expect(defaultReload.contents == defaultRecord.values.text && defaultReload.bounds == defaultEditor.bounds
            && defaultReload.font?.pointSize == CGFloat(defaultRecord.values.fontSize)
            && FreeTextAnnotationEditing.matchesTextColor(expectedDefaultColor, annotation: defaultReload),
            "Default native final text/geometry/size/color changed during actual disk readback. \(defaultFields)")
        let defaultFreshRecovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: defaultDirectory)
        defaultFreshRecovery.bind(fileID: fileID)
        let defaultRecovered = defaultFreshRecovery.restore()
        let retainedDefault = FileManager.default.fileExists(atPath: defaultURL.path)
        var retainedDefaultBytes: Data?
        if retainedDefault { retainedDefaultBytes = try Data(contentsOf: defaultURL) }
        let recoveryFields = "[returnedEditor=\(defaultRecovered != nil), returnedIsNew=\(String(describing: defaultRecovered?.draft.isNew)), "
            + "returnedDetached=\(defaultRecovered?.draft.annotation.page == nil), lastError=\(String(describing: defaultFreshRecovery.lastError)), "
            + "unresolved=\(defaultFreshRecovery.hasUnresolvedRecord), retained=\(retainedDefault), "
            + "retainedExact=\(retainedDefaultBytes == defaultBytes), annotationCount=\(store.document?.page(at: 1)?.annotations.count ?? -1)]"
        expect(defaultRecovered == nil && defaultFreshRecovery.lastError == nil && !retainedDefault,
            "Fresh recovery must recognize the saved default-font pending record. \(recoveryFields) \(defaultFields)")
        try await exerciseMissingNameSafeguards(root: root.appendingPathComponent("missing-name-safeguards"),
            initialStore: store, record: defaultRecord, originalURL: originalURL, copyURL: copyURL,
            copies: copies, queue: queue, defaults: defaults, feedback: feedback, expect: expect)
        let originalAfter = try Data(contentsOf: originalURL)
        expect(originalAfter == originalBytes, "All font-face editing/recovery/Undo/disk readback paths preserve original PDF bytes.")
    }

    private static func exerciseMissingNameSafeguards(root: URL, initialStore: PDFDocumentStore,
        record: IPadInlineNoteDraftRecovery.Record, originalURL: URL, copyURL: URL,
        copies: PDFWorkingCopyStore, queue: PDFSaveQueue, defaults: UserDefaults,
        feedback: OperationFeedbackCenter, expect: (Bool, String) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var store = initialStore
        defer { if store !== initialStore { store.releaseEditorAccess() } }
        func rebuild() throws {
            let previous = store.document
            store.releaseEditorAccess()
            let access = DocumentAccessCoordinator(saveQueue: queue), id = UUID().uuidString
            store = PDFDocumentStore(feedbackCenter: feedback,
                metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("\(id)-metadata.json")),
                aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("\(id)-groups.json")),
                workingCopyStore: copies, saveQueue: queue, accessCoordinator: access,
                exportPresenter: IPadDocumentExportPresenter())
            expect(store.openPDF(from: originalURL, workingCopyURL: copyURL) && store.bindLibraryFile(record.fileID)
                && store.document !== previous, "Missing-name safeguards reconstruct an actual new writer from disk.")
        }
        func reject(_ bytes: Data, name: String) throws {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(UUID().uuidString)-\(record.fileID.uuidString).json")
            try bytes.write(to: url)
            let nativeDocument = try required(store.document)
            let nativeIDs = (0..<nativeDocument.pageCount).flatMap { nativeDocument.page(at: $0)?.annotations ?? [] }.map(ObjectIdentifier.init)
            let beforeOriginal = try Data(contentsOf: originalURL), beforeCopy = try Data(contentsOf: copyURL)
            let recovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: directory)
            recovery.bind(fileID: record.fileID)
            let restored = recovery.restore()
            let retained = FileManager.default.fileExists(atPath: url.path)
            var afterBytes: Data?
            if retained { afterBytes = try Data(contentsOf: url) }
            let afterIDs = (0..<nativeDocument.pageCount).flatMap { nativeDocument.page(at: $0)?.annotations ?? [] }.map(ObjectIdentifier.init)
            let afterOriginal = try Data(contentsOf: originalURL), afterCopy = try Data(contentsOf: copyURL)
            expect(restored == nil && recovery.lastError != nil && recovery.hasUnresolvedRecord && afterBytes == bytes
                && nativeIDs == afterIDs && store.document === nativeDocument && !store.hasUnsavedChanges
                && beforeOriginal == afterOriginal && beforeCopy == afterCopy,
                "Unsafe missing-name recovery \(name) must retain its exact sidecar and reject a second editor/native annotation. [returned=\(restored != nil), error=\(String(describing: recovery.lastError)), retained=\(retained), exact=\(afterBytes == bytes)]")
        }
        let document = try required(store.document), page = try required(document.page(at: record.pageIndex))
        let target = try required(page.annotations.first { $0.type == "FreeText" && $0.contents == record.values.text })
        target.removeValue(forAnnotationKey: .name) // Actual writer's missing-name condition, also deterministic on a future SDK.
        let recordBytes = try JSONEncoder().encode(record)
        var legacyJSON = try required(JSONSerialization.jsonObject(with: recordBytes) as? [String: Any])
        legacyJSON.removeValue(forKey: "baselineSemanticMatchCount")
        let legacyBytes = try JSONSerialization.data(withJSONObject: legacyJSON)
        let legacy = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: legacyBytes)
        expect(legacy.baselineSemanticMatchCount == nil, "A legacy sidecar missing the optional semantic baseline decodes as unknown, never as zero.")
        try reject(legacyBytes, name: "legacy-unknown")
        var legacyUnmarked = legacy; legacyUnmarked.pendingSave = false
        try reject(JSONEncoder().encode(legacyUnmarked), name: "legacy-false-marker-saved-identical")
        var modernUnmarked = record; modernUnmarked.pendingSave = false
        try reject(JSONEncoder().encode(modernUnmarked), name: "known-zero-false-marker-saved-identical")
        _ = target.setValue("foreign-note-identity", forAnnotationKey: .name)
        try reject(recordBytes, name: "foreign-name")
        target.removeValue(forAnnotationKey: .name)
        let baselineFont = target.font, baselineColor = target.fontColor, baselineBounds = target.bounds
        let baselineBorder = target.border
        let mutations: [(String, () -> Void, () -> Void)] = [
            ("wrong-face", { target.font = UIFont(name: "Georgia", size: CGFloat(record.values.fontSize)) }, { target.font = baselineFont }),
            ("wrong-color", { target.fontColor = .blue }, { target.fontColor = baselineColor }),
            ("wrong-bounds", { target.bounds = baselineBounds.offsetBy(dx: 1, dy: 0) }, { target.bounds = baselineBounds }),
            ("wrong-alignment", { target.alignment = .right }, { target.alignment = .left }),
            ("foreign-author", { target.userName = "Another producer" }, { target.userName = nil }),
            ("whitespace-author", { target.userName = " " }, { target.userName = nil }),
            ("visible-border", {
                let border = PDFBorder(); border.style = .solid; border.lineWidth = 2
                target.border = border
            }, { target.border = baselineBorder }),
            ("nonprintable", { target.shouldPrint = false }, { target.shouldPrint = true }),
            ("foreign-subject", { _ = target.setValue("Other metadata", forAnnotationKey: PDFAnnotationKey(rawValue: "/Subj")) },
                { target.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/Subj")) })
        ]
        for (name, mutate, restore) in mutations {
            mutate()
            if name == "visible-border" {
                expect(target.border?.lineWidth == 2 && target.border?.style == .solid,
                    "The visible-border negative fixture installs an actual two-point native border even when the cold PDF had no border object.")
            }
            try reject(recordBytes, name: name); restore()
        }
        var undoRecord = record; undoRecord.pendingUndo = true
        let undoBytes = try JSONEncoder().encode(undoRecord)
        try reject(undoBytes, name: "undo-note-still-present")
        target.font = try required(UIFont(name: "Georgia", size: CGFloat(record.values.fontSize)))
        try reject(undoBytes, name: "undo-note-still-present-wrong-face")
        target.font = baselineFont
        target.alignment = .right
        try reject(undoBytes, name: "undo-note-still-present-wrong-style")
        target.alignment = .left
        let otherPage = try required(document.page(at: record.pageIndex == 0 ? 1 : 0))
        let originalCrop = otherPage.bounds(for: .cropBox)
        otherPage.setBounds(CGRect(x: 0, y: 0, width: 150, height: 150), for: .cropBox)
        page.removeAnnotation(target); otherPage.addAnnotation(target)
        try reject(undoBytes, name: "undo-moved-note-different-crop")
        try reject(recordBytes, name: "saved-note-moved-off-original-page")
        otherPage.removeAnnotation(target); page.addAnnotation(target); otherPage.setBounds(originalCrop, for: .cropBox)

        let moveControlDirectory = root.appendingPathComponent("same-content-move-control")
        let moveControl = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store,
            feedback: feedback, directoryURL: moveControlDirectory)
        moveControl.bind(fileID: record.fileID)
        let moveControlEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft(page: page,
            bounds: CGRect(x: 40, y: 70, width: 210, height: 90))))
        moveControl.track(moveControlEditor); moveControlEditor.values.text = "An unsubmitted same-content page-move control 中文"
        moveControl.track(nil)
        document.exchangePage(at: 0, withPageAt: 1)
        let countBeforeMoveRestore = (0..<document.pageCount).reduce(0) { $0 + (document.page(at: $1)?.annotations.count ?? 0) }
        let movedControlEditor = moveControl.restore()
        expect(movedControlEditor?.draft.isNew == true && movedControlEditor?.draft.annotation.page == nil
            && movedControlEditor?.values.text == moveControlEditor.values.text && moveControl.lastError == nil
            && target.page === page && document.index(for: page) != record.pageIndex
            && (0..<document.pageCount).reduce(0, { $0 + (document.page(at: $1)?.annotations.count ?? 0) }) == countBeforeMoveRestore,
            "After native exchange of identical-content pages, actual Recovery's source/page fingerprint gate still passes for an unsubmitted collision-free control.")
        try reject(recordBytes, name: "saved-note-native-page-move-same-content")
        document.exchangePage(at: 0, withPageAt: 1)

        let preexistingDirectory = root.appendingPathComponent("preexisting")
        let preexistingRecovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: preexistingDirectory)
        preexistingRecovery.bind(fileID: record.fileID)
        let preexistingEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft(page: page, bounds: record.originalBounds)))
        preexistingRecovery.track(preexistingEditor); preexistingEditor.values = record.values.editValues
        let preexistingURL = try required(FileManager.default.contentsOfDirectory(at: preexistingDirectory, includingPropertiesForKeys: nil).first)
        var preexistingRecord = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: Data(contentsOf: preexistingURL))
        expect(preexistingRecord.baselineSemanticMatchCount == 1 && !preexistingRecord.pendingSave
            && preexistingEditor.draft.annotation.page == nil && !store.hasUnsavedChanges,
            "An actual uncommitted new draft records the preexisting identical standard note before any Save.")
        preexistingRecovery.track(nil); preexistingRecord.pendingSave = true
        try reject(JSONEncoder().encode(preexistingRecord), name: "preexisting-identical-not-committed")

        let faultDirectory = root.appendingPathComponent("pre-save-fault"), backup = root.appendingPathComponent("pre-save-backup")
        let faultRecovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: faultDirectory)
        faultRecovery.bind(fileID: record.fileID)
        let faultEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft(page: page, bounds: record.originalBounds)))
        faultRecovery.track(faultEditor); faultEditor.values.text = "Premutation must persist the exact baseline 中文"
        let faultURL = try required(FileManager.default.contentsOfDirectory(at: faultDirectory, includingPropertiesForKeys: nil).first)
        let durableBefore = try Data(contentsOf: faultURL), nativeBefore = page.annotations.map(ObjectIdentifier.init)
        let faultCopyBefore = try Data(contentsOf: copyURL)
        try FileManager.default.moveItem(at: faultDirectory, to: backup)
        try Data("block the actual pre-save sidecar".utf8).write(to: faultDirectory)
        let faultSaved = faultEditor.save(in: store, canCommit: { true })
        let retainedFault = try Data(contentsOf: backup.appendingPathComponent(faultURL.lastPathComponent))
        let faultCopyAfter = try Data(contentsOf: copyURL)
        expect(!faultSaved && faultEditor.completion == nil && faultEditor.draft.annotation.page == nil
            && faultEditor.error != nil && faultEditor.error == faultRecovery.lastError && retainedFault == durableBefore
            && page.annotations.map(ObjectIdentifier.init) == nativeBefore && !store.hasUnsavedChanges && faultCopyBefore == faultCopyAfter,
            "A real pre-Save checkpoint write failure refuses Store mutation and retains the exact durable draft with its storage error.")
        try FileManager.default.removeItem(at: faultDirectory); try FileManager.default.moveItem(at: backup, to: faultDirectory)
        faultRecovery.track(nil)

        let lateDirectory = root.appendingPathComponent("late-producer")
        var lateRecovery: IPadInlineNoteDraftRecovery? = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store,
            feedback: feedback, directoryURL: lateDirectory)
        lateRecovery?.bind(fileID: record.fileID)
        let lateEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft(page: page, bounds: record.originalBounds)))
        lateRecovery?.track(lateEditor); lateEditor.values.text = "Two producers after the last value publication 中文"
        let lateURL = try required(FileManager.default.contentsOfDirectory(at: lateDirectory, includingPropertiesForKeys: nil).first)
        let beforeProducer = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: Data(contentsOf: lateURL))
        expect(beforeProducer.baselineSemanticMatchCount == 0, "The first producer's last value publication captures a real zero baseline.")
        let otherDraft = try required(store.newFreeTextDraft(page: page, bounds: record.originalBounds))
        let otherSaved = store.saveFreeText(otherDraft, values: lateEditor.values)
        var duringAddCallback = false
        let lateObservation = store.$hasUnsavedChanges.sink { dirty in
            guard dirty, !duringAddCallback, lateEditor.draft.annotation.page != nil, !lateEditor.isFinished else { return }
            duringAddCallback = true
            lateEditor.values.text = "A forbidden callback during native add"
        }
        let lateSaved = lateEditor.save(in: store, canCommit: { true })
        lateObservation.cancel()
        let lateBytes = try Data(contentsOf: lateURL)
        let lateRecord = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: lateBytes)
        expect(otherSaved && lateSaved && lateRecord.pendingSave && lateRecord.baselineSemanticMatchCount == 1,
            "The actual pre-Save hook recomputes and durably records the other producer's identical note added after the last values publication.")
        lateEditor.values.text = "A forbidden late callback after native add"
        let afterLateCallback = try Data(contentsOf: lateURL)
        expect(duringAddCallback && afterLateCallback == lateBytes && lateRecord.baselineSemanticMatchCount == 1
            && lateRecord.values.text == "Two producers after the last value publication 中文",
            "A post-add late values callback cannot reset the accepted pending intent or its pre-save semantic baseline.")
        lateRecovery?.track(nil); lateRecovery = nil; await settleSave(store, queue: queue)
        try rebuild()
        let latePage = try required(store.document?.page(at: lateRecord.pageIndex))
        for annotation in latePage.annotations where annotation.contents == lateRecord.values.text {
            annotation.removeValue(forAnnotationKey: .name)
        }
        expect(latePage.annotations.filter { $0.type == "FreeText" && $0.contents == lateRecord.values.text }.count == 2,
            "The actual cold working-copy fixture contains both identical committed notes.")
        try reject(lateBytes, name: "late-producer-baseline-one")
        var ambiguous = lateRecord; ambiguous.baselineSemanticMatchCount = 0
        try reject(JSONEncoder().encode(ambiguous), name: "two-identical-results")

        let interruptedDirectory = root.appendingPathComponent("interrupted-before-store")
        let interruptedRecovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store,
            feedback: feedback, directoryURL: interruptedDirectory)
        interruptedRecovery.bind(fileID: record.fileID)
        let interruptedPage = try required(store.document?.page(at: record.pageIndex))
        let interruptedEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft(page: interruptedPage,
            bounds: CGRect(x: 40, y: 70, width: 210, height: 90))))
        interruptedRecovery.track(interruptedEditor); interruptedEditor.values.text = "Save intent interrupted before the Store 中文"
        let interruptedNativeIDs = interruptedPage.annotations.map(ObjectIdentifier.init)
        let interruptedCopyBefore = try Data(contentsOf: copyURL)
        var commitChecks = 0
        let interruptedSaved = interruptedEditor.save(in: store, canCommit: {
            commitChecks += 1; return commitChecks < 3
        })
        let interruptedURL = try required(FileManager.default.contentsOfDirectory(at: interruptedDirectory, includingPropertiesForKeys: nil).first)
        let interruptedBytes = try Data(contentsOf: interruptedURL)
        let interruptedRecord = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: interruptedBytes)
        let interruptedCopyAfter = try Data(contentsOf: copyURL)
        expect(!interruptedSaved && commitChecks == 3 && interruptedEditor.completion == nil
            && interruptedRecord.pendingSave && interruptedRecord.baselineSemanticMatchCount == 0
            && interruptedEditor.draft.annotation.page == nil && interruptedPage.annotations.map(ObjectIdentifier.init) == interruptedNativeIDs
            && !store.hasUnsavedChanges && interruptedCopyAfter == interruptedCopyBefore,
            "The actual pre-Save hook durably records its intent before the final canCommit recheck refuses Store mutation.")
        interruptedRecovery.track(nil); try rebuild()
        let interruptedColdPage = try required(store.document?.page(at: interruptedRecord.pageIndex))
        let interruptedCount = interruptedColdPage.annotations.count
        let legacyDirectory = root.appendingPathComponent("legacy-unsubmitted-no-collision")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyURL = legacyDirectory.appendingPathComponent("\(UUID().uuidString)-\(record.fileID.uuidString).json")
        var legacyInterruptedJSON = try required(JSONSerialization.jsonObject(with: interruptedBytes) as? [String: Any])
        legacyInterruptedJSON.removeValue(forKey: "baselineSemanticMatchCount"); legacyInterruptedJSON["pendingSave"] = false
        let legacyInterruptedBytes = try JSONSerialization.data(withJSONObject: legacyInterruptedJSON)
        try legacyInterruptedBytes.write(to: legacyURL, options: .atomic)
        let legacyFresh = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store,
            feedback: feedback, directoryURL: legacyDirectory)
        legacyFresh.bind(fileID: record.fileID)
        let legacyResumed = legacyFresh.restore()
        let legacyRetained = try Data(contentsOf: legacyURL)
        expect(legacyResumed?.draft.isNew == true && legacyResumed?.draft.annotation.page == nil
            && legacyResumed?.values.text == interruptedRecord.values.text && legacyFresh.lastError == nil
            && interruptedColdPage.annotations.count == interruptedCount && !store.hasUnsavedChanges && legacyRetained == legacyInterruptedBytes,
            "A legacy unsubmitted sidecar with unknown semantic count and no named/text/bounds collision remains safely restorable as a detached editor.")
        let interruptedFresh = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store,
            feedback: feedback, directoryURL: interruptedDirectory)
        interruptedFresh.bind(fileID: record.fileID)
        let resumed = interruptedFresh.restore()
        let retainedInterrupted = try Data(contentsOf: interruptedURL)
        expect(resumed?.draft.isNew == true && resumed?.draft.annotation.page == nil
            && resumed?.values.text == interruptedRecord.values.text && interruptedFresh.lastError == nil
            && interruptedColdPage.annotations.count == interruptedCount && !store.hasUnsavedChanges && retainedInterrupted == interruptedBytes,
            "A cold actual Store with a known empty baseline and no native collision restores the interrupted intent as a detached editor without adding a note.")
        let resumedEditor = try required(resumed)
        interruptedFresh.track(resumedEditor)
        let resumedSaved = resumedEditor.save(in: store, canCommit: { true })
        await settleSave(store, queue: queue)
        expect(resumedSaved && interruptedColdPage.annotations.count == interruptedCount + 1
            && interruptedColdPage.annotations.filter { $0.type == "FreeText" && $0.contents == interruptedRecord.values.text }.count == 1
            && !store.hasUnsavedChanges && store.workingCopySaveError == nil && !FileManager.default.fileExists(atPath: interruptedURL.path),
            "Only the user's subsequent explicit Save commits exactly one interrupted note and completes its sidecar after the actual working-copy save.")
        interruptedFresh.track(nil)

        let completionDirectory = root.appendingPathComponent("completion-write-fault")
        let completionBackup = root.appendingPathComponent("completion-write-backup")
        var completionRecovery: IPadInlineNoteDraftRecovery? = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store,
            feedback: feedback, directoryURL: completionDirectory)
        completionRecovery?.bind(fileID: record.fileID)
        let completionPage = try required(store.document?.page(at: record.pageIndex))
        let completionEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft(page: completionPage,
            bounds: CGRect(x: 310, y: 70, width: 210, height: 90))))
        completionRecovery?.track(completionEditor); completionEditor.values.text = "Durable intent despite a completion write failure 中文"
        let completionURL = try required(FileManager.default.contentsOfDirectory(at: completionDirectory, includingPropertiesForKeys: nil).first)
        var completionFaultTriggered = false
        var completionFaultSetupError: String?
        let completionObservation = store.$hasUnsavedChanges.sink { dirty in
            guard dirty, !completionFaultTriggered, completionEditor.draft.annotation.page != nil, !completionEditor.isFinished else { return }
            do {
                try FileManager.default.moveItem(at: completionDirectory, to: completionBackup)
                try Data("block only the post-Store completion marker".utf8).write(to: completionDirectory)
                completionFaultTriggered = true
            } catch { completionFaultSetupError = error.localizedDescription }
        }
        let completionSaved = completionEditor.save(in: store, canCommit: { true })
        completionObservation.cancel()
        var completionPathIsDirectory: ObjCBool = false
        let completionPathExists = FileManager.default.fileExists(atPath: completionDirectory.path, isDirectory: &completionPathIsDirectory)
        expect(completionFaultTriggered && completionFaultSetupError == nil && completionPathExists
            && !completionPathIsDirectory.boolValue && completionRecovery?.lastError != nil,
            "The actual native-add callback must replace the recovery directory with a regular file and trigger a completion storage error. [setupError=\(String(describing: completionFaultSetupError)), recoveryError=\(String(describing: completionRecovery?.lastError))]")
        let durableIntent = try Data(contentsOf: completionBackup.appendingPathComponent(completionURL.lastPathComponent))
        let durableIntentRecord = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: durableIntent)
        expect(completionSaved && durableIntentRecord.pendingSave && !durableIntentRecord.completed && durableIntentRecord.baselineSemanticMatchCount == 0
            && durableIntentRecord.values.text == completionEditor.draft.annotation.contents,
            "The previous atomic checkpoint already retains the exact pending Save intent despite a failed post-Store completion write.")
        try FileManager.default.removeItem(at: completionDirectory)
        try FileManager.default.moveItem(at: completionBackup, to: completionDirectory)
        completionRecovery?.track(nil); completionRecovery = nil
        await settleSave(store, queue: queue); try rebuild()
        let completedColdPage = try required(store.document?.page(at: durableIntentRecord.pageIndex))
        let completedNotes = completedColdPage.annotations.filter { $0.type == "FreeText" && $0.contents == durableIntentRecord.values.text }
        expect(completedNotes.count == 1 && !store.hasUnsavedChanges && store.workingCopySaveError == nil,
            "The cold actual working copy contains exactly the committed note after the post-Store marker write failure.")
        let completedNote = try required(completedNotes.first)
        completedNote.removeValue(forAnnotationKey: .name)
        let completedCount = completedColdPage.annotations.count
        let completedFresh = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store,
            feedback: feedback, directoryURL: completionDirectory)
        completedFresh.bind(fileID: record.fileID)
        let completedEditor = completedFresh.restore()
        expect(completedNote.value(forAnnotationKey: .name) == nil && completedEditor == nil && completedFresh.lastError == nil
            && !completedFresh.hasUnresolvedRecord && !FileManager.default.fileExists(atPath: completionURL.path)
            && completedColdPage.annotations.count == completedCount && !store.hasUnsavedChanges,
            "The cold missing-NM result uses the durable pre-Save intent to complete recovery without a second detached editor or duplicate native note.")

        try rebuild()
        let collisionPage = try required(store.document?.page(at: record.pageIndex))
        let collisionDirectory = root.appendingPathComponent("known-preexisting-collisions")
        let collisionRecovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store,
            feedback: feedback, directoryURL: collisionDirectory)
        collisionRecovery.bind(fileID: record.fileID)
        let persistentBaselineRecovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store,
            feedback: feedback, directoryURL: root.appendingPathComponent("live-named-baseline"))
        persistentBaselineRecovery.bind(fileID: record.fileID)
        let persistentBaselineEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft(page: collisionPage, bounds: record.originalBounds)))
        persistentBaselineRecovery.track(persistentBaselineEditor)
        persistentBaselineEditor.values.text = "A live named different-text standard note predating the new draft"
        persistentBaselineEditor.values.fontName = try required(UIFont(name: "Helvetica", size: 14)).fontName
        let persistentBaselineSaved = persistentBaselineEditor.save(in: store, canCommit: { true })
        await settleSave(store, queue: queue); persistentBaselineRecovery.track(nil)
        let liveBaselineName = persistentBaselineEditor.draft.annotation.value(forAnnotationKey: .name) as? String
        expect(persistentBaselineSaved && liveBaselineName != nil && persistentBaselineEditor.draft.annotation.page === collisionPage
            && !store.hasUnsavedChanges && persistentBaselineRecovery.lastError == nil,
            "An actual saved baseline note retains a live native name before its cold working-copy serialization loss is tested.")
        let collisionUndo = UndoManager(); collisionUndo.groupsByEvent = false; store.setUndoManager(collisionUndo)
        let oldEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft(page: collisionPage, bounds: record.originalBounds)))
        collisionRecovery.track(oldEditor); oldEditor.values.text = "An accepted older note sharing the new draft's bounds"
        oldEditor.values.fontName = try required(UIFont(name: "Helvetica", size: 14)).fontName
        collisionUndo.beginUndoGrouping(); let oldSaved = oldEditor.save(in: store, canCommit: { true }); collisionUndo.endUndoGrouping()
        await settleSave(store, queue: queue)
        let oldCompletedURLs = try FileManager.default.contentsOfDirectory(at: collisionDirectory, includingPropertiesForKeys: nil)
        expect(oldSaved && !store.hasUnsavedChanges && collisionUndo.canUndo && oldCompletedURLs.isEmpty,
            "An actual Recovery owner finishes its older standard note before preparing another draft with the same native bounds.")
        let collisionEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft(page: collisionPage, bounds: record.originalBounds)))
        collisionRecovery.track(collisionEditor); collisionEditor.values.text = "An unsubmitted note after known older same-bounds notes 中文"
        var collisionCommitChecks = 0
        let collisionSaved = collisionEditor.save(in: store, canCommit: {
            collisionCommitChecks += 1; return collisionCommitChecks < 3
        })
        let collisionURL = try required(FileManager.default.contentsOfDirectory(at: collisionDirectory, includingPropertiesForKeys: nil).first)
        let collisionBytes = try Data(contentsOf: collisionURL)
        let collisionRecord = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: collisionBytes)
        expect(!collisionSaved && collisionCommitChecks == 3 && collisionRecord.pendingSave
            && collisionRecord.baselineSemanticMatchCount == 0 && collisionRecord.collisionBaselines?.count == 5
            && collisionRecord.collisionBaselines?.allSatisfy({ $0.text != collisionRecord.values.text && $0.bounds == collisionRecord.originalBounds }) == true,
            "The actual write-ahead checkpoint captures five complete different-text baseline notes sharing its bounds, without committing the new draft.")
        let collisionDocument = try required(store.document)
        let liveDateProfile = try required(collisionRecord.collisionBaselines?.first { $0.text == persistentBaselineEditor.values.text })
        let recordedModification = try required(liveDateProfile.modificationDate)
        let recordedSeconds = recordedModification.timeIntervalSince1970
        let liveModification = persistentBaselineEditor.draft.annotation.modificationDate
        let beforeSerializationIDs = (0..<collisionDocument.pageCount).flatMap { collisionDocument.page(at: $0)?.annotations ?? [] }.map(ObjectIdentifier.init)
        let noOpBytes = try required(collisionDocument.dataRepresentation())
        let afterSerializationIDs = (0..<collisionDocument.pageCount).flatMap { collisionDocument.page(at: $0)?.annotations ?? [] }.map(ObjectIdentifier.init)
        let noOpCopyURL = root.appendingPathComponent("no-operation-native-copy.pdf")
        try noOpBytes.write(to: noOpCopyURL)
        let noOpAccess = DocumentAccessCoordinator(saveQueue: queue)
        let noOpStore = PDFDocumentStore(feedbackCenter: feedback,
            metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("no-operation-metadata.json")),
            aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("no-operation-groups.json")),
            workingCopyStore: copies, saveQueue: queue, accessCoordinator: noOpAccess,
            exportPresenter: IPadDocumentExportPresenter())
        let noOpOpened = noOpStore.openPDF(from: originalURL, workingCopyURL: noOpCopyURL)
        expect(noOpOpened && noOpStore.bindLibraryFile(record.fileID) && noOpStore.document !== collisionDocument,
            "The no-operation native serialization control opens its actual PDF bytes through a fresh Access coordinator and Store.")
        let noOpDocument = try required(noOpStore.document)
        let noOpBaseline = try required(noOpDocument.page(at: collisionRecord.pageIndex)?.annotations.first { $0.contents == persistentBaselineEditor.values.text })
        expect(recordedSeconds.isFinite && recordedSeconds != floor(recordedSeconds)
            && liveModification == recordedModification && persistentBaselineEditor.draft.annotation.modificationDate == liveModification
            && beforeSerializationIDs == afterSerializationIDs
            && noOpBaseline.modificationDate?.timeIntervalSince1970 == floor(recordedSeconds),
            "An actual production checkpoint retains fractional /M while unchanged native serialization and cold Store readback produce exactly its floored whole second. [recorded=\(recordedSeconds), live=\(String(describing: liveModification?.timeIntervalSince1970)), cold=\(String(describing: noOpBaseline.modificationDate?.timeIntervalSince1970))]")
        let noOpDirectory = root.appendingPathComponent("no-operation-date-recovery")
        try FileManager.default.createDirectory(at: noOpDirectory, withIntermediateDirectories: true)
        let noOpSidecarURL = noOpDirectory.appendingPathComponent("\(UUID().uuidString)-\(record.fileID.uuidString).json")
        try collisionBytes.write(to: noOpSidecarURL)
        let noOpRecovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: noOpStore,
            feedback: feedback, directoryURL: noOpDirectory)
        noOpRecovery.bind(fileID: record.fileID)
        let noOpIDs = (0..<noOpDocument.pageCount).flatMap { noOpDocument.page(at: $0)?.annotations ?? [] }.map(ObjectIdentifier.init)
        let noOpResumed = noOpRecovery.restore()
        let retainedNoOpBytes = try Data(contentsOf: noOpSidecarURL)
        let retainedNoOpCopy = try Data(contentsOf: noOpCopyURL)
        let noOpAfterIDs = (0..<noOpDocument.pageCount).flatMap { noOpDocument.page(at: $0)?.annotations ?? [] }.map(ObjectIdentifier.init)
        expect(noOpResumed?.draft.isNew == true && noOpResumed?.draft.annotation.page == nil
            && noOpResumed?.values == collisionRecord.values.editValues && noOpRecovery.lastError == nil
            && noOpRecovery.hasUnresolvedRecord && !noOpStore.hasUnsavedChanges
            && retainedNoOpBytes == collisionBytes && retainedNoOpCopy == noOpBytes && noOpIDs == noOpAfterIDs,
            "Directed native /M truncation alone preserves a detached unfinished draft on cold recovery without changing its sidecar, serialized PDF, or existing annotations. \(recoveryFields(noOpRecovery, store: noOpStore, directory: noOpDirectory))")
        noOpRecovery.track(nil); noOpStore.releaseEditorAccess()
        let ordinaryUndoAllowed = collisionRecovery.prepareDocumentUndo(in: collisionDocument)
        store.undoDocumentChange(); collisionRecovery.didUndoDocument(in: collisionDocument)
        let afterOlderUndo = try Data(contentsOf: collisionURL)
        expect(ordinaryUndoAllowed && oldEditor.draft.annotation.page == nil && collisionEditor.draft.annotation.page == nil
            && collisionEditor.completion == nil && afterOlderUndo == collisionBytes && store.document === collisionDocument,
            "Undo of the older accepted native object cannot consume another draft's new write-ahead sidecar even when document and bounds are shared.")
        collisionRecovery.track(nil); await settleSave(store, queue: queue); try rebuild()
        let coldCollisionPage = try required(store.document?.page(at: collisionRecord.pageIndex))
        let coldCollisionCount = coldCollisionPage.annotations.count
        let coldCollisionCopy = try Data(contentsOf: copyURL)
        let coldCollision = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store,
            feedback: feedback, directoryURL: collisionDirectory)
        coldCollision.bind(fileID: record.fileID)
        let collisionResumed = coldCollision.restore()
        let retainedCollision = try Data(contentsOf: collisionURL), coldCollisionCopyAfter = try Data(contentsOf: copyURL)
        let coldNamedBaseline = try required(coldCollisionPage.annotations.first { $0.contents == persistentBaselineEditor.values.text })
        expect(collisionResumed?.draft.isNew == true && collisionResumed?.draft.annotation.page == nil
            && collisionResumed?.values == collisionRecord.values.editValues && coldCollision.lastError == nil
            && coldCollisionPage.annotations.count == coldCollisionCount && !store.hasUnsavedChanges
            && retainedCollision == collisionBytes && coldCollisionCopyAfter == coldCollisionCopy
            && collisionRecord.collisionBaselines?.first(where: { $0.text == persistentBaselineEditor.values.text })?.annotationName == liveBaselineName
            && coldNamedBaseline.value(forAnnotationKey: .name) == nil,
            "A cold actual Store restores the same-bounds unfinished draft only after the captured different-text baseline notes match exactly with no increase in their count. \(recoveryFields(coldCollision, store: store, directory: collisionDirectory))")
        let baselineNote = try required(coldCollisionPage.annotations.first { $0.type == "FreeText" && $0.contents == record.values.text })
        let nativeModification = coldNamedBaseline.modificationDate
        coldNamedBaseline.modificationDate = Date(timeIntervalSince1970: floor(recordedSeconds) + 1)
        try reject(collisionBytes, name: "collision-baseline-changed-whole-second")
        coldNamedBaseline.modificationDate = nativeModification
        let differentFraction = floor(recordedSeconds) + ((recordedSeconds - floor(recordedSeconds)) == 0.25 ? 0.75 : 0.25)
        coldNamedBaseline.modificationDate = Date(timeIntervalSince1970: differentFraction)
        try reject(collisionBytes, name: "collision-baseline-changed-fraction-same-second")
        coldNamedBaseline.modificationDate = nativeModification
        coldNamedBaseline.modificationDate = nil
        try reject(collisionBytes, name: "collision-baseline-date-to-nil")
        coldNamedBaseline.modificationDate = nativeModification
        _ = coldNamedBaseline.setValue("A different nonnil baseline identity", forAnnotationKey: .name)
        try reject(collisionBytes, name: "collision-baseline-foreign-nonnil-name")
        coldNamedBaseline.removeValue(forAnnotationKey: .name)
        let capturedUnnamed = try required(collisionRecord.collisionBaselines?.first { $0.text == baselineNote.contents })
        expect(capturedUnnamed.annotationName == nil
            && baselineNote.value(forAnnotationKey: .name) == nil,
            "The new-name negative fixture requires an actual captured and cold unnamed baseline note.")
        let nativeBaselineColor: PDFPlatformColor? = baselineNote.color
        expect(capturedUnnamed.annotationColor == nil && capturedUnnamed.rawColorPresent == false
            && nativeBaselineColor == nil && baselineNote.value(forAnnotationKey: .color) == nil,
            "The actual cold baseline note has no native annotation color or /C key, and its checkpoint records that exact absence without a default color.")
        _ = baselineNote.setValue("A newly introduced baseline identity", forAnnotationKey: .name)
        try reject(collisionBytes, name: "collision-baseline-nil-to-named")
        baselineNote.removeValue(forAnnotationKey: .name)
        let collisionBaselineFont = baselineNote.font, collisionBaselineText = baselineNote.contents
        baselineNote.font = try required(UIFont(name: "Georgia", size: 14))
        try reject(collisionBytes, name: "collision-baseline-changed-face")
        baselineNote.font = collisionBaselineFont
        baselineNote.contents = "An unrecorded changed baseline note"
        try reject(collisionBytes, name: "collision-baseline-changed-text")
        baselineNote.contents = collisionBaselineText
        baselineNote.alignment = .right
        try reject(collisionBytes, name: "collision-baseline-changed-style")
        baselineNote.alignment = .left
        baselineNote.color = .blue
        try reject(collisionBytes, name: "collision-baseline-absent-to-real-color")
        let colorProbeDirectory = root.appendingPathComponent("colored-collision-baseline")
        let colorProbe = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store,
            feedback: feedback, directoryURL: colorProbeDirectory)
        colorProbe.bind(fileID: record.fileID)
        let colorProbeEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft(page: coldCollisionPage, bounds: record.originalBounds)))
        colorProbe.track(colorProbeEditor); colorProbeEditor.values.text = collisionRecord.values.text
        let colorProbeURL = try required(FileManager.default.contentsOfDirectory(at: colorProbeDirectory, includingPropertiesForKeys: nil).first)
        let colorProbeBytes = try Data(contentsOf: colorProbeURL)
        let colorProbeRecord = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: colorProbeBytes)
        let coloredProfile = try required(colorProbeRecord.collisionBaselines?.first { $0.text == baselineNote.contents })
        expect(coloredProfile.annotationColor == FreeTextAnnotationEditing.textColorComponents(of: .blue)
            && coloredProfile.rawColorPresent == true && baselineNote.value(forAnnotationKey: .color) != nil,
            "The actual production checkpoint captures a present standard /C and its exact native blue RGBA separately from absent color.")
        colorProbe.track(nil); baselineNote.removeValue(forAnnotationKey: .color)
        try reject(colorProbeBytes, name: "collision-baseline-real-to-absent-color")
        let extra = FreeTextAnnotationFactory.make(bounds: baselineNote.bounds)
        extra.font = baselineNote.font; extra.fontColor = baselineNote.fontColor
        let baselineNativeColor: PDFPlatformColor? = baselineNote.color
        if let color = baselineNativeColor { extra.color = color }
        else { extra.removeValue(forAnnotationKey: .color) }
        extra.modificationDate = baselineNote.modificationDate
        if let name = baselineNote.value(forAnnotationKey: .name) as? String { _ = extra.setValue(name, forAnnotationKey: .name) }
        extra.contents = "An unrecorded new different-text collision"
        coldCollisionPage.addAnnotation(extra)
        try reject(collisionBytes, name: "collision-baseline-new-note")
        extra.contents = baselineNote.contents
        extra.modificationDate = baselineNote.modificationDate
        let duplicateProbeDirectory = root.appendingPathComponent("duplicate-profile-prerequisite")
        let duplicateProbe = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store,
            feedback: feedback, directoryURL: duplicateProbeDirectory)
        duplicateProbe.bind(fileID: record.fileID)
        let duplicateProbeEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft(page: coldCollisionPage, bounds: record.originalBounds)))
        duplicateProbe.track(duplicateProbeEditor); duplicateProbeEditor.values.text = collisionRecord.values.text
        let duplicateProbeURL = try required(FileManager.default.contentsOfDirectory(at: duplicateProbeDirectory, includingPropertiesForKeys: nil).first)
        let duplicateProbeRecord = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: Data(contentsOf: duplicateProbeURL))
        let originalProfile = capturedUnnamed
        expect(collisionRecord.collisionBaselines?.filter { $0 == originalProfile }.count == 1
            && duplicateProbeRecord.collisionBaselines?.filter { $0 == originalProfile }.count == 2,
            "The actual production checkpoint confirms the negative fixture increases one exact captured native profile from one note to two.")
        duplicateProbe.track(nil)
        try reject(collisionBytes, name: "collision-baseline-count-increased")
        coldCollisionPage.removeAnnotation(extra)

        let orderedPair = coldCollisionPage.annotations.filter { $0.type == "FreeText" && $0.contents == lateRecord.values.text }
        guard orderedPair.count == 2 else { throw FixtureError.missingDraft }
        let oldPairNames = orderedPair.map { $0.value(forAnnotationKey: .name) as? String }
        _ = orderedPair[0].setValue("Baseline.A", forAnnotationKey: .name)
        _ = orderedPair[1].setValue("Baseline.B", forAnnotationKey: .name)
        orderedPair[0].modificationDate = nil; orderedPair[1].modificationDate = nil
        let orderDirectory = root.appendingPathComponent("mixed-name-loss-order")
        let orderRecovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store,
            feedback: feedback, directoryURL: orderDirectory)
        orderRecovery.bind(fileID: record.fileID)
        let orderEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft(page: coldCollisionPage, bounds: record.originalBounds)))
        orderRecovery.track(orderEditor); orderEditor.values.text = collisionRecord.values.text
        let orderURL = try required(FileManager.default.contentsOfDirectory(at: orderDirectory, includingPropertiesForKeys: nil).first)
        let orderBytes = try Data(contentsOf: orderURL)
        let orderRecord = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: orderBytes)
        let profileA = try required(orderRecord.collisionBaselines?.first { $0.annotationName == "Baseline.A" })
        let profileB = try required(orderRecord.collisionBaselines?.first { $0.annotationName == "Baseline.B" })
        var comparedA = profileA; comparedA.annotationName = profileB.annotationName
        expect(comparedA == profileB,
            "The actual production checkpoint captures two otherwise identical native profiles whose only difference is their known A/B name.")
        orderRecovery.track(nil)
        orderedPair[0].modificationDate = Date(timeIntervalSince1970: floor(recordedSeconds))
        try reject(orderBytes, name: "collision-baseline-nil-to-date")
        orderedPair[0].modificationDate = nil
        orderedPair[0].removeValue(forAnnotationKey: .name)
        _ = orderedPair[1].setValue("Baseline.A", forAnnotationKey: .name)
        let nilFirstOrder = coldCollisionPage.annotations.filter { $0 === orderedPair[0] || $0 === orderedPair[1] }.map(ObjectIdentifier.init)
        let nilFirst = orderRecovery.restore()
        coldCollisionPage.removeAnnotation(orderedPair[0]); coldCollisionPage.addAnnotation(orderedPair[0])
        let namedFirstOrder = coldCollisionPage.annotations.filter { $0 === orderedPair[0] || $0 === orderedPair[1] }.map(ObjectIdentifier.init)
        let namedFirst = orderRecovery.restore()
        let orderRetained = try Data(contentsOf: orderURL)
        expect(nilFirst?.draft.annotation.page == nil && nilFirst?.values == orderRecord.values.editValues
            && namedFirst?.draft.annotation.page == nil && namedFirst?.values == orderRecord.values.editValues
            && nilFirstOrder == orderedPair.map(ObjectIdentifier.init)
            && namedFirstOrder == orderedPair.reversed().map(ObjectIdentifier.init)
            && orderRecovery.lastError == nil && orderRetained == orderBytes && !store.hasUnsavedChanges,
            "Captured A/B baseline names match surviving nil/A profiles in either actual native annotation order through one-to-one complete compatibility, consuming each recorded note once.")
        for (index, annotation) in orderedPair.enumerated() {
            if let name = oldPairNames[index] { _ = annotation.setValue(name, forAnnotationKey: .name) }
            else { annotation.removeValue(forAnnotationKey: .name) }
        }

        let datePair = coldCollisionPage.annotations.filter { $0.type == "FreeText" && $0.contents == lateRecord.values.text }
        guard datePair.count == 2 else { throw FixtureError.missingDraft }
        let oldDatePairNames = datePair.map { $0.value(forAnnotationKey: .name) as? String }
        let oldDatePairDates = datePair.map(\.modificationDate)
        let dateWholeSecond = floor(recordedSeconds)
        let fractionalA = Date(timeIntervalSince1970: dateWholeSecond + 0.25)
        let fractionalB = Date(timeIntervalSince1970: dateWholeSecond + 0.75)
        for annotation in datePair { _ = annotation.setValue("Date.Baseline.A", forAnnotationKey: .name) }
        datePair[0].modificationDate = fractionalA; datePair[1].modificationDate = fractionalB
        let dateDirectory = root.appendingPathComponent("mixed-date-loss-order")
        let dateRecovery = IPadInlineNoteDraftRecovery(workspaceID: UUID(), store: store,
            feedback: feedback, directoryURL: dateDirectory)
        dateRecovery.bind(fileID: record.fileID)
        let dateEditor = IPadInlineNoteEditingSession(draft: try required(store.newFreeTextDraft(page: coldCollisionPage, bounds: record.originalBounds)))
        dateRecovery.track(dateEditor); dateEditor.values.text = collisionRecord.values.text
        let dateURL = try required(FileManager.default.contentsOfDirectory(at: dateDirectory, includingPropertiesForKeys: nil).first)
        let dateBytes = try Data(contentsOf: dateURL)
        let dateRecord = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: dateBytes)
        let dateProfiles = try required(dateRecord.collisionBaselines?.filter { $0.annotationName == "Date.Baseline.A" })
        let profileFractionA = try required(dateProfiles.first { $0.modificationDate == fractionalA })
        let profileFractionB = try required(dateProfiles.first { $0.modificationDate == fractionalB })
        var comparedFractionA = profileFractionA; comparedFractionA.modificationDate = fractionalB
        expect(dateProfiles.count == 2 && comparedFractionA == profileFractionB,
            "An actual production checkpoint captures two same-name native baseline profiles differing only in their exact .25/.75 modification dates.")
        dateRecovery.track(nil)
        datePair[0].modificationDate = Date(timeIntervalSince1970: dateWholeSecond)
        datePair[1].modificationDate = fractionalA
        let integerFirst = dateRecovery.restore()
        let integerFirstOrder = coldCollisionPage.annotations.filter { $0 === datePair[0] || $0 === datePair[1] }.map(ObjectIdentifier.init)
        coldCollisionPage.removeAnnotation(datePair[0]); coldCollisionPage.addAnnotation(datePair[0])
        let fractionalFirst = dateRecovery.restore()
        let fractionalFirstOrder = coldCollisionPage.annotations.filter { $0 === datePair[0] || $0 === datePair[1] }.map(ObjectIdentifier.init)
        let retainedDateBytes = try Data(contentsOf: dateURL)
        expect(integerFirst?.draft.annotation.page == nil && integerFirst?.values == dateRecord.values.editValues
            && fractionalFirst?.draft.annotation.page == nil && fractionalFirst?.values == dateRecord.values.editValues
            && integerFirstOrder == datePair.map(ObjectIdentifier.init)
            && fractionalFirstOrder == datePair.reversed().map(ObjectIdentifier.init)
            && dateRecovery.lastError == nil && retainedDateBytes == dateBytes && !store.hasUnsavedChanges,
            "An exact surviving fractional /M reserves its baseline while a same-name whole-second result consumes the other record in either actual native annotation order.")
        coldCollisionPage.removeAnnotation(datePair[1]); coldCollisionPage.addAnnotation(datePair[1])
        datePair[1].removeValue(forAnnotationKey: .name)
        let mixedIntegerFirst = dateRecovery.restore()
        let mixedIntegerOrder = coldCollisionPage.annotations.filter { $0 === datePair[0] || $0 === datePair[1] }.map(ObjectIdentifier.init)
        coldCollisionPage.removeAnnotation(datePair[0]); coldCollisionPage.addAnnotation(datePair[0])
        let mixedFractionalFirst = dateRecovery.restore()
        let mixedFractionalOrder = coldCollisionPage.annotations.filter { $0 === datePair[0] || $0 === datePair[1] }.map(ObjectIdentifier.init)
        let retainedMixedDateBytes = try Data(contentsOf: dateURL)
        expect(mixedIntegerFirst?.draft.annotation.page == nil && mixedIntegerFirst?.values == dateRecord.values.editValues
            && mixedFractionalFirst?.draft.annotation.page == nil && mixedFractionalFirst?.values == dateRecord.values.editValues
            && mixedIntegerOrder == datePair.map(ObjectIdentifier.init)
            && mixedFractionalOrder == datePair.reversed().map(ObjectIdentifier.init)
            && dateRecovery.lastError == nil && retainedMixedDateBytes == dateBytes && !store.hasUnsavedChanges,
            "Crossed native name/date loss still consumes each complete baseline once: named integer /M and unnamed exact fractional /M recover in either order without adding compatibility edges.")
        for (index, annotation) in datePair.enumerated() {
            annotation.modificationDate = oldDatePairDates[index]
            if let name = oldDatePairNames[index] { _ = annotation.setValue(name, forAnnotationKey: .name) }
            else { annotation.removeValue(forAnnotationKey: .name) }
        }
    }

    private static func settleSave(_ store: PDFDocumentStore, queue: PDFSaveQueue) async {
        await queue.drain()
        for _ in 0..<100 {
            if !store.hasUnsavedChanges && store.workingCopySaveError == nil { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    private static func recoveryFields(_ recovery: IPadInlineNoteDraftRecovery, store: PDFDocumentStore,
                                       directory: URL) -> String {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let records = urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).map { url -> String in
            guard let bytes = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: bytes) else {
                return "\(url.lastPathComponent):unreadable"
            }
            return [
                "draft=\(record.draftID), new=\(record.isNew), pendingSave=\(record.pendingSave), pendingUndo=\(record.pendingUndo), completed=\(record.completed)",
                "page=\(record.pageIndex), NM=\(String(reflecting: record.annotationName)), text=\(String(reflecting: record.values.text))",
                "originalBounds=\(record.originalBounds), finalBounds=\(FreeTextAnnotationEditing.resolvedBounds(record.values.editValues, originalBounds: record.originalBounds, pageBounds: record.pageBounds))",
                "baselineFace=\(String(reflecting: record.baseline.fontName)), explicitFace=\(String(reflecting: record.values.fontName)), size=\(record.values.fontSize), color=\(String(describing: record.values.fontColor ?? record.baseline.fontColor))",
                "baselineMatches=\(String(describing: record.baselineSemanticMatchCount)), collisionBaselines=\(String(describing: record.collisionBaselines)), collisionMSeconds=\(String(describing: record.collisionBaselines?.map { $0.modificationDate?.timeIntervalSince1970 }))"
            ].joined(separator: "; ")
        }
        var annotations: [String] = []
        if let document = store.document {
            for index in 0..<document.pageCount {
                for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == "FreeText" {
                    let nativeAnnotationColor: PDFPlatformColor? = annotation.color
                    let nativeAnnotationRGBA = nativeAnnotationColor.flatMap { FreeTextAnnotationEditing.textColorComponents(of: $0) }
                    annotations.append([
                        "page=\(index), NM=\(String(reflecting: annotation.value(forAnnotationKey: .name))), text=\(String(reflecting: annotation.contents)), bounds=\(annotation.bounds)",
                        "face=\(String(reflecting: annotation.font?.fontName)), size=\(String(describing: annotation.font?.pointSize)), color=\(String(describing: FreeTextAnnotationEditing.textColorComponents(of: annotation.fontColor ?? .black))), annotationColor=\(String(describing: nativeAnnotationRGBA)), rawC=\(String(reflecting: annotation.value(forAnnotationKey: .color))), modifiedSeconds=\(String(describing: annotation.modificationDate?.timeIntervalSince1970))",
                        "alignment=\(annotation.alignment.rawValue), author=\(String(reflecting: annotation.userName)), print=\(annotation.shouldPrint), border=\(String(describing: annotation.border?.lineWidth))/\(String(describing: annotation.border?.style))/\(String(describing: annotation.border?.dashPattern))",
                        "fill=\(String(describing: annotation.interiorColor)), RC=\(String(reflecting: annotation.value(forAnnotationKey: FreeTextAnnotationEditing.richTextKey))), subject=\(String(reflecting: annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Subj")))), popup=\(annotation.popup != nil), action=\(annotation.action != nil)"
                    ].joined(separator: "; "))
                }
            }
        }
        return "[dirty=\(store.hasUnsavedChanges), saveError=\(String(describing: store.workingCopySaveError)), sidecars=\(urls.count), state={\(recovery.diagnosticState)}, records={\(records.joined(separator: " | "))}, native={\(annotations.joined(separator: " | "))}]"
    }

    private enum FixtureError: Error {
        case missingDraft
        case missingRequiredValue(file: String, line: Int)
    }
    private static func required<T>(_ value: T?, file: StaticString = #fileID, line: Int = #line) throws -> T {
        guard let value else { throw FixtureError.missingRequiredValue(file: String(describing: file), line: line) }
        return value
    }
    private static func settle() async { for _ in 0..<8 { await Task.yield() } }
    private static func fixture(color: UIColor, identicalPages: Bool = false) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage(); color.setFill(); context.cgContext.fill(CGRect(x: 60, y: 80, width: 260, height: 200))
            context.beginPage(); color.setFill()
            context.cgContext.fill(identicalPages ? CGRect(x: 60, y: 80, width: 260, height: 200)
                : CGRect(x: 120, y: 160, width: 180, height: 100))
        }
    }
}
#endif
