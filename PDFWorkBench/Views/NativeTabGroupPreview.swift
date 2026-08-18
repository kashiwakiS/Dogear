import AppKit
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
}

struct NativeTabPreviewContext: Equatable {
    let documentTitle: String
    let groupName: String
    let pageDescription: String?
    let hasWorkingCopy: Bool
    let items: [NativeTabPreviewItem]

    var toolTip: String {
        [
            documentTitle,
            groupName,
            pageDescription,
            hasWorkingCopy ? "Working copy active" : nil
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }
}

@MainActor
final class NativeTabGroupPreviewController {
    private weak var window: NSWindow?
    private let accessoryView = NativeTabPreviewAccessoryView()
    private let popover = NSPopover()
    private var hostingController: NSHostingController<NativeTabGroupPreviewView>?
    private var context = NativeTabPreviewContext(
        documentTitle: "No PDF Open",
        groupName: "Ungrouped",
        pageDescription: nil,
        hasWorkingCopy: false,
        items: []
    )
    private var onOpen: ((UUID) -> Void)?
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var showRequestID = UUID()
    private var closeRequestID = UUID()
    private var isAccessoryHovered = false
    private var isPopoverHovered = false

    init() {
        accessoryView.onHoverChanged = { [weak self] isHovered in
            self?.setAccessoryHovered(isHovered)
        }
        accessoryView.onActivate = { [weak self] in
            self?.showImmediately()
        }

        popover.behavior = .applicationDefined
        popover.animates = true
    }

    func update(
        window: NSWindow?,
        context: NativeTabPreviewContext,
        onOpen: @escaping (UUID) -> Void
    ) {
        self.context = context
        self.onOpen = onOpen

        if self.window !== window {
            uninstallFromCurrentWindow()
            self.window = window
            installOnCurrentWindow()
        } else if let window, window.tab.accessoryView !== accessoryView {
            window.tab.accessoryView = accessoryView
        }

        window?.tab.toolTip = context.toolTip
        refreshPopoverContent()
    }

    func dismiss() {
        showRequestID = UUID()
        closeRequestID = UUID()
        removeKeyMonitor()

        if popover.isShown {
            popover.close()
        }

        NativeTabPreviewRegistry.shared.didDismiss(self)
    }

