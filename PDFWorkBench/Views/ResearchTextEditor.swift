import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The platform adapter finishes the exact installed composer before the
/// shared editing owner grants another window access to its draft.
@MainActor
final class ResearchTextEditingCommands: ObservableObject {
    private weak var editor: ResearchNativeTextView?
    func register(_ editor: ResearchNativeTextView) { self.editor = editor }
    var hasMarkedText: Bool { editor?.hasMarkedText() == true }
    func focus(identity: UUID) {
        guard let editor, editor.editorIdentity == identity, editor.isEditable,
              let window = editor.window, window.isKeyWindow else { return }
        if let current = window.firstResponder as? NSTextView, current !== editor { return }
        window.makeFirstResponder(editor)
    }
    @discardableResult
    func finishEditing(identity: UUID) -> Bool {
        guard let editor else { return true }
        guard editor.editorIdentity == identity else { return false }
        editor.commitCurrentText()
        if editor.window?.firstResponder === editor { _ = editor.window?.makeFirstResponder(nil) }
        return true
    }
    func unregister(_ editor: ResearchNativeTextView) {
        if self.editor === editor { self.editor = nil }
    }
}

/// A native text system keeps IME composition, selection, paste and editor Undo independent of PDF editing.
struct ResearchTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    var placeholder = ""
    var onSubmit: (() -> Void)? = nil
    var onQuote: ((String) -> Void)? = nil
    var onPasteImage: ((Data, String) -> Void)? = nil
    var onEditingBoundary: (() -> Void)? = nil
    var commands: ResearchTextEditingCommands? = nil
    var identity: UUID? = nil
    var composerEditing: ResearchComposerEditingSession? = nil
    var composerIsActive = true
    var onExternalTextApplied: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let editor = ResearchNativeTextView(frame: .zero)
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.isEditable = context.coordinator.isEditable
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.usesFindPanel = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.string = context.coordinator.initialText
        editor.placeholder = placeholder
        editor.onSubmit = onSubmit
        editor.onQuote = onQuote
        editor.onPasteImage = onPasteImage
        context.coordinator.install(editor)
        editor.setAccessibilityLabel(placeholder.isEmpty ? L10n.string("Research text") : placeholder)
        scrollView.documentView = editor
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let editor = scrollView.documentView as? ResearchNativeTextView else { return }
        guard context.coordinator.matches(self) else {
            context.coordinator.retire(editor)
            return
        }
        context.coordinator.parent = self
        editor.placeholder = placeholder
        editor.onSubmit = onSubmit
        editor.onQuote = onQuote
        editor.onPasteImage = onPasteImage
        context.coordinator.install(editor)
        context.coordinator.applyExternalText(to: editor)
        editor.needsDisplay = true
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        guard let editor = view.documentView as? ResearchNativeTextView else { return }
        coordinator.dismantle(editor)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ResearchTextEditor
        let identity: UUID?
        let installationID = UUID()
        let composerEditing: ResearchComposerEditingSession?
        private var attachmentTask: Task<Void, Never>?
        private var attachmentGeneration = UUID()
        private var isRetired = false
        private var isDismantled = false

        init(_ parent: ResearchTextEditor) {
            self.parent = parent
            identity = parent.identity
            composerEditing = parent.composerEditing
            super.init()
            if let identity, let composerEditing {
                composerEditing.reserveNativeHost(sessionID: identity, installationID: installationID)
            }
        }

        var initialText: String {
            guard let composerEditing else { return parent.text }
            guard composerEditing.sessionID == identity else { return "" }
            return composerEditing.text
        }

        var isEditable: Bool {
            guard !isRetired, !isDismantled, parent.isEditable else { return false }
            guard let composerEditing else { return true }
            return parent.composerIsActive && hasMatchingAttachment && composerEditing.ownsEditor
        }

        private var hasMatchingAttachment: Bool {
            guard let identity, let composerEditing else { return false }
            return composerEditing.sessionID == identity
                && composerEditing.nativeInstallationID == installationID
        }

        func matches(_ value: ResearchTextEditor) -> Bool {
            identity == value.identity && composerEditing === value.composerEditing
        }

        func install(_ editor: ResearchNativeTextView) {
            editor.editorIdentity = identity
            if editor.commands !== parent.commands { editor.commands?.unregister(editor) }
            editor.commands = parent.commands
            editor.isEditable = isEditable && (composerEditing == nil || editor.window != nil)
            if composerEditing != nil {
                if let submit = parent.onSubmit {
                    editor.onSubmit = { [weak self, weak editor] in
                        guard let self, let editor, self.isEditable, editor.window != nil,
                              editor.delegate === self, editor.editorIdentity == self.identity else { return }
                        submit()
                    }
                }
                if let pasteImage = parent.onPasteImage {
                    editor.onPasteImage = { [weak self, weak editor] data, name in
                        guard let self, let editor, self.isEditable, editor.window != nil,
                              editor.delegate === self, editor.editorIdentity == self.identity else { return }
                        pasteImage(data, name)
                    }
                }
            }
            editor.onWindowReady = { [weak self, weak editor] in
                guard let self, let editor else { return }
                editor.isEditable = self.isEditable && (self.composerEditing == nil || editor.window != nil)
                self.updateCommandsRegistration(editor)
                self.scheduleNativeAttach(editor)
            }
            if composerEditing != nil || parent.commands != nil {
                editor.onCommitCurrentText = { [weak self] value in self?.acceptNativeText(value) }
                updateCommandsRegistration(editor)
                if composerEditing == nil, !editor.hasMarkedText() {
                    parent.onExternalTextApplied?(editor.string)
                }
            } else { editor.onCommitCurrentText = nil }
            scheduleNativeAttach(editor)
        }

        private func updateCommandsRegistration(_ editor: ResearchNativeTextView) {
            if composerEditing == nil || (hasMatchingAttachment && isEditable
                && editor.isEditable && editor.window != nil
                && editor.delegate === self && editor.editorIdentity == identity) {
                parent.commands?.register(editor)
            } else { parent.commands?.unregister(editor) }
        }

        /// Attaching can publish shared ownership. Defer it until AppKit has
        /// installed this exact native host in a window, outside SwiftUI update.
        func scheduleNativeAttach(_ editor: ResearchNativeTextView) {
            cancelScheduledAttach()
            guard !isRetired, !isDismantled, parent.composerIsActive,
                  let identity, let composerEditing, editor.window != nil else { return }
            let generation = attachmentGeneration
            attachmentTask = Task { @MainActor [weak self, weak editor, weak composerEditing] in
                guard let self, let editor, let composerEditing, !Task.isCancelled,
                      self.attachmentGeneration == generation,
                      !self.isRetired, !self.isDismantled, self.parent.composerIsActive,
                      editor.delegate === self, editor.editorIdentity == identity,
                      editor.window != nil, self.composerEditing === composerEditing,
                      composerEditing.sessionID == identity else { return }
                // Only the fixed identity and weak native view belong to the
                // preparation closure retained by the shared editing owner.
                let attached = composerEditing.attachNativeHost(sessionID: identity,
                    installationID: self.installationID, prepareNativeInput: { [weak editor] in
                        guard let editor else { return true }
                        guard editor.editorIdentity == identity else { return false }
                        editor.commitCurrentText()
                        return !editor.hasMarkedText()
                    })
                editor.isEditable = attached && self.isEditable
                self.applyExternalText(to: editor)
                self.updateCommandsRegistration(editor)
                if self.attachmentGeneration == generation { self.attachmentTask = nil }
            }
        }

        private func cancelScheduledAttach() {
            attachmentTask?.cancel()
            attachmentTask = nil
            attachmentGeneration = UUID()
        }

        func applyExternalText(to editor: ResearchNativeTextView) {
            guard !isRetired, !isDismantled, editor.editorIdentity == identity else { return }
            if let composerEditing, let identity {
                // The same retained owner can already be bound to another
                // session. Its current text must never overwrite this host.
                guard hasMatchingAttachment else { return }
                let value = composerEditing.text
                if editor.applyExternalText(value) {
                    composerEditing.externalTextApplied(value, installationID: installationID, sessionID: identity)
                }
            } else if composerEditing == nil, editor.applyExternalText(parent.text) {
                parent.onExternalTextApplied?(parent.text)
            }
        }

        private func acceptNativeText(_ value: String) {
            if let composerEditing, let identity {
                // A stale host is archived by the core under its original
                // session and installation, never through a current Binding.
                _ = composerEditing.acceptNativeText(value, installationID: installationID, sessionID: identity)
            } else if composerEditing == nil { parent.text = value }
        }

        func retire(_ editor: ResearchNativeTextView) {
            guard !isRetired, !isDismantled else { return }
            cancelScheduledAttach()
            if editor.onCommitCurrentText != nil { editor.commitCurrentText() }
            isRetired = true
            editor.commands?.unregister(editor)
            editor.isEditable = false
            editor.onSubmit = nil
            editor.onPasteImage = nil
        }

        func dismantle(_ editor: ResearchNativeTextView) {
            guard !isDismantled else { return }
            cancelScheduledAttach()
            if editor.onCommitCurrentText != nil { editor.commitCurrentText() }
            if let composerEditing, let identity {
                _ = composerEditing.detachNativeHost(installationID: installationID, sessionID: identity)
            }
            isDismantled = true
            editor.commands?.unregister(editor)
            editor.onWindowReady = nil
            editor.onCommitCurrentText = nil
            editor.delegate = nil
            editor.isEditable = false
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? ResearchNativeTextView,
                  editor.delegate === self, editor.editorIdentity == identity else { return }
            if (composerEditing == nil || hasMatchingAttachment),
               (editor.undoManager?.isUndoing == true || editor.undoManager?.isRedoing == true) {
                parent.onEditingBoundary?()
            }
            acceptNativeText(editor.string)
            editor.needsDisplay = true
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let editor = notification.object as? ResearchNativeTextView,
                  editor.delegate === self, editor.editorIdentity == identity,
                  composerEditing == nil || hasMatchingAttachment else { return }
            parent.onEditingBoundary?()
        }
    }
}

