import AppKit
import Combine
import SwiftUI

/// Workspace identity and editing lifetime are independent of the containing window.
@MainActor
final class GroupWorkspaceContext: ObservableObject, Identifiable {
    let id: UUID
    var workspaceID: UUID { id }
    private(set) var groupID: UUID
    let undoManager = UndoManager()
    let titlebarController = GroupWorkspaceTitlebarController()
    @Published private(set) var isActive = false
    private weak var host: GroupWorkspaceHostController?
    private weak var boundWindow: NSWindow?
    var window: NSWindow? { boundWindow }
    private var onActivate: ((NSWindow?) -> Void)?
    private var onClose: (() -> Void)?
    private var didClose = false
    fileprivate var minimumContentSize = NSSize(width: 520, height: 680)

    init(payload: GroupWindowPayload) {
        id = payload.sessionID
        groupID = payload.groupID
        titlebarController.attach(workspace: self)
    }

    func setLifecycleHandlers(onActivate: @escaping (NSWindow?) -> Void, onClose: @escaping () -> Void) {
        guard !didClose else { return }
        let isInitialRegistration = self.onActivate == nil
        self.onActivate = onActivate
        self.onClose = onClose
        // Registration commonly happens while SwiftUI is attaching its native
        // view. Deliver after that update, using the current host and selection.
        if isInitialRegistration {
            DispatchQueue.main.async { [weak self] in self?.notifyActivation() }
        }
    }

    func updateGroupID(_ groupID: UUID) {
        guard self.groupID != groupID else { return }
        objectWillChange.send()
        self.groupID = groupID
        host?.refreshTitlebar()
        GroupWorkspaceHostRegistry.shared.scheduleSave()
    }

    func updateMinimumContentSize(_ size: NSSize) {
        guard size.width.isFinite, size.height.isFinite else { return }
        let value = NSSize(width: max(520, size.width), height: max(680, size.height))
        guard minimumContentSize != value else { return }
        minimumContentSize = value
        if isActive { host?.updateWindowMinimumSize() }
    }

    func select() { host?.select(workspaceID: id, bringToFront: true) }
    func close() { host?.close(workspaceID: id) }
    func selectNextWorkspace(backward: Bool = false) { host?.selectNext(backward: backward) }
    func openWorkspace(_ payload: GroupWindowPayload, newWindow: Bool = false) {
        host?.openWorkspace(payload, newWindow: newWindow)
    }

    fileprivate func bind(to host: GroupWorkspaceHostController?) {
        self.host = host
        updateWindow(host?.window)
    }

    fileprivate func updateWindow(_ window: NSWindow?) {
        guard boundWindow !== window else { return }
        objectWillChange.send()
        boundWindow = window
        titlebarController.hostDidChange()
        notifyActivation()
    }

    fileprivate func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        notifyActivation()
    }

    fileprivate func notifyActivation() {
        guard !didClose else { return }
        onActivate?(isActive ? boundWindow : nil)
    }

    fileprivate func finishClosing() {
        guard !didClose else { return }
        didClose = true
        isActive = false
        onActivate?(nil)
        onClose?()
        onActivate = nil
        onClose = nil
        titlebarController.finishClosing()
        host = nil
        boundWindow = nil
    }

    var owningHost: GroupWorkspaceHostController? { host }
}

/// SwiftUI supplies one content factory. Its result is created exactly once per
/// workspace; tab selection never replaces an NSHostingController.rootView.
struct GroupWorkspaceHostView: NSViewControllerRepresentable {
    let initialWorkspace: GroupWindowPayload
    let makeWorkspace: @MainActor (GroupWindowPayload, GroupWorkspaceContext) -> AnyView

    func makeNSViewController(context: Context) -> GroupWorkspaceHostController {
        let controller = GroupWorkspaceHostController(makeWorkspace: makeWorkspace)
        GroupWorkspaceHostRegistry.shared.openInitialWorkspace(initialWorkspace, in: controller)
        return controller
    }

