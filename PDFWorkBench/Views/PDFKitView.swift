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
    let initialZoomState: PDFZoomState
    let zoomCommand: PDFZoomCommand?
    let outlineNavigationRequest: PDFOutlineNavigationRequest?
    let outlineEntries: [DocumentOutlineEntry]
    let dogears: [DogearMarker]
    let aiHighlightRailMarkers: [AIHighlightRailMarker]
    let isLoadingOutline: Bool
    let isNightMode: Bool
    let isMarginCanvasVisible: Bool
    let freeTextRequestID: Int
    let highlightRequest: PDFHighlightRequest?
    let shortcutSet: PDFReadingShortcutSet = .defaultReading
    let onSelectOutlineEntry: (DocumentOutlineEntry) -> Void
    let onSelectDogear: (DogearMarker) -> Void
    let onSelectAIHighlight: (AIHighlightRailMarker) -> Void
    let onToggleDogear: () -> Void
    let onToggleDogearAtPage: (Int) -> Void
    let onSelectMarginAnnotation: (PDFAnnotationItem.ID) -> Void
    let onSelectMarginText: (String, Int) -> Void
    let onHighlightRemoved: (FeedbackTrigger) -> Void
    let onAnnotationChanged: () -> Void
    let onUndoableAnnotationMutation: (String) -> Void
    let onFreeTextShortcut: () -> Void
    let onShortcutActivated: (PDFReadingShortcutAction, String) -> Void
    let onPageChanged: (Int) -> Void
    let onScaleChanged: (CGFloat, PDFZoomState) -> Void
    let onSelectionChanged: (PDFTextSelectionSnapshot?) -> Void
    var documentUndoManager: UndoManager? = nil
    var onUserInteraction: (() -> Void)? = nil
    var onReadingPositionChanged: ((PDFNavigationTarget) -> Void)? = nil
    var canCommitFreeText: (PDFDocument) -> Bool = { _ in false }
    var onPrepareFreeTextDraft: (PDFDocument, PDFPage, CGRect) -> FreeTextEditDraft? = { _, _, _ in nil }
    var onCommitFreeText: (FreeTextEditDraft, FreeTextEditValues) -> Bool = { _, _ in false }
    var onCommitHighlight: (PDFDocument, PDFSelection, FeedbackTrigger) -> Bool = { _, _, _ in false }

    @Environment(\.locale) private var locale

    func makeCoordinator() -> Coordinator {
        Coordinator(
            displayStyle: displayStyle,
            onPageChanged: onPageChanged,
            onScaleChanged: onScaleChanged,
            onSelectionChanged: onSelectionChanged,
            onReadingPositionChanged: onReadingPositionChanged
        )
    }

    func makeNSView(context: Context) -> PDFReaderContainerView {
        _ = locale
        let container = PDFReaderContainerView()
        let pdfView = container.pdfView
        pdfView.workspaceUndoManager = documentUndoManager
        pdfView.canCommitFreeText = canCommitFreeText
        pdfView.onPrepareFreeTextDraft = onPrepareFreeTextDraft
        pdfView.onCommitFreeText = onCommitFreeText
        pdfView.onCommitHighlight = onCommitHighlight
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
        pdfView.onHighlightRemoved = onHighlightRemoved
        pdfView.onAnnotationChanged = onAnnotationChanged
        pdfView.onUndoableAnnotationMutation = onUndoableAnnotationMutation
        pdfView.onFreeTextShortcut = onFreeTextShortcut
        pdfView.onUserInteraction = onUserInteraction
        pdfView.onDogearShortcut = onToggleDogear
        pdfView.onShortcutActivated = onShortcutActivated
        pdfView.applyNightMode(isNightMode)
        container.updateOutlineOverlay(
            entries: outlineEntries,
            aiHighlights: aiHighlightRailMarkers,
            currentPageIndex: targetPageIndex,
            isLoading: isLoadingOutline,
            isNightMode: isNightMode,
            onSelect: onSelectOutlineEntry,
            onSelectAIHighlight: onSelectAIHighlight
        )
        container.updateDogears(
            dogears,
            currentPageIndex: targetPageIndex,
            pageCount: document.pageCount,
            isNightMode: isNightMode,
            onSelect: onSelectDogear,
            onToggleAtPage: onToggleDogearAtPage
        )
        container.onSelectMarginAnnotation = onSelectMarginAnnotation
        container.onSelectMarginText = onSelectMarginText

        context.coordinator.observePageChanges(for: pdfView, in: container)
        context.coordinator.observeScaleChanges(for: pdfView, in: container)
        context.coordinator.observeSelectionChanges(for: pdfView)
        context.coordinator.observeAnnotationChanges(for: pdfView, in: container)
        return container
    }

    func updateNSView(_ container: PDFReaderContainerView, context: Context) {
        _ = locale
        let pdfView = container.pdfView
        context.coordinator.beginViewUpdate()
        defer { context.coordinator.endViewUpdate(in: container) }
        pdfView.workspaceUndoManager = documentUndoManager
        pdfView.canCommitFreeText = canCommitFreeText
        pdfView.onPrepareFreeTextDraft = onPrepareFreeTextDraft
        pdfView.onCommitFreeText = onCommitFreeText
        pdfView.onCommitHighlight = onCommitHighlight
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onScaleChanged = onScaleChanged
        context.coordinator.onSelectionChanged = onSelectionChanged
        context.coordinator.onReadingPositionChanged = onReadingPositionChanged
        if pdfView.document !== document {
            pdfView.stopQuietLinkPresentation()
            pdfView.beginQuietLinkPresentation(for: document)
            container.updateDogears(
                dogears,
                currentPageIndex: targetPageIndex,
                pageCount: document.pageCount,
                isNightMode: isNightMode,
                onSelect: onSelectDogear,
                onToggleAtPage: onToggleDogearAtPage
            )
            context.coordinator.installDocument(document, targetPageIndex: targetPageIndex, in: container)
            pdfView.hideNativeNoteAnnotations()
            context.coordinator.reportScale(from: pdfView)
            let installedDocument = document
            DispatchQueue.main.async {
                guard pdfView.document === installedDocument else {
                    return
                }
                container.layoutDocumentViewForTwoUpIfNeeded()
                pdfView.applyZoomState(initialZoomState)
                container.updateActiveFitScaleIfNeeded()
                context.coordinator.reportScale(from: pdfView)
                container.layoutMarginCanvas()
                context.coordinator.observeLiveScrolling(for: pdfView, in: container)
                context.coordinator.reportReadingPosition(from: pdfView)
            }
        }
        pdfView.shortcutSet = shortcutSet
        pdfView.onHighlightRemoved = onHighlightRemoved
        pdfView.onAnnotationChanged = onAnnotationChanged
        pdfView.onUndoableAnnotationMutation = onUndoableAnnotationMutation
        pdfView.onFreeTextShortcut = onFreeTextShortcut
        pdfView.onUserInteraction = onUserInteraction
        pdfView.onDogearShortcut = onToggleDogear
        pdfView.onShortcutActivated = onShortcutActivated
        pdfView.applyNightMode(isNightMode)
        container.onSelectMarginAnnotation = onSelectMarginAnnotation
        container.onSelectMarginText = onSelectMarginText
        container.updateOutlineOverlay(
            entries: outlineEntries,
            aiHighlights: aiHighlightRailMarkers,
            currentPageIndex: targetPageIndex,
            isLoading: isLoadingOutline,
            isNightMode: isNightMode,
            onSelect: onSelectOutlineEntry,
            onSelectAIHighlight: onSelectAIHighlight
        )
        container.updateDogears(
            dogears,
            currentPageIndex: targetPageIndex,
            pageCount: document.pageCount,
            isNightMode: isNightMode,
            onSelect: onSelectDogear,
            onToggleAtPage: onToggleDogearAtPage
        )
        container.updateMarginCanvas(
            isVisible: isMarginCanvasVisible,
            isSupported: displayStyle != .twoUp,
            isNightMode: isNightMode,
            selectedAnnotationID: selectedAnnotation?.id
        )
        context.coordinator.observeLiveScrolling(for: pdfView, in: container)

        if context.coordinator.lastDisplayStyle != displayStyle {
            context.coordinator.lastDisplayStyle = displayStyle
            pdfView.applyDisplayStyle(displayStyle, preservingPageIndex: targetPageIndex)
            context.coordinator.reportScale(from: pdfView)
            DispatchQueue.main.async {
                container.layoutDocumentViewForTwoUpIfNeeded()
                container.updateActiveFitScaleIfNeeded()
                container.layoutMarginCanvas()
                context.coordinator.observeLiveScrolling(for: pdfView, in: container)
            }
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
            context.coordinator.navigate(to: outlineNavigationRequest.target, in: container)
        }

        if context.coordinator.lastFreeTextRequestID != freeTextRequestID {
            context.coordinator.lastFreeTextRequestID = freeTextRequestID
            if freeTextRequestID > 0 {
                let requestedDocument = document
                let requestID = freeTextRequestID
                let coordinator = context.coordinator
                // beginSheet triggers native layout/animation. Present after
                // SwiftUI completes updateNSView, not reentrantly inside its
                // AttributeGraph layout transaction.
                DispatchQueue.main.async { [weak pdfView, weak coordinator] in
                    guard let pdfView, let coordinator,
                          coordinator.lastFreeTextRequestID == requestID,
                          pdfView.document === requestedDocument,
                          pdfView.window?.isVisible == true else { return }
                    pdfView.beginFreeTextEditing()
                }
            }
        }

        if let highlightRequest,
           context.coordinator.lastHighlightRequestID != highlightRequest.id {
            context.coordinator.lastHighlightRequestID = highlightRequest.id
            pdfView.addHighlightToCurrentSelection(trigger: highlightRequest.trigger)
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
            context.coordinator.navigate(to: targetPageIndex, in: container)
        }
    }

    static func dismantleNSView(_ container: PDFReaderContainerView, coordinator: Coordinator) {
        container.pdfView.stopQuietLinkPresentation()
        coordinator.stopObserving()
    }

    final class Coordinator {
        var onPageChanged: (Int) -> Void
        var onScaleChanged: (CGFloat, PDFZoomState) -> Void
        var onSelectionChanged: (PDFTextSelectionSnapshot?) -> Void
        var onReadingPositionChanged: ((PDFNavigationTarget) -> Void)?
        var lastFreeTextRequestID = 0
        var lastHighlightRequestID = 0
        var lastTargetPageIndex: Int
        // A requested destination is not an acknowledgement that Library has
        // received the native page change. Keep these two identities separate.
        private var lastReportedPageIndex: Int?
        private var pendingPageConfirmationID: UUID?
        private var isUpdatingView = false
        private var needsPostUpdatePageReport = false
        var lastSelectedAnnotationID: PDFAnnotationItem.ID?
        var lastSelectedSearchResultID: PDFSearchResult.ID?
        var lastZoomCommandID = 0
        var lastOutlineNavigationRequestID = 0
        var lastDisplayStyle: PDFReadingDisplayStyle
        private var pageObserver: NSObjectProtocol?
        private var scrollBoundsObserver: NSObjectProtocol?
        private var scaleObserver: NSObjectProtocol?
        private var selectionObserver: NSObjectProtocol?
        private var annotationObserver: NSObjectProtocol?
        private weak var observedClipView: NSClipView?
        private var pendingScaleUpdate: (scaleFactor: CGFloat, zoomState: PDFZoomState)?
        private var isScaleReportScheduled = false
        private var lastReportedScalePercent: Int?
        private var lastReportedZoomState: PDFZoomState?
        private weak var pendingPositionPDFView: HighlightingPDFView?
        private var isReadingPositionReportScheduled = false
        private var lastReportedReadingPosition: PDFNavigationTarget?

        init(
            displayStyle: PDFReadingDisplayStyle,
            onPageChanged: @escaping (Int) -> Void,
            onScaleChanged: @escaping (CGFloat, PDFZoomState) -> Void,
            onSelectionChanged: @escaping (PDFTextSelectionSnapshot?) -> Void,
            onReadingPositionChanged: ((PDFNavigationTarget) -> Void)? = nil
        ) {
            self.lastDisplayStyle = displayStyle
            self.onPageChanged = onPageChanged
            self.onScaleChanged = onScaleChanged
            self.onSelectionChanged = onSelectionChanged
            self.onReadingPositionChanged = onReadingPositionChanged
            self.lastTargetPageIndex = 0
        }

        func observeSelectionChanges(for pdfView: PDFView) {
            selectionObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name.PDFViewSelectionChanged,
                object: pdfView,
                queue: .main
            ) { [weak self, weak pdfView] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let pdfView,
                          let document = pdfView.document,
                          let selection = pdfView.currentSelection
                    else {
                        self.onSelectionChanged(nil)
                        return
                    }

                    self.onSelectionChanged(PDFTextSelectionService.snapshot(of: selection, in: document))
                }
            }
        }

        func observeAnnotationChanges(for pdfView: HighlightingPDFView, in container: PDFReaderContainerView) {
            annotationObserver = NotificationCenter.default.addObserver(
                forName: .dogearAnnotationsChanged, object: nil, queue: .main
            ) { [weak pdfView, weak container] notification in
                guard let pdfView, let changed = notification.object as? PDFDocument,
                      pdfView.document === changed else { return }
                pdfView.hideNativeNoteAnnotations()
                // Invalidate paint only. Reinstalling the document would reset
                // reading position, native selection and PDFKit Undo routing.
                pdfView.documentView?.needsDisplay = true
                pdfView.needsDisplay = true
                container?.layoutMarginCanvas()
            }
        }

        func observePageChanges(for pdfView: HighlightingPDFView, in container: PDFReaderContainerView) {
            pageObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name.PDFViewPageChanged,
                object: pdfView,
                queue: .main
            ) { [weak self, weak pdfView, weak container] _ in
                guard let self else { return }
                guard let pdfView,
                      let document = pdfView.document,
                      let currentPage = pdfView.currentPage
                else {
                    return
                }

                self.reportPageChange(
                    document.index(for: currentPage),
                    in: container
                )
                DispatchQueue.main.async {
                    container?.layoutDocumentViewForTwoUpIfNeeded()
                    container?.updateActiveFitScaleIfNeeded()
                    container?.layoutMarginCanvas()
                    self.reportReadingPosition(from: pdfView)
                }
            }
        }

        func observeLiveScrolling(
            for pdfView: HighlightingPDFView,
            in container: PDFReaderContainerView
        ) {
            guard let scrollView = pdfView.documentView?.enclosingScrollView else {
                return
            }

            let clipView = scrollView.contentView
            guard observedClipView !== clipView else {
                return
            }
            container.configurePDFScrollView(scrollView)
            reportReadingPosition(from: pdfView)

            if let scrollBoundsObserver {
                NotificationCenter.default.removeObserver(scrollBoundsObserver)
            }
            observedClipView = clipView
            clipView.postsBoundsChangedNotifications = true
            scrollBoundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self, weak pdfView, weak container] _ in
                guard let self,
                      let pdfView,
                      let container,
                      let document = pdfView.document,
                      let visiblePage = pdfView.page(
                        for: NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY),
                        nearest: true
                      )
                else {
                    return
                }

                self.reportPageChange(document.index(for: visiblePage), in: container)
                self.reportReadingPosition(from: pdfView)
                container.layoutMarginCanvas()
            }
        }

        private func reportPageChange(_ pageIndex: Int, in container: PDFReaderContainerView?) {
            guard pendingPageConfirmationID == nil, pageIndex != NSNotFound,
                  lastReportedPageIndex != pageIndex
            else {
                return
            }

            guard !isUpdatingView else {
                needsPostUpdatePageReport = true
                return
            }

            container?.updateCurrentPageIndex(pageIndex)
            lastTargetPageIndex = pageIndex
            lastReportedPageIndex = pageIndex
            onPageChanged(pageIndex)
        }

        func navigate(to pageIndex: Int, in container: PDFReaderContainerView) {
            guard let document = container.pdfView.document else { return }
            lastTargetPageIndex = pageIndex
            performPageNavigation(for: document, in: container) {
                container.pdfView.goToPage(index: pageIndex)
            }
        }

        func navigate(to target: PDFNavigationTarget, in container: PDFReaderContainerView) {
            guard let document = container.pdfView.document else { return }
            lastTargetPageIndex = target.pageIndex
            performPageNavigation(for: document, in: container) {
                container.pdfView.goToOutlineTarget(target)
            }
        }

        func installDocument(_ document: PDFDocument, targetPageIndex: Int, in container: PDFReaderContainerView) {
            // PDFKit may announce page 0 while attaching a new document. Its
            // initial saved destination must be applied before publishing pages.
            resetNavigationState(targetPageIndex: targetPageIndex)
            performPageNavigation(for: document, in: container) {
                container.pdfView.document = document
                container.pdfView.goToPage(index: targetPageIndex)
            }
        }

        func beginViewUpdate() { isUpdatingView = true }

        func endViewUpdate(in container: PDFReaderContainerView) {
            isUpdatingView = false
            guard needsPostUpdatePageReport else { return }
            needsPostUpdatePageReport = false
            if let document = container.pdfView.document {
                performPageNavigation(for: document, in: container) {}
            }
        }

        private func performPageNavigation(for document: PDFDocument, in container: PDFReaderContainerView,
                                           action: () -> Void) {
            let id = UUID()
            pendingPageConfirmationID = id
            action()
            // Native go(to:) may announce intermediate pages synchronously.
            // Confirm its final current page outside updateNSView, discarding
            // superseded commands and callbacks belonging to another PDF.
            DispatchQueue.main.async { [weak self, weak document, weak container] in
                guard let self, self.pendingPageConfirmationID == id else { return }
                self.pendingPageConfirmationID = nil
                guard let document, let container, container.pdfView.document === document else { return }
                self.reportCurrentPage(in: container)
            }
        }

        private func reportCurrentPage(in container: PDFReaderContainerView) {
            guard let document = container.pdfView.document,
                  let page = container.pdfView.currentPage else { return }
            reportPageChange(document.index(for: page), in: container)
        }

        func observeScaleChanges(for pdfView: HighlightingPDFView, in container: PDFReaderContainerView) {
            scaleObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name.PDFViewScaleChanged,
                object: pdfView,
                queue: .main
            ) { [weak self, weak pdfView, weak container] _ in
                guard let self else { return }
                guard let pdfView else {
                    return
                }

                container?.layoutOutlineOverlay()
                container?.layoutMarginCanvas()
                self.reportScale(from: pdfView)
                DispatchQueue.main.async {
                    container?.layoutDocumentViewForTwoUpIfNeeded()
                    container?.updateActiveFitScaleIfNeeded()
                    container?.layoutMarginCanvas()
                }
            }
        }

        func resetNavigationState(targetPageIndex: Int) {
            pendingPageConfirmationID = nil
            needsPostUpdatePageReport = false
            lastTargetPageIndex = targetPageIndex
            lastReportedPageIndex = targetPageIndex
            lastSelectedAnnotationID = nil
            lastSelectedSearchResultID = nil
            lastReportedReadingPosition = nil
            lastReportedScalePercent = nil
            lastReportedZoomState = nil
        }

        /// Position reports are deferred out of NSViewRepresentable updates and
        /// coalesced during smooth scrolling. Read the latest native destination
        /// when delivered so switching documents cannot emit a stale old offset.
        func reportReadingPosition(from pdfView: HighlightingPDFView) {
            guard onReadingPositionChanged != nil else { return }
            pendingPositionPDFView = pdfView
            guard !isReadingPositionReportScheduled else { return }
            isReadingPositionReportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isReadingPositionReportScheduled = false
                guard let position = self.pendingPositionPDFView?.currentReadingPosition,
                      position != self.lastReportedReadingPosition else { return }
                self.lastReportedReadingPosition = position
                self.onReadingPositionChanged?(position)
            }
        }

        func reportScale(from pdfView: HighlightingPDFView) {
            reportReadingPosition(from: pdfView)
            let scaleFactor = pdfView.scaleFactor
            guard scaleFactor.isFinite, scaleFactor > 0 else {
                return
            }

            pendingScaleUpdate = (scaleFactor, pdfView.currentZoomState)
            guard !isScaleReportScheduled else {
                return
            }

            isScaleReportScheduled = true
            DispatchQueue.main.async {
                self.isScaleReportScheduled = false
                guard let pendingScaleUpdate = self.pendingScaleUpdate else {
                    return
                }

                self.pendingScaleUpdate = nil
                let scalePercent = Int((pendingScaleUpdate.scaleFactor * 100).rounded())
                guard self.lastReportedScalePercent != scalePercent
                        || self.lastReportedZoomState != pendingScaleUpdate.zoomState else {
                    return
                }

                self.lastReportedScalePercent = scalePercent
                self.lastReportedZoomState = pendingScaleUpdate.zoomState
                self.onScaleChanged(
                    pendingScaleUpdate.scaleFactor,
                    pendingScaleUpdate.zoomState
                )
            }
        }

        func stopObserving() {
            pendingPageConfirmationID = nil
            needsPostUpdatePageReport = false
            for observer in [pageObserver, scrollBoundsObserver, scaleObserver, selectionObserver, annotationObserver].compactMap({ $0 }) {
                NotificationCenter.default.removeObserver(observer)
            }
            pageObserver = nil
            scrollBoundsObserver = nil
            scaleObserver = nil
            selectionObserver = nil
            annotationObserver = nil
            observedClipView = nil
            pendingPositionPDFView = nil
            pendingScaleUpdate = nil
            onReadingPositionChanged = nil
        }

        deinit {
            if let pageObserver {
                NotificationCenter.default.removeObserver(pageObserver)
            }
            if let scrollBoundsObserver {
                NotificationCenter.default.removeObserver(scrollBoundsObserver)
            }

            if let scaleObserver {
                NotificationCenter.default.removeObserver(scaleObserver)
            }
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }
            if let annotationObserver {
                NotificationCenter.default.removeObserver(annotationObserver)
            }
        }
    }
}

