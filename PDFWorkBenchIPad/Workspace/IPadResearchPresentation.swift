#if os(iOS)
import Combine
import SwiftUI
import UIKit

/// Retained by one Group workspace. It owns layout preference only; Research
/// sessions, editor text and the PDF continue to belong to their existing owners.
@MainActor
final class IPadResearchPresentation: ObservableObject {
    enum Width: Equatable { case fullWidth, sidebar }
    @Published var preferredWidth: Width?
    @Published private(set) var hasOpenedResearch = false
    var focusTrace: ((String) -> Void)?

    init(preferredWidth: Width? = nil) { self.preferredWidth = preferredWidth }

    func resolvedWidth(windowSize: CGSize) -> Width {
        preferredWidth ?? Self.defaultWidth(windowSize: windowSize)
    }

    static func defaultWidth(windowSize: CGSize) -> Width {
        guard windowSize.width.isFinite, windowSize.height.isFinite,
              windowSize.width > 0, windowSize.height > 0 else { return .fullWidth }
        return windowSize.width > windowSize.height ? .sidebar : .fullWidth
    }

    func recordResearchOpened() {
        if !hasOpenedResearch { hasOpenedResearch = true }
    }

    func toggleWidth(windowSize: CGSize) {
        preferredWidth = resolvedWidth(windowSize: windowSize) == .fullWidth ? .sidebar : .fullWidth
    }
}

struct IPadResearchPaneLayout: Equatable {
    static let minimumReaderWidth: CGFloat = 240
    static let minimumResearchWidth: CGFloat = 320
    static let dividerWidth: CGFloat = 1
    let readerFrame: CGRect
    let researchFrame: CGRect
    let readerVisible: Bool
    let researchVisible: Bool
    let isSidebar: Bool

    init(availableSize: CGSize, showsResearch: Bool, width: IPadResearchPresentation.Width) {
        let size = CGSize(width: availableSize.width.isFinite ? max(0, availableSize.width) : 0,
            height: availableSize.height.isFinite ? max(0, availableSize.height) : 0)
        isSidebar = showsResearch && width == .sidebar
            && size.width >= Self.minimumReaderWidth + Self.minimumResearchWidth + Self.dividerWidth
        readerVisible = !showsResearch || isSidebar
        researchVisible = showsResearch
        if isSidebar {
            let researchWidth = min(size.width - Self.minimumReaderWidth - Self.dividerWidth,
                max(Self.minimumResearchWidth, min(420, size.width * 0.42)))
            let readerWidth = size.width - researchWidth - Self.dividerWidth
            readerFrame = CGRect(origin: .zero, size: CGSize(width: readerWidth, height: size.height))
            researchFrame = CGRect(x: readerWidth + Self.dividerWidth, y: 0, width: researchWidth, height: size.height)
        } else {
            readerFrame = CGRect(origin: .zero, size: size)
            researchFrame = CGRect(origin: .zero, size: size)
        }
    }
}

/// Both native views keep the same parent and structural slot. A full Research
/// pane hides the PDF without detaching it or collapsing its last visible size.
struct IPadResearchWorkspacePanes<Reader: View, Research: View>: View {
    let showsResearch: Bool
    @ObservedObject var presentation: IPadResearchPresentation
    let windowSize: CGSize
    let isPresentationActive: Bool
    private let reader: (Bool) -> Reader
    private let research: () -> Research
    @State private var retainedReaderSize: CGSize?
    @State private var retainedResearchSize: CGSize?

    init(showsResearch: Bool, presentation: IPadResearchPresentation, windowSize: CGSize,
         isPresentationActive: Bool = true,
         @ViewBuilder reader: @escaping (Bool) -> Reader,
         @ViewBuilder research: @escaping () -> Research) {
        self.showsResearch = showsResearch; self.presentation = presentation; self.windowSize = windowSize
        self.isPresentationActive = isPresentationActive
        self.reader = reader; self.research = research
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = IPadResearchPaneLayout(availableSize: geometry.size, showsResearch: showsResearch,
                width: presentation.resolvedWidth(windowSize: windowSize))
            let readerSize = layout.readerVisible ? layout.readerFrame.size : retainedReaderSize ?? layout.readerFrame.size
            let researchSize = layout.researchVisible ? layout.researchFrame.size : retainedResearchSize ?? layout.researchFrame.size
            ZStack(alignment: .topLeading) {
                reader(layout.readerVisible)
                    .frame(width: readerSize.width, height: readerSize.height)
                    .opacity(layout.readerVisible ? 1 : 0)
                    .allowsHitTesting(layout.readerVisible).accessibilityHidden(!layout.readerVisible)
                if showsResearch || presentation.hasOpenedResearch {
                    IPadResearchFocusScope(content: research(), presentation: presentation,
                        isActive: isPresentationActive && layout.researchVisible)
                        .frame(width: researchSize.width, height: researchSize.height)
                        .offset(x: layout.researchFrame.minX, y: layout.researchFrame.minY)
                        .opacity(layout.researchVisible ? 1 : 0)
                        .allowsHitTesting(layout.researchVisible).accessibilityHidden(!layout.researchVisible)
                }
                if layout.isSidebar {
                    Divider().frame(width: IPadResearchPaneLayout.dividerWidth, height: geometry.size.height)
                        .offset(x: layout.readerFrame.maxX)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
            .onAppear { retainVisibleSizes(layout) }
            .onChange(of: layout) { _, value in retainVisibleSizes(value) }
        }
        .onAppear { if showsResearch { presentation.recordResearchOpened() } }
        .onChange(of: showsResearch) { _, visible in if visible { presentation.recordResearchOpened() } }
    }

    private func retainVisibleSizes(_ layout: IPadResearchPaneLayout) {
        if layout.readerVisible, layout.readerFrame.width > 0, layout.readerFrame.height > 0 {
            retainedReaderSize = layout.readerFrame.size
        }
        if layout.researchVisible, layout.researchFrame.width > 0, layout.researchFrame.height > 0 {
            retainedResearchSize = layout.researchFrame.size
        }
    }
}

/// A stable public UIKit boundary gives focus continuity an exact Research
/// subtree. A width change may drop native focus while preserving composition;
/// only the field focused before that layout receives one restoration attempt.
private struct IPadResearchFocusScope<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let presentation: IPadResearchPresentation
    let isActive: Bool