    func updateNSViewController(_ nsViewController: GroupWorkspaceHostController, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: GroupWorkspaceHostController,
                     context: Context) -> CGSize? {
        let minimum = nsViewController.selectedContext?.minimumContentSize ?? NSSize(width: 520, height: 680)
        // Only the active workspace defines the window minimum. Do not let
        // SwiftUI infer this host's size from every retained child controller.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? max(1080, minimum.width)
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? max(760, minimum.height)
        return CGSize(width: max(minimum.width, width), height: max(minimum.height, height))
    }

    static func dismantleNSViewController(_ nsViewController: GroupWorkspaceHostController, coordinator: ()) {
        // This dismantles the real host, not an individual workspace's hosting
        // view. Tab switching and cross-window transfer never enter this path.
        nsViewController.finishClosing()
    }
}

@MainActor
private final class GroupWorkspaceEntry {
    let context: GroupWorkspaceContext
    let hosting: NSHostingController<AnyView>
    weak var rememberedResponder: NSView?
    init(payload: GroupWindowPayload, factory: (GroupWindowPayload, GroupWorkspaceContext) -> AnyView) {
        let context = GroupWorkspaceContext(payload: payload)
        self.context = context
        hosting = NSHostingController(rootView: factory(payload, context))
        hosting.sizingOptions = []
        (hosting.view as? NSHostingView<AnyView>)?.sizingOptions = []
        hosting.view.autoresizingMask = []
    }
}

@MainActor
final class GroupWorkspaceHostController: NSViewController {
    let id = UUID()
    fileprivate let factory: (GroupWindowPayload, GroupWorkspaceContext) -> AnyView
    private var entries: [GroupWorkspaceEntry] = []
    private(set) var selectedWorkspaceID: UUID?
    private(set) weak var window: NSWindow?
    private var lastNormalWindowFrame: NSRect?
    private var pendingRestoredWindowFrame: NSRect?
    private var isFrameRestoreScheduled = false
    private var isFullScreenTransition = false
    private var notifications: [NSObjectProtocol] = []
    private var isClosing = false
    private var closesDuplicateRestoration = false
    private lazy var titlebar = GroupWorkspaceHostTitlebar(host: self)
    var contexts: [GroupWorkspaceContext] { entries.map(\.context) }
    var selectedContext: GroupWorkspaceContext? { contexts.first { $0.id == selectedWorkspaceID } }

