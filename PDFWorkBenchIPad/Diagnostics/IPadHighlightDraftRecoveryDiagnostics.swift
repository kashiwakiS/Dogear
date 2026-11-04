#if os(iOS)
import Foundation
import PDFKit
import SwiftUI
import UIKit

/// Real UIKit/PDFKit fixtures use the production editing session and shared
/// writer. Programmatic marked text is not hardware IME or scene-close proof.
@MainActor
enum IPadHighlightDraftRecoveryDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0, failures: [String] = []
        func expect(_ value: Bool, _ message: String) {
            checks += 1; if !value { failures.append(message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearHighlightRecovery-\(UUID())")
        let suite = "DogearHighlightRecovery.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { return (1, ["Could not isolate highlight defaults."]) }
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        do { try await nativeEditing(root: root.appendingPathComponent("native"), defaults: defaults, expect: expect) }
        catch { expect(false, "Native highlight fixture failed: \(error)") }
        do { try await coldRecovery(root: root.appendingPathComponent("cold"), defaults: defaults, expect: expect) }
        catch { expect(false, "Cold highlight fixture failed: \(error)") }
        do { try await saveLifecycle(root: root.appendingPathComponent("save"), defaults: defaults, expect: expect) }
        catch { expect(false, "Highlight save lifecycle fixture failed: \(error)") }
        do { try await newDraftDoesNotBorrowUndoProof(root: root.appendingPathComponent("undo-draft-proof"), defaults: defaults, expect: expect) }
        catch { expect(false, "Highlight Undo draft identity fixture failed: \(error)") }
        do { try await failedIO(root: root.appendingPathComponent("fault"), defaults: defaults, expect: expect) }
        catch { expect(false, "Highlight failure fixture failed: \(error)") }
        do { try await missingOriginal(root: root.appendingPathComponent("missing"), defaults: defaults, expect: expect) }
        catch { expect(false, "Missing-original highlight fixture failed: \(error)") }
        do { try await firstFailureAndConflicts(root: root.appendingPathComponent("conflicts"), defaults: defaults, expect: expect) }
        catch { expect(false, "Highlight first-write/conflict fixture failed: \(error)") }
        do { try await retiredWorkspace(root: root.appendingPathComponent("retired"), defaults: defaults, expect: expect) }
        catch { expect(false, "Retired highlight workspace fixture failed: \(error)") }
        return (checks, failures)
    }

    private static func nativeEditing(root: URL, defaults: UserDefaults, expect: (Bool, String) -> Void) async throws {
        let fixture = try Fixture(root: root, defaults: defaults); defer { fixture.store.releaseEditorAccess() }
        let store = fixture.store
        expect(fixture.openA(), "The native fixture acquires the actual shared writer and Library identity.")
        let session = try fixture.editor()
        let annotation = session.draft.annotation, baseline = session.values
        let bounds = annotation.bounds, points = annotation.quadrilateralPoints
        let host = NativeHost(session: session); defer { host.close() }
        await settle()
        expect(host.native.isFirstResponder && host.native.window === host.window, "Comment typing owns an actual native text view and window.")
        host.native.selectedRange = NSRange(location: (baseline.comment as NSString).length, length: 0)
        host.native.insertText(" 追加中文")
        session.textCommands.refresh(host.native)
        let typed = session.values.comment
        expect(typed == baseline.comment + " 追加中文" && session.textCommands.canUndo,
               "Native typing changes the retained captured comment and exposes independent text Undo.")
        session.textCommands.undo()
        expect(session.values.comment == baseline.comment && host.native.text == baseline.comment,
               "Native text Undo restores the comment without a shared document mutation.")
        session.textCommands.redo()
        expect(session.values.comment == typed && host.native.text == typed,
               "Native text Redo restores the complete retained comment.")
        host.native.selectedRange = NSRange(location: (typed as NSString).length, length: 0)
        host.native.setMarkedText("组合输入", selectedRange: NSRange(location: 4, length: 0))
        let composed = host.native.text ?? ""
        expect(host.native.markedTextRange != nil, "The comment fixture installs an actual UIKit marked-text range.")
        expect(!session.textCommands.commitMarkedTextAndEndEditing(identity: UUID()) && host.native.markedTextRange != nil,
               "Another draft UUID cannot flush the current comment composition.")
        expect(!session.save(in: store, canCommit: { false }) && session.completion == nil
               && host.native.markedTextRange != nil, "A rejected host identity gate preserves composition before Save.")
        expect(session.finishIME() && host.native.markedTextRange == nil && session.values.comment == composed,
               "The captured draft synchronously flushes marked text before presentation removal.")
        session.colorBinding.wrappedValue = Color.red
        expect(abs(PDFPlatformStyle.alphaComponent(of: session.values.color) - PDFPlatformStyle.alphaComponent(of: baseline.color)) < 0.000001,
               "Changing the picker hue preserves the standard highlight's original opacity.")
        expect(annotation.contents == baseline.comment && annotation.color.isEqual(baseline.color)
               && annotation.bounds == bounds && annotation.quadrilateralPoints == points
               && !store.hasUnsavedChanges && !store.canUndoDocumentChange,
               "Comment text history and color drafts do not mutate the PDF or document Undo.")
        fixture.undo.beginUndoGrouping()
        let accepted = session.save(in: store, canCommit: { true })
        fixture.undo.endUndoGrouping()
        expect(accepted && session.completion == .saved && annotation.contents == composed
               && annotation.bounds == bounds && annotation.quadrilateralPoints == points,
               "Explicit Save updates the exact standard annotation once without changing its geometry.")
        expect(!session.save(in: store, canCommit: { true }), "A finished editor cannot submit a second shared mutation.")
        store.undoDocumentChange()
        expect(annotation.contents == baseline.comment && annotation.color.isEqual(baseline.color)
               && !store.canUndoDocumentChange && store.canRedoDocumentChange,
               "One shared document Undo restores both original comment and color.")
        store.redoDocumentChange()
        expect(annotation.contents == composed && !store.canRedoDocumentChange,
               "One shared document Redo restores the complete highlight edit.")
        await fixture.drain()
        let copy = try required(store.currentWorkingCopyURL)
        let roundtrip = try required(PDFDocument(url: copy)?.page(at: 0)?.annotations.first { $0.type == "Highlight" })
        expect(try roundtrip.contents == composed && roundtrip.bounds == bounds && roundtrip.quadrilateralPoints == points
               && IPadHighlightDraftRecovery.ColorValue(session.values.color).matches(roundtrip.color),
               "The actual saved copy roundtrips standard comment, opacity and fractional quadrilateral geometry.")
        expect(try Data(contentsOf: fixture.a) == fixture.aBytes, "Native typing, Save and document Undo leave the original PDF bytes unchanged.")
        host.close()

        let conflict = try fixture.editor()
        conflict.values.comment = "Do not overwrite a later annotation edit"
        fixture.undo.beginUndoGrouping()
        let changed = store.updateHighlight(conflict.draft, color: conflict.draft.color, comment: "Later shared edit")
        fixture.undo.endUndoGrouping()
        expect(changed && !conflict.save(in: store, canCommit: { true }) && conflict.completion == nil
               && conflict.values.comment == "Do not overwrite a later annotation edit" && annotation.contents == "Later shared edit",
               "A real intervening shared mutation rejects the old baseline and preserves its detached values.")
        await fixture.drain()
        let stale = try fixture.editor()
        let staleHost = NativeHost(session: stale); defer { staleHost.close() }
        staleHost.native.selectedRange = NSRange(location: (stale.values.comment as NSString).length, length: 0)
        staleHost.native.setMarkedText("旧稿", selectedRange: NSRange(location: 2, length: 0))
        let retained = staleHost.native.text
        expect(fixture.openB(), "A real native document replacement opens the independent B writer.")
        let bComment = fixture.store.document?.page(at: 0)?.annotations.first?.contents
        expect(!stale.save(in: fixture.store, canCommit: { true }) && stale.completion == nil
               && staleHost.native.markedTextRange != nil && staleHost.native.text == retained
               && fixture.store.document?.page(at: 0)?.annotations.first?.contents == bComment,
               "The old captured editor cannot flush or save into a replacement document.")
        staleHost.close()
        expect(fixture.openA(copy: copy), "The original writer can reopen its saved working copy.")
        let revoked = try fixture.editor()
        let revokedHost = NativeHost(session: revoked); defer { revokedHost.close() }
        revokedHost.native.selectedRange = NSRange(location: (revoked.values.comment as NSString).length, length: 0)
        revokedHost.native.setMarkedText("保留", selectedRange: NSRange(location: 2, length: 0))
        let capturedChange = revokedHost.native.onTextChanged
        revokedHost.native.onTextChanged = { value in capturedChange?(value); store.releaseEditorAccess() }
        expect(!revoked.save(in: store, canCommit: { true }) && !store.canEditDocument && revoked.completion == nil
               && revoked.values.comment.contains("保留") && revoked.draft.annotation.contents == revoked.draft.comment,
               "Losing the actual writer during native flush is revalidated before any shared Save mutation.")
    }

    private static func coldRecovery(root: URL, defaults: UserDefaults, expect: (Bool, String) -> Void) async throws {
        let fixture = try Fixture(root: root, defaults: defaults); defer { fixture.store.releaseEditorAccess() }
        expect(fixture.openA(), "The cold fixture opens its actual standard highlight.")
        let recovery = fixture.recovery(); recovery.bind(fileID: fixture.aID)
        let session = try fixture.editor(); recovery.track(session)
        let host = NativeHost(session: session); defer { host.close() }
        host.native.selectedRange = NSRange(location: (session.values.comment as NSString).length, length: 0)
        host.native.insertText(" 场景关闭中文")
        host.native.setMarkedText("未完成组合", selectedRange: NSRange(location: 5, length: 0))
        session.colorBinding.wrappedValue = Color.green
        expect(recovery.flush() && host.native.markedTextRange == nil, "Lifecycle flush checkpoints the actual captured UIKit composition.")
        let values = session.values, recordURL = try fixture.recordURL()
        let recordBytes = try Data(contentsOf: recordURL)
        let record = try JSONDecoder().decode(IPadHighlightDraftRecovery.Record.self, from: recordBytes)
        expect(record.draftID == session.id && record.fileID == fixture.aID && record.values.comment == values.comment
               && !record.pendingSave && !record.completed, "The typed sidecar records unfinished values under fixed draft and file UUIDs.")
        expect(session.draft.annotation.contents == session.draft.comment && !fixture.store.hasUnsavedChanges
               && !fixture.store.canUndoDocumentChange, "Scene checkpoint leaves the original annotation and document Undo unchanged.")
        host.close(); recovery.track(nil)
        let oldDocument = fixture.store.document
        expect(fixture.coldOpenA() && fixture.store.document !== oldDocument, "Cold recovery uses a fresh Store, coordinator and native PDFDocument.")
        let reload = fixture.recovery(); reload.bind(fileID: fixture.aID)
        let restored = try required(reload.restore())
        expect(try restored.id == session.id && restored.values.comment == values.comment
               && IPadHighlightDraftRecovery.ColorValue(values.color).matches(restored.values.color)
               && restored.draft.document === fixture.store.document && restored.draft.annotation !== session.draft.annotation,
               "Another workspace restores comment and hue against the new exact native annotation identity.")
        expect(try restored.draft.annotation.contents == restored.draft.comment && !fixture.store.hasUnsavedChanges
               && Data(contentsOf: fixture.a) == fixture.aBytes && Data(contentsOf: recordURL) == recordBytes,
               "Cold restore does not automatically commit a PDF edit, alter the original or rewrite the checkpoint.")
        reload.track(restored)
        let trackedRecordBytes = try Data(contentsOf: recordURL)
        let trackedRecord = try JSONDecoder().decode(IPadHighlightDraftRecovery.Record.self, from: trackedRecordBytes)
        expect(trackedRecord.draftID == session.id && trackedRecord.values.comment == values.comment
               && !trackedRecord.pendingSave && !fixture.store.hasUnsavedChanges,
               "Tracking the restored editor checkpoints its current values without a PDF mutation.")
        try authoredPDF(marker: "Changed source", color: .blue).write(to: fixture.a)
        fixture.undo.beginUndoGrouping()
        let changedSourceSave = restored.save(in: fixture.store, canCommit: { true })
        fixture.undo.endUndoGrouping()
        expect(try !changedSourceSave && restored.completion == nil && restored.values.comment == values.comment
               && restored.draft.annotation.contents == restored.draft.comment && !fixture.store.hasUnsavedChanges
               && Data(contentsOf: recordURL) == trackedRecordBytes,
               "A known original replacement rejects live Save before shared mutation and preserves the exact prior recovery payload.")
        reload.track(nil)
        let beforeReplacement = fixture.store.document
        expect(fixture.coldOpenA() && fixture.store.document !== beforeReplacement, "The fixture really loads an externally replaced original into a fresh document.")
        let changed = fixture.recovery(); changed.bind(fileID: fixture.aID)
        expect(try changed.restore() == nil && changed.lastError != nil && changed.hasUnresolvedRecord
               && Data(contentsOf: recordURL) == trackedRecordBytes,
               "Changed source/page content refuses recovery while retaining the exact unresolved sidecar.")
        let stalePermit = try required(changed.captureDiscardPermit())
        expect(fixture.openB(), "A retained mismatch does not prevent opening B."); changed.bind(fileID: fixture.bID)
        let bSession = try fixture.editor(); changed.track(bSession)
        bSession.values.comment = "独立 B 草稿"; expect(changed.flush(), "B checkpoints under its own stable file UUID.")
        changed.track(nil)
        expect(try !changed.discardSavedDraft(using: stalePermit) && fixture.recordURLs().count == 2
               && Data(contentsOf: recordURL) == trackedRecordBytes,
               "A's captured discard capability cannot clear B or overwrite A after a file switch.")
        changed.track(bSession)
        expect(try bSession.discard() && fixture.recordURLs().count == 1 && Data(contentsOf: recordURL) == trackedRecordBytes,
               "Explicit B discard completes only its record and preserves the unrelated source mismatch.")
    }

    private static func saveLifecycle(root: URL, defaults: UserDefaults, expect: (Bool, String) -> Void) async throws {
        let fixture = try Fixture(root: root, defaults: defaults); defer { fixture.store.releaseEditorAccess() }
        expect(fixture.openA(), "The save fixture acquires the actual writer.")
        let recovery = fixture.recovery(); recovery.bind(fileID: fixture.aID)
        let session = try fixture.editor(); recovery.track(session)
        session.values.comment = "Saved 中文, switch before completion"; session.colorBinding.wrappedValue = Color.orange
        fixture.undo.beginUndoGrouping(); let accepted = session.save(in: fixture.store, canCommit: { true }); fixture.undo.endUndoGrouping()
        let recordURL = try fixture.recordURL()
        let pending = try JSONDecoder().decode(IPadHighlightDraftRecovery.Record.self, from: Data(contentsOf: recordURL))
        expect(accepted && pending.pendingSave && !pending.completed && fixture.store.hasUnsavedChanges,
               "Accepted Save durably writes pending intent and retains the sidecar before actual persistence.")
        recovery.track(nil)
        let copy = try required(fixture.store.currentWorkingCopyURL)
        expect(fixture.openB(), "Save can switch to B without draining the queue."); recovery.bind(fileID: fixture.bID)
        expect(fixture.openA(copy: copy), "A's retained dirty native document reopens before its Save callback."); recovery.bind(fileID: fixture.aID)
        expect(try recovery.restore() == nil && fixture.store.hasUnsavedChanges && fixture.recordURLs().count == 1,
               "An already-applied highlight cannot complete its sidecar while the retained writer is dirty.")
        await fixture.drain()
        expect(try !fixture.store.hasUnsavedChanges && fixture.store.workingCopySaveError == nil && fixture.recordURLs().isEmpty,
               "The coordinator's actual clean publication completes the matching pending highlight record.")
        expect(try PDFDocument(url: copy)?.page(at: 0)?.annotations.first?.contents == session.values.comment
               && Data(contentsOf: fixture.a) == fixture.aBytes,
               "The copy really persists the edited standard comment after revisiting A; the original remains unchanged.")

        let undone = try fixture.editor(); recovery.track(undone)
        undone.values.comment = "This saved draft must not return after Undo"
        fixture.undo.beginUndoGrouping(); let savedForUndo = undone.save(in: fixture.store, canCommit: { true }); fixture.undo.endUndoGrouping()
        recovery.track(nil)
        let document = try required(fixture.store.document)
        expect(savedForUndo && recovery.prepareDocumentUndo(in: document), "Undo prepares a durable intent through the production recovery hook.")
        fixture.store.undoDocumentChange(); recovery.didUndoDocument(in: document)
        expect(try undone.draft.annotation.contents == undone.draft.comment && fixture.recordURLs().isEmpty,
               "The actual shared document Undo returns the captured highlight to baseline and completes its recovery intent.")
        expect(fixture.openB(), "The undone writer switches to B without waiting for a save."); recovery.bind(fileID: fixture.bID)
        expect(fixture.openA(copy: copy), "The undone retained A writer can immediately reopen."); recovery.bind(fileID: fixture.aID)
        expect(try recovery.restore() == nil && recovery.lastError == nil && fixture.recordURLs().isEmpty,
               "A no-drain revisit after explicit document Undo does not resurrect the saved comment editor.")
        await fixture.drain()
        expect(try Data(contentsOf: fixture.a) == fixture.aBytes, "Pending Save and Undo preserve the original bytes across file switches.")

        let movedRecovery = fixture.recovery(); movedRecovery.bind(fileID: fixture.aID)
        let movedEditor = try fixture.editor(); movedRecovery.track(movedEditor)
        let originalPage = try required(movedEditor.draft.annotation.page)
        let movedBounds = movedEditor.baselineBounds, movedPoints = movedEditor.baselinePoints
        movedEditor.values.comment = "Saved 中文 follows the moved native page"
        fixture.undo.beginUndoGrouping(); let savedBeforeMove = movedEditor.save(in: fixture.store, canCommit: { true }); fixture.undo.endUndoGrouping()
        movedRecovery.track(nil)
        fixture.undo.beginUndoGrouping(); fixture.store.movePages(fromOffsets: IndexSet(integer: 0), toOffset: 2); fixture.undo.endUndoGrouping()
        expect(savedBeforeMove && fixture.store.document?.page(at: 1) === originalPage
               && fixture.store.document?.index(for: originalPage) == 1 && movedEditor.draft.annotation.page === originalPage,
               "The actual shared page move relocates the saved highlight's original native page from index zero to one.")
        expect(fixture.openB(), "The moved pending writer switches to B without yielding or draining."); movedRecovery.bind(fileID: fixture.bID)
        expect(fixture.openA(copy: copy), "The moved retained A writer immediately reopens."); movedRecovery.bind(fileID: fixture.aID)
        expect(try movedRecovery.restore() == nil && movedRecovery.lastError == nil && fixture.store.hasUnsavedChanges
               && fixture.recordURLs().count == 1 && movedEditor.draft.annotation.page === fixture.store.document?.page(at: 1),
               "A unique already-applied highlight uses its actual moved page while retaining the pending sidecar until persistence.")
        await fixture.drain()
        let movedCopy = try required(PDFDocument(url: copy))
        let savedMovedAnnotation = try required(movedCopy.page(at: 1)?.annotations.first { $0.type == "Highlight" })
        expect(try !fixture.store.hasUnsavedChanges && fixture.recordURLs().isEmpty
               && savedMovedAnnotation.contents == movedEditor.values.comment && savedMovedAnnotation.bounds == movedBounds
               && savedMovedAnnotation.quadrilateralPoints?.map({ PDFPlatformStyle.point(from: $0) }) == movedPoints
               && Data(contentsOf: fixture.a) == fixture.aBytes,
               "Actual queue drain cleans the moved pending record and persists the page-one comment and fractional geometry without altering original bytes.")

        let duplicated = try fixture.editor(); movedRecovery.track(duplicated)
        duplicated.values.comment = "Two actual pages share this final highlight"
        fixture.undo.beginUndoGrouping(); let savedBeforeDuplicate = duplicated.save(in: fixture.store, canCommit: { true }); fixture.undo.endUndoGrouping()
        movedRecovery.track(nil)
        fixture.undo.beginUndoGrouping(); let inserted = fixture.store.duplicatePages(at: IndexSet(integer: 1)); fixture.undo.endUndoGrouping()
        let duplicatedDocument = try required(fixture.store.document)
        let finalMatches = (0..<duplicatedDocument.pageCount).flatMap { duplicatedDocument.page(at: $0)?.annotations ?? [] }
            .filter { $0.type == "Highlight" && $0.contents == duplicated.values.comment }
        let duplicateURL = try fixture.recordURL(), duplicateBytes = try Data(contentsOf: duplicateURL)
        let duplicateColor = try IPadHighlightDraftRecovery.ColorValue(duplicated.values.color)
        let duplicateName = duplicated.draft.annotation.value(forAnnotationKey: .name) as? String
        expect(savedBeforeDuplicate && !inserted.isEmpty && finalMatches.count == 2 && finalMatches[0] !== finalMatches[1]
               && finalMatches.allSatisfy { $0.bounds == duplicated.baselineBounds
                   && $0.quadrilateralPoints?.map({ PDFPlatformStyle.point(from: $0) }) == duplicated.baselinePoints
                   && ($0.value(forAnnotationKey: .name) as? String) == duplicateName && duplicateColor.matches($0.color) },
               "Actual shared page duplication produces two native final-value candidates without fabricating recovery state.")
        let duplicateOpenedB = fixture.openB(); movedRecovery.bind(fileID: fixture.bID)
        let duplicateReopenedA = fixture.openA(copy: copy); movedRecovery.bind(fileID: fixture.aID)
        expect(duplicateOpenedB && duplicateReopenedA, "The duplicate pending writer makes an actual no-drain B/A switch with each captured file binding.")
        expect(try movedRecovery.restore() == nil && movedRecovery.lastError != nil
               && fixture.recordURLs().count == 1 && Data(contentsOf: duplicateURL) == duplicateBytes,
               "Competing final annotations refuse first-match cleanup and preserve the exact pending recovery payload.")
        await fixture.drain()
        expect(try fixture.recordURLs().count == 1 && Data(contentsOf: duplicateURL) == duplicateBytes
               && Data(contentsOf: fixture.a) == fixture.aBytes,
               "Successful PDF persistence cannot silently choose between duplicate final candidates or rewrite their original.")
    }

    private static func newDraftDoesNotBorrowUndoProof(root: URL, defaults: UserDefaults,
                                                      expect: (Bool, String) -> Void) async throws {
        let fixture = try Fixture(root: root, defaults: defaults); defer { fixture.store.releaseEditorAccess() }
        expect(fixture.openA(), "The highlight Undo proof fixture opens an actual isolated Store writer.")
        let recovery = fixture.recovery(); recovery.bind(fileID: fixture.aID)
        let earlier = try fixture.editor(); recovery.track(earlier)
        let document = try required(fixture.store.document), highlight = earlier.draft.annotation
        let originalBounds = highlight.bounds
        let originalPoints = highlight.quadrilateralPoints?.map { PDFPlatformStyle.point(from: $0) }
        let originalColor = try IPadHighlightDraftRecovery.ColorValue(highlight.color)
        earlier.values.comment = "An earlier accepted highlight comment 中文 Y"
        fixture.undo.beginUndoGrouping()
        let earlierSaved = earlier.save(in: fixture.store, canCommit: { true })
        fixture.undo.endUndoGrouping()
        await fixture.drain()
        let copy = try required(fixture.store.currentWorkingCopyURL)
        let savedCopyBytes = try Data(contentsOf: copy), savedCopy = try required(PDFDocument(data: savedCopyBytes))
        let completedURLs = try fixture.recordURLs()
        expect(earlierSaved && earlier.completion == .saved && highlight.contents == earlier.values.comment
               && !fixture.store.hasUnsavedChanges && fixture.store.workingCopySaveError == nil && completedURLs.isEmpty
               && savedCopy.page(at: 0)?.annotations.first { $0.type == "Highlight" }?.contents == earlier.values.comment,
               "The actual earlier Save reaches the queue and disk, completing its old sidecar before a new draft exists.")
        recovery.track(nil)

        let otherPage = try required(document.page(at: 1)), originalRotation = otherPage.rotation
        fixture.undo.beginUndoGrouping()
        fixture.store.rotatePages(at: IndexSet(integer: 1), clockwise: true)
        fixture.undo.endUndoGrouping()
        let rotatedRotation = (originalRotation + 90) % 360
        expect(document.page(at: 1) === otherPage && otherPage.rotation == rotatedRotation
               && fixture.store.hasUnsavedChanges && fixture.store.canUndoDocumentChange && !fixture.undo.canRedo,
               "A real shared Store rotation of another page is the latest document Undo, independent of the earlier highlight Save.")
        let next = try fixture.editor(); recovery.track(next)
        next.values.comment = "A new unfinished highlight comment 中文 Z"
        let nextValues = next.values, nativeIDs = document.page(at: 0)?.annotations.map(ObjectIdentifier.init)
        let undoName = fixture.undo.undoActionName, groupingLevel = fixture.undo.groupingLevel
        var commitChecks = 0
        let rejectedSave = next.save(in: fixture.store, canCommit: {
            commitChecks += 1; return commitChecks < 3
        })
        let recordURL = try fixture.recordURL(), pendingBytes = try Data(contentsOf: recordURL)
        let pending = try JSONDecoder().decode(IPadHighlightDraftRecovery.Record.self, from: pendingBytes)
        expect(!rejectedSave && commitChecks == 3 && next.id != earlier.id && pending.draftID == next.id
               && pending.pendingSave && !pending.pendingUndo && !pending.completed
               && pending.baseline.comment == earlier.values.comment && pending.values.comment == nextValues.comment
               && next.draft.annotation === highlight && highlight.contents == earlier.values.comment && next.completion == nil
               && document.page(at: 0)?.annotations.map(ObjectIdentifier.init) == nativeIDs
               && fixture.undo.undoActionName == undoName && fixture.undo.groupingLevel == groupingLevel && !fixture.undo.canRedo,
               "The third actual canCommit rejects Store mutation after the new UUID's durable Save intent; no artificial Undo group surrounds this rejected Save.")

        // There is no await or queue drain between the new WAL and ordinary Undo.
        let beforeUndoBytes = try required(document.dataRepresentation())
        let prepared = recovery.prepareDocumentUndo(in: document)
        let afterPreparation = try? Data(contentsOf: recordURL)
        expect(prepared && afterPreparation == pendingBytes,
               "An older accepted native annotation cannot mark another draft's new write-ahead record as pending Undo.")
        fixture.store.undoDocumentChange(); recovery.didUndoDocument(in: document)
        expect(fixture.store.document === document && document.page(at: 1) === otherPage
               && otherPage.rotation == originalRotation && highlight.contents == earlier.values.comment
               && fixture.undo.canUndo && fixture.undo.canRedo && fixture.undo.groupingLevel == groupingLevel,
               "Ordinary shared Undo reverses only the actual top rotation and keeps the earlier saved highlight and remaining document history.")
        let retainedBytes = try? Data(contentsOf: recordURL)
        let retained = retainedBytes.flatMap { try? JSONDecoder().decode(IPadHighlightDraftRecovery.Record.self, from: $0) }
        expect(retainedBytes == pendingBytes && retained?.draftID == next.id && retained?.pendingSave == true
               && retained?.pendingUndo == false && retained?.completed == false && next.values == nextValues
               && next.completion == nil && next.isDirty && next.matchesBaseline(in: fixture.store)
               && document.page(at: 0)?.annotations.map(ObjectIdentifier.init) == nativeIDs,
               "Undo of an unrelated rotation preserves the new draft's exact JSON, unfinished editable Chinese values and native annotation identity.")
        let afterUndoBytes = try required(document.dataRepresentation())
        let beforeUndoPDF = try required(PDFDocument(data: beforeUndoBytes)), afterUndoPDF = try required(PDFDocument(data: afterUndoBytes))
        let afterUndoHighlight = try required(afterUndoPDF.page(at: 0)?.annotations.first { $0.type == "Highlight" })
        let sourceAfterUndo = try Data(contentsOf: fixture.a)
        expect(beforeUndoPDF.page(at: 1)?.rotation == rotatedRotation && afterUndoPDF.page(at: 1)?.rotation == originalRotation
               && afterUndoHighlight.contents == earlier.values.comment && afterUndoHighlight.bounds == originalBounds
               && afterUndoHighlight.quadrilateralPoints?.map({ PDFPlatformStyle.point(from: $0) }) == originalPoints
               && originalColor.matches(afterUndoHighlight.color)
               && sourceAfterUndo == fixture.aBytes,
               "Actual PDF byte snapshots confirm only the rotation changed; highlight geometry/comment/color and the original source remain intact.")

        fixture.undo.beginUndoGrouping()
        let acceptedNext = next.save(in: fixture.store, canCommit: { true })
        fixture.undo.endUndoGrouping()
        let acceptedBytes = try Data(contentsOf: recordURL)
        let acceptedRecord = try JSONDecoder().decode(IPadHighlightDraftRecovery.Record.self, from: acceptedBytes)
        expect(acceptedNext && next.completion == .saved && acceptedRecord.draftID == next.id
               && acceptedRecord.pendingSave && !acceptedRecord.pendingUndo && highlight.contents == nextValues.comment,
               "A subsequent real Save grants the new draft its own native Undo proof instead of borrowing the previous Save's identity.")
        recovery.track(nil)
        let acceptedUndoPrepared = recovery.prepareDocumentUndo(in: document)
        fixture.store.undoDocumentChange(); recovery.didUndoDocument(in: document)
        let afterAcceptedUndoURLs = try fixture.recordURLs()
        expect(acceptedUndoPrepared && highlight.contents == earlier.values.comment && otherPage.rotation == originalRotation
               && afterAcceptedUndoURLs.isEmpty && fixture.undo.canUndo && fixture.undo.canRedo,
               "The newly accepted draft's actual document Undo still restores its baseline and completes only its own sidecar.")
        await fixture.drain()
        let finalCopyBytes = try Data(contentsOf: copy), finalCopy = try required(PDFDocument(data: finalCopyBytes))
        let finalSource = try Data(contentsOf: fixture.a), finalURLs = try fixture.recordURLs()
        expect(!fixture.store.hasUnsavedChanges && fixture.store.workingCopySaveError == nil && finalURLs.isEmpty
               && finalCopy.page(at: 1)?.rotation == originalRotation
               && finalCopy.page(at: 0)?.annotations.first { $0.type == "Highlight" }?.contents == earlier.values.comment
               && finalSource == fixture.aBytes,
               "The actual queue persists the restored highlight/rotation state without losing the new draft early or changing the original PDF.")
    }

    private static func failedIO(root: URL, defaults: UserDefaults, expect: (Bool, String) -> Void) async throws {
        let fixture = try Fixture(root: root, defaults: defaults); defer { fixture.store.releaseEditorAccess() }
        expect(fixture.openA(), "The fault fixture acquires a real writer before exercising failed IO.")
        let recovery = fixture.recovery(); recovery.bind(fileID: fixture.aID)
        let session = try fixture.editor(); recovery.track(session)
        session.values.comment = "IO failure keeps 中文 payload"; session.colorBinding.wrappedValue = Color.purple
        expect(recovery.flush(), "The fault test has a real durable unfinished record before breaking storage.")
        let values = session.values, url = try fixture.recordURL(), bytes = try Data(contentsOf: url)
        let backup = root.appendingPathComponent("drafts-backup")
        try FileManager.default.moveItem(at: fixture.directory, to: backup)
        try Data("not a directory".utf8).write(to: fixture.directory)
        let storedBackup = backup.appendingPathComponent(url.lastPathComponent)
        // An empty native group is an independent control, not permission to
        // relax the Store's no-mutation/no-document-Undo assertion below.
        let emptyControl = UndoManager(); emptyControl.groupsByEvent = false
        let emptyBefore = emptyControl.canUndo
        emptyControl.beginUndoGrouping(); let emptyInside = emptyControl.canUndo
        emptyControl.endUndoGrouping(); let emptyAfter = emptyControl.canUndo
        let baselineBefore = session.matchesBaseline(in: fixture.store)
        let dirtyBefore = fixture.store.hasUnsavedChanges
        let undoBefore = fixture.undo.canUndo, storeUndoBefore = fixture.store.canUndoDocumentChange
        let redoBefore = fixture.undo.canRedo, undoGroupingBefore = fixture.undo.groupingLevel
        // Failed intent must never reach PDF mutation. Do not manufacture an
        // empty group in the Store's real UndoManager around this rejected Save.
        let failedSave = session.save(in: fixture.store, canCommit: { true })
        let undoAfter = fixture.undo.canUndo
        let baselineAfter = session.matchesBaseline(in: fixture.store)
        let failureMetadata = "[saveReturned=\(failedSave), completionNil=\(session.completion == nil), valuesEqual=\(session.values == values), errorPresent=\(session.error != nil), nativeContentsBaseline=\(session.draft.annotation.contents == session.draft.comment), storeDirty=\(fixture.store.hasUnsavedChanges), storeCanUndo=\(fixture.store.canUndoDocumentChange), baselineBefore=\(baselineBefore), baselineAfter=\(baselineAfter), dirtyBefore=\(dirtyBefore), storeUndoBefore=\(storeUndoBefore), nativeUndoBefore=\(undoBefore), nativeUndoAfter=\(undoAfter), nativeRedoUnchanged=\(fixture.undo.canRedo == redoBefore), nativeGroupingUnchanged=\(fixture.undo.groupingLevel == undoGroupingBefore), emptyControlBefore=\(emptyBefore), emptyControlInside=\(emptyInside), emptyControlAfter=\(emptyAfter), recoveryErrorPresent=\(recovery.lastError != nil), error=\(session.error ?? "nil")]"
        expect(!failedSave && session.completion == nil && session.values == values && session.error != nil
               && session.draft.annotation.contents == session.draft.comment && !fixture.store.hasUnsavedChanges
               && !fixture.store.canUndoDocumentChange
               && baselineBefore && baselineAfter && !dirtyBefore && !storeUndoBefore && !undoBefore && !undoAfter
               && fixture.undo.canRedo == redoBefore && fixture.undo.groupingLevel == undoGroupingBefore,
               "A real pending-intent write failure prevents PDF Save and preserves all editable values. \(failureMetadata)")
        expect(try !session.discard() && session.completion == nil && session.isDirty && Data(contentsOf: storedBackup) == bytes,
               "Failed durable Discard retains the live payload and the exact previous unfinished JSON.")
        try FileManager.default.removeItem(at: fixture.directory)
        try FileManager.default.moveItem(at: backup, to: fixture.directory)
        expect(try session.discard() && session.completion == .discarded && fixture.recordURLs().isEmpty,
               "Explicit retry after repairing storage completes only the retained draft.")
        expect(try Data(contentsOf: fixture.a) == fixture.aBytes && !fixture.store.hasUnsavedChanges,
               "Both failure paths and discard retry leave the PDF unchanged.")
    }

    private static func missingOriginal(root: URL, defaults: UserDefaults, expect: (Bool, String) -> Void) async throws {
        let fixture = try Fixture(root: root, defaults: defaults); defer { fixture.store.releaseEditorAccess() }
        expect(fixture.openA(), "The missing-original fixture starts with a real standard highlight.")
        let saved = try fixture.editor(); saved.values.comment = "Working-copy baseline"
        fixture.undo.beginUndoGrouping(); let accepted = saved.save(in: fixture.store, canCommit: { true }); fixture.undo.endUndoGrouping()
        await fixture.drain()
        let copy = try required(fixture.store.currentWorkingCopyURL)
        expect(accepted && PDFDocument(url: copy)?.page(at: 0)?.annotations.first?.contents == saved.values.comment,
               "The missing-original test first persists an actual working copy.")
        try FileManager.default.removeItem(at: fixture.a) // Authored disposable original only.
        let recovery = fixture.recovery(); recovery.bind(fileID: fixture.aID)
        let session = try fixture.editor(); recovery.track(session); session.values.comment = "Original missing, retain 中文"
        expect(recovery.flush(), "Missing original access still checkpoints the working-copy comment.")
        let url = try fixture.recordURL()
        let record = try JSONDecoder().decode(IPadHighlightDraftRecovery.Record.self, from: Data(contentsOf: url))
        expect(record.sourceDigest == nil && record.pageDigest != nil && record.values.comment == session.values.comment,
               "Unavailable original hashing preserves text and the required native page fingerprint.")
        recovery.track(nil); let oldDocument = fixture.store.document
        expect(fixture.coldOpenA(copy: copy) && fixture.store.document !== oldDocument,
               "A fresh owner opens the real working copy with its original absent.")
        let reload = fixture.recovery(); reload.bind(fileID: fixture.aID)
        let restored = try required(reload.restore()); reload.track(restored)
        expect(restored.id == session.id && restored.values.comment == session.values.comment
               && restored.draft.annotation.contents == saved.values.comment && !fixture.store.hasUnsavedChanges,
               "Library, page content and annotation baseline restore the missing-original draft without committing it.")
        expect(restored.discard(), "A restored working-copy comment retains an explicit safe Discard.")
    }

    private static func firstFailureAndConflicts(root: URL, defaults: UserDefaults, expect: (Bool, String) -> Void) async throws {
        let fixture = try Fixture(root: root, defaults: defaults); defer { fixture.store.releaseEditorAccess() }
        expect(fixture.openA(), "The first-write fault starts with a real native writer and no sidecar.")
        try Data("not a directory".utf8).write(to: fixture.directory)
        let recovery = fixture.recovery(); recovery.bind(fileID: fixture.aID)
        let session = try fixture.editor(); recovery.track(session)
        let host = NativeHost(session: session); defer { host.close() }
        host.native.selectedRange = NSRange(location: (session.values.comment as NSString).length, length: 0)
        host.native.setMarkedText("首写失败保留中文", selectedRange: NSRange(location: 8, length: 0))
        let captured = host.native.text
        expect(!recovery.flush() && session.completion == nil && session.values.comment == captured
               && session.isDirty && session.error != nil && recovery.lastError != nil,
               "A real first-checkpoint failure reports false and retains the flushed composition in the unfinished session.")
        expect(try session.draft.annotation.contents == session.draft.comment && !fixture.store.hasUnsavedChanges
               && Data(contentsOf: fixture.a) == fixture.aBytes,
               "Failure before any durable record does not manufacture a PDF mutation.")
        try FileManager.default.removeItem(at: fixture.directory)
        expect(recovery.flush(), "Retry with repaired storage checkpoints the same retained payload.")
        let repaired = try JSONDecoder().decode(IPadHighlightDraftRecovery.Record.self, from: Data(contentsOf: fixture.recordURL()))
        expect(repaired.draftID == session.id && repaired.values.comment == captured && !repaired.pendingSave,
               "First-write retry retains the exact draft UUID and Chinese text, rather than creating a replacement draft.")
        host.close()
        expect(session.discard(), "An explicit discard releases the repaired unfinished record.")
        recovery.track(nil)

        // Create both candidates through real checkpoint calls. Temporarily
        // park the first JSON, then return it as an older orphan arriving after
        // the second checkpoint; do not inject fabricated pendingSave state.
        let firstRecovery = fixture.recovery(); firstRecovery.bind(fileID: fixture.aID)
        let first = try fixture.editor(); firstRecovery.track(first); first.values.comment = "First real unfinished draft"
        expect(firstRecovery.flush(), "The first conflicting candidate is an actual unfinished checkpoint.")
        let firstURL = try fixture.recordURL(), firstBytes = try Data(contentsOf: firstURL)
        firstRecovery.track(nil)
        let parked = root.appendingPathComponent("parked-first.json")
        try FileManager.default.moveItem(at: firstURL, to: parked)
        let secondRecovery = fixture.recovery(); secondRecovery.bind(fileID: fixture.aID)
        let second = try fixture.editor(); secondRecovery.track(second); second.values.comment = "Second real unfinished draft"
        expect(secondRecovery.flush(), "The second conflicting candidate is independently checkpointed under the same actual writer.")
        let secondURL = try fixture.recordURL(), secondBytes = try Data(contentsOf: secondURL)
        secondRecovery.track(nil)
        try FileManager.default.moveItem(at: parked, to: firstURL)
        let oldDocument = fixture.store.document
        expect(fixture.coldOpenA() && fixture.store.document !== oldDocument, "Competing-record recovery uses a distinct fresh native document.")
        let collision = fixture.recovery(); collision.bind(fileID: fixture.aID)
        expect(try collision.restore() == nil && collision.hasUnresolvedRecord && collision.lastError != nil
               && fixture.recordURLs().count == 2 && Data(contentsOf: firstURL) == firstBytes && Data(contentsOf: secondURL) == secondBytes,
               "Two actual unfinished candidates refuse automatic selection and retain both exact payloads.")

        try FileManager.default.moveItem(at: firstURL, to: parked)
        let malformedBytes = Data("interrupted or malformed JSON".utf8)
        try malformedBytes.write(to: secondURL) // Disposable record corruption only.
        let malformed = fixture.recovery(); malformed.bind(fileID: fixture.aID)
        expect(try malformed.restore() == nil && malformed.hasUnresolvedRecord && malformed.lastError != nil
               && Data(contentsOf: secondURL) == malformedBytes,
               "Another workspace recognizes the file-UUID suffix of a malformed record and preserves it instead of overwriting it.")
        let permit = try required(malformed.captureDiscardPermit())
        expect(malformed.discardSavedDraft(using: permit) && !FileManager.default.fileExists(atPath: secondURL.path),
               "Malformed recovery still requires an exact document/file/content capability for explicit discard.")
        expect(try Data(contentsOf: fixture.a) == fixture.aBytes && !fixture.store.hasUnsavedChanges,
               "First-write, collision and malformed-record paths leave the standard annotation and original unchanged.")
    }

    private static func retiredWorkspace(root: URL, defaults: UserDefaults, expect: (Bool, String) -> Void) async throws {
        let fixture = try Fixture(root: root, defaults: defaults)
        let library = LibraryStore(userDefaults: defaults,
            storage: try LibraryJSONStore(stateURL: root.appendingPathComponent("library.json")),
            workingCopyStore: fixture.copies)
        let file = try required(library.upsertOpenedURLs([fixture.a], refreshBookmark: false).first)
        let group = try required(library.createGroup(named: "Highlight retiring group"))
        let research = ResearchStore(rootURL: root.appendingPathComponent("research"))
        let commands = ResearchCommandService(store: research)
        let configuration = AIConfigurationStore(configurationURL: root.appendingPathComponent("ai.json"),
            legacyUserDefaults: defaults, secretStore: EmptySecrets())
        let trace = AIHighlightTraceRecorder(fileURL: root.appendingPathComponent("trace.jsonl"), defaults: defaults)
        let runtime = ResearchRuntime(storage: research, configuration: configuration,
            service: AIHighlightWorkflowService(traceRecorder: trace), traceRecorder: trace,
            commands: commands, retrievalSelection: .lexical)
        let services = IPadApplicationServices(library: library, research: research, configuration: configuration,
            language: AppLanguageStore(userDefaults: defaults), commands: commands, runtime: runtime,
            saveQueue: fixture.queue, observesApplication: false,
            beginBackgroundTask: { _ in .invalid }, endBackgroundTask: { _ in })
        var made: [IPadGroupWorkspace] = []
        let workspaceFactory: @MainActor (UUID, UUID, DocumentAccessCoordinator) -> IPadGroupWorkspace = { id, groupID, access in
            let store = makeStore(root: root, feedback: fixture.feedback, copies: fixture.copies, queue: fixture.queue, access: access)
            let workspace = IPadGroupWorkspace(id: id, groupID: groupID, documentStore: store,
                feedbackCenter: fixture.feedback, accessCoordinator: access,
                noteDraftDirectoryURL: root.appendingPathComponent("note-drafts"), highlightDraftDirectoryURL: fixture.directory)
            workspace.state.undoManager.groupsByEvent = false
            made.append(workspace); return workspace
        }
        let tabs = IPadWindowTabs(windowID: UUID(), services: services, defaults: defaults, restore: false,
            sessionFactory: { id in IPadWorkspaceSession(id: id, services: services, userDefaults: defaults,
                accessCoordinator: fixture.access, workspaceFactory: workspaceFactory) })
        defer { _ = tabs.closeWindow(); made.forEach { $0.document.releaseEditorAccess() } }
        let sceneSession = try required(tabs.ensureBlankTab())
        expect(sceneSession.open(file, in: group.id), "The retirement fixture opens through the real scene Session and Library Group.")
        let held = sceneSession.workspace, nativeDocument = try required(held.document.document)
        let item = try required(held.document.annotations.first { $0.kind == .highlight })
        let editor = IPadHighlightEditingSession(draft: try required(held.document.highlightEditDraft(for: item)))
        held.highlightEditingSession = editor
        let documentUndo = held.state.undoManager
        try Data("first sidecar write blocked".utf8).write(to: fixture.directory)
        let host = NativeHost(session: editor); defer { host.close() }
        host.native.selectedRange = NSRange(location: (editor.values.comment as NSString).length, length: 0)
        host.native.setMarkedText("移除组时保留中文", selectedRange: NSRange(location: 8, length: 0))
        let captured = host.native.text
        expect(!tabs.closeWindow() && sceneSession.acceptsUserActions && sceneSession.workspace === held
               && held.highlightEditingSession === editor && held.document.document === nativeDocument,
               "Failed real tab/window preparation refuses teardown and keeps the exact live draft owner.")
        expect(library.deleteGroup(group), "Another Library mutation really removes the active Group despite its blocked checkpoint.")
        await settle()
        expect(sceneSession.groupID == LibraryGroup.ungroupedID
               && sceneSession.workspacesNeedingDraftRecovery.contains { $0 === held }
               && !held.state.isClosed && !held.state.isActive && held.highlightEditingSession === editor
               && editor.values.comment == captured && held.document.document === nativeDocument
               && held.state.undoManager === documentUndo && fixture.access.owns(held.document, url: fixture.a),
               "Actual Group reconciliation retains the removed workspace, draft, native PDF, document Undo and writer after first-write IO failure.")
        try FileManager.default.removeItem(at: fixture.directory)
        expect(sceneSession.recoverDraftWorkspace(id: held.state.id) && sceneSession.workspace === held
               && sceneSession.workspace.document.document === nativeDocument && held.highlightEditingSession === editor
               && held.state.undoManager === documentUndo && held.state.isActive
               && sceneSession.workspacesNeedingDraftRecovery.isEmpty && library.group(withID: held.state.groupID) != nil,
               "Recover Draft creates a visible Group around the exact retained workspace instead of cloning PDF or editor state.")
        expect(held.flushHighlight(), "Visible recovery retries the same draft's real sidecar write after storage is repaired.")
        let record = try JSONDecoder().decode(IPadHighlightDraftRecovery.Record.self, from: Data(contentsOf: fixture.recordURL()))
        expect(try record.fileID == file.id && record.draftID == editor.id && record.values.comment == captured
               && editor.draft.annotation.contents == editor.draft.comment && !held.document.hasUnsavedChanges
               && !documentUndo.canUndo && Data(contentsOf: fixture.a) == fixture.aBytes,
               "Recovered lifecycle values checkpoint under the actual Library UUID without committing an annotation or changing the original.")
        expect(editor.discard(), "The retained failed-workspace editor can still explicitly discard after recovery.")
        held.highlightEditingSession = nil; host.close()
        expect(tabs.closeWindow() && !sceneSession.acceptsUserActions, "Successful durable preparation then permits normal window teardown.")
    }

    private final class Fixture {
        let root: URL, a: URL, b: URL, directory: URL
        let aBytes: Data
        let aID = UUID(), bID = UUID()
        let copies: PDFWorkingCopyStore, queue: PDFSaveQueue, feedback: OperationFeedbackCenter
        let undo = UndoManager()
        var access: DocumentAccessCoordinator
        var store: PDFDocumentStore
        init(root: URL, defaults: UserDefaults) throws {
            self.root = root; a = root.appendingPathComponent("A.pdf"); b = root.appendingPathComponent("B.pdf")
            directory = root.appendingPathComponent("drafts")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            aBytes = try IPadHighlightDraftRecoveryDiagnostics.authoredPDF(marker: "Highlight fixture A", color: .red)
            try aBytes.write(to: a); try IPadHighlightDraftRecoveryDiagnostics.authoredPDF(marker: "Highlight fixture B", color: .green).write(to: b)
            copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
            queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("queue"))
            feedback = OperationFeedbackCenter(userDefaults: defaults); access = DocumentAccessCoordinator(saveQueue: queue)
            store = IPadHighlightDraftRecoveryDiagnostics.makeStore(root: root, feedback: feedback, copies: copies, queue: queue, access: access)
            undo.groupsByEvent = false; store.setUndoManager(undo)
        }
        func openA(copy: URL? = nil) -> Bool { store.openPDF(from: a, workingCopyURL: copy) && store.bindLibraryFile(aID) }
        func openB() -> Bool { store.openPDF(from: b) && store.bindLibraryFile(bID) }
        func coldOpenA(copy: URL? = nil) -> Bool {
            store.releaseEditorAccess(); access = DocumentAccessCoordinator(saveQueue: queue)
            store = IPadHighlightDraftRecoveryDiagnostics.makeStore(root: root, feedback: feedback, copies: copies, queue: queue, access: access)
            store.setUndoManager(undo)
            return openA(copy: copy)
        }
        func editor() throws -> IPadHighlightEditingSession {
            let item = try IPadHighlightDraftRecoveryDiagnostics.required(store.annotations.first { $0.kind == .highlight })
            return IPadHighlightEditingSession(draft: try IPadHighlightDraftRecoveryDiagnostics.required(store.highlightEditDraft(for: item)))
        }
        func recovery() -> IPadHighlightDraftRecovery {
            IPadHighlightDraftRecovery(workspaceID: UUID(), store: store, feedback: feedback, directoryURL: directory)
        }
        func recordURLs() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        }
        func recordURL() throws -> URL { try IPadHighlightDraftRecoveryDiagnostics.required(recordURLs().first) }
        func drain() async { await queue.drain(); await IPadHighlightDraftRecoveryDiagnostics.settle() }
    }

    private final class NativeHost {
        let native: IPadResearchNativeTextView
        let coordinator: IPadResearchNativeTextEditor.Coordinator
        let window: UIWindow
        private let previousWindow: UIWindow?
        private var closed = false
        init(session: IPadHighlightEditingSession) {
            let native = IPadResearchNativeTextView(frame: CGRect(x: 0, y: 0, width: 440, height: 220))
            self.native = native
            let input = IPadResearchNativeTextEditor(text: session.commentBinding, commands: session.textCommands, identity: session.id)
            coordinator = IPadResearchNativeTextEditor.Coordinator(input)
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            previousWindow = scene?.windows.first(where: \.isKeyWindow)
            window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: native.frame)
            coordinator.install(native)
            let controller = UIViewController(); controller.view.addSubview(native)
            window.rootViewController = controller; window.makeKeyAndVisible()
            _ = native.becomeFirstResponder(); session.textCommands.activate(native)
        }
        func close() {
            guard !closed else { return }; closed = true
            IPadResearchNativeTextEditor.dismantleUIView(native, coordinator: coordinator)
            window.isHidden = true; previousWindow?.makeKey()
        }
    }

    private static func makeStore(root: URL, feedback: OperationFeedbackCenter, copies: PDFWorkingCopyStore,
                                  queue: PDFSaveQueue, access: DocumentAccessCoordinator) -> PDFDocumentStore {
        let id = UUID().uuidString
        return PDFDocumentStore(feedbackCenter: feedback,
            metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("\(id)-metadata.json")),
            aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("\(id)-groups.json")),
            workingCopyStore: copies, saveQueue: queue, accessCoordinator: access, exportPresenter: IPadDocumentExportPresenter())
    }
    private enum FixtureError: Error { case missingNativeValue }
    private final class EmptySecrets: AISecretStoring {
        func readSecret(profileID: UUID) -> String? { nil }
        func saveSecret(_ secret: String, profileID: UUID, configurationName: String) {}
        func removeSecret(profileID: UUID) {}
        func updateLabel(profileID: UUID, configurationName: String) {}
    }
    private static func required<T>(_ value: T?) throws -> T { guard let value else { throw FixtureError.missingNativeValue }; return value }
    private static func settle() async { for _ in 0..<8 { await Task.yield() } }
    private static func authoredPDF(marker: String, color: UIColor) throws -> Data {
        let bytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage()
            (marker as NSString).draw(at: CGPoint(x: 72, y: 90), withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black])
            color.setFill(); context.cgContext.fill(CGRect(x: 100, y: 240, width: 180, height: 90))
            context.beginPage()
            ("Independent second page" as NSString).draw(at: CGPoint(x: 72, y: 130), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
        }
        let document = try required(PDFDocument(data: bytes))
        let selection = try required(document.findString(marker, withOptions: []).first)
        let prepared = try required(PDFTextSelectionService.prepareHighlights(from: selection, in: document).first)
        let bounds = prepared.annotation.bounds
        prepared.annotation.bounds = CGRect(x: bounds.minX + 0.13, y: bounds.minY + 0.21,
                                             width: bounds.width + 0.37, height: bounds.height + 0.23)
        prepared.annotation.quadrilateralPoints = prepared.annotation.quadrilateralPoints?.map {
            let point = PDFPlatformStyle.point(from: $0)
            return PDFPlatformStyle.pointValue(CGPoint(x: point.x + 0.17, y: point.y + 0.29))
        }
        prepared.annotation.color = UIColor(red: 1, green: 0.8, blue: 0.2, alpha: 0.27)
        prepared.annotation.contents = "基线批注：中文"
        prepared.annotation.setValue("fixture-highlight", forAnnotationKey: .name)
        prepared.page.addAnnotation(prepared.annotation) // Initial authored fixture, never a business mutation bypass.
        return try required(document.dataRepresentation())
    }
}
#endif
