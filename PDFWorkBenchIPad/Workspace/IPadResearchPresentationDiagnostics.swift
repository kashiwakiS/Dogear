#if os(iOS)
import Combine
import PDFKit
import SwiftUI
import UIKit

/// Mounts the production pane container with the actual PDFKit and text views.
/// Preference checks alone cannot detect a SwiftUI branch rebuilding either
/// native editor, or the loss of composition when its width changes.
@MainActor
enum IPadResearchPresentationDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        expect(IPadResearchPresentation.defaultWidth(windowSize: .init(width: 768, height: 1024)) == .fullWidth,
            "A portrait window defaults to full-width Research.")
        expect(IPadResearchPresentation.defaultWidth(windowSize: .init(width: 1024, height: 768)) == .sidebar,
            "A landscape window defaults to a Research sidebar.")
        let preference = IPadResearchPresentation()
        preference.toggleWidth(windowSize: .init(width: 768, height: 1024))
        expect(preference.resolvedWidth(windowSize: .init(width: 1024, height: 768)) == .sidebar,
            "An explicit Research width survives window orientation changes.")
        let narrow = IPadResearchPaneLayout(availableSize: .init(width: 500, height: 900), showsResearch: true,
            width: preference.resolvedWidth(windowSize: .init(width: 1024, height: 768)))
        expect(!narrow.isSidebar && !narrow.readerVisible && narrow.researchVisible
            && preference.preferredWidth == .sidebar && narrow.researchFrame.width == 500,
            "A narrow detail pane uses full Research without discarding the user's sidebar preference.")
        let expanded = IPadResearchPaneLayout(availableSize: .init(width: 1000, height: 600), showsResearch: true,
            width: preference.resolvedWidth(windowSize: .init(width: 1024, height: 768)))
        expect(expanded.isSidebar && expanded.readerVisible && expanded.researchVisible
            && expanded.readerFrame.width >= IPadResearchPaneLayout.minimumReaderWidth
            && expanded.researchFrame.width >= IPadResearchPaneLayout.minimumResearchWidth
            && expanded.readerFrame.maxX < expanded.researchFrame.minX,
            "A sufficiently wide detail pane displays nonoverlapping native Reader and Research panes.")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearResearchLayout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ResearchStore(rootURL: root)
        let sessionID = storage.createSession(title: "Layout fixture")
        let renderer = UIGraphicsPDFRenderer(bounds: .init(x: 0, y: 0, width: 612, height: 792))
        let bytes = renderer.pdfData { context in
            for index in 0..<3 {
                context.beginPage()
                ("Layout native selection page \(index + 1)" as NSString).draw(at: .init(x: 60, y: 80),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
        guard let document = PDFDocument(data: bytes), let page = document.page(at: 1),
              let selection = page.selection(for: NSRange(location: 0, length: 6)) else {
            expect(false, "The layout fixture requires an actual three-page PDF with native selectable glyphs.")
            return (checks, failures)
        }
        let state = FixtureState(document: document, storage: storage, sessionID: sessionID)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previous = scene?.windows.first(where: \.isKeyWindow)
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: .init(x: 0, y: 0, width: 1024, height: 768))
        let host = UIHostingController(rootView: FixtureView(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        await settle(host)
        guard let reader = find(PDFView.self, in: host.view) else {
            expect(false, "The production pane container mounts an actual PDFView.")
            return (checks, failures)
        }
        expect(reader.document === document && reader.currentPage.map { document.index(for: $0) } == 1,
            "The production Reader slot resumes the actual second PDF page.")
        reader.setCurrentSelection(selection, animate: false)
        await settle(host)
        expect((reader as? UIKitReaderPDFView)?.requestReaderFocus(allowPDFSelectionResponder: true) == true,
            "The visible layout fixture can acquire actual Reader keyboard focus.")
        let expectedSelection = PDFTextSelectionService.snapshot(of: selection, in: document)
        let pageCount = document.pageCount
        let annotationCount = (0..<pageCount).reduce(0) { $0 + (document.page(at: $1)?.annotations.count ?? 0) }
        state.showsResearch = true
        state.presentation.preferredWidth = .fullWidth
        await settle(host)
        guard let textView = find(IPadResearchNativeTextView.self, in: host.view) else {
            expect(false, "The Research slot mounts an actual native editor on its first presentation.")
            return (checks, failures)
        }
        expect(find(PDFView.self, in: host.view) === reader && reader.window === window
            && reader.bounds.width > 0 && reader.bounds.height > 0
            && (reader as? UIKitReaderPDFView)?.isReaderInputActive == false
            && (reader as? UIKitReaderPDFView)?.hasReaderKeyboardFocus == false
            && (reader as? UIKitReaderPDFView)?.requestReaderFocus() == false,
            "Full-width Research keeps the same attached PDFView with a nonzero viewport.")
        textView.becomeFirstResponder()
        state.commands.activate(textView)
        textView.insertText("Research draft ")
        await settle(host)
        expect(textView.isFirstResponder && textView.undoManager?.canUndo == true
            && storage.session(id: sessionID)?.draft.text == textView.text,
            "The layout fixture owns real native focus, independent Undo and a durable captured Research draft.")
        textView.setMarkedText("中文候选", selectedRange: .init(location: 4, length: 0))
        let text = textView.text
        let range = textView.selectedRange
        let marked = markedRange(textView)
        let textUndo = textView.undoManager
        let savedDraft = storage.session(id: sessionID)?.draft
        let undoState = (canUndo: textUndo?.canUndo, canRedo: textUndo?.canRedo,
                         undoName: textUndo?.undoActionName, redoName: textUndo?.redoActionName,
                         groupingLevel: textUndo?.groupingLevel)
        func undoUnchanged() -> Bool {
            textView.undoManager === textUndo && textUndo?.canUndo == undoState.canUndo
                && textUndo?.canRedo == undoState.canRedo && textUndo?.undoActionName == undoState.undoName
                && textUndo?.redoActionName == undoState.redoName && textUndo?.groupingLevel == undoState.groupingLevel
        }
        func compositionUnchanged() -> Bool {
            marked != nil && textView.markedTextRange != nil && markedRange(textView) == marked
                && textView.text == text && textView.selectedRange == range && textView.isFirstResponder
                && storage.session(id: sessionID)?.draft == savedDraft && undoUnchanged()
        }
        func probe(_ phase: String) -> String {
            let currentMarked = markedRange(textView)
            let editorFrame = textView.convert(textView.bounds, to: host.view)
            let readerFrame = reader.convert(reader.bounds, to: host.view)
            let actualDraft = storage.session(id: sessionID)?.draft
            let details = "phase=\(phase), sameEditor=\(find(IPadResearchNativeTextView.self, in: host.view) === textView), "
                + "sameReader=\(find(PDFView.self, in: host.view) === reader), identity=\(textView.editorIdentity == sessionID), "
                + "markedExists=\(currentMarked != nil), markedEqual=\(currentMarked == marked), textEqual=\(textView.text == text), "
                + "selectionEqual=\(textView.selectedRange == range), focus=\(textView.isFirstResponder), "
                + "draftEqual=\(actualDraft == savedDraft), draftTextEqual=\(actualDraft?.text == savedDraft?.text), "
                + "undoIdentity=\(textView.undoManager === textUndo), undoStateEqual=\(undoUnchanged()), "
                + "attached=\(textView.window === window), keyWindow=\(window.isKeyWindow), editable=\(textView.isEditable), "
                + "markedBefore=\(String(describing: marked)), markedAfter=\(String(describing: currentMarked)), "
                + "selectionBefore=\(range), selectionAfter=\(textView.selectedRange), "
                + "editorFrame=\(editorFrame), readerFrame=\(readerFrame), windowSize=\(window.bounds.size)"
            // Authored fixture text and file paths are deliberately excluded.
            print("Research presentation native probe: \(details)")
            return details
        }
        expect(marked != nil, "Research layout checks start with an actual marked Chinese text range.")
        _ = probe("marked-immediate")
        // Keep the original snapshot. A no-preference-change control exposes
        // asynchronous native input/layout changes before attributing them to
        // the subsequent width transition.
        await settle(host)
        let controlDetails = probe("marked-control")
        expect(compositionUnchanged(),
            "With unchanged Research width, native composition, selection, focus, draft and Undo remain stable. [\(controlDetails)]")
        state.presentation.preferredWidth = .sidebar
        await settle(host)
        let sidebarDetails = probe("sidebar")
        expect(find(PDFView.self, in: host.view) === reader && find(IPadResearchNativeTextView.self, in: host.view) === textView
            && textView.undoManager === textUndo && textView.editorIdentity == sessionID,
            "Changing Research width preserves both native view identities and the exact text Undo manager.")
        expect(compositionUnchanged(),
            "A sidebar transition preserves actual composition, text selection, focus and its captured draft. [\(sidebarDetails)]")
        state.presentation.preferredWidth = .fullWidth
        await settle(host)
        let fullDetails = probe("full-return")
        expect(find(IPadResearchNativeTextView.self, in: host.view) === textView && markedRange(textView) == marked
            && textView.text == text && textView.undoManager === textUndo && textView.isFirstResponder
            && compositionUnchanged(),
            "Returning to full Research does not dismantle or finish the native composition. [\(fullDetails)]")
        expect(reader.document === document && reader.currentSelection.flatMap {
            PDFTextSelectionService.snapshot(of: $0, in: document)
        } == expectedSelection && document.pageCount == pageCount
            && (0..<pageCount).reduce(0, { $0 + (document.page(at: $1)?.annotations.count ?? 0) }) == annotationCount,
            "Research width changes preserve authoritative PDF glyph selection and the document's pages and annotations.")
        state.presentation.preferredWidth = nil
        await settle(host)
        let actualWindow = window.bounds.size
        let reportedWindow = state.windowSize
        let automaticWidth = state.presentation.resolvedWidth(windowSize: reportedWindow)
        state.contentHeight = max(120, host.view.bounds.height * 0.4)
        await settle(host)
        expect(state.windowSize == actualWindow && reportedWindow == actualWindow
            && window.bounds.size == actualWindow
            && state.presentation.resolvedWidth(windowSize: state.windowSize) == automaticWidth,
            "Reducing content height for a keyboard leaves the actual-window Research default unchanged.")
        expect(find(IPadResearchNativeTextView.self, in: host.view) === textView && markedRange(textView) == marked
            && textView.text == text && textView.undoManager === textUndo,
            "Keyboard-height layout changes retain the same editor and active composition.")
        expect(state.commands.commitMarkedTextAndEndEditing(identity: sessionID)
            && textView.markedTextRange == nil && storage.session(id: sessionID)?.draft.text == textView.text
            && textView.text.contains("中文候选"),
            "An explicit presentation boundary commits marked text only to its captured Research session.")
        state.showsResearch = false
        await settle(host)
        expect(find(IPadResearchNativeTextView.self, in: host.view) === textView
            && textView.undoManager === textUndo && !textView.isFirstResponder && textView.markedTextRange == nil
            && find(PDFView.self, in: host.view) === reader
            && (reader as? UIKitReaderPDFView)?.isReaderInputActive == true
            && reader.currentPage.map { document.index(for: $0) } == 1,
            "Returning to Reader retains both views and text history after the explicit input boundary.")
        state.showsResearch = true
        await settle(host)
        expect(find(IPadResearchNativeTextView.self, in: host.view) === textView
            && storage.session(id: sessionID)?.draft.text == textView.text && textView.undoManager === textUndo,
            "Reopening Research reuses the same native editor and captured durable draft.")
        let committedText = textView.text
        let committedUndo = (canUndo: textUndo?.canUndo, canRedo: textUndo?.canRedo,
                             undoName: textUndo?.undoActionName, redoName: textUndo?.redoActionName,
                             groupingLevel: textUndo?.groupingLevel)
        func committedStateUnchanged() -> Bool {
            textView.text == committedText && textView.markedTextRange == nil
                && textView.editorIdentity == sessionID && textView.undoManager === textUndo
                && textUndo?.canUndo == committedUndo.canUndo && textUndo?.canRedo == committedUndo.canRedo
                && textUndo?.undoActionName == committedUndo.undoName && textUndo?.redoActionName == committedUndo.redoName
                && textUndo?.groupingLevel == committedUndo.groupingLevel
        }
        let otherInput = UITextField(frame: .init(x: 12, y: 12, width: 160, height: 44))
        host.view.addSubview(otherInput)
        expect(textView.becomeFirstResponder(), "A focus-safety fixture begins with the actual Research editor focused.")
        state.presentation.toggleWidth(windowSize: state.windowSize)
        let focusedOther = otherInput.becomeFirstResponder()
        await settle(host)
        let owner = firstResponder(in: window)
        let ownerClass = owner.map { NSStringFromClass(type(of: $0)) } ?? "none"
        let ownerTextInput = owner as? any UITextInput
        let otherDetails = "focusedOtherReturn=\(focusedOther), otherFocused=\(otherInput.isFirstResponder), "
            + "editorFocused=\(textView.isFirstResponder), committedStateEqual=\(committedStateUnchanged()), "
            + "textEqual=\(textView.text == committedText), markedNil=\(textView.markedTextRange == nil), "
            + "identity=\(textView.editorIdentity == sessionID), undoIdentity=\(textView.undoManager === textUndo), "
            + "canUndoEqual=\(textUndo?.canUndo == committedUndo.canUndo), canRedoEqual=\(textUndo?.canRedo == committedUndo.canRedo), "
            + "undoNameEqual=\(textUndo?.undoActionName == committedUndo.undoName), redoNameEqual=\(textUndo?.redoActionName == committedUndo.redoName), "
            + "groupingEqual=\(textUndo?.groupingLevel == committedUndo.groupingLevel), ownerClass=\(ownerClass), "
            + "ownerIsEditor=\(owner === textView), ownerIsOther=\(owner === otherInput), ownerInReader=\(owner?.isDescendant(of: reader) == true), "
            + "ownerIsTextInput=\(ownerTextInput != nil), ownerIsTextView=\(owner is UITextView), ownerIsTextField=\(owner is UITextField), "
            + "ownerEditable=\((owner as? UITextView)?.isEditable == true), ownerMarked=\(ownerTextInput?.markedTextRange != nil), "
            + "keyWindow=\(window.isKeyWindow), editorAttached=\(textView.window === window), otherAttached=\(otherInput.window === window)"
        print("Research other-input native probe: \(otherDetails)")
        expect(focusedOther && otherInput.isFirstResponder && !textView.isFirstResponder && committedStateUnchanged(),
            "A delayed width layout preserves a different native input's explicit focus and the Research text history. [\(otherDetails)]")
        otherInput.resignFirstResponder(); otherInput.removeFromSuperview()
        expect(textView.becomeFirstResponder(), "A hidden-pane fixture begins with its exact native editor focused.")
        state.presentation.toggleWidth(windowSize: state.windowSize)
        state.isPresentationActive = false
        textView.resignFirstResponder()
        await settle(host)
        expect(!textView.isFirstResponder && find(IPadResearchNativeTextView.self, in: host.view) === textView
            && committedStateUnchanged(),
            "A late width layout cannot refocus a hidden tab's retained native Research editor.")
        let teardown = TeardownFixtureState()
        let teardownHost = UIHostingController(rootView: TeardownFixtureView(state: teardown, windowSize: window.bounds.size))
        window.rootViewController = teardownHost
        await settle(teardownHost)
        guard let retiredEditor = find(IPadResearchNativeTextView.self, in: teardownHost.view),
              let installer = teardown.installer else {
            expect(false, "An attached-teardown fixture requires the actual production native editor installation.")
            return (checks, failures)
        }
        expect(retiredEditor.becomeFirstResponder() && retiredEditor.window === window && retiredEditor.delegate != nil,
            "An attached-teardown fixture focuses its installed actual native Research editor before capture.")
        teardown.traces.removeAll()
        teardown.presentation.toggleWidth(windowSize: window.bounds.size)
        let capturedFocused = teardown.traces.contains { $0.contains("phase=captured,") && $0.contains("focused=true") }
        teardown.retiredDelegate = retiredEditor.delegate
        installer.teardown(retiredEditor)
        retiredEditor.resignFirstResponder()
        expect(capturedFocused && retiredEditor.delegate == nil && teardown.retiredDelegate == nil
            && retiredEditor.window === window,
            "A real production dismantle releases the captured weak delegate while its old editor remains attached.")
        await settle(teardownHost)
        let rejectedAttachedLease = teardown.traces.contains {
            $0.contains("phase=cancel-restoration-guard,") && $0.contains("attached=true")
                && $0.contains("scopeMatches=true") && $0.contains("capturedDelegateAlive=false")
                && $0.contains("currentDelegatePresent=false")
                && $0.contains("active=true") && $0.contains("dismantled=false")
                && $0.contains("keyWindow=true") && $0.contains("editable=true")
                && $0.contains("ownerClass=none")
        }
        expect(rejectedAttachedLease && !retiredEditor.isFirstResponder && retiredEditor.window === window
            && retiredEditor.delegate == nil && teardown.retiredDelegate == nil
            && retiredEditor.editorIdentity == teardown.identity
            && find(IPadResearchNativeTextView.self, in: teardownHost.view) === retiredEditor,
            "A pending width capture rejects a still-attached torn-down editor whose exact weak delegate no longer exists.")
        return (checks, failures)
    }

    private static func settle(_ host: UIViewController) async {
        for _ in 0..<4 {
            await Task.yield()
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let value = view as? T { return value }
        for child in view.subviews { if let value = find(type, in: child) { return value } }
        return nil
    }

    private static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews { if let owner = firstResponder(in: child) { return owner } }
        return nil
    }

    private static func markedRange(_ view: UITextView) -> NSRange? {
        guard let range = view.markedTextRange else { return nil }
        return .init(location: view.offset(from: view.beginningOfDocument, to: range.start),
            length: view.offset(from: range.start, to: range.end))
    }

    private final class FixtureState: ObservableObject {
        let document: PDFDocument
        let storage: ResearchStore
        let sessionID: UUID
        let commands = IPadResearchTextEditingCommands()
        let presentation = IPadResearchPresentation()
        @Published var showsResearch = false
        @Published var isPresentationActive = true
        @Published var windowSize = CGSize.zero
        @Published var contentHeight: CGFloat?
        init(document: PDFDocument, storage: ResearchStore, sessionID: UUID) {
            self.document = document; self.storage = storage; self.sessionID = sessionID
            presentation.focusTrace = { print("Research focus continuity trace: \($0)") }
        }
        var text: Binding<String> {
            Binding(get: { self.storage.session(id: self.sessionID)?.draft.text ?? "" }, set: { value in
                guard var draft = self.storage.session(id: self.sessionID)?.draft else { return }
                draft.text = value; _ = self.storage.saveDraft(draft, sessionID: self.sessionID)
            })
        }
    }

    private struct FixtureView: View {
        @ObservedObject var state: FixtureState
        var body: some View {
            IPadResearchWorkspacePanes(showsResearch: state.showsResearch, presentation: state.presentation,
                windowSize: state.windowSize, isPresentationActive: state.isPresentationActive, reader: { active in
                    PDFReaderUIKitView(document: state.document,
                        initialReadingState: .init(document: state.document, pageIndex: 1, zoom: .percent(100)),
                        isPresentationActive: active && state.isPresentationActive)
                }, research: {
                    IPadResearchNativeTextEditor(text: state.text, commands: state.commands, identity: state.sessionID,
                        isEditable: state.isPresentationActive && state.showsResearch)
                        .id(state.sessionID)
                })
                .frame(height: state.contentHeight)
                .background(IPadWorkspaceWindowGeometry(onChange: { state.windowSize = $0 }))
        }
    }

    private final class TeardownFixtureState {
        let presentation = IPadResearchPresentation(preferredWidth: .fullWidth)
        let commands = IPadResearchTextEditingCommands()
        let identity = UUID()
        var text = "Teardown fixture"
        var traces: [String] = []
        weak var installer: TeardownInstaller?
        weak var retiredDelegate: (any UITextViewDelegate)?
        init() {
            presentation.focusTrace = { [weak self] value in
                self?.traces.append(value)
                print("Research attached teardown trace: \(value)")
            }
        }
        var wrapper: IPadResearchNativeTextEditor {
            IPadResearchNativeTextEditor(text: Binding(get: { self.text }, set: { self.text = $0 }),
                commands: commands, identity: identity)
        }
    }
    private final class TeardownInstaller {
        var native: IPadResearchNativeTextEditor.Coordinator?
        private(set) var isTornDown = false
        init(_ wrapper: IPadResearchNativeTextEditor) { native = wrapper.makeCoordinator() }
        func teardown(_ editor: IPadResearchNativeTextView) {
            guard let coordinator = native else { return }
            isTornDown = true
            IPadResearchNativeTextEditor.dismantleUIView(editor, coordinator: coordinator)
            native = nil
        }
    }
    private struct TeardownNativeEditor: UIViewRepresentable {
        let state: TeardownFixtureState
        func makeCoordinator() -> TeardownInstaller {
            let installer = TeardownInstaller(state.wrapper)
            state.installer = installer
            return installer
        }
        func makeUIView(context: Context) -> IPadResearchNativeTextView {
            let editor = IPadResearchNativeTextView(frame: .zero)
            context.coordinator.native?.install(editor)
            return editor
        }
        func updateUIView(_ editor: IPadResearchNativeTextView, context: Context) {
            // Framework layout must not reinstall the retired production
            // coordinator and mask the weak-nil teardown condition.
            guard !context.coordinator.isTornDown, let native = context.coordinator.native else { return }
            native.parent = state.wrapper; native.install(editor)
        }
        static func dismantleUIView(_ editor: IPadResearchNativeTextView, coordinator: TeardownInstaller) {
            coordinator.teardown(editor)
        }
    }
    private struct TeardownFixtureView: View {
        let state: TeardownFixtureState
        let windowSize: CGSize
        var body: some View {
            IPadResearchWorkspacePanes(showsResearch: true, presentation: state.presentation,
                windowSize: windowSize, reader: { _ in Color.clear }, research: { TeardownNativeEditor(state: state) })
        }
    }
}
#endif
