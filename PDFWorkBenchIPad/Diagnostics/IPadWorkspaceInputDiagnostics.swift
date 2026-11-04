#if os(iOS)
import Combine
import PDFKit
import UIKit

/// Exercises native-host reading and preview ownership with the real Store,
/// Library, save queue and evidence resolver, using authored disposable PDFs.
@MainActor
enum IPadWorkspaceInputDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0, failures: [String] = []
        func expect(_ value: Bool, _ message: String) {
            checks += 1; if !value { failures.append(message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearWorkspaceInput-\(UUID())")
        let suite = "DogearWorkspaceInput.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { return (1, ["Could not isolate workspace defaults."]) }
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let urls = ["A", "B", "C"].map { root.appendingPathComponent("\($0).pdf") }
            for (index, url) in urls.enumerated() { try fixtureData("Native document \(index)").write(to: url) }
            let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
            let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("recovery"))
            let access = DocumentAccessCoordinator(saveQueue: queue)
            let persistence = try LibraryJSONStore(stateURL: root.appendingPathComponent("library.json"))
            let library = LibraryStore(userDefaults: defaults, storage: persistence, workingCopyStore: copies)
            let files = library.upsertOpenedURLs(urls, refreshBookmark: false)
            guard files.count == 3 else { return (checks + 1, failures + ["Could not create distinct Library records."]) }
            func makeStore(_ name: String) -> PDFDocumentStore {
                PDFDocumentStore(feedbackCenter: OperationFeedbackCenter(userDefaults: defaults),
                    metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("\(name)-metadata.json")),
                    aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("\(name)-groups.json")),
                    workingCopyStore: copies, saveQueue: queue, accessCoordinator: access,
                    exportPresenter: IPadDocumentExportPresenter())
            }
            let store = makeStore("reader"), other = makeStore("other")
            defer { store.releaseEditorAccess(); other.releaseEditorAccess() }
            let workspace = IPadGroupWorkspace(id: UUID(), groupID: LibraryGroup.ungroupedID,
                documentStore: store, feedbackCenter: OperationFeedbackCenter(userDefaults: defaults))
            workspace.state.setActive(true)
            let groupUndo = workspace.state.undoManager
            groupUndo.groupsByEvent = false
            let binding = IPadWorkingCopyLibraryBinding(store: store, library: library)
            workspace.libraryBinding = binding
            expect(store.openPDF(from: urls[0]) && store.bindLibraryFile(files[0].id), "A real Store binds document A.")
            binding.bind(fileID: files[0].id)
            guard let first = store.document, let draftA = store.newFreeTextDraft() else {
                return (checks + 1, failures + ["Could not prepare native document A."])
            }
            var valuesA = draftA.values; valuesA.text = "Copy A 中文"
            let originalABytes = try Data(contentsOf: urls[0])
            groupUndo.beginUndoGrouping()
            let savedA = store.saveFreeText(draftA, values: valuesA)
            groupUndo.endUndoGrouping()
            expect(savedA, "A first edit creates a standard annotation and copy.")
            guard let copyA = store.currentWorkingCopyURL else { return (checks + 1, failures + ["Copy A was not allocated."]) }
            expect(library.allFiles.first { $0.id == files[0].id }?.workingCopyURL?.libraryComparablePath == copyA.libraryComparablePath,
                "The retained host immediately records copy A, including before asynchronous disk completion.")
            binding.recordZoom(percent: 300, isFit: false, in: first); binding.flushZoom()
            expect(library.allFiles.first { $0.id == files[0].id }?.lastZoomState == .custom(scaleFactor: 3),
                "Document A stores its own custom zoom.")
            let offset = PDFPageOffset(x: 123.5, y: 456.25)
            binding.recordPosition(page: 0, offset: offset, in: first)
            expect(library.flushPendingPersistence()
                && LibraryStore(userDefaults: defaults, storage: persistence, workingCopyStore: copies).allFiles.first { $0.id == files[0].id }?.lastPageOffset == offset,
                "Actual Library JSON round-trips the existing page-offset field without a schema migration.")
            binding.suspendUpdates(); binding.recordPosition(page: 0, offset: .init(x: 9, y: 9), in: first); binding.resumeUpdates()
            expect(library.allFiles.first { $0.id == files[0].id }?.lastPageOffset == offset,
                "Suspended document installation cannot overwrite the saved viewport.")

            // Match the native host's suspended binding while a new target is
            // decoded. A failed open never binds that target or redirects A.
            await queue.drain(); await settle()
            expect(PDFDocument(url: copyA)?.page(at: 0)?.annotations.contains {
                $0.type == "FreeText" && $0.contents == valuesA.text
            } == true, "Copy A contains its first real standard note before the rejected open.")
            let invalidURL = root.appendingPathComponent("Invalid.pdf")
            let invalidBytes = Data("Authored fixture: these bytes are not a PDF.".utf8)
            try invalidBytes.write(to: invalidURL)
            guard let invalidFile = library.upsertOpenedURLs([invalidURL], refreshBookmark: false).first else {
                return (checks + 1, failures + ["Could not create the invalid target's isolated Library record."])
            }
            let rejectedOpen = { () -> Bool in
                binding.suspendUpdates()
                defer { binding.resumeUpdates() }
                return store.openPDF(from: invalidURL, workingCopyURL: library.openingWorkingCopyURL(for: invalidFile))
            }()
            expect(!rejectedOpen, "An existing file containing non-PDF bytes fails a real native Store open.")
            expect(store.document === first && store.selectedPDFURL == urls[0] && store.currentWorkingCopyURL == copyA,
                "Rejected native open preserves A's exact document, original URL and working-copy URL.")
            let retainedA = access.retainedEntry(for: urls[0])
            expect(store.canEditDocument && access.owns(store, url: urls[0]) && retainedA?.owner === store
                && retainedA?.document === first && retainedA?.workingCopyURL == copyA && retainedA?.fileID == files[0].id,
                "Rejected native open preserves the exact A editing owner and stable Library identity.")
            expect(binding.owns(fileID: files[0].id) && !binding.owns(fileID: invalidFile.id),
                "A failed open leaves the host binding on A rather than binding the invalid target.")
            expect(store.canUndoDocumentChange && groupUndo.canUndo && groupUndo.groupingLevel == 0,
                "Rejected native open retains A's explicitly grouped document Undo action.")
            store.undoDocumentChange()
            expect(draftA.annotation.page == nil && first.page(at: 0)?.annotations.isEmpty == true && store.canRedoDocumentChange,
                "The preserved pre-failure Undo removes A's exact first annotation.")
            store.redoDocumentChange()
            expect(draftA.annotation.page === first.page(at: 0)
                && first.page(at: 0)?.annotations.contains(where: { $0 === draftA.annotation }) == true,
                "The preserved pre-failure Redo restores the same standard annotation identity.")
            let invalidCopy = copies.workingCopyURL(forOriginalURL: invalidURL)
            expect(library.allFiles.first { $0.id == invalidFile.id }?.workingCopyURL == nil
                && access.retainedEntry(for: invalidURL) == nil && !FileManager.default.fileExists(atPath: invalidCopy.path),
                "The rejected target acquires neither a Library working copy nor an editing entry or copy file.")
            guard let followupDraft = store.newFreeTextDraft() else {
                return (checks + 1, failures + ["Rejected open prevented a subsequent real edit to A."])
            }
            var followupValues = followupDraft.values; followupValues.text = "Keep A after failed open 中文"
            groupUndo.beginUndoGrouping()
            let savedFollowup = store.saveFreeText(followupDraft, values: followupValues)
            groupUndo.endUndoGrouping()
            expect(savedFollowup && followupDraft.document === first && followupDraft.annotation.type == "FreeText"
                && followupDraft.annotation.page === first.page(at: 0),
                "Editing after a failed open creates another standard FreeText in the same document A.")
            store.undoDocumentChange()
            expect(followupDraft.annotation.page == nil && draftA.annotation.page === first.page(at: 0)
                && first.page(at: 0)?.annotations.count == 1 && groupUndo.canUndo,
                "One follow-up Undo removes only the later A note and retains its earlier grouped Undo history.")
            store.redoDocumentChange()
            expect(followupDraft.annotation.page === first.page(at: 0)
                && first.page(at: 0)?.annotations.contains(where: { $0 === followupDraft.annotation }) == true
                && draftA.annotation.page === first.page(at: 0),
                "Follow-up Redo restores that exact A note without replacing the first annotation.")
            await queue.drain(); await settle()
            expect(store.document === first && store.currentWorkingCopyURL == copyA && store.canEditDocument
                && !store.hasUnsavedChanges && store.workingCopySaveError == nil,
                "Subsequent A edits drain successfully into its retained working copy after the rejected open.")
            let persistedA = PDFDocument(url: copyA)
            let persistedANotes = (0..<(persistedA?.pageCount ?? 0)).flatMap { persistedA?.page(at: $0)?.annotations ?? [] }
            expect(persistedA?.string?.contains("Native document 0") == true
                && persistedANotes.contains { $0.type == "FreeText" && $0.contents == valuesA.text }
                && persistedANotes.contains { $0.type == "FreeText" && $0.contents == followupValues.text },
                "The actual disk copy A contains its source and both standard notes, including the post-failure edit.")
            expect(try Data(contentsOf: urls[0]) == originalABytes && Data(contentsOf: invalidURL) == invalidBytes,
                "Failed open, continued editing and Undo/Redo leave both authored source files unchanged.")
            expect(library.flushPendingPersistence(), "The failed-open fixture flushes its actual Library state before reload.")
            let failedOpenReload = LibraryStore(userDefaults: defaults,
                storage: try LibraryJSONStore(stateURL: root.appendingPathComponent("library.json")), workingCopyStore: copies)
            let reloadedA = failedOpenReload.allFiles.first { $0.id == files[0].id }
            let reloadedInvalid = failedOpenReload.allFiles.first { $0.id == invalidFile.id }
            expect(reloadedA?.url.libraryComparablePath == urls[0].libraryComparablePath
                && reloadedA?.workingCopyURL?.libraryComparablePath == copyA.libraryComparablePath,
                "Actual Library reload preserves A's original path and exact retained working-copy file.")
            expect(reloadedInvalid?.url.libraryComparablePath == invalidURL.libraryComparablePath
                && reloadedInvalid?.workingCopyURL == nil && !FileManager.default.fileExists(atPath: invalidCopy.path),
                "Library reload keeps the invalid target separate and cannot fabricate its working copy.")
            expect(reloadedA.map { failedOpenReload.openingWorkingCopyURL(for: $0)?.libraryComparablePath == copyA.libraryComparablePath } == true
                && reloadedInvalid.map { failedOpenReload.openingWorkingCopyURL(for: $0) == nil } == true,
                "Library's real reopen resolution selects copy A and no copy for the rejected target.")

            expect(other.openPDF(from: urls[1]) && other.bindLibraryFile(files[1].id), "A second real Store prepares B independently.")
            guard let draftB = other.newFreeTextDraft() else { return (checks + 1, failures + ["Could not prepare copy B."]) }
            var valuesB = draftB.values; valuesB.text = "Copy B 中文"
            expect(other.saveFreeText(draftB, values: valuesB), "Document B receives its own standard note.")
            guard let copyB = other.currentWorkingCopyURL else { return (checks + 1, failures + ["Copy B was not allocated."]) }
            library.updateWorkingCopyURL(copyB, for: files[1]); other.releaseEditorAccess()
            await queue.drain(); await settle()
            // Deliberately omit the host's extra suspend guard here: this tests
            // the binding's source identity against Store's intermediate order
            // (selected URL, copy URL, then document).
            expect(store.openPDF(from: urls[1], workingCopyURL: copyB) && store.bindLibraryFile(files[1].id),
                "An actual A-to-B open changes native Store identity.")
            binding.bind(fileID: files[1].id)
            workspace.restoreZoom(from: library.allFiles.first { $0.id == files[1].id }?.lastZoomState)
            expect(workspace.zoomIsFit && workspace.zoomPercent == 100, "A new document defaults to fit instead of inheriting A's zoom.")
            // iOS may normalize /private/var to /var after a file is written.
            // Compare exact resolved file paths, then reopen through the actual
            // stored Library URLs so serialization spelling cannot mask A/B.
            let recordedCopyA = library.allFiles.first { $0.id == files[0].id }?.workingCopyURL
            let recordedCopyB = library.allFiles.first { $0.id == files[1].id }?.workingCopyURL
            expect(recordedCopyA?.libraryComparablePath == copyA.libraryComparablePath
                && recordedCopyB?.libraryComparablePath == copyB.libraryComparablePath
                && copyA.libraryComparablePath != copyB.libraryComparablePath,
                "Intermediate B copy publication cannot redirect or clear A's copy record. A=\(recordedCopyA?.path ?? "nil"), expected=\(copyA.path); B=\(recordedCopyB?.path ?? "nil"), expected=\(copyB.path).")
            expect(recordedCopyA.flatMap { PDFDocument(url: $0) }?.string?.contains("Native document 0") == true
                && recordedCopyB.flatMap { PDFDocument(url: $0) }?.string?.contains("Native document 1") == true,
                "Distinct persisted copy records reopen their actual source contents.")
            guard let second = store.document else { return (checks + 1, failures + ["Native B did not install."]) }
            binding.recordZoom(percent: 80, isFit: false, in: second); binding.flushZoom()
            expect(store.openPDF(from: urls[0], workingCopyURL: copyA) && store.bindLibraryFile(files[0].id), "A reopens its retained copy.")
            binding.bind(fileID: files[0].id)
            workspace.restoreZoom(from: library.allFiles.first { $0.id == files[0].id }?.lastZoomState)
            expect(!workspace.zoomIsFit && workspace.zoomPercent == 300, "Returning to A restores A's own 300 percent zoom.")
            binding.recordZoom(percent: 999, isFit: false, in: second); binding.flushZoom()
            expect(library.allFiles.first { $0.id == files[0].id }?.lastZoomState == .custom(scaleFactor: 3),
                "A stale B zoom callback cannot overwrite A's reading state.")
            binding.suspendUpdates()
            expect(store.openPDF(from: urls[2]) && store.bindLibraryFile(files[2].id), "An unedited third source opens during a suspended binding.")
            binding.bind(fileID: files[2].id); binding.resumeUpdates()
            expect(store.openPDF(from: urls[1], workingCopyURL: copyB) && store.bindLibraryFile(files[1].id),
                "An unedited-to-edited switch installs B's known copy.")
            binding.bind(fileID: files[1].id)
            expect(library.allFiles.first { $0.id == files[2].id }?.workingCopyURL == nil
                && library.allFiles.first { $0.id == files[0].id }?.workingCopyURL?.libraryComparablePath == copyA.libraryComparablePath,
                "An unedited source cannot acquire B's copy and prior A stays intact.")
            binding.recordPage(1, in: store.document!); binding.flushZoom()
            _ = library.flushPendingPersistence()
            let reloaded = LibraryStore(userDefaults: defaults, storage: try LibraryJSONStore(stateURL: root.appendingPathComponent("library.json")), workingCopyStore: copies)
            expect(reloaded.allFiles.first { $0.id == files[0].id }?.lastZoomState == .custom(scaleFactor: 3)
                && reloaded.allFiles.first { $0.id == files[1].id }?.lastZoomState == .custom(scaleFactor: 0.8),
                "Independent per-file zoom survives Library reload.")
            expect(reloaded.allFiles.first { $0.id == files[1].id }?.lastPageIndex == 1,
                "Native page reporting persists by stable file identity.")
            workspace.restoreZoom(from: .fitWidth)
            expect(workspace.zoomMode == .fitWidth, "The saved fit-width preference remains distinct from native fit-page.")
            workspace.restoreZoom(from: .custom(scaleFactor: .nan))
            expect(workspace.zoomIsFit && workspace.zoomPercent == 100, "Invalid persisted zoom cannot poison native restoration.")

            binding.suspendUpdates()
            expect(store.openPDF(from: urls[2]) && store.bindLibraryFile(files[2].id), "An unedited source opens before native Locate Original.")
            binding.bind(fileID: files[2].id); binding.resumeUpdates()
            let beforeRelink = store.document
            let relocatedOriginal = root.appendingPathComponent("C-moved.pdf")
            let beforeRelinkBytes = try Data(contentsOf: urls[2])
            try beforeRelinkBytes.write(to: relocatedOriginal)
            _ = try await library.captureOriginalFingerprint(for: files[2].id)
            let plan = try await library.prepareRelink(fileID: files[2].id, to: relocatedOriginal)
            let checked = try await library.revalidateRelink(plan)
            try access.relocateOriginal(fileID: files[2].id, from: checked.originalURL, to: checked.candidateURL,
                                       updateLibrary: { _ = try library.commitRelink(checked) })
            expect(store.document === beforeRelink && store.selectedPDFURL?.libraryComparablePath == relocatedOriginal.libraryComparablePath,
                   "Locate Original retains the native document and updates the actual writer.")
            guard let relocatedDraft = store.newFreeTextDraft() else {
                return (checks + 1, failures + ["A relocated unedited source could not begin its first edit."])
            }
            var relocatedValues = relocatedDraft.values; relocatedValues.text = "First edit after Locate 中文"
            groupUndo.beginUndoGrouping()
            let firstRelocatedEdit = store.saveFreeText(relocatedDraft, values: relocatedValues)
            groupUndo.endUndoGrouping()
            let recordedRelocated = library.allFiles.first { $0.id == files[2].id }
            expect(firstRelocatedEdit && recordedRelocated?.workingCopyURL != nil
                && recordedRelocated?.workingCopyURL?.libraryComparablePath == store.currentWorkingCopyURL?.libraryComparablePath,
                   "The retained host records a first working copy after original relocation.")
            await queue.drain(); await settle()
            let relocatedDisk = recordedRelocated?.workingCopyURL.flatMap { PDFDocument(url: $0) }
            expect(relocatedDisk?.page(at: 0)?.annotations.contains { $0.contents == relocatedValues.text } == true,
                   "The first post-relink edit survives actual PDF serialization.")
            let afterRelinkBytes = try Data(contentsOf: relocatedOriginal)
            expect(afterRelinkBytes == beforeRelinkBytes, "Editing the reconnected source preserves its original bytes.")

            // Two actual Stores share stable identity despite a moved original.
            store.releaseEditorAccess()
            expect(store.openPDF(from: urls[0], workingCopyURL: copyA) && store.bindLibraryFile(files[0].id), "The first scene owns A at its original path.")
            expect(other.openPDF(from: urls[1], workingCopyURL: copyB) && other.bindLibraryFile(files[1].id), "The second scene retains another document.")
            var activations = 0; store.setEditorActivationHandler { activations += 1 }
            let secondSceneDocument = other.document
            let secondSceneUndo = UndoManager(); secondSceneUndo.groupsByEvent = false; other.setUndoManager(secondSceneUndo)
            guard let otherDraft = other.newFreeTextDraft() else { return (checks + 1, failures + ["Could not establish second-scene Undo."]) }
            var otherValues = otherDraft.values; otherValues.text = "Keep scene B"
            secondSceneUndo.beginUndoGrouping(); _ = other.saveFreeText(otherDraft, values: otherValues); secondSceneUndo.endUndoGrouping()
            let moved = root.appendingPathComponent("moved-A.pdf")
            try FileManager.default.moveItem(at: urls[0], to: moved)
            expect(!access.activateExistingEditor(for: moved, excluding: other), "A moved original no longer matches a path-only owner lookup.")
            expect(access.activateExistingEditor(fileID: files[0].id, excluding: other) && activations == 1,
                "Stable file identity activates the already-open writer before another Store opens.")
            expect(other.document === secondSceneDocument && other.canUndoDocumentChange,
                "Stable-owner refusal preserves the second scene's exact document and Undo history.")
            await queue.drain(); await settle()

            let detached = PDFDocument(data: fixtureData("Resolved evidence"))!
            let sourceID = UUID(), version = DocumentAccessCoordinator.contentVersion(of: detached)
            let evidence = ResearchEvidence(source: .init(fileID: sourceID, displayName: "Evidence", fingerprint: version),
                kind: .pdfText, anchor: .init(pageIndex: 0), excerpt: "Resolved evidence")
            let read = PDFSourceReadSnapshot(fileID: sourceID, originalURL: root.appendingPathComponent("evidence.pdf"), contentVersion: version, document: detached)
            let resolved = try await ResearchEvidenceResolver.resolve(evidence, read: read)
            workspace.state.setActive(true); workspace.showsResearch = true
            var errors: [String] = []
            let oldGate = PreviewGate()
            workspace.beginEvidencePreview(resolve: { await oldGate.wait(); return resolved }, title: "Old", onError: { errors.append($0) })
            await settle(); workspace.showsResearch = false; oldGate.resume(); await settle()
            expect(workspace.reference == nil && errors.isEmpty, "Reader takeover revokes a delayed actual resolved preview.")
            workspace.showsResearch = true
            let firstGate = PreviewGate(), newestGate = PreviewGate()
            workspace.beginEvidencePreview(resolve: { await firstGate.wait(); return resolved }, title: "Earlier", onError: { errors.append($0) })
            await settle()
            workspace.beginEvidencePreview(resolve: { await newestGate.wait(); return resolved }, title: "Newest", onError: { errors.append($0) })
            await settle(); newestGate.resume(); await settle(); firstGate.resume(); await settle()
            expect(workspace.reference?.title == "Newest" && workspace.reference?.document === detached,
                "A later evidence click owns presentation even when an older resolved task finishes last.")
            let inactiveGate = PreviewGate()
            workspace.beginEvidencePreview(resolve: { await inactiveGate.wait(); throw DocumentAccessError.snapshotUnavailable }, title: "Inactive", onError: { errors.append($0) })
            await settle(); workspace.cancelEvidencePreview(); workspace.state.setActive(false); inactiveGate.resume(); await settle()
            expect(workspace.reference == nil && errors.isEmpty, "Group deactivation refuses stale preview errors and results.")
            workspace.state.setActive(true)
            let closeGate = PreviewGate()
            workspace.beginEvidencePreview(resolve: { await closeGate.wait(); return resolved }, title: "Closed", onError: { errors.append($0) })
            await settle(); workspace.cancelEvidencePreview(); _ = workspace.state.finishClosing(); closeGate.resume(); await settle()
            expect(workspace.reference == nil && errors.isEmpty, "Scene close leaves no late evidence presentation capability.")
            workspace.beginEvidencePreview(resolve: { return resolved }, title: "Closed retry", onError: { errors.append($0) })
            await settle()
            expect(workspace.reference == nil, "A closed workspace cannot start a new evidence preview.")
        } catch { expect(false, "Workspace input fixture failed: \(error.localizedDescription)") }
        let clampedOpen = await verifyClampedSessionOpen()
        checks += clampedOpen.checks; failures.append(contentsOf: clampedOpen.failures)
        let exclusiveRecovery = await verifyExclusiveDraftRecovery()
        checks += exclusiveRecovery.checks; failures.append(contentsOf: exclusiveRecovery.failures)
        return (checks, failures)
    }

    private static func verifyExclusiveDraftRecovery() async -> (checks: Int, failures: [String]) {
        var checks = 0, failures: [String] = []
        for noteFirst in [true, false] {
            let order = noteFirst ? "note first" : "highlight first"
            func expect(_ value: Bool, _ message: String) {
                checks += 1; if !value { failures.append("Exclusive draft recovery (\(order)): " + message) }
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearExclusiveDrafts-\(UUID())")
            let suite = "DogearExclusiveDrafts.\(UUID())"
            guard let defaults = UserDefaults(suiteName: suite) else {
                expect(false, "Could not isolate defaults."); continue
            }
            defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let originalURL = root.appendingPathComponent("Original.pdf")
                let marker = "Cross-kind recovery"
                let authored = try requireDraftFixture(PDFDocument(data: fixtureData(marker)))
                let selection = try requireDraftFixture(authored.findString(marker, withOptions: []).first)
                let prepared = try requireDraftFixture(PDFTextSelectionService.prepareHighlights(from: selection, in: authored).first)
                let baselineComment = "Original highlight"
                prepared.annotation.contents = baselineComment
                prepared.annotation.setValue("exclusive-highlight", forAnnotationKey: .name)
                prepared.page.addAnnotation(prepared.annotation) // Author the original fixture before Store ownership.
                let originalBytes = try requireDraftFixture(authored.dataRepresentation())
                try originalBytes.write(to: originalURL)
                let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
                let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("journal"), workingCopyStore: copies)
                let library = LibraryStore(userDefaults: defaults,
                    storage: try LibraryJSONStore(stateURL: root.appendingPathComponent("library.json")), workingCopyStore: copies)
                let file = try requireDraftFixture(library.upsertOpenedURLs([originalURL], refreshBookmark: false).first)
                let workspaceID = UUID(), noteDirectory = root.appendingPathComponent("notes")
                let highlightDirectory = root.appendingPathComponent("highlights")
                func makeWorkspace(_ name: String) -> IPadGroupWorkspace {
                    let feedback = OperationFeedbackCenter(userDefaults: defaults)
                    let store = PDFDocumentStore(feedbackCenter: feedback,
                        metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("\(name)-metadata.json")),
                        aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("\(name)-groups.json")),
                        workingCopyStore: copies, saveQueue: queue,
                        accessCoordinator: DocumentAccessCoordinator(saveQueue: queue), exportPresenter: IPadDocumentExportPresenter())
                    return IPadGroupWorkspace(id: workspaceID, groupID: LibraryGroup.ungroupedID,
                        documentStore: store, feedbackCenter: feedback, noteDraftDirectoryURL: noteDirectory,
                        highlightDraftDirectoryURL: highlightDirectory)
                }
                let producer = makeWorkspace("producer")
                defer { producer.document.releaseEditorAccess() }
                expect(producer.document.openPDF(from: originalURL) && producer.document.bindLibraryFile(file.id),
                    "The producer opens an actual authored PDF and binds its Library identity.")
                let producerDocument = try requireDraftFixture(producer.document.document)
                producer.noteDraftRecovery.bind(fileID: file.id); producer.highlightDraftRecovery.bind(fileID: file.id)
                let noteDraft = try requireDraftFixture(producer.document.newFreeTextDraft(page: producerDocument.page(at: 1)))
                let note = IPadInlineNoteEditingSession(draft: noteDraft)
                producer.inlineNoteSession = note; note.values.text = "Recovered note 中文"
                expect(producer.flushInlineNote(), "The real note recovery service checkpoints detached edited values.")
                // Simulate an unmounted editor, preserving its unfinished sidecar.
                producer.inlineNoteSession = nil
                let producerHighlight = try requireDraftFixture(producerDocument.page(at: 0)?.annotations.first { $0.type == "Highlight" })
                let highlight = IPadHighlightEditingSession(draft: .init(document: producerDocument,
                    annotation: producerHighlight, quote: marker, color: producerHighlight.color, comment: baselineComment))
                producer.highlightEditingSession = highlight; highlight.values.comment = "Recovered highlight 中文"
                expect(producer.flushHighlight(), "The real highlight recovery service checkpoints the second kind independently.")
                producer.highlightEditingSession = nil
                let filename = "\(workspaceID.uuidString)-\(file.id.uuidString).json"
                let noteURL = noteDirectory.appendingPathComponent(filename), highlightURL = highlightDirectory.appendingPathComponent(filename)
                let noteBytes = try Data(contentsOf: noteURL), highlightBytes = try Data(contentsOf: highlightURL)
                let noteRecord = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: noteBytes)
                let highlightRecord = try JSONDecoder().decode(IPadHighlightDraftRecovery.Record.self, from: highlightBytes)
                expect(noteRecord.draftID == note.id && highlightRecord.draftID == highlight.id
                    && noteRecord.values.text == note.values.text && highlightRecord.values.comment == highlight.values.comment
                    && !noteRecord.completed && !highlightRecord.completed && !noteRecord.pendingSave && !highlightRecord.pendingSave,
                    "Both genuine JSON sidecars retain distinct draft UUIDs and complete unfinished text.")
                let bytesAfterDrafts = try Data(contentsOf: originalURL)
                expect(!producer.document.hasUnsavedChanges && producer.document.currentWorkingCopyURL == nil
                    && bytesAfterDrafts == originalBytes,
                    "Producing both recovery records never edits the PDF or allocates a working copy.")
                producer.document.releaseEditorAccess()

                let workspace = makeWorkspace("cold")
                let store = workspace.document
                defer { store.releaseEditorAccess() }
                workspace.state.setActive(true); workspace.state.undoManager.groupsByEvent = false
                expect(store.openPDF(from: originalURL) && store.bindLibraryFile(file.id),
                    "A fresh workspace acquires a new actual Store/document for cold recovery.")
                let document = try requireDraftFixture(store.document)
                let page = try requireDraftFixture(document.page(at: 0))
                let nativeHighlight = try requireDraftFixture(page.annotations.first { $0.type == "Highlight" })
                let highlightBounds = nativeHighlight.bounds, highlightPoints = nativeHighlight.quadrilateralPoints
                workspace.noteDraftRecovery.bind(fileID: file.id); workspace.highlightDraftRecovery.bind(fileID: file.id)
                expect(document !== producerDocument && !workspace.noteDraftRecovery.hasUnresolvedRecord
                    && !workspace.highlightDraftRecovery.hasUnresolvedRecord,
                    "Cold bind starts without borrowing the producer's document or already-loaded record state.")
                if noteFirst { workspace.restoreInlineNoteIfNeeded() } else { workspace.restoreHighlightIfNeeded() }
                let firstNote = workspace.inlineNoteSession, firstHighlight = workspace.highlightEditingSession
                expect(noteFirst ? (firstNote?.id == note.id && firstNote?.values.text == note.values.text && firstHighlight == nil)
                    : (firstHighlight?.id == highlight.id && firstHighlight?.values.comment == highlight.values.comment && firstNote == nil),
                    "The first restore recreates exactly one live editor with its original draft and text.")
                if noteFirst { workspace.restoreHighlightIfNeeded() } else { workspace.restoreInlineNoteIfNeeded() }
                func deferredIsVisible() -> Bool {
                    // These are the actual DocumentWorkspace notice / Retry visibility conditions.
                    noteFirst ? (workspace.highlightDraftRecovery.hasUnresolvedRecord && workspace.highlightDraftRecovery.lastError != nil)
                        : (workspace.noteDraftRecovery.hasUnresolvedRecord && workspace.noteDraftRecovery.lastError != nil)
                }
                expect(deferredIsVisible() && (noteFirst ? workspace.highlightEditingSession == nil : workspace.inlineNoteSession == nil),
                    "The second kind stays pending with the existing recovery notice and explicit Retry visible.")
                let deferredURL = noteFirst ? highlightURL : noteURL
                let deferredBytes = noteFirst ? highlightBytes : noteBytes
                let bytesAfterDeferral = try Data(contentsOf: deferredURL)
                expect(bytesAfterDeferral == deferredBytes && store.currentWorkingCopyURL == nil
                    && nativeHighlight.contents == baselineComment && document.page(at: 1)?.annotations.isEmpty == true,
                    "Deferral is byte-preserving and does not mutate either native annotation page.")
                let firstNavigation = workspace.navigation?.id
                if noteFirst { workspace.restoreHighlightIfNeeded() } else { workspace.restoreInlineNoteIfNeeded() }
                expect(workspace.inlineNoteSession === firstNote && workspace.highlightEditingSession === firstHighlight
                    && workspace.navigation?.id == firstNavigation && deferredIsVisible(),
                    "Retry while the other editor is unfinished neither installs another editor nor changes navigation.")
                func canCommitNote(_ session: IPadInlineNoteEditingSession) -> Bool {
                    workspace.inlineNoteSession === session && !session.isFinished && workspace.state.isActive
                        && !workspace.state.isClosed && store.document === session.draft.document && store.canEditDocument
                        && workspace.highlightEditingSession == nil
                }
                func canCommitHighlight(_ session: IPadHighlightEditingSession) -> Bool {
                    workspace.highlightEditingSession === session && !session.isFinished && workspace.state.isActive
                        && !workspace.state.isClosed && store.document === session.draft.document && store.canEditDocument
                        && workspace.inlineNoteSession == nil
                }
                expect(noteFirst ? firstNote.map(canCommitNote) == true : firstHighlight.map(canCommitHighlight) == true,
                    "The existing Reader cross-kind commit guard is satisfiable for the first editor.")
                workspace.state.undoManager.beginUndoGrouping()
                let firstSaved: Bool
                if let firstNote { firstSaved = firstNote.save(in: store, canCommit: { canCommitNote(firstNote) }) }
                else if let firstHighlight { firstSaved = firstHighlight.save(in: store, canCommit: { canCommitHighlight(firstHighlight) }) }
                else { firstSaved = false }
                workspace.state.undoManager.endUndoGrouping()
                expect(firstSaved && store.canUndoDocumentChange,
                    "The first editor saves through its real recovery intent and Store with one independent Undo group.")
                // Match Reader's onFinish callback after a successful Save.
                if noteFirst { workspace.inlineNoteSession = nil } else { workspace.highlightEditingSession = nil }
                await queue.drain(); await settle()
                expect(workspace.inlineNoteSession == nil && workspace.highlightEditingSession == nil && deferredIsVisible()
                    && workspace.state.isActive && !workspace.state.isClosed && store.document === document,
                    "After the first editor finishes, the actual notice Retry remains reachable in the same active workspace.")
                let bytesAfterFirstSave = try Data(contentsOf: deferredURL)
                expect(bytesAfterFirstSave == deferredBytes,
                    "Durably saving the first kind leaves the deferred kind's entire JSON unchanged.")
                if noteFirst { workspace.restoreHighlightIfNeeded() } else { workspace.restoreInlineNoteIfNeeded() }
                let recoveredNote = try requireDraftFixture(noteFirst ? firstNote : workspace.inlineNoteSession)
                let recoveredHighlight = try requireDraftFixture(noteFirst ? workspace.highlightEditingSession : firstHighlight)
                expect(recoveredNote.id == note.id && recoveredNote.values.text == note.values.text
                    && recoveredHighlight.id == highlight.id && recoveredHighlight.values.comment == highlight.values.comment,
                    "Explicit Retry restores the second original draft after the first kind is safely saved.")
                expect(noteFirst ? canCommitHighlight(recoveredHighlight) : canCommitNote(recoveredNote),
                    "The unchanged Reader commit guard also permits the second editor after presentation cleanup.")
                workspace.state.undoManager.beginUndoGrouping()
                let secondSaved = noteFirst
                    ? recoveredHighlight.save(in: store, canCommit: { canCommitHighlight(recoveredHighlight) })
                    : recoveredNote.save(in: store, canCommit: { canCommitNote(recoveredNote) })
                workspace.state.undoManager.endUndoGrouping()
                if noteFirst { workspace.highlightEditingSession = nil } else { workspace.inlineNoteSession = nil }
                let savedNote = recoveredNote.draft.annotation
                func bothSaved() -> Bool {
                    savedNote.page === document.page(at: 1) && savedNote.contents == note.values.text
                        && nativeHighlight === recoveredHighlight.draft.annotation && nativeHighlight.page === page
                        && nativeHighlight.contents == highlight.values.comment && nativeHighlight.bounds == highlightBounds
                        && nativeHighlight.quadrilateralPoints == highlightPoints && document.pageCount == 2
                }
                expect(secondSaved && bothSaved(), "Both recovered texts are saved as their exact native standard annotations.")
                workspace.undoDocumentChange()
                expect(noteFirst ? (savedNote.page === document.page(at: 1) && nativeHighlight.contents == baselineComment)
                    : (savedNote.page == nil && nativeHighlight.contents == highlight.values.comment),
                    "One document Undo reverses only the second recovered Save.")
                workspace.undoDocumentChange()
                expect(savedNote.page == nil && nativeHighlight.page === page && nativeHighlight.contents == baselineComment
                    && !store.canUndoDocumentChange && document.pageCount == 2,
                    "The second Undo restores the authored PDF without deleting either page or the original highlight.")
                store.redoDocumentChange(); store.redoDocumentChange()
                expect(bothSaved() && !store.canRedoDocumentChange,
                    "Two Redo operations restore both exact native annotations and complete recovered values.")
                await queue.drain(); await settle()
                let copyURL = try requireDraftFixture(store.currentWorkingCopyURL)
                let copy = try requireDraftFixture(PDFDocument(url: copyURL))
                expect(copy.pageCount == 2 && copy.page(at: 0)?.annotations.contains { $0.type == "Highlight" && $0.contents == highlight.values.comment } == true
                    && copy.page(at: 1)?.annotations.contains { $0.type == "FreeText" && $0.contents == note.values.text } == true,
                    "The actual working copy reload contains both recovered standard annotations.")
                expect(!workspace.noteDraftRecovery.hasUnresolvedRecord && !workspace.highlightDraftRecovery.hasUnresolvedRecord
                    && !FileManager.default.fileExists(atPath: noteURL.path) && !FileManager.default.fileExists(atPath: highlightURL.path),
                    "Only durable completion of both Saves clears both unfinished recovery records.")
                let finalOriginalBytes = try Data(contentsOf: originalURL)
                expect(finalOriginalBytes == originalBytes && !store.hasUnsavedChanges && store.workingCopySaveError == nil,
                    "Recovery, Save, Undo and Redo preserve the original PDF bytes and finish without a pending copy write.")
            } catch { expect(false, "Fixture failed: \(error.localizedDescription)") }
        }
        return (checks, failures)
    }

    private static func requireDraftFixture<T>(_ value: T?) throws -> T {
        guard let value else { throw ClampedOpenError.missingFixture }; return value
    }

    private static func verifyClampedSessionOpen() async -> (checks: Int, failures: [String]) {
        var checks = 0, failures: [String] = []
        func expect(_ value: Bool, _ message: String) {
            checks += 1; if !value { failures.append("Clamped Session open: " + message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearClampedOpen-\(UUID())")
        let suite = "DogearClampedOpen.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return (1, ["Clamped Session open: Could not isolate defaults."])
        }
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let aURL = root.appendingPathComponent("A.pdf"), bURL = root.appendingPathComponent("B.pdf")
            let invalidURL = root.appendingPathComponent("Invalid.pdf")
            let originalA = fixtureData("Session A"), longB = fixtureData("Session B", pageCount: 10)
            let invalidBytes = Data("Authored invalid PDF fixture".utf8)
            try originalA.write(to: aURL); try longB.write(to: bURL); try invalidBytes.write(to: invalidURL)
            let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
            let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("journal"), workingCopyStore: copies)
            let access = DocumentAccessCoordinator(saveQueue: queue)
            let libraryURL = root.appendingPathComponent("library.json")
            let library = LibraryStore(userDefaults: defaults, storage: try LibraryJSONStore(stateURL: libraryURL),
                readingPositionSaveDelay: 3_600, workingCopyStore: copies)
            _ = library.upsertOpenedURLs([aURL, bURL, invalidURL], refreshBookmark: false)
            guard let fileA = library.file(for: aURL), let fileB = library.file(for: bURL),
                  let invalidFile = library.file(for: invalidURL) else { throw ClampedOpenError.missingFixture }
            let aOffset = PDFPageOffset(x: 123.5, y: 456.25)
            let staleBOffset = PDFPageOffset(x: 44, y: 650)
            library.updateReadingPosition(fileID: fileA.id, pageIndex: 0, offset: aOffset)
            library.updateReadingPosition(fileID: fileB.id, pageIndex: 9, offset: staleBOffset)
            library.updateZoomState(.custom(scaleFactor: 2), for: bURL)
            expect(PDFDocument(url: bURL)?.pageCount == 10 && library.flushPendingPersistence(),
                "The real Library records B's tenth page before an external truncation.")
            let shortenedB = fixtureData("Session B shortened")
            try shortenedB.write(to: bURL)
            guard let savedA = library.file(for: aURL), let staleB = library.file(for: bURL) else {
                throw ClampedOpenError.missingFixture
            }
            expect(PDFDocument(url: bURL)?.pageCount == 2 && staleB.lastPageIndex == 9
                && staleB.lastPageOffset == staleBOffset,
                "The shortened native PDF and its genuinely stale saved page coexist.")

            let research = ResearchStore(rootURL: root.appendingPathComponent("research"))
            let commands = ResearchCommandService(store: research)
            let configuration = AIConfigurationStore(configurationURL: root.appendingPathComponent("ai.json"),
                legacyUserDefaults: defaults, secretStore: ClampedOpenSecrets())
            let trace = AIHighlightTraceRecorder(fileURL: root.appendingPathComponent("trace.jsonl"), defaults: defaults)
            let runtime = ResearchRuntime(storage: research, configuration: configuration,
                service: AIHighlightWorkflowService(traceRecorder: trace), traceRecorder: trace,
                commands: commands, retrievalSelection: .lexical)
            defer { runtime.shutdown() }
            let services = IPadApplicationServices(library: library, research: research,
                configuration: configuration, language: AppLanguageStore(userDefaults: defaults),
                commands: commands, runtime: runtime, saveQueue: queue, observesApplication: false,
                beginBackgroundTask: { _ in .invalid }, endBackgroundTask: { _ in })
            let session = IPadWorkspaceSession(id: UUID(), services: services, userDefaults: defaults,
                accessCoordinator: access, workspaceFactory: { id, groupID, coordinator in
                    let feedback = OperationFeedbackCenter(userDefaults: defaults)
                    let directory = root.appendingPathComponent(id.uuidString)
                    let store = PDFDocumentStore(feedbackCenter: feedback,
                        metadataStore: DocumentMetadataStore(stateURL: directory.appendingPathComponent("metadata.json")),
                        aiHighlightGroupStore: AIHighlightGroupStore(stateURL: directory.appendingPathComponent("groups.json")),
                        workingCopyStore: copies, saveQueue: queue, accessCoordinator: coordinator,
                        exportPresenter: IPadDocumentExportPresenter())
                    return IPadGroupWorkspace(id: id, groupID: groupID, documentStore: store,
                        feedbackCenter: feedback, accessCoordinator: coordinator,
                        noteDraftDirectoryURL: root.appendingPathComponent("drafts"),
                        highlightDraftDirectoryURL: root.appendingPathComponent("highlight-drafts"))
                })
            defer { session.close() }
            expect(session.open(savedA), "The actual Session opens A with its own saved offset.")
            let workspace = session.workspace
            guard let nativeA = workspace.document.document, let oldRequest = workspace.pendingNavigation else {
                throw ClampedOpenError.missingFixture
            }
            expect(workspace.pageOffset == aOffset && oldRequest.document === nativeA
                && oldRequest.pageOffset == aOffset && !oldRequest.isAccepted,
                "A owns a nonempty page offset and an outstanding native navigation receipt.")
            expect(!session.open(invalidFile) && workspace.document.document === nativeA
                && workspace.pageOffset == aOffset && workspace.pendingNavigation?.id == oldRequest.id
                && !oldRequest.isCancelled,
                "A rejected open retains A's exact document, pending receipt and offset.")
            expect(session.open(staleB), "The actual Session opens B after its page count shrank.")
            guard let nativeB = workspace.document.document, let clampedRequest = workspace.pendingNavigation else {
                throw ClampedOpenError.missingFixture
            }
            expect(nativeB !== nativeA && nativeB.pageCount == 2 && workspace.document.currentPageIndex == 1
                && oldRequest.isCancelled && clampedRequest.id != oldRequest.id
                && clampedRequest.document === nativeB && clampedRequest.pageIndex == 1
                && clampedRequest.pageOffset == nil && workspace.pageOffset == nil
                && workspace.readingState(for: nativeB).pageOffset == nil,
                "Successful replacement cancels A and restores the Store-clamped page without either obsolete offset.")

            let reader = UIKitReaderPDFView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            reader.displayMode = .singlePage; reader.autoScales = true
            let readerCoordinator = PDFReaderUIKitView.Coordinator()
            readerCoordinator.attach(to: reader)
            var reportedPosition: (document: PDFDocument, page: Int, offset: PDFPageOffset)?
            readerCoordinator.onPageChanged = { pdf, page in
                guard workspace.document.document === pdf else { return }
                workspace.document.recordCurrentPage(page)
                workspace.libraryBinding?.recordPage(page, in: pdf)
            }
            readerCoordinator.onReadingPositionChanged = { pdf, page, offset in
                guard workspace.document.document === pdf else { return }
                reportedPosition = (pdf, page, offset)
                workspace.pageOffset = offset
                workspace.libraryBinding?.recordPosition(page: page, offset: offset, in: pdf)
            }
            readerCoordinator.onNavigationAccepted = { pdf, id in workspace.acknowledgeNavigation(in: pdf, requestID: id) }
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let previous = scene?.windows.first(where: \.isKeyWindow)
            let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: reader.frame)
            let controller = UIViewController(); controller.view.addSubview(reader)
            window.rootViewController = controller; window.makeKeyAndVisible()
            defer {
                readerCoordinator.detach(); reader.removeFromSuperview(); window.isHidden = true; previous?.makeKey()
            }
            readerCoordinator.install(nativeB, in: reader, initialReadingState: workspace.readingState(for: nativeB))
            expect(readerCoordinator.navigate(clampedRequest, in: reader), "The real Reader accepts B's corrected page request.")
            await settleClampedReader(reader)
            guard let bPage = nativeB.page(at: 1), let reported = reportedPosition else {
                throw ClampedOpenError.missingFixture
            }
            let nativePoint = reader.convert(reader.bounds.origin, to: bPage)
            expect(reader.document === nativeB && reader.currentPage === bPage && reported.document === nativeB
                && reported.page == 1 && workspace.document.currentPageIndex == 1 && clampedRequest.isAccepted,
                "The mounted PDFView and normal host callbacks settle on B's actual second page.")
            expect(abs(reported.offset.x - nativePoint.x) < 0.001 && abs(reported.offset.y - nativePoint.y) < 0.001
                && workspace.pageOffset == reported.offset && reported.offset != aOffset && reported.offset != staleBOffset,
                "B's reported offset is the actual native viewport rather than A's or the removed page's offset.")
            expect(library.flushPendingPersistence(), "The corrected native reading position flushes to Library JSON.")
            let firstReload = LibraryStore(userDefaults: defaults, storage: try LibraryJSONStore(stateURL: libraryURL), workingCopyStore: copies)
            expect(firstReload.allFiles.first { $0.id == fileA.id }?.lastPageOffset == aOffset
                && firstReload.allFiles.first { $0.id == fileB.id }?.lastPageIndex == 1
                && firstReload.allFiles.first { $0.id == fileB.id }?.lastPageOffset == reported.offset,
                "Fresh Library readback keeps A's offset and records only B's corrected native position.")

            // Use a destination accepted by the real, 200-percent native viewport,
            // then restore that measured offset instead of assuming a fit-page offset is reachable.
            reader.go(to: PDFDestination(page: bPage, at: CGPoint(x: 110, y: 610)))
            await settleClampedReader(reader)
            let reachablePoint = reader.convert(reader.bounds.origin, to: bPage)
            let reachableOffset = PDFPageOffset(x: reachablePoint.x, y: reachablePoint.y)
            expect(reader.currentPage === bPage && reader.scaleFactor > 1.9
                && reportedPosition?.document === nativeB && reportedPosition?.offset == reachableOffset,
                "A real scrollable B viewport supplies a reachable, reported page offset.")
            guard let validB = library.file(for: bURL), let reopenA = library.file(for: aURL) else {
                throw ClampedOpenError.missingFixture
            }
            expect(validB.lastPageIndex == 1 && validB.lastPageOffset == reachableOffset,
                "The valid B record comes from actual Reader callbacks, not an expected-value Library write.")
            readerCoordinator.detach()
            expect(session.open(reopenA), "Opening A first avoids B's same-file idempotent shortcut.")
            expect(session.open(validB), "The Session reopens B using its latest valid Library snapshot.")
            guard let restoredB = workspace.document.document, let validRequest = workspace.pendingNavigation else {
                throw ClampedOpenError.missingFixture
            }
            expect(validRequest.document === restoredB && validRequest.pageIndex == 1
                && validRequest.pageOffset == reachableOffset && workspace.pageOffset == reachableOffset
                && workspace.readingState(for: restoredB).pageOffset == reachableOffset,
                "A still-valid saved page preserves B's own measured offset in navigation and initial reading state.")
            reportedPosition = nil
            readerCoordinator.attach(to: reader)
            readerCoordinator.install(restoredB, in: reader, initialReadingState: workspace.readingState(for: restoredB))
            expect(readerCoordinator.navigate(validRequest, in: reader), "The Reader accepts B's legitimate offset restoration.")
            await settleClampedReader(reader)
            guard let restoredPage = restoredB.page(at: 1), let restoredPosition = reportedPosition else {
                throw ClampedOpenError.missingFixture
            }
            let restoredPoint = reader.convert(reader.bounds.origin, to: restoredPage)
            expect(reader.currentPage === restoredPage && restoredPosition.document === restoredB && restoredPosition.page == 1
                && abs(restoredPoint.x - reachableOffset.x) < 1 && abs(restoredPoint.y - reachableOffset.y) < 1
                && abs(restoredPosition.offset.x - restoredPoint.x) < 0.001
                && abs(restoredPosition.offset.y - restoredPoint.y) < 0.001,
                "A valid B offset survives A-to-B reopening within one PDF point through actual PDFKit transforms.")
            expect(library.flushPendingPersistence(), "The restored valid offset flushes before independent reload.")
            let finalReload = LibraryStore(userDefaults: defaults, storage: try LibraryJSONStore(stateURL: libraryURL), workingCopyStore: copies)
            expect(finalReload.allFiles.first { $0.id == fileA.id }?.lastPageOffset == aOffset
                && finalReload.allFiles.first { $0.id == fileB.id }?.lastPageIndex == 1
                && finalReload.allFiles.first { $0.id == fileB.id }?.lastPageOffset == restoredPosition.offset
                && finalReload.allFiles.first { $0.id == fileA.id }?.workingCopyURL == nil
                && finalReload.allFiles.first { $0.id == fileB.id }?.workingCopyURL == nil,
                "Final Library reload preserves independent offsets without allocating a PDF working copy.")
            await queue.drain()
            let finalABytes = try Data(contentsOf: aURL), finalBBytes = try Data(contentsOf: bURL)
            let finalInvalidBytes = try Data(contentsOf: invalidURL)
            expect(finalABytes == originalA && finalBBytes == shortenedB
                && finalInvalidBytes == invalidBytes && !workspace.document.hasUnsavedChanges,
                "Reading restoration preserves the exact authored original bytes, including B's post-truncation baseline.")
        } catch { expect(false, "Fixture failed: \(error.localizedDescription)") }
        return (checks, failures)
    }

    private enum ClampedOpenError: Error { case missingFixture }
    private final class ClampedOpenSecrets: AISecretStoring {
        func readSecret(profileID: UUID) -> String? { nil }
        func saveSecret(_ secret: String, profileID: UUID, configurationName: String) {}
        func removeSecret(profileID: UUID) {}
        func updateLabel(profileID: UUID, configurationName: String) {}
    }
    private static func settleClampedReader(_ reader: PDFView) async {
        for _ in 0..<12 {
            reader.setNeedsLayout(); reader.layoutIfNeeded()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private final class PreviewGate {
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func resume() { continuation?.resume(); continuation = nil }
    }
    private static func settle() async {
        for _ in 0..<12 { await Task.yield() }
    }
    private static func fixtureData(_ text: String, pageCount: Int = 2) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        return renderer.pdfData { context in
            for page in 0..<pageCount {
                context.beginPage()
                ("\(text) page \(page + 1)" as NSString).draw(at: CGPoint(x: 64, y: 100),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            }
        }
    }
}
#endif