class ResearchNativeTextView: NSTextView {
    var editorIdentity: UUID?
    weak var commands: ResearchTextEditingCommands?
    var onCommitCurrentText: ((String) -> Void)?
    var onWindowReady: (() -> Void)?
    var placeholder = ""
    var onSubmit: (() -> Void)?
    var onQuote: ((String) -> Void)?
    var onPasteImage: ((Data, String) -> Void)?
    private let researchUndoManager = UndoManager()

    override var undoManager: UndoManager? { researchUndoManager }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowReady?()
    }

    /// NSTextView registers edits with the overridden manager, but AppKit's
    /// standard undo:/redo: responder actions otherwise reach NSWindow's manager.
    /// Own those actions too so the Edit menu never targets PDF editing history.
    @objc func undo(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), researchUndoManager.canUndo else { return }
        breakUndoCoalescing()
        researchUndoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), researchUndoManager.canRedo else { return }
        breakUndoCoalescing()
        researchUndoManager.redo()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return isEditable && !hasMarkedText() && researchUndoManager.canUndo }
        if item.action == #selector(redo(_:)) { return isEditable && !hasMarkedText() && researchUndoManager.canRedo }
        return super.validateUserInterfaceItem(item)
    }

    /// Binding echoes of native typing must not clear Undo. A genuine external
    /// replacement (new draft, applied suggestion) establishes a fresh history.
    @discardableResult
    func applyExternalText(_ value: String) -> Bool {
        guard !hasMarkedText() else { return false }
        guard string != value else { return true }
        let previousSelection = selectedRange()
        breakUndoCoalescing()
        string = value
        researchUndoManager.removeAllActions()
        let length = (value as NSString).length
        setSelectedRange(NSRange(location: min(previousSelection.location, length), length: 0))
        return true
    }

    func commitCurrentText() {
        if hasMarkedText() { unmarkText() }
        onCommitCurrentText?(string)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty && !placeholder.isEmpty else { return }
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
            withAttributes: [.font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                             .foregroundColor: NSColor.placeholderTextColor])
    }

    override func keyDown(with event: NSEvent) {
        if handleEditorShortcut(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleEditorShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func handleEditorShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, isEditable, !hasMarkedText() else { return false }
        // Caps Lock and keypad metadata do not change the command's modifiers.
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if (event.keyCode == 36 || event.keyCode == 76), modifiers == .command, let onSubmit {
            onSubmit()
            return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "z" {
            if modifiers == .command { undo(nil); return true }
            if modifiers == [.command, .shift] { redo(nil); return true }
        }
        return false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if onQuote != nil && selectedRange().length > 0 {
            menu.addItem(.separator())
            let item = NSMenuItem(title: L10n.string("Quote and follow up"), action: #selector(quoteSelection), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func quoteSelection() {
        let selected = selectedRange()
        guard selected.location != NSNotFound, selected.length > 0,
              NSMaxRange(selected) <= (string as NSString).length else { return }
        onQuote?((string as NSString).substring(with: selected))
    }

    override func paste(_ sender: Any?) {
        if let onPasteImage, let image = Self.image(from: .general) {
            onPasteImage(image.data, image.name)
            return
        }
        super.paste(sender)
    }

    static func image(from pasteboard: NSPasteboard) -> (data: Data, name: String)? {
        if let data = pasteboard.data(forType: .png) { return (data, L10n.string("Pasted image.png")) }
        if let data = pasteboard.data(forType: .tiff) { return (data, L10n.string("Pasted image.tiff")) }
        return nil
    }
}

/// The actual drawing width follows the final frame, never a speculative
/// SwiftUI size proposal. This does not publish state or change the frame.
final class ResearchReadingTextView: ResearchNativeTextView {
    override func layout() {
        super.layout()
        let size = NSSize(width: max(1, bounds.width - 2 * textContainerInset.width),
                          height: .greatestFiniteMagnitude)
        if textContainer?.containerSize != size { textContainer?.containerSize = size }
    }
}

/// Read-only text participates directly in the outer scroll view's layout.
/// Measure synchronously at the proposed width: deferred height state updates
/// inside a lazy message row create a layout/scroll-offset feedback loop.
struct ResearchSelectableText: NSViewRepresentable {
    let text: String
    var sources: [ResearchSourceSnapshot] = []
    var evidence: [ResearchEvidence] = []
    var onViewEvidence: ((ResearchEvidence) -> Void)? = nil
    var onQuote: ((String) -> Void)? = nil
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ResearchNativeTextView {
        let view = Self.makeTextView(text: "", onQuote: onQuote)
        view.delegate = context.coordinator
        context.coordinator.update(view, parent: self)
        return view
    }

    func updateNSView(_ view: ResearchNativeTextView, context: Context) {
        context.coordinator.update(view, parent: self)
        view.onQuote = onQuote
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ResearchNativeTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return Self.measuredSize(of: nsView, width: width)
    }

    static func makeTextView(text: String, onQuote: ((String) -> Void)? = nil) -> ResearchNativeTextView {
        let view = ResearchReadingTextView(frame: .zero)
        view.isRichText = false
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 8, height: 8)
        // SwiftUI owns the frame; NSTextView must not resize itself or track a
        // transient frame width while SwiftUI is probing the proposed size.
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.heightTracksTextView = false
        view.textStorage?.setAttributedString(ResearchMarkdown.render(text))
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.onQuote = onQuote
        view.setAccessibilityLabel(L10n.string("Research text"))
        return view
    }

    static func measuredSize(of view: NSTextView, width: CGFloat) -> CGSize {
        guard let container = view.textContainer, let manager = view.layoutManager else {
            return CGSize(width: width, height: 40)
        }
        // SwiftUI probes several widths; a probe must not alter drawing layout.
        let previousSize = container.containerSize
        defer { container.containerSize = previousSize }
        container.containerSize = NSSize(width: max(1, width - 2 * view.textContainerInset.width),
                                         height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return CGSize(width: width, height: max(40, ceil(manager.usedRect(for: container).height
                                                       + 2 * view.textContainerInset.height)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ResearchSelectableText
        private var renderedText: String?
        private var renderedSources: [ResearchSourceSnapshot] = []
        private var renderedEvidence: [ResearchEvidence] = []
        init(_ parent: ResearchSelectableText) { self.parent = parent }

        func update(_ view: NSTextView, parent: ResearchSelectableText) {
            self.parent = parent
            guard renderedText != parent.text || renderedSources != parent.sources || renderedEvidence != parent.evidence else { return }
            let selection = view.selectedRange()
            view.textStorage?.setAttributedString(ResearchMarkdown.render(parent.text, sources: parent.sources, evidence: parent.evidence))
            view.setSelectedRange(NSRange(location: min(selection.location, (view.string as NSString).length), length: 0))
            view.needsLayout = true
            renderedText = parent.text; renderedSources = parent.sources; renderedEvidence = parent.evidence
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return true }
            switch ResearchLinkTarget(url: url) {
            case .evidence(let id):
                if let evidence = parent.evidence.first(where: { $0.id == id }) {
                    parent.onViewEvidence?(evidence)
                }
            case .web(let url): parent.openURL(url)
            case .unsupported: break
            }
            return true
        }
    }
}