    init(makeWorkspace: @escaping (GroupWindowPayload, GroupWorkspaceContext) -> AnyView) {
        factory = makeWorkspace
        super.init(nibName: nil, bundle: nil)
        GroupWorkspaceHostRegistry.shared.register(self)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func loadView() {
        let container = GroupWorkspaceContainerView(frame: NSRect(x: 0, y: 0, width: 1080, height: 760))
        container.onWindowChange = { [weak self] in self?.bindWindow($0) }
        view = container
    }

    func openWorkspace(_ payload: GroupWindowPayload, newWindow: Bool = false) {
        if newWindow {
            let host = GroupWorkspaceHostController(makeWorkspace: factory)
            host.add(GroupWorkspaceEntry(payload: payload, factory: factory))
            host.showDetachedWindow(frame: restorableWindowFrame)
            return
        }
        if let existing = GroupWorkspaceHostRegistry.shared.context(id: payload.sessionID) {
            if entries.isEmpty, existing.owningHost !== self {
                closesDuplicateRestoration = true
                closeDuplicateRestorationIfNeeded()
            }
            existing.select()
            return
        }
        add(GroupWorkspaceEntry(payload: payload, factory: factory))
    }

    private func add(_ entry: GroupWorkspaceEntry, at index: Int? = nil) {
        closesDuplicateRestoration = false
        loadViewIfNeeded()
        let index = min(max(0, index ?? entries.count), entries.count)
        entries.insert(entry, at: index)
        addChild(entry.hosting)
        entry.context.bind(to: self)
        let container = view as! GroupWorkspaceContainerView
        let content = entry.hosting.view
        content.frame = container.workspaceContentRect
        content.isHidden = true
        content.setAccessibilityHidden(true)
        container.addSubview(content)
        // Keep every workspace mounted so its real SwiftUI body and window
        // accessor initialize the tab title and file menu even before selection.
        content.layoutSubtreeIfNeeded()
        select(workspaceID: entry.context.id, bringToFront: false)
    }

    func select(workspaceID: UUID, bringToFront: Bool) {
        guard let entry = entries.first(where: { $0.context.id == workspaceID }), !isClosing else { return }
        if selectedWorkspaceID != workspaceID {
            if let previous = entries.first(where: { $0.context.id == selectedWorkspaceID }) {
                rememberResponder(for: previous)
                guard relinquishResponder(for: previous) else { return }
                previous.context.setActive(false)
                previous.context.titlebarController.fileMenu.dismiss()
                previous.hosting.view.isHidden = true
                previous.hosting.view.setAccessibilityHidden(true)
            }
            selectedWorkspaceID = workspaceID
            let container = view as! GroupWorkspaceContainerView
            container.activeContext = entry.context
            container.activeContent = entry.hosting.view
            entry.hosting.view.frame = container.workspaceContentRect
            entry.hosting.view.isHidden = false
            entry.hosting.view.setAccessibilityHidden(false)
            container.needsLayout = true
            entry.hosting.view.layoutSubtreeIfNeeded()
            restoreResponder(for: entry)
            entry.context.setActive(true)
            updateWindowMinimumSize()
            refreshTitlebar()
            GroupWorkspaceHostRegistry.shared.scheduleSave()
        }
        if bringToFront {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            entry.context.notifyActivation()
        }
    }

    func selectNext(backward: Bool = false) {
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.context.id == selectedWorkspaceID } ?? 0
        let next = (index + (backward ? entries.count - 1 : 1)) % entries.count
        select(workspaceID: entries[next].context.id, bringToFront: true)
    }

    func close(workspaceID: UUID) {
        guard entries.contains(where: { $0.context.id == workspaceID }) else { return }
        if entries.count == 1, let window {
            window.performClose(nil)
            return
        }
        guard let entry = take(workspaceID: workspaceID) else { return }
        entry.context.finishClosing()
        refreshTitlebar()
        GroupWorkspaceHostRegistry.shared.scheduleSave()
    }

    /// Taking a controller changes presentation ownership, never editor ownership.
    private func take(workspaceID: UUID) -> GroupWorkspaceEntry? {
        guard let index = entries.firstIndex(where: { $0.context.id == workspaceID }) else { return nil }
        let entry = entries[index]
        let wasSelected = selectedWorkspaceID == workspaceID
        if wasSelected {
            rememberResponder(for: entry)
            guard relinquishResponder(for: entry) else { return nil }
        }
        entries.remove(at: index)
        entry.context.setActive(false)
        entry.hosting.view.isHidden = true
        entry.hosting.view.setAccessibilityHidden(true)
        entry.hosting.view.removeFromSuperview()
        entry.hosting.removeFromParent()
        entry.context.bind(to: nil)
        if wasSelected {
            selectedWorkspaceID = nil
            (view as? GroupWorkspaceContainerView)?.activeContext = nil
            (view as? GroupWorkspaceContainerView)?.activeContent = nil
            if !entries.isEmpty {
                select(workspaceID: entries[min(index, entries.count - 1)].context.id, bringToFront: false)
            }
        }
        refreshTitlebar()
        return entry
    }

