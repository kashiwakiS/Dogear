import AppKit
import CoreImage
import PDFKit
import SwiftUI

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    let selectedAnnotation: PDFAnnotationItem?
    let selectedSearchResult: PDFSearchResult?
    let targetPageIndex: Int
    let displayStyle: PDFReadingDisplayStyle
    let zoomCommand: PDFZoomCommand?
    let outlineNavigationRequest: PDFOutlineNavigationRequest?
    let outlineEntries: [DocumentOutlineEntry]
    let isLoadingOutline: Bool
    let isNightMode: Bool
    let freeTextRequestID: Int
    let shortcutSet: PDFReadingShortcutSet = .defaultReading
    let onSelectOutlineEntry: (DocumentOutlineEntry) -> Void
    let onHighlightCreated: () -> Void
    let onHighlightRemoved: (FeedbackTrigger) -> Void
    let onAnnotationChanged: () -> Void
    let onFreeTextShortcut: () -> Void
    let onShortcutActivated: (PDFReadingShortcutAction, String) -> Void
    let onPageChanged: (Int) -> Void
    let onScaleChanged: (CGFloat) -> Void
    let onSelectionChanged: (PDFTextSelectionSnapshot?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            displayStyle: displayStyle,
            onPageChanged: onPageChanged,
            onScaleChanged: onScaleChanged,
            onSelectionChanged: onSelectionChanged
        )
    }

    func makeNSView(context: Context) -> PDFReaderContainerView {
        let container = PDFReaderContainerView()
        let pdfView = container.pdfView
        // PDFKit's data detectors add temporary Link annotations for addresses,
        // URLs, dates, and phone numbers. They duplicate the app's link layer
        // and can add non-interactive dotted menus over wrapped PDF links.
        // Use KVC for the public property because its typed API is deprecated
        // on current macOS SDKs without a PDFDocument replacement being exposed.
        pdfView.setValue(false, forKey: "enableDataDetectors")
        pdfView.autoScales = true
        pdfView.displayMode = displayStyle.pdfDisplayMode
        pdfView.displayDirection = .vertical
        pdfView.displaysAsBook = displayStyle.displaysAsBook
        pdfView.shortcutSet = shortcutSet
        pdfView.onHighlightCreated = onHighlightCreated
        pdfView.onHighlightRemoved = onHighlightRemoved
        pdfView.onAnnotationChanged = onAnnotationChanged
        pdfView.onFreeTextShortcut = onFreeTextShortcut
        pdfView.onShortcutActivated = onShortcutActivated
        pdfView.applyNightMode(isNightMode)
        container.updateOutlineOverlay(
            entries: outlineEntries,
            currentPageIndex: targetPageIndex,
            isLoading: isLoadingOutline,
            isNightMode: isNightMode,
            onSelect: onSelectOutlineEntry
        )

        context.coordinator.observePageChanges(for: pdfView, in: container)
        context.coordinator.observeScaleChanges(for: pdfView, in: container)
        context.coordinator.observeSelectionChanges(for: pdfView)
        return container
    }

    func updateNSView(_ container: PDFReaderContainerView, context: Context) {
        let pdfView = container.pdfView
        if pdfView.document !== document {
            pdfView.stopQuietLinkPresentation()
            pdfView.beginQuietLinkPresentation(for: document)
            pdfView.document = document
            pdfView.hideNativeFreeTextAnnotations()
            context.coordinator.resetNavigationState(targetPageIndex: targetPageIndex)
            pdfView.goToPage(index: targetPageIndex)
            context.coordinator.reportScale(from: pdfView)
        }
        pdfView.shortcutSet = shortcutSet
        pdfView.onHighlightCreated = onHighlightCreated
        pdfView.onHighlightRemoved = onHighlightRemoved
        pdfView.onAnnotationChanged = onAnnotationChanged
        pdfView.onFreeTextShortcut = onFreeTextShortcut
        pdfView.onShortcutActivated = onShortcutActivated
        pdfView.applyNightMode(isNightMode)
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onScaleChanged = onScaleChanged
        context.coordinator.onSelectionChanged = onSelectionChanged
        container.updateOutlineOverlay(
            entries: outlineEntries,
            currentPageIndex: targetPageIndex,
            isLoading: isLoadingOutline,
            isNightMode: isNightMode,
            onSelect: onSelectOutlineEntry
        )

        if context.coordinator.lastDisplayStyle != displayStyle {
            context.coordinator.lastDisplayStyle = displayStyle
            pdfView.applyDisplayStyle(displayStyle, preservingPageIndex: targetPageIndex)
            context.coordinator.reportScale(from: pdfView)
        }

        if let zoomCommand,
           context.coordinator.lastZoomCommandID != zoomCommand.id {
            context.coordinator.lastZoomCommandID = zoomCommand.id
            pdfView.applyZoomCommand(zoomCommand.action)
            context.coordinator.reportScale(from: pdfView)
        }

        if let outlineNavigationRequest,
           context.coordinator.lastOutlineNavigationRequestID != outlineNavigationRequest.id {
            context.coordinator.lastOutlineNavigationRequestID = outlineNavigationRequest.id
            pdfView.goToOutlineTarget(outlineNavigationRequest.target)
            context.coordinator.lastTargetPageIndex = outlineNavigationRequest.target.pageIndex
        }

        if context.coordinator.lastFreeTextRequestID != freeTextRequestID {
            context.coordinator.lastFreeTextRequestID = freeTextRequestID
            if freeTextRequestID > 0 {
                pdfView.beginFreeTextEditing()
            }
        }

        if let selectedAnnotation {
            if context.coordinator.lastSelectedAnnotationID != selectedAnnotation.id {
                context.coordinator.lastSelectedAnnotationID = selectedAnnotation.id
                context.coordinator.lastSelectedSearchResultID = nil
                pdfView.goToAnnotation(selectedAnnotation)
            }
        } else if let selectedSearchResult {
            if context.coordinator.lastSelectedSearchResultID != selectedSearchResult.id {
                context.coordinator.lastSelectedSearchResultID = selectedSearchResult.id
                context.coordinator.lastSelectedAnnotationID = nil
                pdfView.goToSearchResult(selectedSearchResult)
            }
        } else if context.coordinator.lastTargetPageIndex != targetPageIndex {
            context.coordinator.lastSelectedAnnotationID = nil
            context.coordinator.lastSelectedSearchResultID = nil
            context.coordinator.lastTargetPageIndex = targetPageIndex
            pdfView.goToPage(index: targetPageIndex)
        }
    }

    static func dismantleNSView(_ container: PDFReaderContainerView, coordinator: Coordinator) {
        container.pdfView.stopQuietLinkPresentation()
    }

    final class Coordinator {
        var onPageChanged: (Int) -> Void
        var onScaleChanged: (CGFloat) -> Void
        var onSelectionChanged: (PDFTextSelectionSnapshot?) -> Void
        var lastFreeTextRequestID = 0
        var lastTargetPageIndex: Int
        var lastSelectedAnnotationID: PDFAnnotationItem.ID?
        var lastSelectedSearchResultID: PDFSearchResult.ID?
        var lastZoomCommandID = 0
        var lastOutlineNavigationRequestID = 0
        var lastDisplayStyle: PDFReadingDisplayStyle
        private var pageObserver: NSObjectProtocol?
        private var scaleObserver: NSObjectProtocol?
        private var selectionObserver: NSObjectProtocol?
        private var pendingScaleFactor: CGFloat?
        private var isScaleReportScheduled = false
        private var lastReportedScalePercent: Int?

        init(
            displayStyle: PDFReadingDisplayStyle,
            onPageChanged: @escaping (Int) -> Void,
            onScaleChanged: @escaping (CGFloat) -> Void,
            onSelectionChanged: @escaping (PDFTextSelectionSnapshot?) -> Void
        ) {
            self.lastDisplayStyle = displayStyle
            self.onPageChanged = onPageChanged
            self.onScaleChanged = onScaleChanged
            self.onSelectionChanged = onSelectionChanged
            self.lastTargetPageIndex = 0
        }

        func observeSelectionChanges(for pdfView: PDFView) {
            selectionObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name.PDFViewSelectionChanged,
                object: pdfView,
                queue: .main
            ) { [weak pdfView] _ in
                guard let pdfView,
                      let document = pdfView.document,
                      let selection = pdfView.currentSelection,
                      let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty
                else {
                    self.onSelectionChanged(nil)
                    return
                }

                let pages = selection.pages
                    .map { document.index(for: $0) }
                    .filter { $0 != NSNotFound }
                    .map { $0 + 1 }
                self.onSelectionChanged(
                    PDFTextSelectionSnapshot(
                        text: text,
                        pageNumbers: Array(Set(pages)).sorted()
                    )
                )
            }
        }

        func observePageChanges(for pdfView: HighlightingPDFView, in container: PDFReaderContainerView) {
            pageObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name.PDFViewPageChanged,
                object: pdfView,
                queue: .main
            ) { [weak pdfView, weak container] _ in
                guard let pdfView,
                      let document = pdfView.document,
                      let currentPage = pdfView.currentPage
                else {
                    return
                }

                let pageIndex = document.index(for: currentPage)
                container?.updateCurrentPageIndex(pageIndex)
                container?.layoutOutlineOverlay()
                self.lastTargetPageIndex = pageIndex
                self.onPageChanged(pageIndex)
            }
        }

        func observeScaleChanges(for pdfView: HighlightingPDFView, in container: PDFReaderContainerView) {
            scaleObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name.PDFViewScaleChanged,
                object: pdfView,
                queue: .main
            ) { [weak pdfView, weak container] _ in
                guard let pdfView else {
                    return
                }

                container?.layoutOutlineOverlay()
                self.reportScale(from: pdfView)
            }
        }

        func resetNavigationState(targetPageIndex: Int) {
            lastTargetPageIndex = targetPageIndex
            lastSelectedAnnotationID = nil
            lastSelectedSearchResultID = nil
        }

        func reportScale(from pdfView: PDFView) {
            let scaleFactor = pdfView.scaleFactor
            guard scaleFactor.isFinite, scaleFactor > 0 else {
                return
            }

            pendingScaleFactor = scaleFactor
            guard !isScaleReportScheduled else {
                return
            }

            isScaleReportScheduled = true
            DispatchQueue.main.async {
                self.isScaleReportScheduled = false
                guard let pendingScaleFactor = self.pendingScaleFactor else {
                    return
                }

                self.pendingScaleFactor = nil
                let scalePercent = Int((pendingScaleFactor * 100).rounded())
                guard self.lastReportedScalePercent != scalePercent else {
                    return
                }

                self.lastReportedScalePercent = scalePercent
                self.onScaleChanged(pendingScaleFactor)
            }
        }

        deinit {
            if let pageObserver {
                NotificationCenter.default.removeObserver(pageObserver)
            }

            if let scaleObserver {
                NotificationCenter.default.removeObserver(scaleObserver)
            }
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }
        }
    }
}

