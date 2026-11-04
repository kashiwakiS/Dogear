// Isolated production-sheet diagnostics. The dedicated application entry point
// does not construct user Library or workspace scenes.
// This mounts the production FreeTextEditorSheet. Its controlled onSave=false
// injection tests the presentation contract, not an actual disk-failure path.
// No real OS Chinese input, Cancel confirmation, Highlight sheet, or
// GroupWorkspaceHost close behavior is claimed by this probe.
#if os(macOS)
import AppKit
import Combine
import PDFKit
import SwiftUI

@MainActor
enum MacAnnotationSheetDiagnostics {
    struct Report {
        var checks: Int
        var failures: [String]
        var observations: [String]
    }

    private final class Model: ObservableObject {
        let store: PDFDocumentStore
        @Published var draft: FreeTextEditDraft?
        @Published var rejectSave = false
        var saveCalls = 0

        init(store: PDFDocumentStore, draft: FreeTextEditDraft) {
            self.store = store
            self.draft = draft
        }
    }

    private struct Root: View {
        @ObservedObject var model: Model

        var body: some View {
            Color.clear
                .frame(width: 700, height: 760)
                .sheet(item: $model.draft) { draft in
                    FreeTextEditorSheet(
                        draft: draft,
                        onSave: { values in
                            model.saveCalls += 1
                            guard !model.rejectSave else { return false }
                            return model.store.saveFreeText(draft, values: values)
                        },
                        onDismiss: { model.draft = nil }
                    )
                }
                .environment(\.locale, Locale(identifier: "en"))
        }
    }

    private static func editor(in view: NSView) -> ResearchNativeTextView? {
        if let editor = view as? ResearchNativeTextView { return editor }
        for child in view.subviews {
            if let editor = editor(in: child) { return editor }
        }
        return nil
    }

    private static func settle(_ window: NSWindow) async {
        for _ in 0..<4 {
            window.contentView?.layoutSubtreeIfNeeded()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    static func run() async -> Report {
        var checks = 0
        var failures: [String] = []
        var observations: [String] = []

        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }

        guard MacAnnotationEditorLifecycle.unfinishedWindow == nil else {
            return Report(checks: 1,
                failures: ["An existing unfinished editor prevents an isolated run."],
                observations: [])
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DogearMacSheetProbe-\(UUID())")
        let suite = "DogearMacSheetProbe.\(UUID())"

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let defaults = UserDefaults(suiteName: suite) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }

            let source = PDFDocument()
            let sourcePage = PDFPage()
            sourcePage.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox)
            source.insert(sourcePage, at: 0)
            let note = PDFAnnotation(bounds: CGRect(x: 80, y: 500, width: 240, height: 120),
                forType: .freeText, withProperties: nil)
            note.contents = "Probe baseline"
            note.font = .systemFont(ofSize: 14)
            note.fontColor = .black
            sourcePage.addAnnotation(note)
            guard let data = source.dataRepresentation() else { throw CocoaError(.fileReadCorruptFile) }
            let sourceURL = directory.appendingPathComponent("source.pdf")
            try data.write(to: sourceURL)

            let queue = PDFSaveQueue(recoveryDirectoryURL: directory.appendingPathComponent("recovery"))
            let access = DocumentAccessCoordinator(saveQueue: queue)
            let store = PDFDocumentStore(
                feedbackCenter: OperationFeedbackCenter(userDefaults: defaults),
                metadataStore: DocumentMetadataStore(stateURL: directory.appendingPathComponent("metadata.json")),
                aiHighlightGroupStore: AIHighlightGroupStore(stateURL: directory.appendingPathComponent("groups.json")),
                workingCopyStore: try PDFWorkingCopyStore(directoryURL: directory.appendingPathComponent("copies")),
                saveQueue: queue, accessCoordinator: access)
            defer { store.releaseEditorAccess(); queue.waitUntilDrained() }
            guard store.openPDF(from: sourceURL), let document = store.document,
                  let page = document.page(at: 0),
                  let annotation = page.annotations.first(where: { $0.type == "FreeText" }) else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let documentUndo = UndoManager()
            documentUndo.groupsByEvent = false
            store.setUndoManager(documentUndo)
            let draft = FreeTextEditDraft(document: document, page: page, annotation: annotation)
            let model = Model(store: store, draft: draft)
            let parent = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 700, height: 760),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            parent.title = "Dogear isolated annotation probe"
            parent.contentViewController = NSHostingController(rootView: Root(model: model))
            defer {
                // This teardown concerns only the authored scratch fixture.
                model.draft = nil
                if let sheet = parent.attachedSheet { parent.endSheet(sheet); sheet.orderOut(nil) }
                parent.close()
            }

