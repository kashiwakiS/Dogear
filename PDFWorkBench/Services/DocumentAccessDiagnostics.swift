import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit

@MainActor
enum DocumentAccessDiagnostics {
    static func run() async -> AIHighlightFoundationDiagnosticReport {
        var count = 0
        var failures: [String] = []
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            count += 1
            if !value() { failures.append(message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentAccessDiagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let original = root.appendingPathComponent("source.pdf")
            let secondURL = root.appendingPathComponent("second.pdf")
            let fixture = try makeDocument()
            guard let originalData = fixture.dataRepresentation() else { throw DocumentAccessError.snapshotUnavailable }
            try originalData.write(to: original)
            try originalData.write(to: secondURL)
            let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("recovery"))
            let coordinator = DocumentAccessCoordinator(saveQueue: queue)
            let copyStore = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
            func store() -> PDFDocumentStore {
                PDFDocumentStore(feedbackCenter: OperationFeedbackCenter(), workingCopyStore: copyStore,
                                 saveQueue: queue, accessCoordinator: coordinator)
            }
            let first = store()
            let second = store()
            var activations = 0
            first.setEditorActivationHandler { activations += 1 }
            check(first.openPDF(from: original), "The initial editor did not open.")
            let fileID = UUID()
            first.bindLibraryFile(fileID)
            check(!second.openPDF(from: original), "A second editor acquired the same source.")
            check(activations == 1, "A duplicate open did not activate its existing editor.")
            let alias = root.appendingPathComponent("alias.pdf")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
            check(!second.openPDF(from: alias), "A symlink created a competing editor.")
            check(activations == 2, "A canonical-path duplicate did not activate its editor.")
            let initialPermit = first.captureWritePermit(requestID: UUID())
            check(initialPermit != nil, "The editor did not issue a write permit.")
            if let initialPermit { try first.validateWritePermit(initialPermit) }
            guard let page = first.document?.page(at: 0) else { throw DocumentAccessError.snapshotUnavailable }
            let annotation = PDFAnnotation(bounds: CGRect(x: 70, y: 680, width: 140, height: 20), forType: .highlight, withProperties: nil)
            annotation.contents = "Latest retained annotation"
            page.addAnnotation(annotation)
            if let initialPermit {
                do { try first.validateWritePermit(initialPermit); check(false, "Annotation changes did not invalidate the request permit.") }
                catch { check(true, "") }
            }
            let visibleVersion = DocumentAccessCoordinator.contentVersion(of: first.document!)
            annotation.shouldDisplay = false
            check(visibleVersion == DocumentAccessCoordinator.contentVersion(of: first.document!), "Visibility-only changes invalidated the source.")
            annotation.shouldDisplay = true
            page.rotation = 90
            check(visibleVersion != DocumentAccessCoordinator.contentVersion(of: first.document!), "Page rotation did not invalidate the source.")
            page.rotation = 0
            first.markAnnotationsChanged()
            let versionBeforeDrain = first.captureWritePermit(requestID: UUID())?.contentVersion
            let snapshot = try coordinator.readSnapshot(fileID: fileID, originalURL: original)
            check(snapshot.document !== first.document, "Research received the writable PDFDocument instance.")
            check(snapshot.document.page(at: 0)?.annotations.contains(where: { $0.contents == annotation.contents }) == true,
                  "Research read old disk contents during a pending save.")
            let exported = PDFDocument(data: try coordinator.exportData(fileID: fileID, originalURL: original,
                workingCopyURL: first.currentWorkingCopyURL))
            check(exported?.page(at: 0)?.annotations.contains(where: { $0.contents == annotation.contents }) == true,
                  "A Library export from another window lost the active owner's latest annotation.")
            check(first.openPDF(from: secondURL), "Switching away from a pending save failed.")
            check(second.openPDF(from: original), "The released editor could not be reopened.")
            second.bindLibraryFile(fileID)
            check(second.document?.page(at: 0)?.annotations.contains(where: { $0.contents == annotation.contents }) == true,
                  "Reopening during a pending save lost the latest edit.")
            await drain(queue, in: root)
            check(versionBeforeDrain == second.captureWritePermit(requestID: UUID())?.contentVersion,
                  "An unchanged save completion altered the effective source version.")
            check((try? Data(contentsOf: original)) == originalData, "An ordinary edit overwrote the source PDF.")
            if let initialPermit {
                do { try second.validateWritePermit(initialPermit); check(false, "An old editor's permit transferred to a replacement editor.") }
                catch { check(true, "") }
            }
            second.releaseEditorAccess()
            check(!second.canEditDocument, "A closed editor retained write access.")
            first.releaseEditorAccess()
            let third = store()
            check(third.openPDF(from: original), "A clean working copy did not reopen.")
            third.document?.page(at: 0)?.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil))
            third.markAnnotationsChanged()
            let discardedURL = third.currentWorkingCopyURL
            guard let discardedURL else { throw DocumentAccessError.snapshotUnavailable }
            try coordinator.discardWorkingCopy(originalURL: original, workingCopyURL: discardedURL, fileID: fileID)
            check(third.canEditDocument && third.captureWritePermit(requestID: UUID())?.fileID == fileID,
                  "A Library discard from another window did not reopen and rebind the actual owner.")
            await drain(queue, in: root)
            check(third.document?.page(at: 0)?.annotations.isEmpty == true, "Confirmed discard restored unsaved annotation state.")
            check(!FileManager.default.fileExists(atPath: discardedURL.path), "A late queued save resurrected a discarded working copy.")
            check(queue.pendingData(for: discardedURL) == nil, "Confirmed discard left recoverable abandoned bytes.")
            third.releaseEditorAccess()
            let beforeRasterChange = try coordinator.readSnapshot(originalURL: secondURL)
            check(!FileManager.default.fileExists(atPath: copyStore.workingCopyURL(forOriginalURL: secondURL).path), "A research-only read created a working copy.")
            let imageChanged = try makeDocument(addGraphic: true)
            try imageChanged.dataRepresentation()!.write(to: secondURL)
            let afterRasterChange = try coordinator.readSnapshot(originalURL: secondURL)
            check(beforeRasterChange.document.string == afterRasterChange.document.string, "Graphic version fixture unexpectedly changed extracted text.")
            check(beforeRasterChange.contentVersion != afterRasterChange.contentVersion, "A graphic-only source change did not invalidate the source version.")