enum PDFReadingDisplayStyle: String, CaseIterable, Identifiable {
    case singlePage
    case continuous
    case twoUp

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .singlePage:
            return "Single"
        case .continuous:
            return "Continuous"
        case .twoUp:
            return "Two-Up"
        }
    }

    var systemImage: String {
        switch self {
        case .singlePage:
            return "doc"
        case .continuous:
            return "doc.text"
        case .twoUp:
            return "square.split.2x1"
        }
    }

    var pdfDisplayMode: PDFDisplayMode {
        switch self {
        case .singlePage:
            return .singlePage
        case .continuous:
            return .singlePageContinuous
        case .twoUp:
            return .twoUpContinuous
        }
    }

    var displaysAsBook: Bool {
        self == .twoUp
    }
}

struct PDFZoomCommand: Equatable {
    let id: Int
    let action: PDFZoomAction
}

enum PDFZoomAction: Equatable {
    case zoomIn
    case zoomOut
    case actualSize
    case fitWidth
    case fitPage
}

struct PDFReadingShortcutSet: Equatable {
    var highlightKeys: Set<String>
    var noteKeys: Set<String>
    var pageUpKeys: Set<String>
    var pageDownKeys: Set<String>

    static let defaultReading = PDFReadingShortcutSet(
        highlightKeys: ["h"],
        noteKeys: ["t"],
        pageUpKeys: ["w", "k"],
        pageDownKeys: ["s", "j"]
    )

