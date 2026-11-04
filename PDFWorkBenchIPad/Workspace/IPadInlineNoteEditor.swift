#if os(iOS)
import Combine
import PDFKit
import SwiftUI
import UIKit

/// The workspace retains this detached draft while its reader is hidden. Every
/// native callback and save continues to own the original document and UUID.
@MainActor
final class IPadInlineNoteEditingSession: ObservableObject, Identifiable {
    enum Completion: Equatable { case saved, discarded }
    let draft: FreeTextEditDraft
    var id: UUID { draft.id }
    let textCommands = IPadResearchTextEditingCommands()
    @Published var values: FreeTextEditValues
    @Published var error: String?
    @Published var confirmsDiscard = false
    @Published private(set) var completion: Completion?
    var beforeDiscard: (() -> Bool)?
    var beforeSave: (() -> Bool)?

    init(draft: FreeTextEditDraft) {
        self.draft = draft
        values = draft.values
    }

    var isFinished: Bool { completion != nil }
    var isDirty: Bool { !isFinished && (values != draft.values || textCommands.hasMarkedText) }
    var bounds: CGRect {
        var presentationValues = values
        if !values.width.isFinite || values.width <= 0 { presentationValues.width = draft.originalBounds.width }
        if !values.height.isFinite || values.height <= 0 { presentationValues.height = draft.originalBounds.height }
        return FreeTextAnnotationEditing.resolvedBounds(presentationValues, draft: draft)
    }

    var textBinding: Binding<String> {
        Binding(get: { self.values.text }, set: { if !self.isFinished { self.values.text = $0 } })
    }

    @discardableResult
    func finishIME() -> Bool {
        guard !isFinished else { return true }
        return textCommands.commitMarkedTextAndEndEditing(identity: id)
    }

    /// Returns true only when a caller can immediately release a clean draft.
    /// Dirty drafts remain retained until the visible discard confirmation.
    @discardableResult
    func requestDiscard() -> Bool {
        guard finishIME() else { return false }
        if isDirty { confirmsDiscard = true; return false }
        return true
    }

    @discardableResult
    func discard() -> Bool {
        guard finishIME(), beforeDiscard?() != false else { return false }
        completion = .discarded
        confirmsDiscard = false
        return true
    }

    @discardableResult
    func save(in store: PDFDocumentStore, canCommit: () -> Bool) -> Bool {
        guard !isFinished, canCommit(), isCurrent(in: store), finishIME(),
              canCommit(), isCurrent(in: store) else {
            error = L10n.string("The document changed. Reopen this note before editing it.")
            return false
        }
        if let message = FreeTextAnnotationEditing.validationMessage(values, draft: draft) {
            error = message
            return false
        }
        guard beforeSave?() != false else { return false }
        guard canCommit(), isCurrent(in: store) else {
            error = L10n.string("The document changed. Reopen this note before editing it.")
            return false
        }
        guard store.saveFreeText(draft, values: values) else {
            error = L10n.string("The document changed. Reopen this note before editing it.")
            return false
        }
        completion = .saved
        return true
    }

    private func isCurrent(in store: PDFDocumentStore) -> Bool {
        store.canEditDocument && FreeTextAnnotationEditing.isCurrent(draft, in: store.document)
    }
}

/// The floating presentation owns placement. Native text Undo remains separate
/// from document Undo, and all Save/discard boundaries stay in the session.
@MainActor
struct IPadInlineNoteEditorControls: View {
    @ObservedObject var session: IPadInlineNoteEditingSession
    @ObservedObject private var commands: IPadResearchTextEditingCommands
    let store: PDFDocumentStore
    let canCommit: () -> Bool
    let onFinish: () -> Void
    private var displayedFontSize: Double {
        let size = session.values.fontSize
        return size.isFinite && size > 0 ? min(144, max(4, size)) : 14
    }
    private static let swatches: [(name: String, color: PDFColorComponents)] = [
        ("Black", .init(red: 0, green: 0, blue: 0, alpha: 1)),
        ("Red", .init(red: 1, green: 0, blue: 0, alpha: 1)),
        ("Blue", .init(red: 0, green: 0, blue: 1, alpha: 1)),
        ("Green", .init(red: 0, green: 0.5, blue: 0, alpha: 1))
    ]

