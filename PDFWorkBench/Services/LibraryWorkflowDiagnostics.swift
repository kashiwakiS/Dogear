import CryptoKit
import Foundation

/// Isolated Foundation fixtures. No app Library, user PDF, provider or UI is used.
@MainActor
enum LibraryWorkflowDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("LibraryWorkflowDiagnostics-\(UUID().uuidString)")
        let domain = "Dogear.LibraryWorkflowDiagnostics.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else {
            return (1, ["Could not create isolated Library workflow defaults."])
        }
        defer {
            try? manager.removeItem(at: root)
            defaults.removePersistentDomain(forName: domain)
        }
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            let original = root.appendingPathComponent("original.pdf")
            let replacement = root.appendingPathComponent("moved-original.pdf")
            let different = root.appendingPathComponent("different.pdf")
            let bytes = Data("abc".utf8)
            try bytes.write(to: original)
            try bytes.write(to: replacement)
            try Data("abd".utf8).write(to: different)
            let fingerprint = try await PDFOriginalIdentityService.fingerprint(at: original)
            check(fingerprint.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
                    && fingerprint.byteCount == 3, "Original fingerprint did not match the SHA-256 reference vector.")
            let largeURL = root.appendingPathComponent("streamed.pdf")
            let largeBytes = Data(repeating: 0x5a, count: 2_097_169)
            try largeBytes.write(to: largeURL)
            let streamed = try await PDFOriginalIdentityService.fingerprint(at: largeURL)
            check(streamed.sha256 == SHA256.hash(data: largeBytes).map { String(format: "%02x", $0) }.joined(),
                  "Streaming fingerprint lost bytes across chunk boundaries.")

            let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
            try manager.createDirectory(at: copies.directoryURL, withIntermediateDirectories: true)
            let storage = try LibraryJSONStore(stateURL: root.appendingPathComponent("library/state.json"))
            let library = LibraryStore(userDefaults: defaults, storage: storage, workingCopyStore: copies)
            let file = library.upsertOpenedURL(original, refreshBookmark: false)
            let copyURL = copies.workingCopyURL(forOriginalURL: original)
            let edited = Data("edited working copy; not the original".utf8)
            try edited.write(to: copyURL)
            library.updateWorkingCopyURL(copyURL, for: file)
            let baseline = try await library.captureOriginalFingerprint(for: file.id)
            check(baseline == fingerprint.sha256, "Baseline was taken from the edited copy instead of the original.")
            let persisted = try storage.load()
            check(persisted?.schemaVersion == 6 && persisted?.files.first?.originalSHA256 == baseline,
                  "Original SHA-256 did not survive Library persistence.")
            let legacyFile = try JSONDecoder().decode(LibraryFile.self, from: JSONEncoder().encode(file))
            check(legacyFile.originalSHA256 == nil && legacyFile.id == file.id,
                  "A legacy record without original SHA-256 did not decode unchanged.")

            let second = library.upsertOpenedURL(different, refreshBookmark: false)
            let third = library.upsertOpenedURL(largeURL, refreshBookmark: false)
            let firstGroup = try library.createGroup(named: "First", containing: [file.id, second.id, file.id])
            let otherGroup = try library.createGroup(named: "Other", containing: [file.id])
            check(library.files(in: firstGroup.id).map(\.id) == [file.id, second.id],
                  "Create-from-selection lost source order or duplicated membership.")
            let added = try library.addFiles([file.id, second.id, third.id], to: otherGroup.id)
            check(added == 2 && library.files(in: otherGroup.id).map(\.id) == [file.id, second.id, third.id],
                  "Batch add did not preserve existing members and selection order.")
            let moved = try library.moveFiles([file.id, second.id], to: otherGroup.id, from: firstGroup.id)
            check(moved == 2 && library.files(in: firstGroup.id).isEmpty
                    && library.files(in: otherGroup.id).count == 3,
                  "Batch move lost target membership or failed to remove source membership.")
            _ = try library.addFiles([file.id], to: firstGroup.id)
            _ = try library.removeFiles([file.id], from: otherGroup.id)
            check(library.isFile(file, in: firstGroup) && !library.isFile(file, in: otherGroup),
                  "Batch removal altered another Group's membership.")
            try library.updateTags([" Reading ", "reading", "AI", ""], for: [file.id, second.id])
            check(library.file(for: original)?.tags == ["Reading", "AI"], "Tag normalization lost content or kept duplicates.")
            let beforeInvalidBatch = library.state
            do { _ = try library.addFiles([third.id, UUID()], to: firstGroup.id); check(false, "Invalid batch partly applied.") }
            catch { check(library.state == beforeInvalidBatch, "Invalid batch changed Library state.") }
            do { _ = try library.createGroup(named: "First", containing: [third.id]); check(false, "Duplicate Group creation was accepted.") }
            catch { check(error as? LibraryWorkflowError == .groupNameExists && library.state == beforeInvalidBatch,
                          "Duplicate Group creation changed existing membership.") }
            let sessionID = UUID()
            library.recordOpenedFiles([file.id, second.id, file.id], in: firstGroup.id, sessionID: sessionID)
            check(library.openSession(for: firstGroup.id, sessionID: sessionID)?.openFileIDs == [file.id, second.id],
                  "Batch session recording duplicated or reordered files.")
            let imported = library.upsertOpenedURLs([original, different, original], refreshBookmark: false,
                groupID: otherGroup.id, sessionID: UUID())
            check(imported.map(\.id) == [file.id, second.id] && !library.isFile(file, in: otherGroup),
                  "Batch reopen duplicated files or silently changed existing membership.")

            library.updateLastPage(for: original, pageIndex: 7)
            let mismatchURL = root.appendingPathComponent("mismatch.pdf")
            try Data("different candidate".utf8).write(to: mismatchURL)
            let mismatch = try await library.prepareRelink(fileID: file.id, to: mismatchURL)
            check(mismatch.disposition == .differentContent, "Different bytes passed the relink check.")
            let beforeMismatch = library.state
            do { _ = try library.commitRelink(mismatch); check(false, "Different bytes acquired the old identity.") }
            catch { check(error as? LibraryWorkflowError == .contentMismatch && library.state == beforeMismatch,
                          "Rejected relink changed the original Library record.") }
            do { _ = try await library.prepareRelink(fileID: file.id, to: different); check(false, "Existing Library destination passed relink.") }
            catch { check(error as? LibraryWorkflowError == .alreadyInLibrary, "Wrong duplicate-destination failure.") }
            do { _ = try await library.prepareRelink(fileID: file.id, to: copyURL); check(false, "Working copy was adopted as an original.") }
            catch { check(error as? LibraryWorkflowError == .unsafeWorkingCopy, "Working-copy destination was not explicitly rejected.") }

            let stale = try await library.prepareRelink(fileID: file.id, to: replacement)
            try Data("changed".utf8).write(to: replacement)
            do { _ = try library.commitRelink(stale); check(false, "Changed candidate passed the final relink check.") }
            catch { check(error as? LibraryWorkflowError == .changedWhileReading, "Changed candidate did not fail by file-version check.") }
            try bytes.write(to: replacement)
            let prepared = try await library.prepareRelink(fileID: file.id, to: replacement)
            let verified = try await library.revalidateRelink(prepared)
            try manager.removeItem(at: original)
            let relocated = try library.commitRelink(verified)
            check(relocated.id == file.id && relocated.originalSHA256 == baseline
                    && relocated.canonicalPath == replacement.resolvingSymlinksInPath().standardizedFileURL.path
                    && relocated.workingCopyPath == copyURL.standardizedFileURL.path,
                  "Verified relink changed file identity or lost the old working-copy path.")
            check(relocated.tags == ["Reading", "AI"] && relocated.lastPageIndex == 7
                    && library.isFile(relocated, in: firstGroup),
                  "Verified relink lost tags, reading position or Group membership.")
            check(try Data(contentsOf: copyURL) == edited && Data(contentsOf: replacement) == bytes,
                  "Relinking modified PDF bytes.")
            let reloaded = LibraryStore(userDefaults: defaults, storage: storage, workingCopyStore: copies)
            check(reloaded.file(for: replacement)?.id == file.id && reloaded.file(for: replacement)?.workingCopyURL == copyURL,
                  "Relink did not survive reload.")

            let missingURL = root.appendingPathComponent("unknown-original.pdf")
            let unknown = library.upsertOpenedURL(missingURL, refreshBookmark: false)
            let unknownCandidate = root.appendingPathComponent("unknown-candidate.pdf")
            try bytes.write(to: unknownCandidate)
            let unknownPlan = try await library.prepareRelink(fileID: unknown.id, to: unknownCandidate)
            check(unknownPlan.disposition == .baselineUnavailable && unknownPlan.originalSHA256 == nil,
                  "A missing legacy original borrowed the candidate's hash as its baseline.")
            do { _ = try library.commitRelink(unknownPlan); check(false, "Unknown baseline acquired the old identity.") }
            catch { check(error as? LibraryWorkflowError == .baselineUnavailable, "Unknown baseline did not require a new file identity.") }

            let rollbackURL = root.appendingPathComponent("rollback-candidate.pdf")
            try bytes.write(to: rollbackURL)
            let rollbackPlan = try await library.prepareRelink(fileID: file.id, to: rollbackURL)
            let beforeFailedWrite = library.state
            // The production ISO-8601 encoder stores whole seconds; compare
            // decoded snapshots, not persisted dates with in-memory fractions.
            let persistedBeforeFailedWrite = try storage.load()
            let libraryDirectory = storage.stateURL.deletingLastPathComponent()
            let heldDirectory = root.appendingPathComponent("held-library")
            try manager.moveItem(at: libraryDirectory, to: heldDirectory)
            try Data("blocks directory creation".utf8).write(to: libraryDirectory)
            do { _ = try library.commitRelink(rollbackPlan); check(false, "Relink succeeded despite a failed Library write.") }
            catch { check(error as? LibraryWorkflowError == .persistenceFailed && library.state == beforeFailedWrite,
                          "Failed relink persistence published the candidate binding.") }
            do { _ = try library.createGroup(named: "Must roll back", containing: [file.id]); check(false, "Batch creation succeeded despite a failed Library write.") }
            catch { check(error as? LibraryWorkflowError == .persistenceFailed && library.state == beforeFailedWrite,
                          "Failed Group transaction published a partial Group or membership.") }
            try manager.removeItem(at: libraryDirectory)
            try manager.moveItem(at: heldDirectory, to: libraryDirectory)
            let recoveredFlush = library.flushPendingPersistence()
            let recoveredState = try storage.load()
            check(recoveredFlush && recoveredState == persistedBeforeFailedWrite,
                  "Rejected Library transaction reappeared after persistence recovered.")

            let cancelURL = root.appendingPathComponent("cancelled.pdf")
            try largeBytes.write(to: cancelURL)
            let cancelledFile = library.upsertOpenedURL(cancelURL, refreshBookmark: false)
            let cancelled = Task { try await library.captureOriginalFingerprint(for: cancelledFile.id) }
            cancelled.cancel()
            do { _ = try await cancelled.value; check(false, "Cancelled baseline capture succeeded.") }
            catch { check(error is CancellationError && library.file(for: cancelURL)?.originalSHA256 == nil,
                          "Cancelled baseline capture wrote Library metadata.") }

            let orphanURL = copies.directoryURL.appendingPathComponent("orphan.pdf")
            try bytes.write(to: orphanURL)
            let missingCopy = copies.directoryURL.appendingPathComponent("missing-copy.pdf")
            library.updateWorkingCopyURL(missingCopy, for: unknown)
            let unsafeURL = copies.directoryURL.appendingPathComponent("alias.pdf")
            try manager.createSymbolicLink(at: unsafeURL, withDestinationURL: replacement)
            try manager.removeItem(at: replacement)
            let inventory = try await WorkingCopyInventoryService.scan(directoryURL: copies.directoryURL,
                files: library.allFiles)
            let associated = inventory.first { $0.fileIDs.contains(file.id) }
            check(associated?.status == .available && associated?.missingOriginalFileIDs == [file.id]
                    && associated?.sizeBytes == Int64(edited.count),
                  "Inventory lost the readable copy or its missing-original state.")
            check(inventory.first { $0.fileIDs.contains(unknown.id) }?.status == .missing,
                  "Inventory omitted a missing recorded copy.")
            check(inventory.first { $0.url.lastPathComponent == "alias.pdf" }?.status == .unsafeReference,
                  "Inventory treated a symbolic link as a manageable regular copy.")
            guard let orphan = inventory.first(where: { $0.url.lastPathComponent == "orphan.pdf" }) else {
                throw LibraryWorkflowError.fileUnavailable
            }
            check(orphan.status == .unassociated && orphan.fileIDs.isEmpty, "Inventory failed to identify an unassociated copy.")
            let protected = try await WorkingCopyInventoryService.scan(directoryURL: copies.directoryURL,
                files: library.allFiles, protectedURLs: [orphanURL])
            check(protected.first { $0.url.lastPathComponent == "orphan.pdf" }?.status == .protected,
                  "A pending/live copy was incorrectly offered as an unassociated copy.")
            let exportedURL = root.appendingPathComponent("recovered.pdf")
            _ = try await WorkingCopyInventoryService.exportUnassociatedCopy(orphan, to: exportedURL)
            check(try Data(contentsOf: exportedURL) == bytes && Data(contentsOf: orphanURL) == bytes,
                  "Recovery export did not preserve the independent original and recovered bytes.")
            do { _ = try await WorkingCopyInventoryService.exportUnassociatedCopy(orphan, to: exportedURL); check(false, "Recovery overwrote an existing destination.") }
            catch { check(error as? LibraryWorkflowError == .destinationExists, "Recovery did not report an existing destination.") }

            let legacyOriginal = root.appendingPathComponent("legacy-original.pdf")
            let legacyMoved = root.appendingPathComponent("legacy-moved.pdf")
            try bytes.write(to: legacyOriginal)
            try bytes.write(to: legacyMoved)
            let legacy = library.upsertOpenedURL(legacyOriginal, refreshBookmark: false)
            _ = try await library.captureOriginalFingerprint(for: legacy.id)
            let beforeFirstEdit = try await library.prepareRelink(fileID: legacy.id, to: legacyMoved)
            let lateCopy = copies.workingCopyURL(forOriginalURL: legacyOriginal)
            try edited.write(to: lateCopy)
            check(library.openingWorkingCopyURL(for: legacy)?.path == lateCopy.path,
                  "Opening did not find a legacy working copy before its path was persisted.")
            let afterFirstEdit = try library.commitRelink(beforeFirstEdit)
            check(afterFirstEdit.workingCopyURL?.path == lateCopy.path,
                  "Relink lost the first working copy created after preflight but before commit.")

            // A bookmark may resolve at the new URL while the persisted path
            // still names the previous location. No actual user file is moved.
            var staleLocation = afterFirstEdit
            staleLocation.canonicalPath = legacyOriginal.standardizedFileURL.path
            staleLocation.workingCopyPath = nil
            let bookmarkStorage = try LibraryJSONStore(stateURL: root.appendingPathComponent("bookmark-library.json"))
            try bookmarkStorage.save(LibraryState(files: [staleLocation]))
            let bookmarkLibrary = LibraryStore(userDefaults: defaults, storage: bookmarkStorage, workingCopyStore: copies)
            check(bookmarkLibrary.file(for: legacyMoved) == nil
                    && bookmarkLibrary.fileForOpening(at: legacyMoved)?.id == legacy.id,
                  "Opening failed to match the existing bookmark when its stored path was stale.")
            let bookmarkReopened = bookmarkLibrary.upsertOpenedURLs([legacyMoved, legacyMoved])
            check(bookmarkReopened.count == 1 && bookmarkReopened.first?.id == legacy.id
                    && bookmarkLibrary.allFiles.count == 1
                    && bookmarkReopened.first?.workingCopyURL?.path == lateCopy.path
                    && bookmarkReopened.first?.canonicalPath == staleLocation.canonicalPath,
                  "Bookmark-based import duplicated identity, lost its copy or changed the writer path before handoff.")
            bookmarkLibrary.refreshResolvedURL(legacyMoved, for: staleLocation)
            check(bookmarkLibrary.file(for: legacyMoved)?.id == legacy.id
                    && bookmarkLibrary.file(for: legacyMoved)?.workingCopyURL?.path == lateCopy.path,
                  "Successful opening failed to refresh the moved path while retaining the old copy.")

            let probe = LibraryWorkflowWriteProbe()
            let writer = LibraryStateWriter(delay: 60, save: probe.save)
            var accepted = library.state
            accepted.files[0].lastPageIndex = 42
            writer.saveSoon(accepted)
            var rejected = accepted
            rejected.groups.append(LibraryGroup(name: "Reject transaction", sortIndex: 999))
            do { try writer.saveTransactionally(rejected); check(false, "Injected transaction failure was ignored.") }
            catch { check(true, "") }
            check(writer.flush() && probe.saved == accepted,
                  "A failed transaction replaced the prior pending snapshot or reappeared during flush.")
        } catch {
            check(false, "Library workflow fixture failed: \(error.localizedDescription)")
        }
        return (checks, failures)
    }
}

nonisolated private final class LibraryWorkflowWriteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: LibraryState?
    var saved: LibraryState? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }
    func save(_ state: LibraryState) throws {
        if state.groups.contains(where: { $0.name == "Reject transaction" }) {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        lock.lock(); defer { lock.unlock() }
        latest = state
    }
}