struct PDFReadingShortcutSet: Equatable {
    var highlightKeys: Set<String>
    var noteKeys: Set<String>
    var dogearKeys: Set<String>
    var pageUpKeys: Set<String>
    var pageDownKeys: Set<String>

    static let defaultReading = PDFReadingShortcutSet(
        highlightKeys: ["h"],
        noteKeys: ["t"],
        dogearKeys: ["d"],
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

        if dogearKeys.contains(key) {
            return .dogear
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
    case dogear
    case pageUp
    case pageDown
}

final class PDFReaderContainerView: NSView {
    let pdfView = HighlightingPDFView()
    let marginCanvasView = MarginCanvasView()

    private let outlineInteractionWidth: CGFloat = 72
    private let outlinePresentationWidth: CGFloat = 260
    private let preferredMarginCanvasWidth: CGFloat = 248
    private let minimumMarginCanvasWidth: CGFloat = 164
    private let marginCanvasEdgeInset: CGFloat = 10
    private let marginCanvasContentGap: CGFloat = 12
    private var outlineHostingView: NSHostingView<DocumentOutlineRailView>?
    private struct OutlinePresentation: Equatable {
        let entries: [DocumentOutlineEntry]
        let dogears: [DogearMarker]
        let aiHighlights: [AIHighlightRailMarker]
        let pageCount: Int
        let currentPage: Int
        let isLoading: Bool
        let isNightMode: Bool
        let selectedEntryID: DocumentOutlineEntry.ID?
    }
    private var renderedOutline: OutlinePresentation?
    private(set) var outlineRenderCount = 0
    private var outlineEntries: [DocumentOutlineEntry] = []
    private var aiHighlightRailMarkers: [AIHighlightRailMarker] = []
    private var outlineCurrentPageIndex = 0
    private var isLoadingOutline = false
    private var isOutlineNightMode = false
    private var onSelectOutlineEntry: ((DocumentOutlineEntry) -> Void)?
    private var onSelectAIHighlight: ((AIHighlightRailMarker) -> Void)?
    private var selectedOutlineEntryID: DocumentOutlineEntry.ID?
    private var selectedOutlinePageIndex: Int?
    private var dogears: [DogearMarker] = []
    private var dogearPageCount = 0
    private var onSelectDogear: ((DogearMarker) -> Void)?
    private let dogearOverlayProvider = DogearPageOverlayViewProvider()
    private var requestsMarginCanvas = false
    private var supportsMarginCanvas = true
    private var isMarginCanvasNightMode = false
    private var selectedMarginAnnotationID: PDFAnnotationItem.ID?
    private weak var marginContentBoundsDocument: PDFDocument?
    private var marginContentBoundsByPage: [ObjectIdentifier: NSRect] = [:]
    var onSelectMarginAnnotation: ((PDFAnnotationItem.ID) -> Void)?
    var onSelectMarginText: ((String, Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(pdfView)
        marginCanvasView.pdfView = pdfView
        marginCanvasView.onSelectText = { [weak self] text, entry in
            self?.onSelectMarginText?(text, entry.pageNumber)
        }
        addSubview(marginCanvasView, positioned: .above, relativeTo: pdfView)
        marginCanvasView.isHidden = true
        pdfView.onAnnotatedHighlightPressed = { [weak self] annotation in
            self?.activateMarginAnnotation(annotation) ?? false
        }
        pdfView.pageOverlayViewProvider = dogearOverlayProvider
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
        marginCanvasView.frame = bounds
        pdfView.updateActiveFitScaleIfNeeded()
        layoutDocumentViewForTwoUpIfNeeded()
        layoutOutlineOverlay()
        layoutMarginCanvas()
    }

    func updateMarginCanvas(
        isVisible: Bool,
        isSupported: Bool,
        isNightMode: Bool,
        selectedAnnotationID: PDFAnnotationItem.ID?
    ) {
        let requiresLayout = requestsMarginCanvas != isVisible
            || supportsMarginCanvas != isSupported
        let presentationChanged = isMarginCanvasNightMode != isNightMode
            || selectedMarginAnnotationID != selectedAnnotationID
        requestsMarginCanvas = isVisible
        supportsMarginCanvas = isSupported
        isMarginCanvasNightMode = isNightMode
        selectedMarginAnnotationID = selectedAnnotationID
        if requiresLayout {
            needsLayout = true
            layoutSubtreeIfNeeded()
        } else if presentationChanged {
            layoutMarginCanvas()
        }
    }

    func layoutMarginCanvas() {
        guard isMarginCanvasActive,
              let document = pdfView.document
        else {
            guard !marginCanvasView.isHidden else { return }
            marginCanvasView.isHidden = true
            marginCanvasView.update(
                entries: [],
                laneFrame: .zero,
                selectedEntryID: nil,
                isNightMode: isMarginCanvasNightMode
            )
            return
        }

        if marginContentBoundsDocument !== document {
            marginContentBoundsDocument = document
            marginContentBoundsByPage = [:]
        }

        var entries: [MarginCanvasAnnotationEntry] = []
        var visiblePageFrames: [NSRect] = []
        var visibleContentFrames: [NSRect] = []

        for page in pdfView.visiblePages {
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { continue }
            let pageFrame = convert(
                pdfView.convert(page.bounds(for: pdfView.displayBox), from: page),
                from: pdfView
            )
            visiblePageFrames.append(pageFrame)
            for (annotationIndex, annotation) in page.annotations.enumerated() {
                guard Self.supportsMarginCard(annotation),
                      let note = annotation.contents?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !note.isEmpty
                else {
                    continue
                }

                let classification = AIAnnotationProvenance.classify(annotation)
                if classification.isAI && !annotation.shouldDisplay {
                    continue
                }

                let anchorFrame = convert(
                    pdfView.convert(annotation.bounds, from: page),
                    from: pdfView
                )
                let entryID = PDFAnnotationItem.id(
                    pageIndex: pageIndex,
                    annotationIndex: annotationIndex,
                    annotation: annotation
                )
                entries.append(
                    MarginCanvasAnnotationEntry(
                        id: entryID,
                        pageIndex: pageIndex,
                        annotation: annotation,
                        note: note,
                        anchorFrame: anchorFrame,
                        pageFrame: pageFrame,
                        isAIGenerated: classification.isAI,
                        category: AIAnnotationProvenance.embeddedMetadata(of: annotation)?.category
                    )
                )
            }
        }

        // Most pages have no margin notes. Do not extract all their text just
        // to place a lane that has nothing to display.
        guard !entries.isEmpty else {
            if !marginCanvasView.isHidden {
                marginCanvasView.isHidden = true
                marginCanvasView.update(entries: [], laneFrame: .zero,
                    selectedEntryID: nil, isNightMode: isMarginCanvasNightMode)
            }
            return
        }
        for page in pdfView.visiblePages {
            let contentBounds = estimatedContentBounds(for: page)
            visibleContentFrames.append(
                convert(pdfView.convert(contentBounds, from: page), from: pdfView)
            )
        }

        let laneFrame = floatingMarginCanvasFrame(
            pageFrames: visiblePageFrames,
            contentFrames: visibleContentFrames
        )
        guard !laneFrame.isEmpty else {
            marginCanvasView.isHidden = true
            marginCanvasView.update(
                entries: [],
                laneFrame: .zero,
                selectedEntryID: nil,
                isNightMode: isMarginCanvasNightMode
            )
            return
        }

        marginCanvasView.isHidden = false
        marginCanvasView.update(
            entries: entries,
            laneFrame: laneFrame,
            selectedEntryID: selectedMarginAnnotationID,
            isNightMode: isMarginCanvasNightMode
        )
    }

    private var isMarginCanvasActive: Bool {
        requestsMarginCanvas && supportsMarginCanvas
    }

    private func estimatedContentBounds(for page: PDFPage) -> NSRect {
        let key = ObjectIdentifier(page)
        if let cached = marginContentBoundsByPage[key] {
            return cached
        }

        let pageBounds = page.bounds(for: pdfView.displayBox)
        let textLength = page.string.map { ($0 as NSString).length } ?? 0
        let contentBounds: NSRect
        if textLength > 0,
           let selection = page.selection(for: NSRange(location: 0, length: textLength)) {
            let selectedBounds = selection.bounds(for: page).intersection(pageBounds)
            contentBounds = selectedBounds.width > 1 && selectedBounds.height > 1
                ? selectedBounds
                : pageBounds
        } else {
            contentBounds = pageBounds
        }

        marginContentBoundsByPage[key] = contentBounds
        return contentBounds
    }

    private func floatingMarginCanvasFrame(
        pageFrames: [NSRect],
        contentFrames: [NSRect]
    ) -> NSRect {
        guard !pageFrames.isEmpty,
              bounds.width >= minimumMarginCanvasWidth + marginCanvasEdgeInset * 2
        else {
            return .zero
        }

        let rightEdge = bounds.maxX - marginCanvasEdgeInset
        let rightmostContentEdge = contentFrames
            .map(\.maxX)
            .max()
            ?? pageFrames.map(\.maxX).max()
            ?? rightEdge
        let clearWidth = rightEdge - rightmostContentEdge - marginCanvasContentGap
        let fallbackWidth = min(
            preferredMarginCanvasWidth,
            max(minimumMarginCanvasWidth, bounds.width * 0.28)
        )
        let width = clearWidth >= minimumMarginCanvasWidth
            ? min(preferredMarginCanvasWidth, clearWidth)
            : fallbackWidth

        return NSRect(
            x: rightEdge - width,
            y: bounds.minY,
            width: width,
            height: bounds.height
        )
    }

    private static func supportsMarginCard(_ annotation: PDFAnnotation) -> Bool {
        switch annotation.type {
        case "Highlight", "Text", "FreeText":
            return true
        default:
            return false
        }
    }

    @discardableResult
    private func activateMarginAnnotation(_ annotation: PDFAnnotation) -> Bool {
        guard isMarginCanvasActive,
              let page = annotation.page,
              let document = pdfView.document,
              Self.supportsMarginCard(annotation),
              annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return false
        }

        if AIAnnotationProvenance.classify(annotation).isAI,
           !annotation.shouldDisplay {
            return false
        }

        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound,
              let annotationIndex = page.annotations.firstIndex(where: { $0 === annotation })
        else {
            return false
        }
        let entryID = PDFAnnotationItem.id(
            pageIndex: pageIndex,
            annotationIndex: annotationIndex,
            annotation: annotation
        )
        selectedMarginAnnotationID = entryID
        marginCanvasView.select(entryID: entryID)
        onSelectMarginAnnotation?(entryID)
        return true
    }

    func layoutDocumentViewForTwoUpIfNeeded() {
        guard pdfView.displayMode == .twoUp || pdfView.displayMode == .twoUpContinuous,
              let documentView = pdfView.documentView
        else {
            return
        }

        let pageViews = documentView.subviews
        guard !pageViews.isEmpty else {
            return
        }

        let maxX = pageViews.map { $0.frame.maxX }.max() ?? documentView.frame.maxX
        let maxY = pageViews.map { $0.frame.maxY }.max() ?? documentView.frame.maxY
        guard maxX > 0, maxY > 0 else {
            return
        }

        let expectedSize = NSSize(width: maxX + 4, height: maxY + 4)
        guard abs(documentView.frame.width - expectedSize.width) > 1
                || abs(documentView.frame.height - expectedSize.height) > 1
        else {
            return
        }

        documentView.frame = NSRect(origin: .zero, size: expectedSize)
        documentView.enclosingScrollView?.tile()
    }

    func configurePDFScrollView(_ scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.controlSize = .mini
        scrollView.horizontalScroller?.controlSize = .mini
    }

    func updateActiveFitScaleIfNeeded() {
        pdfView.updateActiveFitScaleIfNeeded()
    }

    func updateOutlineOverlay(
        entries: [DocumentOutlineEntry],
        aiHighlights: [AIHighlightRailMarker],
        currentPageIndex: Int,
        isLoading: Bool,
        isNightMode: Bool,
        onSelect: @escaping (DocumentOutlineEntry) -> Void,
        onSelectAIHighlight: @escaping (AIHighlightRailMarker) -> Void
    ) {
        outlineEntries = entries
        aiHighlightRailMarkers = aiHighlights
        outlineCurrentPageIndex = currentPageIndex
        isLoadingOutline = isLoading
        isOutlineNightMode = isNightMode
        onSelectOutlineEntry = onSelect
        self.onSelectAIHighlight = onSelectAIHighlight
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

        let presentation = OutlinePresentation(entries: outlineEntries, dogears: dogears,
            aiHighlights: aiHighlightRailMarkers, pageCount: dogearPageCount,
            currentPage: outlineCurrentPageIndex, isLoading: isLoadingOutline,
            isNightMode: isOutlineNightMode, selectedEntryID: selectedOutlineEntryID)
        guard renderedOutline != presentation else { return }
        renderedOutline = presentation
        outlineRenderCount += 1

        let rootView = DocumentOutlineRailView(
            entries: outlineEntries,
            dogears: dogears,
            aiHighlights: aiHighlightRailMarkers,
            pageCount: dogearPageCount,
            currentPageIndex: outlineCurrentPageIndex,
            isLoading: isLoadingOutline,
            isNightMode: isOutlineNightMode,
            selectedEntryID: selectedOutlineEntryID,
            onSelect: { [weak self] entry in
                self?.activateOutlineEntry(entry)
            },
            onSelectDogear: { [weak self] marker in
                self?.onSelectDogear?(marker)
            },
            onSelectAIHighlight: { [weak self] marker in
                self?.onSelectAIHighlight?(marker)
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

    func updateDogears(
        _ markers: [DogearMarker],
        currentPageIndex: Int,
        pageCount: Int,
        isNightMode: Bool,
        onSelect: @escaping (DogearMarker) -> Void,
        onToggleAtPage: @escaping (Int) -> Void
    ) {
        dogears = markers
        dogearPageCount = pageCount
        outlineCurrentPageIndex = currentPageIndex
        isOutlineNightMode = isNightMode
        onSelectDogear = onSelect
        dogearOverlayProvider.dogears = markers
        dogearOverlayProvider.isNightMode = isNightMode
        dogearOverlayProvider.onToggleDogearAtPage = onToggleAtPage
        dogearOverlayProvider.update(dogears: markers, isNightMode: isNightMode)
        renderOutlineOverlay()
    }

    private func activateOutlineEntry(_ entry: DocumentOutlineEntry) {
        selectedOutlineEntryID = entry.id
        selectedOutlinePageIndex = entry.target.pageIndex
        renderOutlineOverlay()
        onSelectOutlineEntry?(entry)
    }

    func layoutOutlineOverlay() {
        guard let outlineHostingView else {
            outlineHostingView?.isHidden = true
            return
        }

        let height = outlineHostingView.rootView.preferredHeight
        let x = min(
            bounds.minX + 8,
            bounds.maxX - outlineInteractionWidth - 8
        )
        let y = bounds.midY - height / 2

        outlineHostingView.isHidden = false
        outlineHostingView.frame = NSRect(
            x: x,
            y: y,
            width: outlinePresentationWidth,
            height: height
        )
    }

}

final class HighlightingPDFView: PDFView, NSUserInterfaceValidations {
    weak var workspaceUndoManager: UndoManager?
    override var undoManager: UndoManager? { workspaceUndoManager ?? super.undoManager }

    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return undoManager?.canUndo == true }
        if item.action == #selector(redo(_:)) { return undoManager?.canRedo == true }
        return true
    }

    var onUserInteraction: (() -> Void)?
    var shortcutSet: PDFReadingShortcutSet = .defaultReading
    var onHighlightRemoved: ((FeedbackTrigger) -> Void)?
    var onAnnotationChanged: (() -> Void)?
    var onUndoableAnnotationMutation: ((String) -> Void)?
    var onFreeTextShortcut: (() -> Void)?
    var canCommitFreeText: (PDFDocument) -> Bool = { _ in false }
    var onPrepareFreeTextDraft: (PDFDocument, PDFPage, CGRect) -> FreeTextEditDraft? = { _, _, _ in nil }
    var onCommitFreeText: (FreeTextEditDraft, FreeTextEditValues) -> Bool = { _, _ in false }
    var onCommitHighlight: (PDFDocument, PDFSelection, FeedbackTrigger) -> Bool = { _, _, _ in false }
    var onDogearShortcut: (() -> Void)?
    var onShortcutActivated: ((PDFReadingShortcutAction, String) -> Void)?
    var onAnnotatedHighlightPressed: ((PDFAnnotation) -> Bool)?

    private var freeTextDrag: FreeTextDrag?
    private var freeTextEditorPanel: NSPanel?
    private weak var selectedHighlight: PDFAnnotation?
    private var consumedAnnotatedHighlightPress = false
    private var highlightMenuEndTrackingObserver: NSObjectProtocol?
    private weak var quietLinkDocument: PDFDocument?
    private weak var hoveredQuietLink: PDFAnnotation?
    private weak var activatedQuietLink: PDFAnnotation?
    private weak var pressedQuietLink: PDFAnnotation?
    private var quietLinkTrackingArea: NSTrackingArea?
    private var quietLinkRectsCache: [ObjectIdentifier: [NSRect]] = [:]
    private var quietLinkActivationID = 0
    private var standardBackgroundColor: NSColor?
    private var standardPageShadowsEnabled: Bool?
    private var appliedNightMode: Bool?
    private let nightSelectionPresentation = PDFNightSelectionPresentation()
    private enum ActiveFitMode {
        case page
        case width
    }

    private var activeFitMode: ActiveFitMode?
    private var standardDisplaysPageBreaks: Bool?
    private var standardPageBreakMargins: NSEdgeInsets?
    private var standardFitMinScaleFactor: CGFloat?
    private var standardFitShadowsEnabled: Bool?

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
        if standardPageShadowsEnabled == nil {
            standardPageShadowsEnabled = pageShadowsEnabled
        }
        appliedNightMode = isEnabled
        wantsLayer = true

        if isEnabled {
            backgroundColor = .white
            pageShadowsEnabled = false
            layer?.filters = PDFNightSelectionPresentation.nightFilters()
        } else {
            backgroundColor = standardBackgroundColor ?? .windowBackgroundColor
            pageShadowsEnabled = activeFitMode != nil
                ? false
                : standardPageShadowsEnabled ?? true
            layer?.filters = nil
        }
        nightSelectionPresentation.apply(to: self, enabled: isEnabled)
    }

    /// PDFKit represents its current viewport as a destination in page space.
    /// Keeping this point (including offsets outside the page edges) preserves
    /// horizontal scrolling, page margins and rotated-page positions on return.
    var currentReadingPosition: PDFNavigationTarget? {
        guard let document else { return nil }
        let destination = currentDestination
        guard let page = destination?.page ?? currentPage else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return nil }
        let viewportTopLeft = NSPoint(x: bounds.minX, y: isFlipped ? bounds.minY : bounds.maxY)
        let fallbackPoint = convert(viewportTopLeft, to: page)
        let destinationPoint = destination?.point ?? fallbackPoint
        let point = CGPoint(
            x: destinationPoint.x.isFinite && destinationPoint.x != kPDFDestinationUnspecifiedValue ? destinationPoint.x : fallbackPoint.x,
            y: destinationPoint.y.isFinite && destinationPoint.y != kPDFDestinationUnspecifiedValue ? destinationPoint.y : fallbackPoint.y
        )
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let pageBounds = page.bounds(for: displayBox)
        let relative = pageBounds.height > 0 ? min(1, max(0, (pageBounds.maxY - point.y) / pageBounds.height)) : nil
        return PDFNavigationTarget(pageIndex: pageIndex, point: point, relativePagePosition: relative)
    }

    func goToOutlineTarget(_ target: PDFNavigationTarget) {
        guard let page = document?.page(at: target.pageIndex) else {
            return
        }

        if let point = target.point, point.x.isFinite, point.y.isFinite {
            let destination = PDFDestination(page: page, at: point)
            // Navigation restores position only. Its zoom belongs to the reader's
            // explicit Fit/custom mode and must not be reset by PDFDestination.
            destination.zoom = kPDFDestinationUnspecifiedValue
            go(to: destination)
        } else {
            go(to: page)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !isHiddenOrHasHiddenAncestor {
            window?.makeFirstResponder(self)
        }
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
        onUserInteraction?()
        window?.makeFirstResponder(self)

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
        if let selectedHighlight,
           onAnnotatedHighlightPressed?(selectedHighlight) == true {
            consumedAnnotatedHighlightPress = true
            return
        }
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
        var bounds = freeTextDrag.currentBounds
        bounds.origin.x = pagePoint.x - freeTextDrag.pointerOffset.x
        bounds.origin.y = pagePoint.y - freeTextDrag.pointerOffset.y
        bounds = clamped(bounds, to: freeTextDrag.page.bounds(for: .cropBox))
        guard bounds != freeTextDrag.currentBounds else {
            return
        }

        var updatedDrag = freeTextDrag
        updatedDrag.currentBounds = bounds
        self.freeTextDrag = updatedDrag
        invalidateFreeTextDrag(
            on: freeTextDrag.page,
            from: freeTextDrag.currentBounds,
            to: bounds
        )
    }

    override func mouseUp(with event: NSEvent) {
        if consumedAnnotatedHighlightPress {
            consumedAnnotatedHighlightPress = false
            return
        }

        if let pressedQuietLink {
            self.pressedQuietLink = nil
            if quietLinkAnnotation(at: event) === pressedQuietLink {
                performQuietLinkAction(pressedQuietLink)
            }
            return
        }

        if let freeTextDrag {
            self.freeTextDrag = nil
            guard freeTextDrag.currentBounds != freeTextDrag.initialBounds else {
                return
            }

            freeTextDrag.annotation.bounds = freeTextDrag.currentBounds
            registerBoundsUndo(
                for: freeTextDrag.annotation,
                page: freeTextDrag.page,
                restoring: freeTextDrag.initialBounds,
                actionName: "Move Free Text Note"
            )
            refreshDisplay(for: freeTextDrag.page)
            onAnnotationChanged?()
            return
        }

        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        onUserInteraction?()
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
        case .highlight:
            addHighlightToCurrentSelection(trigger: .keyboard(shortcut: "H"))
        case .note:
            onFreeTextShortcut?()
        case .dogear:
            onDogearShortcut?()
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
                self.registerAnnotationPresenceUndo(
                    [AnnotationUndoRecord(page: page, annotation: annotation)],
                    restoringPresence: true,
                    actionName: "Remove Highlight"
                )
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

    /// Gestures choose a custom scale, unlike scale changes caused by Fit layout.
    func beginUserMagnification() {
        endFitMode()
        autoScales = false
    }

    override func magnify(with event: NSEvent) {
        onUserInteraction?()
        beginUserMagnification()
        super.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        onUserInteraction?()
        beginUserMagnification()
        super.smartMagnify(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        onUserInteraction?()
        super.scrollWheel(with: event)
    }

    func applyZoomCommand(_ action: PDFZoomAction) {
        switch action {
        case .zoomIn:
            endFitMode()
            autoScales = false
            scaleFactor = clampedScaleFactor(scaleFactor * 1.2)
        case .zoomOut:
            endFitMode()
            autoScales = false
            scaleFactor = clampedScaleFactor(scaleFactor / 1.2)
        case .actualSize:
            endFitMode()
            autoScales = false
            scaleFactor = clampedScaleFactor(1)
        case .fitWidth:
            beginFitMode(.width)
        case .fitPage:
            beginFitMode(.page)
        case .custom(let percent):
            guard percent.isFinite else { return }
            endFitMode()
            autoScales = false
            let requestedScale = CGFloat(min(500, max(25, percent)) / 100)
            // PDFKit's defaults can vary with the installed page and prior Fit
            // mode. Ensure the supported custom range is actually reachable.
            minScaleFactor = min(minScaleFactor, requestedScale)
            maxScaleFactor = max(maxScaleFactor, requestedScale)
            scaleFactor = requestedScale
        }
    }

    var currentZoomState: PDFZoomState {
        switch activeFitMode {
        case .width:
            return .fitWidth
        case .page:
            return .fitPage
        case nil:
            return .custom(scaleFactor: Double(scaleFactor))
        }
    }

    func applyZoomState(_ zoomState: PDFZoomState) {
        switch zoomState.mode {
        case .fitWidth:
            applyZoomCommand(.fitWidth)
        case .fitPage:
            applyZoomCommand(.fitPage)
        case .custom:
            guard let storedScaleFactor = zoomState.scaleFactor,
                  storedScaleFactor.isFinite,
                  storedScaleFactor > 0 else {
                applyZoomCommand(.fitWidth)
                return
            }
            endFitMode()
            autoScales = false
            scaleFactor = clampedScaleFactor(CGFloat(storedScaleFactor))
        }
    }

    func updateActiveFitScaleIfNeeded() {
        guard let activeFitMode else {
            return
        }

        displaysPageBreaks = false
        pageBreakMargins = NSEdgeInsetsZero
        pageShadowsEnabled = false

        let fittedScaleFactor: CGFloat
        switch activeFitMode {
        case .page:
            fittedScaleFactor = scaleFactorForFitPage()
        case .width:
            fittedScaleFactor = scaleFactorForFitWidth()
        }
        let targetScaleFactor = min(fittedScaleFactor, maxScaleFactor)
        if minScaleFactor > targetScaleFactor {
            minScaleFactor = targetScaleFactor
        }
        guard abs(scaleFactor - targetScaleFactor) > 0.0001 else {
            return
        }

        autoScales = false
        scaleFactor = targetScaleFactor
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

        goToAnnotation(annotation, on: page)
        setCurrentSelection(nil, animate: false)
    }

    func goToAnnotation(_ annotation: PDFAnnotation, on page: PDFPage) {
        let pageBounds = page.bounds(for: displayBox)
        let annotationBounds = annotation.bounds.intersection(pageBounds)
        guard !annotationBounds.isEmpty else {
            go(to: page)
            return
        }

        let contextHeight = min(120, max(56, annotationBounds.height * 0.75))
        let destination = PDFDestination(
            page: page,
            at: NSPoint(
                x: max(pageBounds.minX, annotationBounds.minX),
                y: min(pageBounds.maxY, annotationBounds.maxY + contextHeight)
            )
        )
        go(to: destination)
    }

    func goToSearchResult(_ result: PDFSearchResult) {
        go(to: result.selection)
        setCurrentSelection(result.selection, animate: true)
    }

    func hideNativeNoteAnnotations() {
        document?.setNoteAnnotationsShouldDisplay(false)
    }

    func beginFreeTextEditing() {
        if let panel = freeTextEditorPanel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard let window, window.attachedSheet == nil, let document,
              canCommitFreeText(document),
              let page = currentPage ?? document.page(at: 0) else { return }
        guard let draft = onPrepareFreeTextDraft(document, page, defaultFreeTextBounds(on: page)),
              draft.isNew, draft.document === document, draft.page === page,
              draft.annotation.page == nil else { return }
        // Mac draws note text in its existing margin/reader overlay.
        draft.annotation.shouldDisplay = false
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = L10n.string("Add Free Text Note")
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView:
            FreeTextEditorSheet(draft: draft, onSave: { [weak self] values in
                self?.commitNewFreeText(draft, values: values) ?? false
            }, onDismiss: { [weak self, weak panel] in
                guard let panel else { return }
                panel.sheetParent?.endSheet(panel)
                panel.orderOut(nil)
                self?.freeTextEditorPanel = nil
                self?.window?.makeFirstResponder(self)
            }).environment(\.locale, AppLanguageStore.shared.locale))
        freeTextEditorPanel = panel
        // Attach to this reader's window, never NSApp.keyWindow (which may be
        // another workspace by the time a SwiftUI update delivers the request).
        window.beginSheet(panel)
    }

    @discardableResult
    func commitNewFreeText(_ draft: FreeTextEditDraft, values: FreeTextEditValues) -> Bool {
        guard draft.isNew, document === draft.document, draft.page.document === document,
              canCommitFreeText(draft.document),
              draft.annotation.page == nil,
              FreeTextAnnotationEditing.validationMessage(values, draft: draft) == nil else { return false }
        guard onCommitFreeText(draft, values) else { return false }
        refreshDisplay(for: draft.page)
        return true
    }

    @discardableResult
    func addHighlightToCurrentSelection(trigger: FeedbackTrigger) -> Bool {
        guard let document, let selection = currentSelection,
              selection.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            NSSound.beep()
            return false
        }

        guard onCommitHighlight(document, selection, trigger) else {
            NSSound.beep()
            return false
        }
        clearSelection()
        setNeedsDisplay(bounds)
        return true
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
        registerAnnotationPresenceUndo(
            [AnnotationUndoRecord(page: page, annotation: annotation)],
            restoringPresence: true,
            actionName: "Remove Highlight"
        )
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
            initialBounds: bounds,
            currentBounds: bounds,
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

    private func invalidateFreeTextDrag(
        on page: PDFPage,
        from oldBounds: NSRect,
        to newBounds: NSRect
    ) {
        let padding = max(2, 4 / max(scaleFactor, 0.01))
        let pageDirtyBounds = oldBounds.union(newBounds).insetBy(dx: -padding, dy: -padding)
        setNeedsDisplay(convert(pageDirtyBounds, from: page))
    }

    private func drawFreeTextNotes(on page: PDFPage, in context: CGContext) {
        for annotation in page.annotations where annotation.type == "FreeText" {
            drawFreeTextNote(annotation, in: context)
        }
    }

    private func drawFreeTextNote(_ annotation: PDFAnnotation, in context: CGContext) {
        let drawingBounds = freeTextDrag?.annotation === annotation
            ? freeTextDrag?.currentBounds : nil
        FreeTextAnnotationEditing.draw(annotation, bounds: drawingBounds, in: context)
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
        guard let document,
              let currentPage = currentPage ?? document.page(at: 0)
        else {
            return scaleFactor
        }

        let viewportWidth = documentView?.enclosingScrollView?.contentSize.width
            ?? bounds.width
        let contentWidth = pagesForCurrentLayout(in: document, currentPage: currentPage)
            .map(displaySize(for:))
            .reduce(0) { $0 + $1.width }
        guard viewportWidth > 0, contentWidth > 0 else {
            return scaleFactor
        }

        return viewportWidth / contentWidth
    }

    private func beginFitMode(_ mode: ActiveFitMode) {
        if standardDisplaysPageBreaks == nil {
            standardDisplaysPageBreaks = displaysPageBreaks
        }
        if standardPageBreakMargins == nil {
            standardPageBreakMargins = pageBreakMargins
        }
        if standardFitMinScaleFactor == nil {
            standardFitMinScaleFactor = minScaleFactor
        }
        if standardFitShadowsEnabled == nil {
            standardFitShadowsEnabled = pageShadowsEnabled
        }
        displaysPageBreaks = false
        pageBreakMargins = NSEdgeInsetsZero
        pageShadowsEnabled = false
        autoScales = false
        activeFitMode = mode
        updateActiveFitScaleIfNeeded()
    }

    private func endFitMode() {
        guard activeFitMode != nil else {
            return
        }

        activeFitMode = nil
        if let standardDisplaysPageBreaks {
            displaysPageBreaks = standardDisplaysPageBreaks
        }
        if let standardPageBreakMargins {
            pageBreakMargins = standardPageBreakMargins
        }
        if let standardFitMinScaleFactor {
            minScaleFactor = standardFitMinScaleFactor
        }
        if appliedNightMode == true {
            pageShadowsEnabled = false
        } else if let standardFitShadowsEnabled {
            pageShadowsEnabled = standardFitShadowsEnabled
        }

        self.standardDisplaysPageBreaks = nil
        self.standardPageBreakMargins = nil
        standardFitMinScaleFactor = nil
        standardFitShadowsEnabled = nil
    }

    private func scaleFactorForFitPage() -> CGFloat {
        guard let document,
              let currentPage = currentPage ?? document.page(at: 0)
        else {
            return scaleFactor
        }

        let viewportSize = documentView?.enclosingScrollView?.contentSize
            ?? bounds.size
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return scaleFactor
        }

        let pageSizes = pagesForCurrentLayout(in: document, currentPage: currentPage)
            .map(displaySize(for:))
        let contentWidth = pageSizes.reduce(0) { $0 + $1.width }
        let contentHeight = pageSizes.map(\.height).max() ?? 0
        guard contentWidth > 0, contentHeight > 0 else {
            return scaleFactor
        }

        return min(
            viewportSize.width / contentWidth,
            viewportSize.height / contentHeight
        )
    }

    private func pagesForCurrentLayout(
        in document: PDFDocument,
        currentPage: PDFPage
    ) -> [PDFPage] {
        guard displayMode == .twoUp || displayMode == .twoUpContinuous else {
            return [currentPage]
        }

        let pageIndex = document.index(for: currentPage)
        let firstIndex = max(0, pageIndex - pageIndex % 2)
        return [firstIndex, firstIndex + 1].compactMap(document.page(at:))
    }

    private func displaySize(for page: PDFPage) -> NSSize {
        let bounds = page.bounds(for: displayBox)
        let normalizedRotation = ((page.rotation % 360) + 360) % 360
        if normalizedRotation == 90 || normalizedRotation == 270 {
            return NSSize(width: bounds.height, height: bounds.width)
        }
        return bounds.size
    }

    private func defaultFreeTextBounds(on page: PDFPage) -> NSRect {
        let pageBounds = page.bounds(for: .cropBox)
        let size = NSSize(
            width: min(240, max(24, pageBounds.width)),
            height: min(120, max(24, pageBounds.height))
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

    private func registerAnnotationPresenceUndo(
        _ records: [AnnotationUndoRecord],
        restoringPresence: Bool,
        actionName: String
    ) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.applyAnnotationPresence(
                records,
                isPresent: restoringPresence,
                actionName: actionName
            )
        }
        undoManager?.setActionName(actionName)
    }

    private func applyAnnotationPresence(
        _ records: [AnnotationUndoRecord],
        isPresent: Bool,
        actionName: String
    ) {
        for record in records {
            if isPresent, record.annotation.page == nil {
                record.page.addAnnotation(record.annotation)
            } else if !isPresent, record.annotation.page === record.page {
                record.page.removeAnnotation(record.annotation)
            }
            refreshDisplay(for: record.page)
        }

        registerAnnotationPresenceUndo(
            records,
            restoringPresence: !isPresent,
            actionName: actionName
        )
        onUndoableAnnotationMutation?(actionName)
    }

    private func registerBoundsUndo(
        for annotation: PDFAnnotation,
        page: PDFPage,
        restoring bounds: NSRect,
        actionName: String
    ) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreAnnotationBounds(
                annotation,
                page: page,
                bounds: bounds,
                actionName: actionName
            )
        }
        undoManager?.setActionName(actionName)
    }

    private func restoreAnnotationBounds(
        _ annotation: PDFAnnotation,
        page: PDFPage,
        bounds: NSRect,
        actionName: String
    ) {
        guard annotation.page === page else { return }
        let previousBounds = annotation.bounds
        annotation.bounds = bounds
        registerBoundsUndo(
            for: annotation,
            page: page,
            restoring: previousBounds,
            actionName: actionName
        )
        refreshDisplay(for: page)
        onUndoableAnnotationMutation?(actionName)
    }

    private struct FreeTextDrag {
        let annotation: PDFAnnotation
        let page: PDFPage
        let initialBounds: NSRect
        var currentBounds: NSRect
        let pointerOffset: NSPoint
    }

    private struct AnnotationUndoRecord {
        let page: PDFPage
        let annotation: PDFAnnotation
    }

    private enum QuietLinkKind {
        case documentReference
        case citation
        case backReference
        case external
        case internalLink
    }

    deinit {
        stopObservingHighlightMenu()
    }
}