    init(session: IPadInlineNoteEditingSession, store: PDFDocumentStore,
         canCommit: @escaping () -> Bool, onFinish: @escaping () -> Void) {
        self.session = session; self.store = store
        self.canCommit = canCommit; self.onFinish = onFinish
        commands = session.textCommands
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    if session.requestDiscard(), session.discard() { onFinish() }
                } label: { controlIcon("xmark") }
                    .accessibilityLabel("Cancel").accessibilityIdentifier("ipad.note.cancel")
                Button { commands.undo() } label: { controlIcon("arrow.uturn.backward") }
                    .disabled(!commands.canUndo).accessibilityLabel("Undo")
                Button { commands.redo() } label: { controlIcon("arrow.uturn.forward") }
                    .disabled(!commands.canRedo).accessibilityLabel("Redo")
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        fontMenu
                        Button { changeFontSize(by: -1) } label: { controlIcon("minus") }
                            .disabled(displayedFontSize <= 4 || !canCommit())
                            .accessibilityLabel("Decrease font size").accessibilityIdentifier("ipad.note.font.decrease")
                        Text(displayedFontSize, format: .number.precision(.fractionLength(0...1)))
                            .font(.system(size: 11)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                            .frame(width: 24, height: 44)
                            .accessibilityLabel(Text("Font size: \(displayedFontSize.formatted(.number.precision(.fractionLength(0...1))))"))
                        Button { changeFontSize(by: 1) } label: { controlIcon("plus") }
                            .disabled(displayedFontSize >= 144 || !canCommit())
                            .accessibilityLabel("Increase font size").accessibilityIdentifier("ipad.note.font.increase")
                        ForEach(Self.swatches.indices, id: \.self) { index in
                            swatchButton(Self.swatches[index])
                        }
                        Button { changeTextColor(nil) } label: { controlIcon("arrow.counterclockwise.circle") }
                            .disabled(!canCommit()).accessibilityLabel("Default text color")
                            .accessibilityIdentifier("ipad.note.color.default")
                        colorPicker
                    }
                    .frame(width: 420, height: 44)
                }.scrollIndicators(.hidden).frame(maxWidth: .infinity).frame(height: 44)
                Button {
                    if session.save(in: store, canCommit: canCommit) { onFinish() }
                } label: {
                    VStack(spacing: 0) {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                        Text("Save").font(.system(size: 9, weight: .semibold))
                    }.frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .foregroundStyle(Color.accentColor).disabled(!canCommit())
                    .accessibilityLabel("Save").accessibilityIdentifier("ipad.note.save")
            }
            .buttonStyle(.plain).font(.system(size: 13)).frame(height: 44)
            .background {
                RoundedRectangle(cornerRadius: 6).fill(.regularMaterial)
                    .frame(height: IPadInlineNoteControlsLayout.visualRowHeight)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
            }
            if let error = session.error {
                Text(verbatim: error).font(.caption).foregroundStyle(.red).lineLimit(2)
                    .frame(height: 40, alignment: .topLeading).padding(.horizontal, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .confirmationDialog("Discard changes?", isPresented: $session.confirmsDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { if session.discard() { onFinish() } }
            Button("Keep editing", role: .cancel) {}
        }
    }

    private func controlIcon(_ name: String) -> some View {
        Image(systemName: name).frame(width: 44, height: 44).contentShape(Rectangle())
    }

    private var fontMenu: some View {
        let fonts = FreeTextAnnotationEditing.commonFontNames.compactMap { name -> (label: String, font: UIFont)? in
            guard let font = UIFont(name: name, size: 14) else { return nil }
            return (name, font)
        }
        return Menu {
            Button("Default font") { changeFontName(nil) }
            ForEach(fonts.indices, id: \.self) { index in
                Button { changeFontName(fonts[index].font.fontName) } label: {
                    Text(verbatim: fonts[index].label)
                }
            }
        } label: {
            Group {
                if let name = session.values.fontName {
                    Text(verbatim: UIFont(name: name, size: 14)?.familyName ?? name)
                } else { Text("Default font") }
            }
            .font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.7)
            .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .disabled(!canCommit()).accessibilityLabel("Font").accessibilityIdentifier("ipad.note.font.family")
    }

    private var colorPicker: some View {
        ColorPicker("Text color", selection: pickerColor, supportsOpacity: false)
            .labelsHidden().frame(width: 44, height: 44).contentShape(Rectangle())
            .disabled(!canCommit()).accessibilityLabel("Text color")
            .accessibilityIdentifier("ipad.note.color.custom")
    }

    private var pickerColor: Binding<Color> {
        Binding(get: {
            Color(uiColor: FreeTextAnnotationEditing.resolvedTextColor(session.values, draft: session.draft))
        }, set: { value in
            guard let components = FreeTextAnnotationEditing.textColorComponents(of: UIColor(value)) else { return }
            changeTextColor(components)
        })
    }

    private func swatchButton(_ swatch: (name: String, color: PDFColorComponents)) -> some View {
        let color = PDFPlatformStyle.color(swatch.color)
        let selected = FreeTextAnnotationEditing.resolvedTextColor(session.values, draft: session.draft).isEqual(color)
        let outline = selected ? Color.accentColor : Color(uiColor: .separator)
        let outlineWidth: CGFloat = selected ? 2 : 0.5
        return Button { changeTextColor(swatch.color) } label: {
            Circle().fill(Color(uiColor: color)).frame(width: 14, height: 14)
                .padding(3)
                .overlay(Circle().stroke(outline, lineWidth: outlineWidth))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .disabled(!canCommit()).accessibilityLabel(Text(LocalizedStringKey(swatch.name)))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("ipad.note.color.\(swatch.name.lowercased())")
    }

    private func changeFontSize(by amount: Double) {
        guard !session.isFinished, canCommit(), session.finishIME(), canCommit() else { return }
        session.values.fontSize = min(144, max(4, displayedFontSize + amount))
    }

    private func changeFontName(_ name: String?) {
        guard !session.isFinished, canCommit(), session.finishIME(), canCommit() else { return }
        session.values.fontName = name
    }

    private func changeTextColor(_ color: PDFColorComponents?) {
        guard !session.isFinished, canCommit(), session.finishIME(), canCommit() else { return }
        session.values.fontColor = color
    }
}

/// The native PDF rectangle and obstruction rectangles share viewport points.
/// Prefer empty space next to the note; a clipped/oversized note falls back to a
/// viewport edge that does not cover the exact editor caret or native keyboard.
struct IPadInlineNoteControlsLayout {
    static let rowHeight: CGFloat = 44
    static let visualRowHeight: CGFloat = 32
    static let preferredWidth: CGFloat = 600
    static let minimumViewportWidth: CGFloat = 228
    let frame: CGRect?

    init(noteFrame: CGRect?, viewport: CGRect, keyboardFrame: CGRect? = nil,
         caretFrame: CGRect? = nil, height: CGFloat = Self.rowHeight) {
        guard !viewport.isEmpty, !viewport.isNull, !viewport.isInfinite,
              height.isFinite, height >= Self.rowHeight else { frame = nil; return }
        let usable = viewport.insetBy(dx: 6, dy: 6)
        guard usable.width >= Self.minimumViewportWidth, usable.height >= height else { frame = nil; return }
        let width = min(Self.preferredWidth, usable.width), gap: CGFloat = 6
        let note = noteFrame.flatMap { $0.isEmpty || $0.isNull || $0.isInfinite ? nil : $0 }
        let caret = caretFrame.flatMap { $0.isEmpty || $0.isNull || $0.isInfinite ? nil : $0.insetBy(dx: -4, dy: -4) }
        func safe(_ rect: CGRect) -> Bool {
            usable.contains(rect) && !(keyboardFrame?.intersects(rect) ?? false) && !(caret?.intersects(rect) ?? false)
        }
        func clampedX(_ x: CGFloat) -> CGFloat { min(usable.maxX - width, max(usable.minX, x)) }
        func clampedY(_ y: CGFloat) -> CGFloat { min(usable.maxY - height, max(usable.minY, y)) }
        var candidates: [CGRect] = []
        if let note {
            let x = clampedX(note.minX)
            candidates = [CGRect(x: x, y: note.minY - gap - height, width: width, height: height),
                CGRect(x: x, y: note.maxY + gap, width: width, height: height),
                CGRect(x: note.minX - gap - width, y: clampedY(note.minY), width: width, height: height),
                CGRect(x: note.maxX + gap, y: clampedY(note.minY), width: width, height: height)]
            if let outside = candidates.first(where: { safe($0) && !$0.intersects(note) }) { frame = outside; return }
        }
        var ys = [usable.minY, usable.maxY - height]
        if let caret { ys += [caret.minY - gap - height, caret.maxY + gap] }
        if let keyboardFrame { ys += [keyboardFrame.minY - gap - height, keyboardFrame.maxY + gap] }
        let xs = [clampedX(note?.minX ?? usable.minX), usable.minX, usable.maxX - width]
        frame = ys.flatMap { y in xs.map { CGRect(x: $0, y: y, width: width, height: height) } }.first(where: safe)
    }
}

@MainActor
struct IPadInlineNoteFloatingControls: View {
    @ObservedObject var session: IPadInlineNoteEditingSession
    let store: PDFDocumentStore
    let layout: PDFReaderUIKitOverlayLayout?
    let isActive: Bool
    let canCommit: () -> Bool
    let onFinish: () -> Void
    @State private var keyboardFrame: CGRect?
    @State private var caretFrame: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let placement = IPadInlineNoteControlsLayout(noteFrame: layout?.viewportFrame,
                viewport: CGRect(origin: .zero, size: geometry.size), keyboardFrame: keyboardFrame,
                caretFrame: caretFrame, height: IPadInlineNoteControlsLayout.rowHeight + (session.error == nil ? 0 : 40))
            IPadInlineNoteEditorControls(session: session, store: store, canCommit: canCommit,
                onFinish: onFinish)
                .frame(width: placement.frame?.width ?? IPadInlineNoteControlsLayout.preferredWidth,
                    height: placement.frame?.height ?? IPadInlineNoteControlsLayout.rowHeight)
                .position(x: placement.frame?.midX ?? 0, y: placement.frame?.midY ?? 0)
                .opacity(isActive && placement.frame != nil ? 1 : 0)
                .allowsHitTesting(isActive && placement.frame != nil)
                .accessibilityHidden(!isActive || placement.frame == nil)
                .accessibilityIdentifier("ipad.note.floatingControls")
        }
        .background(IPadInlineNoteViewportProbe(identity: session.id, isActive: isActive) { keyboard, caret in
            keyboardFrame = keyboard; caretFrame = caret
        }.allowsHitTesting(false))
    }
}