    func move(_ context: GroupWorkspaceContext, before target: GroupWorkspaceContext?) {
        guard let source = context.owningHost else { return }
        if source === self {
            guard let oldIndex = entries.firstIndex(where: { $0.context === context }) else { return }
            let entry = entries.remove(at: oldIndex)
            let index = target.flatMap { target in entries.firstIndex { $0.context === target } } ?? entries.count
            entries.insert(entry, at: index)
            select(workspaceID: context.id, bringToFront: true)
            refreshTitlebar()
            GroupWorkspaceHostRegistry.shared.scheduleSave()
            return
        }
        guard let entry = source.take(workspaceID: context.id) else { return }
        let index = target.flatMap { target in entries.firstIndex { $0.context === target } } ?? entries.count
        add(entry, at: index)
        window?.makeKeyAndOrderFront(nil)
        entry.context.notifyActivation()
        if source.entries.isEmpty { source.window?.performClose(nil) }
        GroupWorkspaceHostRegistry.shared.scheduleSave()
    }

    func detach(_ context: GroupWorkspaceContext, at point: NSPoint? = nil) {
        guard context.owningHost === self else { return }
        guard entries.count > 1 else {
            if let point { positionWindow(at: point) }
            window?.makeKeyAndOrderFront(nil)
            return
        }
        let previousFrame = restorableWindowFrame
        guard let entry = take(workspaceID: context.id) else { return }
        let host = GroupWorkspaceHostController(makeWorkspace: factory)
        host.add(entry)
        host.showDetachedWindow(frame: previousFrame, at: point)
        GroupWorkspaceHostRegistry.shared.scheduleSave()
    }

    func refreshTitlebar() { titlebar.refresh() }

    private func rememberResponder(for entry: GroupWorkspaceEntry) {
        if let responder = ownedResponder(for: entry) { entry.rememberedResponder = responder }
    }