    func action(for key: String) -> PDFReadingShortcutAction? {
        if highlightKeys.contains(key) {
            return .highlight
        }

        if noteKeys.contains(key) {
            return .note
        }

        if pageUpKeys.contains(key) {
            return .pageUp
        }

        if pageDownKeys.contains(key) {
            return .pageDown
        }

        return nil
    }
}

enum PDFReadingShortcutAction {
    case highlight
    case note
    case pageUp
    case pageDown
}

final class PDFReaderContainerView: NSView {
    let pdfView = HighlightingPDFView()

    private let outlineInteractionWidth: CGFloat = 72
    private let outlinePresentationWidth: CGFloat = 260
    private var outlineHostingView: NSHostingView<DocumentOutlineRailView>?
    private var outlineEntries: [DocumentOutlineEntry] = []
    private var outlineCurrentPageIndex = 0
    private var isLoadingOutline = false
    private var isOutlineNightMode = false
    private var onSelectOutlineEntry: ((DocumentOutlineEntry) -> Void)?
    private var selectedOutlineEntryID: DocumentOutlineEntry.ID?
    private var selectedOutlinePageIndex: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(pdfView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let outlineHostingView,
           !outlineHostingView.isHidden,
           outlineHostingView.frame.contains(point) {
            let outlinePoint = convert(point, to: outlineHostingView)
            if outlinePoint.x <= outlineInteractionWidth,
               let outlineHit = outlineHostingView.hitTest(outlinePoint) {
                return outlineHit
            }

            return pdfView.hitTest(convert(point, to: pdfView))
        }

        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        pdfView.frame = bounds
        layoutOutlineOverlay()
    }

    func updateOutlineOverlay(
        entries: [DocumentOutlineEntry],
        currentPageIndex: Int,
        isLoading: Bool,
        isNightMode: Bool,
        onSelect: @escaping (DocumentOutlineEntry) -> Void
    ) {
        outlineEntries = entries
        outlineCurrentPageIndex = currentPageIndex
        isLoadingOutline = isLoading
        isOutlineNightMode = isNightMode
        onSelectOutlineEntry = onSelect
        if let selectedOutlineEntryID,
           !entries.contains(where: { $0.id == selectedOutlineEntryID }) {
            self.selectedOutlineEntryID = nil
            selectedOutlinePageIndex = nil
        }
        renderOutlineOverlay()
    }

    func updateCurrentPageIndex(_ pageIndex: Int) {
        guard outlineCurrentPageIndex != pageIndex else {
            return
        }

        outlineCurrentPageIndex = pageIndex
        if let selectedOutlinePageIndex,
           selectedOutlinePageIndex != pageIndex {
            selectedOutlineEntryID = nil
            self.selectedOutlinePageIndex = nil
        }
        renderOutlineOverlay()
    }

    private func renderOutlineOverlay() {
        guard onSelectOutlineEntry != nil else {
            return
        }

        let rootView = DocumentOutlineRailView(
            entries: outlineEntries,
            currentPageIndex: outlineCurrentPageIndex,
            isLoading: isLoadingOutline,
            isNightMode: isOutlineNightMode,
            selectedEntryID: selectedOutlineEntryID,
            onSelect: { [weak self] entry in
                self?.activateOutlineEntry(entry)
            }
        )

        if let outlineHostingView {
            outlineHostingView.rootView = rootView
        } else {
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.translatesAutoresizingMaskIntoConstraints = true
            hostingView.wantsLayer = true
            hostingView.layer?.zPosition = 1_000
            hostingView.layer?.masksToBounds = false
            addSubview(hostingView, positioned: .above, relativeTo: pdfView)
            outlineHostingView = hostingView
        }

        layoutOutlineOverlay()
    }

    private func activateOutlineEntry(_ entry: DocumentOutlineEntry) {
        selectedOutlineEntryID = entry.id
        selectedOutlinePageIndex = entry.target.pageIndex
        renderOutlineOverlay()
        onSelectOutlineEntry?(entry)
    }

    func layoutOutlineOverlay() {
        guard let outlineHostingView,
              let page = pdfView.currentPage
        else {
            outlineHostingView?.isHidden = true
            return
        }

        let pageRect = pdfView.convert(
            pdfView.convert(page.bounds(for: .cropBox), from: page),
            to: self
        )
        let visibleBounds = pdfView.convert(pdfView.visibleRect, to: self)
        let height = outlineHostingView.rootView.preferredHeight
        let preferredX = pageRect.minX + 8
        let x = min(
            max(visibleBounds.minX + 8, preferredX),
            visibleBounds.maxX - outlineInteractionWidth - 8
        )
        let y = visibleBounds.midY - height / 2

        outlineHostingView.isHidden = false
        outlineHostingView.frame = NSRect(
            x: x,
            y: y,
            width: outlinePresentationWidth,
            height: height
        )
    }
}

