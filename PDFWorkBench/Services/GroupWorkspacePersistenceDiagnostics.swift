import AppKit
import Foundation

/// Offline regressions for Group persistence, content adaptation and Undo ownership.
/// Storage is disposable and native windows remain unshown; no user PDF is opened.
@MainActor
enum GroupWorkspacePersistenceDiagnostics {
    static func run() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroupWorkspaceDiagnostics-\(UUID().uuidString)")
        let defaultsName = "Dogear.GroupWorkspaceDiagnostics.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            return (1, ["Could not create an isolated defaults domain."])
        }
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: defaultsName)
        }

        do {
            let storage = try LibraryJSONStore(stateURL: root.appendingPathComponent("library.json"))
            let groupA = LibraryGroup(name: "Research", sortIndex: 0)
            let groupB = LibraryGroup(name: "Course", sortIndex: 1)
            let member = LibraryFile(displayName: "member.pdf", canonicalPath: root.appendingPathComponent("member.pdf").path,
                lastPageIndex: 4, lastPageOffset: PDFPageOffset(x: 0.1, y: 0.7), lastZoomState: .custom(scaleFactor: 1.5))
            let temporary = LibraryFile(displayName: "reference.pdf", canonicalPath: root.appendingPathComponent("reference.pdf").path)
            let course = LibraryFile(displayName: "course.pdf", canonicalPath: root.appendingPathComponent("course.pdf").path)
            let firstSession = GroupWindowSession(groupID: groupA.id, openFileIDs: [member.id], selectedFileID: member.id)
            let membership = GroupMembership(groupID: groupA.id, fileID: member.id, addedAt: Date())
            try storage.save(LibraryState(files: [member, temporary, course], groups: [groupA, groupB],
                memberships: [membership], windowSessions: [firstSession]))
            let library = LibraryStore(userDefaults: defaults, storage: storage)
            let restoredBeforeEnsure = library.openSession(for: groupA.id, sessionID: firstSession.id)
            let emptySessionID = UUID()
            library.ensureWindowSession(for: groupB.id, sessionID: emptySessionID)
            check(library.openSession(for: groupB.id, sessionID: emptySessionID)?.openFileIDs.isEmpty == true
                    && library.openSession(for: groupB.id, sessionID: emptySessionID)?.selectedFileID == nil,
                  "An empty Group workspace was not persisted without inventing a selected PDF.")
            let stateBeforeRepeat = library.state
            for _ in 0..<5 {
                library.ensureWindowSession(for: groupA.id, sessionID: firstSession.id)
                library.ensureWindowSession(for: groupB.id, sessionID: emptySessionID)
            }
            check(library.state == stateBeforeRepeat && library.state.windowSessions.count == 2,
                  "Repeated workspace activation duplicated a session or changed existing state.")
            check(library.openSession(for: groupA.id, sessionID: firstSession.id) == restoredBeforeEnsure,
                  "Ensuring a restored workspace reset its selected file, open-file order, or timestamp.")
            library.ensureWindowSession(for: UUID(), sessionID: UUID())
            check(library.state == stateBeforeRepeat, "An unavailable Group created an orphan workspace session.")

            library.recordOpenedFile(temporary.id, in: groupA.id, sessionID: firstSession.id)
            library.ensureWindowSession(for: groupB.id, sessionID: emptySessionID)
            library.recordOpenedFile(course.id, in: groupB.id, sessionID: emptySessionID)
            library.ensureWindowSession(for: groupA.id, sessionID: firstSession.id)
            check(library.openSession(for: groupA.id, sessionID: firstSession.id)?.selectedFileID == temporary.id
                    && library.openSession(for: groupB.id, sessionID: emptySessionID)?.selectedFileID == course.id,
                  "Switching between Group workspaces lost or leaked the selected file.")
            check(library.openSession(for: groupA.id, sessionID: firstSession.id)?.openFileIDs == [member.id, temporary.id],
                  "Group reactivation reordered or discarded the temporary reference file.")
            check(library.state.memberships.count == 1
                    && library.state.memberships.first?.groupID == groupA.id
                    && library.state.memberships.first?.fileID == member.id,
                  "Opening a temporary workspace file silently changed Group membership.")

            let secondWindowID = UUID()
            library.ensureWindowSession(for: groupA.id, sessionID: secondWindowID)
            library.recordOpenedFile(member.id, in: groupA.id, sessionID: secondWindowID)
            let stillEmptyID = UUID()
            library.ensureWindowSession(for: groupB.id, sessionID: stillEmptyID)
            check(library.openSession(for: groupA.id, sessionID: firstSession.id)?.selectedFileID == temporary.id
                    && library.openSession(for: groupA.id, sessionID: secondWindowID)?.selectedFileID == member.id,
                  "Two windows for one Group shared a session or overwrote each other's selection.")

            let reloaded = LibraryStore(userDefaults: defaults, storage: storage)
            for session in reloaded.state.windowSessions {
                reloaded.ensureWindowSession(for: session.groupID, sessionID: session.id)
            }
            check(reloaded.state.windowSessions.count == 4
                    && reloaded.openSession(for: groupA.id, sessionID: firstSession.id)?.selectedFileID == temporary.id
                    && reloaded.openSession(for: groupB.id, sessionID: emptySessionID)?.selectedFileID == course.id
                    && reloaded.openSession(for: groupA.id, sessionID: secondWindowID)?.selectedFileID == member.id,
                  "Relaunch plus ensure lost independent workspace selections or added duplicate sessions.")
            check(reloaded.openSession(for: groupA.id, sessionID: firstSession.id)?.openFileIDs == [member.id, temporary.id]
                    && reloaded.filesForWindow(in: groupA.id, sessionID: firstSession.id).map(\.id) == [member.id, temporary.id],
                  "Relaunch lost the temporary reference or promoted unrelated Library files into the workspace.")
            check(reloaded.openSession(for: groupB.id, sessionID: stillEmptyID)?.openFileIDs.isEmpty == true
                    && reloaded.openSession(for: groupB.id, sessionID: stillEmptyID)?.selectedFileID == nil,
                  "A saved empty workspace disappeared or inherited another window's PDF on reload.")
            let restoredMember = reloaded.state.files.first { $0.id == member.id }
            check(restoredMember?.lastPageIndex == member.lastPageIndex
                    && restoredMember?.lastPageOffset == member.lastPageOffset
                    && restoredMember?.lastZoomState == member.lastZoomState,
                  "Workspace creation/restoration changed the saved PDF reading position.")

            // Fixed pre-adapter schema-1 JSON, not generated by today's encoder:
            // this catches accidental Codable shape changes as well as data loss.
            let legacyData = Data(legacyNoteJSON.utf8)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            var note = try decoder.decode(ResearchNote.self, from: legacyData)
            check(note.schemaVersion == 1 && note.content == .markdown("# Summary\n\n**Source** [p. 3]"),
                  "A legacy Markdown note no longer decodes through the content adapter.")
            let oldObject = try JSONSerialization.jsonObject(with: legacyData) as? NSDictionary
            let encodedObject = try JSONSerialization.jsonObject(with: encoder.encode(note)) as? NSDictionary
            check(oldObject != nil && oldObject == encodedObject,
                  "Viewing legacy note content changed its JSON schema, metadata, evidence, history, or suggestions.")
            check(note.revisions.first?.content == .markdown("Earlier body")
                    && note.suggestions.first?.content == .markdown("Suggested body"),
                  "Historical/suggested content stopped using its own stored Markdown body.")
            let original = note
            note.content = .markdown("# Edited 摘要\n\n- One\n- Two\n\n`**literal**`")
            var expected = original
            expected.body = "# Edited 摘要\n\n- One\n- Two\n\n`**literal**`"
            check(note == expected, "Editing typed content changed note identity, sources, revisions, or other metadata.")
            let reopened = try decoder.decode(ResearchNote.self, from: encoder.encode(note))
            check(reopened == expected && reopened.content == note.content,
                  "Typed Markdown edits did not survive the existing schema-1 JSON round trip.")
        } catch {
            check(false, "Group workspace/content fixture failed: \(error.localizedDescription)")
        }
        let undo = workspaceUndoDiagnostics()
        checks += undo.checks
        failures.append(contentsOf: undo.failures)
        return (checks, failures)
    }

    private static func workspaceUndoDiagnostics() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        let frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        let firstWindow = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let secondWindow = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        firstWindow.isReleasedWhenClosed = false
        secondWindow.isReleasedWhenClosed = false
        firstWindow.contentView = NSView(frame: frame)
        secondWindow.contentView = NSView(frame: frame)
        let firstView = HighlightingPDFView(frame: NSRect(x: 0, y: 0, width: 240, height: 300))
        let secondView = HighlightingPDFView(frame: NSRect(x: 250, y: 0, width: 240, height: 300))
        let firstManager = UndoManager()
        let secondManager = UndoManager()
        firstManager.groupsByEvent = false
        secondManager.groupsByEvent = false
        firstView.workspaceUndoManager = firstManager
        secondView.workspaceUndoManager = secondManager
        firstWindow.contentView?.addSubview(firstView)
        firstWindow.contentView?.addSubview(secondView)
        defer {
            firstManager.removeAllActions()
            secondManager.removeAllActions()
            firstView.removeFromSuperview()
            secondView.removeFromSuperview()
            firstWindow.close()
            secondWindow.close()
        }
        let first = WorkspaceUndoValue(view: firstView)
        let second = WorkspaceUndoValue(view: secondView)
        let undoAction = #selector(HighlightingPDFView.undo(_:))
        let redoAction = #selector(HighlightingPDFView.redo(_:))
        first.edit(1)
        second.edit(9)
        let firstUndoHandled = firstView.tryToPerform(undoAction, with: nil)
        check(firstUndoHandled && first.value == 0 && second.value == 9 && secondManager.canUndo,
              "Undo in one PDF workspace changed or consumed another workspace's history in the same window.")
        let firstRedoHandled = firstView.tryToPerform(redoAction, with: nil)
        let secondUndoHandled = secondView.tryToPerform(undoAction, with: nil)
        check(firstRedoHandled && secondUndoHandled && first.value == 1 && second.value == 0,
              "PDF responder Redo/Undo did not independently restore the two workspace values.")

        // Match AppKit key-equivalent routing: an unhandled PDFView event may
        // still be handled by the Edit menu. A false view result alone is not a
        // broken shortcut, and must not justify a global Undo override.
        firstWindow.makeFirstResponder(firstView)
        let editMenu = NSMenu(title: "Edit")
        let undoItem = NSMenuItem(title: "Undo", action: undoAction, keyEquivalent: "z")
        undoItem.target = firstView
        let redoItem = NSMenuItem(title: "Redo", action: redoAction, keyEquivalent: "Z")
        redoItem.target = firstView
        editMenu.addItem(undoItem)
        editMenu.addItem(redoItem)
        if let undoKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: firstWindow.windowNumber, context: nil,
            characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6),
           let redoKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: 0, windowNumber: firstWindow.windowNumber, context: nil,
            characters: "Z", charactersIgnoringModifiers: "Z", isARepeat: false, keyCode: 6) {
            let undoKeyHandled = firstView.performKeyEquivalent(with: undoKey) || editMenu.performKeyEquivalent(with: undoKey)
            check(undoKeyHandled && first.value == 0 && second.value == 0,
                  "Native Command-Z routing failed or consumed another workspace's Undo history.")
            let redoKeyHandled = firstView.performKeyEquivalent(with: redoKey) || editMenu.performKeyEquivalent(with: redoKey)
            check(redoKeyHandled && first.value == 1 && second.value == 0,
                  "Native Shift-Command-Z routing failed or consumed another workspace's Redo history.")
        } else { check(false, "Could not create native PDF Undo/Redo key fixtures.") }

        firstView.removeFromSuperview()
        secondWindow.contentView?.addSubview(firstView)
        let movedUndoHandled = firstView.tryToPerform(undoAction, with: nil)
        check(firstView.window === secondWindow && firstView.undoManager === firstManager
                && movedUndoHandled && first.value == 0 && second.value == 0 && secondManager.canRedo,
              "Moving a PDF view to a different window replaced its manager or lost/misdirected the existing Undo.")

        firstView.removeFromSuperview()
        let detachedRedoHandled = firstView.tryToPerform(redoAction, with: nil)
        check(firstView.window == nil && detachedRedoHandled && first.value == 1 && second.value == 0,
              "Temporarily removing a workspace view from its window lost pending Redo.")
        first.edit(2)
        let detachedUndoHandled = firstView.tryToPerform(undoAction, with: nil)
        check(detachedUndoHandled && first.value == 1 && firstManager.canRedo && second.value == 0,
              "An edit registered while a workspace view was detached had no usable Undo.")
        let editedRedoHandled = firstView.tryToPerform(redoAction, with: nil)
        check(editedRedoHandled && first.value == 2 && second.value == 0,
              "Undo of a detached workspace edit failed to register its inverse Redo.")

        firstWindow.contentView?.addSubview(firstView)
        let lastUndoHandled = firstView.tryToPerform(undoAction, with: nil)
        let originalUndoHandled = firstView.tryToPerform(undoAction, with: nil)
        check(firstView.window === firstWindow && lastUndoHandled && originalUndoHandled && first.value == 0,
              "Returning a workspace to its original host lost the pre-move or detached-edit Undo sequence.")
        let secondRedoHandled = secondView.tryToPerform(redoAction, with: nil)
        check(secondRedoHandled && second.value == 9 && first.value == 0,
              "Moving and undoing another workspace consumed the untouched workspace's pending Redo.")
        return (checks, failures)
    }

    /// A tiny editable value exercises the view's actual manager and responder
    /// dispatch without duplicating PDF annotation logic or reading any file.
    private final class WorkspaceUndoValue {
        let view: HighlightingPDFView
        private(set) var value = 0
        init(view: HighlightingPDFView) { self.view = view }
        func edit(_ newValue: Int) {
            let manager = view.undoManager
            manager?.beginUndoGrouping()
            set(newValue)
            manager?.endUndoGrouping()
        }
        private func set(_ newValue: Int) {
            let previous = value
            view.undoManager?.registerUndo(withTarget: self) { target in target.set(previous) }
            value = newValue
        }
    }

    private static let legacyNoteJSON = #"""
    {
      "schemaVersion": 1,
      "id": "10000000-0000-0000-0000-000000000001",
      "title": "Existing research",
      "body": "# Summary\n\n**Source** [p. 3]",
      "provenance": [{
        "origin": "verifiedAI",
        "sessionID": "20000000-0000-0000-0000-000000000001",
        "messageID": "30000000-0000-0000-0000-000000000001",
        "evidence": [{
          "id": "40000000-0000-0000-0000-000000000001",
          "source": {
            "fileID": "50000000-0000-0000-0000-000000000001",
            "displayName": "source.pdf",
            "fingerprint": "source-v1"
          },
          "kind": "pdfText",
          "anchor": { "pageIndex": 2, "x": 10, "y": 20, "width": 30, "height": 40 },
          "excerpt": "Original evidence"
        }]
      }],
      "attachmentIDs": ["60000000-0000-0000-0000-000000000001"],
      "revision": 2,
      "revisions": [{
        "id": "70000000-0000-0000-0000-000000000001",
        "number": 1, "title": "Earlier research", "body": "Earlier body",
        "provenance": [], "attachmentIDs": [], "verificationInvalidated": false,
        "createdAt": 1789459200000
      }],
      "suggestions": [{
        "id": "80000000-0000-0000-0000-000000000001",
        "baseRevision": 2, "body": "Suggested body", "provenance": [], "attachmentIDs": [],
        "createdAt": 1789545600000
      }],
      "verificationInvalidated": true,
      "createdAt": 1789459200000,
      "updatedAt": 1789545600000
    }
    """#
}
