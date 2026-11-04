#if os(iOS)
import Combine
import SwiftUI
import UIKit

/// Touch commands target the native field that owns focus. Each field's Undo
/// remains independent of PDF mutations and of other notes or sessions.
@MainActor
final class IPadResearchTextEditingCommands: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var hasMarkedText = false
    private weak var editor: IPadResearchNativeTextView?

    func register(_ editor: IPadResearchNativeTextView) {
        if self.editor == nil || self.editor?.editorIdentity != editor.editorIdentity {
            // Installation during SwiftUI rendering must not publish state.
            self.editor = editor
            editor.scheduleCommandRefresh()
        }
    }

    func activate(_ editor: IPadResearchNativeTextView) {
        self.editor = editor
        refresh(editor)
    }

    func refresh(_ editor: IPadResearchNativeTextView) {
        guard self.editor === editor else { return }
        let marked = editor.markedTextRange != nil
        let undo = editor.isEditable && !marked && editor.undoManager?.canUndo == true
        let redo = editor.isEditable && !marked && editor.undoManager?.canRedo == true
        if hasMarkedText != marked { hasMarkedText = marked }
        if canUndo != undo { canUndo = undo }
        if canRedo != redo { canRedo = redo }
    }

    func undo() { editor?.performNativeUndo(); if let editor { refresh(editor) } }
    func redo() { editor?.performNativeRedo(); if let editor { refresh(editor) } }

    /// Touch Send explicitly finishes composition and commits through the
    /// field's captured binding before the caller freezes its request.
    @discardableResult
    func commitMarkedTextAndEndEditing(identity: UUID) -> Bool {
        guard let editor else { return true }
        guard editor.editorIdentity == identity else { return false }
        editor.commitCurrentText()
        _ = editor.resignFirstResponder()
        editor.onTextChanged?(editor.text ?? "")
        refresh(editor)
        return true
    }

    func unregister(_ editor: IPadResearchNativeTextView) {
        guard self.editor === editor else { return }
        self.editor = nil
        Task { @MainActor [weak self] in
            guard let self, self.editor == nil else { return }
            if self.canUndo { self.canUndo = false }
            if self.canRedo { self.canRedo = false }
            if self.hasMarkedText { self.hasMarkedText = false }
        }
    }
}

@MainActor
final class IPadResearchNativeTextView: UITextView {
    static let selectionDidChangeNotification = Notification.Name("Dogear.NativeTextSelectionDidChange")
    private let noteUndoManager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    private struct TextSnapshot {
        let text: String
        let selection: NSRange
    }
    private var recordedSnapshot: TextSnapshot?
    private var pendingEditSnapshot: TextSnapshot?
    private var compositionSnapshot: TextSnapshot?
    private var nativeInputDepth = 0
    var onEditingBoundary: (() -> Void)?
    var onTextChanged: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    var onWindowReady: (() -> Void)?
    var editorIdentity = UUID()
    weak var commands: IPadResearchTextEditingCommands?

