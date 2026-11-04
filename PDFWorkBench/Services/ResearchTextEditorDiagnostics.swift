import AppKit
import Combine
import Foundation
import SwiftUI

/// Native text-system fixtures run in an unshown window with a named pasteboard.
/// They never focus a user window, touch the general clipboard or edit a PDF.
@MainActor
enum ResearchTextEditorDiagnostics {
    struct Report: Sendable { let checks: Int; let failures: [String] }

    static func run() -> Report {
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ failure: String) {
            checks += 1
            if !value { failures.append(failure) }
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 260),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = ResearchNativeTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 260))
        editor.isRichText = false
        editor.isEditable = true
        editor.allowsUndo = true
        editor.string = "Initial"
        window.contentView = editor
        window.makeFirstResponder(editor)
        var bound = "Initial"
        var submissions = 0
        var editingBoundaries = 0
        let parent = ResearchTextEditor(text: Binding(get: { bound }, set: { bound = $0 }),
            onSubmit: { submissions += 1 }, onEditingBoundary: { editingBoundaries += 1 })
        let coordinator = ResearchTextEditor.Coordinator(parent)
        editor.delegate = coordinator
        editor.onSubmit = { submissions += 1 }
        let undoItem = NSMenuItem(title: "Undo", action: #selector(ResearchNativeTextView.undo(_:)), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: #selector(ResearchNativeTextView.redo(_:)), keyEquivalent: "Z")
        check(editor.responds(to: undoItem.action!) && editor.responds(to: redoItem.action!),
              "Native editor does not expose the Edit menu's undo:/redo: actions")
        check(!editor.validateUserInterfaceItem(undoItem), "Empty text history enabled Undo")
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.insertText(" typed", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(bound == "Initial typed" && editor.undoManager?.canUndo == true,
              "Native typing did not publish the binding or register undo")
        check(editor.validateUserInterfaceItem(undoItem), "Edit menu Undo stayed disabled after native typing")
        check(editor.undoManager !== window.undoManager, "Research text shares the document/window undo manager")
        editor.applyExternalText(bound)
        check(editor.undoManager?.canUndo == true, "A SwiftUI binding echo cleared native undo history")
        editor.undo(nil)
        check(editor.string == "Initial" && bound == "Initial", "Responder Undo did not restore and persist the preceding text")
        check(editor.validateUserInterfaceItem(redoItem), "Edit menu Redo stayed disabled after Undo")
        editor.redo(nil)
        check(editor.string == "Initial typed" && bound == "Initial typed", "Responder Redo failed to restore text")
        check(editingBoundaries >= 2, "Undo/Redo did not close the note revision edit burst")

        if let undo = key("z", code: 6, modifiers: .command, window: window),
           let redo = key("Z", code: 6, modifiers: [.command, .shift], window: window) {
            check(editor.performKeyEquivalent(with: undo) && editor.string == "Initial", "Command-Z escaped the editor's manager")
            check(editor.performKeyEquivalent(with: redo) && editor.string == "Initial typed", "Shift-Command-Z did not redo the text edit")
        } else { check(false, "Could not create native Undo key fixtures") }

        editor.applyExternalText("Replacement")
        check(editor.string == "Replacement" && editor.undoManager?.canUndo == false && editor.undoManager?.canRedo == false,
              "External content replacement retained old-session undo or redo")
        editor.undo(nil)
        check(editor.string == "Replacement", "Undo resurrected a replaced draft")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        if let newline = key("\r", code: 36, modifiers: [], window: window) {
            editor.keyDown(with: newline)
            check(editor.string == "Replacement\n" && submissions == 0, "Return sent a request or failed to insert a newline")
        } else { check(false, "Could not create Return fixture") }
        let beforeSubmit = editor.string
        if let submit = key("\r", code: 36, modifiers: .command, window: window) {
            check(editor.performKeyEquivalent(with: submit) && submissions == 1 && editor.string == beforeSubmit,
                  "Command-Return did not submit exactly once without inserting text")
        }
        if let keypadSubmit = key("\r", code: 76, modifiers: [.command, .numericPad, .capsLock], window: window) {
            check(editor.performKeyEquivalent(with: keypadSubmit) && submissions == 2,
                  "Caps Lock or keypad metadata broke Command-Return")
        }
        if let modified = key("\r", code: 36, modifiers: [.command, .shift], window: window) {
            _ = editor.performKeyEquivalent(with: modified)
            check(submissions == 2, "Shift-Command-Return unexpectedly sent the draft")
        }
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        check(editor.hasMarkedText(), "IME fixture did not establish marked text")
        let marked = editor.string
        editor.applyExternalText("An external echo must not replace composition")
        check(editor.hasMarkedText() && editor.string == marked, "A binding update destroyed an active IME composition")
        if let markedReturn = key("\r", code: 36, modifiers: .command, window: window) {
            _ = editor.performKeyEquivalent(with: markedReturn)
            check(submissions == 2, "Command-Return sent while Chinese composition was marked")
        }
        editor.insertText("拼音", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(!editor.hasMarkedText() && editor.string.hasSuffix("拼音"), "IME commit lost the selected Chinese text")
        if let committedReturn = key("\r", code: 36, modifiers: .command, window: window) {
            _ = editor.performKeyEquivalent(with: committedReturn)
            check(submissions == 3, "Command-Return did not resume after IME commit")
        }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DogearTextDiagnostics-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let pasted = "Pasted line one\n第二行"
        check(pasteboard.setString(pasted, forType: .string), "Could not prepare the isolated text pasteboard")
        editor.applyExternalText("Before paste")
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        check(editor.readSelection(from: pasteboard, type: .string), "Native text paste failed")
        check(editor.string == pasted && editor.validateUserInterfaceItem(undoItem), "Native paste failed to register an undoable replacement")
        editor.undo(nil)
        check(editor.string == "Before paste", "Paste undo did not restore the replaced selection")
        editor.redo(nil)
        check(editor.string == pasted, "Paste redo did not restore the full multiline content")
        editor.isEditable = false
        check(!editor.validateUserInterfaceItem(undoItem) && !editor.validateUserInterfaceItem(redoItem),
              "Read-only research text advertises editing history")
        editor.undo(nil)
        check(editor.string == pasted, "Read-only text accepted Undo")

        let nextSession = ResearchNativeTextView(frame: .zero)
        nextSession.allowsUndo = true
        nextSession.string = pasted
        check(nextSession.undoManager !== editor.undoManager && nextSession.undoManager?.canUndo == false,
              "Recreating the text view for a session identity inherited another session's history")
        // Long read-only answers must be fully laid out before the outer scroll
        // view positions them, with no inner scroller or deferred height state.
        let longAnswer = String(repeating: "A long answer with English and 中文证据 that must wrap at the available width.\n", count: 160)
        let reading = ResearchSelectableText.makeTextView(text: longAnswer)
        let narrow = ResearchSelectableText.measuredSize(of: reading, width: 280)
        let wide = ResearchSelectableText.measuredSize(of: reading, width: 620)
        check(narrow.height > wide.height && wide.height > 1_600,
              "Long answers stopped wrapping or retained the old 1600-point clipping limit")
        check(reading.enclosingScrollView == nil && !reading.isVerticallyResizable && !reading.isHorizontallyResizable,
              "Read-only answers own a competing scroll view or resize themselves")
        check(!reading.isEditable && reading.isSelectable, "Read-only answers lost native selection or became editable")
        var sizesAreStable = true
        for _ in 0..<30 {
            let measured = ResearchSelectableText.measuredSize(of: reading, width: 280)
            reading.setFrameSize(measured)
            reading.layoutSubtreeIfNeeded()
            sizesAreStable = sizesAreStable && measured == narrow
            _ = ResearchSelectableText.measuredSize(of: reading, width: 620)
        }
        check(sizesAreStable, "Alternating width proposals changed a previously measured answer height")
        reading.setFrameSize(wide)
        reading.needsLayout = true
        reading.layoutSubtreeIfNeeded()
        let drawingWidth = reading.textContainer?.containerSize.width
        _ = ResearchSelectableText.measuredSize(of: reading, width: 80)
        check(drawingWidth == 604 && reading.textContainer?.containerSize.width == drawingWidth,
              "A speculative narrow size proposal changed the final drawing width")
        reading.applyExternalText("Short answer")
        check(ResearchSelectableText.measuredSize(of: reading, width: 280).height < narrow.height,
              "Replacing an answer retained stale long-text geometry")
        var quoted = ""
        reading.onQuote = { quoted = $0 }
        reading.setSelectedRange(NSRange(location: 0, length: 5))
        _ = reading.perform(NSSelectorFromString("quoteSelection"))
        check(quoted == "Short", "Read-only selection quoting changed after removing the inner scroll view")
        let formatted = ResearchMarkdown.render("# Heading\n\nA **bold** and *italic* sentence.\n\n1. First\n2. Second\n\n`literal **stars**`")
        check(formatted.string.hasPrefix("Heading\nA bold and italic") && formatted.string.contains("1.  First\n2.  Second"),
              "Markdown headings, paragraphs or ordered list markers were not rendered")
        let boldRange = (formatted.string as NSString).range(of: "bold")
        let boldFont = formatted.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        check(boldFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true,
              "Markdown strong emphasis did not become a bold font")
        check(formatted.string.contains("literal **stars**"), "Inline code lost literal Markdown characters")
        let firstSource = ResearchSourceSnapshot(fileID: UUID(), displayName: "First.pdf", fingerprint: "first")
        let secondSource = ResearchSourceSnapshot(fileID: UUID(), displayName: "Second.pdf", fingerprint: "second")
        let page6 = ResearchEvidence(source: secondSource, anchor: ResearchPageAnchor(pageIndex: 5), excerpt: "six")
        let page7 = ResearchEvidence(source: secondSource, anchor: ResearchPageAnchor(pageIndex: 6), excerpt: "seven")
        let linked = ResearchMarkdown.render("[D002 p. 7] [D002 p. 6–7] [D001 p. 7] `[D002 p. 7]`", sources: [firstSource, secondSource], evidence: [page6, page7])
        let linkedText = linked.string as NSString
        let firstLink = linked.attribute(.link, at: 0, effectiveRange: nil) as? URL
        check(firstLink?.host?.lowercased() == page7.id.uuidString.lowercased(),
              "A citation linked by evidence order rather than its frozen document number and page")
        let range6 = linkedText.range(of: "6–7")
        check((linked.attribute(.link, at: range6.location, effectiveRange: nil) as? URL)?.host?.lowercased() == page6.id.uuidString.lowercased()
              && (linked.attribute(.link, at: range6.location + 2, effectiveRange: nil) as? URL)?.host?.lowercased() == page7.id.uuidString.lowercased(),
              "Multi-page citation endpoints did not keep their distinct evidence links")
        let missingRange = linkedText.range(of: "[D001 p. 7]")
        check(linked.attribute(.link, at: missingRange.location, effectiveRange: nil) == nil
              && linked.attribute(.link, at: linked.length - 2, effectiveRange: nil) == nil,
              "An unsupported citation or inline-code example became a navigation link")
        var opened: UUID?
        let linkParent = ResearchSelectableText(text: "", sources: [firstSource, secondSource], evidence: [page6, page7],
            onViewEvidence: { opened = $0.id })
        let linkCoordinator = ResearchSelectableText.Coordinator(linkParent)
        if let firstLink {
            _ = linkCoordinator.textView(reading, clickedOnLink: firstLink, at: 0)
        }
        check(opened == page7.id, "Native citation clicks did not route through the existing evidence action")
        return Report(checks: checks, failures: failures)
    }

    /// Exercises the production representable, including its deferred native
    /// installation and actual dismantle. The two windows stay unshown and do
    /// not change the user's key window or clipboard.
    static func runComposerNative() async -> Report {
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearMacComposer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResearchStore(rootURL: root)
        let sessionA = store.createSession(title: "Native A")
        let sessionB = store.createSession(title: "Native B")
        for (id, text) in [(sessionA, "A baseline"), (sessionB, "B baseline")] {
            if var draft = store.session(id: id)?.draft { draft.text = text; _ = store.saveDraft(draft, sessionID: id) }
        }
        let editing = ResearchComposerEditingSession(store: store)
        let commands = ResearchTextEditingCommands()
        check(editing.bind(sessionID: sessionA, prepareNativeInput: { true }), "The native Mac fixture binds its actual shared composer owner.")
        let firstState = ComposerFixtureState(editing: editing, commands: commands, identity: sessionA)
        let secondState = ComposerFixtureState(editing: editing, commands: commands, identity: sessionA)
        let firstHost = NSHostingView(rootView: ComposerFixture(state: firstState))
        let firstWindow = composerWindow(), secondWindow = composerWindow()
        defer { firstWindow.close(); secondWindow.close() }
        firstWindow.contentView = firstHost
        await settleComposer(firstHost)
        guard let first = nativeEditor(in: firstHost), let firstInstallation = editing.nativeInstallationID else {
            check(false, "The production Mac composer did not attach its actual window-ready NSTextView.")
            return Report(checks: checks, failures: failures)
        }
        check(first.window === firstWindow && first.isEditable && editing.ownsEditor && first.editorIdentity == sessionA,
            "Only the exact window-ready native composer becomes editable.")
        firstWindow.makeFirstResponder(first)
        first.setSelectedRange(NSRange(location: (first.string as NSString).length, length: 0))
        first.insertText(" typed", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(store.session(id: sessionA)?.draft.text == first.string && first.undoManager?.canUndo == true,
            "Actual NSTextView typing writes its captured composer and retains independent native Undo.")
        first.setMarkedText("中文候选", selectedRange: NSRange(location: 4, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        check(first.hasMarkedText(), "A same-object remount begins with actual Mac marked Chinese input.")
        let secondHost = NSHostingView(rootView: ComposerFixture(state: secondState))
        secondWindow.contentView = secondHost
        await settleComposer(secondHost)
        guard let second = nativeEditor(in: secondHost), let secondInstallation = editing.nativeInstallationID else {
            check(false, "The replacement native Mac composer did not attach.")
            return Report(checks: checks, failures: failures)
        }
        let preparedText = first.string
        check(firstInstallation != secondInstallation && !first.hasMarkedText()
            && preparedText.contains("中文候选") && store.session(id: sessionA)?.draft.text == preparedText
            && second.string == preparedText && second.isEditable && editing.ownsEditor,
            "A real same-StateObject remount prepares old composition before granting the new immutable installation.")
        secondWindow.makeFirstResponder(second)
        second.setSelectedRange(NSRange(location: (second.string as NSString).length, length: 0))
        second.insertText(" newer", replacementRange: NSRange(location: NSNotFound, length: 0))
        await settleComposer(secondHost)
        await settleComposer(firstHost)
        let canonical = store.composerSnapshot(sessionID: sessionA)
        let currentLease = editing.lease
        let currentText = editing.localText, currentError = editing.error
        check(canonical?.text == second.string && canonical?.text.hasSuffix(" newer") == true
            && first.string == preparedText && !first.isEditable,
            "The superseded host cannot receive a new binding echo or remain editable under the replacement lease.")
        first.commitCurrentText()
        check(store.composerSnapshot(sessionID: sessionA) == canonical && editing.nativeInstallationID == secondInstallation
            && editing.lease == currentLease && editing.localText == currentText && editing.error == currentError
            && store.composerConflicts.contains(where: { $0.id == firstInstallation && $0.sessionID == sessionA && $0.text == preparedText }),
            "A real old native commit archives its original session text without borrowing the fresh host's lease.")
        firstState.isMounted = false
        await settleComposer(firstHost)
        check(first.delegate == nil && first.onCommitCurrentText == nil && editing.nativeInstallationID == secondInstallation
            && editing.lease == currentLease && editing.ownsEditor && second.isEditable,
            "Dismantling the old representable detaches only its installation and preserves the fresh native owner.")
        second.setMarkedText("新输入", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        check(commands.finishEditing(identity: sessionA) && !second.hasMarkedText()
            && store.session(id: sessionA)?.draft.text == second.string && second.string.contains("新输入"),
            "The command adapter remains attached to the actual replacement editor after old teardown.")
        check(editing.bind(sessionID: sessionB, prepareNativeInput: { true }),
            "The same shared editing object can bind a genuinely different Research session.")
        let thirdState = ComposerFixtureState(editing: editing, commands: commands, identity: sessionB)
        let thirdHost = NSHostingView(rootView: ComposerFixture(state: thirdState))
        let thirdWindow = composerWindow(); defer { thirdWindow.close() }
        thirdWindow.contentView = thirdHost
        await settleComposer(thirdHost)
        guard let third = nativeEditor(in: thirdHost), let thirdInstallation = editing.nativeInstallationID else {
            check(false, "The different-session native Mac composer did not attach.")
            return Report(checks: checks, failures: failures)
        }
        let beforeB = store.composerSnapshot(sessionID: sessionB)
        let beforeBLease = editing.lease, beforeBLocal = editing.localText, beforeBError = editing.error
        let beforeA = store.composerSnapshot(sessionID: sessionA)
        // Model a text-system result delivered after the native host became
        // read-only. It changes the actual old NSTextStorage, then uses the
        // production commit callback; it never writes through a Binding.
        second.textStorage?.append(NSAttributedString(string: " late A"))
        let lateAText = second.string
        second.commitCurrentText()
        await settleComposer(secondHost)
        check(editing.sessionID == sessionB && editing.nativeInstallationID == thirdInstallation
            && store.composerSnapshot(sessionID: sessionB) == beforeB && editing.lease == beforeBLease
            && editing.localText == beforeBLocal && editing.error == beforeBError && third.string == "B baseline"
            && store.composerSnapshot(sessionID: sessionA) == beforeA && lateAText.hasSuffix(" late A")
            && store.composerConflicts.contains(where: { $0.id == secondInstallation && $0.sessionID == sessionA && $0.text == lateAText }),
            "A captured late native callback cannot redirect old A text into the current B composer.")
        check(second.editorIdentity == sessionA && second.string.contains("新输入") && !second.isEditable,
            "The old A view does not apply the reused editing object's B binding getter as an A echo.")
        secondState.isMounted = false
        await settleComposer(secondHost)
        check(editing.nativeInstallationID == thirdInstallation && editing.ownsEditor,
            "Late dismantle from another Research UUID cannot detach the current composer.")

        let delayedEditing = ResearchComposerEditingSession(store: store)
        let delayedID = store.createSession(title: "Deferred native")
        check(delayedEditing.bind(sessionID: delayedID, prepareNativeInput: { true }),
            "The deferred native fixture has an independent real shared owner.")
        let delayedState = ComposerFixtureState(editing: delayedEditing, commands: ResearchTextEditingCommands(), identity: delayedID)
        let delayedHost = NSHostingView(rootView: ComposerFixture(state: delayedState))
        delayedHost.frame = NSRect(x: 0, y: 0, width: 400, height: 260)
        await settleComposer(delayedHost)
        check(delayedEditing.nativeInstallationID == nil, "A windowless native view does not claim an editing installation.")
        delayedState.isActive = false
        await settleComposer(delayedHost)
        let delayedWindow = composerWindow(); defer { delayedWindow.close() }
        delayedWindow.contentView = delayedHost
        await settleComposer(delayedHost)
        check(delayedEditing.nativeInstallationID == nil && nativeEditor(in: delayedHost)?.isEditable == false,
            "An inactive host rejects its late window-ready attachment.")
        delayedState.isActive = true
        await settleComposer(delayedHost)
        check(delayedEditing.nativeInstallationID != nil && nativeEditor(in: delayedHost)?.isEditable == true,
            "A still-current native installation can attach when its presentation becomes active.")

        let reservedID = store.createSession(title: "Never-attached host")
        let reservedEditing = ResearchComposerEditingSession(store: store)
        check(reservedEditing.bind(sessionID: reservedID, prepareNativeInput: { true }),
            "The late-window fixture binds a real shared composer independently.")
        let reservedCommands = ResearchTextEditingCommands()
        let oldReservedState = ComposerFixtureState(editing: reservedEditing, commands: reservedCommands, identity: reservedID)
        let oldReservedHost = NSHostingView(rootView: ComposerFixture(state: oldReservedState))
        oldReservedHost.frame = NSRect(x: 0, y: 0, width: 400, height: 260)
        await settleComposer(oldReservedHost)
        check(nativeEditor(in: oldReservedHost) != nil && reservedEditing.nativeInstallationID == nil,
            "The old reservation belongs to an actual mounted, windowless NSTextView.")
        let freshReservedState = ComposerFixtureState(editing: reservedEditing, commands: reservedCommands, identity: reservedID)
        let freshReservedHost = NSHostingView(rootView: ComposerFixture(state: freshReservedState))
        let freshReservedWindow = composerWindow(), oldReservedWindow = composerWindow()
        defer { freshReservedWindow.close(); oldReservedWindow.close() }
        freshReservedWindow.contentView = freshReservedHost
        await settleComposer(freshReservedHost)
        guard let freshReserved = nativeEditor(in: freshReservedHost),
              let reservedInstallation = reservedEditing.nativeInstallationID else {
            check(false, "The newer reservation did not attach its actual native window.")
            return Report(checks: checks, failures: failures)
        }
        freshReservedWindow.makeFirstResponder(freshReserved)
        freshReserved.insertText("latest native host", replacementRange: NSRange(location: NSNotFound, length: 0))
        let reservedSnapshot = store.composerSnapshot(sessionID: reservedID)
        let reservedLease = reservedEditing.lease
        oldReservedWindow.contentView = oldReservedHost
        await settleComposer(oldReservedHost)
        check(reservedEditing.nativeInstallationID == reservedInstallation && reservedEditing.lease == reservedLease
            && reservedEditing.ownsEditor && freshReserved.isEditable
            && nativeEditor(in: oldReservedHost)?.isEditable == false
            && store.composerSnapshot(sessionID: reservedID) == reservedSnapshot,
            "A never-attached old host cannot claim the latest reservation when its window arrives late.")
        freshReserved.setMarkedText("新宿主", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        oldReservedState.isMounted = false
        await settleComposer(oldReservedHost)
        check(reservedCommands.finishEditing(identity: reservedID) && !freshReserved.hasMarkedText()
            && reservedEditing.nativeInstallationID == reservedInstallation && reservedEditing.ownsEditor
            && store.session(id: reservedID)?.draft.text == freshReserved.string,
            "Late old-host teardown preserves the fresh command target and captured Chinese composition.")
        freshReservedState.isMounted = false
        await settleComposer(freshReservedHost)
        thirdState.isMounted = false; delayedState.isMounted = false
        await settleComposer(thirdHost); await settleComposer(delayedHost)
        check(editing.nativeInstallationID == nil && delayedEditing.nativeInstallationID == nil
            && !editing.ownsEditor && !delayedEditing.ownsEditor,
            "Actual current-host dismantle releases only its exact native editing owners.")
        return Report(checks: checks, failures: failures)
    }

    private static func composerWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 260),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func settleComposer(_ view: NSView) async {
        for _ in 0..<5 {
            view.needsLayout = true; view.layoutSubtreeIfNeeded()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func nativeEditor(in view: NSView) -> ResearchNativeTextView? {
        if let value = view as? ResearchNativeTextView { return value }
        for child in view.subviews { if let value = nativeEditor(in: child) { return value } }
        return nil
    }

    private final class ComposerFixtureState: ObservableObject {
        let editing: ResearchComposerEditingSession
        let commands: ResearchTextEditingCommands
        let identity: UUID
        @Published var isActive = true
        @Published var isMounted = true
        init(editing: ResearchComposerEditingSession, commands: ResearchTextEditingCommands, identity: UUID) {
            self.editing = editing; self.commands = commands; self.identity = identity
        }
    }

    private struct ComposerFixture: View {
        @ObservedObject var state: ComposerFixtureState
        @ObservedObject var editing: ResearchComposerEditingSession
        init(state: ComposerFixtureState) { self.state = state; editing = state.editing }
        var body: some View {
            Group {
                if state.isMounted {
                    ResearchTextEditor(text: Binding(get: { editing.text }, set: { _ = editing.acceptNativeText($0) }),
                        commands: state.commands, identity: state.identity,
                        composerEditing: editing, composerIsActive: state.isActive)
                        .id(state.identity)
                } else { Color.clear }
            }.frame(width: 400, height: 260)
        }
    }

    private static func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }
}
