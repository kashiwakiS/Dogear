import AppKit

struct GroupWorkspaceChoice: Identifiable, Equatable {
    let id: UUID
    let name: String
}

/// Per-workspace presentation and actions. A separate host owns the titlebar;
/// no AppKit native tab group participates in workspace identity or switching.
@MainActor
final class GroupWorkspaceTitlebarController: NSObject {
    static let height: CGFloat = 38
    private let fallbackIdentifier = UUID()
    fileprivate var identifier: UUID { workspace?.id ?? fallbackIdentifier }
    private weak var workspace: GroupWorkspaceContext?
    fileprivate var window: NSWindow? { workspace?.window }
    fileprivate var context: NativeTabPreviewContext?
    let fileMenu = NativeTabGroupPreviewController()
    private var groups: [GroupWorkspaceChoice] = []
    private var openFile: ((UUID) -> Void)?
    private var openGroup: ((UUID) -> Void)?
    private var newGroup: (() -> Void)?
    private var temporaryWorkspace: (() -> Void)?
    static var activeWorkspaceIDs: Set<UUID> { GroupWorkspaceHostRegistry.shared.activeWorkspaceIDs }

    func attach(workspace: GroupWorkspaceContext) { self.workspace = workspace }

    func update(workspace: GroupWorkspaceContext, context: NativeTabPreviewContext,
                groups: [GroupWorkspaceChoice], onOpenFile: @escaping (UUID) -> Void,
                onOpenGroup: @escaping (UUID) -> Void, onNewGroup: @escaping () -> Void,
                onTemporaryWorkspace: @escaping () -> Void) {
        self.workspace = workspace
        self.context = context
        self.groups = groups
        openFile = onOpenFile
        openGroup = onOpenGroup
        newGroup = onNewGroup
        temporaryWorkspace = onTemporaryWorkspace
        hostDidChange()
    }

    func hostDidChange() {
        guard let context else { return }
        fileMenu.update(window: workspace?.window, context: context, usesNativeAccessory: false) { [weak self] fileID in
            guard let self else { return }
            self.workspace?.select()
            self.openFile?(fileID)
        }
        workspace?.owningHost?.refreshTitlebar()
    }

    func finishClosing() {
        fileMenu.update(window: nil, context: NativeTabPreviewContext(documentTitle: "", groupName: "",
            pageDescription: nil, hasWorkingCopy: false, items: []), usesNativeAccessory: false, onOpen: { _ in })
        openFile = nil
        openGroup = nil
        newGroup = nil
        temporaryWorkspace = nil
        workspace = nil
    }

    @discardableResult
    func activateWorkspace(groupID: UUID, fileID: UUID? = nil) -> Bool {
        guard let existing = GroupWorkspaceHostRegistry.shared.context(groupID: groupID, preferring: workspace?.owningHost) else { return false }
        existing.select()
        if let fileID { existing.titlebarController.openFile?(fileID) }
        return true
    }

    func openWorkspace(_ payload: GroupWindowPayload) { workspace?.openWorkspace(payload) }
    func prepareNewWorkspace() {}
    fileprivate func select() { workspace?.select() }
    fileprivate func close() { workspace?.close() }
    fileprivate func move(to destination: GroupWorkspaceTitlebarController, before target: GroupWorkspaceTitlebarController?) {
        guard let workspace, let host = destination.workspace?.owningHost else { return }
        fileMenu.dismiss()
        host.move(workspace, before: target?.workspace)
    }
    fileprivate func detach(at point: NSPoint? = nil) {
        guard let workspace else { return }
        fileMenu.dismiss()
        workspace.owningHost?.detach(workspace, at: point)
    }