    private func ownedResponder(for entry: GroupWorkspaceEntry) -> NSView? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        if responder.isDescendant(of: entry.hosting.view) { return responder }
        // AppKit's shared field editor is outside the hosting hierarchy. Keep
        // its owning control instead, since the editor is reused between tabs.
        if let editor = responder as? NSTextView, editor.isFieldEditor,
           let owner = editor.delegate as? NSView, owner.isDescendant(of: entry.hosting.view) {
            return owner
        }
        return nil
    }

    private func relinquishResponder(for entry: GroupWorkspaceEntry) -> Bool {
        guard ownedResponder(for: entry) != nil, let window else { return true }
        // Honor an editor that refuses to finish editing instead of hiding its
        // workspace while it still owns the responder chain.
        return window.makeFirstResponder(view)
    }

    private func restoreResponder(for entry: GroupWorkspaceEntry) {
        guard let window else { return }
        if let responder = entry.rememberedResponder, responder.window === window,
           !responder.isHiddenOrHasHiddenAncestor, window.makeFirstResponder(responder) { return }
        if ownedResponder(for: entry) != nil { return }
        // A new hidden workspace never received PDFView's initial focus. Give
        // its reader (or the active undo container) the first responder now.
        if let reader = firstPDFResponder(in: entry.hosting.view), window.makeFirstResponder(reader) { return }
        window.makeFirstResponder(view)
    }

    private func firstPDFResponder(in view: NSView) -> NSView? {
        guard !view.isHiddenOrHasHiddenAncestor else { return nil }
        if view is HighlightingPDFView { return view }
        for child in view.subviews {
            if let reader = firstPDFResponder(in: child) { return reader }
        }
        return nil
    }

    fileprivate var restorableWindowFrame: NSRect? {
        recordNormalWindowFrame()
        return lastNormalWindowFrame
    }

    private func recordNormalWindowFrame() {
        guard pendingRestoredWindowFrame == nil, !isFullScreenTransition,
              let window, !window.styleMask.contains(.fullScreen) else { return }
        lastNormalWindowFrame = window.frame
    }

    fileprivate func restoreWindowFrame(_ frame: NSRect) {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return }
        lastNormalWindowFrame = frame
        pendingRestoredWindowFrame = frame
        scheduleFrameRestore()
    }

    private func scheduleFrameRestore() {
        guard !isFrameRestoreScheduled, pendingRestoredWindowFrame != nil,
              let window, !isFullScreenTransition, !window.styleMask.contains(.fullScreen) else { return }
        isFrameRestoreScheduled = true
        // The outer SwiftUI scene applies its initial content sizing after the
        // native view joins a window. Restore after that pass, not inside it.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self else { return }
            self.isFrameRestoreScheduled = false
            guard let window, self.window === window, !self.isClosing,
                  !self.isFullScreenTransition, !window.styleMask.contains(.fullScreen),
                  let pending = self.pendingRestoredWindowFrame else { return }
            window.contentView?.layoutSubtreeIfNeeded()
            let frame = self.constrainRestoredFrame(pending, for: window)
            self.pendingRestoredWindowFrame = nil
            window.setFrame(frame, display: false)
            self.recordNormalWindowFrame()
            GroupWorkspaceHostRegistry.shared.scheduleSave()
        }
    }

    private func constrainRestoredFrame(_ frame: NSRect, for window: NSWindow) -> NSRect {
        let intersectingScreen = NSScreen.screens.max { lhs, rhs in
            let left = lhs.visibleFrame.intersection(frame)
            let right = rhs.visibleFrame.intersection(frame)
            return (left.isNull ? 0 : left.width * left.height) < (right.isNull ? 0 : right.width * right.height)
        }
        let screen = intersectingScreen.flatMap { $0.visibleFrame.intersects(frame) ? $0 : nil }
            ?? window.screen ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return frame }
        var result = frame
        result.size.width = min(result.width, bounds.width)
        result.size.height = min(result.height, bounds.height)
        result.origin.x = min(max(result.minX, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.minY, bounds.minY), bounds.maxY - result.height)
        return result
    }

    func updateWindowMinimumSize() {
        guard let window, let context = selectedContext else { return }
        window.contentMinSize = context.minimumContentSize
        view.invalidateIntrinsicContentSize()
    }

    private func bindWindow(_ window: NSWindow?) {
        guard self.window !== window, !isClosing else { return }
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        titlebar.uninstall()
        self.window = window
        entries.forEach { $0.context.updateWindow(window) }
        guard let window else { return }
        window.tabbingMode = .disallowed
        titlebar.install(on: window)
        updateWindowMinimumSize()
        isFullScreenTransition = false
        if pendingRestoredWindowFrame != nil {
            scheduleFrameRestore()
        } else {
            recordNormalWindowFrame()
        }
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.selectedContext?.notifyActivation() }
        })
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            notifications.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Freeze before animation starts; resize notifications can
                    // otherwise persist an intermediate or full-screen frame.
                    self?.recordNormalWindowFrame()
                    self?.isFullScreenTransition = true
                }
            })
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            notifications.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWindow.didEnterFullScreenNotification || name == NSWindow.didExitFullScreenNotification {
                        self.isFullScreenTransition = false
                    }
                    if name == NSWindow.didExitFullScreenNotification { self.scheduleFrameRestore() }
                    self.recordNormalWindowFrame()
                    self.contexts.forEach { $0.titlebarController.fileMenu.dismiss() }
                    self.view.needsLayout = true
                    self.refreshTitlebar()
                    GroupWorkspaceHostRegistry.shared.scheduleSave()
                }
            })
        }
        notifications.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            // The SwiftUI host can be released as the window closes. Finish
            // synchronously while the workspace/editor callbacks still exist.
            MainActor.assumeIsolated { self?.finishClosing() }
        })
        // A mounted hidden hosting view still needs one initial layout when
        // its real window arrives; subsequent container layouts touch only the
        // active view, preserving inactive reading geometry and scroll state.
        entries.forEach { $0.hosting.view.layoutSubtreeIfNeeded() }
        if let selected = entries.first(where: { $0.context.id == selectedWorkspaceID }) {
            restoreResponder(for: selected)
        }
        selectedContext?.notifyActivation()
        GroupWorkspaceHostRegistry.shared.scheduleSave()
        closeDuplicateRestorationIfNeeded()
    }

    private func closeDuplicateRestorationIfNeeded() {
        guard closesDuplicateRestoration, entries.isEmpty, let window else { return }
        // Older SwiftUI scene restoration may recreate a window whose roster
        // the first host already restored. It owns no workspace or editor.
        window.orderOut(nil)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, self.closesDuplicateRestoration, self.entries.isEmpty else { return }
            window?.performClose(nil)
        }
    }

    fileprivate func finishClosing() {
        guard !isClosing else { return }
        isClosing = true
        let closingEntries = entries
        entries.removeAll()
        selectedWorkspaceID = nil
        closingEntries.forEach { entry in
            entry.context.finishClosing()
            entry.hosting.view.removeFromSuperview()
            entry.hosting.removeFromParent()
        }
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        titlebar.uninstall()
        GroupWorkspaceHostRegistry.shared.unregister(self)
        window = nil
    }

    fileprivate func showDetachedWindow(frame: NSRect?, at point: NSPoint? = nil) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentViewController = self
        if let frame { restoreWindowFrame(frame) } else { window.center() }
        let controller = NSWindowController(window: window)
        GroupWorkspaceHostRegistry.shared.retainDetachedWindow(controller, for: self)
        bindWindow(window)
        if let point { positionWindow(at: point) }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func positionWindow(at point: NSPoint) {
        guard let window else { return }
        var origin = NSPoint(x: point.x - min(150, window.frame.width / 2), y: point.y - window.frame.height + 19)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            origin.x = max(screen.visibleFrame.minX, min(origin.x, screen.visibleFrame.maxX - window.frame.width))
            origin.y = max(screen.visibleFrame.minY, min(origin.y, screen.visibleFrame.maxY - window.frame.height))
        }
        window.setFrameOrigin(origin)
    }
}

