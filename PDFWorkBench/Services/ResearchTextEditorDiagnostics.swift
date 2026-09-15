import AppKit
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

    private static func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }
}