    fileprivate func tabMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(actionItem(L10n.string("Close Workspace"), action: #selector(closeWorkspace)))
        let detach = actionItem(L10n.string("Move Workspace to New Window"), action: #selector(detachWorkspace))
        detach.isEnabled = (workspace?.owningHost?.contexts.count ?? 1) > 1
        menu.addItem(detach)
        let merge = NSMenu(title: L10n.string("Move to Window"))
        for target in GroupWorkspaceHostRegistry.shared.all where target !== workspace?.owningHost {
            let item = actionItem(target.selectedContext?.titlebarController.context?.groupName ?? "Dogear", action: #selector(mergeWorkspace(_:)))
            item.representedObject = target.id.uuidString
            merge.addItem(item)
        }
        if !merge.items.isEmpty {
            let item = NSMenuItem(title: L10n.string("Move to Window"), action: nil, keyEquivalent: "")
            item.submenu = merge
            menu.addItem(item)
        }
        return menu
    }
    @objc private func closeWorkspace() { close() }
    @objc private func detachWorkspace() { detach() }
    @objc private func mergeWorkspace(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value),
              let host = GroupWorkspaceHostRegistry.shared.host(id: id), let workspace else { return }
        host.move(workspace, before: nil)
    }

    fileprivate func showWorkspaceMenu(from button: NSButton) {
        let menu = NSMenu()
        let heading = NSMenuItem(title: L10n.string("Open Workspace"), action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        for group in groups {
            let item = actionItem(group.name, action: #selector(openGroupChoice(_:)))
            item.representedObject = group.id.uuidString
            menu.addItem(item)
        }
        if !groups.isEmpty { menu.addItem(.separator()) }
        menu.addItem(actionItem(L10n.string("Temporary Reading"), action: #selector(openTemporaryWorkspace)))
        menu.addItem(actionItem(L10n.string("New Group…"), action: #selector(createGroup)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }
    private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
    @objc private func openGroupChoice(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value) else { return }
        if activateWorkspace(groupID: id) { return }
        openGroup?(id)
    }
    @objc private func openTemporaryWorkspace() { temporaryWorkspace?() }
    @objc private func createGroup() { newGroup?() }
}

/// Exactly one titlebar accessory and one set of traffic lights per real window.
@MainActor
final class GroupWorkspaceHostTitlebar {
    private weak var host: GroupWorkspaceHostController?
    private weak var window: NSWindow?
    private let accessory = NSTitlebarAccessoryViewController()
    private let titlebar = GroupWorkspaceTitlebarView()
    private var originalButtonVisibility: [(NSWindow.ButtonType, Bool)] = []

    init(host: GroupWorkspaceHostController) {
        self.host = host
        accessory.layoutAttribute = .top
        titlebar.frame = NSRect(x: 0, y: 0, width: 800, height: GroupWorkspaceTitlebarController.height)
        accessory.view = titlebar
        titlebar.onAdd = { [weak host] button in host?.selectedContext?.titlebarController.showWorkspaceMenu(from: button) }
    }
    func install(on window: NSWindow) {
        self.window = window
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        originalButtonVisibility = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { kind in
            guard let button = window.standardWindowButton(kind) else { return nil }
            let wasHidden = button.isHidden
            button.isHidden = true
            return (kind, wasHidden)
        }
        window.addTitlebarAccessoryViewController(accessory)
        titlebar.installWindowControls(for: window)
        refresh()
    }
    func uninstall() {
        guard let window else { return }
        if let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
        for (kind, wasHidden) in originalButtonVisibility { window.standardWindowButton(kind)?.isHidden = wasHidden }
        originalButtonVisibility = []
        self.window = nil
    }
    func refresh() {
        guard let host else { return }
        let isFullScreen = window?.styleMask.contains(.fullScreen) == true
        configureAccessoryLayout(isFullScreen: isFullScreen)
        titlebar.setTabs(host.contexts.map(\.titlebarController), selectedID: host.selectedWorkspaceID)
        window?.title = host.selectedContext?.titlebarController.context?.groupName ?? "Dogear"
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = true
        }
        titlebar.isFullScreen = isFullScreen
    }

    private func configureAccessoryLayout(isFullScreen: Bool) {
        let layout: NSLayoutConstraint.Attribute = isFullScreen ? .bottom : .top
        guard accessory.layoutAttribute != layout else { return }
        // Only bottom accessories support a persistent minimum in full screen.
        // Reinstall this same accessory once per transition so AppKit updates
        // its layout ownership; workspace content and editor instances stay put.
        let installedIndex = window?.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory })
        if let installedIndex { window?.removeTitlebarAccessoryViewController(at: installedIndex) }
        if isFullScreen {
            accessory.layoutAttribute = .bottom
            accessory.automaticallyAdjustsSize = false
            accessory.fullScreenMinHeight = GroupWorkspaceTitlebarController.height
        } else {
            accessory.fullScreenMinHeight = 0
            accessory.layoutAttribute = .top
        }
        titlebar.frame.size.height = GroupWorkspaceTitlebarController.height
        if installedIndex != nil { window?.addTitlebarAccessoryViewController(accessory) }
        host?.view.needsLayout = true
    }
}

@MainActor
private final class GroupWorkspaceTitlebarView: NSView {
    var onAdd: ((NSButton) -> Void)?
    var isFullScreen = false { didSet { if oldValue != isFullScreen { needsLayout = true } } }
    private let scrollView = NSScrollView()
    private let tabs = GroupWorkspaceTabStrip()
    private let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)!, target: nil, action: nil)
    private let brand = NSTextField(labelWithString: "Dogear")
    private var controls: [NSButton] = []
    private var tabViews: [UUID: GroupWorkspaceTabView] = [:]
    private var selectedTabID: UUID?
    private var needsSelectedTabReveal = false
    private weak var owningWindow: NSWindow?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.documentView = tabs
        addSubview(scrollView)
        plus.isBordered = false
        plus.target = self
        plus.action = #selector(addWorkspace)
        plus.toolTip = L10n.string("Open Workspace")
        plus.setAccessibilityLabel(L10n.string("Open Workspace"))
        addSubview(plus)
        brand.font = .systemFont(ofSize: 12, weight: .semibold)
        brand.textColor = .secondaryLabelColor
        addSubview(brand)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func installWindowControls(for window: NSWindow) {
        owningWindow = window
        controls.forEach { $0.removeFromSuperview() }
        controls = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap {
            NSWindow.standardWindowButton($0, for: [.titled, .closable, .miniaturizable, .resizable])
        }
        for (index, button) in controls.enumerated() {
            button.target = self
            button.action = index == 0 ? #selector(closeWindow) : index == 1 ? #selector(minimizeWindow) : #selector(zoomWindow)
            addSubview(button)
        }
        needsLayout = true
    }
    @objc private func closeWindow() { owningWindow?.performClose(nil) }
    @objc private func minimizeWindow() { owningWindow?.performMiniaturize(nil) }
    @objc private func zoomWindow() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true { owningWindow?.performZoom(nil) }
        else { owningWindow?.toggleFullScreen(nil) }
    }
    @objc private func addWorkspace() { onAdd?(plus) }

    func setTabs(_ controllers: [GroupWorkspaceTitlebarController], selectedID: UUID?) {
        let nextSelectedID = selectedID
        let oldOrder = tabs.orderedViews.compactMap { $0.controller?.identifier }
        let newOrder = controllers.map(\.identifier)
        if selectedTabID != nextSelectedID || oldOrder != newOrder {
            needsSelectedTabReveal = true
        }
        selectedTabID = nextSelectedID
        let validIDs = Set(controllers.map(\.identifier))
        for id in Array(tabViews.keys) where !validIDs.contains(id) { tabViews.removeValue(forKey: id)?.removeFromSuperview() }
        tabs.orderedViews = controllers.map { controller in
            let view = tabViews[controller.identifier] ?? GroupWorkspaceTabView(controller: controller)
            tabViews[controller.identifier] = view
            if view.superview == nil { tabs.addSubview(view) }
            view.update(selected: controller.identifier == selectedID)
            return view
        }
        tabs.destinationController = controllers.first
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let height = bounds.height
        for (index, control) in controls.enumerated() {
            control.frame = NSRect(x: 13 + CGFloat(index * 20), y: (height - 14) / 2, width: 14, height: 14)
            control.isHidden = isFullScreen
        }
        let leading: CGFloat = isFullScreen ? 12 : 82
        brand.frame = NSRect(x: max(leading, bounds.width - 66), y: (height - 16) / 2, width: 56, height: 16)
        plus.frame = NSRect(x: max(leading, bounds.width - 98), y: (height - 26) / 2, width: 26, height: 26)
        let viewportWidth = max(0, bounds.width - leading - 110)
        if scrollView.frame.width != viewportWidth { needsSelectedTabReveal = true }
        scrollView.frame = NSRect(x: leading, y: 0, width: viewportWidth, height: height)
        var x: CGFloat = 0
        for view in tabs.orderedViews {
            let width = view.preferredWidth
            view.frame = NSRect(x: x, y: max(0, (height - 29) / 2), width: width, height: 29)
            x += width + 5
        }
        tabs.frame = NSRect(x: 0, y: 0, width: max(scrollView.bounds.width, x), height: height)
        tabs.needsLayout = true
        // Reveal only after a selection/order/viewport change. Ordinary context
        // refreshes and manual horizontal scrolling must not pull the strip back.
        if needsSelectedTabReveal, viewportWidth > 0, let selectedTabID, let selectedTab = tabViews[selectedTabID] {
            needsSelectedTabReveal = false
            if !scrollView.documentVisibleRect.contains(selectedTab.frame) {
                tabs.scrollToVisible(selectedTab.frame)
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { owningWindow?.performZoom(nil) }
        else { owningWindow?.performDrag(with: event) }
    }
}

private let groupWorkspaceDragType = NSPasteboard.PasteboardType("com.dogear.workspace-tab")

@MainActor
private final class GroupWorkspaceTabStrip: NSView {
    var orderedViews: [GroupWorkspaceTabView] = []
    weak var destinationController: GroupWorkspaceTitlebarController?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([groupWorkspaceDragType])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragController(sender) == nil ? [] : .move }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { dragController(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let source = dragController(sender), let destinationController else { return false }
        let location = convert(sender.draggingLocation, from: nil)
        let target = orderedViews.first { location.x < $0.frame.midX && $0.controller !== source }?.controller
        source.move(to: destinationController, before: target)
        return true
    }
    private func dragController(_ sender: NSDraggingInfo) -> GroupWorkspaceTitlebarController? {
        guard let string = sender.draggingPasteboard.string(forType: groupWorkspaceDragType), let id = UUID(uuidString: string) else { return nil }
        return GroupWorkspaceHostRegistry.shared.context(id: id)?.titlebarController
    }
}

@MainActor
private final class GroupWorkspaceTabView: NSView, NSDraggingSource {
    weak var controller: GroupWorkspaceTitlebarController?
    private let title = NSTextField(labelWithString: "")
    private let chevron = NativeTabPreviewAccessoryView(systemSymbolName: "chevron.down")
    private let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!, target: nil, action: nil)
    private var downEvent: NSEvent?
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // A noneditable NSTextField in a titlebar can otherwise become a window
        // drag target. Label/background gestures belong to the workspace tab.
        return hit === title ? self : hit
    }
    private var selected = false
    var preferredWidth: CGFloat { min(220, max(126, title.intrinsicContentSize.width + 70)) }
    override var isFlipped: Bool { true }

    init(controller: GroupWorkspaceTitlebarController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.isSelectable = false
        addSubview(title)
        chevron.translatesAutoresizingMaskIntoConstraints = true
        chevron.onHoverChanged = { [weak self] hovered in
            guard let self else { return }
            self.controller?.fileMenu.setAnchorHovered(hovered, anchor: self.chevron)
        }
        chevron.onActivate = { [weak self] in
            guard let self else { return }
            self.controller?.fileMenu.toggle(from: self.chevron)
        }
        addSubview(chevron)
        close.isBordered = false
        close.imageScaling = .scaleProportionallyDown
        close.contentTintColor = .tertiaryLabelColor
        close.target = self
        close.action = #selector(closeTab)
        close.toolTip = L10n.string("Close Workspace")
        close.setAccessibilityLabel(L10n.string("Close Workspace"))
        addSubview(close)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    func update(selected: Bool) {
        self.selected = selected
        title.stringValue = controller?.context?.groupName ?? "Dogear"
        title.textColor = selected ? .labelColor : .secondaryLabelColor
        toolTip = controller?.context?.toolTip
        setAccessibilityLabel(title.stringValue)
        setAccessibilityValue(selected ? L10n.string("Selected") : "")
        updateBackgroundAppearance()
        needsLayout = true
    }
    private func updateBackgroundAppearance() {
        // CALayer retains a resolved CGColor. Resolve it in this view's
        // appearance, matching the dynamic label colors drawn by AppKit, even
        // when a model refresh arrives under a different drawing appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = selected ? NSColor.controlBackgroundColor.cgColor : NSColor.clear.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundAppearance()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackgroundAppearance()
    }
    override func layout() {
        super.layout()
        title.frame = NSRect(x: 10, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 66), height: 16)
        chevron.frame = NSRect(x: bounds.width - 51, y: (bounds.height - 24) / 2, width: 24, height: 24)
        close.frame = NSRect(x: bounds.width - 25, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }
    @objc private func closeTab() { controller?.close() }
    override func accessibilityPerformPress() -> Bool { controller?.select(); return true }
    override func menu(for event: NSEvent) -> NSMenu? { controller?.tabMenu() }
    override func mouseDown(with event: NSEvent) { downEvent = event }
    override func mouseUp(with event: NSEvent) {
        if downEvent != nil { controller?.select() }
        downEvent = nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard let downEvent, let controller else { return }
        let distance = hypot(event.locationInWindow.x - downEvent.locationInWindow.x, event.locationInWindow.y - downEvent.locationInWindow.y)
        guard distance > 5 else { return }
        self.downEvent = nil
        controller.fileMenu.dismiss()
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(controller.identifier.uuidString, forType: groupWorkspaceDragType)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let image = NSImage(size: bounds.size, flipped: false) { [title = title.stringValue] rect in
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            (title as NSString).draw(at: NSPoint(x: 10, y: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
            return true
        }
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // A cancelled drag (Escape) must never turn into a detach.
        guard operation.isEmpty, NSApp.currentEvent?.keyCode != 53,
              NSApp.currentEvent?.type != .keyDown else { return }
        let releasedOutsideWindow = window.map { !$0.frame.contains(screenPoint) } ?? false
        if releasedOutsideWindow { controller?.detach(at: screenPoint) }
    }
}

/// Uses the real tab view while deliberately making the drawing appearance
/// disagree with the containing window. No document, layout or input changes.
@MainActor
enum GroupWorkspaceTitlebarAppearanceDiagnostics {
    static func run() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        let controller = GroupWorkspaceTitlebarController()
        let tab = GroupWorkspaceTabView(controller: controller)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 38),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab
        defer { tab.removeFromSuperview(); window.close() }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name),
                  let opposite = NSAppearance(named: name == .aqua ? .darkAqua : .aqua) else { continue }
            window.appearance = appearance
            for active in [true, false] {
                if active { window.makeKey() } else { window.resignKey() }
                opposite.performAsCurrentDrawingAppearance { tab.update(selected: true) }
                var expected: CGColor?
                tab.effectiveAppearance.performAsCurrentDrawingAppearance {
                    expected = NSColor.controlBackgroundColor.cgColor
                }
                checks += 1
                if tab.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != name
                    || tab.layer?.backgroundColor != expected {
                    failures.append("Selected Group tab resolved its background in the wrong appearance: \(name.rawValue), active=\(active).")
                }
            }
            opposite.performAsCurrentDrawingAppearance { tab.update(selected: false) }
            checks += 1
            if tab.layer?.backgroundColor?.alpha != 0 {
                failures.append("Unselected Group tab acquired an opaque background in \(name.rawValue).")
            }
        }
        return (checks, failures)
    }
}

/// Native layout/hit-testing only. This does not claim an OS drag/drop session
/// was exercised; it verifies that label hits reach the tab's gesture owner.
@MainActor
enum GroupWorkspaceTitlebarInteractionDiagnostics {
    static func run() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let titlebar = GroupWorkspaceTitlebarView(frame: NSRect(x: 0, y: 0, width: 620, height: 38))
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 160))
        window.contentView?.addSubview(titlebar)
        defer { titlebar.removeFromSuperview(); window.close() }
        let controllers = (0..<12).map { index in
            let controller = GroupWorkspaceTitlebarController()
            controller.context = NativeTabPreviewContext(documentTitle: "Fixture.pdf", groupName: "Group \(index + 1)",
                pageDescription: "Page 1 of 8", hasWorkingCopy: false, items: [])
            return controller
        }
        guard let scroll = titlebar.subviews.compactMap({ $0 as? NSScrollView }).first,
              let strip = scroll.documentView as? GroupWorkspaceTabStrip else {
            return (1, ["The native titlebar fixture has no tab scroll view."])
        }
        titlebar.setTabs(controllers, selectedID: controllers.last?.identifier)
        titlebar.layoutSubtreeIfNeeded()
        guard let last = strip.orderedViews.last, let first = strip.orderedViews.first else {
            return (1, ["The native titlebar fixture created no workspace tabs."])
        }
        check(strip.frame.width > scroll.contentView.bounds.width
                && scroll.documentVisibleRect.contains(last.frame),
              "Selecting an overflowing Group did not reveal its full native tab frame.")

        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let manualOrigin = scroll.contentView.bounds.origin.x
        for page in 2...15 {
            controllers.last?.context = NativeTabPreviewContext(documentTitle: "Fixture.pdf", groupName: "Group 12",
                pageDescription: "Page \(page) of 20", hasWorkingCopy: false, items: [])
            titlebar.setTabs(controllers, selectedID: controllers.last?.identifier)
            titlebar.layoutSubtreeIfNeeded()
        }
        check(abs(scroll.contentView.bounds.origin.x - manualOrigin) < 0.5
                && !scroll.documentVisibleRect.contains(last.frame),
              "An ordinary page/context refresh pulled the manually scrolled tab strip back to its selected Group.")

        titlebar.setTabs(controllers, selectedID: controllers.first?.identifier)
        titlebar.layoutSubtreeIfNeeded()
        check(scroll.documentVisibleRect.contains(first.frame),
              "Selecting the first Group did not reveal its tab after overflow scrolling.")
        first.layoutSubtreeIfNeeded()
        if let label = first.subviews.compactMap({ $0 as? NSTextField }).first {
            let labelPoint = NSPoint(x: label.frame.midX, y: label.frame.midY)
            let hit = titlebar.hitTest(titlebar.convert(labelPoint, from: first))
            check(hit === first && !first.mouseDownCanMoveWindow,
                  "A Group title label swallowed tab gestures or became a window-drag target.")
        } else { check(false, "The Group tab fixture has no title label.") }
        if let close = first.subviews.compactMap({ $0 as? NSButton }).first {
            let closePoint = NSPoint(x: close.frame.midX, y: close.frame.midY)
            check(titlebar.hitTest(titlebar.convert(closePoint, from: first)) === close,
                  "The Group tab intercepted its close button's native mouse target.")
        } else { check(false, "The Group tab fixture has no close button.") }

        titlebar.setTabs(controllers, selectedID: controllers.last?.identifier)
        titlebar.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        titlebar.frame.size.width = 530
        titlebar.layoutSubtreeIfNeeded()
        check(scroll.documentVisibleRect.contains(last.frame),
              "Shrinking the titlebar viewport left its selected Group clipped off-screen.")

        let reordered = [controllers.last!] + Array(controllers.dropLast())
        titlebar.setTabs(reordered, selectedID: controllers.last?.identifier)
        titlebar.layoutSubtreeIfNeeded()
        check(strip.orderedViews.first === last && scroll.documentVisibleRect.contains(last.frame),
              "Applying a changed Group order did not relayout/reveal the selected native tab.")
        return (checks, failures)
    }
}