final class HighlightingPDFView: PDFView {
    var shortcutSet: PDFReadingShortcutSet = .defaultReading
    var onHighlightCreated: (() -> Void)?
    var onHighlightRemoved: ((FeedbackTrigger) -> Void)?
    var onAnnotationChanged: (() -> Void)?
    var onFreeTextShortcut: (() -> Void)?
    var onShortcutActivated: ((PDFReadingShortcutAction, String) -> Void)?

    private var freeTextDrag: FreeTextDrag?
    private var freeTextEditor: FreeTextEditor?
    private weak var selectedHighlight: PDFAnnotation?
    private var highlightMenuEndTrackingObserver: NSObjectProtocol?
    private weak var quietLinkDocument: PDFDocument?
    private weak var hoveredQuietLink: PDFAnnotation?
    private weak var activatedQuietLink: PDFAnnotation?
    private weak var pressedQuietLink: PDFAnnotation?
    private var quietLinkTrackingArea: NSTrackingArea?
    private var quietLinkRectsCache: [ObjectIdentifier: [NSRect]] = [:]
    private var quietLinkActivationID = 0
    private var standardBackgroundColor: NSColor?
    private var appliedNightMode: Bool?

    override var acceptsFirstResponder: Bool {
        true
    }

    func applyNightMode(_ isEnabled: Bool) {
        guard appliedNightMode != isEnabled else {
            return
        }

        if standardBackgroundColor == nil {
            standardBackgroundColor = backgroundColor
        }
        appliedNightMode = isEnabled
        wantsLayer = true

        if isEnabled {
            backgroundColor = .white
            layer?.filters = [CIFilter(name: "CIColorInvert")].compactMap { $0 }
        } else {
            backgroundColor = standardBackgroundColor ?? .windowBackgroundColor
            layer?.filters = nil
        }
    }