/// Read-only public UIKit geometry. It never commits composition, changes
/// selection, or reaches into another editor's command/history ownership.
private struct IPadInlineNoteViewportProbe: UIViewRepresentable {
    let identity: UUID
    let isActive: Bool
    let onChange: (CGRect?, CGRect?) -> Void
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView(); view.isUserInteractionEnabled = false
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        return view
    }
    func updateUIView(_ view: ProbeView, context: Context) {
        view.identity = identity; view.isActive = isActive; view.onChange = onChange; view.scheduleReport()
    }
    static func dismantleUIView(_ view: ProbeView, coordinator: ()) {
        view.isActive = false; view.onChange = nil; view.stopObserving()
    }

    final class ProbeView: UIView {
        var identity = UUID()
        var isActive = false
        var onChange: ((CGRect?, CGRect?) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var scheduled = false
        private var previousKeyboard: CGRect?
        private var previousCaret: CGRect?
        private weak var cachedEditor: IPadResearchNativeTextView?
        override func didMoveToWindow() {
            super.didMoveToWindow(); stopObserving()
            if window != nil {
                for name in [IPadResearchNativeTextView.selectionDidChangeNotification,
                             UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification,
                             UIResponder.keyboardDidChangeFrameNotification, UITextView.textDidChangeNotification,
                             UITextView.textDidBeginEditingNotification, UITextView.textDidEndEditingNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            if notification.name == UIWindow.didBecomeKeyNotification || notification.name == UIWindow.didResignKeyNotification {
                                guard let window = self.window, let sender = notification.object as? UIWindow, sender === window else { return }
                                self.cachedEditor = nil
                            }
                            if notification.name == IPadResearchNativeTextView.selectionDidChangeNotification {
                                guard self.isActive, let editor = notification.object as? IPadResearchNativeTextView,
                                      editor.editorIdentity == self.identity, editor.window === self.window,
                                      editor.isFirstResponder, self.window?.isKeyWindow == true else { return }
                                self.cachedEditor = editor
                            }
                            self.setNeedsLayout(); self.scheduleReport()
                        }
                    })
                }
            }
            scheduleReport()
        }
        override func layoutSubviews() { super.layoutSubviews(); scheduleReport() }
        func stopObserving() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            cachedEditor = nil
        }
        func scheduleReport() {
            guard !scheduled else { return }; scheduled = true
            let capturedIdentity = identity
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.scheduled = false
                guard self.identity == capturedIdentity else { self.scheduleReport(); return }
                let keyboard: CGRect?, caret: CGRect?
                if self.isActive, let window = self.window, window.isKeyWindow {
                    let obstruction = self.keyboardLayoutGuide.layoutFrame.intersection(self.bounds)
                    keyboard = obstruction.isEmpty || obstruction.isNull ? nil : obstruction
                    let editor = self.cachedEditor.flatMap {
                        $0.editorIdentity == self.identity && $0.window === window && $0.isFirstResponder ? $0 : nil
                    } ?? self.focusedEditor(in: window)
                    self.cachedEditor = editor
                    if let editor, let end = editor.selectedTextRange?.end {
                        caret = self.convert(editor.caretRect(for: end), from: editor)
                    } else { caret = nil }
                } else { self.cachedEditor = nil; keyboard = nil; caret = nil }
                guard keyboard != self.previousKeyboard || caret != self.previousCaret else { return }
                self.previousKeyboard = keyboard; self.previousCaret = caret; self.onChange?(keyboard, caret)
            }
        }
        private func focusedEditor(in view: UIView) -> IPadResearchNativeTextView? {
            if let editor = view as? IPadResearchNativeTextView, editor.isFirstResponder, editor.editorIdentity == identity { return editor }
            for child in view.subviews { if let editor = focusedEditor(in: child) { return editor } }
            return nil
        }
    }
}

/// PDFKit supplies the actual page-to-viewport transform. The editor uses
/// UIKit points at the same scale, with no extra text padding or raster image.
@MainActor
struct IPadInlineNoteEditor: View {
    @ObservedObject var session: IPadInlineNoteEditingSession
    let layout: PDFReaderUIKitOverlayLayout?
    let canEdit: Bool
    let onBoundsChanged: (UUID, CGRect) -> Void
    let onSubmit: () -> Void

    private var pdfFont: UIFont {
        var values = session.values
        values.fontSize = values.fontSize.isFinite ? min(144, max(4, values.fontSize)) : 14
        return FreeTextAnnotationEditing.resizedFont(values, annotation: session.draft.annotation)
    }

