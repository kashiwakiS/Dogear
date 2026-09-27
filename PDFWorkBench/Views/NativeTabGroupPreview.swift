import AppKit
import Combine
import SwiftUI

struct NativeTabPreviewItem: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let detail: String?
    let path: String
    let isSelected: Bool
    let isTemporary: Bool
    let isUnavailable: Bool
    let hasWorkingCopy: Bool
    var lastPageIndex: Int? = nil
}

struct NativeTabPreviewContext: Equatable {
    let documentTitle: String
    let groupName: String
    let pageDescription: String?
    let hasWorkingCopy: Bool
    let items: [NativeTabPreviewItem]

    var toolTip: String {
        [documentTitle, groupName, pageDescription,
         hasWorkingCopy ? L10n.string("Working copy active") : nil]
            .compactMap { $0 }.joined(separator: "\n")
    }
}

@MainActor
private final class NativeTabPreviewPresentation: ObservableObject {
    @Published var query = ""
    @Published var selectedIndex = 0
    @Published var context = NativeTabPreviewContext(documentTitle: "", groupName: "",
        pageDescription: nil, hasWorkingCopy: false, items: [])

    var filteredItems: [NativeTabPreviewItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return context.items }
        return context.items.filter {
            $0.displayName.localizedStandardContains(text) || $0.path.localizedStandardContains(text)
        }
    }
}

/// The same file menu can be anchored in a system tab accessory or a custom titlebar tab.
@MainActor
final class NativeTabGroupPreviewController {
    private weak var window: NSWindow?
    private weak var anchorView: NSView?
    private let accessoryView = NativeTabPreviewAccessoryView()
    private let popover = NSPopover()
    private let presentation = NativeTabPreviewPresentation()
    private var hostingController: NSHostingController<NativeTabGroupPreviewView>?
    private var onOpen: ((UUID) -> Void)?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var showRequestID = UUID()
    private var closeRequestID = UUID()
    private var isAnchorHovered = false
    private var isPopoverHovered = false
    private var isPinned = false
    private var lastPinReason: String?
    private var usesNativeAccessory = true

    init() {
        accessoryView.onHoverChanged = { [weak self] hovered in
            guard let self else { return }
            self.setAnchorHovered(hovered, anchor: self.accessoryView)
        }
        accessoryView.onActivate = { [weak self] in
            guard let self else { return }
            self.toggle(from: self.accessoryView)
        }
        popover.behavior = .applicationDefined
        popover.animates = true
    }

    func update(window: NSWindow?, context: NativeTabPreviewContext,
                usesNativeAccessory: Bool = true, onOpen: @escaping (UUID) -> Void) {
        if presentation.context != context { presentation.context = context }
        self.onOpen = onOpen
        if self.window !== window || self.usesNativeAccessory != usesNativeAccessory {
            uninstall()
            self.window = window
            self.usesNativeAccessory = usesNativeAccessory
            install()
        }
        if usesNativeAccessory, let window, window.tab.accessoryView !== accessoryView {
            window.tab.accessoryView = accessoryView
        }
        window?.tab.toolTip = context.toolTip
        if hostingController == nil { makePopoverContent() }
    }