            let missingCopy = root.appendingPathComponent("missing.pdf")
            do {
                _ = try coordinator.readSnapshot(originalURL: original, workingCopyURL: missingCopy)
                check(false, "A missing recorded working copy silently fell back to the original.")
            } catch DocumentAccessError.workingCopyMissing { check(true, "") }

            // Deterministic destination failure: a regular file occupies its parent.
            let obstruction = root.appendingPathComponent("blocked")
            try Data("block".utf8).write(to: obstruction)
            let destination = obstruction.appendingPathComponent("failed.pdf")
            let firstBytes = Data("old".utf8)
            let latestBytes = originalData
            _ = await write(firstBytes, to: destination, queue: queue)
            _ = await write(latestBytes, to: destination, queue: queue)
            check(queue.pendingData(for: destination) == latestBytes, "Failed saves did not retain the latest bytes.")
            check(queue.failureDescription(for: destination) != nil, "Save failure was not retained for retry.")
            check(!queue.hasUnrecoverablePendingWrites, "A protected failed write incorrectly blocked termination.")
            let restoredQueue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("recovery"))
            check(restoredQueue.pendingData(for: destination) == latestBytes, "Interrupted save bytes did not recover in a new queue.")
            try FileManager.default.removeItem(at: obstruction)
            let retryResult: Result<URL, Error> = await withCheckedContinuation { continuation in
                let started = restoredQueue.retry(to: destination) { continuation.resume(returning: $0) }
                if !started { continuation.resume(returning: .failure(DocumentAccessError.snapshotUnavailable)) }
            }
            if case .success = retryResult { check(true, "") } else { check(false, "Retry did not save retained bytes.") }
            check((try? Data(contentsOf: destination)) == latestBytes, "Retry wrote an older snapshot.")
            check(restoredQueue.pendingData(for: destination) == nil, "Successful retry retained a pending write.")
            let afterRetry = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("recovery"))
            check(afterRetry.pendingData(for: destination) == nil, "Successful retry left a recovery journal.")

            let orphanObstruction = root.appendingPathComponent("orphan-blocked")
            try Data().write(to: orphanObstruction)
            let orphanDestination = orphanObstruction.appendingPathComponent("discard.pdf")
            let orphanOwner = store()
            check(orphanOwner.openPDF(from: original), "The closed-owner discard fixture could not open.")
            guard let orphanDocument = orphanOwner.document else { throw DocumentAccessError.snapshotUnavailable }
            let orphanAnnotation = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil)
            orphanAnnotation.contents = "Unsaved closed-owner note"
            orphanDocument.page(at: 0)?.addAnnotation(orphanAnnotation)
            _ = coordinator.noteMutation(for: original, document: orphanDocument, workingCopyURL: orphanDestination)
            let orphanData = orphanDocument.dataRepresentationWithAIAnnotationsDisplayed()!
            _ = await write(orphanData, to: orphanDestination, queue: queue)
            coordinator.notePreparedData(for: original)
            orphanOwner.releaseEditorAccess()
            let orphanExport = PDFDocument(data: try coordinator.exportData(originalURL: original, workingCopyURL: orphanDestination))
            check(orphanExport?.page(at: 0)?.annotations.contains(where: { $0.contents == orphanAnnotation.contents }) == true,
                  "A closed owner's failed save was missing from Library export.")
            try coordinator.discardWorkingCopy(originalURL: original, workingCopyURL: orphanDestination)
            check(coordinator.retainedEntry(for: original) == nil && queue.pendingData(for: orphanDestination) == nil,
                  "Closed-owner discard retained the edited document or pending bytes.")
            let afterOrphanDiscard = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("recovery"))
            check(afterOrphanDiscard.pendingData(for: orphanDestination) == nil, "Discarded closed-owner edits recovered after relaunch.")
            let reopenedOriginal = try coordinator.readSnapshot(originalURL: original)
            check(reopenedOriginal.document.page(at: 0)?.annotations.isEmpty == true,
                  "Closed-owner discard resurrected edits when reopening the original.")
            do {
                try coordinator.discardWorkingCopy(originalURL: original, workingCopyURL: original)
                check(false, "A discard command accepted the original as its working-copy destination.")
            } catch DocumentAccessError.discardFailed { check(true, "") }
            check((try? Data(contentsOf: original)) == originalData, "Cross-window or closed-owner discard changed the original.")

            let observedWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
            let unrelatedWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
            var closes = 0
            var observation: DocumentEditorWindowCloseObserver? = DocumentEditorWindowCloseObserver(window: observedWindow) { closes += 1 }
            weak var weakObservation = observation
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: unrelatedWindow)
            check(closes == 0, "An unrelated window released the observed editor.")
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: observedWindow)
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: observedWindow)
            check(closes == 1, "A close observer was not removed after its first close.")
            observation = nil
            check(weakObservation == nil, "NotificationCenter retained the completed close observer.")
            observation = DocumentEditorWindowCloseObserver(window: observedWindow) { closes += 1 }
            weakObservation = observation
            observation = nil
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: observedWindow)
            check(weakObservation == nil && closes == 1, "Dropping a view left its close observer registered or retained.")

            let cleanupRecovery = root.appendingPathComponent("cleanup-recovery")
            let cleanupManager = JournalRemovalFailingFileManager(directoryURL: cleanupRecovery)
            let cleanupQueue = PDFSaveQueue(fileManager: cleanupManager, recoveryDirectoryURL: cleanupRecovery)
            let cleanupDestination = root.appendingPathComponent("cleanup-target.pdf")
            let cleanupResult = await write(originalData, to: cleanupDestination, queue: cleanupQueue)
            if case .failure = cleanupResult { check(true, "") }
            else { check(false, "A successful target write hid its failed recovery-journal cleanup.") }
            check((try? Data(contentsOf: cleanupDestination)) == originalData,
                  "Journal-cleanup failure damaged the successfully written destination.")
            check(cleanupQueue.pendingData(for: cleanupDestination) == originalData && cleanupQueue.failureDescription(for: cleanupDestination) != nil,
                  "Journal-cleanup failure forgot the pending bytes or retry error.")
            do {
                try cleanupQueue.discardPendingData(for: cleanupDestination)
                check(false, "Discard reported success after recovery-journal deletion failed.")
            } catch { check(true, "") }
            check(cleanupQueue.pendingData(for: cleanupDestination) == originalData,
                  "Failed journal deletion abandoned the in-memory recovery bytes.")
            let cleanupReload = PDFSaveQueue(recoveryDirectoryURL: cleanupRecovery)
            check(cleanupReload.pendingData(for: cleanupDestination) == originalData,
                  "A failed discard did not preserve its recoverable journal.")
            cleanupManager.allowsRemoval = true
            let cleanupRetry = await write(originalData, to: cleanupDestination, queue: cleanupQueue)
            if case .success = cleanupRetry { check(true, "") }
            else { check(false, "A journal-cleanup retry did not complete after the failure was resolved.") }
            check(cleanupQueue.pendingData(for: cleanupDestination) == nil &&
                PDFSaveQueue(recoveryDirectoryURL: cleanupRecovery).pendingData(for: cleanupDestination) == nil,
                  "Successful journal-cleanup retry left pending or relaunch recovery state.")

            cleanupManager.allowsRemoval = false
            let cleanupCoordinator = DocumentAccessCoordinator(saveQueue: cleanupQueue)
            let cleanupCopies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("cleanup-copies"))
            let cleanupOwner = PDFDocumentStore(feedbackCenter: OperationFeedbackCenter(), workingCopyStore: cleanupCopies,
                saveQueue: cleanupQueue, accessCoordinator: cleanupCoordinator)
            check(cleanupOwner.openPDF(from: original), "The journal-cleanup owner fixture could not open.")
            let cleanupAnnotation = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil)
            cleanupOwner.document?.page(at: 0)?.addAnnotation(cleanupAnnotation)
            cleanupOwner.markAnnotationsChanged()
            await drain(cleanupQueue, in: root)
            guard let cleanupCopy = cleanupOwner.currentWorkingCopyURL else { throw DocumentAccessError.snapshotUnavailable }
            do {
                try cleanupCoordinator.discardWorkingCopy(originalURL: original, workingCopyURL: cleanupCopy)
                check(false, "The active-owner discard ignored journal-cleanup failure.")
            } catch { check(true, "") }
            check(cleanupOwner.canEditDocument && cleanupOwner.document?.page(at: 0)?.annotations.isEmpty == false &&
                cleanupQueue.pendingData(for: cleanupCopy) != nil,
                  "A failed active-owner discard cleared the editable document or pending bytes.")
            cleanupOwner.releaseEditorAccess()
            do {
                try cleanupCoordinator.discardWorkingCopy(originalURL: original, workingCopyURL: cleanupCopy)
                check(false, "The closed-owner discard ignored journal-cleanup failure.")
            } catch { check(true, "") }
            check(cleanupCoordinator.retainedEntry(for: original) != nil && cleanupQueue.pendingData(for: cleanupCopy) != nil,
                  "A failed closed-owner discard cleared retained state.")
            cleanupManager.allowsRemoval = true
            try cleanupCoordinator.discardWorkingCopy(originalURL: original, workingCopyURL: cleanupCopy)
            check(cleanupCoordinator.retainedEntry(for: original) == nil && cleanupQueue.pendingData(for: cleanupCopy) == nil &&
                PDFSaveQueue(recoveryDirectoryURL: cleanupRecovery).pendingData(for: cleanupCopy) == nil,
                  "A retried confirmed discard did not clear memory and its recovery journal together.")
            check((try? Data(contentsOf: original)) == originalData, "Journal-cleanup failures or discard retries changed the original PDF.")

            let blockedJournal = root.appendingPathComponent("blocked-recovery")
            let blockedTarget = root.appendingPathComponent("blocked-target")
            try Data().write(to: blockedJournal)
            try Data().write(to: blockedTarget)
            let unprotectedQueue = PDFSaveQueue(recoveryDirectoryURL: blockedJournal)
            let unprotectedCoordinator = DocumentAccessCoordinator(saveQueue: unprotectedQueue)
            _ = await write(latestBytes, to: blockedTarget.appendingPathComponent("pending.pdf"), queue: unprotectedQueue)
            check(unprotectedQueue.hasUnrecoverablePendingWrites, "A failed write without recovery was reported protected.")
            check(unprotectedCoordinator.hasUnrecoverableChanges, "Termination did not detect unprotected pending bytes.")
            try FileManager.default.removeItem(at: blockedJournal)
            unprotectedCoordinator.retryPendingSaves()
            unprotectedQueue.waitUntilDrained()
            check(!unprotectedCoordinator.hasUnrecoverableChanges, "A successful recovery journal still blocked termination before callbacks.")

            let serializationStore = store()
            check(serializationStore.openPDF(from: original), "Serialization-failure fixture could not open.")
            if let document = serializationStore.document {
                _ = coordinator.noteMutation(for: original, document: document, workingCopyURL: copyStore.workingCopyURL(forOriginalURL: original))
                serializationStore.releaseEditorAccess()
                check(coordinator.hasUnrecoverableChanges, "A retained dirty document with no prepared data did not block termination.")
                coordinator.retryPendingSaves()
                queue.waitUntilDrained()
                check(!coordinator.hasUnrecoverableChanges, "Retry did not protect a closed dirty document independently of callbacks.")
            }
        } catch { failures.append(error.localizedDescription) }
        return AIHighlightFoundationDiagnosticReport(checkCount: count, failures: failures)
    }

    private static func write(_ data: Data, to url: URL, queue: PDFSaveQueue) async -> Result<URL, Error> {
        await withCheckedContinuation { continuation in
            queue.enqueue(data: data, to: url) { continuation.resume(returning: $0) }
        }
    }

    private static func drain(_ queue: PDFSaveQueue, in directory: URL) async {
        _ = await write(Data(), to: directory.appendingPathComponent("drain"), queue: queue)
    }

    private static func makeDocument(addGraphic: Bool = false) throws -> PDFDocument {
        let bytes = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: bytes as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw DocumentAccessError.snapshotUnavailable }
        context.beginPDFPage(nil)
        if addGraphic {
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 40, y: 40, width: 100, height: 100))
        }
        context.textPosition = CGPoint(x: 72, y: 700)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let text = NSAttributedString(string: "Evidence is retained across editing windows.", attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(data: bytes as Data) else { throw DocumentAccessError.snapshotUnavailable }
        return document
    }
}

nonisolated private final class JournalRemovalFailingFileManager: FileManager {
    private let directoryURL: URL
    private let lock = NSLock()
    private var removalAllowed = false

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        super.init()
    }

    var allowsRemoval: Bool {
        get { lock.lock(); defer { lock.unlock() }; return removalAllowed }
        set { lock.lock(); removalAllowed = newValue; lock.unlock() }
    }

    override func removeItem(at URL: URL) throws {
        if URL.deletingLastPathComponent().standardizedFileURL.path == directoryURL.standardizedFileURL.path && !allowsRemoval {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}