    var body: some View {
        let bounds = session.bounds
        let proposedScale = layout?.scale ?? 1
        let scale = proposedScale.isFinite && proposedScale > 0 ? proposedScale : 1
        let proposedWidth = bounds.width * scale, proposedHeight = bounds.height * scale
        let editorWidth = proposedWidth.isFinite && proposedWidth > 0 ? proposedWidth : 24
        let editorHeight = proposedHeight.isFinite && proposedHeight > 0 ? proposedHeight : 24
        let transform = layout?.pageToViewportTransform ?? .identity
        let font = pdfFont
        let proposedFontSize = font.pointSize * scale
        let editorFontSize = proposedFontSize.isFinite && proposedFontSize > 0 ? proposedFontSize : 14
        let presentation = IPadResearchTextEditorPresentation(
            font: font.withSize(editorFontSize),
            textColor: FreeTextAnnotationEditing.resolvedTextColor(session.values, draft: session.draft),
            isScrollEnabled: false, textAlignment: session.draft.annotation.alignment,
            autofocus: layout != nil && canEdit)
        IPadResearchNativeTextEditor(text: session.textBinding, commands: session.textCommands,
            identity: session.id, isEditable: canEdit && layout != nil,
            accessibilityLabel: L10n.string("Note Text"), presentation: presentation,
            onSubmit: onSubmit)
            .id(session.id)
            .frame(width: editorWidth, height: editorHeight)
            // Do not change annotation display flags: an autosave may be active.
            .background(Color.white)
            .clipped()
            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
            .rotationEffect(.radians(Double(atan2(transform.b, transform.a))))
            .position(CGPoint(x: bounds.width / 2, y: bounds.height / 2).applying(transform))
            .opacity(layout == nil ? 0 : 1)
            .allowsHitTesting(canEdit && layout != nil)
            .accessibilityHidden(layout == nil)
            .accessibilityIdentifier("ipad.note.inlineText")
            .onAppear { onBoundsChanged(session.id, bounds) }
            .onChange(of: bounds) { _, next in onBoundsChanged(session.id, next) }
            .onChange(of: layout == nil) { _, hidden in if hidden { _ = session.finishIME() } }
    }
}