    func setAnchorHovered(_ hovered: Bool, anchor: NSView) {
        anchorView = anchor
        isAnchorHovered = hovered
        if hovered {
            closeRequestID = UUID()
            let requestID = UUID()
            showRequestID = requestID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self, self.showRequestID == requestID, self.isAnchorHovered else { return }
                self.show(pin: false)
            }
        } else {
            showRequestID = UUID()
            scheduleClose()
        }
    }

    func toggle(from anchor: NSView) {
        anchorView = anchor
        showRequestID = UUID()
        if popover.isShown && isPinned { dismiss() }
        else { show(pin: true) }
    }

    func dismiss() {
        showRequestID = UUID()
        closeRequestID = UUID()
        isPinned = false
        lastPinReason = nil
        isPopoverHovered = false
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        popover.close()
        NativeTabPreviewRegistry.shared.didDismiss(self)
    }

    private func install() {
        guard let window else { return }
        if usesNativeAccessory { window.tab.accessoryView = accessoryView }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification,
            object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.dismiss() }
            })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.dismiss() }
            })
        for notification in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            observers.append(center.addObserver(forName: notification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.dismiss() }
            })
        }
        for notification in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(center.addObserver(forName: notification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.usesNativeAccessory else { return }
                    self.window?.tab.accessoryView = self.accessoryView
                }
            })
        }
    }

    private func uninstall() {
        dismiss()
        if let window, window.tab.accessoryView === accessoryView { window.tab.accessoryView = nil }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func show(pin: Bool) {
        guard let anchorView, anchorView.window != nil else { return }
        NativeTabPreviewRegistry.shared.willShow(self)
        if pin { pinPreview(reason: "anchor click") }
        closeRequestID = UUID()
        if !popover.isShown {
            presentation.query = ""
            presentation.selectedIndex = 0
            makePopoverContent()
            let priorWindow = NSApp.keyWindow
            let priorResponder = priorWindow?.firstResponder
            let priorTextView = priorResponder as? NSTextView
            let priorField = priorTextView?.isFieldEditor == true ? priorTextView?.delegate as? NSTextField : nil
            let priorSelection = priorTextView?.selectedRange()
            let priorText = priorTextView?.string
            let restoreFocus = { [weak priorWindow, weak priorResponder, weak priorField] in
                guard let priorWindow else { return }
                priorWindow.makeKey()
                // A control's shared field editor can detach on resign-key.
                // Restore its owning field so AppKit reconnects editing first.
                let textView: NSTextView?
                if let priorField, priorField.window === priorWindow {
                    priorWindow.makeFirstResponder(priorField)
                    textView = priorField.currentEditor() as? NSTextView
                } else {
                    priorWindow.makeFirstResponder(priorResponder)
                    textView = priorResponder as? NSTextView
                }
                if let textView, let priorSelection, textView.string == priorText,
                   NSMaxRange(priorSelection) <= (textView.string as NSString).length {
                    textView.setSelectedRange(priorSelection)
                }
            }
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
            // Hover reveals content without moving typing focus away from the PDF/AI editor.
            if !pin, let priorWindow {
                restoreFocus()
                // AppKit/SwiftUI may assign the popover's initial field editor
                // after show() returns. Restore hover focus after that setup,
                // unless an actual click/key has engaged the preview meanwhile.
                DispatchQueue.main.async { [weak self, weak priorWindow] in
                    guard let self, let priorWindow, self.popover.isShown, !self.isPinned,
                          NSApp.keyWindow === priorWindow
                            || NSApp.keyWindow === self.hostingController?.view.window else { return }
                    restoreFocus()
                }
            }
        }
        installEventMonitor()
    }

    private func scheduleClose() {
        let requestID = UUID()
        closeRequestID = requestID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.closeRequestID == requestID,
                  !self.isAnchorHovered, !self.isPopoverHovered, !self.isPinned else { return }
            self.dismiss()
        }
    }

    private func makePopoverContent() {
        let view = NativeTabGroupPreviewView(presentation: presentation,
            onOpen: { [weak self] in self?.open(fileID: $0) },
            onHoverChanged: { [weak self] hovered in self?.setPopoverHovered(hovered) },
            onEngage: { [weak self] in self?.pinPreview(reason: "search binding") },
            onDismiss: { [weak self] in self?.dismiss() })
        if let hostingController { hostingController.rootView = view }
        else {
            let hostingController = NSHostingController(rootView: view)
            self.hostingController = hostingController
            popover.contentViewController = hostingController
        }
        popover.contentSize = NSSize(width: 370,
            height: 146 + CGFloat(min(max(presentation.context.items.count, 2), 8) * 48))
    }

    private func setPopoverHovered(_ hovered: Bool) {
        isPopoverHovered = hovered
        if hovered { closeRequestID = UUID() } else { scheduleClose() }
    }

    private func pinPreview(reason: String) {
        isPinned = true
        lastPinReason = reason
    }

    private func open(fileID: UUID) {
        guard presentation.context.items.contains(where: { $0.id == fileID }) else { return }
        if let window, let group = window.tabGroup, group.windows.contains(where: { $0 === window }) {
            group.selectedWindow = window
        }
        let action = onOpen
        dismiss()
        DispatchQueue.main.async { action?(fileID) }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            let popoverWindow = self.hostingController?.view.window
            if event.type != .keyDown {
                if event.window === popoverWindow { self.pinPreview(reason: "popover mouse"); return event }
                if let anchor = self.anchorView, event.window === anchor.window,
                   anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return event }
                self.dismiss()
                return event
            }
            let textEditor = event.window?.firstResponder as? NSTextView
            if textEditor?.hasMarkedText() == true { return event }
            if event.keyCode == 53 { self.dismiss(); return nil }
            if event.window === popoverWindow { self.pinPreview(reason: "popover key") }
            // Never capture ordinary typing, including numbers in search or another text editor.
            if textEditor?.isEditable == true { return event }
            guard event.window === popoverWindow || event.window === self.anchorView?.window else { return event }
            let items = self.presentation.filteredItems
            let blocked: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            guard event.modifierFlags.intersection(blocked).isEmpty else { return event }
            if event.keyCode == 125 || event.keyCode == 126 {
                self.pinPreview(reason: "navigation key")
                self.presentation.selectedIndex = min(max(0, self.presentation.selectedIndex + (event.keyCode == 125 ? 1 : -1)), max(0, items.count - 1))
                return nil
            }
            if event.keyCode == 36, items.indices.contains(self.presentation.selectedIndex) {
                self.open(fileID: items[self.presentation.selectedIndex].id)
                return nil
            }
            if !event.modifierFlags.contains(.function),
               let characters = event.charactersIgnoringModifiers, let number = Int(characters),
               (1...9).contains(number), items.indices.contains(number - 1) {
                self.open(fileID: items[number - 1].id)
                return nil
            }
            return event
        }
    }
}