    func goToOutlineTarget(_ target: PDFNavigationTarget) {
        guard let page = document?.page(at: target.pageIndex) else {
            return
        }

        if let point = target.point {
            go(to: PDFDestination(page: page, at: point))
        } else {
            go(to: page)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let quietLinkTrackingArea {
            removeTrackingArea(quietLinkTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        quietLinkTrackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        let isOverQuietLink = quietLinkAnnotation(at: event) != nil
        updateHoveredQuietLink(for: event)
        guard !isOverQuietLink else {
            return
        }

        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        updateHoveredQuietLink(for: nil)
        NSCursor.arrow.set()
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if freeTextEditor != nil {
            commitFreeTextEditor()
            return
        }

        if let drag = freeTextDragContext(for: event) {
            freeTextDrag = drag
            return
        }

        if let link = quietLinkAnnotation(at: event) {
            showQuietLinkActivation(link)
            if canPerformQuietLinkAction(link) {
                pressedQuietLink = link
                selectedHighlight = nil
                return
            }
        }

        selectedHighlight = highlightAnnotation(at: event)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if pressedQuietLink != nil {
            return
        }

        guard let freeTextDrag else {
            super.mouseDragged(with: event)
            return
        }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let pagePoint = convert(viewPoint, to: freeTextDrag.page)
        var bounds = freeTextDrag.annotation.bounds
        bounds.origin.x = pagePoint.x - freeTextDrag.pointerOffset.x
        bounds.origin.y = pagePoint.y - freeTextDrag.pointerOffset.y
        freeTextDrag.annotation.bounds = clamped(bounds, to: freeTextDrag.page.bounds(for: .cropBox))
        setNeedsDisplay(self.bounds)
    }

    override func mouseUp(with event: NSEvent) {
        if let pressedQuietLink {
            self.pressedQuietLink = nil
            if quietLinkAnnotation(at: event) === pressedQuietLink {
                performQuietLinkAction(pressedQuietLink)
            }
            return
        }

        if freeTextDrag != nil {
            freeTextDrag = nil
            onAnnotationChanged?()
            return
        }

        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            super.keyDown(with: event)
            return
        }

        if [51, 117].contains(event.keyCode),
           removeSelectedHighlight(trigger: .keyboard(shortcut: "Delete")) {
            return
        }

        let action = shortcutSet.action(for: key)
        if let action {
            onShortcutActivated?(action, key.uppercased())
        }

        switch action {
        case .highlight where addHighlightToCurrentSelection():
            onHighlightCreated?()
        case .highlight:
            NSSound.beep()
        case .note:
            onFreeTextShortcut?()
        case .pageUp:
            goToPreviousPage(nil)
        case .pageDown:
            goToNextPage(nil)
        case nil:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else {
            return nil
        }

        guard let annotation = menu.items
            .compactMap({ $0.representedObject as? PDFAnnotation })
            .first(where: { $0.type == "Highlight" }),
              let page = annotation.page
        else {
            return menu
        }

        selectedHighlight = annotation
        stopObservingHighlightMenu()
        highlightMenuEndTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: menu,
            queue: .main
        ) { [weak self] _ in
            guard let self else {
                return
            }

            self.stopObservingHighlightMenu()
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      !page.annotations.contains(where: { $0 === annotation })
                else {
                    return
                }

                self.selectedHighlight = nil
                self.refreshDisplay(for: page)
                self.onHighlightRemoved?(.pointer)
            }
        }
        return menu
    }

    func applyDisplayStyle(_ displayStyle: PDFReadingDisplayStyle, preservingPageIndex pageIndex: Int) {
        displayMode = displayStyle.pdfDisplayMode
        displayDirection = .vertical
        displaysAsBook = displayStyle.displaysAsBook
        goToPage(index: pageIndex)
    }

    func applyZoomCommand(_ action: PDFZoomAction) {
        switch action {
        case .zoomIn:
            autoScales = false
            scaleFactor = clampedScaleFactor(scaleFactor * 1.2)
        case .zoomOut:
            autoScales = false
            scaleFactor = clampedScaleFactor(scaleFactor / 1.2)
        case .actualSize:
            autoScales = false
            scaleFactor = clampedScaleFactor(1)
        case .fitWidth:
            autoScales = false
            scaleFactor = clampedScaleFactor(scaleFactorForFitWidth())
        case .fitPage:
            autoScales = true
        }
    }

    override func drawPagePost(_ page: PDFPage, to context: CGContext) {
        super.drawPagePost(page, to: context)
        drawQuietLinks(on: page, in: context)
        drawFreeTextNotes(on: page, in: context)
    }

    func beginQuietLinkPresentation(for document: PDFDocument) {
        guard quietLinkDocument !== document else {
            return
        }

        stopQuietLinkPresentation()
        quietLinkRectsCache.removeAll()
        quietLinkDocument = document
        QuietLinkDisplayRegistry.shared.beginDisplaying(document)
    }

    func stopQuietLinkPresentation() {
        guard let quietLinkDocument else {
            return
        }

        updateHoveredQuietLink(for: nil)
        activatedQuietLink = nil
        pressedQuietLink = nil
        quietLinkRectsCache.removeAll()
        self.quietLinkDocument = nil
        QuietLinkDisplayRegistry.shared.endDisplaying(quietLinkDocument)
    }

    func goToPage(index: Int) {
        guard let document,
              let page = document.page(at: min(max(0, index), max(0, document.pageCount - 1))),
              currentPage !== page
        else {
            return
        }

        go(to: page)
    }

    func goToAnnotation(_ item: PDFAnnotationItem) {
        guard let document,
              let page = document.page(at: item.pageIndex),
              let annotation = AnnotationExtractor.annotation(matching: item, in: document)
        else {
            return
        }

        let destination = PDFDestination(
            page: page,
            at: NSPoint(x: annotation.bounds.midX, y: annotation.bounds.midY)
        )
        go(to: destination)
        setCurrentSelection(nil, animate: false)
    }

    func goToSearchResult(_ result: PDFSearchResult) {
        go(to: result.selection)
        setCurrentSelection(result.selection, animate: true)
    }

    func hideNativeFreeTextAnnotations() {
        document?.setFreeTextAnnotationsShouldDisplay(false)
    }

    func beginFreeTextEditing() {
        commitFreeTextEditor()

        guard let page = currentPage ?? document?.page(at: 0) else {
            return
        }

        let annotationBounds = defaultFreeTextBounds(on: page)
        let fieldFrame = convert(annotationBounds, from: page)
        let annotationFont = Self.freeTextAnnotationFont
        let textField = FreeTextInputField(frame: fieldFrame)
        textField.cell = FreeTextInputCell(
            textCell: "",
            padding: Self.freeTextTextPadding * scaleFactor
        )
        let editorFont = Self.freeTextEditorFont(for: scaleFactor)
        textField.font = editorFont
        textField.placeholderAttributedString = NSAttributedString(
            string: "Type note",
            attributes: [
                .font: editorFont,
                .foregroundColor: Self.freeTextPlaceholderColor
            ]
        )
        textField.textColor = Self.freeTextForegroundColor
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.isBordered = false
        textField.isEditable = true
        textField.isSelectable = true
        textField.focusRingType = .none
        textField.target = self
        textField.action = #selector(commitFreeTextEditor)
        textField.onCancel = { [weak self] in
            self?.cancelFreeTextEditor()
        }

        addSubview(textField)
        freeTextEditor = FreeTextEditor(
            textField: textField,
            page: page,
            initialBounds: annotationBounds,
            annotationFont: annotationFont
        )
        window?.makeFirstResponder(textField)
        textField.selectText(nil)
    }

    private func addHighlightToCurrentSelection() -> Bool {
        guard let selection = currentSelection,
              selection.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return false
        }

        var pageGeometries: [PageHighlightGeometry] = []

        for lineSelection in selection.selectionsByLine() {
            for page in lineSelection.pages {
                let bounds = lineSelection.bounds(for: page)

                guard !bounds.isEmpty else {
                    continue
                }

                let highlightBounds = bounds.insetBy(dx: -1, dy: -1)
                if let geometryIndex = pageGeometries.firstIndex(where: { $0.page === page }) {
                    pageGeometries[geometryIndex].lineBounds.append(highlightBounds)
                } else {
                    pageGeometries.append(
                        PageHighlightGeometry(page: page, lineBounds: [highlightBounds])
                    )
                }
            }
        }

        for geometry in pageGeometries {
            guard let annotationBounds = geometry.lineBounds.reduce(nil, { partialBounds, lineBounds in
                partialBounds?.union(lineBounds) ?? lineBounds
            }) else {
                continue
            }

            let highlight = PDFAnnotation(
                bounds: annotationBounds,
                forType: .highlight,
                withProperties: nil
            )
            highlight.color = Self.highlightColor
            highlight.quadrilateralPoints = geometry.lineBounds.flatMap {
                quadrilateralPoints(for: $0, relativeTo: annotationBounds.origin)
            }
            // Keep contents empty so PDFKit does not show highlight note popovers.
            geometry.page.addAnnotation(highlight)
        }

        clearSelection()
        setNeedsDisplay(bounds)
        return !pageGeometries.isEmpty
    }