    private func installOnCurrentWindow() {
        guard let window else {
            return
        }

        window.tab.accessoryView = accessoryView
        window.tab.toolTip = context.toolTip

        let notificationCenter = NotificationCenter.default
        observers = [
            notificationCenter.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.dismiss()
                }
            },
            notificationCenter.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.dismiss()
                }
            },
            notificationCenter.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reinstallAccessoryAfterWindowTransition()
                }
            },
            notificationCenter.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reinstallAccessoryAfterWindowTransition()
                }
            }
        ]
    }

    private func uninstallFromCurrentWindow() {
        dismiss()

        if let window, window.tab.accessoryView === accessoryView {
            window.tab.accessoryView = nil
        }

        let notificationCenter = NotificationCenter.default
        observers.forEach(notificationCenter.removeObserver)
        observers.removeAll()
    }

    private func reinstallAccessoryAfterWindowTransition() {
        dismiss()

        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else {
                return
            }

            window.tab.accessoryView = self.accessoryView
            window.tab.toolTip = self.context.toolTip
        }
    }

    private func setAccessoryHovered(_ isHovered: Bool) {
        isAccessoryHovered = isHovered

        if isHovered {
            closeRequestID = UUID()
            scheduleShow()
        } else {
            showRequestID = UUID()
            scheduleClose()
        }
    }

    private func setPopoverHovered(_ isHovered: Bool) {
        isPopoverHovered = isHovered

        if isHovered {
            closeRequestID = UUID()
        } else {
            scheduleClose()
        }
    }

    private func scheduleShow() {
        let requestID = UUID()
        showRequestID = requestID

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self,
                  self.showRequestID == requestID,
                  self.isAccessoryHovered
            else {
                return
            }

            self.show()
        }
    }

    private func showImmediately() {
        showRequestID = UUID()
        show()
    }

    private func show() {
        guard accessoryView.window != nil else {
            return
        }

        NativeTabPreviewRegistry.shared.willShow(self)
        refreshPopoverContent()

        if !popover.isShown {
            popover.show(
                relativeTo: accessoryView.bounds,
                of: accessoryView,
                preferredEdge: .minY
            )
        }

        installKeyMonitor()
    }

    private func scheduleClose() {
        let requestID = UUID()
        closeRequestID = requestID

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self,
                  self.closeRequestID == requestID,
                  !self.isAccessoryHovered,
                  !self.isPopoverHovered
            else {
                return
            }

            self.dismiss()
        }
    }

    private func refreshPopoverContent() {
        let rootView = NativeTabGroupPreviewView(
            context: context,
            onOpen: { [weak self] fileID in
                self?.open(fileID: fileID)
            },
            onHoverChanged: { [weak self] isHovered in
                self?.setPopoverHovered(isHovered)
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

        if let hostingController {
            hostingController.rootView = rootView
        } else {
            let hostingController = NSHostingController(rootView: rootView)
            self.hostingController = hostingController
            popover.contentViewController = hostingController
        }

        let visibleRows = min(max(context.items.count, 1), 8)
        popover.contentSize = NSSize(
            width: 360,
            height: 132 + CGFloat(visibleRows * 38)
        )
    }

    private func open(fileID: UUID) {
        guard context.items.contains(where: { $0.id == fileID }) else {
            return
        }

        if let window,
           let tabGroup = window.tabGroup,
           tabGroup.windows.contains(where: { $0 === window }) {
            tabGroup.selectedWindow = window
        }

        let openAction = onOpen
        dismiss()

        DispatchQueue.main.async {
            openAction?(fileID)
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else {
            return
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else {
                return event
            }

            if event.keyCode == 53 {
                self.dismiss()
                return nil
            }

            let disallowedModifiers: NSEvent.ModifierFlags = [
                .command,
                .control,
                .option,
                .shift,
                .function
            ]
            guard event.modifierFlags.intersection(disallowedModifiers).isEmpty,
                  let characters = event.charactersIgnoringModifiers,
                  let number = Int(characters),
                  (1...9).contains(number),
                  context.items.indices.contains(number - 1)
            else {
                return event
            }

            self.open(fileID: context.items[number - 1].id)
            return nil
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else {
            return
        }

        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }
}

@MainActor
private final class NativeTabPreviewRegistry {
    static let shared = NativeTabPreviewRegistry()

    weak var activeController: NativeTabGroupPreviewController?

    private init() {}

    func willShow(_ controller: NativeTabGroupPreviewController) {
        if activeController !== controller {
            activeController?.dismiss()
        }

        activeController = controller
    }

    func didDismiss(_ controller: NativeTabGroupPreviewController) {
        if activeController === controller {
            activeController = nil
        }
    }
}

private final class NativeTabPreviewAccessoryView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onActivate: (() -> Void)?

    private let imageView = NSImageView()
    private var trackingAreaReference: NSTrackingArea?
    private var isPointerInside = false {
        didSet {
            guard oldValue != isPointerInside else {
                return
            }

            layer?.backgroundColor = isPointerInside
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.12).cgColor
                : NSColor.clear.cgColor
            onHoverChanged?(isPointerInside)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.clear.cgColor

        imageView.image = NSImage(
            systemSymbolName: "list.bullet.rectangle",
            accessibilityDescription: nil
        )
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        toolTip = "Show Group files"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Show Group files")

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 22),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 15),
            imageView.heightAnchor.constraint(equalToConstant: 15)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true

        if window == nil {
            isPointerInside = false
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .activeAlways,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved
            ],
            owner: self
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
    }

    override func mouseMoved(with event: NSEvent) {
        isPointerInside = true
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private struct NativeTabGroupPreviewView: View {
    let context: NativeTabPreviewContext
    let onOpen: (UUID) -> Void
    let onHoverChanged: (Bool) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(context.documentTitle)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(context.groupName, systemImage: "folder")

                    if let pageDescription = context.pageDescription {
                        Text(pageDescription)
                    }

                    if context.hasWorkingCopy {
                        Label("Working copy", systemImage: "pencil.circle.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Divider()

            if context.items.isEmpty {
                ContentUnavailableView(
                    "No PDFs",
                    systemImage: "tray",
                    description: Text("This Group has no window files.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(context.items.enumerated()), id: \.element.id) { index, item in
                            Button {
                                onOpen(item.id)
                            } label: {
                                NativeTabPreviewRow(
                                    item: item,
                                    shortcutNumber: index < 9 ? index + 1 : nil
                                )
                            }
                            .buttonStyle(.plain)
                            .help(item.path)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onHover(perform: onHoverChanged)
        .onExitCommand(perform: onDismiss)
    }
}

private struct NativeTabPreviewRow: View {
    let item: NativeTabPreviewItem
    let shortcutNumber: Int?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)
                    .foregroundStyle(item.isUnavailable ? .secondary : .primary)

                if let detail = item.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            if item.isTemporary {
                Image(systemName: "pin.slash")
                    .foregroundStyle(.secondary)
                    .help("Temporary in this window")
            }

            if item.isUnavailable {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help("File unavailable")
            }

            if item.hasWorkingCopy {
                Image(systemName: "pencil.circle")
                    .foregroundStyle(.secondary)
                    .help("Working copy available")
            }

            if let shortcutNumber {
                Text("\(shortcutNumber)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            } else {
                Color.clear
                    .frame(width: 18, height: 18)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            item.isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .opacity(item.isUnavailable ? 0.65 : 1)
    }
}
