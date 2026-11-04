#if os(iOS)
import SwiftUI
import UIKit
import Combine

/// Uses the real UIKit text system and ResearchStore with disposable notes.
/// No provider, production defaults, user document or PDF Undo is accessed.
@MainActor
enum IPadResearchTextEditorDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearIPadText-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ResearchStore(rootURL: root)
        let noteID = storage.createNote(title: "中文标题", body: "起点：苹果根系。")
        let otherID = storage.createNote(title: "Other note", body: "Independent text")
        let owner = UUID()
        expect(storage.claimNoteEditor(noteID: noteID, editorID: owner) == owner,
               "The note editor claims the actual shared editing lease.")
        defer { storage.releaseNoteEditor(noteID: noteID, editorID: owner) }
        let commands = IPadResearchTextEditingCommands()
        let binding = noteBinding(storage: storage, noteID: noteID, keyPath: \.body)
        let input = IPadResearchNativeTextEditor(text: binding, commands: commands, identity: noteID,
            onEditingBoundary: { storage.endNoteEditBurst(noteID: noteID) })
        let coordinator = IPadResearchNativeTextEditor.Coordinator(input)
        let native = IPadResearchNativeTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 240))
        coordinator.install(native)

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previousWindow = scene?.windows.first(where: \.isKeyWindow)
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: native.frame)
        let controller = UIViewController()
        controller.view.addSubview(native)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        native.becomeFirstResponder()
        commands.activate(native)
        await settleNativeEditing()
        expect(native.isFirstResponder && native.window === window,
               "The real text fixture owns native focus before typing and Undo.")
        defer {
            IPadResearchNativeTextEditor.dismantleUIView(native, coordinator: coordinator)
            window.isHidden = true
            previousWindow?.makeKey()
        }

        var commandPublications = 0
        let commandObservation = commands.objectWillChange.sink { commandPublications += 1 }
        commands.refresh(native)
        commands.refresh(native)
        expect(commandPublications == 0,
               "Unchanged native command state does not create a SwiftUI update loop.")
        withExtendedLifetime(commandObservation) {}

        let initial = binding.wrappedValue
        native.selectedRange = NSRange(location: (initial as NSString).length, length: 0)
        native.insertText(" 追加中文。")
        coordinator.textViewDidChange(native)
        // Native keyboard edits and touch commands are separate event turns.
        // Let UIKit close its own typing group instead of replacing its grouping
        // policy and invoking Undo while that insertion is still being processed.
        await settleNativeEditing()
        commands.refresh(native)
        let typed = binding.wrappedValue
        expect(typed == initial + " 追加中文。" && native.text == typed,
               "Native Chinese typing commits to the captured Research note.")
        expect(commands.canUndo && native.undoManager?.canUndo == true,
               "Touch Undo exposes the current native text history.")
        let selection = native.selectedRange
        native.applyExternalText(typed)
        expect(native.undoManager?.canUndo == true && native.selectedRange == selection,
               "A shared Store echo preserves native Undo and selection.")
        commands.undo()
        await settleNativeEditing()
        commands.refresh(native)
        expect(native.text == initial && binding.wrappedValue == initial,
               "Touch Undo updates both the real text view and durable note. Native=\(native.text ?? ""), stored=\(binding.wrappedValue), grouping=\(native.undoManager?.groupingLevel ?? -1)")
        expect(commands.canRedo, "Native Undo exposes touch Redo.")
        expect(native.selectedRange == NSRange(location: (initial as NSString).length, length: 0),
               "Native text Undo restores the exact pre-edit selection.")
        commands.redo()
        await settleNativeEditing()
        commands.refresh(native)
        expect(native.text == typed && binding.wrappedValue == typed,
               "Touch Redo restores the same Chinese text through the shared Store.")

        var submissions = 0
        native.onSubmit = { submissions += 1 }
        native.selectedRange = NSRange(location: (typed as NSString).length, length: 0)
        native.setMarkedText("组合输入", selectedRange: NSRange(location: 4, length: 0))
        let markedText = native.text
        expect(native.markedTextRange != nil, "The fixture creates an actual UIKit marked-text range.")
        native.submitResearch()
        expect(submissions == 0, "Command-Return refuses to send during marked-text composition.")
        commands.undo()
        expect(native.text == markedText && native.markedTextRange != nil,
               "Touch Undo does not destroy active Chinese composition.")
        native.applyExternalText("External replacement")
        expect(native.text == markedText, "A model replacement cannot overwrite marked text.")
        expect(!commands.commitMarkedTextAndEndEditing(identity: otherID) && native.markedTextRange != nil,
               "A different session identity cannot commit the active field.")
        expect(commands.commitMarkedTextAndEndEditing(identity: noteID) && native.markedTextRange == nil
               && binding.wrappedValue == native.text && binding.wrappedValue.contains("组合输入"),
               "Touch Send commits composition synchronously to its captured identity.")
        native.submitResearch()
        expect(submissions == 1, "Command-Return sends once after composition has finished.")
        let composed = binding.wrappedValue
        commands.undo()
        expect(native.text == typed && binding.wrappedValue == typed,
               "A committed Chinese composition is one native Undo action.")
        commands.redo()
        expect(native.text == composed && binding.wrappedValue == composed,
               "Native Redo restores the complete composed phrase and durable note.")
        native.undoResearchText()
        expect(native.text == typed && binding.wrappedValue == typed,
               "The native keyboard Undo action uses the same isolated text history.")
        native.redoResearchText()
        expect(native.text == composed && binding.wrappedValue == composed,
               "The native keyboard Redo action restores the full committed composition.")

        native.applyExternalText("Applied suggestion")
        expect(native.undoManager?.canUndo == false && native.undoManager?.canRedo == false,
               "A genuine external replacement clears obsolete native history.")

        let otherBinding = noteBinding(storage: storage, noteID: otherID, keyPath: \.body)
        let otherInput = IPadResearchNativeTextEditor(text: otherBinding, commands: commands, identity: otherID)
        let otherCoordinator = IPadResearchNativeTextEditor.Coordinator(otherInput)
        let otherNative = IPadResearchNativeTextView(frame: native.frame)
        otherCoordinator.install(otherNative)
        commands.activate(otherNative)
        native.text = "Late old-note completion"
        coordinator.textViewDidChange(native)
        expect(binding.wrappedValue == "Late old-note completion" && otherBinding.wrappedValue == "Independent text",
               "A late native callback remains bound to the old note UUID.")
        native.setMarkedText("保留", selectedRange: NSRange(location: 2, length: 0))
        let finalOldText = native.text
        IPadResearchNativeTextEditor.dismantleUIView(native, coordinator: coordinator)
        expect(binding.wrappedValue == finalOldText && native.markedTextRange == nil,
               "Unmounting commits old-note composition before revoking its delegate.")
        expect(commands.commitMarkedTextAndEndEditing(identity: otherID),
               "Unmounting an old note cannot revoke the newer native editor.")
        expect(otherBinding.wrappedValue == "Independent text",
               "Old-note unmount does not redirect text into a new note.")
        IPadResearchNativeTextEditor.dismantleUIView(otherNative, coordinator: otherCoordinator)

        let titleCommands = IPadResearchTextEditingCommands()
        let titleInput = IPadResearchNativeTextEditor(
            text: noteBinding(storage: storage, noteID: noteID, keyPath: \.title),
            commands: titleCommands, identity: noteID, isTitle: true)
        let titleCoordinator = IPadResearchNativeTextEditor.Coordinator(titleInput)
        let titleNative = IPadResearchNativeTextView(frame: native.frame)
        titleCoordinator.install(titleNative)
        expect(titleNative.undoManager !== native.undoManager,
               "Title and body keep separate native Undo histories.")
        expect(!titleCoordinator.textView(titleNative, shouldChangeTextIn: .init(location: 0, length: 0), replacementText: "\n"),
               "A title field rejects native Return as a multiline edit.")
        titleNative.isEditable = false
        titleCommands.activate(titleNative)
        expect(!titleCommands.canUndo && !titleCommands.canRedo,
               "A read-only note lease cannot expose mutation commands.")
        IPadResearchNativeTextEditor.dismantleUIView(titleNative, coordinator: titleCoordinator)

        let reload = ResearchStore(rootURL: root)
        expect(reload.note(id: noteID)?.body == storage.note(id: noteID)?.body
               && reload.note(id: otherID)?.body == "Independent text",
               "Native typing, Undo and composition survive actual Research reload.")
        expect(storage.note(id: noteID)?.revisions.contains(where: { $0.body == initial }) == true,
               "The note history keeps the original text through native Undo boundaries.")
        exerciseRestoredInput(storage: storage, hostView: controller.view, expect: expect)
        await Task.yield()
        return (checks, failures)
    }

    private static func noteBinding(storage: ResearchStore, noteID: UUID,
                                    keyPath: WritableKeyPath<ResearchNote, String>) -> Binding<String> {
        Binding(get: { storage.note(id: noteID)?[keyPath: keyPath] ?? "" }, set: { text in
            guard var note = storage.note(id: noteID), note[keyPath: keyPath] != text else { return }
            note[keyPath: keyPath] = text
            _ = storage.updateNote(note, coalescingEdits: true)
        })
    }

    private static func settleNativeEditing() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    private static func exerciseRestoredInput(storage: ResearchStore, hostView: UIView, expect: (Bool, String) -> Void) {
        let sessionID = storage.createSession(title: "Composition restoration")
        let otherID = storage.createSession(title: "Independent session")
        _ = storage.saveDraft(ResearchDraft(text: "Current draft "), sessionID: sessionID)
        _ = storage.saveDraft(ResearchDraft(text: "Other draft"), sessionID: otherID)
        let binding = Binding<String>(get: { storage.session(id: sessionID)?.draft.text ?? "" }, set: { text in
            guard var draft = storage.session(id: sessionID)?.draft else { return }
            draft.text = text
            _ = storage.saveDraft(draft, sessionID: sessionID)
        })
        let commands = IPadResearchTextEditingCommands()
        var submittedText: String?
        var requestID: UUID?
        let input = IPadResearchNativeTextEditor(text: binding, commands: commands, identity: sessionID,
            onSubmit: {
                guard let draft = storage.session(id: sessionID)?.draft else { return }
                submittedText = draft.text
                requestID = storage.beginRequest(sessionID: sessionID, question: draft.text,
                    sourceSnapshot: [], input: draft)
            })
        let coordinator = IPadResearchNativeTextEditor.Coordinator(input)
        let native = IPadResearchNativeTextView(frame: .init(x: 0, y: 0, width: 300, height: 100))
        coordinator.install(native)
        hostView.addSubview(native)
        defer { native.removeFromSuperview() }
        native.becomeFirstResponder()
        commands.activate(native)
        native.selectedRange = NSRange(location: (binding.wrappedValue as NSString).length, length: 0)
        native.setMarkedText("中文", selectedRange: .init(location: 2, length: 0))
        expect(native.markedTextRange != nil, "Restore input fixture uses an actual native composition.")
        expect(commands.commitMarkedTextAndEndEditing(identity: sessionID),
               "Restore input commits composition to its captured session before merging.")
        var restored = storage.session(id: sessionID)?.draft ?? ResearchDraft()
        restored.text += "\nRestored request text"
        _ = storage.saveDraft(restored, sessionID: sessionID)
        coordinator.install(native)
        expect(native.text == restored.text && native.markedTextRange == nil,
               "The native external echo installs the actual merged Research draft.")
        _ = commands.commitMarkedTextAndEndEditing(identity: sessionID)
        expect(storage.session(id: sessionID)?.draft.text == restored.text,
               "Later native commit cannot overwrite the restored request text.")
        native.submitResearch()
        expect(submittedText == restored.text && submittedText?.contains("中文") == true,
               "Native Send captures the actual restored draft after Chinese composition commits.")
        expect(requestID != nil && storage.session(id: sessionID)?.messages.last?.input.text == restored.text,
               "The real Research request persists the restored text rather than the pre-restore native buffer.")
        native.text = restored.text + " late old-session edit"
        coordinator.textViewDidChange(native)
        expect(storage.session(id: sessionID)?.draft.text == native.text
               && storage.session(id: otherID)?.draft.text == "Other draft",
               "A restored old-session callback cannot redirect into a newer session.")
        expect(storage.session(id: sessionID)?.messages.last?.input.text == restored.text,
               "A late old-session input callback cannot rewrite the frozen request input.")
        if let requestID {
            _ = storage.finishRequest(sessionID: sessionID, requestID: requestID, status: .cancelled, origin: .user)
        }
        IPadResearchNativeTextEditor.dismantleUIView(native, coordinator: coordinator)
    }
}
#endif