@MainActor
private final class GroupWorkspaceContainerView: NSView, NSUserInterfaceValidations, NSMenuItemValidation {
    var onWindowChange: ((NSWindow?) -> Void)?
    weak var activeContext: GroupWorkspaceContext?
    weak var activeContent: NSView?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { activeContext?.undoManager ?? super.undoManager }
    @objc func undo(_ sender: Any?) { if activeContext?.undoManager.canUndo == true { activeContext?.undoManager.undo() } }
    @objc func redo(_ sender: Any?) { if activeContext?.undoManager.canRedo == true { activeContext?.undoManager.redo() } }
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return activeContext?.undoManager.canUndo == true }
        if item.action == #selector(redo(_:)) { return activeContext?.undoManager.canRedo == true }
        return true
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { validateUserInterfaceItem(menuItem) }
    override var intrinsicContentSize: NSSize { activeContext?.minimumContentSize ?? NSSize(width: 520, height: 680) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindowChange?(window); needsLayout = true }
    var workspaceContentRect: NSRect {
        let content = window.map { convert($0.contentLayoutRect, from: nil).intersection(bounds) } ?? bounds
        return content.isNull ? bounds : content
    }
    override func layout() {
        super.layout()
        activeContent?.frame = workspaceContentRect
    }
}

@MainActor
final class GroupWorkspaceHostRegistry {
    static let shared = GroupWorkspaceHostRegistry()
    private struct SavedLayout: Codable {
        var version = 1
        var hosts: [SavedHost]
    }
    private struct SavedHost: Codable {
        var workspaces: [GroupWindowPayload]
        var selectedWorkspaceID: UUID?
        var frame: CGRect?
    }
    private final class WeakHost {
        weak var value: GroupWorkspaceHostController?
        init(_ value: GroupWorkspaceHostController) { self.value = value }
    }
    private let defaults = UserDefaults.standard
    private let layoutKey = "PDFWorkBench.GroupWorkspaceHostLayout.v1"
    private var hosts: [UUID: WeakHost] = [:]
    private var detachedWindows: [UUID: NSWindowController] = [:]
    private var didAttemptRestore = false
    private var isRestoring = false
    private var isTerminating = false
    private var saveRequest = UUID()
    private var terminationObserver: NSObjectProtocol?