    override var undoManager: UndoManager? { noteUndoManager }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onWindowReady?() }
    }

    override func insertText(_ text: String) {
        performNativeInput { super.insertText(text) }
    }

    override func deleteBackward() {
        performNativeInput { super.deleteBackward() }
    }

    override func replace(_ range: UITextRange, withText text: String) {
        performNativeInput { super.replace(range, withText: text) }
    }

    override func paste(_ sender: Any?) {
        performNativeInput { super.paste(sender) }
    }

    func prepareNativeEdit() {
        if pendingEditSnapshot == nil { pendingEditSnapshot = snapshot() }
    }

    /// UITextView does not populate a substituted responder UndoManager on all
    /// input paths. Register accepted native text changes explicitly; PDF and
    /// Research persistence stay outside this field's transient editing history.
    func recordNativeEdit() {
        guard nativeInputDepth == 0, !noteUndoManager.isUndoing, !noteUndoManager.isRedoing,
              markedTextRange == nil else { return }
        let current = snapshot()
        let previous = compositionSnapshot ?? pendingEditSnapshot ?? recordedSnapshot
        pendingEditSnapshot = nil
        compositionSnapshot = nil
        recordedSnapshot = current
        guard let previous, previous.text != current.text else { return }
        registerUndo(previous)
    }

    private func snapshot() -> TextSnapshot {
        .init(text: text ?? "", selection: selectedRange)
    }

    private func registerUndo(_ snapshot: TextSnapshot) {
        let needsGroup = !noteUndoManager.isUndoing && !noteUndoManager.isRedoing
        if needsGroup { noteUndoManager.beginUndoGrouping() }
        noteUndoManager.registerUndo(withTarget: self) { editor in editor.restore(snapshot) }
        if needsGroup { noteUndoManager.endUndoGrouping() }
    }

    private func restore(_ value: TextSnapshot) {
        registerUndo(snapshot())
        noteUndoManager.disableUndoRegistration()
        // Replace through UITextInput so UIKit keeps its editing installation;
        // assigning .text is reserved for a genuine external history reset.
        if let range = textRange(from: beginningOfDocument, to: endOfDocument) {
            super.replace(range, withText: value.text)
        } else {
            textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: value.text)
        }
        let length = (value.text as NSString).length
        let location = min(value.selection.location, length)
        selectedRange = NSRange(location: location, length: min(value.selection.length, length - location))
        noteUndoManager.enableUndoRegistration()
        recordedSnapshot = snapshot()
        pendingEditSnapshot = nil
        compositionSnapshot = nil
        onTextChanged?(text ?? "")
        scheduleCommandRefresh()
    }

    private func performNativeInput(_ operation: () -> Void) {
        let outermost = nativeInputDepth == 0
        if outermost {
            prepareNativeEdit()
            // This field owns one history. Suppress any UIKit registration
            // during native mutation before recording its accepted result.
            noteUndoManager.disableUndoRegistration()
        }
        nativeInputDepth += 1
        operation()
        nativeInputDepth -= 1
        if outermost {
            noteUndoManager.enableUndoRegistration()
            recordNativeEdit()
            onTextChanged?(text ?? "")
            scheduleCommandRefresh()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        var result = super.keyCommands ?? []
        let undo = UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoResearchText))
        let redo = UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoResearchText))
        undo.wantsPriorityOverSystemBehavior = true
        redo.wantsPriorityOverSystemBehavior = true
        result += [undo, redo]
        if onSubmit != nil {
            result.append(UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(submitResearch)))
        }
        return result
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(undoResearchText) {
            return isEditable && markedTextRange == nil && noteUndoManager.canUndo
        }
        if action == #selector(redoResearchText) {
            return isEditable && markedTextRange == nil && noteUndoManager.canRedo
        }
        if action == #selector(submitResearch) { return isEditable && markedTextRange == nil && onSubmit != nil }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func undoResearchText() { performNativeUndo(); commands?.refresh(self) }
    @objc func redoResearchText() { performNativeRedo(); commands?.refresh(self) }

    @objc func submitResearch() {
        guard isEditable, markedTextRange == nil, let onSubmit else { return }
        onTextChanged?(text ?? "")
        onEditingBoundary?()
        onSubmit()
    }

    func commitCurrentText() {
        if markedTextRange != nil { unmarkText() }
        onTextChanged?(text ?? "")
        onEditingBoundary?()
    }

    func performNativeUndo() {
        guard isEditable, markedTextRange == nil, noteUndoManager.canUndo else { return }
        onEditingBoundary?()
        noteUndoManager.undo()
        onTextChanged?(text ?? "")
    }

    func performNativeRedo() {
        guard isEditable, markedTextRange == nil, noteUndoManager.canRedo else { return }
        onEditingBoundary?()
        noteUndoManager.redo()
        onTextChanged?(text ?? "")
    }

    /// Store echoes retain native Undo/selection. A genuine replacement, such
    /// as applying a suggestion, creates a new native editing history.
    @discardableResult
    func applyExternalText(_ value: String) -> Bool {
        guard markedTextRange == nil else { return false }
        guard text != value else { return true }
        let selection = selectedRange
        text = value
        noteUndoManager.removeAllActions()
        selectedRange = NSRange(location: min(selection.location, (value as NSString).length), length: 0)
        recordedSnapshot = snapshot()
        pendingEditSnapshot = nil
        compositionSnapshot = nil
        return true
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        if compositionSnapshot == nil { compositionSnapshot = snapshot() }
        performNativeInput { super.setMarkedText(markedText, selectedRange: selectedRange) }
    }

    override func unmarkText() {
        performNativeInput { super.unmarkText() }
    }

    func scheduleCommandRefresh() {
        // updateUIView can replace text. Publish command availability only after
        // that native update returns; the active editor check drops old events.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.commands?.refresh(self)
        }
    }
}