/// Actual UIKit composition and shared PDF mutations in an isolated fixture.
/// This does not synthesize a Pencil, hardware keyboard, or production screen.
@MainActor
enum IPadInlineNoteEditorDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0, failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearInlineNote-\(UUID())")
        let suite = "DogearInlineNote.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { return (1, ["Could not isolate inline-note defaults."]) }
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("recovery"))
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let originalURL = root.appendingPathComponent("original.pdf")
            let originalBytes = UIGraphicsPDFRenderer(bounds: .init(x: 0, y: 0, width: 600, height: 800)).pdfData {
                $0.beginPage()
                ("Native note fixture" as NSString).draw(at: .init(x: 40, y: 40),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
            try originalBytes.write(to: originalURL)
            let access = DocumentAccessCoordinator(saveQueue: queue)
            let store = PDFDocumentStore(feedbackCenter: OperationFeedbackCenter(userDefaults: defaults),
                metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("metadata.json")),
                aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("groups.json")),
                workingCopyStore: try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies")),
                saveQueue: queue, accessCoordinator: access, exportPresenter: IPadDocumentExportPresenter())
            defer { store.releaseEditorAccess() }
            let undo = UndoManager(); undo.groupsByEvent = false; store.setUndoManager(undo)
            guard store.openPDF(from: originalURL), let document = store.document, let page = document.page(at: 0),
                  let draft = store.newFreeTextDraft(page: page, bounds: .init(x: 100, y: 480, width: 240, height: 120)) else {
                throw DocumentAccessError.snapshotUnavailable
            }
            let session = IPadInlineNoteEditingSession(draft: draft)
            let native = IPadResearchNativeTextView(frame: .init(x: 0, y: 0, width: 480, height: 240))
            var input = IPadResearchNativeTextEditor(text: session.textBinding, commands: session.textCommands,
                identity: session.id, presentation: .init(font: draft.annotation.font!.withSize(28), textColor: .red,
                    isScrollEnabled: false))
            let coordinator = IPadResearchNativeTextEditor.Coordinator(input)
            coordinator.install(native)
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let previous = scene?.windows.first(where: \.isKeyWindow)
            let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: native.frame)
            let controller = UIViewController(); controller.view.addSubview(native)
            window.rootViewController = controller; window.makeKeyAndVisible()
            defer {
                IPadResearchNativeTextEditor.dismantleUIView(native, coordinator: coordinator)
                window.isHidden = true; previous?.makeKey()
            }
            native.becomeFirstResponder(); session.textCommands.activate(native)
            await settle()
            expect(native.isFirstResponder && native.window === window, "Inline fixture owns an actual focused UITextView.")
            native.insertText("Inline "); coordinator.textViewDidChange(native)
            let selection = native.selectedRange
            expect(native.undoManager?.canUndo == true, "Inline native typing records independent text Undo.")
            await verifyFloatingControls(document: document, page: page, noteBounds: draft.originalBounds,
                editor: native, controller: controller, expect: expect)
            await verifySelectionOnlyProbe(editor: native, coordinator: coordinator, controller: controller, expect: expect)
            input.presentation = .init(font: draft.annotation.font!.withSize(42), textColor: .red, isScrollEnabled: false)
            coordinator.parent = input; coordinator.install(native)
            expect(native.font?.pointSize == 42 && native.textContainerInset == .zero
                && native.textContainer.lineFragmentPadding == 0 && !native.adjustsFontForContentSizeCategory,
                "Note font follows PDF font times actual scale, with zero native padding.")
            expect(native.undoManager?.canUndo == true && native.selectedRange == selection && native.text == "Inline ",
                "Updating native note presentation preserves text, selection and Undo history.")
            native.setMarkedText("中文", selectedRange: .init(location: 2, length: 0))
            expect(native.markedTextRange != nil && draft.annotation.page == nil,
                "Actual marked Chinese input remains detached before explicit Save.")
            expect(!session.textCommands.commitMarkedTextAndEndEditing(identity: UUID()) && native.markedTextRange != nil,
                "Another draft UUID cannot finish inline composition.")
            let expectedBounds = session.bounds
            undo.beginUndoGrouping()
            let saved = session.save(in: store, canCommit: { true })
            undo.endUndoGrouping()
            expect(saved, "Inline Save commits composition through the shared PDF Store.")
            expect(native.markedTextRange == nil && draft.annotation.contents == session.values.text
                && session.values.text.contains("中文") && session.completion == .saved,
                "Saved FreeText contains the complete marked input and reports explicit saved completion.")
            expect(draft.annotation.page === page && draft.annotation.type == "FreeText"
                && draft.annotation.bounds == expectedBounds && draft.annotation.font?.pointSize == 14,
                "Standard PDF FreeText preserves resolved PDF bounds and the unscaled 14-point PDF font.")
            expect(undo.canUndo && undo.undoActionName == "Add Free Text Note",
                "Saving one inline draft records one document Undo action.")
            store.undoDocumentChange()
            expect(draft.annotation.page == nil && !undo.canUndo && undo.canRedo,
                "One document Undo removes the complete saved note, independently of native text history.")
            store.redoDocumentChange()
            expect(draft.annotation.page === page && draft.annotation.contents?.contains("中文") == true,
                "Document Redo restores the same standard note and Chinese contents.")
            if let serialized = document.dataRepresentation(), let reload = PDFDocument(data: serialized),
               let note = reload.page(at: 0)?.annotations.first(where: { $0.type == "FreeText" }) {
                expect(note.contents == session.values.text && note.bounds == expectedBounds && note.font?.pointSize == 14,
                    "Actual PDF serialization preserves standard note content, placement and font size.")
            } else { expect(false, "Saved inline note could not be read back through PDFKit.") }

            guard let cancelledDraft = store.newFreeTextDraft(page: page, bounds: .init(x: 80, y: 280, width: 240, height: 120)) else {
                throw DocumentAccessError.snapshotUnavailable
            }
            let cancelled = IPadInlineNoteEditingSession(draft: cancelledDraft)
            let initialSnapshot = DocumentSnapshot(document), initialUndo = UndoSnapshot(undo)
            let control1 = document.dataRepresentation()
            let snapshot1 = DocumentSnapshot(document), undo1 = UndoSnapshot(undo)
            let control2 = document.dataRepresentation()
            let snapshot2 = DocumentSnapshot(document), undo2 = UndoSnapshot(undo)
            let control3 = document.dataRepresentation()
            let beforeCancel = DocumentSnapshot(document), beforeCancelUndo = UndoSnapshot(undo)
            let controlAvailable = control1 != nil && control2 != nil && control3 != nil
            let control12Equal = control1 == control2, control23Equal = control2 == control3
            let controlStable = controlAvailable && control12Equal && control23Equal
            expect(controlAvailable && initialSnapshot == snapshot1 && snapshot1 == snapshot2 && snapshot2 == beforeCancel
                && initialUndo == undo1 && undo1 == undo2 && undo2 == beforeCancelUndo,
                "Three no-operation PDF serialization controls retain the complete immutable PDF and Undo snapshots.")
            print("Inline note serialization control: available=\(controlAvailable), pair12Equal=\(control12Equal), pair23Equal=\(control23Equal), bytes=\(control1?.count ?? -1)/\(control2?.count ?? -1)/\(control3?.count ?? -1), deepEqual=\(initialSnapshot == beforeCancel), undoEqual=\(initialUndo == beforeCancelUndo)")
            cancelled.values.text = "Unsaved detached draft"
            expect(!cancelled.requestDiscard() && cancelled.confirmsDiscard && cancelled.completion == nil,
                "Cancel requests confirmation for a dirty draft and preserves it.")
            cancelled.beforeDiscard = { false }
            let refusedDiscard = !cancelled.discard()
            let afterFailedCleanup = document.dataRepresentation()
            let failedCleanupSnapshot = DocumentSnapshot(document), failedCleanupUndo = UndoSnapshot(undo)
            let failedCleanupBytesMatch = afterFailedCleanup != nil && (!controlStable || afterFailedCleanup == control3)
            let failedCleanupOriginalUnchanged = try Data(contentsOf: originalURL) == originalBytes
            print("Inline note failed cleanup: bytes=\(afterFailedCleanup?.count ?? -1), strictBytes=\(controlStable), bytesEqual=\(afterFailedCleanup == control3), deepEqual=\(failedCleanupSnapshot == beforeCancel), undoEqual=\(failedCleanupUndo == beforeCancelUndo), originalEqual=\(failedCleanupOriginalUnchanged)")
            expect(refusedDiscard && cancelled.completion == nil && cancelled.isDirty
                && cancelled.values.text == "Unsaved detached draft" && controlAvailable && failedCleanupBytesMatch
                && failedCleanupSnapshot == beforeCancel && failedCleanupUndo == beforeCancelUndo
                && failedCleanupOriginalUnchanged,
                "Failed draft-recovery cleanup preserves the detached draft, complete PDF and Undo snapshots, and strict original bytes; stable serialization also preserves exact PDF output bytes.")
            cancelled.beforeDiscard = { true }
            expect(cancelled.discard() && cancelled.completion == .discarded,
                "Explicit confirmed discard reports completion without applying PDF edits.")
            let afterDiscard = document.dataRepresentation()
            let discardSnapshot = DocumentSnapshot(document), discardUndo = UndoSnapshot(undo)
            let discardBytesMatch = afterDiscard != nil && (!controlStable || afterDiscard == control3)
            let discardOriginalUnchanged = try Data(contentsOf: originalURL) == originalBytes
            print("Inline note confirmed discard: bytes=\(afterDiscard?.count ?? -1), strictBytes=\(controlStable), bytesEqual=\(afterDiscard == control3), deepEqual=\(discardSnapshot == beforeCancel), undoEqual=\(discardUndo == beforeCancelUndo), originalEqual=\(discardOriginalUnchanged)")
            expect(cancelledDraft.annotation.page == nil && controlAvailable && discardBytesMatch
                && discardSnapshot == beforeCancel && discardUndo == beforeCancelUndo
                && discardOriginalUnchanged,
                "Discard preserves complete immutable PDF and Undo snapshots and strict original bytes; stable serialization also preserves exact PDF output bytes.")

            guard let retainedDraft = store.newFreeTextDraft(page: page, bounds: .init(x: 60, y: 200, width: 240, height: 120)) else {
                throw DocumentAccessError.snapshotUnavailable
            }
            let retained = IPadInlineNoteEditingSession(draft: retainedDraft)
            let retainedNative = IPadResearchNativeTextView(frame: native.frame)
            let retainedInput = IPadResearchNativeTextEditor(text: retained.textBinding,
                commands: retained.textCommands, identity: retained.id,
                presentation: .init(font: .systemFont(ofSize: 28), textColor: .red, autofocus: true))
            let retainedCoordinator = IPadResearchNativeTextEditor.Coordinator(retainedInput)
            retainedCoordinator.install(retainedNative); controller.view.addSubview(retainedNative)
            retainedNative.becomeFirstResponder(); retained.textCommands.activate(retainedNative)
            retainedNative.insertText("Retained "); retainedCoordinator.textViewDidChange(retainedNative)
            retainedNative.setMarkedText("保留", selectedRange: .init(location: 2, length: 0))
            IPadResearchNativeTextEditor.dismantleUIView(retainedNative, coordinator: retainedCoordinator)
            _ = retainedNative.resignFirstResponder()
            await settle()
            expect(retained.values.text.contains("保留") && retainedNative.markedTextRange == nil
                && retained.completion == nil && retainedDraft.annotation.page == nil,
                "Unmounting the representation commits composition only to its retained detached session.")
            expect(!retainedNative.isFirstResponder,
                "A dismantled installation cannot execute a queued autofocus against a later editor.")
            let fixedID = retained.id, retainedValues = retained.values
            let replacementURL = root.appendingPathComponent("replacement.pdf")
            try originalBytes.write(to: replacementURL)
            expect(store.openPDF(from: replacementURL) && store.document !== document,
                "Failure fixture installs a genuinely different PDF identity.")
            expect(!retained.save(in: store, canCommit: { true }) && retained.values == retainedValues
                && retained.id == fixedID && retained.draft.document === document && retained.error != nil
                && retained.completion == nil && retainedDraft.annotation.page == nil,
                "A changed-document Save retains text, fixed UUID and original PDF identity without redirecting edits.")
            await queue.drain()
            await settle()
            expect(try Data(contentsOf: originalURL) == originalBytes,
                "Inline Save and discard leave the original on-disk PDF bytes unchanged.")
        } catch { failures.append("Inline-note fixture setup failed: \(error.localizedDescription)") }
        await queue.drain()
        await settle()
        return (checks, failures)
    }

    private static func settle() async {
        for _ in 0..<3 { await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        } }
    }

    private static func verifyFloatingControls(document: PDFDocument, page: PDFPage, noteBounds: CGRect,
                                               editor: IPadResearchNativeTextView, controller: UIViewController,
                                               expect: (Bool, String) -> Void) async {
        let focusBeforePDF = editor.isFirstResponder
        let originalRotation = page.rotation, selection = editor.selectedRange, editorText = editor.text
        let originalHistory = editor.undoManager.map { UndoSnapshot($0) }
        let annotations = page.annotations.map(ObjectIdentifier.init)
        let pdf = PDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 800))
        controller.view.insertSubview(pdf, at: 0); pdf.document = document; pdf.displayMode = .singlePage
        pdf.autoScales = false; pdf.scaleFactor = 1
        let focusAfterPDF = editor.isFirstResponder
        defer { page.rotation = originalRotation; pdf.removeFromSuperview() }
        // PDFKit's real document installation resigns the previously focused
        // text view. Production installs the PDF before opening its note editor;
        // establish that same ordering before testing read-only control geometry.
        pdf.layoutDocumentView(); pdf.go(to: noteBounds, on: page)
        await settle()
        let focusAfterSetup = editor.isFirstResponder
        let focusRequest = editor.becomeFirstResponder()
        editor.commands?.activate(editor)
        await settle()
        let focusReady = editor.isFirstResponder && editor.window?.isKeyWindow == true
            && editor.window === pdf.window && editor.window === controller.view.window
        let setupHistoryEqual = editor.undoManager.map { UndoSnapshot($0) } == originalHistory
        print("DogearInlineControls setup focusBeforePDF=\(focusBeforePDF) focusAfterPDF=\(focusAfterPDF) focusAfterSetup=\(focusAfterSetup) focusRequest=\(focusRequest) focusReady=\(focusReady) key=\(editor.window?.isKeyWindow == true) exactWindow=\(editor.window === pdf.window) selection=\(editor.selectedRange == selection) text=\(editor.text == editorText) undo=\(setupHistoryEqual) annotations=\(page.annotations.map(ObjectIdentifier.init) == annotations)")
        expect(focusReady && pdf.document === document && editor.selectedRange == selection && editor.text == editorText
            && setupHistoryEqual && page.annotations.map(ObjectIdentifier.init) == annotations,
            "The fully installed native PDF establishes a focused, window-ready note fixture without changing its text, selection, Undo or annotations.")
        func caret() -> CGRect? {
            editor.selectedTextRange.map { pdf.convert(editor.caretRect(for: $0.end), from: editor) }
        }
        for rotation in [0, 90] {
            let focusBeforeGo = editor.isFirstResponder
            page.rotation = rotation; pdf.layoutDocumentView(); pdf.go(to: noteBounds, on: page)
            await settle()
            let note = pdf.convert(noteBounds, from: page), cursor = caret()
            let placement = IPadInlineNoteControlsLayout(noteFrame: note, viewport: pdf.bounds, caretFrame: cursor).frame
            let sizeOK = placement.map { $0.width == 600 && $0.height == 44 } == true
            let viewportOK = placement.map { pdf.bounds.insetBy(dx: 6, dy: 6).contains($0) } == true
            let noteOK = placement.map { !$0.intersects(note) } == true
            let caretOK = placement.map { !(cursor?.insetBy(dx: -4, dy: -4).intersects($0) ?? false) } == true
            print("DogearInlineControls rotation=\(rotation) viewport=\(pdf.bounds) note=\(note) caret=\(String(describing: cursor)) placement=\(String(describing: placement)) size=\(sizeOK) viewportSafe=\(viewportOK) noteSafe=\(noteOK) caretSafe=\(caretOK) document=\(pdf.document === document) focusBeforePDF=\(focusBeforePDF) focusAfterPDF=\(focusAfterPDF) focusBeforeGo=\(focusBeforeGo) focus=\(editor.isFirstResponder) key=\(editor.window?.isKeyWindow == true) pdfFocus=\(pdf.isFirstResponder) scale=\(pdf.scaleFactor)")
            expect(sizeOK && viewportOK && noteOK && caretOK
                && pdf.document === document && editor.isFirstResponder,
                "Floating note controls use real PDFKit rotation \(rotation), remain outside its displayed text rectangle and native caret, and retain 44-point touch targets.")
        }
        pdf.frame.size.height = 300; pdf.layoutDocumentView(); pdf.go(to: noteBounds, on: page)
        await settle()
        let note = pdf.convert(noteBounds, from: page), cursor = caret()
        let keyboard = CGRect(x: 0, y: 216, width: pdf.bounds.width, height: 84)
        let shortened = IPadInlineNoteControlsLayout(noteFrame: note, viewport: pdf.bounds,
            keyboardFrame: keyboard, caretFrame: cursor).frame
        expect(shortened.map { pdf.bounds.insetBy(dx: 6, dy: 6).contains($0) && $0.height == 44
            && !$0.intersects(keyboard) && !(cursor?.insetBy(dx: -4, dy: -4).intersects($0) ?? false) } == true,
            "A resized native viewport and keyboard obstruction clamp the floating controls without covering the native caret or keyboard.")
        let offscreen = IPadInlineNoteControlsLayout(noteFrame: nil, viewport: pdf.bounds,
            keyboardFrame: keyboard, caretFrame: cursor).frame
        let unavailable = IPadInlineNoteControlsLayout(noteFrame: nil, viewport: CGRect(x: 0, y: 0, width: 240, height: 50)).frame
        let recovered = IPadInlineNoteControlsLayout(noteFrame: nil, viewport: pdf.bounds,
            keyboardFrame: keyboard, caretFrame: cursor).frame
        let narrowViewport = CGRect(x: 0, y: 0, width: 240, height: 300)
        let narrow = IPadInlineNoteControlsLayout(noteFrame: nil, viewport: narrowViewport,
            keyboardFrame: keyboard, caretFrame: cursor).frame
        expect(narrow.map { $0.width == 228 && $0.height == 44 && narrowViewport.insetBy(dx: 6, dy: 6).contains($0)
            && !$0.intersects(keyboard) && !(cursor?.insetBy(dx: -4, dy: -4).intersects($0) ?? false) } == true
            && IPadInlineNoteControlsLayout.visualRowHeight == 32
            && IPadInlineNoteControlsLayout.rowHeight - IPadInlineNoteControlsLayout.visualRowHeight == 12,
            "A 240-point native viewport retains a 228-point scrolling control entry with 44-point touch geometry, 32-point material and safe keyboard/caret clearance.")
        let offscreenViewportOK = offscreen.map { pdf.bounds.insetBy(dx: 6, dy: 6).contains($0) } == true
        let offscreenKeyboardOK = offscreen.map { !$0.intersects(keyboard) } == true
        let offscreenCaretOK = offscreen.map { !(cursor?.insetBy(dx: -4, dy: -4).intersects($0) ?? false) } == true
        print("DogearInlineControls offscreen viewport=\(pdf.bounds) caret=\(String(describing: cursor)) keyboard=\(keyboard) placement=\(String(describing: offscreen)) recovered=\(String(describing: recovered)) unavailable=\(String(describing: unavailable)) viewportSafe=\(offscreenViewportOK) keyboardSafe=\(offscreenKeyboardOK) caretSafe=\(offscreenCaretOK) selection=\(editor.selectedRange == selection) text=\(editor.text == editorText) focus=\(editor.isFirstResponder) undo=\(editor.undoManager?.canUndo == true) annotations=\(page.annotations.map(ObjectIdentifier.init) == annotations)")
        expect(offscreenViewportOK && offscreenKeyboardOK && offscreenCaretOK
            && unavailable == nil && recovered == offscreen && editor.selectedRange == selection && editor.text == editorText
            && editor.isFirstResponder && editor.undoManager?.canUndo == true && page.annotations.map(ObjectIdentifier.init) == annotations,
            "An offscreen note retains a safe floating Save/Cancel entry; an unusable 44-point viewport hides it until recovery without changing native text, selection, Undo or PDF annotations.")
    }

    private static func verifySelectionOnlyProbe(editor: IPadResearchNativeTextView,
                                                 coordinator: IPadResearchNativeTextEditor.Coordinator,
                                                 controller: UIViewController, expect: (Bool, String) -> Void) async {
        guard let undo = editor.undoManager else { expect(false, "Caret-only fixture requires its native text Undo owner."); return }
        let selection = editor.selectedRange, text = editor.text, history = UndoSnapshot(undo)
        let marked = editor.markedTextRange
        let probe = IPadInlineNoteViewportProbe.ProbeView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        probe.isUserInteractionEnabled = false; probe.keyboardLayoutGuide.followsUndockedKeyboard = true
        probe.identity = editor.editorIdentity; probe.isActive = true
        var reports: [(CGRect, CGRect?)] = []
        probe.onChange = { keyboard, caret in if let caret { reports.append((caret, keyboard)) } }
        controller.view.addSubview(probe); probe.layoutIfNeeded(); probe.scheduleReport(); await settle()
        defer {
            probe.onChange = nil; probe.isActive = false; probe.stopObserving(); probe.removeFromSuperview()
            editor.selectedRange = selection
        }
        let before = reports.last
        let beforeReportCount = reports.count
        let oversized = CGRect(x: 0, y: 0, width: 600, height: 300)
        let beforePlacement = before.flatMap {
            IPadInlineNoteControlsLayout(noteFrame: oversized, viewport: probe.bounds, keyboardFrame: $0.1, caretFrame: $0.0).frame
        }
        editor.selectedRange = NSRange(location: 0, length: 0)
        coordinator.textViewDidChangeSelection(editor)
        await settle()
        let after = reports.last
        let afterPlacement = after.flatMap {
            IPadInlineNoteControlsLayout(noteFrame: oversized, viewport: probe.bounds, keyboardFrame: $0.1, caretFrame: $0.0).frame
        }
        let caretChanged = before?.0 != nil && after?.0 != nil && before?.0 != after?.0
        let placementChanged = beforePlacement != nil && afterPlacement != nil && beforePlacement != afterPlacement
        let caretSafe = afterPlacement.map { !(after?.0.insetBy(dx: -4, dy: -4).intersects($0) ?? true) } == true
        let keyboardSafe = afterPlacement.map { !(after?.1?.intersects($0) ?? false) } == true
        print("DogearInlineControls selectionOnly reports=\(beforeReportCount)/\(reports.count) viewport=\(probe.bounds) caretBefore=\(String(describing: before?.0)) caretAfter=\(String(describing: after?.0)) keyboardBefore=\(String(describing: before?.1)) keyboardAfter=\(String(describing: after?.1)) placementBefore=\(String(describing: beforePlacement)) placementAfter=\(String(describing: afterPlacement)) caretChanged=\(caretChanged) placementChanged=\(placementChanged) caretSafe=\(caretSafe) keyboardSafe=\(keyboardSafe) focus=\(editor.isFirstResponder) key=\(probe.window?.isKeyWindow == true) exactIdentity=\(editor.editorIdentity == probe.identity) exactWindow=\(editor.window === probe.window) selectionBefore=\(selection) selectionAfter=\(editor.selectedRange) text=\(editor.text == text) marked=\((editor.markedTextRange != nil) == (marked != nil)) undo=\(UndoSnapshot(undo) == history)")
        expect(caretChanged && placementChanged && caretSafe && keyboardSafe
            && editor.isFirstResponder && editor.editorIdentity == probe.identity && editor.window === probe.window
            && editor.selectedRange == NSRange(location: 0, length: 0) && editor.text == text
            && (editor.markedTextRange != nil) == (marked != nil) && UndoSnapshot(undo) == history,
            "An exact native selection-only notification recomputes caret-safe floating placement without changing text, marked state, focus or native Undo history.")
    }

    private struct UndoSnapshot: Equatable {
        let undoName: String, redoName: String
        let canUndo: Bool, canRedo: Bool, isUndoing: Bool, isRedoing: Bool, groupsByEvent: Bool
        let groupingLevel: Int, levelsOfUndo: Int
        @MainActor init(_ undo: UndoManager) {
            undoName = undo.undoActionName; redoName = undo.redoActionName
            canUndo = undo.canUndo; canRedo = undo.canRedo
            isUndoing = undo.isUndoing; isRedoing = undo.isRedoing; groupsByEvent = undo.groupsByEvent
            groupingLevel = undo.groupingLevel; levelsOfUndo = undo.levelsOfUndo
        }
    }

    private struct DocumentSnapshot: Equatable {
        let identity: ObjectIdentifier
        let pageCount: Int
        let attributes: String
        let pages: [PageSnapshot]
        @MainActor init(_ document: PDFDocument) {
            identity = ObjectIdentifier(document); pageCount = document.pageCount
            attributes = IPadInlineNoteEditorDiagnostics.frozenValue(document.documentAttributes)
            pages = (0..<document.pageCount).compactMap { document.page(at: $0).map { PageSnapshot($0) } }
        }
    }

    private struct PageSnapshot: Equatable {
        let identity: ObjectIdentifier
        let text: String?
        let rotation: Int
        let boxes: [CGRect]
        let annotations: [FreeTextAnnotationSnapshot]
        @MainActor init(_ page: PDFPage) {
            identity = ObjectIdentifier(page); text = page.string; rotation = page.rotation
            boxes = [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox].map { page.bounds(for: $0) }
            annotations = page.annotations.map { FreeTextAnnotationSnapshot($0) }
        }
    }

    private struct FreeTextAnnotationSnapshot: Equatable {
        let identity: ObjectIdentifier, pageIdentity: ObjectIdentifier?
        let type: String?, contents: String?, userName: String?
        let bounds: CGRect
        let font: String, fontColor: String, color: String, interiorColor: String, border: String
        let alignment: Int
        let shouldDisplay: Bool, shouldPrint: Bool, hasAppearance: Bool, highlighted: Bool
        let modificationDate: Date?
        let keyValues: [String: String]
        @MainActor init(_ annotation: PDFAnnotation) {
            let ownerPageIdentity = annotation.page.map(ObjectIdentifier.init)
            identity = ObjectIdentifier(annotation); pageIdentity = ownerPageIdentity
            type = annotation.type; contents = annotation.contents; userName = annotation.userName; bounds = annotation.bounds
            font = IPadInlineNoteEditorDiagnostics.frozenValue(annotation.font)
            // Native annotations may omit color keys despite the nonnull
            // imported color accessor. KVC preserves the actual optional value.
            fontColor = IPadInlineNoteEditorDiagnostics.frozenValue(annotation.value(forKey: "fontColor"))
            color = IPadInlineNoteEditorDiagnostics.frozenValue(annotation.value(forKey: "color"))
            interiorColor = IPadInlineNoteEditorDiagnostics.frozenValue(annotation.value(forKey: "interiorColor"))
            border = IPadInlineNoteEditorDiagnostics.frozenValue(annotation.border); alignment = annotation.alignment.rawValue
            shouldDisplay = annotation.shouldDisplay; shouldPrint = annotation.shouldPrint
            hasAppearance = annotation.hasAppearanceStream; highlighted = annotation.isHighlighted
            modificationDate = annotation.modificationDate
            // PDFKit returns a deep copy. Freeze its values immediately into
            // strings, retaining no mutable NSDictionary/Any references. /P is
            // separately captured by the actual owning page's identity above.
            keyValues = Dictionary(uniqueKeysWithValues: annotation.annotationKeyValues.map { key, value in
                let name = String(describing: key)
                return (name, name == "/P" ? String(describing: ownerPageIdentity) : IPadInlineNoteEditorDiagnostics.frozenValue(value))
            })
        }
    }

    /// Canonicalizes only values exposed by native PDF annotation dictionaries.
    /// These frozen values remain in memory and are never included in logging.
    private static func frozenValue(_ value: Any?) -> String {
        guard let value else { return "nil" }
        func field(_ text: String) -> String { "\(text.utf8.count):\(text)" }
        if let font = value as? UIFont {
            return "font" + field(font.fontName) + field(String(describing: font.pointSize)) + frozenValue(font.fontDescriptor.fontAttributes)
        }
        if let descriptor = value as? UIFontDescriptor { return "descriptor" + frozenValue(descriptor.fontAttributes) }
        if let color = value as? UIColor {
            let resolved = color.resolvedColor(with: .init(userInterfaceStyle: .light))
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            let rgb = resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return "color:\(rgb):\(red):\(green):\(blue):\(alpha):" + field(String(describing: resolved.cgColor.components))
        }
        if let border = value as? PDFBorder { return "border" + frozenValue(border.borderKeyValues) }
        if let dictionary = value as? NSDictionary {
            return "dictionary" + dictionary.map { (String(describing: $0.key), frozenValue($0.value)) }
                .sorted { $0.0 < $1.0 }.map { field($0.0) + field($0.1) }.joined()
        }
        if let array = value as? NSArray { return "array" + array.map { field(frozenValue($0)) }.joined() }
        if let data = value as? Data { return "data" + data.base64EncodedString() }
        if let date = value as? Date { return "date:\(date.timeIntervalSinceReferenceDate)" }
        if let number = value as? NSNumber { return "number" + field(String(cString: number.objCType)) + field(number.stringValue) }
        if let text = value as? String { return "string" + field(text) }
        if value is NSNull { return "null" }
        return field(String(reflecting: type(of: value))) + field(String(describing: value))
    }
}
#endif
