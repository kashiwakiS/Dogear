import Foundation

/// Runs solely against disposable local records; no credentials, provider, or user PDF access.
@MainActor
enum ResearchPersistenceDiagnostics {
    static func run() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }
        // Sibling pane budgets cover both sides of the narrow-window threshold.
        let paneCases = [CGFloat(520), 804, 1169, 1170, 1197, 1600].flatMap { width in
            [CGFloat(0), 284].flatMap { annotation in
                [false, true].flatMap { shown in
                    [false, true].map { focused in
                        (width, shown, ResearchWorkspaceLayout(availableWidth: width,
                            annotationWidth: annotation, showsResearch: shown,
                            readerFraction: 0.5, focusesResearch: focused))
                    }
                }
            }
        }
        check(paneCases.allSatisfy { width, shown, layout in
            let divider = shown && layout.canSplit ? ResearchWorkspaceLayout.dividerWidth : 0
            return abs(layout.readerWidth + layout.researchWidth + divider + layout.annotationWidth - width) < 0.01
        }, "PDF/AI/annotation widths overlap or leave an unallocated gap across focus and visibility transitions.")
        check(paneCases.allSatisfy { _, shown, layout in
            !shown || !layout.canSplit || (layout.readerWidth >= 520 && layout.researchWidth >= 360)
        }, "Split mode violates a pane minimum instead of switching to narrow-window focus.")
        let full = ResearchWorkspaceLayout(availableWidth: 1197, annotationWidth: 284,
            showsResearch: true, readerFraction: 0.5, focusesResearch: true)
        check(full.annotationWidth == 284 && full.readerWidth == 520 && full.researchWidth == 387,
              "Opening AI does not preserve the complete 284-point right sidebar in the reported window.")
        let narrow = ResearchWorkspaceLayout(availableWidth: 804, annotationWidth: 284,
            showsResearch: true, readerFraction: 0.5, focusesResearch: true)
        check(!narrow.canSplit && narrow.researchWidth == 520 && narrow.annotationWidth == 284,
              "A narrow AI workspace hides or clips the annotation sidebar.")
        let annotations: Set<ReaderSidebarSection> = [.fullText, .dogears, .annotations]
        let sidebar = ReaderSidebarLayout(availableHeight: 700,
            expandedSections: [.annotations, .askSelection], visibleSections: annotations)
        check(annotations.reduce(CGFloat(0)) { $0 + sidebar.height(for: $1) } == 700
              && sidebar.height(for: .askSelection) == 0,
              "The detached Ask section still takes half the sidebar or reserves an invisible header.")
        check(ReaderSidebarLayout.maximumExpandedSectionCount(for: 516, sectionCount: 3) == 2,
              "Annotation-only expansion capacity still counts the hidden Ask section.")
        for showsResearch in [false, true] {
            let baseline = ResearchWorkspaceLayout(availableWidth: 1300, annotationWidth: 0,
                showsResearch: showsResearch, readerFraction: 0.5, focusesResearch: true)
            for opening in [false, true] {
                let frames = (0...60).map { frame in
                    let progress = CGFloat(opening ? frame : 60 - frame) / 60
                    return ResearchWorkspaceLayout(availableWidth: 1300 + 284 * progress,
                        annotationWidth: 284, showsResearch: showsResearch,
                        readerFraction: 0.5, focusesResearch: true,
                        fixedReadingAreaWidth: baseline.readingAreaWidth)
                }
                check(frames.allSatisfy { $0.readerWidth == baseline.readerWidth
                    && $0.researchWidth == baseline.researchWidth && $0.canSplit == baseline.canSplit },
                    "Annotation window animation changed PDF/AI widths or narrow focus at an intermediate frame.")
                let settled = ResearchWorkspaceLayout(availableWidth: opening ? 1584 : 1300,
                    annotationWidth: opening ? 284 : 0, showsResearch: showsResearch,
                    readerFraction: 0.5, focusesResearch: true)
                check(settled.readerWidth == baseline.readerWidth && settled.researchWidth == baseline.researchWidth,
                      "Releasing the annotation animation snapshot resized the reading panes.")
            }
        }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("ResearchDiagnostics-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        do {
            let store = ResearchStore(rootURL: root)
            let source = ResearchSourceSnapshot(fileID: UUID(), displayName: "same.pdf", fingerprint: "version-a")
            let other = ResearchSourceSnapshot(fileID: UUID(), displayName: "same.pdf", fingerprint: "version-b")
            let selection = ResearchSourceSelection(fileIDs: [source.fileID, source.fileID, other.fileID], groupID: UUID())
            check(selection.expandedFileIDs(groupMembers: [other.fileID, source.fileID]) == [other.fileID, source.fileID],
                  "Source expansion did not deduplicate stable identities or preserve Group order.")
            let sessionID = store.createSession(title: "Research", sourceSelection: selection)
            let emptyID = store.createSession(title: "Independent")
            let evidence = ResearchEvidence(source: source, anchor: ResearchPageAnchor(pageIndex: 2, x: 10, y: 20, width: 30, height: 40), excerpt: "Original evidence")
            let block = ResearchInputBlock(kind: .pdfText, text: "Original evidence", explanation: "Check this", evidence: evidence)
            let draft = ResearchDraft(text: "Question", blocks: [block, ResearchInputBlock(kind: .discussion, text: "Earlier opinion")])
            check(store.saveDraft(draft, sessionID: sessionID), "Could not save ordered input blocks.")
            let requestID = store.beginRequest(sessionID: sessionID, question: "Question", sourceSnapshot: [source, other])!
            check(store.beginRequest(sessionID: sessionID, question: "Another", sourceSnapshot: []) == nil,
                  "A second active request started in one session.")
            check(store.session(id: emptyID)?.messages.isEmpty == true, "A request leaked into another session.")
            let runningReload = ResearchStore(rootURL: root)
            check(runningReload.session(id: sessionID)?.messages.last?.status == .interrupted, "Reload did not interrupt running requests.")
            check(runningReload.session(id: sessionID)?.draft == draft, "Reload lost the input draft.")
            check(runningReload.session(id: sessionID)?.activeRequestID == nil, "Reload kept an automatically resumable request.")
            check(!runningReload.finishRequest(sessionID: sessionID, requestID: requestID, answer: "Late", status: .accepted),
                  "Interrupted request accepted a late answer.")
            let restoredID = runningReload.beginRequest(sessionID: sessionID, question: "Question", sourceSnapshot: [source])!
            runningReload.saveDraft(ResearchDraft(text: "Next question"), sessionID: sessionID)
            check(runningReload.finishRequest(sessionID: sessionID, requestID: restoredID, answer: "Accepted answer", evidence: [evidence], status: .accepted),
                  "Could not save an accepted answer.")
            check(runningReload.session(id: sessionID)?.draft.text == "Next question", "Completion erased the next draft.")
            let nextID = runningReload.beginRequest(sessionID: sessionID, question: "Next question", sourceSnapshot: [source])!
            runningReload.finishRequest(sessionID: sessionID, requestID: nextID, answer: "Second answer", status: .accepted, origin: .localOutline)
            check(runningReload.session(id: sessionID)?.draft.isEmpty == true, "Successful request did not clear its unchanged draft.")
            let persisted = ResearchStore(rootURL: root)
            check(persisted.session(id: sessionID)?.messages.last?.origin == .localOutline, "Local answer provenance was lost.")
            check(persisted.session(id: sessionID)?.messages.first?.sourceSnapshot == [source, other], "Same-name file identities were conflated.")
            let roundTripEvidence = persisted.session(id: sessionID)?.messages.first(where: { $0.status == .accepted })?.evidence.first
            check(roundTripEvidence == evidence, "Page coordinates, source version, or evidence excerpt did not survive reload.")

            let attachment = try persisted.importAttachment(data: Data([137, 80, 78, 71]), displayName: "diagram.png", mimeType: "image/png", fileExtension: "png")
            persisted.saveDraft(ResearchDraft(blocks: [ResearchInputBlock(kind: .image, attachmentID: attachment.id)]), sessionID: sessionID)
            let provenance = ResearchNoteProvenance(origin: .verifiedAI, sessionID: sessionID, messageID: restoredID, evidence: [evidence])
            let noteID = persisted.createNote(title: "Independent note", body: "Verified answer", provenance: [provenance], attachmentIDs: [attachment.id])
            check(persisted.attachmentReferenceCounts()[attachment.id] == 2, "Attachment references in a session draft and independent note were not both counted.")
            var note = persisted.note(id: noteID)!
            note.body = "User edited answer"
            check(persisted.updateNote(note), "Could not save a user note edit.")
            note = persisted.note(id: noteID)!
            check(note.revision == 2 && note.revisions.first?.body == "Verified answer", "Note revision history did not retain previous content.")
            check(note.verificationInvalidated, "User edit kept the original AI verification status.")
            check(!persisted.updateNote(ResearchNote(id: noteID, title: "Stale", body: "Old editor", revision: 1)), "A stale editor overwrote a newer note revision.")
            let editorID = UUID()
            check(persisted.claimNoteEditor(noteID: noteID, editorID: editorID) == editorID, "Could not claim a note editor.")
            check(persisted.claimNoteEditor(noteID: noteID, editorID: UUID()) == editorID, "A duplicate note editor acquired ownership.")
            persisted.releaseNoteEditor(noteID: noteID, editorID: UUID())
            check(persisted.claimNoteEditor(noteID: noteID, editorID: UUID()) == editorID, "A different editor released note ownership.")
            let suggestion = ResearchNoteSuggestion(baseRevision: note.revision, body: "Suggested body")
            check(persisted.addSuggestion(suggestion, noteID: noteID), "Could not preserve a suggested note rewrite.")
            check(persisted.note(id: noteID)?.body == "User edited answer", "A suggestion replaced user content without application.")
            try persisted.applySuggestion(id: suggestion.id, noteID: noteID)
            check(persisted.note(id: noteID)?.body == "Suggested body", "Explicit suggestion application did not update the note.")
            let staleSuggestion = ResearchNoteSuggestion(baseRevision: 2, body: "Stale")
            check(!persisted.addSuggestion(staleSuggestion, noteID: noteID), "Stale suggestion was accepted.")
            check(persisted.deleteSession(id: sessionID), "Could not explicitly delete a session.")
            check(persisted.note(id: noteID) != nil && persisted.attachmentURL(id: attachment.id) != nil,
                  "Session deletion cascaded to independent notes or attachments.")
            let removedWhileReferenced = try persisted.removeUnreferencedAttachments()
            check(removedWhileReferenced == 0, "Attachment referenced by a note was removed.")
            let exportURL = root.appendingPathComponent("exported-note")
            try persisted.exportNote(id: noteID, to: exportURL)
            let markdown = try String(contentsOf: exportURL.appendingPathComponent("research.md"), encoding: .utf8)
            check(markdown.contains("attachments/\(attachment.filename)") && markdown.contains("page 3") && markdown.contains(source.fileID.uuidString),
                  "Markdown export lost relative image links or human-readable evidence identity.")
            check(fileManager.fileExists(atPath: exportURL.appendingPathComponent("attachments/\(attachment.filename)").path), "Export omitted its attachment.")
            do { try persisted.exportNote(id: noteID, to: exportURL); check(false, "Export overwrote an existing folder.") }
            catch ResearchStoreError.exportDestinationExists { check(true, "") }

            // Model SavePanel's target-only grant: sibling staging is forbidden,
            // while Foundation's item-replacement directory remains writable.
            let selectedParent = root.appendingPathComponent("save-panel-parent", isDirectory: true)
            try fileManager.createDirectory(at: selectedParent, withIntermediateDirectories: false)
            let sibling = selectedParent.appendingPathComponent("keep.txt")
            try Data("Existing unrelated file".utf8).write(to: sibling)
            for failure in ResearchExportFileManager.Failure.allCases {
                let destination = selectedParent.appendingPathComponent("export-\(failure.rawValue)")
                let replacementRoot = root.appendingPathComponent("replacement-\(failure.rawValue)", isDirectory: true)
                let exportManager = ResearchExportFileManager(selectedParent: selectedParent,
                    replacementRoot: replacementRoot, failure: failure)
                let exporter = ResearchStore(rootURL: root, fileManager: exportManager)
                do {
                    try exporter.exportNote(id: noteID, to: destination)
                    check(failure == .none, "An injected export failure was reported as success: \(failure.rawValue).")
                } catch {
                    check(failure != .none, "Target-only export still required sibling access: \(error.localizedDescription)")
                }
                check(exportManager.requestedDestination?.standardizedFileURL.path == selectedParent.standardizedFileURL.path,
                      "Export did not use the existing destination parent to select Foundation's staging volume.")
                check(!fileManager.fileExists(atPath: replacementRoot.path),
                      "Export left temporary staging after \(failure.rawValue).")
                if failure == .none {
                    let output = try String(contentsOf: destination.appendingPathComponent("research.md"), encoding: .utf8)
                    let exportedImage = try Data(contentsOf: destination.appendingPathComponent("attachments/\(attachment.filename)"))
                    check(output == markdown && exportedImage == Data([137, 80, 78, 71]),
                          "Target-only export lost Markdown or attachment bytes.")
                } else if failure == .destinationAppears {
                    let existing = try String(contentsOf: destination.appendingPathComponent("existing.txt"), encoding: .utf8)
                    check(existing == "Keep concurrent destination" && !fileManager.fileExists(atPath: destination.appendingPathComponent("research.md").path),
                          "Export overwrote or merged into a destination created during preparation.")
                } else {
                    check(!fileManager.fileExists(atPath: destination.path),
                          "A failed export left an incomplete destination after \(failure.rawValue).")
                }
            }
            let preservedSibling = try String(contentsOf: sibling, encoding: .utf8)
            check(preservedSibling == "Existing unrelated file", "Export modified an unrelated destination sibling.")
            let beforeDelete = ResearchStore(rootURL: root)
            check(beforeDelete.note(id: noteID)?.revisions.count == 2, "Independent note revisions did not survive reload.")
            check(persisted.deleteNote(id: noteID), "Could not delete an independent note.")
            let cleaned = try persisted.removeUnreferencedAttachments()
            check(cleaned == 1 && persisted.attachmentURL(id: attachment.id) == nil, "Explicit cleanup did not remove unreferenced attachments.")

            var history = ResearchSession(title: "History")
            for index in 0..<8 {
                history.messages.append(ResearchMessage(question: "Q\(index)", answer: "A\(index)", status: .accepted))
            }
            let rounds = ResearchHistorySelection.select(from: history)
            check(rounds.count == 6 && rounds.first?.question == "Q2" && rounds.last?.question == "Q7", "History did not retain only the latest six full rounds.")
            check(rounds.allSatisfy { $0.kind == .discussion }, "History was mislabeled as factual source evidence.")
            check(ResearchHistorySelection.select(from: history, maximumCharacters: 7).count == 1, "History character limit split a round or exceeded its budget.")
            history.messages.append(ResearchMessage(question: "Large", answer: String(repeating: "x", count: 12_001), status: .accepted))
            check(ResearchHistorySelection.select(from: history).isEmpty, "Oversized latest history round was silently truncated or skipped.")

            // Typing history is bounded independently of per-edit versions and
            // immediate autosave. An injected clock avoids timing-sensitive sleeps.
            var typingNow = Date(timeIntervalSince1970: 1_700_000_000)
            let typingRoot = root.appendingPathComponent("typing-fixture")
            let typing = ResearchStore(rootURL: typingRoot, noteEditClock: { typingNow })
            let typingID = typing.createNote(title: "Typing", body: "Start", provenance: [provenance])
            let initialNote = typing.note(id: typingID)!
            let beforeTypingSuggestion = ResearchNoteSuggestion(baseRevision: initialNote.revision, body: "Suggestion before typing")
            _ = typing.addSuggestion(beforeTypingSuggestion, noteID: typingID)
            var everyTypingSaveSucceeded = true
            for _ in 0..<40 {
                var edited = typing.note(id: typingID)!
                edited.body += "x"
                let saved = typing.updateNote(edited, coalescingEdits: true)
                everyTypingSaveSucceeded = everyTypingSaveSucceeded && saved
                typingNow += 0.01
            }
            check(everyTypingSaveSucceeded, "A typing autosave failed.")
            var typed = typing.note(id: typingID)!
            check(typed.revision == 41 && typed.revisions.count == 1,
                  "Typing either failed to advance every revision or created a snapshot for every keystroke.")
            check(typed.revisions.first?.body == "Start" && typed.revisions.first?.provenance == [provenance],
                  "The beginning of a typing burst lost its original body/source state.")
            check(ResearchStore(rootURL: typingRoot).note(id: typingID)?.body == typed.body,
                  "Typing history coalescing delayed the latest body's autosave.")
            check(typed.verificationInvalidated, "A coalesced edit preserved obsolete AI verification.")
            check(!typing.updateNote(initialNote, coalescingEdits: true), "A stale typing snapshot overwrote the latest note.")
            check(!typing.addSuggestion(ResearchNoteSuggestion(baseRevision: 1, body: "Stale AI"), noteID: typingID),
                  "Per-burst history allowed an AI suggestion based on an old per-edit version.")
            do {
                try typing.applySuggestion(id: beforeTypingSuggestion.id, noteID: typingID)
                check(false, "A pre-typing suggestion overwrote newer coalesced edits.")
            } catch ResearchStoreError.staleNoteRevision { check(true, "") }
            let beforePause = typed.body
            typingNow += 3
            typed.body += " paused"
            _ = typing.updateNote(typed, coalescingEdits: true)
            typed = typing.note(id: typingID)!
            check(typed.revisions.count == 2 && typed.revisions.last?.body == beforePause,
                  "A typing pause did not begin an independent history burst.")
            // Continuous typing also gets a boundary every 30 seconds.
            let countBeforeLongBurst = typed.revisions.count
            for _ in 0..<31 {
                typingNow += 1
                var edited = typing.note(id: typingID)!
                edited.body += "c"
                _ = typing.updateNote(edited, coalescingEdits: true)
            }
            typed = typing.note(id: typingID)!
            check(typed.revisions.count == countBeforeLongBurst + 1,
                  "Uninterrupted typing retained an unbounded single history burst.")
            let beforeRenameCount = typed.revisions.count
            typed.title = "Renamed while typing"
            _ = typing.updateNote(typed, coalescingEdits: true)
            typed = typing.note(id: typingID)!
            check(typed.revisions.count == beforeRenameCount + 1,
                  "Switching from body edits to title edits merged distinct history boundaries.")
            let beforeSourcesCount = typed.revisions.count
            typed.provenance.append(ResearchNoteProvenance(origin: .user))
            _ = typing.updateNote(typed, coalescingEdits: true)
            typed = typing.note(id: typingID)!
            check(typed.revisions.count == beforeSourcesCount + 1,
                  "A source change was merged into a typing history burst.")
            let beforeExplicit = typed.revisions.count
            typed.body = "Explicitly restored body"
            _ = typing.updateNote(typed)
            typed = typing.note(id: typingID)!
            typed.body += " manual"
            _ = typing.updateNote(typed, coalescingEdits: true)
            typed = typing.note(id: typingID)!
            check(typed.revisions.count == beforeExplicit + 2,
                  "An explicit restore or following typing failed to keep its own boundary.")
            let beforeBoundary = typed.revisions.count
            typing.endNoteEditBurst(noteID: typingID)
            typed.body += " after undo"
            _ = typing.updateNote(typed, coalescingEdits: true)
            typed = typing.note(id: typingID)!
            check(typed.revisions.count == beforeBoundary + 1, "The native Undo/focus boundary did not end a typing burst.")
            let typingEditor = UUID()
            _ = typing.claimNoteEditor(noteID: typingID, editorID: typingEditor)
            typing.releaseNoteEditor(noteID: typingID, editorID: typingEditor)
            let beforeRelease = typed.revisions.count
            typed.body += " reopened"
            _ = typing.updateNote(typed, coalescingEdits: true)
            typed = typing.note(id: typingID)!
            check(typed.revisions.count == beforeRelease + 1, "Releasing a note editor left its typing burst active.")
            let freshSuggestion = ResearchNoteSuggestion(baseRevision: typed.revision, body: "Accepted rewrite")
            _ = typing.addSuggestion(freshSuggestion, noteID: typingID)
            let beforeSuggestion = typed.revisions.count
            try typing.applySuggestion(id: freshSuggestion.id, noteID: typingID)
            typed = typing.note(id: typingID)!
            check(typed.body == "Accepted rewrite" && typed.revisions.count == beforeSuggestion + 1,
                  "Applying a suggestion merged its change into a preceding typing burst.")
            let afterSuggestion = typed.revisions.count
            typed.body += " continued"
            _ = typing.updateNote(typed, coalescingEdits: true)
            check(typing.note(id: typingID)?.revisions.count == afterSuggestion + 1,
                  "Typing after applying an AI suggestion omitted its history boundary.")
            let restarted = ResearchStore(rootURL: typingRoot, noteEditClock: { typingNow })
            var afterRestart = restarted.note(id: typingID)!
            let beforeRestartEdit = afterRestart.revisions.count
            afterRestart.body += " restart"
            _ = restarted.updateNote(afterRestart, coalescingEdits: true)
            check(restarted.note(id: typingID)?.revisions.count == beforeRestartEdit + 1,
                  "A restart improperly continued an earlier in-memory typing burst.")

            var shouldFail = false
            let failureRoot = root.appendingPathComponent("failure-fixture")
            let failing = ResearchStore(rootURL: failureRoot, atomicWriter: { data, url in
                if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            })
            let failedID = failing.createSession(title: "Last valid")
            shouldFail = true
            var unsaved = failing.session(id: failedID)!
            unsaved.title = "Unsaved edit"
            check(!failing.updateSession(unsaved), "Injected save failure was ignored.")
            check(failing.session(id: failedID)?.title == "Unsaved edit" && !failing.saveFailures.isEmpty, "Save failure discarded unsaved memory or its retry state.")
            check(ResearchStore(rootURL: failureRoot).session(id: failedID)?.title == "Last valid", "Failed save damaged the last valid file.")
            check(failing.beginRequest(sessionID: failedID, question: "Never send", sourceSnapshot: []) == nil,
                  "Provider start was allowed before pending request persistence.")
            check(failing.session(id: failedID)?.activeRequestID == nil, "Failed persistence left a phantom running request.")
            shouldFail = false
            failing.retryFailedSaves()
            check(failing.saveFailures.isEmpty && ResearchStore(rootURL: failureRoot).session(id: failedID)?.title == "Unsaved edit", "Retry did not recover pending user content.")
            let failedTypingID = failing.createNote(title: "Failed typing", body: "Last valid note")
            shouldFail = true
            for suffix in ["a", "b", "c"] {
                var edit = failing.note(id: failedTypingID)!
                edit.body += suffix
                _ = failing.updateNote(edit, coalescingEdits: true)
            }
            check(failing.note(id: failedTypingID)?.body == "Last valid noteabc"
                    && failing.note(id: failedTypingID)?.revisions.count == 1,
                  "Failed typing discarded the newest text or expanded history per failed keystroke.")
            check(ResearchStore(rootURL: failureRoot).note(id: failedTypingID)?.body == "Last valid note",
                  "Failed typing damaged the last durable note body.")
            shouldFail = false
            failing.retryFailedSaves()
            check(ResearchStore(rootURL: failureRoot).note(id: failedTypingID)?.body == "Last valid noteabc",
                  "Retry did not persist the latest coalesced typing edits.")
            let corruptURL = failureRoot.appendingPathComponent("sessions/\(UUID().uuidString).json")
            try Data("broken record".utf8).write(to: corruptURL)
            let damaged = ResearchStore(rootURL: failureRoot)
            check(damaged.sessions.count == 1 && damaged.loadWarnings.count == 1, "One corrupt record prevented recovery of healthy research.")
            do { _ = try damaged.removeUnreferencedAttachments(); check(false, "Cleanup ran with unreadable records.") }
            catch ResearchStoreError.incompleteAttachmentInventory { check(true, "") }
            let fileAttributes = try fileManager.attributesOfItem(atPath: failureRoot.appendingPathComponent("sessions/\(failedID.uuidString).json").path)
            check((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Research records are not private (0600).")
            let directoryAttributes = try fileManager.attributesOfItem(atPath: failureRoot.path)
            check((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Research directory is not private (0700).")
        } catch {
            failures.append("Research fixture error: \(error.localizedDescription)")
        }
        return (checks, failures)
    }
}

/// Deterministic target-only authorization and failure injection; all paths are
/// disposable test fixtures. The real default FileManager export also runs above.
nonisolated private final class ResearchExportFileManager: FileManager {
    enum Failure: String, CaseIterable { case none, temporaryDirectory, attachmentCopy, publish, destinationAppears }
    private let selectedParent: URL
    private let replacementRoot: URL
    private let failure: Failure
    private let lock = NSLock()
    private var appropriateDestination: URL?

    var requestedDestination: URL? {
        lock.lock()
        defer { lock.unlock() }
        return appropriateDestination
    }

    init(selectedParent: URL, replacementRoot: URL, failure: Failure) {
        self.selectedParent = selectedParent
        self.replacementRoot = replacementRoot
        self.failure = failure
        super.init()
    }

    override func url(for directory: FileManager.SearchPathDirectory, in domain: FileManager.SearchPathDomainMask,
                      appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL {
        guard directory == .itemReplacementDirectory else {
            return try super.url(for: directory, in: domain, appropriateFor: url, create: shouldCreate)
        }
        lock.lock()
        appropriateDestination = url
        lock.unlock()
        guard domain == .userDomainMask, shouldCreate, failure != .temporaryDirectory else { throw CocoaError(.fileWriteNoPermission) }
        try super.createDirectory(at: replacementRoot, withIntermediateDirectories: false)
        return replacementRoot
    }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        if url.deletingLastPathComponent().standardizedFileURL.path == selectedParent.standardizedFileURL.path {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try super.copyItem(at: srcURL, to: dstURL)
        if failure == .attachmentCopy { throw CocoaError(.fileWriteOutOfSpace) }
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if failure == .publish { throw CocoaError(.fileWriteNoPermission) }
        if failure == .destinationAppears {
            try FileManager.default.createDirectory(at: dstURL, withIntermediateDirectories: false)
            try Data("Keep concurrent destination".utf8).write(to: dstURL.appendingPathComponent("existing.txt"))
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