    private init() {
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.prepareForApplicationTermination() }
            }
    }

    var all: [GroupWorkspaceHostController] { hosts.values.compactMap(\.value) }
    var activeWorkspaceIDs: Set<UUID> { Set(all.flatMap(\.contexts).map(\.id)) }
    func register(_ host: GroupWorkspaceHostController) { hosts[host.id] = WeakHost(host) }
    func unregister(_ host: GroupWorkspaceHostController) {
        hosts.removeValue(forKey: host.id)
        detachedWindows.removeValue(forKey: host.id)
        scheduleSave()
    }
    func retainDetachedWindow(_ controller: NSWindowController, for host: GroupWorkspaceHostController) { detachedWindows[host.id] = controller }
    func context(id: UUID) -> GroupWorkspaceContext? { all.flatMap(\.contexts).first { $0.id == id } }
    func context(groupID: UUID, preferring host: GroupWorkspaceHostController?) -> GroupWorkspaceContext? {
        host?.contexts.first { $0.groupID == groupID } ?? all.flatMap(\.contexts).first { $0.groupID == groupID }
    }
    func host(id: UUID) -> GroupWorkspaceHostController? { hosts[id]?.value }

    func openInitialWorkspace(_ fallback: GroupWindowPayload, in primary: GroupWorkspaceHostController) {
        guard !didAttemptRestore else {
            primary.openWorkspace(fallback)
            return
        }
        didAttemptRestore = true
        guard let data = defaults.data(forKey: layoutKey),
              let saved = try? JSONDecoder().decode(SavedLayout.self, from: data), saved.version == 1,
              !saved.hosts.isEmpty else {
            primary.openWorkspace(fallback)
            return
        }
        isRestoring = true
        var seen = Set<UUID>()
        let savedHosts = saved.hosts.compactMap { savedHost -> SavedHost? in
            let payloads = savedHost.workspaces.filter { seen.insert($0.sessionID).inserted }
            guard !payloads.isEmpty else { return nil }
            return SavedHost(workspaces: payloads, selectedWorkspaceID: savedHost.selectedWorkspaceID, frame: savedHost.frame)
        }
        guard !savedHosts.isEmpty else {
            isRestoring = false
            primary.openWorkspace(fallback)
            return
        }
        for (index, savedHost) in savedHosts.enumerated() {
            let host = index == 0 ? primary : GroupWorkspaceHostController(makeWorkspace: primary.factory)
            for payload in savedHost.workspaces { host.openWorkspace(payload) }
            if let selected = savedHost.selectedWorkspaceID { host.select(workspaceID: selected, bringToFront: false) }
            if index == 0 {
                if let frame = savedHost.frame { host.restoreWindowFrame(frame) }
            } else {
                host.showDetachedWindow(frame: savedHost.frame)
            }
        }
        isRestoring = false
        DispatchQueue.main.async { [weak primary] in primary?.window?.makeKeyAndOrderFront(nil) }
        scheduleSave()
    }

    func scheduleSave() {
        guard !isRestoring, !isTerminating else { return }
        let request = UUID()
        saveRequest = request
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.saveRequest == request, !self.isTerminating else { return }
            self.saveLayout()
        }
    }

    /// Call only once termination has actually been approved. Ordinary window
    /// closes remove their layout; terminating the app preserves the last set.
    func prepareForApplicationTermination() {
        guard !isTerminating else { return }
        saveLayout()
        isTerminating = true
        saveRequest = UUID()
    }

    private func saveLayout() {
        guard !isRestoring else { return }
        let current = all.sorted { lhs, rhs in
            if lhs.window?.isKeyWindow != rhs.window?.isKeyWindow { return lhs.window?.isKeyWindow == true }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let saved = SavedLayout(hosts: current.compactMap { host in
            guard !host.contexts.isEmpty else { return nil }
            return SavedHost(workspaces: host.contexts.map { GroupWindowPayload(sessionID: $0.id, groupID: $0.groupID) },
                selectedWorkspaceID: host.selectedWorkspaceID, frame: host.restorableWindowFrame)
        })
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: layoutKey) }
    }
}