    func makeUIViewController(context: Context) -> Controller {
        Controller(content: AnyView(content.environment(\.self, context.environment)),
                   presentation: presentation, isActive: isActive)
    }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(content: AnyView(content.environment(\.self, context.environment)),
                          presentation: presentation, isActive: isActive)
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.invalidate() }

    final class Controller: UIViewController {
        @MainActor private final class Lease {
            weak var editor: IPadResearchNativeTextView?
            weak var window: UIWindow?
            weak var delegate: (any UITextViewDelegate)?
            let identity: UUID
            let generation: UInt
            init(editor: IPadResearchNativeTextView, window: UIWindow, generation: UInt) {
                self.editor = editor; self.window = window; delegate = editor.delegate
                identity = editor.editorIdentity; self.generation = generation
            }
        }
        private final class ScopeView: UIView {
            var beforeGeometryChange: (() -> Void)?
            override var frame: CGRect {
                willSet { if newValue.size != frame.size { beforeGeometryChange?() } }
            }
            override var bounds: CGRect {
                willSet { if newValue.size != bounds.size { beforeGeometryChange?() } }
            }
        }
        private let host: UIHostingController<AnyView>
        private weak var presentation: IPadResearchPresentation?
        private var observation: AnyCancellable?
        private var inputObservations: [AnyCancellable] = []
        private var isActive = false
        private var isDismantled = false
        private var generation: UInt = 0
        private var lease: Lease?
        private var completion: Task<Void, Never>?

        init(content: AnyView, presentation: IPadResearchPresentation, isActive: Bool) {
            host = UIHostingController(rootView: content)
            super.init(nibName: nil, bundle: nil)
            configure(presentation: presentation, isActive: isActive)
            for name in [UITextView.textDidBeginEditingNotification, UITextField.textDidBeginEditingNotification] {
                inputObservations.append(NotificationCenter.default.publisher(for: name).sink { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let captured = self.lease, let input = notification.object as? UIView,
                              input.window === captured.window, input !== captured.editor else { return }
                        self.trace("other-input-began", captured: captured, input: input)
                        self.cancelLease(reason: "other-input-began")
                    }
                })
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func loadView() {
            let scope = ScopeView(); scope.backgroundColor = .clear
            scope.beforeGeometryChange = { [weak self] in self?.captureFocusedEditor() }
            view = scope
            addChild(host)
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            scope.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: scope.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: scope.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: scope.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: scope.bottomAnchor)
            ])
            host.didMove(toParent: self)
        }
        func update(content: AnyView, presentation: IPadResearchPresentation, isActive: Bool) {
            configure(presentation: presentation, isActive: isActive)
            host.rootView = content
        }
        private func configure(presentation: IPadResearchPresentation, isActive: Bool) {
            self.isActive = isActive
            if !isActive { cancelLease(reason: "inactive") }
            if self.presentation !== presentation {
                cancelLease(reason: "presentation-changed"); self.presentation = presentation
                observation = presentation.objectWillChange.sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.captureFocusedEditor() }
                }
            }
        }
        func invalidate() {
            isDismantled = true; isActive = false; observation = nil; inputObservations = []
            (viewIfLoaded as? ScopeView)?.beforeGeometryChange = nil
            cancelLease(reason: "dismantled")
        }
        private func cancelLease(reason: String) {
            if let captured = lease { trace("cancel-\(reason)", captured: captured) }
            generation &+= 1; lease = nil
            completion?.cancel(); completion = nil
        }
        private func captureFocusedEditor() {
            guard isActive, !isDismantled, let scope = viewIfLoaded,
                  let window = scope.window, window.isKeyWindow,
                  let editor = focusedEditor(in: scope), editor.isEditable,
                  editor.window === window else { return }
            generation &+= 1
            completion?.cancel(); completion = nil
            lease = Lease(editor: editor, window: window, generation: generation)
            if let captured = lease { trace("captured", captured: captured) }
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            guard completion == nil, let captured = lease else { return }
            completion = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                guard !Task.isCancelled, self.lease === captured,
                      self.generation == captured.generation else {
                    self.trace("cancel-stale-task", captured: captured); return
                }
                self.completion = nil
                self.lease = nil
                self.trace("restore-before", captured: captured)
                guard self.isActive, !self.isDismantled, let scope = self.viewIfLoaded,
                      let editor = captured.editor, let window = captured.window,
                      let expectedDelegate = captured.delegate,
                      scope.window === window, editor.window === window, window.isKeyWindow,
                      editor.isDescendant(of: scope), editor.editorIdentity == captured.identity,
                      editor.delegate === expectedDelegate, editor.isEditable else {
                    self.trace("cancel-restoration-guard", captured: captured); return
                }
                if editor.isFirstResponder { self.trace("already-focused", captured: captured); return }
                guard self.firstResponder(in: window) == nil else {
                    self.trace("cancel-other-responder", captured: captured); return
                }
                let restored = editor.becomeFirstResponder()
                self.trace("restore-after-\(restored)", captured: captured)
            }
        }
        private func trace(_ phase: String, captured: Lease, input: UIView? = nil) {
            guard let callback = presentation?.focusTrace else { return }
            let editor = captured.editor
            let window = captured.window
            let attached = window != nil && viewIfLoaded?.window === window && editor?.window === window
            let expectedDelegate = captured.delegate
            let editorMatches = expectedDelegate != nil && editor?.editorIdentity == captured.identity
                && editor?.delegate === expectedDelegate
            let scopeMatches = viewIfLoaded.map { editor?.isDescendant(of: $0) == true } ?? false
            let owner = window.flatMap { firstResponder(in: $0) }
            let ownerClass = owner.map { NSStringFromClass(type(of: $0)) } ?? "none"
            let ownerInScope = viewIfLoaded.map { owner?.isDescendant(of: $0) == true } ?? false
            let ownerTextInput = owner as? any UITextInput
            let inputClass = input.map { NSStringFromClass(type(of: $0)) } ?? "none"
            let details = "phase=\(phase), active=\(isActive), dismantled=\(isDismantled), "
                + "generation=\(generation), capturedGeneration=\(captured.generation), "
                + "focused=\(editor?.isFirstResponder == true), keyWindow=\(window?.isKeyWindow == true), "
                + "attached=\(attached), scopeMatches=\(scopeMatches), editorMatches=\(editorMatches), "
                + "capturedDelegateAlive=\(expectedDelegate != nil), currentDelegatePresent=\(editor?.delegate != nil), "
                + "editable=\(editor?.isEditable == true), ownerClass=\(ownerClass), "
                + "ownerIsEditor=\(owner != nil && owner === editor), ownerInScope=\(ownerInScope), "
                + "ownerIsTextInput=\(ownerTextInput != nil), ownerIsTextView=\(owner is UITextView), "
                + "ownerIsTextField=\(owner is UITextField), ownerEditable=\((owner as? UITextView)?.isEditable == true), "
                + "ownerMarked=\(ownerTextInput?.markedTextRange != nil), inputClass=\(inputClass)"
            callback(details)
        }
        private func focusedEditor(in root: UIView) -> IPadResearchNativeTextView? {
            if let editor = root as? IPadResearchNativeTextView, editor.isFirstResponder { return editor }
            for child in root.subviews { if let editor = focusedEditor(in: child) { return editor } }
            return nil
        }
        private func firstResponder(in root: UIView) -> UIView? {
            if root.isFirstResponder { return root }
            for child in root.subviews { if let responder = firstResponder(in: child) { return responder } }
            return nil
        }
    }
}

/// Sample this view's actual window, including Stage Manager and split windows.
/// Keyboard safe-area changes may resize SwiftUI content, never this input.
struct IPadWorkspaceWindowGeometry: UIViewRepresentable {
    let onChange: (CGSize) -> Void
    func makeUIView(context: Context) -> GeometryView {
        let view = GeometryView(); view.isUserInteractionEnabled = false; view.onChange = onChange
        return view
    }
    func updateUIView(_ view: GeometryView, context: Context) {
        view.onChange = onChange; view.reportGeometry()
    }

    final class GeometryView: UIView {
        var onChange: ((CGSize) -> Void)?
        private var reportedSize: CGSize?
        private var reportedWindow: ObjectIdentifier?
        override func didMoveToWindow() { super.didMoveToWindow(); reportGeometry() }
        override func layoutSubviews() { super.layoutSubviews(); reportGeometry() }
        func reportGeometry() {
            guard let window else { return }
            let size = window.bounds.size
            guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite,
                  size != reportedSize || reportedWindow != ObjectIdentifier(window) else { return }
            reportedSize = size; reportedWindow = ObjectIdentifier(window)
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window, window.bounds.size == size else { return }
                self.onChange?(size)
            }
        }
    }
}
#endif
