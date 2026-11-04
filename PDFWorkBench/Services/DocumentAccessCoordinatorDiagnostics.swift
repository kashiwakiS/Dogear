import CoreGraphics
import CryptoKit
import Foundation
import PDFKit

/// The owner is a protocol test double. PDF documents, fingerprints,
/// serialization, writes/recovery and working-copy paths use real services.
/// Everything lives beneath an isolated temporary root, never user state.
@MainActor
enum DocumentAccessCoordinatorDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        @MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearSharedAccess-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("recovery"))
            let coordinator = DocumentAccessCoordinator(saveQueue: queue)
            let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
            var originals: [URL: Data] = [:]
            @MainActor func original(_ name: String) throws -> (URL, PDFDocument) {
                let url = root.appendingPathComponent(name + ".pdf")
                let document = try makeDocument(name)
                let data = try bytes(document)
                try data.write(to: url)
                originals[url] = data
                return (url, document)
            }

            let (firstURL, firstPDF) = try original("first")
            let (secondURL, secondPDF) = try original("second")
            let firstCopy = copies.workingCopyURL(forOriginalURL: firstURL)
            let first = Owner()
            let second = Owner()
            coordinator.register(first, url: firstURL, document: firstPDF, workingCopyURL: firstCopy)
            coordinator.register(second, url: secondURL, document: secondPDF, workingCopyURL: nil)
            check(coordinator.owns(first, url: firstURL) && !coordinator.owns(second, url: firstURL),
                  "Writer ownership did not use the exact protocol object identity.")
            let alias = root.appendingPathComponent("first-alias.pdf")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: firstURL)
            check(coordinator.owns(first, url: alias), "A source alias did not resolve to the same writer.")
            check(!coordinator.activateExistingEditor(for: firstURL, excluding: first),
                  "Activating a source did not exclude its own writer.")
            check(coordinator.activateExistingEditor(for: alias, excluding: second) && first.activations == 1,
                  "A duplicate source did not activate its actual writer.")
            let fileID = UUID()
            check(coordinator.bind(fileID: fileID, to: first, url: firstURL), "The current writer could not bind a stable file ID.")
            check(!coordinator.bind(fileID: UUID(), to: second, url: firstURL), "Another owner bound the current writer's source.")
            check(coordinator.activateExistingEditor(fileID: fileID, excluding: second) && first.activations == 2,
                  "Stable file identity did not activate the existing writer.")
            check(!coordinator.activateExistingEditor(fileID: fileID, excluding: first),
                  "Stable identity activation did not exclude its own writer.")
            check(!coordinator.bind(fileID: fileID, to: second, url: secondURL) && first.activations == 3,
                  "Another source acquired a live writer's stable file ID.")
            coordinator.release(second, url: firstURL)
            coordinator.discardRetainedState(for: firstURL, owner: second)
            check(coordinator.owns(first, url: firstURL), "Another owner released or discarded the current writer.")
            check(coordinator.protectedWorkingCopyURLs.contains(firstCopy), "A live writer's copy was not protected.")
            coordinator.release(second, url: secondURL)
            check(coordinator.retainedEntry(for: secondURL) == nil, "Releasing a clean writer retained its editor state.")

            let (weakURL, weakPDF) = try original("weak")
            var ephemeral: Owner? = Owner()
            weak var weakOwner = ephemeral
            coordinator.register(ephemeral!, url: weakURL, document: weakPDF, workingCopyURL: nil)
            ephemeral = nil
            check(weakOwner == nil && coordinator.retainedEntry(for: weakURL) == nil,
                  "The coordinator strongly retained a clean protocol owner.")
            weakOwner = nil

            let firstGeneration = coordinator.noteMutation(for: firstURL, document: firstPDF, workingCopyURL: firstCopy)
            check(coordinator.retainedEntry(for: firstURL)?.dirty == true && coordinator.hasUnrecoverableChanges,
                  "A new mutation did not retain dirty state before bytes were prepared.")
            coordinator.notePreparedData(for: firstURL)
            check(!coordinator.hasUnrecoverableChanges, "Prepared dirty state remained unrecoverable.")
            let firstRevision = try coordinator.retrievalCandidate(originalURL: firstURL).fastRevision
            firstPDF.page(at: 0)?.annotations.first?.contents = "newest in-memory edit"
            let latestGeneration = coordinator.noteMutation(for: firstURL, document: firstPDF, workingCopyURL: firstCopy)
            coordinator.notePreparedData(for: firstURL)
            let latestRevision = try coordinator.retrievalCandidate(originalURL: firstURL).fastRevision
            check(firstGeneration != latestGeneration, "A later mutation reused a save generation.")
            // No on-disk working copy exists yet, so the fast revision may be
            // unavailable; sourceVersion must still reflect the live edit.
            check(firstRevision == nil && latestRevision == nil,
                  "Missing source bytes unexpectedly produced a cache revision.")
            let olderSave = await write(originals[firstURL]!, to: firstCopy, queue: queue)
            coordinator.finishSave(for: firstURL, generation: firstGeneration, result: olderSave)
            check(coordinator.retainedEntry(for: firstURL)?.dirty == true && first.saveStates.isEmpty,
                  "A stale save completion cleared or published the latest dirty state.")
            let snapshot = try coordinator.readSnapshot(fileID: fileID, originalURL: firstURL)
            check(snapshot.document !== firstPDF && snapshot.document.page(at: 0) !== firstPDF.page(at: 0),
                  "A reader snapshot shared the writer's PDFKit objects.")
            check(marker(in: snapshot.document) == "newest in-memory edit", "A reader lost the latest live edit after a stale save.")
            snapshot.document.page(at: 0)?.annotations.first?.contents = "snapshot-only edit"
            check(marker(in: firstPDF) == "newest in-memory edit", "Editing a detached snapshot changed the writer's PDF.")
            let bytesBeforeNextMutation = try coordinator.retrievalCandidate(originalURL: firstURL)
            let nextGeneration = coordinator.noteMutation(for: firstURL, document: firstPDF, workingCopyURL: firstCopy)
            coordinator.notePreparedData(for: firstURL)
            let bytesAfterNextMutation = try coordinator.retrievalCandidate(originalURL: firstURL)
            check(bytesBeforeNextMutation.sourceByteFingerprint == bytesAfterNextMutation.sourceByteFingerprint
                  && bytesBeforeNextMutation.fastRevision != bytesAfterNextMutation.fastRevision,
                  "A dirty mutation reused a retrieval revision for unchanged disk bytes.")
            let latestSave = await write(try bytes(firstPDF), to: firstCopy, queue: queue)
            coordinator.finishSave(for: firstURL, generation: nextGeneration, result: latestSave)
            check(coordinator.retainedEntry(for: firstURL)?.dirty == false && first.saveStates.last?.dirty == false,
                  "The current save completion did not publish clean owner state.")
            coordinator.release(first, url: firstURL)
            check(coordinator.retainedEntry(for: firstURL) == nil && !coordinator.protectedWorkingCopyURLs.contains(firstCopy),
                  "A completed clean writer retained its state or copy protection after release.")
            check(!coordinator.activateExistingEditor(fileID: fileID), "Released clean state still activated a writer.")

            let (retainedURL, retainedPDF) = try original("retained")
            let retainedCopy = copies.workingCopyURL(forOriginalURL: retainedURL)
            var retainedOwner: Owner? = Owner()
            weak var weakRetainedOwner = retainedOwner
            coordinator.register(retainedOwner!, url: retainedURL, document: retainedPDF, workingCopyURL: retainedCopy)
            let retainedGeneration = coordinator.noteMutation(for: retainedURL, document: retainedPDF, workingCopyURL: retainedCopy)
            retainedOwner = nil
            check(weakRetainedOwner == nil && coordinator.retainedEntry(for: retainedURL)?.owner == nil,
                  "Dirty retained state strongly held its released editor owner.")
            weakRetainedOwner = nil
            check(coordinator.retainedEntry(for: retainedURL)?.document === retainedPDF
                  && coordinator.protectedWorkingCopyURLs.contains(retainedCopy),
                  "Owner deallocation lost the dirty PDF or copy protection.")
            coordinator.notePreparedData(for: retainedURL)
            coordinator.finishSave(for: retainedURL, generation: retainedGeneration,
                result: await write(try bytes(retainedPDF), to: retainedCopy, queue: queue))
            check(coordinator.retainedEntry(for: retainedURL) == nil,
                  "Saving ownerless retained state failed to release its clean PDF.")

            let (oldURL, relocatedPDF) = try original("relocate-old")
            let (newURL, _) = try original("relocate-new")
            // The Library's exact-content verification is outside this
            // coordinator; supply equal originals for its relocation handoff.
            try originals[oldURL]!.write(to: newURL)
            originals[newURL] = originals[oldURL]
            let relocationCopy = copies.workingCopyURL(forOriginalURL: oldURL)
            let relocating = Owner()
            coordinator.register(relocating, url: oldURL, document: relocatedPDF, workingCopyURL: relocationCopy)
            let relocationID = UUID()
            check(coordinator.bind(fileID: relocationID, to: relocating, url: oldURL), "Relocation fixture could not bind its source.")
            relocatedPDF.page(at: 0)?.annotations.first?.contents = "retained relocation edit"
            let relocationGeneration = coordinator.noteMutation(for: oldURL, document: relocatedPDF, workingCopyURL: relocationCopy)
            coordinator.notePreparedData(for: oldURL)
            _ = await write(try bytes(relocatedPDF), to: relocationCopy, queue: queue)
            do {
                try coordinator.relocateOriginal(fileID: relocationID, from: oldURL, to: newURL) { throw FixtureError.transaction }
                check(false, "A failed Library transaction completed relocation.")
            } catch FixtureError.transaction { check(true, "") }
            check(coordinator.owns(relocating, url: oldURL) && !coordinator.owns(relocating, url: newURL)
                  && coordinator.retainedEntry(for: oldURL)?.generation == relocationGeneration,
                  "A failed Library transaction changed writer path or generation.")
            check(relocating.adoptions.isEmpty && relocating.saveStates.isEmpty,
                  "A failed relocation published an editor adoption or save state.")
            let destinationOwner = Owner()
            coordinator.register(destinationOwner, url: newURL, document: try makeDocument("destination"), workingCopyURL: nil)
            var committed = false
            do {
                try coordinator.relocateOriginal(fileID: relocationID, from: oldURL, to: newURL) { committed = true }
                check(false, "Relocation replaced a live destination editor.")
            } catch DocumentAccessError.relinkConflict { check(!committed, "A conflicting relocation committed Library state.") }
            coordinator.release(destinationOwner, url: newURL)
            var oldOwnershipAtCommit = false
            try coordinator.relocateOriginal(fileID: relocationID, from: oldURL, to: newURL) {
                oldOwnershipAtCommit = coordinator.owns(relocating, url: oldURL) && !coordinator.owns(relocating, url: newURL)
            }
            check(oldOwnershipAtCommit, "Relocation changed ownership before durable Library commit.")
            check(relocating.retries == 2 && relocating.adoptions.last?.url == newURL,
                  "Relocation did not retain retry/adoption ordering through the owner protocol.")
            check(coordinator.owns(relocating, url: newURL) && !coordinator.owns(relocating, url: oldURL),
                  "Successful relocation left the writer on its old path.")
            check(coordinator.retainedEntry(for: newURL)?.document === relocatedPDF
                  && coordinator.retainedEntry(for: newURL)?.workingCopyURL == relocationCopy,
                  "Relocation replaced the edited PDF or renamed its historical working copy.")
            check(coordinator.retainedEntry(for: newURL)?.generation != relocationGeneration
                  && relocating.saveStates.last?.dirty == false,
                  "Relocation did not invalidate old generations and publish current clean state.")
            let relocatedRead = try coordinator.readSnapshot(fileID: relocationID, originalURL: oldURL)
            check(relocatedRead.originalURL == newURL && marker(in: relocatedRead.document) == "retained relocation edit",
                  "Stable-ID reads lost the relocated owner's latest PDF.")
            do {
                try coordinator.discardWorkingCopy(originalURL: oldURL, workingCopyURL: relocationCopy, fileID: relocationID)
                check(false, "Discard bypassed a stable-ID writer still at its relocated path.")
            } catch DocumentAccessError.sourceChanged { check(FileManager.default.fileExists(atPath: relocationCopy.path), "A stale-path discard deleted the working copy.") }

            let (unsavedURL, unsavedPDF) = try original("unprepared")
            let missingCopy = copies.workingCopyURL(forOriginalURL: unsavedURL)
            let unsaved = Owner()
            coordinator.register(unsaved, url: unsavedURL, document: unsavedPDF, workingCopyURL: missingCopy)
            _ = coordinator.noteMutation(for: unsavedURL, document: unsavedPDF, workingCopyURL: missingCopy)
            do {
                try coordinator.relocateOriginal(fileID: UUID(), from: unsavedURL, to: root.appendingPathComponent("unprepared-new.pdf")) {}
                check(false, "Relocation lost unprepared dirty data.")
            } catch DocumentAccessError.pendingSaveFailed { check(coordinator.owns(unsaved, url: unsavedURL), "Failed-save relocation released the writer.") }
            coordinator.notePreparedData(for: unsavedURL)
            do {
                try coordinator.relocateOriginal(fileID: UUID(), from: unsavedURL, to: root.appendingPathComponent("unprepared-new.pdf")) {}
                check(false, "Relocation accepted a dirty missing working copy.")
            } catch DocumentAccessError.pendingSaveFailed { check(true, "") }

            let (discardURL, discardPDF) = try original("discard")
            let discardCopy = copies.workingCopyURL(forOriginalURL: discardURL)
            _ = await write(try bytes(discardPDF), to: discardCopy, queue: queue)
            let discarding = Owner()
            coordinator.register(discarding, url: discardURL, document: discardPDF, workingCopyURL: discardCopy)
            let discardID = UUID()
            check(coordinator.bind(fileID: discardID, to: discarding, url: discardURL), "Discard fixture could not bind its file ID.")
            do {
                try coordinator.discardWorkingCopy(originalURL: discardURL, workingCopyURL: discardCopy, fileID: discardID)
                check(false, "An editor's failed discard was reported as success.")
            } catch DocumentAccessError.discardFailed {
                check(coordinator.owns(discarding, url: discardURL) && FileManager.default.fileExists(atPath: discardCopy.path),
                      "A failed explicit discard lost current editor state or its copy.")
            }
            let reopened = try makeDocument("discard")
            discarding.discardAction = {
                do {
                    queue.waitUntilDrained()
                    try FileManager.default.removeItem(at: discardCopy)
                    try queue.discardPendingData(for: discardCopy)
                    coordinator.discardRetainedState(for: discardURL, owner: discarding)
                    coordinator.register(discarding, url: discardURL, document: reopened, workingCopyURL: nil)
                    return true
                } catch { return false }
            }
            discarding.bindAction = { coordinator.bind(fileID: $0, to: discarding, url: discardURL) }
            try coordinator.discardWorkingCopy(originalURL: discardURL, workingCopyURL: discardCopy, fileID: discardID)
            check(discarding.discards == 2 && discarding.binds == [discardID],
                  "Explicit discard did not delegate to and rebind the actual editing owner.")
            check(coordinator.owns(discarding, url: discardURL)
                  && coordinator.retainedEntry(for: discardURL)?.document === reopened
                  && !FileManager.default.fileExists(atPath: discardCopy.path),
                  "Successful explicit discard failed to retain the reopened writer or remove its copy.")
            discarding.discardAction = nil
            discarding.bindAction = nil

            let obstruction = root.appendingPathComponent("obstruction")
            try Data("block".utf8).write(to: obstruction)
            let failedCopy = obstruction.appendingPathComponent("pending.pdf")
            let olderPDF = try makeDocument("older pending")
            let newestPDF = try makeDocument("newest pending")
            let olderBytes = try bytes(olderPDF)
            let newestBytes = try bytes(newestPDF)
            _ = await write(olderBytes, to: failedCopy, queue: queue)
            let failedResult = await write(newestBytes, to: failedCopy, queue: queue)
            check(queue.pendingData(for: failedCopy) == newestBytes, "Failed writes retained older pending bytes.")
            check(queue.failureDescription(for: failedCopy) != nil && !queue.hasUnrecoverablePendingWrites,
                  "A failed save lost its recoverable journal or error state.")
            let diskReader = DocumentAccessCoordinator(saveQueue: queue)
            let pendingRead = try diskReader.readSnapshot(originalURL: firstURL, workingCopyURL: failedCopy)
            check(marker(in: pendingRead.document) == "newest pending", "A closed-source read ignored the newest pending bytes.")
            let pendingExport = try diskReader.exportData(originalURL: firstURL, workingCopyURL: failedCopy)
            check(PDFDocument(data: pendingExport).map { marker(in: $0) } == "newest pending",
                  "Export lost the newest failed-save snapshot.")
            check(diskReader.protectedWorkingCopyURLs.contains(failedCopy), "Unowned pending bytes lost copy protection.")
            let failedOwner = Owner()
            diskReader.register(failedOwner, url: firstURL, document: newestPDF, workingCopyURL: failedCopy)
            let failedGeneration = diskReader.noteMutation(for: firstURL, document: newestPDF, workingCopyURL: failedCopy)
            diskReader.notePreparedData(for: firstURL)
            diskReader.finishSave(for: firstURL, generation: failedGeneration, result: failedResult)
            check(failedOwner.saveStates.last?.dirty == true && failedOwner.saveStates.last?.error != nil,
                  "A current save failure did not synchronize dirty/error state to its owner.")
            diskReader.release(failedOwner, url: firstURL)
            check(diskReader.retainedEntry(for: firstURL)?.owner == nil && diskReader.retainedEntry(for: firstURL)?.dirty == true,
                  "Closing a failed writer discarded its retained dirty state.")
            try diskReader.discardWorkingCopy(originalURL: firstURL, workingCopyURL: failedCopy)
            check(queue.pendingData(for: failedCopy) == nil && diskReader.retainedEntry(for: firstURL) == nil,
                  "Explicit ownerless discard left pending bytes or dirty state behind.")
            let recoveredQueue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("recovery"))
            check(recoveredQueue.pendingData(for: failedCopy) == nil, "Explicit discard left a journal that resurrected abandoned bytes.")
            do {
                try diskReader.discardWorkingCopy(originalURL: firstURL, workingCopyURL: alias)
                check(false, "Ownerless discard accepted an original-file alias as a working copy.")
            } catch DocumentAccessError.discardFailed { check(true, "") }
            do {
                _ = try diskReader.readSnapshot(originalURL: firstURL, workingCopyURL: root.appendingPathComponent("absent-copy.pdf"))
                check(false, "A missing recorded copy silently fell back to the original.")
            } catch DocumentAccessError.workingCopyMissing { check(true, "") }
            check(originals.allSatisfy { (try? Data(contentsOf: $0.key)) == $0.value },
                  "Coordinator ownership/read/relocate/discard fixtures rewrote an original PDF.")
        } catch { check(false, "Shared coordinator fixture failed: \(error)") }
        return (checks, failures)
    }

    private struct SaveState {
        let dirty: Bool
        let error: String?
    }

    private final class Owner: PDFDocumentEditingOwner {
        var activations = 0
        var retries = 0
        var discards = 0
        var binds: [UUID] = []
        var adoptions: [(url: URL, fileID: UUID)] = []
        var saveStates: [SaveState] = []
        var discardAction: (() -> Bool)?
        var bindAction: ((UUID) -> Bool)?

        func activateEditor() { activations += 1 }
        func retryWorkingCopySave() { retries += 1 }
        func adoptRelocatedOriginal(_ url: URL, fileID: UUID) { adoptions.append((url, fileID)) }
        func synchronizeSaveState(from entry: DocumentAccessCoordinator.Entry) {
            saveStates.append(SaveState(dirty: entry.dirty, error: entry.saveError))
        }
        func discardCurrentWorkingCopyAndReopenOriginal() -> Bool {
            discards += 1
            return discardAction?() ?? false
        }
        @discardableResult func bindLibraryFile(_ fileID: UUID) -> Bool {
            binds.append(fileID)
            return bindAction?(fileID) ?? true
        }
    }

    private enum FixtureError: Error { case pdf, transaction }

    private static func makeDocument(_ marker: String) throws -> PDFDocument {
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw FixtureError.pdf }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 40, y: 40, width: 80, height: 30))
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(data: data as Data), let page = document.page(at: 0) else { throw FixtureError.pdf }
        let note = PDFAnnotation(bounds: CGRect(x: 50, y: 100, width: 30, height: 30), forType: .text, withProperties: nil)
        note.contents = marker
        page.addAnnotation(note)
        return document
    }

    private static func bytes(_ document: PDFDocument) throws -> Data {
        guard let data = document.dataRepresentationWithAIAnnotationsDisplayed() else { throw FixtureError.pdf }
        return data
    }

    private static func marker(in document: PDFDocument) -> String? {
        document.page(at: 0)?.annotations.first(where: { $0.type == "Text" })?.contents
    }

    private static func write(_ data: Data, to url: URL, queue: PDFSaveQueue) async -> Result<URL, Error> {
        await withCheckedContinuation { continuation in
            queue.enqueue(data: data, to: url) { continuation.resume(returning: $0) }
        }
    }
}
