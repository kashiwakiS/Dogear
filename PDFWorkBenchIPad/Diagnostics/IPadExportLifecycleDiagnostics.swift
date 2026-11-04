#if os(iOS)
import CryptoKit
import Combine
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// Real export presenter, application lifecycle and shared save/recovery services.
/// UIApplication registration, credentials and one directory-failure endpoint
/// are injected; actual documents, stores and journals use disposable paths.
@MainActor
enum IPadExportLifecycleDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        let shared = DocumentExportRequestDiagnostics.run()
        checks += shared.checkCount
        failures += shared.failures.map { "Shared export: \($0)" }
        let saveQueue = await PDFSaveQueueDiagnostics.run()
        checks += saveQueue.checks
        failures += saveQueue.failures.map { "Shared save queue: \($0)" }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearIPadExportLifecycle-\(UUID())")
        let suiteName = "DogearIPadExportLifecycle.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return (checks + 1, failures + ["Could not create lifecycle fixture defaults."])
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try exercisePresenter(root: root, check: check)
            try await exerciseRecovery(root: root, defaults: defaults, check: check)
            try await exerciseContainerRecovery(root: root.appendingPathComponent("container-with-copy"),
                defaults: defaults, savesInitialCopy: true, check: check)
            try await exerciseContainerRecovery(root: root.appendingPathComponent("container-first-copy"),
                defaults: defaults, savesInitialCopy: false, check: check)
            try await exerciseBackground(root: root, defaults: defaults, check: check)
            try await exerciseBackgroundRecovery(root: root.appendingPathComponent("background-recovery"),
                defaults: defaults, check: check)
            try await exerciseWorkspaceLifecycle(root: root.appendingPathComponent("workspace-lifecycle"),
                defaults: defaults, check: check)
        } catch { check(false, "Export/lifecycle fixture failed: \(error.localizedDescription)") }
        return (checks, failures)
    }

    private static func exercisePresenter(root: URL, check: (Bool, String) -> Void) throws {
        let original = root.appendingPathComponent("original.pdf")
        let originalBytes = fixtureData()
        try originalBytes.write(to: original)
        let request = DocumentExportRequest(data: Data("captured export".utf8), suggestedName: "copy.pdf",
            contentType: .pdf, protectedOriginalURL: original)
        let presenter = IPadDocumentExportPresenter()
        var results: [Result<URL?, Error>] = []
        presenter.export(request) { results.append($0) }
        let first = try required(presenter.ticket)
        var competingExportFailed = false
        presenter.export(request) { result in
            if case .failure = result { competingExportFailed = true }
        }
        check(competingExportFailed && presenter.ticket?.id == first.id,
              "A competing export replaced the current presenter ticket.")
        presenter.finish(UUID(), result: .success(nil))
        check(presenter.ticket?.id == first.id && results.isEmpty,
              "An unrelated native dismissal completed the current export.")
        let cancelledDestination = root.appendingPathComponent("cancelled.pdf")
        presenter.finish(first.id, result: .success(nil))
        presenter.finish(first.id, result: .success(cancelledDestination))
        let oldWrite = try presenter.write(first.id, to: cancelledDestination)
        check(isExpired(oldWrite) && !FileManager.default.fileExists(atPath: cancelledDestination.path)
                && results.count == 1,
              "A cancelled ticket wrote bytes or completed more than once.")

        presenter.export(request) { results.append($0) }
        let second = try required(presenter.ticket)
        do {
            _ = try presenter.write(second.id, to: original)
            check(false, "The native presenter wrote over the protected original.")
        } catch SafeDocumentExportError.originalDestination { check(true, "") }
        check(presenter.ticket?.id == second.id && (try? Data(contentsOf: original)) == originalBytes,
              "Original refusal completed its ticket or changed the original.")

        let destination = root.appendingPathComponent("existing.pdf")
        let previousBytes = Data("previous exported file".utf8)
        try previousBytes.write(to: destination)
        let firstConfirmation = try confirmation(presenter.write(second.id, to: destination))
        check((try? Data(contentsOf: destination)) == previousBytes && results.count == 1,
              "An existing file changed before explicit replacement consent.")
        presenter.cancelReplacement(firstConfirmation)
        check(isExpired(try presenter.replace(firstConfirmation))
                && (try? Data(contentsOf: destination)) == previousBytes,
              "A cancelled replacement confirmation remained capable of writing.")

        let confirmationA = try confirmation(presenter.write(second.id, to: destination))
        // Same bytes, a different inode: content equality alone cannot grant consent.
        try previousBytes.write(to: destination, options: .atomic)
        let confirmationB = try confirmation(presenter.replace(confirmationA))
        check(confirmationB.id != confirmationA.id && presenter.canReplace(confirmationB)
                && (try? Data(contentsOf: destination)) == previousBytes,
              "Changing target identity did not obtain fresh replacement consent.")
        check(isExpired(try presenter.replace(confirmationA)),
              "An older confirmation remained usable after target replacement.")
        let changedBytes = Data("edited while confirmation was open".utf8)
        try changedBytes.write(to: destination)
        let confirmationC = try confirmation(presenter.replace(confirmationB))
        check(confirmationC.id != confirmationB.id && (try? Data(contentsOf: destination)) == changedBytes,
              "Editing the same target did not require a new confirmation.")
        let replaced = try presenter.replace(confirmationC)
        check(isCompleted(replaced) && presenter.ticket == nil && results.count == 2
                && (try? Data(contentsOf: destination)) == request.data,
              "The current explicit confirmation did not complete exactly one frozen export.")

        presenter.export(request) { results.append($0) }
        let third = try required(presenter.ticket)
        let removedTarget = root.appendingPathComponent("removed.pdf")
        try previousBytes.write(to: removedTarget)
        let removedConfirmation = try confirmation(presenter.write(third.id, to: removedTarget))
        try FileManager.default.removeItem(at: removedTarget)
        check(isCompleted(try presenter.replace(removedConfirmation))
                && (try? Data(contentsOf: removedTarget)) == request.data,
              "A removed target did not use safe exclusive creation.")

        presenter.export(request) { results.append($0) }
        let fourth = try required(presenter.ticket)
        let aliasTarget = root.appendingPathComponent("alias-target.pdf")
        try previousBytes.write(to: aliasTarget)
        let aliasConfirmation = try confirmation(presenter.write(fourth.id, to: aliasTarget))
        try FileManager.default.removeItem(at: aliasTarget)
        try FileManager.default.linkItem(at: original, to: aliasTarget)
        let aliasAttributes = try FileManager.default.attributesOfItem(atPath: aliasTarget.path)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: original.path)
        check(aliasAttributes[.systemNumber] as? NSNumber == originalAttributes[.systemNumber] as? NSNumber
                && aliasAttributes[.systemFileNumber] as? NSNumber == originalAttributes[.systemFileNumber] as? NSNumber
                && aliasAttributes[.systemFileNumber] != nil,
              "Native late-alias fixture lacks an actual hard link: alias \(aliasAttributes), original \(originalAttributes).")
        do {
            let outcome = try presenter.replace(aliasConfirmation)
            check(false, "A confirmed export did not reject a newly introduced original hard link; outcome \(outcome).")
        } catch SafeDocumentExportError.originalDestination { check(true, "") }
        check((try? Data(contentsOf: original)) == originalBytes
                && (try? Data(contentsOf: aliasTarget)) == originalBytes && presenter.ticket?.id == fourth.id,
              "A late original alias refusal changed original/alias bytes or completed its retryable ticket.")
        presenter.finish(fourth.id, result: .success(nil))

        presenter.export(request) { results.append($0) }
        let fifth = try required(presenter.ticket)
        let failedTarget = root.appendingPathComponent("missing/failure.pdf")
        do {
            _ = try presenter.write(fifth.id, to: failedTarget)
            check(false, "A missing export directory reported success.")
        } catch { check(presenter.ticket?.id == fifth.id, "Write failure discarded the retryable ticket.") }
        let retryTarget = root.appendingPathComponent("retry.pdf")
        check(isCompleted(try presenter.write(fifth.id, to: retryTarget))
                && (try? Data(contentsOf: retryTarget)) == request.data,
              "A failed native export could not retry with its frozen request.")
    }

    private static func exerciseRecovery(root: URL, defaults: UserDefaults,
                                         check: (Bool, String) -> Void) async throws {
        let original = root.appendingPathComponent("recover-original.pdf")
        let originalBytes = fixtureData()
        try originalBytes.write(to: original)
        let obstruction = root.appendingPathComponent("blocked-copies")
        try Data("block copy directory".utf8).write(to: obstruction)
        let copies = try PDFWorkingCopyStore(directoryURL: obstruction)
        let journal = root.appendingPathComponent("recovery-journal")
        let queue = PDFSaveQueue(recoveryDirectoryURL: journal, workingCopyStore: copies)
        let access = DocumentAccessCoordinator(saveQueue: queue)
        func makeStore(queue: PDFSaveQueue, access: DocumentAccessCoordinator) -> PDFDocumentStore {
            PDFDocumentStore(feedbackCenter: OperationFeedbackCenter(userDefaults: defaults),
                metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("recovery-metadata.json")),
                aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("recovery-groups.json")),
                workingCopyStore: copies, saveQueue: queue, accessCoordinator: access,
                exportPresenter: IPadDocumentExportPresenter())
        }
        let first = makeStore(queue: queue, access: access)
        defer { first.releaseEditorAccess() }
        check(first.openPDF(from: original), "The actual recovery writer could not open the fixture PDF.")
        let draft = try required(first.newFreeTextDraft())
        var values = draft.values
        values.text = "Older recovery note"
        check(first.saveFreeText(draft, values: values), "The initial recoverable edit was refused.")
        let edit = try required(first.annotations.first { $0.kind == .note }.flatMap { first.freeTextEditDraft(for: $0) })
        values = edit.values
        values.text = "Latest recovery note"
        check(first.saveFreeText(edit, values: values), "The newest recoverable edit was refused.")
        await queue.drain()
        await deliverCompletions()
        let copy = try required(first.currentWorkingCopyURL)
        let pending = try required(queue.pendingData(for: copy))
        check(first.hasUnsavedChanges && first.workingCopySaveError != nil
                && !queue.hasUnrecoverablePendingWrites,
              "A failed Store save did not retain its dirty state and durable recovery bytes.")
        first.releaseEditorAccess()
        check(access.retainedEntry(for: original)?.owner == nil && access.retainedEntry(for: original)?.dirty == true,
              "Closing the failed editing owner discarded its latest state.")

        let restoredQueue = PDFSaveQueue(recoveryDirectoryURL: journal, workingCopyStore: copies)
        let restoredAccess = DocumentAccessCoordinator(saveQueue: restoredQueue)
        let restored = makeStore(queue: restoredQueue, access: restoredAccess)
        defer { restored.releaseEditorAccess() }
        check(restoredQueue.pendingData(for: copy) == pending,
              "A new save queue did not recover the latest failed PDF snapshot.")
        check(restored.openPDF(from: original, workingCopyURL: copy)
                && restored.annotations.contains(where: { $0.note == "Latest recovery note" })
                && restored.hasUnsavedChanges,
              "A new actual Store did not reopen the journal's latest annotated working copy.")
        try FileManager.default.removeItem(at: obstruction)
        restored.retryWorkingCopySave()
        await restoredQueue.drain()
        await deliverCompletions()
        check(!restored.hasUnsavedChanges && restored.workingCopySaveError == nil
                && restoredQueue.pendingData(for: copy) == nil,
              "Explicit retry did not clear actual Store and queue save failures.")
        let reloadedQueue = PDFSaveQueue(recoveryDirectoryURL: journal, workingCopyStore: copies)
        let journalFiles = try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil)
        check(reloadedQueue.pendingData(for: copy) == nil && journalFiles.isEmpty,
              "Successful retry left a recovery journal: copy \(copy.path), resolved \(copy.resolvingSymlinksInPath().path), journals \(journalFiles.map(\.lastPathComponent)), pending \(reloadedQueue.pendingDestinations.map(\.path)).")
        // Read the actual committed bytes rather than a PDFKit URL cache. Keep
        // the exact latest annotation assertion separate from journal cleanup.
        let committedBytes = try Data(contentsOf: copy)
        let committedPDF = try required(PDFDocument(data: committedBytes))
        let committedNotes = committedPDF.page(at: 0)?.annotations.map { $0.contents ?? "<nil>" } ?? []
        check(committedNotes.contains("Latest recovery note"),
              "Successful retry saved an older annotation: copy \(copy.path), bytes \(committedBytes.count), page count \(committedPDF.pageCount), notes \(committedNotes).")
        check((try? Data(contentsOf: original)) == originalBytes,
              "Failed saves, recovery or retry changed the original PDF.")
    }

    private static func exerciseContainerRecovery(root: URL, defaults: UserDefaults,
                                                  savesInitialCopy: Bool,
                                                  check: (Bool, String) -> Void) async throws {
        let manager = FileManager.default
        let label = savesInitialCopy ? "existing A0 copy" : "missing first copy"
        let original = root.appendingPathComponent("original.pdf")
        let originalBytes = fixtureData()
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try originalBytes.write(to: original)
        let oldRoot = root.appendingPathComponent("old-container")
        let newRoot = root.appendingPathComponent("new-container")
        let suffix = "Library/Application Support/PDFWorkBench"
        let oldSupport = oldRoot.appendingPathComponent(suffix)
        let oldCopies = try PDFWorkingCopyStore(directoryURL: oldSupport.appendingPathComponent("WorkingCopies"))
        let oldJournal = oldSupport.appendingPathComponent("PendingPDFWrites")
        let oldCopy = oldCopies.workingCopyURL(forOriginalURL: original)
        let failingManager = RecoveryDirectoryFailingFileManager(directoryURL: oldCopies.directoryURL)
        let firstQueue = PDFSaveQueue(fileManager: failingManager, recoveryDirectoryURL: oldJournal,
                                      workingCopyStore: oldCopies)
        func makeStore(copies: PDFWorkingCopyStore, queue: PDFSaveQueue,
                       access: DocumentAccessCoordinator, support: URL) -> PDFDocumentStore {
            PDFDocumentStore(feedbackCenter: OperationFeedbackCenter(userDefaults: defaults),
                metadataStore: DocumentMetadataStore(stateURL: support.appendingPathComponent("metadata.json")),
                aiHighlightGroupStore: AIHighlightGroupStore(stateURL: support.appendingPathComponent("groups.json")),
                workingCopyStore: copies, saveQueue: queue, accessCoordinator: access,
                exportPresenter: IPadDocumentExportPresenter())
        }
        func notes(in data: Data) -> [String] {
            PDFDocument(data: data)?.page(at: 0)?.annotations.compactMap {
                $0.type == "FreeText" ? $0.contents : nil
            } ?? []
        }
        let file = LibraryFile(displayName: "original.pdf", canonicalPath: original.path,
                               workingCopyPath: oldCopy.path)
        let first = makeStore(copies: oldCopies, queue: firstQueue,
            access: DocumentAccessCoordinator(saveQueue: firstQueue), support: oldSupport)
        defer { first.releaseEditorAccess() }
        check(first.openPDF(from: original) && first.bindLibraryFile(file.id),
              "Container recovery (\(label)) could not open/bind the actual editing Store.")
        if savesInitialCopy {
            let draft = try required(first.newFreeTextDraft())
            var values = draft.values
            values.text = "Container disk A0"
            check(first.saveFreeText(draft, values: values), "Container A0 edit was refused.")
            await firstQueue.drain()
            await waitForStoreSaveCompletion(first, failed: false)
            let diskNotes = notes(in: try Data(contentsOf: oldCopy))
            check(diskNotes == ["Container disk A0"] && !first.hasUnsavedChanges && first.workingCopySaveError == nil,
                  "Container fixture did not establish a committed standard A0 annotation: notes \(diskNotes), copy \(oldCopy.path), current \(first.currentWorkingCopyURL?.path ?? "nil"), dirty \(first.hasUnsavedChanges), error \(first.workingCopySaveError ?? "nil"), pending \(firstQueue.pendingDestinations.map(\.path)).")
        }
        failingManager.blocksWrites = true
        let earlierDraft = try required(first.annotations.first { $0.kind == .note }
            .flatMap { first.freeTextEditDraft(for: $0) } ?? first.newFreeTextDraft())
        var values = earlierDraft.values
        values.text = "Container earlier pending edit"
        check(first.saveFreeText(earlierDraft, values: values), "Container earlier pending edit was refused.")
        await firstQueue.drain()
        await waitForStoreSaveCompletion(first, failed: true)
        check(!failingManager.blockedDirectoryPaths.isEmpty && first.hasUnsavedChanges && first.workingCopySaveError != nil,
              "Container failure injection did not intercept the actual working-copy directory: expected \(oldCopies.directoryURL.path), attempted \(failingManager.attemptedDirectoryPaths), blocked \(failingManager.blockedDirectoryPaths), current \(first.currentWorkingCopyURL?.path ?? "nil"), dirty \(first.hasUnsavedChanges), error \(first.workingCopySaveError ?? "nil").")
        let firstJournals = try manager.contentsOfDirectory(at: oldJournal, includingPropertiesForKeys: nil)
        guard let firstJournalURL = firstJournals.first(where: { $0.pathExtension == "json" }) else {
            throw NSError(domain: "DogearContainerRecoveryFixture", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Container recovery (\(label)) has no earlier durable journal; attempted \(failingManager.attemptedDirectoryPaths), blocked \(failingManager.blockedDirectoryPaths), current \(first.currentWorkingCopyURL?.path ?? "nil"), error \(first.workingCopySaveError ?? "nil")."])
        }
        let earlierJournalBytes = try Data(contentsOf: firstJournalURL)
        let latestDraft = try required(first.annotations.first { $0.kind == .note }
            .flatMap { first.freeTextEditDraft(for: $0) })
        values = latestDraft.values
        values.text = "Container latest A1"
        check(first.saveFreeText(latestDraft, values: values), "Container latest pending A1 edit was refused.")
        await firstQueue.drain()
        await waitForStoreSaveCompletion(first, failed: true)
        let latest = try required(firstQueue.pendingData(for: oldCopy))
        check(notes(in: latest) == ["Container latest A1"] && first.hasUnsavedChanges
                && first.workingCopySaveError != nil && !firstQueue.hasUnrecoverablePendingWrites,
              "Container recovery (\(label)) lacks an actual durable latest standard A1 annotation: notes \(notes(in: latest)), dirty \(first.hasUnsavedChanges), error \(first.workingCopySaveError ?? "nil"), blocked \(failingManager.blockedDirectoryPaths).")
        let oldDiskUnchanged = savesInitialCopy ? notes(in: try Data(contentsOf: oldCopy)) == ["Container disk A0"]
                                               : !manager.fileExists(atPath: oldCopy.path)
        check(oldDiskUnchanged,
              "Container fixture failure changed A0 or created the first copy before recovery.")

        // Retain a real earlier journal under a legacy raw-alias path hash.
        // Both old names must map to one newest destination after relocation.
        let aliasRoot = root.appendingPathComponent("old-container-alias")
        try manager.createSymbolicLink(at: aliasRoot, withDestinationURL: oldRoot)
        let aliasCopy = aliasRoot.appendingPathComponent(suffix + "/WorkingCopies/" + oldCopy.lastPathComponent)
        let legacyHash = SHA256.hash(data: Data(aliasCopy.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let legacyJournal = oldJournal.appendingPathComponent(legacyHash + ".json")
        try earlierJournalBytes.write(to: legacyJournal, options: .atomic)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: legacyJournal.path)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: firstJournalURL.path)
        check(legacyJournal != firstJournalURL,
              "Container fixture did not preserve two distinct old path-hash journals.")
        try LibraryJSONStore(stateURL: oldSupport.appendingPathComponent("library.json")).save(LibraryState(files: [file]))
        first.releaseEditorAccess()
        try manager.moveItem(at: oldRoot, to: newRoot)

        let newSupport = newRoot.appendingPathComponent(suffix)
        let newCopies = try PDFWorkingCopyStore(directoryURL: newSupport.appendingPathComponent("WorkingCopies"))
        let newCopy = newCopies.directoryURL.appendingPathComponent(oldCopy.lastPathComponent)
        let newJournal = newSupport.appendingPathComponent("PendingPDFWrites")
        let recoveredQueue = PDFSaveQueue(recoveryDirectoryURL: newJournal, workingCopyStore: newCopies)
        let persistence = try LibraryJSONStore(stateURL: newSupport.appendingPathComponent("library.json"))
        let library = LibraryStore(userDefaults: defaults, storage: persistence, workingCopyStore: newCopies)
        let restoredFile = try required(library.allFiles.first)
        let openingCopy = try required(library.openingWorkingCopyURL(for: restoredFile))
        check(restoredFile.id == file.id && openingCopy.libraryComparablePath == newCopy.libraryComparablePath,
              "Container recovery (\(label)) lost Library identity or its current managed-copy intent.")
        check(recoveredQueue.pendingDestinations.count == 1 && recoveredQueue.pendingData(for: newCopy) == latest
                && PDFSaveQueue(recoveryDirectoryURL: newJournal).pendingData(for: newCopy) == latest,
              "Container journals did not map newest A1 to the injected/default current managed directory: old \(oldCopy.path), current \(newCopy.path), pending \(recoveredQueue.pendingDestinations.map(\.path)).")
        let newDiskUnchanged = savesInitialCopy ? notes(in: try Data(contentsOf: newCopy)) == ["Container disk A0"]
                                               : !manager.fileExists(atPath: newCopy.path)
        check(!manager.fileExists(atPath: oldRoot.path) && newDiskUnchanged,
              "Loading container journals wrote bytes or recreated the obsolete container.")
        let recovered = makeStore(copies: newCopies, queue: recoveredQueue,
            access: DocumentAccessCoordinator(saveQueue: recoveredQueue), support: newSupport)
        defer { recovered.releaseEditorAccess() }
        check(recovered.openPDF(from: original, workingCopyURL: openingCopy)
                && recovered.bindLibraryFile(restoredFile.id)
                && recovered.annotations.filter { $0.kind == .note }.compactMap(\.note) == ["Container latest A1"]
                && recovered.hasUnsavedChanges
                && recovered.currentWorkingCopyURL?.libraryComparablePath == newCopy.libraryComparablePath,
              "Container recovery (\(label)) actual Store opened disk A0/original instead of journal A1.")
        recovered.retryWorkingCopySave()
        await recoveredQueue.drain()
        await waitForStoreSaveCompletion(recovered, failed: false)
        let journals = try manager.contentsOfDirectory(at: newJournal, includingPropertiesForKeys: nil)
        let committedNotes = notes(in: try Data(contentsOf: newCopy))
        check(committedNotes == ["Container latest A1"]
                && !recovered.hasUnsavedChanges && recovered.workingCopySaveError == nil,
              "Container retry (\(label)) did not commit current standard A1 annotations and clear Store failure: notes \(committedNotes), dirty \(recovered.hasUnsavedChanges), error \(recovered.workingCopySaveError ?? "nil"), pending \(recoveredQueue.pendingDestinations.map(\.path)).")
        let finalQueue = PDFSaveQueue(recoveryDirectoryURL: newJournal, workingCopyStore: newCopies)
        check(journals.isEmpty && recoveredQueue.pendingDestinations.isEmpty && finalQueue.pendingDestinations.isEmpty,
              "Container retry retained old/current hash journals or resurrected pending edits: \(journals.map(\.lastPathComponent)), pending \(finalQueue.pendingDestinations.map(\.path)).")
        recovered.releaseEditorAccess()
        let final = makeStore(copies: newCopies, queue: finalQueue,
            access: DocumentAccessCoordinator(saveQueue: finalQueue), support: newSupport)
        defer { final.releaseEditorAccess() }
        check(final.openPDF(from: original, workingCopyURL: openingCopy)
                && final.annotations.filter { $0.kind == .note }.compactMap(\.note) == ["Container latest A1"]
                && !final.hasUnsavedChanges && final.workingCopySaveError == nil,
              "Container retry (\(label)) did not survive reconstructed queue and actual Store reload.")
        check((try? Data(contentsOf: original)) == originalBytes && !manager.fileExists(atPath: oldRoot.path),
              "Container recovery changed original bytes or recreated an obsolete destination.")
    }

    private static func exerciseBackground(root: URL, defaults: UserDefaults,
                                           check: (Bool, String) -> Void) async throws {
        let libraryFile = root.appendingPathComponent("background-original.pdf")
        try fixtureData().write(to: libraryFile)
        let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("background-copies"))
        let persistence = try LibraryJSONStore(stateURL: root.appendingPathComponent("background-library.json"))
        let library = LibraryStore(userDefaults: defaults, storage: persistence,
                                   readingPositionSaveDelay: 3_600, workingCopyStore: copies)
        _ = library.upsertOpenedURLs([libraryFile], refreshBookmark: false)
        let research = ResearchStore(rootURL: root.appendingPathComponent("background-research"))
        let commands = ResearchCommandService(store: research)
        let configuration = AIConfigurationStore(configurationURL: root.appendingPathComponent("background-ai.json"),
            legacyUserDefaults: defaults, secretStore: EmptySecrets())
        let trace = AIHighlightTraceRecorder(fileURL: root.appendingPathComponent("background-trace.jsonl"), defaults: defaults)
        let runtime = ResearchRuntime(storage: research, configuration: configuration,
            service: AIHighlightWorkflowService(traceRecorder: trace), traceRecorder: trace,
            commands: commands, retrievalSelection: .lexical)
        let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("background-journal"), workingCopyStore: copies)
        var expirations: [@MainActor () -> Void] = []
        var endedTasks: [UIBackgroundTaskIdentifier] = []
        let services = IPadApplicationServices(library: library, research: research,
            configuration: configuration, language: AppLanguageStore(userDefaults: defaults),
            commands: commands, runtime: runtime, saveQueue: queue, observesApplication: false,
            beginBackgroundTask: { expiration in
                expirations.append(expiration)
                return UIBackgroundTaskIdentifier(rawValue: expirations.count)
            }, endBackgroundTask: { endedTasks.append($0) })
        let session = research.createSession(title: "Background fixture")
        _ = research.saveDraft(ResearchDraft(text: "Retained background draft"), sessionID: session)
        let firstRequest = research.beginRequest(sessionID: session, question: "First pending request", sourceSnapshot: [])
        check(firstRequest != nil, "The background fixture did not create a durable pending Research request.")
        library.updateLastPage(for: libraryFile, pageIndex: 1)
        services.saveForBackground()
        check(research.session(id: session)?.activeRequestID == nil
                && (try? persistence.load())?.files.first?.lastPageIndex == 1,
              "The application background boundary did not interrupt Research and flush Library state.")

        // No actor yield: the first native drain is still pending. This is the
        // same boundary as foreground edits followed by another background event.
        let secondRequest = research.beginRequest(sessionID: session, question: "New foreground request", sourceSnapshot: [])
        library.updateLastPage(for: libraryFile, pageIndex: 2)
        services.saveForBackground()
        check(secondRequest != nil && research.session(id: session)?.activeRequestID == nil
                && (try? persistence.load())?.files.first?.lastPageIndex == 2,
              "A pending prior drain skipped the next background Research/Library flush.")
        check(expirations.count == 1 && endedTasks.isEmpty,
              "Repeated background events opened duplicate native save windows.")
        expirations[0]()
        check(endedTasks.count == 1, "Native expiration did not end the first background save window.")
        library.updateLastPage(for: libraryFile, pageIndex: 3)
        services.saveForBackground()
        check(expirations.count == 2, "A later background event did not reopen an expired save window.")
        expirations[0]()
        check(endedTasks.count == 1, "An old expiration callback ended the current background window.")
        expirations[1]()
        await services.waitForBackgroundSave()
        check(endedTasks.count == 2, "Drain completion ended an expired background task twice.")
        services.saveForBackground()
        await services.waitForBackgroundSave()
        check(expirations.count == 3 && endedTasks.count == 3,
              "A completed drain prevented a subsequent background save window.")
        let reloaded = ResearchStore(rootURL: research.rootURL)
        check(reloaded.session(id: session)?.draft.text == "Retained background draft"
                && reloaded.session(id: session)?.activeRequestID == nil
                && (try? persistence.load())?.files.first?.lastPageIndex == 3,
              "Background lifecycle did not durably preserve the draft and latest reading position.")
    }

    /// Exercises real service persistence with injected background-task callbacks.
    /// Fresh service instances model reconstruction, not OS process termination.
    private static func exerciseBackgroundRecovery(root: URL, defaults: UserDefaults,
                                                   check: (Bool, String) -> Void) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("original.pdf"), originalBytes = fixtureData()
        try originalBytes.write(to: original)
        let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
        let journal = root.appendingPathComponent("journal")
        let failingManager = RecoveryDirectoryFailingFileManager(directoryURL: copies.directoryURL)
        let queue = PDFSaveQueue(fileManager: failingManager, recoveryDirectoryURL: journal, workingCopyStore: copies)
        let access = DocumentAccessCoordinator(saveQueue: queue)
        let persistence = try LibraryJSONStore(stateURL: root.appendingPathComponent("library.json"))
        let library = LibraryStore(userDefaults: defaults, storage: persistence,
                                   readingPositionSaveDelay: 3_600, workingCopyStore: copies)
        let file = try required(library.upsertOpenedURLs([original], refreshBookmark: false).first)
        func makeStore(queue: PDFSaveQueue, access: DocumentAccessCoordinator) -> PDFDocumentStore {
            PDFDocumentStore(feedbackCenter: OperationFeedbackCenter(userDefaults: defaults),
                metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("metadata.json")),
                aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("groups.json")),
                workingCopyStore: copies, saveQueue: queue, accessCoordinator: access,
                exportPresenter: IPadDocumentExportPresenter())
        }
        func standardNotes(in document: PDFDocument) -> [[String]] {
            (0..<document.pageCount).map { index in
                document.page(at: index)?.annotations.compactMap { $0.type == "FreeText" ? $0.contents : nil } ?? []
            }
        }
        func standardNotes(in data: Data) throws -> [[String]] {
            standardNotes(in: try required(PDFDocument(data: data)))
        }
        let diskText = "Background committed A0", earlierText = "Background pending A1"
        let latestText = "Background latest A2"
        let diskNotes: [[String]] = [[], [diskText], [], []]
        let earlierNotes: [[String]] = [[], [earlierText], [], []]
        let latestNotes: [[String]] = [[], [latestText], [], []]
        let first = makeStore(queue: queue, access: access)
        defer { first.releaseEditorAccess() }
        check(first.openPDF(from: original, initialPageIndex: 1) && first.bindLibraryFile(file.id),
              "Background recovery could not open/bind the actual page-two editing Store.")
        let binding = IPadWorkingCopyLibraryBinding(store: first, library: library)
        binding.bind(fileID: file.id)
        let document = try required(first.document)
        let draft = try required(first.newFreeTextDraft())
        var values = draft.values; values.text = diskText
        check(first.saveFreeText(draft, values: values), "Background recovery refused its initial standard A0 note.")
        await queue.drain()
        await waitForStoreSaveCompletion(first, failed: false)
        let copy = try required(first.currentWorkingCopyURL)
        let committedA0 = try Data(contentsOf: copy)
        let establishedNotes = try standardNotes(in: committedA0)
        check(establishedNotes == diskNotes && !first.hasUnsavedChanges
                && first.workingCopySaveError == nil && queue.pendingDestinations.isEmpty
                && library.allFiles.first(where: { $0.id == file.id })?.workingCopyURL?.libraryComparablePath == copy.libraryComparablePath,
              "Background recovery did not establish standard page-two A0 and its bound Library copy: notes \(establishedNotes), dirty \(first.hasUnsavedChanges), error \(first.workingCopySaveError ?? "nil"), copy \(copy.path).")

        failingManager.blocksWrites = true
        let earlier = try required(first.annotations.first { $0.kind == .note }.flatMap { first.freeTextEditDraft(for: $0) })
        values = earlier.values; values.text = earlierText
        check(first.saveFreeText(earlier, values: values), "Background recovery refused its earlier pending A1 edit.")
        await queue.drain()
        await waitForStoreSaveCompletion(first, failed: true)
        let earlierPending = try required(queue.pendingData(for: copy))
        let durableEarlierNotes = try standardNotes(in: earlierPending)
        check(durableEarlierNotes == earlierNotes && first.hasUnsavedChanges
                && first.workingCopySaveError != nil && !queue.hasUnrecoverablePendingWrites
                && failingManager.blockedDirectoryPaths.count == 1,
              "Background recovery did not establish an intercepted, durable A1 failure: notes \(durableEarlierNotes), attempted \(failingManager.attemptedDirectoryPaths), blocked \(failingManager.blockedDirectoryPaths), error \(first.workingCopySaveError ?? "nil").")

        let research = ResearchStore(rootURL: root.appendingPathComponent("research"))
        let commands = ResearchCommandService(store: research)
        let configuration = AIConfigurationStore(configurationURL: root.appendingPathComponent("ai.json"),
            legacyUserDefaults: defaults, secretStore: EmptySecrets())
        let trace = AIHighlightTraceRecorder(fileURL: root.appendingPathComponent("trace.jsonl"), defaults: defaults)
        let runtime = ResearchRuntime(storage: research, configuration: configuration,
            service: AIHighlightWorkflowService(traceRecorder: trace), traceRecorder: trace,
            commands: commands, retrievalSelection: .lexical)
        var expirations: [@MainActor () -> Void] = []
        var endedTasks: [UIBackgroundTaskIdentifier] = []
        let firstTask = UIBackgroundTaskIdentifier(rawValue: 101), secondTask = UIBackgroundTaskIdentifier(rawValue: 102)
        let services = IPadApplicationServices(library: library, research: research,
            configuration: configuration, language: AppLanguageStore(userDefaults: defaults),
            commands: commands, runtime: runtime, saveQueue: queue, observesApplication: false,
            beginBackgroundTask: { expiration in
                expirations.append(expiration)
                return UIBackgroundTaskIdentifier(rawValue: 100 + expirations.count)
            }, endBackgroundTask: { endedTasks.append($0) })
        let session = research.createSession(title: "Pending PDF background recovery")
        let draftText = "Draft retained with latest PDF journal"
        _ = research.saveDraft(ResearchDraft(text: draftText), sessionID: session)
        let firstRequest = research.beginRequest(sessionID: session, question: "Earlier foreground request", sourceSnapshot: [])
        first.recordCurrentPage(2); binding.recordPage(2, in: document)
        services.saveForBackground()
        check(firstRequest != nil && research.session(id: session)?.activeRequestID == nil
                && (try? persistence.load())?.files.first(where: { $0.id == file.id })?.lastPageIndex == 2
                && queue.pendingData(for: copy) == earlierPending,
              "Background services did not flush the bound reading page while retaining durable failed A1.")

        // Keep the first MainActor drain pending while real Store IO receives A2.
        // Its completion and the background task are separate service boundaries.
        // A1 is already durable; A2 durability is asserted only after draining.
        // Injected expiration does not prove A2 was journaled before OS expiry.
        let latest = try required(first.annotations.first { $0.kind == .note }.flatMap { first.freeTextEditDraft(for: $0) })
        values = latest.values; values.text = latestText
        check(first.saveFreeText(latest, values: values), "Background recovery refused the newest standard A2 edit.")
        first.recordCurrentPage(3); binding.recordPage(3, in: document)
        let secondRequest = research.beginRequest(sessionID: session, question: "Latest foreground request", sourceSnapshot: [])
        services.saveForBackground()
        check(secondRequest != nil && research.session(id: session)?.activeRequestID == nil
                && expirations.count == 1 && endedTasks.isEmpty
                && (try? persistence.load())?.files.first(where: { $0.id == file.id })?.lastPageIndex == 3,
              "A pending PDF drain skipped the newer reading page/Research interruption or duplicated its background window.")
        let firstExpiration = try required(expirations.first)
        firstExpiration()
        check(endedTasks == [firstTask], "Expiration did not end exactly the pending PDF's first task.")
        services.saveForBackground()
        check(expirations.count == 2 && endedTasks == [firstTask],
              "A new event with pending PDF data did not reopen the expired save window.")
        firstExpiration()
        check(endedTasks == [firstTask], "The old PDF-drain expiration ended its replacement window.")
        let secondExpiration = try required(expirations.dropFirst().first)
        secondExpiration()
        await services.waitForBackgroundSave()
        await waitForStoreSaveCompletion(first, failed: true)
        let latestPending = try required(queue.pendingData(for: copy))
        let durableLatestNotes = try standardNotes(in: latestPending)
        let failedJournals = try manager.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil)
        check(endedTasks == [firstTask, secondTask] && expirations.count == 2,
              "PDF drain completion double-ended an expired task or acquired an extra window.")
        check(durableLatestNotes == latestNotes && latestPending != earlierPending
                && first.hasUnsavedChanges && first.workingCopySaveError != nil
                && !queue.hasUnrecoverablePendingWrites && queue.pendingDestinations.count == 1
                && failingManager.blockedDirectoryPaths.count == 2
                && failedJournals.filter { $0.pathExtension == "json" }.count == 1,
              "Expired/repeated background callbacks did not retain latest standard A2 after drain: notes \(durableLatestNotes), blocked \(failingManager.blockedDirectoryPaths), journals \(failedJournals.map(\.lastPathComponent)), pending \(queue.pendingDestinations.map(\.path)), error \(first.workingCopySaveError ?? "nil").")
        check(try Data(contentsOf: copy) == committedA0 && Data(contentsOf: original) == originalBytes,
              "Failed background writes changed committed A0 or original PDF bytes.")
        let savedState = try required(try persistence.load())
        let savedFile = try required(savedState.files.first(where: { $0.id == file.id }))
        let reloadedResearch = ResearchStore(rootURL: research.rootURL)
        check(savedFile.lastPageIndex == 3 && savedFile.workingCopyURL?.libraryComparablePath == copy.libraryComparablePath
                && reloadedResearch.session(id: session)?.draft.text == draftText
                && reloadedResearch.session(id: session)?.activeRequestID == nil,
              "The PDF failure/expiration boundary lost the bound copy, latest page or Research draft on reload.")

        binding.suspendUpdates(); first.releaseEditorAccess()
        let restoredQueue = PDFSaveQueue(fileManager: failingManager, recoveryDirectoryURL: journal, workingCopyStore: copies)
        let restoredAccess = DocumentAccessCoordinator(saveQueue: restoredQueue)
        let restoredLibrary = LibraryStore(userDefaults: defaults, storage: persistence, workingCopyStore: copies)
        let restoredFile = try required(restoredLibrary.allFiles.first(where: { $0.id == file.id }))
        let openingCopy = try required(restoredLibrary.openingWorkingCopyURL(for: restoredFile))
        let restored = makeStore(queue: restoredQueue, access: restoredAccess)
        defer { restored.releaseEditorAccess() }
        check(restoredQueue.pendingData(for: openingCopy) == latestPending && !restoredQueue.hasUnrecoverablePendingWrites,
              "Fresh queue reconstruction after simulated expiration lost durable latest A2.")
        check(restored.openPDF(from: original, workingCopyURL: openingCopy, initialPageIndex: restoredFile.lastPageIndex)
                && restored.bindLibraryFile(restoredFile.id) && restored.document !== document
                && restored.document.map { standardNotes(in: $0) == latestNotes } == true
                && restored.hasUnsavedChanges && restored.workingCopySaveError != nil
                && restored.currentPageIndex == 3 && restored.currentWorkingCopyURL?.libraryComparablePath == copy.libraryComparablePath,
              "Fresh Store/Access reconstruction opened A0/original or lost A2's failure, bound copy or saved page.")
        let restoredBinding = IPadWorkingCopyLibraryBinding(store: restored, library: restoredLibrary)
        restoredBinding.bind(fileID: restoredFile.id)
        failingManager.blocksWrites = false
        restored.retryWorkingCopySave()
        await restoredQueue.drain()
        await waitForStoreSaveCompletion(restored, failed: false)
        let journalsAfterRetry = try manager.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil)
        let committedLatestNotes = try standardNotes(in: Data(contentsOf: copy))
        check(committedLatestNotes == latestNotes && !restored.hasUnsavedChanges
                && restored.workingCopySaveError == nil && restored.currentPageIndex == 3,
              "Actual recovered Store Retry failed to commit newest standard A2 or clear save failure without changing page: notes \(committedLatestNotes), dirty \(restored.hasUnsavedChanges), error \(restored.workingCopySaveError ?? "nil"), page \(restored.currentPageIndex).")
        check(journalsAfterRetry.isEmpty && restoredQueue.pendingDestinations.isEmpty && restoredLibrary.flushPendingPersistence(),
              "Recovered Store Retry retained a recovery journal or failed to flush its bound Library copy.")
        restoredBinding.suspendUpdates(); restored.releaseEditorAccess()
        let finalQueue = PDFSaveQueue(recoveryDirectoryURL: journal, workingCopyStore: copies)
        let finalLibrary = LibraryStore(userDefaults: defaults, storage: persistence, workingCopyStore: copies)
        let finalFile = try required(finalLibrary.allFiles.first(where: { $0.id == file.id }))
        let finalCopy = try required(finalLibrary.openingWorkingCopyURL(for: finalFile))
        let final = makeStore(queue: finalQueue, access: DocumentAccessCoordinator(saveQueue: finalQueue))
        defer { final.releaseEditorAccess() }
        check(finalQueue.pendingDestinations.isEmpty
                && final.openPDF(from: original, workingCopyURL: finalCopy, initialPageIndex: finalFile.lastPageIndex)
                && final.bindLibraryFile(finalFile.id) && final.document !== restored.document
                && final.document.map { standardNotes(in: $0) == latestNotes } == true
                && !final.hasUnsavedChanges && final.workingCopySaveError == nil && final.currentPageIndex == 3
                && finalCopy.libraryComparablePath == copy.libraryComparablePath,
              "A second reconstructed queue/Store resurrected failed edits or lost committed A2, file identity, copy or reading page.")
        check(try Data(contentsOf: original) == originalBytes,
              "Background failure, service reconstruction or recovered Retry modified the original PDF.")
    }

    /// Calls real Session lifecycle methods. Native scene-disconnect delivery
    /// and third-party Files authorization remain separate OS acceptance.
    private static func exerciseWorkspaceLifecycle(root: URL, defaults: UserDefaults,
                                                    check: (Bool, String) -> Void) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let originalBytes = fixtureData()
        let urls = ["A", "B", "C"].map { root.appendingPathComponent("\($0).pdf") }
        for url in urls { try originalBytes.write(to: url) }
        let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
        let fault = RecoveryDirectoryFailingFileManager(directoryURL: copies.directoryURL)
        let journal = root.appendingPathComponent("journal")
        let queue = PDFSaveQueue(fileManager: fault, recoveryDirectoryURL: journal, workingCopyStore: copies)
        let access = DocumentAccessCoordinator(saveQueue: queue)
        let storage = try LibraryJSONStore(stateURL: root.appendingPathComponent("library.json"))
        let library = LibraryStore(userDefaults: defaults, storage: storage,
            readingPositionSaveDelay: 3_600, workingCopyStore: copies)
        let files = library.upsertOpenedURLs(urls, refreshBookmark: false)
        guard files.count == 3 else { throw FixtureError.missingValue }
        let groupA = try required(library.createGroup(named: "Scene Group A"))
        let groupB = try required(library.createGroup(named: "Scene Group B"))
        library.addFile(files[0], to: groupA); library.addFile(files[1], to: groupB)
        let research = ResearchStore(rootURL: root.appendingPathComponent("research"))
        let commands = ResearchCommandService(store: research)
        let configuration = AIConfigurationStore(configurationURL: root.appendingPathComponent("ai.json"),
            legacyUserDefaults: defaults, secretStore: EmptySecrets())
        let trace = AIHighlightTraceRecorder(fileURL: root.appendingPathComponent("trace.jsonl"), defaults: defaults)
        let runtime = ResearchRuntime(storage: research, configuration: configuration,
            service: AIHighlightWorkflowService(traceRecorder: trace), traceRecorder: trace,
            commands: commands, retrievalSelection: .lexical)
        let services = IPadApplicationServices(library: library, research: research,
            configuration: configuration, language: AppLanguageStore(userDefaults: defaults),
            commands: commands, runtime: runtime, saveQueue: queue, observesApplication: false,
            beginBackgroundTask: { _ in .invalid }, endBackgroundTask: { _ in })
        let draftDirectory = root.appendingPathComponent("drafts")
        let factory: @MainActor (UUID, UUID, DocumentAccessCoordinator) -> IPadGroupWorkspace = { id, groupID, coordinator in
            let feedback = OperationFeedbackCenter(userDefaults: defaults)
            let directory = root.appendingPathComponent(id.uuidString)
            let store = PDFDocumentStore(feedbackCenter: feedback,
                metadataStore: DocumentMetadataStore(stateURL: directory.appendingPathComponent("metadata.json")),
                aiHighlightGroupStore: AIHighlightGroupStore(stateURL: directory.appendingPathComponent("groups.json")),
                workingCopyStore: copies, saveQueue: queue, accessCoordinator: coordinator,
                exportPresenter: IPadDocumentExportPresenter())
            let workspace = IPadGroupWorkspace(id: id, groupID: groupID, documentStore: store,
                feedbackCenter: feedback, accessCoordinator: coordinator, noteDraftDirectoryURL: draftDirectory)
            workspace.state.undoManager.groupsByEvent = false
            return workspace
        }
        let first = IPadWorkspaceSession(id: UUID(), services: services, userDefaults: defaults,
            accessCoordinator: access, workspaceFactory: factory)
        let second = IPadWorkspaceSession(id: UUID(), services: services, userDefaults: defaults,
            accessCoordinator: access, workspaceFactory: factory)
        defer { first.close(); second.close() }
        var firstActivations = 0, secondActivations = 0
        first.activateScene = { firstActivations += 1 }
        second.activateScene = { secondActivations += 1 }
        check(first.open(files[0], in: groupA.id), "The first actual Session could not open Group A's PDF.")
        let firstA = first.workspace, documentA = try required(first.workspace.document.document)
        let noteA = try required(firstA.document.newFreeTextDraft())
        var valuesA = noteA.values; valuesA.text = "Scene A retained standard note"
        firstA.state.undoManager.beginUndoGrouping()
        let savedA = firstA.document.saveFreeText(noteA, values: valuesA)
        firstA.state.undoManager.endUndoGrouping()
        await queue.drain(); await waitForStoreSaveCompletion(firstA.document, failed: false)
        check(savedA && firstA.document.canUndoDocumentChange && access.owns(firstA.document, url: urls[0]),
            "The first Session did not establish its unique owner and native document Undo.")
        check(!second.open(files[0], in: groupA.id) && firstActivations == 1
            && second.workspace.document.document == nil && firstA.document.document === documentA,
            "A second Session opened a duplicate writer instead of activating the original Session.")
        let secondA = second.workspace
        check(second.open(files[1], in: groupB.id), "The second Session could not open its independent Group B PDF.")
        let secondB = second.workspace, documentB = try required(second.workspace.document.document)
        let noteB = try required(secondB.document.newFreeTextDraft())
        var valuesB = noteB.values; valuesB.text = "Scene B committed note"
        secondB.state.undoManager.beginUndoGrouping()
        let savedB = secondB.document.saveFreeText(noteB, values: valuesB)
        secondB.state.undoManager.endUndoGrouping()
        await queue.drain(); await waitForStoreSaveCompletion(secondB.document, failed: false)
        check(savedB && documentA !== documentB && secondB.document.canUndoDocumentChange
            && access.owns(secondB.document, url: urls[1]), "Independent Session B lost its document or Undo owner.")
        check(!first.open(files[1], in: groupB.id) && secondActivations == 1,
            "Opening another retained Session's PDF did not activate its existing editing owner.")
        check(first.selectGroup(groupA.id) && first.workspace === firstA
            && firstA.document.document === documentA && firstA.document.canUndoDocumentChange,
            "Returning to a retained Group replaced its native PDF or Undo history.")
        firstA.document.recordCurrentPage(1); firstA.libraryBinding?.recordPage(1, in: documentA)
        firstA.libraryBinding?.recordZoom(percent: 125, isFit: false, in: documentA)
        check(first.prepareForPresentationTransition(), "A clean Session could not checkpoint its retained reading state.")
        firstA.export.export(DocumentExportRequest(data: originalBytes, suggestedName: "Scene A export.pdf",
            contentType: .pdf, protectedOriginalURL: urls[0])) { _ in }
        let exportTicket = try required(firstA.export.ticket)
        check(!first.prepareForPresentationTransition() && firstA.export.ticket?.id == exportTicket.id
            && firstA.state.isActive && firstA.document.document === documentA,
            "A tab transition hid or dismissed the actual pending native export ticket.")
        firstA.export.finish(exportTicket.id, result: .success(nil))
        let options = DocumentExportOptionsRequest(title: "Export options", message: "Choose pages",
            confirmTitle: "Export", allowsMultipleSelection: true, options: []) { _ in }
        firstA.document.pendingExportOptions = options
        check(!first.prepareForPresentationTransition() && firstA.document.pendingExportOptions?.id == options.id,
            "A tab transition bypassed the shared pending PDF export-options request.")
        firstA.document.pendingExportOptions = nil
        firstA.document.requestConfirmation(title: "Delete page?", message: "Review the pending operation",
            confirmTitle: "Delete", action: "Session transition fixture") { _ in }
        let confirmation = try required(firstA.document.pendingConfirmation)
        check(!first.prepareForPresentationTransition()
            && firstA.document.pendingConfirmation?.id == confirmation.id,
            "A tab transition hid or consumed the captured destructive-operation confirmation.")
        firstA.document.pendingConfirmation = nil
        var stalePreparations = 0, currentPreparations = 0
        let staleToken = firstA.registerResearchPresentationPreparation { stalePreparations += 1; return true }
        let currentToken = firstA.registerResearchPresentationPreparation { currentPreparations += 1; return false }
        firstA.unregisterResearchPresentationPreparation(staleToken)
        check(!first.prepareForPresentationTransition() && currentPreparations == 1 && stalePreparations == 0,
            "An old Research host unregistered the newer preparation or a rejected composer boundary allowed tab transition.")
        firstA.unregisterResearchPresentationPreparation(currentToken)
        check(first.prepareForPresentationTransition() && currentPreparations == 1,
            "Unregistering the current Research host did not release its exact preparation capability.")
        first.setPresented(false)
        check(!firstA.state.isActive && firstA.document.document === documentA
            && firstA.document.canUndoDocumentChange && access.owns(firstA.document, url: urls[0]),
            "Hiding a Session released its writer, PDF or document Undo.")
        check(first.selectGroup(groupA.id) && !firstA.state.isActive,
            "A retained Group selection reactivated a hidden Session before presentation.")
        first.setPresented(true)
        check(firstA.state.isActive && firstA.document.currentPageIndex == 1
            && firstA.document.document === documentA, "Presenting the Session failed to restore its retained reading state.")
        let savedAFile = try required(try storage.load()?.files.first(where: { $0.id == files[0].id }))
        check(savedAFile.lastPageIndex == 1 && savedAFile.lastZoomState?.mode == .custom
            && savedAFile.lastZoomState?.scaleFactor == 1.25,
            "Tab presentation preparation did not durably flush page and pending native zoom.")
        check(library.deleteGroup(groupA), "The actual Library refused Group A deletion.")
        for _ in 0..<50 {
            if firstA.state.isClosed && secondA.state.isClosed { break }
            await deliverCompletions()
        }
        check(firstA.state.isClosed && secondA.state.isClosed && firstA.libraryBinding == nil
            && secondA.libraryBinding == nil && first.groupID == LibraryGroup.ungroupedID,
            "Group deletion did not close every Session's unreachable cached workspace and reveal Ungrouped.")
        check(!access.owns(firstA.document, url: urls[0]) && firstA.document.document === documentA
            && second.workspace === secondB && secondB.state.isActive && !secondB.state.isClosed
            && secondB.document.document === documentB && secondB.document.canUndoDocumentChange,
            "Deleted Group teardown retained its owner or damaged the other Session's active document/Undo.")
        let firstKey = "Dogear.iPad.Workspace.\(first.id.uuidString).\(groupA.id.uuidString)"
        let secondKey = "Dogear.iPad.Workspace.\(second.id.uuidString).\(groupA.id.uuidString)"
        check(defaults.string(forKey: firstKey) == nil && defaults.string(forKey: secondKey) == nil
            && library.allFiles.contains(where: { $0.id == files[0].id })
            && library.openSession(for: groupA.id, sessionID: first.id) == nil,
            "Group deletion lost its PDF or kept unreachable Session identity in isolated defaults/Library.")

        // A dirty, detached note must checkpoint before ordinary tab hiding.
        check(first.open(files[2], in: groupB.id), "The Session could not open an independent draft fixture.")
        let draftWorkspace = first.workspace, draftDocument = try required(first.workspace.document.document)
        let draft = try required(draftWorkspace.document.newFreeTextDraft())
        let inline = IPadInlineNoteEditingSession(draft: draft)
        draftWorkspace.inlineNoteSession = inline
        try Data("Obstruct recovery directory".utf8).write(to: draftDirectory)
        inline.values.text = "保留未提交中文草稿"
        check(!first.prepareForPresentationTransition() && draftWorkspace.noteDraftRecovery.lastError != nil
            && inline.values.text == "保留未提交中文草稿" && draft.annotation.page == nil,
            "A failed inline draft checkpoint allowed tab transition or silently committed/lost its draft.")
        try manager.removeItem(at: draftDirectory)
        check(first.prepareForPresentationTransition() && draftWorkspace.noteDraftRecovery.lastError == nil,
            "Repairing the draft directory did not permit an explicit retry of tab preparation.")
        let draftFiles = try manager.contentsOfDirectory(at: draftDirectory, includingPropertiesForKeys: nil)
        check(draftFiles.count == 1 && draftDocument.page(at: 0)?.annotations.isEmpty == true,
            "Tab preparation failed to persist exactly one detached sidecar or altered the PDF.")

        // Close a real failed writer, then recover it through a different Session.
        fault.blocksWrites = true
        let editB = try required(secondB.document.annotations.first(where: { $0.kind == .note })
            .flatMap { secondB.document.freeTextEditDraft(for: $0) })
        valuesB = editB.values; valuesB.text = "Scene B latest failed note"
        secondB.state.undoManager.beginUndoGrouping()
        let changedB = secondB.document.saveFreeText(editB, values: valuesB)
        secondB.state.undoManager.endUndoGrouping()
        secondB.document.recordCurrentPage(2); secondB.libraryBinding?.recordPage(2, in: documentB)
        await queue.drain(); await waitForStoreSaveCompletion(secondB.document, failed: true)
        let copyB = try required(secondB.document.currentWorkingCopyURL)
        check(changedB && secondB.document.hasUnsavedChanges && secondB.document.workingCopySaveError != nil
            && queue.pendingData(for: copyB) != nil && !queue.hasUnrecoverablePendingWrites,
            "The Session close fixture did not establish an actual durable failed PDF write.")
        second.close(); second.close()
        check(!second.acceptsUserActions && secondB.state.isClosed && !access.owns(secondB.document, url: urls[1])
            && access.retainedEntry(for: urls[1])?.dirty == true,
            "Idempotent Session close discarded a failed writer or kept its editing lease.")
        check(!second.selectGroup(groupB.id) && !second.open(files[1], in: groupB.id)
            && (try? storage.load())?.files.first(where: { $0.id == files[1].id })?.lastPageIndex == 2,
            "A closed Session reacquired a writer or failed to flush its latest page.")
        let replacement = IPadWorkspaceSession(id: UUID(), services: services, userDefaults: defaults,
            accessCoordinator: access, workspaceFactory: factory)
        defer { replacement.close() }
        let latestB = try required(library.allFiles.first(where: { $0.id == files[1].id }))
        check(replacement.open(latestB, in: groupB.id)
            && replacement.workspace.document.annotations.contains(where: { $0.note == "Scene B latest failed note" })
            && replacement.workspace.document.currentPageIndex == 2
            && access.owns(replacement.workspace.document, url: urls[1]),
            "A different Session did not inherit the closed owner's latest recoverable standard note and page.")
        fault.blocksWrites = false
        replacement.workspace.document.retryWorkingCopySave()
        await queue.drain(); await waitForStoreSaveCompletion(replacement.workspace.document, failed: false)
        check(!replacement.workspace.document.hasUnsavedChanges && queue.pendingData(for: copyB) == nil,
            "The replacement Session could not retry the released owner's latest failed write.")

        // First prove that this direct-import destination really reaches the
        // Session's reader callback; folder import creates a different Group.
        let control = IPadWorkspaceSession(id: UUID(), services: services, userDefaults: defaults,
            accessCoordinator: access, workspaceFactory: factory)
        defer { control.close() }
        _ = control.selectGroup(groupB.id)
        control.importURLs([urls[0]], groupID: groupB.id)
        for _ in 0..<500 {
            if !control.importer.isRunning { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        check(!control.importer.isRunning && !control.importer.cancelled
            && control.importer.completed == 1 && control.importer.failures.isEmpty
            && control.workspace.document.document != nil
            && library.file(for: control.workspace.document.selectedPDFURL)?.id == files[0].id
            && access.owns(control.workspace.document, url: urls[0]),
            "The actual direct-import Session did not open its completed PDF in the captured Group.")
        control.close()

        // Cancellation is delivered by actual Library publication after 24
        // completed direct imports, rather than a duplicate importer algorithm.
        let folder = root.appendingPathComponent("Late scene import")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let directURLs = (0..<30).map { folder.appendingPathComponent("late-\($0).pdf") }
        for url in directURLs { try originalBytes.write(to: url) }
        let importing = IPadWorkspaceSession(id: UUID(), services: services, userDefaults: defaults,
            accessCoordinator: access, workspaceFactory: factory)
        defer { importing.close() }
        _ = importing.selectGroup(groupB.id)
        let importingWorkspace = importing.workspace
        let before = library.allFiles.count
        var closedAfterBatch = false
        let observation = library.$state.sink { state in
            MainActor.assumeIsolated {
                if !closedAfterBatch && state.files.count >= before + 24 {
                    closedAfterBatch = true; importing.close()
                }
            }
        }
        defer { observation.cancel() }
        importing.importURLs(directURLs, groupID: groupB.id)
        for _ in 0..<500 {
            if !importing.importer.isRunning { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        check(closedAfterBatch && !importing.acceptsUserActions && !importing.importer.isRunning
            && importing.importer.cancelled && importing.importer.completed == 24 && importing.importer.failures.isEmpty,
            "Closing the actual importing Session did not cancel after 24 completed PDFs: completed \(importing.importer.completed), running \(importing.importer.isRunning), errors \(importing.importer.failures).")
        check(library.allFiles.count == before + 24 && importingWorkspace.state.isClosed
            && importingWorkspace.document.document == nil && !importing.open(files[0], in: groupB.id),
            "A late import callback reopened a closed Session or removed its completed batch.")
        let persisted = try required(try storage.load())
        check(persisted.files.count == before + 24 && persisted.files.contains(where: { $0.id == files[0].id })
            && persisted.files.contains(where: { $0.id == files[1].id }),
            "Scene teardown/import cancellation lost durable original Library identities.")
        check(try urls.allSatisfy { try Data(contentsOf: $0) == originalBytes },
            "Session owner activation, Group deletion, tab preparation, close, recovery or import rewrote an original PDF.")
    }

    private static func confirmation(_ outcome: IPadDocumentExportPresenter.WriteOutcome) throws -> IPadDocumentExportPresenter.Replacement {
        guard case .replacementRequired(let value) = outcome else { throw FixtureError.unexpectedOutcome }
        return value
    }
    private static func isExpired(_ outcome: IPadDocumentExportPresenter.WriteOutcome) -> Bool {
        if case .expired = outcome { return true }; return false
    }
    private static func isCompleted(_ outcome: IPadDocumentExportPresenter.WriteOutcome) -> Bool {
        if case .completed = outcome { return true }; return false
    }
    private static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw FixtureError.missingValue }; return value
    }
    private static func deliverCompletions() async { for _ in 0..<8 { await Task.yield() } }
    private static func waitForStoreSaveCompletion(_ store: PDFDocumentStore, failed: Bool) async {
        // Queue drain covers disk IO. Give the actual MainActor completion a
        // bounded event turn rather than assuming Task.yield runs that task.
        for _ in 0..<50 {
            if failed ? (store.hasUnsavedChanges && store.workingCopySaveError != nil)
                      : (!store.hasUnsavedChanges && store.workingCopySaveError == nil) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    private static func fixtureData() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            for page in 1...4 {
                context.beginPage()
                ("Authored export and recovery fixture \(page)" as NSString).draw(at: CGPoint(x: 72, y: 72),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
    }
    private enum FixtureError: Error { case missingValue, unexpectedOutcome }
    private final class EmptySecrets: AISecretStoring {
        func readSecret(profileID: UUID) -> String? { nil }
        func saveSecret(_ secret: String, profileID: UUID, configurationName: String) {}
        func removeSecret(profileID: UUID) {}
        func updateLabel(profileID: UUID, configurationName: String) {}
    }
}

/// Fails the queue's directory step while leaving real journal persistence and
/// an already committed A0 copy intact. No Store/queue behavior is substituted.
/// Configuration is immutable; fault flags and traces are protected by failureLock.
nonisolated private final class RecoveryDirectoryFailingFileManager: FileManager {
    private let directoryURL: URL
    private let failureLock = NSLock()
    private var shouldBlock = false
    private var attemptedPaths: [String] = []
    private var blockedPaths: [String] = []

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        super.init()
    }

    var blocksWrites: Bool {
        get { failureLock.lock(); defer { failureLock.unlock() }; return shouldBlock }
        set { failureLock.lock(); shouldBlock = newValue; failureLock.unlock() }
    }
    var attemptedDirectoryPaths: [String] {
        failureLock.lock(); defer { failureLock.unlock() }; return attemptedPaths
    }
    var blockedDirectoryPaths: [String] {
        failureLock.lock(); defer { failureLock.unlock() }; return blockedPaths
    }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        if blocksWrites {
            failureLock.lock(); attemptedPaths.append(url.path); failureLock.unlock()
        }
        // Journal persistence creates the support parent before the target
        // call. Resolve that existing parent on each call, including physical
        // iOS /private/var and /var spellings and a still-missing first copy.
        let expectedParent = Self.comparablePath(for: directoryURL.deletingLastPathComponent())
        let requestedParent = Self.comparablePath(for: url.deletingLastPathComponent())
        if blocksWrites && url.lastPathComponent == directoryURL.lastPathComponent && requestedParent == expectedParent {
            failureLock.lock(); blockedPaths.append(url.path); failureLock.unlock()
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
    nonisolated private static func comparablePath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
#endif