            parent.makeKeyAndOrderFront(nil)
            var installed: (NSWindow, ResearchNativeTextView)?
            for _ in 0..<12 {
                await settle(parent)
                if let sheet = parent.attachedSheet, let content = sheet.contentView,
                   let native = editor(in: content) {
                    installed = (sheet, native)
                    break
                }
            }
            guard let (sheet, native) = installed else {
                check(false, "The production SwiftUI sheet did not install its native editor.")
                return Report(checks: checks, failures: failures, observations: observations)
            }
            observations.append("initial appActive=\(NSApp.isActive) sheetKey=\(sheet.isKeyWindow) "
                + "autofocus=\(sheet.firstResponder === native)")
            guard NSApp.isActive, sheet.isKeyWindow else {
                check(false, "Focus acceptance requires an active app and key native sheet.")
                return Report(checks: checks, failures: failures, observations: observations)
            }

            check(sheet.makeFirstResponder(native),
                "The installed native editor could not receive explicit fixture focus.")
            await settle(parent)
            check(native.editorIdentity == draft.id && native.window === sheet,
                "The native editor does not belong to the exact draft and sheet.")
            check(MacAnnotationEditorLifecycle.unfinishedWindow == nil,
                "An unchanged production sheet unexpectedly vetoes Quit.")
            let baseline = native.string
            let pageCount = document.pageCount
            let annotationIDs = page.annotations.map(ObjectIdentifier.init)
            let nativeUndo = native.undoManager
            native.setSelectedRange(NSRange(location: (baseline as NSString).length, length: 0))
            native.insertText(" pending", replacementRange: NSRange(location: NSNotFound, length: 0))
            await settle(parent)
            let pending = native.string
            check(pending == baseline + " pending" && nativeUndo?.canUndo == true,
                "Native input or its local Undo did not survive SwiftUI binding updates.")
            check(nativeUndo !== documentUndo && !documentUndo.canUndo
                && draft.baseline.matches(annotation) && !store.hasUnsavedChanges,
                "Unsubmitted native input mutated the PDF or document Undo.")
            check(MacAnnotationEditorLifecycle.unfinishedWindow === sheet,
                "The production lifetime host did not register the dirty native sheet.")
            native.undo(nil)
            await settle(parent)
            check(native.string == baseline && !documentUndo.canUndo,
                "Native text Undo changed the document or failed to restore text.")
            native.redo(nil)
            await settle(parent)
            check(native.string == pending && !documentUndo.canUndo,
                "Native text Redo did not restore the retained draft independently.")