    private func quadrilateralPoints(for bounds: NSRect, relativeTo origin: NSPoint) -> [NSValue] {
        [
            NSValue(point: NSPoint(x: bounds.minX - origin.x, y: bounds.maxY - origin.y)),
            NSValue(point: NSPoint(x: bounds.maxX - origin.x, y: bounds.maxY - origin.y)),
            NSValue(point: NSPoint(x: bounds.minX - origin.x, y: bounds.minY - origin.y)),
            NSValue(point: NSPoint(x: bounds.maxX - origin.x, y: bounds.minY - origin.y))
        ]
    }

    private func highlightAnnotation(at event: NSEvent) -> PDFAnnotation? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else {
            return nil
        }

        let pagePoint = convert(viewPoint, to: page)
        guard let annotation = page.annotation(at: pagePoint),
              annotation.type == "Highlight"
        else {
            return nil
        }

        return annotation
    }

    private func quietLinkAnnotation(at event: NSEvent) -> PDFAnnotation? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else {
            return nil
        }

        let pagePoint = convert(viewPoint, to: page)
        let links = page.annotations.filter { $0.type == "Link" }
        if let compensatedLink = links.first(where: { annotation in
            let rects = quietLinkRects(for: annotation, on: page)
            return rects.count > 1 && rects.contains(where: { $0.contains(pagePoint) })
        }) {
            return compensatedLink
        }

        return links.last { annotation in
            quietLinkRects(for: annotation, on: page).contains(where: { $0.contains(pagePoint) })
        }
    }

    private func quietLinkRects(for annotation: PDFAnnotation, on page: PDFPage) -> [NSRect] {
        let cacheKey = ObjectIdentifier(annotation)
        if let cachedRects = quietLinkRectsCache[cacheKey] {
            return cachedRects
        }

        let rects = QuietLinkGeometryResolver.rects(for: annotation, on: page)
        quietLinkRectsCache[cacheKey] = rects
        return rects
    }

    private func updateHoveredQuietLink(for event: NSEvent?) {
        let link = event.flatMap(quietLinkAnnotation(at:))
        guard hoveredQuietLink !== link else {
            return
        }

        let previousPage = hoveredQuietLink?.page
        hoveredQuietLink = link

        if let link {
            NSCursor.pointingHand.set()
            toolTip = quietLinkTooltip(for: link)
        } else {
            NSCursor.arrow.set()
            toolTip = nil
        }

        if let previousPage {
            refreshDisplay(for: previousPage)
        }
        if let page = link?.page, page !== previousPage {
            refreshDisplay(for: page)
        }
    }

    private func showQuietLinkActivation(_ link: PDFAnnotation) {
        activatedQuietLink = link
        quietLinkActivationID += 1
        let activationID = quietLinkActivationID
        if let page = link.page {
            refreshDisplay(for: page)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self, weak link] in
            guard let self,
                  self.quietLinkActivationID == activationID,
                  self.activatedQuietLink === link
            else {
                return
            }

            self.activatedQuietLink = nil
            if let page = link?.page {
                self.refreshDisplay(for: page)
            }
        }
    }

    private func quietLinkTooltip(for annotation: PDFAnnotation) -> String {
        switch quietLinkKind(for: annotation) {
        case .external:
            if let host = quietLinkURL(for: annotation)?.host(), !host.isEmpty {
                return "Open web link: \(host)"
            }
            return "Open web link"
        case .citation:
            return "Go to cited reference"
        case .documentReference:
            return "Go to document reference"
        case .backReference:
            return "Return to citation"
        case .internalLink:
            return "Go to document link"
        }
    }

    private func quietLinkURL(for annotation: PDFAnnotation) -> URL? {
        (annotation.action as? PDFActionURL)?.url ?? annotation.url
    }

    private func quietLinkDestination(for annotation: PDFAnnotation) -> PDFDestination? {
        (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination
    }

    private func canPerformQuietLinkAction(_ annotation: PDFAnnotation) -> Bool {
        quietLinkDestination(for: annotation) != nil || quietLinkURL(for: annotation) != nil
    }

    private func performQuietLinkAction(_ annotation: PDFAnnotation) {
        if let destination = quietLinkDestination(for: annotation) {
            go(to: destination)
            return
        }

        if let url = quietLinkURL(for: annotation) {
            NSWorkspace.shared.open(url)
        }
    }

    private func quietLinkKind(for annotation: PDFAnnotation) -> QuietLinkKind {
        if quietLinkURL(for: annotation) != nil {
            return .external
        }

        if isQuietLinkColor(annotation.color, red: 0, green: 1, blue: 0) {
            return .citation
        }
        if isQuietLinkColor(annotation.color, red: 1, green: 0, blue: 0) {
            return .documentReference
        }

        guard let document,
              let sourcePage = annotation.page,
              let destinationPage = quietLinkDestination(for: annotation)?.page
        else {
            return .internalLink
        }

        let sourceIndex = document.index(for: sourcePage)
        let destinationIndex = document.index(for: destinationPage)
        if destinationIndex < sourceIndex {
            return .backReference
        }
        return .internalLink
    }

    private func isQuietLinkColor(
        _ color: NSColor,
        red targetRed: CGFloat,
        green targetGreen: CGFloat,
        blue targetBlue: CGFloat
    ) -> Bool {
        guard let rgbColor = color.usingColorSpace(.deviceRGB) else {
            return false
        }

        let tolerance: CGFloat = 0.2
        return abs(rgbColor.redComponent - targetRed) <= tolerance
            && abs(rgbColor.greenComponent - targetGreen) <= tolerance
            && abs(rgbColor.blueComponent - targetBlue) <= tolerance
    }

    private func drawQuietLinks(on page: PDFPage, in context: CGContext) {
        for annotation in page.annotations where annotation.type == "Link" {
            let kind = quietLinkKind(for: annotation)
            let isHovered = annotation === hoveredQuietLink
            let isActivated = annotation === activatedQuietLink

            guard kind == .external || isHovered || isActivated else {
                continue
            }

            let color = quietLinkColor(for: kind)
            let lineWidth = max(0.55, 1 / max(scaleFactor, 0.01))
            let underlineWidth = isHovered || isActivated ? lineWidth * 1.45 : lineWidth
            let linkRects = quietLinkRects(for: annotation, on: page)

            context.saveGState()
            context.setAllowsAntialiasing(true)

            if isActivated {
                context.setFillColor(color.withAlphaComponent(0.12).cgColor)
                for linkRect in linkRects {
                    context.fill(linkRect.insetBy(dx: -1.5, dy: -1))
                }
            }

            context.setStrokeColor(
                color.withAlphaComponent(isHovered || isActivated ? 0.78 : 0.42).cgColor
            )
            context.setLineWidth(underlineWidth)
            context.setLineCap(.round)
            for linkRect in linkRects {
                let underlineY = linkRect.minY + lineWidth * 0.5
                context.move(to: CGPoint(x: linkRect.minX, y: underlineY))
                context.addLine(to: CGPoint(x: linkRect.maxX, y: underlineY))
            }
            context.strokePath()
            context.restoreGState()
        }
    }

    private func quietLinkColor(for kind: QuietLinkKind) -> NSColor {
        switch kind {
        case .documentReference:
            return NSColor(calibratedRed: 0.30, green: 0.36, blue: 0.62, alpha: 1)
        case .citation, .backReference:
            return NSColor(calibratedRed: 0.23, green: 0.52, blue: 0.48, alpha: 1)
        case .external, .internalLink:
            return .linkColor
        }
    }

    private func removeSelectedHighlight(trigger: FeedbackTrigger) -> Bool {
        guard let selectedHighlight else {
            return false
        }

        return removeHighlight(selectedHighlight, trigger: trigger)
    }

    @discardableResult
    private func removeHighlight(
        _ annotation: PDFAnnotation,
        trigger: FeedbackTrigger
    ) -> Bool {
        guard annotation.type == "Highlight",
              let page = annotation.page
        else {
            selectedHighlight = nil
            return false
        }

        page.removeAnnotation(annotation)
        selectedHighlight = nil
        refreshDisplay(for: page)
        onHighlightRemoved?(trigger)
        return true
    }

    private func stopObservingHighlightMenu() {
        guard let highlightMenuEndTrackingObserver else {
            return
        }

        NotificationCenter.default.removeObserver(highlightMenuEndTrackingObserver)
        self.highlightMenuEndTrackingObserver = nil
    }

    @objc private func commitFreeTextEditor() {
        guard let editor = freeTextEditor else {
            return
        }

        let noteText = editor.textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !noteText.isEmpty else {
            freeTextEditor = nil
            editor.textField.removeFromSuperview()
            return
        }

        let font = editor.annotationFont
        let pageBounds = editor.page.bounds(for: .cropBox)
        let noteOrigin = editor.initialBounds.origin
        let committedTextField = editor.textField
        freeTextEditor = nil

        let noteBounds = freeTextBounds(
            for: noteText,
            near: noteOrigin,
            in: pageBounds,
            font: font
        )
        let note = PDFAnnotation(bounds: noteBounds, forType: .freeText, withProperties: nil)
        note.contents = noteText
        note.font = font
        note.fontColor = Self.freeTextForegroundColor
        note.alignment = .left
        note.shouldDisplay = false
        note.shouldPrint = true
        note.border = PDFBorder()
        note.border?.lineWidth = 0
        note.removeValue(forAnnotationKey: .color)
        note.removeValue(forAnnotationKey: .interiorColor)
        editor.page.addAnnotation(note)
        refreshDisplay(for: editor.page)
        onAnnotationChanged?()

        DispatchQueue.main.async { [weak self, weak committedTextField] in
            committedTextField?.removeFromSuperview()
            guard let self else {
                return
            }

            self.window?.makeFirstResponder(self)
        }
    }

    private func cancelFreeTextEditor() {
        guard let editor = freeTextEditor else {
            return
        }

        freeTextEditor = nil
        editor.textField.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    private func freeTextDragContext(for event: NSEvent) -> FreeTextDrag? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else {
            return nil
        }

        let pagePoint = convert(viewPoint, to: page)
        guard let annotation = page.annotations
            .last(where: { $0.type == "FreeText" && $0.bounds.contains(pagePoint) })
        else {
            return nil
        }

        let bounds = annotation.bounds
        return FreeTextDrag(
            annotation: annotation,
            page: page,
            pointerOffset: NSPoint(
                x: pagePoint.x - bounds.origin.x,
                y: pagePoint.y - bounds.origin.y
            )
        )
    }

    private func refreshDisplay(for page: PDFPage) {
        let pageBounds = convert(page.bounds(for: displayBox), from: page)
        documentView?.setNeedsDisplay(documentView?.bounds ?? .zero)
        setNeedsDisplay(pageBounds)
        setNeedsDisplay(bounds)
    }

    private func drawFreeTextNotes(on page: PDFPage, in context: CGContext) {
        for annotation in page.annotations where annotation.type == "FreeText" {
            drawFreeTextNote(annotation, in: context)
        }
    }

    private func drawFreeTextNote(_ annotation: PDFAnnotation, in context: CGContext) {
        context.saveGState()
        defer {
            context.restoreGState()
        }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(true)

        guard let contents = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines),
              !contents.isEmpty
        else {
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.freeTextAnnotationFont,
            .foregroundColor: Self.freeTextForegroundColor,
            .paragraphStyle: paragraphStyle
        ]

        (contents as NSString).draw(
            with: annotation.bounds.insetBy(dx: Self.freeTextTextPadding, dy: Self.freeTextTextPadding),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )

        NSGraphicsContext.restoreGraphicsState()
    }

    private func clamped(_ bounds: NSRect, to pageBounds: NSRect) -> NSRect {
        var clampedBounds = bounds
        clampedBounds.origin.x = min(
            max(pageBounds.minX, bounds.origin.x),
            pageBounds.maxX - bounds.width
        )
        clampedBounds.origin.y = min(
            max(pageBounds.minY, bounds.origin.y),
            pageBounds.maxY - bounds.height
        )
        return clampedBounds
    }

    private func clampedScaleFactor(_ scaleFactor: CGFloat) -> CGFloat {
        min(max(minScaleFactor, scaleFactor), maxScaleFactor)
    }

    private func scaleFactorForFitWidth() -> CGFloat {
        guard let page = currentPage ?? document?.page(at: 0) else {
            return scaleFactor
        }

        let pageWidth = page.bounds(for: displayBox).width
        guard pageWidth > 0 else {
            return scaleFactor
        }

        let horizontalInset: CGFloat = displayMode == .twoUp || displayMode == .twoUpContinuous ? 48 : 32
        let columns: CGFloat = displayMode == .twoUp || displayMode == .twoUpContinuous ? 2 : 1
        let availableWidth = max(80, bounds.width - horizontalInset)
        return availableWidth / (pageWidth * columns)
    }

    private func defaultFreeTextBounds(on page: PDFPage) -> NSRect {
        let pageBounds = page.bounds(for: .cropBox)
        let size = NSSize(
            width: min(220, pageBounds.width - 72),
            height: Self.singleLineFreeTextHeight(for: Self.freeTextAnnotationFont)
        )
        let viewPoint = NSPoint(x: bounds.midX, y: bounds.midY)
        let pointPage = self.page(for: viewPoint, nearest: true) ?? page
        let pagePoint = convert(viewPoint, to: pointPage)
        let origin: NSPoint

        if pointPage === page {
            origin = NSPoint(
                x: pagePoint.x - size.width / 2,
                y: pagePoint.y - size.height / 2
            )
        } else {
            origin = NSPoint(
                x: pageBounds.midX - size.width / 2,
                y: pageBounds.midY - size.height / 2
            )
        }

        return clamped(
            NSRect(origin: origin, size: size),
            to: pageBounds
        )
    }

    private func freeTextBounds(
        for text: String,
        near origin: NSPoint,
        in pageBounds: NSRect,
        font: NSFont
    ) -> NSRect {
        let horizontalPadding: CGFloat = 10
        let verticalPadding: CGFloat = 8
        let maxWidth = min(280, max(80, pageBounds.width - 72))
        let textBounds = (text as NSString).boundingRect(
            with: NSSize(
                width: maxWidth - horizontalPadding * 2,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let width = min(
            max(ceil(textBounds.width) + horizontalPadding * 2, 80),
            pageBounds.width - 72
        )
        let height = min(
            max(
                ceil(textBounds.height) + verticalPadding * 2,
                Self.singleLineFreeTextHeight(for: font)
            ),
            pageBounds.height - 72
        )

        return clamped(
            NSRect(
                x: origin.x,
                y: origin.y,
                width: width,
                height: height
            ),
            to: pageBounds
        )
    }

    private struct FreeTextDrag {
        let annotation: PDFAnnotation
        let page: PDFPage
        let pointerOffset: NSPoint
    }

    private struct FreeTextEditor {
        let textField: FreeTextInputField
        let page: PDFPage
        let initialBounds: NSRect
        let annotationFont: NSFont
    }

    private struct PageHighlightGeometry {
        let page: PDFPage
        var lineBounds: [NSRect]
    }

    private enum QuietLinkKind {
        case documentReference
        case citation
        case backReference
        case external
        case internalLink
    }

    private static var highlightColor: NSColor {
        NSColor(calibratedRed: 1.0, green: 0.92, blue: 0.24, alpha: 1.0)
    }

    private static var freeTextForegroundColor: NSColor {
        NSColor(calibratedRed: 0.84, green: 0.05, blue: 0.07, alpha: 1.0)
    }

    private static var freeTextPlaceholderColor: NSColor {
        NSColor(calibratedRed: 0.68, green: 0.10, blue: 0.12, alpha: 0.82)
    }

    private static var freeTextAnnotationFont: NSFont {
        NSFont.systemFont(ofSize: 14)
    }

    private static var freeTextTextPadding: CGFloat {
        8
    }

    private static func singleLineFreeTextHeight(for font: NSFont) -> CGFloat {
        let lineBounds = ("Hg" as NSString).boundingRect(
            with: NSSize(width: 220, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return max(ceil(lineBounds.height) + freeTextTextPadding * 2, 32)
    }

    private static func freeTextEditorFont(for scaleFactor: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: max(14, freeTextAnnotationFont.pointSize * scaleFactor))
    }

    deinit {
        stopObservingHighlightMenu()
    }
}

private final class FreeTextInputField: NSTextField {
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        selectText(nil)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }

        super.keyDown(with: event)
    }
}

private final class FreeTextInputCell: NSTextFieldCell {
    private let padding: CGFloat

    init(textCell string: String, padding: CGFloat) {
        self.padding = padding
        super.init(textCell: string)
        isEditable = true
        isSelectable = true
        isEnabled = true
        isScrollable = false
        wraps = true
        lineBreakMode = .byWordWrapping
    }

    required init(coder: NSCoder) {
        self.padding = 0
        super.init(coder: coder)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        textRect(forBounds: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        textRect(forBounds: rect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: textRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: textRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }

    private func textRect(forBounds rect: NSRect) -> NSRect {
        rect.insetBy(dx: padding, dy: padding)
    }
}
