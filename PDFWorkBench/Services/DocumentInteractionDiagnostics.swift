import CoreGraphics
import Foundation
import PDFKit

/// Isolated native-document checks; no windows, user Library, pickers or network.
@MainActor
enum DocumentInteractionDiagnostics {
    static func run() -> AIHighlightFoundationDiagnosticReport {
        var checks = 0
        var failures: [String] = []
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !value() { failures.append(message) }
        }
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearDocumentInteractions-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let suite = "DogearDocumentInteractions-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("recovery"))
            defer { queue.waitUntilDrained() }
            let coordinator = DocumentAccessCoordinator(saveQueue: queue)
            let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
            func makeStore() -> PDFDocumentStore {
                PDFDocumentStore(feedbackCenter: OperationFeedbackCenter(userDefaults: defaults),
                    metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("metadata.json")),
                    aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("groups.json")),
                    workingCopyStore: copies, saveQueue: queue, accessCoordinator: coordinator)
            }
            let source = root.appendingPathComponent("source.pdf")
            let other = root.appendingPathComponent("other.pdf")
            let moved = root.appendingPathComponent("moved.pdf")
            let bytes = try fixtureData()
            for url in [source, other, moved] { try bytes.write(to: url) }
            let store = makeStore()
            defer { store.releaseEditorAccess() }
            let fileID = UUID()
            check(store.openPDF(from: source), "The confirmation fixture did not open.")
            store.bindLibraryFile(fileID)
            let undo = UndoManager()
            undo.groupsByEvent = false
            store.setUndoManager(undo)

            store.deleteCurrentPageFromWorkingCopy()
            check(store.pendingConfirmation != nil && store.pageCount == 3,
                "Requesting a page confirmation performed a deletion before confirmation.")
            store.pendingConfirmation = nil
            check(store.pageCount == 3 && store.currentWorkingCopyURL == nil,
                "Cancelling a confirmation mutated the source or created a working copy.")

            store.currentPageIndex = 0
            store.deleteCurrentPageFromWorkingCopy()
            let capturedPage = store.document?.page(at: 0)
            let confirmation = try require(store.pendingConfirmation)
            store.pendingConfirmation = nil
            store.currentPageIndex = 2
            undo.beginUndoGrouping()
            confirmation.onConfirm()
            undo.endUndoGrouping()
            check(store.pageCount == 2 && capturedPage?.document == nil,
                "A delayed page confirmation deleted the newly navigated page instead of its captured page.")
            confirmation.onConfirm()
            check(store.pageCount == 2, "A replayed confirmation executed its destructive command twice.")
            undo.undo()
            check(store.pageCount == 3, "Confirmed page deletion did not retain Undo.")

            store.deleteCurrentPageFromWorkingCopy()
            let changed = try require(store.pendingConfirmation)
            store.pendingConfirmation = nil
            store.document?.page(at: 0)?.rotation = 90
            changed.onConfirm()
            check(store.pageCount == 3, "A confirmation accepted a changed PDF version.")
            store.document?.page(at: 0)?.rotation = 0

            store.deleteCurrentPageFromWorkingCopy()
            let switched = try require(store.pendingConfirmation)
            check(store.openPDF(from: other), "The target-switch fixture did not open.")
            switched.onConfirm()
            check(store.pageCount == 3, "A delayed confirmation mutated a different open PDF.")
            check(store.pendingConfirmation == nil, "Switching PDFs retained a stale presented confirmation.")
            check(store.openPDF(from: source), "The relink fixture did not reopen.")
            store.bindLibraryFile(fileID)

            var deletedCallbacks = 0
            check(store.deletePagesFromWorkingCopy(at: IndexSet(integer: 0), onDeleted: { deletedCallbacks += 1 }),
                "A valid organizer deletion did not request confirmation.")
            check(store.pendingConfirmation?.scope == .pageOrganizer && deletedCallbacks == 0,
                "Organizer deletion used the wrong presenter or changed its selection before confirmation.")
            store.pendingConfirmation = nil
            check(deletedCallbacks == 0, "Cancelling organizer deletion changed its selection.")
            check(!store.deletePagesFromWorkingCopy(at: IndexSet(integer: 9)),
                "The organizer accepted a page outside the document.")

            let beforeRelink = try require(store.captureWritePermit(requestID: UUID()))
            let workingCopy = store.currentWorkingCopyURL
            let sameDocument = store.document
            if let workingCopy {
                queue.waitUntilDrained()
                let savedBeforeWrongPathDiscard = try Data(contentsOf: workingCopy)
                do {
                    try coordinator.discardWorkingCopy(originalURL: moved, workingCopyURL: workingCopy, fileID: fileID)
                    check(false, "A bookmark-followed path bypassed its still-active original-path writer during discard.")
                } catch DocumentAccessError.sourceChanged { check(true, "") }
                check((try? Data(contentsOf: workingCopy)) == savedBeforeWrongPathDiscard
                    && coordinator.owns(store, url: source) && store.currentWorkingCopyURL == workingCopy,
                    "Rejected moved-path discard deleted saved bytes or disturbed the original writer.")
                store.markAnnotationsChanged()
                store.releaseEditorAccess()
                do {
                    try coordinator.discardWorkingCopy(originalURL: moved, workingCopyURL: workingCopy, fileID: fileID)
                    check(false, "A moved-path discard bypassed a closed owner's retained dirty document.")
                } catch DocumentAccessError.sourceChanged { check(true, "") }
                check(coordinator.retainedEntry(for: source)?.document === sameDocument,
                    "Rejected moved-path discard cleared a closed owner's retained document.")
                check(store.openPDF(from: source, workingCopyURL: workingCopy) && store.bindLibraryFile(fileID),
                    "The retained writer could not reopen after rejecting moved-path discard.")
            }
            do {
                try coordinator.relocateOriginal(fileID: fileID, from: source, to: moved) { throw FixtureError.failedCommit }
                check(false, "A failed Library transaction reported relink success.")
            } catch FixtureError.failedCommit { check(true, "") }
            check(store.selectedPDFURL == source && coordinator.owns(store, url: source),
                "Failed Library persistence changed the editor's original binding.")
            var commits = 0
            try coordinator.relocateOriginal(fileID: fileID, from: source, to: moved) { commits += 1 }
            check(commits == 1 && store.selectedPDFURL == moved && coordinator.owns(store, url: moved),
                "Exact-content relink did not atomically update the active editor.")
            check(store.document === sameDocument && store.currentWorkingCopyURL == workingCopy && store.canEditDocument,
                "Relink replaced the working document, lost its working copy or dropped the editing lease.")
            check(!coordinator.owns(store, url: source), "The old path retained a second writing lease after relink.")
            do {
                try store.validateWritePermit(beforeRelink)
                check(false, "Relink failed to invalidate an old AI write permit.")
            } catch { check(true, "") }
            let snapshot = try coordinator.readSnapshot(fileID: fileID, originalURL: source, workingCopyURL: workingCopy)
            check(snapshot.originalURL == moved && snapshot.document.pageCount == store.pageCount,
                "Stable-ID readers did not follow the relocated original.")
            if let workingCopy {
                check(coordinator.protectedWorkingCopyURLs.contains(workingCopy),
                    "Storage inventory did not protect the active relocated working copy.")
            }
            let competing = makeStore()
            defer { competing.releaseEditorAccess() }
            var identityActivations = 0
            store.setEditorActivationHandler { identityActivations += 1 }
            check(coordinator.activateExistingEditor(fileID: fileID, excluding: competing) && identityActivations == 1,
                "Stable file identity did not activate the same owner after relocating its path.")
            check(!coordinator.activateExistingEditor(fileID: fileID, excluding: store),
                "Identity activation incorrectly redirected a request to its own store.")
            check(competing.openPDF(from: other), "The competing relink fixture did not open.")
            do {
                try coordinator.relocateOriginal(fileID: fileID, from: moved, to: other) { commits += 1 }
                check(false, "Relink replaced another active editor.")
            } catch DocumentAccessError.relinkConflict { check(true, "") }
            check(commits == 1 && store.selectedPDFURL == moved, "A conflicting relink reached Library commit.")
            check(!competing.bindLibraryFile(fileID), "The same Library identity acquired a competing path's writer.")
            check(competing.document == nil && competing.selectedPDFURL == nil
                && competing.currentWorkingCopyURL == nil && competing.annotations.isEmpty
                && competing.documentSearchResults.isEmpty && competing.outlineEntries.isEmpty
                && !coordinator.owns(competing, url: other),
                "A failed Library binding left a stale document or writing lease in the rejected store.")
            check(coordinator.owns(store, url: moved) && identityActivations == 2,
                "Rejecting a duplicate binding disturbed the original owner or failed to activate it.")

            // A second window may edit the same owned document while the
            // Library's nonblocking discard confirmation remains visible.
            let discardSource = root.appendingPathComponent("discard-source.pdf")
            try bytes.write(to: discardSource)
            let libraryStorage = try LibraryJSONStore(stateURL: root.appendingPathComponent("library.json"))
            let library = LibraryStore(userDefaults: defaults, storage: libraryStorage, workingCopyStore: copies)
            let discardFile = library.upsertOpenedURL(discardSource, refreshBookmark: false)
            let discardStore = makeStore()
            defer { discardStore.releaseEditorAccess() }
            check(discardStore.openPDF(from: discardSource), "The discard-version fixture did not open.")
            discardStore.bindLibraryFile(discardFile.id)
            let note = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 20, height: 20),
                forType: .text, withProperties: nil)
            note.contents = "Edits visible when confirmation opened"
            discardStore.document?.page(at: 0)?.addAnnotation(note)
            discardStore.markAnnotationsChanged()
            let discardCopy = try require(discardStore.currentWorkingCopyURL)
            library.updateWorkingCopyURL(discardCopy, for: discardFile)
            let staleDiscard = try WorkingCopyDiscardRequest(file: discardFile, originalURL: discardSource,
                workingCopyURL: discardCopy, coordinator: coordinator)
            note.contents = "New edits from another window after confirmation opened"
            discardStore.markAnnotationsChanged()
            do {
                try staleDiscard.discard(library: library, coordinator: coordinator)
                check(false, "A stale discard confirmation deleted edits made after it opened.")
            } catch DocumentAccessError.sourceChanged { check(true, "") }
            check(library.file(for: discardSource)?.workingCopyURL == discardCopy
                && discardStore.currentWorkingCopyURL == discardCopy && note.page != nil,
                "A rejected stale discard cleared the copy association or its in-memory annotations.")
            queue.waitUntilDrained()
            check(PDFDocument(url: discardCopy)?.page(at: 0)?.annotations.contains { $0.contents == note.contents } == true,
                "A rejected stale discard failed to preserve the latest saved edit.")
            let freshDiscard = try WorkingCopyDiscardRequest(file: discardFile, originalURL: discardSource,
                workingCopyURL: discardCopy, coordinator: coordinator)
            try freshDiscard.discard(library: library, coordinator: coordinator)
            check(library.file(for: discardSource)?.workingCopyURL == nil
                && discardStore.currentWorkingCopyURL == nil
                && !FileManager.default.fileExists(atPath: discardCopy.path),
                "A fresh discard confirmation did not clear the working copy and Library association together.")
            check(discardStore.document?.page(at: 0)?.annotations.isEmpty == true
                && (try? Data(contentsOf: discardSource)) == bytes,
                "Confirmed discard changed the original or resurrected a discarded annotation.")

            let symlink = root.appendingPathComponent("source-link.pdf")
            let hardlink = root.appendingPathComponent("source-hardlink.pdf")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
            try FileManager.default.linkItem(at: source, to: hardlink)
            for target in [source, symlink, hardlink] {
                do {
                    try SafeDocumentExport.write(data: Data("must not write".utf8), to: target, protecting: source)
                    check(false, "Export allowed original destination or alias: \(target.lastPathComponent).")
                } catch SafeDocumentExportError.originalDestination { check(true, "") }
            }
            let destination = root.appendingPathComponent("export.pdf")
            try SafeDocumentExport.write(data: bytes, to: destination, protecting: source)
            check((try? Data(contentsOf: destination)) == bytes, "A safe copy destination could not be exported.")
            check((try? Data(contentsOf: source)) == bytes && (try? Data(contentsOf: moved)) == bytes,
                "Confirmation, relink or copy export changed an original PDF.")
        } catch { failures.append(error.localizedDescription) }
        return .init(checkCount: checks, failures: failures)
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw FixtureError.missing }; return value
    }
    private enum FixtureError: Error { case missing, failedCommit }

    private static func fixtureData() throws -> Data {
        let bytes = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let consumer = CGDataConsumer(data: bytes as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw FixtureError.missing }
        for index in 0..<3 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: CGFloat(index + 1) / 4, alpha: 1))
            context.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
            context.endPDFPage()
        }
        context.closePDF()
        return bytes as Data
    }
}