            model.rejectSave = true
            await settle(parent)
            let canUndoBeforeSave = nativeUndo?.canUndo
            let canRedoBeforeSave = nativeUndo?.canRedo
            guard let submit = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: sheet.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else {
                throw NSError(domain: "DogearMacSheetProbe", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not create native Command-Return event."])
            }
            check(native.performKeyEquivalent(with: submit),
                "Command-Return did not enter the production sheet Save action.")
            await settle(parent)
            check(model.saveCalls == 1 && model.draft?.id == draft.id
                && parent.attachedSheet === sheet && native.window === sheet && native.string == pending,
                "A false onSave result dismissed or replaced the actual draft/editor.")
            check(native.undoManager === nativeUndo && nativeUndo?.canUndo == canUndoBeforeSave
                && nativeUndo?.canRedo == canRedoBeforeSave,
                "Failed Save destroyed local text Undo/Redo.")
            check(document.pageCount == pageCount && page.annotations.map(ObjectIdentifier.init) == annotationIDs
                && draft.baseline.matches(annotation) && !store.hasUnsavedChanges && !documentUndo.canUndo,
                "Failed Save changed the PDF or document Undo.")
            check(MacAnnotationEditorLifecycle.unfinishedWindow === sheet,
                "Failed Save removed the dirty sheet's native Quit protection.")
            observations.append("failedSave focused=\(sheet.firstResponder === native) "
                + "owner=\(sheet.firstResponder.map { String(reflecting: type(of: $0)) } ?? "none")")
            check(sheet.firstResponder === native,
                "Failed Save did not return focus to the exact retained native text editor.")

            // Observe AppKit's default behavior; this is not a verdict about
            // GroupWorkspaceHost.close or a claimed dirty-Cancel action test.
            parent.performClose(nil)
            await settle(parent)
            observations.append("parentClose parentVisible=\(parent.isVisible) "
                + "sameSheet=\(parent.attachedSheet === sheet) editorAttached=\(native.window === sheet) "
                + "draftRetained=\(model.draft?.id == draft.id) "
                + "registered=\(MacAnnotationEditorLifecycle.unfinishedWindow === sheet)")
            model.draft = nil
            // SwiftUI can retain a sheet during its dismissal animation. Wait
            // for the actual native detachment before assessing stale registry
            // state; a fixed short delay would test animation timing instead.
            for _ in 0..<30 {
                await settle(parent)
                if parent.attachedSheet !== sheet { break }
            }
            observations.append("dismiss parentAttached=\(parent.attachedSheet === sheet) "
                + "sheetVisible=\(sheet.isVisible) editorAttached=\(native.window === sheet) "
                + "registered=\(MacAnnotationEditorLifecycle.unfinishedWindow === sheet)")
            check(parent.attachedSheet !== sheet,
                "The actual native sheet did not detach after programmatic fixture dismissal.")
            check(MacAnnotationEditorLifecycle.unfinishedWindow !== sheet,
                "Dismissing the actual native sheet left an active Quit registration behind.")

            // A cached native sheet must bind a later draft's actual identity,
            // not retain the old registration or its text Undo installation.
            let nextDraft = FreeTextEditDraft(document: document, page: page, annotation: annotation)
            model.rejectSave = false
            model.draft = nextDraft
            var reopened: (NSWindow, ResearchNativeTextView)?
            for _ in 0..<20 {
                await settle(parent)
                if let nextSheet = parent.attachedSheet, let content = nextSheet.contentView,
                   let nextEditor = editor(in: content), nextEditor.editorIdentity == nextDraft.id {
                    reopened = (nextSheet, nextEditor)
                    break
                }
            }
            guard let (nextSheet, nextEditor) = reopened else {
                check(false, "A fresh draft did not install after the cached sheet was dismissed.")
                return Report(checks: checks, failures: failures, observations: observations)
            }
            check(nextDraft.id != draft.id && nextEditor.string == baseline,
                "A reopened sheet inherited the old draft identity or discarded text.")
            check(MacAnnotationEditorLifecycle.unfinishedWindow == nil,
                "An unchanged reopened draft inherited the dismissed editor's Quit veto.")
            check(nextSheet.makeFirstResponder(nextEditor), "The reopened native editor could not receive focus.")
            nextEditor.setSelectedRange(NSRange(location: (baseline as NSString).length, length: 0))
            nextEditor.insertText(" saved", replacementRange: NSRange(location: NSNotFound, length: 0))
            await settle(parent)
            let savedText = nextEditor.string
            check(MacAnnotationEditorLifecycle.unfinishedWindow === nextSheet && !documentUndo.canUndo,
                "The reopened dirty draft did not rebind native Quit protection independently of PDF history.")
            guard let nextSubmit = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: nextSheet.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else {
                throw CocoaError(.coderInvalidValue)
            }
            documentUndo.beginUndoGrouping()
            let submitted = nextEditor.performKeyEquivalent(with: nextSubmit)
            documentUndo.endUndoGrouping()
            await queue.drain()
            for _ in 0..<30 {
                await settle(parent)
                if parent.attachedSheet !== nextSheet { break }
            }
            check(submitted && model.saveCalls == 2 && model.draft == nil
                && parent.attachedSheet !== nextSheet && MacAnnotationEditorLifecycle.unfinishedWindow == nil,
                "Successful native Save did not dismiss and release the exact reopened sheet.")
            check(annotation.contents == savedText && documentUndo.canUndo && !store.hasUnsavedChanges
                && store.workingCopySaveError == nil && page.annotations.map(ObjectIdentifier.init) == annotationIDs,
                "Successful native Save did not commit one standard annotation through the actual Store and queue.")
            store.undoDocumentChange()
            check(annotation.contents == baseline && documentUndo.canRedo,
                "One document Undo did not restore the pre-sheet standard PDF note.")
            store.redoDocumentChange()
            check(annotation.contents == savedText && documentUndo.canUndo,
                "Document Redo did not restore the saved sheet values.")
            await queue.drain()
            if let copy = store.currentWorkingCopyURL, let fresh = PDFDocument(url: copy),
               let saved = fresh.page(at: 0)?.annotations.first(where: { $0.type == "FreeText" }) {
                check(fresh.pageCount == pageCount && saved.contents == savedText
                    && saved.bounds == annotation.bounds && saved.font?.pointSize == annotation.font?.pointSize,
                    "A fresh native PDF read did not preserve the sheet's actual saved annotation.")
            } else { check(false, "Successful sheet Save produced no readable working copy.") }
            check(try Data(contentsOf: sourceURL) == data,
                "Native sheet Save, Undo or Redo changed the original PDF bytes.")
        } catch { check(false, "Probe setup failed: \(error.localizedDescription)") }
        return Report(checks: checks, failures: failures, observations: observations)
    }
}
#endif
