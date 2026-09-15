import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A native text system keeps IME composition, selection, paste and editor Undo independent of PDF editing.
struct ResearchTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    var placeholder = ""
    var onSubmit: (() -> Void)? = nil
    var onQuote: ((String) -> Void)? = nil
    var onPasteImage: ((Data, String) -> Void)? = nil
    var onEditingBoundary: (() -> Void)? = nil

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
        editor.isEditable = isEditable
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
        editor.string = text
        editor.placeholder = placeholder
        editor.onSubmit = onSubmit
        editor.onQuote = onQuote
        editor.onPasteImage = onPasteImage
        editor.setAccessibilityLabel(placeholder.isEmpty ? L10n.string("Research text") : placeholder)
        scrollView.documentView = editor
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scrollView.documentView as? ResearchNativeTextView else { return }
        editor.isEditable = isEditable
        editor.placeholder = placeholder
        editor.onSubmit = onSubmit
        editor.onQuote = onQuote
        editor.onPasteImage = onPasteImage
        editor.applyExternalText(text)
        editor.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ResearchTextEditor
        init(_ parent: ResearchTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? ResearchNativeTextView else { return }
            if editor.undoManager?.isUndoing == true || editor.undoManager?.isRedoing == true {
                parent.onEditingBoundary?()
            }
            parent.text = editor.string
            editor.needsDisplay = true
        }

        func textDidEndEditing(_ notification: Notification) { parent.onEditingBoundary?() }
    }
}

class ResearchNativeTextView: NSTextView {
    var placeholder = ""
    var onSubmit: (() -> Void)?
    var onQuote: ((String) -> Void)?
    var onPasteImage: ((Data, String) -> Void)?
    private let researchUndoManager = UndoManager()

    override var undoManager: UndoManager? { researchUndoManager }

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
    func applyExternalText(_ value: String) {
        guard string != value, !hasMarkedText() else { return }
        let previousSelection = selectedRange()
        breakUndoCoalescing()
        string = value
        researchUndoManager.removeAllActions()
        let length = (value as NSString).length
        setSelectedRange(NSRange(location: min(previousSelection.location, length), length: 0))
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
            if url.scheme == "dogear-evidence", let host = url.host, let id = UUID(uuidString: host),
               let evidence = parent.evidence.first(where: { $0.id == id }) {
                parent.onViewEvidence?(evidence)
            } else if ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return true
        }
    }
}