@MainActor
private final class NativeTabPreviewRegistry {
    static let shared = NativeTabPreviewRegistry()
    weak var activeController: NativeTabGroupPreviewController?
    func willShow(_ controller: NativeTabGroupPreviewController) {
        if activeController !== controller { activeController?.dismiss() }
        activeController = controller
    }
    func didDismiss(_ controller: NativeTabGroupPreviewController) {
        if activeController === controller { activeController = nil }
    }
}

@MainActor
enum NativeTabPreviewInteractionDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        await NativeTabGroupPreviewController.runInteractionDiagnostics()
    }
}

extension NativeTabGroupPreviewController {
    /// Calls the real tracking/SwiftUI hover handlers with a native popover.
    /// It validates controller behavior, not physical pointer movement.
    fileprivate static func runInteractionDiagnostics() async -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        func wait(_ milliseconds: UInt64) async {
            try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        }
        let priorWindow = NSApp.keyWindow
        let priorResponder = priorWindow?.firstResponder
        let priorApplication = NSWorkspace.shared.frontmostApplication
        let priorActivationPolicy = NSApp.activationPolicy()
        let appWasActive = NSApp.isActive
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 480, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Dogear Group Preview Diagnostics"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        window.contentView = content
        let editor = NSTextField(frame: NSRect(x: 30, y: 50, width: 280, height: 26))
        editor.stringValue = "Fixture typing focus"
        content.addSubview(editor)
        let anchor = NativeTabPreviewAccessoryView(frame: NSRect(x: 30, y: 135, width: 24, height: 24))
        content.addSubview(anchor)
        let controller = NativeTabGroupPreviewController()
        controller.popover.animates = false
        let context = NativeTabPreviewContext(documentTitle: "Fixture.pdf", groupName: "Fixture Group",
            pageDescription: "Page 3 of 8", hasWorkingCopy: false, items: [])
        controller.update(window: window, context: context, usesNativeAccessory: false, onOpen: { _ in })
        anchor.onHoverChanged = { [weak controller, weak anchor] hovered in
            guard let anchor else { return }
            controller?.setAnchorHovered(hovered, anchor: anchor)
        }
        defer {
            controller.update(window: nil, context: context, usesNativeAccessory: false, onOpen: { _ in })
            window.close()
            if let priorWindow {
                priorWindow.makeKey()
                priorWindow.makeFirstResponder(priorResponder)
            }
            NSApp.setActivationPolicy(priorActivationPolicy)
            if !appWasActive, priorApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                priorApplication?.activate(options: [])
            }
        }
        // The CLI diagnostic runner can start without an active AppKit app.
        // A real key-window/focus test must first establish that native state.
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<20 {
            if NSApp.isActive { break }
            await wait(20)
        }
        window.makeKey()
        window.makeFirstResponder(editor)
        let editorResponder = window.firstResponder
        let selection = NSRange(location: 8, length: 6)
        (editorResponder as? NSTextView)?.setSelectedRange(selection)
        let originalText = editor.stringValue
        check(NSApp.keyWindow === window && editorResponder is NSTextView && editor.currentEditor() === editorResponder,
              "Native hover fixture did not establish a key window/text editor (appActive=\(NSApp.isActive), key=\(window.isKeyWindow)).")
        guard let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
            trackingNumber: 1, userData: nil),
              let exited = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2,
            trackingNumber: 1, userData: nil) else {
            return (1, ["Could not create native tracking events for the Group preview fixture."])
        }

        anchor.mouseEntered(with: entered)
        check(!controller.popover.isShown, "Anchor hover opened its preview synchronously instead of waiting.")
        anchor.mouseExited(with: exited)
        await wait(240)
        check(!controller.popover.isShown, "Leaving the anchor did not cancel a pending hover-open request.")

        anchor.mouseEntered(with: entered)
        await wait(240)
        check(controller.popover.isShown && !controller.isPinned,
              "A sustained anchor hover did not open an unpinned native popover (shown=\(controller.popover.isShown), pinned=\(controller.isPinned), reason=\(controller.lastPinReason ?? "none")).")
        let restoredEditor = editor.currentEditor() as? NSTextView
        check(NSApp.keyWindow === window && restoredEditor != nil && window.firstResponder === restoredEditor
                && restoredEditor?.selectedRange() == selection && restoredEditor?.string == originalText
                && editor.stringValue == originalText,
            "Hovering a Group preview lost the original field's editing focus, text, or selection (appActive=\(NSApp.isActive), key=\(window.isKeyWindow), ownerRestored=\(restoredEditor != nil && window.firstResponder === restoredEditor)).")
        controller.presentation.query = "Programmatic fixture refresh"
        await wait(40)
        controller.presentation.query = ""
        await wait(40)
        check(controller.popover.isShown && !controller.isPinned,
              "Programmatic query refresh/reset pinned a hover preview (reason=\(controller.lastPinReason ?? "none")).")

        anchor.mouseExited(with: exited)
        check(controller.popover.isShown, "Leaving an open anchor closed its popover before the crossing grace period.")
        controller.setPopoverHovered(true)
        await wait(410)
        check(controller.popover.isShown,
              "Moving from the anchor into its popover failed to cancel the pending close.")
        controller.setPopoverHovered(false)
        anchor.mouseEntered(with: entered)
        await wait(410)
        check(controller.popover.isShown && !controller.isPinned,
              "Moving from the popover back onto the anchor closed or pinned a hover preview.")

        anchor.mouseExited(with: exited)
        controller.setPopoverHovered(false)
        await wait(410)
        check(!controller.popover.isShown,
              "Leaving both anchor and popover did not close the unpinned preview after its delay.")

        controller.toggle(from: anchor)
        anchor.mouseExited(with: exited)
        controller.setPopoverHovered(false)
        await wait(410)
        check(controller.popover.isShown && controller.isPinned,
              "A clicked/pinned preview incorrectly closed when the pointer left.")
        controller.toggle(from: anchor)
        check(!controller.popover.isShown, "Clicking an already pinned preview did not dismiss it.")

        anchor.mouseEntered(with: entered)
        controller.dismiss()
        await wait(240)
        check(!controller.popover.isShown,
              "A delayed hover request reopened the preview after explicit dismissal.")
        return (checks, failures)
    }
}