@MainActor
struct IPadResearchTextEditorPresentation {
    var font: UIFont
    var textColor: UIColor
    var textContainerInset: UIEdgeInsets = .zero
    var lineFragmentPadding: CGFloat = 0
    var isScrollEnabled = true
    var textAlignment: NSTextAlignment = .left
    var autofocus = false
}

@MainActor
struct IPadResearchNativeTextEditor: UIViewRepresentable {
    @Binding var text: String
    let commands: IPadResearchTextEditingCommands
    let identity: UUID
    var isEditable = true
    var isTitle = false
    var accessibilityLabel: String? = nil
    var presentation: IPadResearchTextEditorPresentation? = nil
    var onEditingBoundary: (() -> Void)?
    var onSubmit: (() -> Void)?
    var onExternalTextApplied: ((String) -> Void)?
    var composerEditing: ResearchComposerEditingSession?
    var composerIsActive = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> IPadResearchNativeTextView {
        let editor = IPadResearchNativeTextView(frame: .zero)
        editor.backgroundColor = .clear
        editor.font = isTitle ? .preferredFont(forTextStyle: .headline) : .preferredFont(forTextStyle: .body)
        editor.adjustsFontForContentSizeCategory = true
        editor.isScrollEnabled = !isTitle
        editor.textContainerInset = UIEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
        context.coordinator.install(editor)
        return editor
    }

    func updateUIView(_ editor: IPadResearchNativeTextView, context: Context) {
        guard context.coordinator.identity == identity else {
            // Callers use .id(identity). If a host reuses an installation anyway,
            // commit to its old binding and refuse a redirected native writer.
            editor.commitCurrentText()
            _ = context.coordinator.parent.composerEditing?.detachNativeHost(
                installationID: context.coordinator.installationID, sessionID: context.coordinator.identity)
            editor.commands?.unregister(editor)
            editor.isEditable = false
            return
        }
        context.coordinator.parent = self
        context.coordinator.install(editor)
        editor.scheduleCommandRefresh()
    }