final class NativeTabPreviewAccessoryView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onActivate: (() -> Void)?
    private let imageView = NSImageView()
    private var tracking: NSTrackingArea?
    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24), heightAnchor.constraint(equalToConstant: 24),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor), imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 10), imageView.heightAnchor.constraint(equalToConstant: 12)
        ])
        toolTip = L10n.string("Show Group files")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L10n.string("Show Group files"))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    convenience init(systemSymbolName: String) {
        self.init(frame: .zero)
        imageView.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        self.tracking = tracking
        addTrackingArea(tracking)
    }
    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
    override func mouseDown(with event: NSEvent) { onActivate?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onActivate?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

private struct NativeTabGroupPreviewView: View {
    @ObservedObject var presentation: NativeTabPreviewPresentation
    @ObservedObject private var language = AppLanguageStore.shared
    let onOpen: (UUID) -> Void
    let onHoverChanged: (Bool) -> Void
    let onEngage: () -> Void
    let onDismiss: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(presentation.context.groupName, systemImage: "folder")
                    .font(.headline).lineLimit(1)
                Spacer()
                Text("Group files").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a file", text: Binding(get: { presentation.query }, set: {
                    // SwiftUI writes the existing value while attaching or
                    // synchronizing its native field editor; that is not typing.
                    guard presentation.query != $0 else { return }
                    presentation.query = $0
                    presentation.selectedIndex = 0
                    onEngage()
                }))
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit {
                        let items = presentation.filteredItems
                        if items.indices.contains(presentation.selectedIndex) { onOpen(items[presentation.selectedIndex].id) }
                    }
            }
            .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if presentation.filteredItems.isEmpty {
                            Text(presentation.context.items.isEmpty ? "This Group has no window files." : "No matching files")
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
                        }
                        ForEach(Array(presentation.filteredItems.enumerated()), id: \.element.id) { index, item in
                            Button { onOpen(item.id) } label: {
                                NativeTabPreviewRow(item: item, shortcutNumber: index < 9 ? index + 1 : nil,
                                    isKeyboardSelected: presentation.selectedIndex == index && !searchFocused)
                            }
                            .buttonStyle(.plain).help(item.path).id(item.id)
                        }
                    }
                }
                .onChange(of: presentation.selectedIndex) { _, index in
                    let items = presentation.filteredItems
                    if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
                }
            }
            if let page = presentation.context.pageDescription {
                HStack(spacing: 5) {
                    Text(presentation.context.documentTitle).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(page).fixedSize()
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, language.locale)
        .onAppear { searchFocused = false }
        .onHover(perform: onHoverChanged)
        .onExitCommand(perform: onDismiss)
        // Initial focus and programmatic query resets are presentation work.
        // Only a real click/key or text binding edit pins a hover preview.
    }
}

private struct NativeTabPreviewRow: View {
    let item: NativeTabPreviewItem
    let shortcutNumber: Int?
    let isKeyboardSelected: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isSelected ? "checkmark.circle.fill" : "doc.text")
                .foregroundStyle(item.isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName).lineLimit(1)
                    .foregroundStyle(item.isUnavailable ? .secondary : .primary)
                HStack(spacing: 6) {
                    if let page = item.lastPageIndex { Text("Page \(page + 1)") }
                    if let detail = item.detail { Text(detail).lineLimit(1) }
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if item.isTemporary { Image(systemName: "pin.slash").help("Temporary in this window") }
            if item.isUnavailable { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            if item.hasWorkingCopy { Image(systemName: "pencil.circle").help("Working copy available") }
            if let shortcutNumber {
                Text("\(shortcutNumber)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    .frame(width: 16)
            }
        }
        .font(.callout).padding(.horizontal, 8).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(item.isSelected ? Color.accentColor.opacity(0.10) : isKeyboardSelected ? Color.primary.opacity(0.05) : .clear,
            in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}