    static func dismantleUIView(_ editor: IPadResearchNativeTextView, coordinator: Coordinator) {
        coordinator.invalidateFocus()
        // This coordinator still owns the old identity/binding. A late IME
        // completion is committed there before the view loses its delegates.
        editor.commitCurrentText()
        _ = coordinator.parent.composerEditing?.detachNativeHost(installationID: coordinator.installationID, sessionID: coordinator.identity)
        editor.commands?.unregister(editor)
        editor.delegate = nil
        editor.onTextChanged = nil
        editor.onSubmit = nil
        editor.onWindowReady = nil
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        func textViewDidChangeSelection(_ textView: UITextView) {
            NotificationCenter.default.post(name: IPadResearchNativeTextView.selectionDidChangeNotification, object: textView)
        }
        var parent: IPadResearchNativeTextEditor
        let identity: UUID
        let installationID = UUID()
        private var composerAttachScheduled = false
        private var focusScheduled = false
        private var didAttemptInitialFocus = false
        private var isDismantled = false
        init(_ parent: IPadResearchNativeTextEditor) {
            self.parent = parent; identity = parent.identity
            parent.composerEditing?.reserveNativeHost(sessionID: identity, installationID: installationID)
        }

        func invalidateFocus() { isDismantled = true }

        func install(_ editor: IPadResearchNativeTextView) {
            editor.delegate = self
            editor.commands = parent.commands
            editor.editorIdentity = parent.identity
            editor.isEditable = parent.isEditable && (parent.composerEditing == nil
                || (parent.composerEditing?.nativeInstallationID == installationID && parent.composerEditing?.ownsEditor == true))
            editor.accessibilityLabel = parent.accessibilityLabel ?? L10n.string(parent.isTitle ? "Note title" : "Research note")
            if let presentation = parent.presentation {
                editor.font = presentation.font
                editor.textColor = presentation.textColor
                editor.adjustsFontForContentSizeCategory = false
                editor.textContainerInset = presentation.textContainerInset
                editor.textContainer.lineFragmentPadding = presentation.lineFragmentPadding
                editor.isScrollEnabled = presentation.isScrollEnabled
                editor.textAlignment = presentation.textAlignment
            }
            editor.onWindowReady = { [weak self, weak editor] in
                guard let editor else { return }
                self?.scheduleInitialFocus(editor)
                self?.scheduleComposerAttach(editor)
            }
            editor.onEditingBoundary = parent.onEditingBoundary
            if parent.onSubmit != nil {
                editor.onSubmit = { [weak self] in
                    guard let self else { return }
                    if let owner = self.parent.composerEditing {
                        guard self.parent.composerIsActive, owner.ownsEditor,
                              owner.sessionID == self.identity,
                              owner.nativeInstallationID == self.installationID else { return }
                    }
                    self.parent.onSubmit?()
                }
            } else { editor.onSubmit = nil }
            editor.onTextChanged = { [weak self] value in self?.accept(value) }
            if editor.applyExternalText(parent.text) {
                if let owner = parent.composerEditing {
                    owner.externalTextApplied(parent.text, installationID: installationID, sessionID: identity)
                } else { parent.onExternalTextApplied?(parent.text) }
            }
            parent.commands.register(editor)
            scheduleComposerAttach(editor)
            scheduleInitialFocus(editor)
        }

        private func scheduleInitialFocus(_ editor: IPadResearchNativeTextView) {
            guard !isDismantled, parent.presentation?.autofocus == true, !didAttemptInitialFocus, !focusScheduled else { return }
            focusScheduled = true
            Task { @MainActor [weak self, weak editor] in
                guard let self else { return }
                self.focusScheduled = false
                guard let editor, !self.isDismantled, editor.delegate === self,
                      self.parent.presentation?.autofocus == true,
                      self.parent.identity == self.identity, editor.editorIdentity == self.identity,
                      editor.isEditable, let window = editor.window, !window.isHidden, window.isKeyWindow else { return }
                self.didAttemptInitialFocus = true
                let windows = window.windowScene?.windows ?? [window]
                guard !windows.contains(where: { self.hasOtherMarkedInput(in: $0, except: editor) }) else { return }
                _ = editor.becomeFirstResponder()
            }
        }

        private func hasOtherMarkedInput(in view: UIView, except editor: UITextView) -> Bool {
            if view !== editor, view.isFirstResponder,
               let input = view as? UITextInput, input.markedTextRange != nil { return true }
            return view.subviews.contains { hasOtherMarkedInput(in: $0, except: editor) }
        }

        private func accept(_ value: String) {
            if let owner = parent.composerEditing {
                _ = owner.acceptNativeText(value, installationID: installationID, sessionID: identity)
            } else if parent.text != value { parent.text = value }
        }

        private func scheduleComposerAttach(_ editor: IPadResearchNativeTextView) {
            guard let owner = parent.composerEditing, parent.composerIsActive,
                  !isDismantled, !composerAttachScheduled else { return }
            composerAttachScheduled = true
            Task { @MainActor [weak self, weak editor, weak owner] in
                guard let self else { return }
                self.composerAttachScheduled = false
                guard let editor, let owner, !self.isDismantled, self.parent.composerIsActive,
                      self.parent.composerEditing === owner, editor.delegate === self,
                      editor.editorIdentity == self.identity, editor.window != nil else { return }
                let capturedIdentity = self.identity
                let attached = owner.attachNativeHost(sessionID: capturedIdentity, installationID: self.installationID,
                    prepareNativeInput: { [weak editor] in
                        guard let editor, editor.editorIdentity == capturedIdentity else { return true }
                        editor.commitCurrentText()
                        _ = editor.resignFirstResponder()
                        return true
                    })
                guard !self.isDismantled else { return }
                editor.isEditable = attached && self.parent.isEditable && owner.ownsEditor
                    && owner.nativeInstallationID == self.installationID
                if attached, editor.applyExternalText(owner.text) {
                    owner.externalTextApplied(owner.text, installationID: self.installationID, sessionID: self.identity)
                }
                editor.scheduleCommandRefresh()
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            guard let editor = textView as? IPadResearchNativeTextView else { return }
            parent.commands.activate(editor)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let editor = textView as? IPadResearchNativeTextView else { return }
            if editor.undoManager?.isUndoing == true || editor.undoManager?.isRedoing == true {
                parent.onEditingBoundary?()
            }
            editor.recordNativeEdit()
            accept(editor.text ?? "")
            editor.scheduleCommandRefresh()
        }

        func textViewDidEndEditing(_ textView: UITextView) { parent.onEditingBoundary?() }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard !parent.isTitle || text != "\n" else { return false }
            (textView as? IPadResearchNativeTextView)?.prepareNativeEdit()
            return true
        }
    }
}
#endif
