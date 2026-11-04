#if os(iOS)
import PDFKit
import SwiftUI
import UIKit

/// A one-shot navigation request belongs to the exact installed PDF. Page
/// numbers alone cannot identify a target after the reader changes documents.
@MainActor
struct PDFReaderUIKitNavigation: Identifiable {
    let id = UUID()
    let document: PDFDocument
    let pageIndex: Int
    var bounds: CGRect? = nil
    var selection: PDFSelection? = nil
    var zoom: ResearchZoomCommand? = nil
    var pageOffset: PDFPageOffset? = nil
    private let receipt = PDFReaderUIKitNavigationReceipt()

    init(document: PDFDocument, pageIndex: Int, bounds: CGRect? = nil,
         selection: PDFSelection? = nil, zoom: ResearchZoomCommand? = nil, pageOffset: PDFPageOffset? = nil) {
        self.document = document; self.pageIndex = pageIndex
        self.bounds = bounds; self.selection = selection; self.zoom = zoom; self.pageOffset = pageOffset
    }

    /// Acceptance is not observable state. A retained owner can stop delivering
    /// this request before its deferred acknowledgement clears published state.
    var isAccepted: Bool { receipt.isAccepted }
    var isCancelled: Bool { receipt.isCancelled }
    func cancel() { receipt.isCancelled = true; receipt.isAccepted = true }
    fileprivate func markAccepted() { receipt.isAccepted = true }
}

@MainActor
private final class PDFReaderUIKitNavigationReceipt {
    var isAccepted = false
    var isCancelled = false
}

/// A native installation resumes reading state without creating a new command.
/// Subsequent SwiftUI updates must not restore this state over user scrolling.
@MainActor
struct PDFReaderUIKitReadingState {
    let document: PDFDocument
    let pageIndex: Int
    var selection: PDFSelection? = nil
    var zoom: ResearchZoomCommand = .fit
    var pageOffset: PDFPageOffset? = nil
}

@MainActor
struct PDFReaderUIKitOverlayTarget {
    let document: PDFDocument
    let page: PDFPage
    let bounds: CGRect
}

/// Coordinates are local to this PDFView/representable. The affine transform
/// maps a top-left-origin overlay measured in PDF points into that viewport.
/// Set an editor's bounds to the target PDF size, its center to the transformed
/// local midpoint, and its transform to the linear a/b/c/d terms only.
@MainActor
struct PDFReaderUIKitOverlayLayout: Equatable {
    let viewportFrame: CGRect
    let scale: CGFloat
    let pageToViewportTransform: CGAffineTransform
}

/// The same native reader displays an editing document or a detached research
/// snapshot. It reports user intent; its host owns every mutation and save.
@MainActor
struct PDFReaderUIKitView: UIViewRepresentable {
    let document: PDFDocument
    var navigation: PDFReaderUIKitNavigation? = nil
    var initialReadingState: PDFReaderUIKitReadingState? = nil
    var displayStyle: PDFReadingDisplayStyle = .continuous
    var inputMode: PDFReaderUIKitInputMode = .read
    var overlayTarget: PDFReaderUIKitOverlayTarget? = nil
    var isPresentationActive = true
    var onUserInteraction: () -> Void = {}
    var onPageChanged: (PDFDocument, Int) -> Void = { _, _ in }
    var onZoomChanged: (PDFDocument, Double, Bool) -> Void = { _, _, _ in }
    var onReadingPositionChanged: (PDFDocument, Int, PDFPageOffset) -> Void = { _, _, _ in }
    var onZoomModeChanged: (PDFDocument, PDFZoomState) -> Void = { _, _ in }
    var onNavigationAccepted: (PDFDocument, UUID) -> Void = { _, _ in }
    var onSelectionChanged: (PDFDocument, PDFSelection?, PDFTextSelectionSnapshot?) -> Void = { _, _, _ in }
    var onAnnotationTapped: (PDFDocument, PDFAnnotation) -> Void = { _, _ in }
    var onNotePlaced: (PDFDocument, PDFPage, CGRect) -> Void = { _, _, _ in }
    var onKeyboardCommand: (PDFDocument, PDFReaderUIKitKeyboardCommand) -> Void = { _, _ in }
    var onOpenURL: (URL) -> Void = { _ in }
    var onOverlayLayout: (PDFDocument, PDFPage, PDFReaderUIKitOverlayLayout?) -> Void = { _, _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let view = UIKitReaderPDFView()
        view.autoScales = true
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        // The public property is deprecated by current SDKs without a usable
        // replacement. Match the Mac reader's detector setting through KVC so
        // PDFKit does not add temporary address/link annotations to this view.
        view.setValue(false, forKey: "enableDataDetectors")
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onPageChanged = onPageChanged
        coordinator.onZoomChanged = onZoomChanged
        coordinator.onReadingPositionChanged = onReadingPositionChanged
        coordinator.onZoomModeChanged = onZoomModeChanged
        coordinator.onNavigationAccepted = onNavigationAccepted
        coordinator.onSelectionChanged = onSelectionChanged
        coordinator.onAnnotationTapped = onAnnotationTapped
        coordinator.onNotePlaced = onNotePlaced
        coordinator.onKeyboardCommand = onKeyboardCommand
        coordinator.onOpenURL = onOpenURL
        coordinator.onUserInteraction = onUserInteraction
        coordinator.onOverlayLayout = onOverlayLayout
        if view.displayMode != displayStyle.pdfDisplayMode { view.displayMode = displayStyle.pdfDisplayMode }
        if view.displaysAsBook != displayStyle.displaysAsBook { view.displaysAsBook = displayStyle.displaysAsBook }
        coordinator.configurePresentation(active: isPresentationActive)
        coordinator.install(document, in: view, initialReadingState: initialReadingState)
        coordinator.configureOverlay(overlayTarget)
        coordinator.configureInput(mode: inputMode)
        coordinator.cancelRevokedNavigation()
        if let navigation { coordinator.navigate(navigation, in: view) }
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.detach()
        view.delegate = nil
        view.document = nil
    }

    @MainActor
    final class Coordinator: NSObject, PDFViewDelegate, UIGestureRecognizerDelegate {
        var onPageChanged: (PDFDocument, Int) -> Void = { _, _ in }
        var onZoomChanged: (PDFDocument, Double, Bool) -> Void = { _, _, _ in }
        var onReadingPositionChanged: (PDFDocument, Int, PDFPageOffset) -> Void = { _, _, _ in }
        var onZoomModeChanged: (PDFDocument, PDFZoomState) -> Void = { _, _ in }
        var onNavigationAccepted: (PDFDocument, UUID) -> Void = { _, _ in }
        var onSelectionChanged: (PDFDocument, PDFSelection?, PDFTextSelectionSnapshot?) -> Void = { _, _, _ in }
        var onAnnotationTapped: (PDFDocument, PDFAnnotation) -> Void = { _, _ in }
        var onNotePlaced: (PDFDocument, PDFPage, CGRect) -> Void = { _, _, _ in }
        var onKeyboardCommand: (PDFDocument, PDFReaderUIKitKeyboardCommand) -> Void = { _, _ in }
        var onOpenURL: (URL) -> Void = { _ in }
        var onUserInteraction: () -> Void = {}
        var onOverlayLayout: (PDFDocument, PDFPage, PDFReaderUIKitOverlayLayout?) -> Void = { _, _, _ in }

        private weak var view: PDFView?
        private weak var installedDocument: PDFDocument?
        private var isPresentationActive = true
        private var observers: [NSObjectProtocol] = []
        private var annotationTap: UITapGestureRecognizer?
        private var observedInteractionGestures: [UIGestureRecognizer] = []
        let inputAdapter = PDFReaderUIKitInputAdapter()
        private var installationID = UUID()
        private var lastNavigationID: UUID?
        // Requested navigation and observed reading position have independent
        // histories. A command never pretends that its target has been reported.
        private var lastReportedPageIndex: Int?
        private var lastReportedSelection: PDFTextSelectionSnapshot?
        private var hasReportedSelection = false
        private var needsPageReport = false
        private var needsSelectionReport = false
        private var needsZoomReport = false
        private var lastReportedZoomPercent: Double?
        private var lastReportedZoomIsFit: Bool?
        private var lastReportedPosition: (page: Int, offset: PDFPageOffset)?
        private var lastReportedZoomMode: PDFZoomState?
        private var zoomMode: PDFZoomState.Mode = .fitPage
        private var isFittingWidth = false
        private var reportScheduled = false
        private var isReportingState = false
        private struct PendingLocation {
            let document: PDFDocument
            let page: PDFPage
            let pageIndex: Int
            let bounds: CGRect?
            let selection: PDFSelection?
            let zoom: ResearchZoomCommand?
            let pageOffset: PDFPageOffset?
            let request: PDFReaderUIKitNavigation?
        }
        private var pendingLocation: PendingLocation?
        private var locationRevision = UUID()
        private var isApplyingLocation = false
        private var locationVerificationScheduled = false
        private var locationAttempts = 0
        private var expectedViewportPoint: CGPoint?
        private var overlayTarget: PDFReaderUIKitOverlayTarget?
        private var overlayScheduled = false
        private var overlayRevision = UUID()
        private var lastOverlayLayout: PDFReaderUIKitOverlayLayout?
        private var hasReportedOverlay = false
        private var scrollObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]

        func attach(to view: PDFView) {
            detach()
            self.view = view
            view.delegate = self
            inputAdapter.onInteraction = { [weak self] in self?.reportUserInteraction() }
            inputAdapter.onPlaceNote = { [weak self] document, page, bounds in
                guard let self, self.isPresentationActive, self.installedDocument === document, self.view?.document === document else { return }
                self.onNotePlaced(document, page, bounds)
            }
            inputAdapter.onSelectionApplied = { [weak self] document in
                guard let self, self.isPresentationActive, self.installedDocument === document, self.view?.document === document else { return }
                (self.view as? UIKitReaderPDFView)?.requestReaderFocus(allowPDFSelectionResponder: true)
                self.synchronizeSelectionPresentation()
            }
            inputAdapter.attach(to: view)
            observe(.PDFViewPageChanged, object: view) { [weak self] in
                self?.scheduleReport(page: true)
                self?.scheduleOverlayReport()
            }
            observe(.PDFViewVisiblePagesChanged, object: view) { [weak self] in self?.scheduleOverlayReport() }
            observe(.PDFViewSelectionChanged, object: view) { [weak self] in
                self?.synchronizeSelectionPresentation()
                self?.scheduleReport(selection: true)
            }
            observe(.PDFViewDocumentChanged, object: view) { [weak self, weak view] in
                guard let self, let view, self.view === view else { return }
                (view as? UIKitReaderPDFView)?.clearSelectionPresentation()
            }
            observe(.PDFViewScaleChanged, object: view) { [weak self] in
                if let self, !self.isApplyingLocation, !self.isFittingWidth, self.pendingLocation == nil {
                    self.zoomMode = self.view?.autoScales == true ? .fitPage : .custom
                }
                self?.inputAdapter.cancelSelection(restoring: true)
                self?.scheduleReport(zoom: true)
                self?.scheduleOverlayReport()
            }
            observe(UIApplication.willResignActiveNotification, object: nil) { [weak self] in
                guard let self, let document = self.installedDocument, self.view?.document === document else { return }
                self.inputAdapter.cancelSelection(restoring: true)
                (self.view as? UIKitReaderPDFView)?.releaseReaderFocus()
            }
            observers.append(NotificationCenter.default.addObserver(forName: .dogearAnnotationsChanged, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let document = notification.object as? PDFDocument,
                          self.installedDocument === document, self.view?.document === document else { return }
                    self.view?.setNeedsDisplay()
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: .dogearDocumentStructureChanged, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let document = notification.object as? PDFDocument,
                          self.installedDocument === document, self.view?.document === document else { return }
                    self.inputAdapter.cancelSelection(restoring: false)
                    self.cancelPendingLocation(consumingRequest: true)
                    self.view?.clearSelection()
                    self.scheduleReport(page: true, selection: true)
                }
            })
            let tap = UITapGestureRecognizer(target: self, action: #selector(annotationTapped(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            tap.require(toFail: inputAdapter.selectionPan)
            view.addGestureRecognizer(tap)
            annotationTap = tap
            inputAdapter.annotationTapRecognizer = tap
            if let native = view as? UIKitReaderPDFView {
                native.onReaderKey = { [weak self, weak native] command in
                    guard let native else { return }
                    _ = self?.performKeyboardCommand(command, in: native)
                }
                native.onWindowDetached = { [weak self] in
                    guard let self, let document = self.installedDocument, self.view?.document === document else { return }
                    self.inputAdapter.cancelSelection(restoring: true)
                    self.scheduleOverlayReport()
                }
                native.onLayout = { [weak self] in
                    self?.inputAdapter.refreshNativeGestures()
                    self?.observeNativeInteractionGestures()
                    self?.applyPendingLocationIfReady()
                    self?.applyFitWidthIfNeeded()
                    self?.scheduleOverlayReport()
                    self?.scheduleReport(page: true, zoom: true)
                }
            }
            observeNativeInteractionGestures()
        }

        func install(_ document: PDFDocument, in view: PDFView,
                     initialReadingState: PDFReaderUIKitReadingState? = nil) {
            guard self.view === view else { return }
            guard installedDocument !== document || view.document !== document else { return }
            installationID = UUID()
            installedDocument = document
            lastNavigationID = nil
            lastReportedPageIndex = nil
            lastReportedZoomPercent = nil
            lastReportedZoomIsFit = nil
            lastReportedZoomMode = nil; lastReportedPosition = nil; zoomMode = .fitPage
            lastReportedSelection = nil
            hasReportedSelection = false
            needsPageReport = false
            needsSelectionReport = false
            needsZoomReport = false
            reportScheduled = false
            overlayRevision = UUID(); overlayScheduled = false; hasReportedOverlay = false; lastOverlayLayout = nil
            cancelPendingLocation()
            if let state = initialReadingState, state.document === document,
               let page = document.page(at: state.pageIndex), isValidZoom(state.zoom) {
                let selection = state.selection.flatMap {
                    PDFTextSelectionService.snapshot(of: $0, in: document) == nil ? nil : ($0.copy() as? PDFSelection)
                }
                pendingLocation = PendingLocation(document: document, page: page, pageIndex: state.pageIndex,
                    bounds: nil, selection: selection, zoom: state.zoom, pageOffset: state.pageOffset, request: nil)
            }
            (view as? UIKitReaderPDFView)?.clearSelectionPresentation()
            view.clearSelection()
            view.document = document
            inputAdapter.install(document)
            applyPendingLocationIfReady()
            synchronizeSelectionPresentation()
            scheduleReport(page: true, selection: true, zoom: true)
            scheduleOverlayReport()
        }

        func configureInput(mode: PDFReaderUIKitInputMode) {
            inputAdapter.configure(mode: mode)
            if !isPresentationActive { disableReaderInputRecognizers() }
        }

        func configurePresentation(active: Bool) {
            let changed = isPresentationActive != active
            isPresentationActive = active
            view?.isUserInteractionEnabled = active
            if !active {
                inputAdapter.cancelSelection(restoring: true)
                disableReaderInputRecognizers()
            } else if changed {
                inputAdapter.configure(mode: inputAdapter.mode)
            }
            if let native = view as? UIKitReaderPDFView {
                native.isReaderInputActive = active
                if !active { native.releaseReaderFocus() }
            }
        }

        private func disableReaderInputRecognizers() {
            for gesture in [inputAdapter.selectionPan, inputAdapter.selectionTap, inputAdapter.noteTap,
                            inputAdapter.selectionDismissTap].compactMap({ $0 }) {
                gesture.isEnabled = false
            }
        }

        @discardableResult
        func navigate(_ request: PDFReaderUIKitNavigation, in view: PDFView) -> Bool {
            guard !request.isCancelled, self.view === view, request.id != lastNavigationID,
                  installedDocument === request.document, view.document === request.document,
                  let page = request.document.page(at: request.pageIndex) else { return false }
            if let selection = request.selection,
               PDFTextSelectionService.snapshot(of: selection, in: request.document) == nil { return false }
            if let zoom = request.zoom, !isValidZoom(zoom) { return false }
            let effectiveZoom = request.zoom ?? pendingLocation?.zoom
            lastNavigationID = request.id
            cancelPendingLocation()
            inputAdapter.cancelSelection(restoring: true)
            pendingLocation = PendingLocation(document: request.document, page: page, pageIndex: request.pageIndex,
                bounds: request.bounds, selection: request.selection, zoom: effectiveZoom, pageOffset: request.pageOffset, request: request)
            applyPendingLocationIfReady()
            scheduleReport(page: true, selection: true, zoom: true)
            return true
        }

        private func completePendingLocation(_ location: PendingLocation) {
            pendingLocation = nil
            location.request?.markAccepted()
            synchronizeSelectionPresentation()
            scheduleReport(page: true, selection: true, zoom: true)
            scheduleOverlayReport()
            guard let request = location.request else { return }
            acknowledgeNavigation(request)
        }

        private func acknowledgeNavigation(_ request: PDFReaderUIKitNavigation) {
            let installation = installationID
            let requestID = request.id
            let document = request.document
            // Native acceptance must not publish during updateUIView. The
            // receipt already prevents a retained owner replaying this request
            // if this installation disappears before acknowledgement delivery.
            DispatchQueue.main.async { [weak self, weak document] in
                guard let self, let document, self.installationID == installation,
                      self.installedDocument === document, self.view?.document === document,
                      self.lastNavigationID == requestID else { return }
                self.onNavigationAccepted(document, requestID)
            }
        }

        private func cancelPendingLocation(consumingRequest: Bool = false) {
            let request = pendingLocation?.request
            pendingLocation = nil; locationRevision = UUID(); locationVerificationScheduled = false; locationAttempts = 0
            expectedViewportPoint = nil
            if consumingRequest, let request {
                // A newer native reading gesture consumes a queued command;
                // acknowledgement clears its owner without publishing its page.
                request.markAccepted(); acknowledgeNavigation(request)
                scheduleReport(page: true, selection: true, zoom: true)
            }
        }

        func cancelRevokedNavigation() {
            if pendingLocation?.request?.isCancelled == true { cancelPendingLocation() }
        }

        private func applyPendingLocationIfReady() {
            cancelRevokedNavigation()
            guard !isApplyingLocation, !locationVerificationScheduled, let location = pendingLocation, let view,
                  installedDocument === location.document, view.document === location.document,
                  location.page.document === location.document, location.document.index(for: location.page) == location.pageIndex,
                  view.bounds.width > 0, view.bounds.height > 0,
                  !(view is UIKitReaderPDFView) || view.window != nil else { return }
            isApplyingLocation = true
            view.layoutDocumentView()
            applyLocation(page: location.page, bounds: location.bounds,
                selection: location.request == nil ? nil : location.selection, zoom: location.zoom,
                pageOffset: location.pageOffset, in: view)
            view.setCurrentSelection(location.selection, animate: false)
            isApplyingLocation = false
            if !(view is UIKitReaderPDFView) { completePendingLocation(location); return }
            locationVerificationScheduled = true; locationAttempts += 1
            let revision = locationRevision, installation = installationID
            let bounds = view.bounds, scale = view.scaleFactor
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.locationRevision == revision, self.installationID == installation,
                      self.view === view, self.installedDocument === location.document, view.document === location.document else { return }
                self.locationVerificationScheduled = false
                self.cancelRevokedNavigation()
                guard self.pendingLocation != nil, view.window != nil else { return }
                let destination = location.bounds == nil && location.request != nil
                    ? (location.selection?.pages.first ?? location.page) : location.page
                let point = view.convert(CGPoint(x: view.bounds.minX, y: view.bounds.minY), to: location.page)
                let offsetSettled = self.expectedViewportPoint.map { abs($0.x - point.x) < 0.5 && abs($0.y - point.y) < 0.5 } ?? true
                if view.bounds == bounds, view.scaleFactor == scale, view.currentPage === destination, offsetSettled {
                    self.completePendingLocation(location)
                } else if self.locationAttempts < 4 {
                    self.applyPendingLocationIfReady()
                }
            }
        }

        private func isValidZoom(_ zoom: ResearchZoomCommand) -> Bool {
            if case .percent(let percent) = zoom { return percent.isFinite && percent > 0 }
            return true
        }

        private func applyLocation(page: PDFPage, bounds: CGRect?, selection: PDFSelection?,
                                   zoom: ResearchZoomCommand?, pageOffset: PDFPageOffset?, in view: PDFView) {
            if let zoom {
                switch zoom {
                case .fit:
                    zoomMode = .fitPage; view.autoScales = true
                case .fitWidth:
                    zoomMode = .fitWidth; fitWidth(page: page, in: view)
                case .percent(let percent):
                    zoomMode = .custom; view.autoScales = false
                    view.scaleFactor = min(view.maxScaleFactor, max(view.minScaleFactor, CGFloat(percent) / 100))
                }
                view.layoutDocumentView()
            }
            if let offset = pageOffset, offset.x.isFinite, offset.y.isFinite {
                restoreViewportPoint(CGPoint(x: offset.x, y: offset.y), on: page, in: view)
            } else if let bounds, !bounds.isEmpty, !bounds.isNull, !bounds.isInfinite {
                let target = bounds.intersection(page.bounds(for: view.displayBox))
                if !target.isEmpty { view.go(to: target, on: page) }
                else { view.go(to: page) }
            } else if let selection {
                view.go(to: selection)
            } else {
                view.go(to: page)
            }
        }

        /// UIKit PDFKit's currentDestination/go(to:) are not inverse viewport
        /// operations (including a viewport-height displacement on rotated pages).
        /// Anchor the actual top-left through public coordinate conversion and
        /// the native scroll view, without changing PDFKit delegates/gestures.
        private func restoreViewportPoint(_ point: CGPoint, on page: PDFPage, in view: PDFView) {
            if locationAttempts == 0 { view.go(to: page) }
            view.layoutDocumentView()
            var ancestor = view.documentView?.superview
            while let native = ancestor {
                if let scroll = native as? UIScrollView {
                    let target = view.convert(point, from: page)
                    let inset = scroll.adjustedContentInset
                    let proposed = CGPoint(x: scroll.contentOffset.x + target.x - view.bounds.minX,
                                           y: scroll.contentOffset.y + target.y - view.bounds.minY)
                    let bounded = CGPoint(
                        x: min(max(-inset.left, proposed.x), max(-inset.left, scroll.contentSize.width - scroll.bounds.width + inset.right)),
                        y: min(max(-inset.top, proposed.y), max(-inset.top, scroll.contentSize.height - scroll.bounds.height + inset.bottom)))
                    expectedViewportPoint = view.convert(CGPoint(x: target.x + bounded.x - proposed.x,
                        y: target.y + bounded.y - proposed.y), to: page)
                    scroll.setContentOffset(bounded, animated: false)
                    return
                }
                ancestor = native.superview
            }
            let destination = PDFDestination(page: page, at: point)
            destination.zoom = kPDFDestinationUnspecifiedValue
            view.go(to: destination)
        }

        private func fitWidth(page: PDFPage, in view: PDFView) {
            guard !isFittingWidth, view.scaleFactor > 0, view.bounds.width > 0 else { return }
            let pageWidth = view.convert(page.bounds(for: view.displayBox), from: page).width / view.scaleFactor
            let margins = view.displaysPageBreaks ? view.pageBreakMargins.left + view.pageBreakMargins.right : 0
            let available = view.bounds.width - margins
            guard pageWidth.isFinite, pageWidth > 0, available > 0 else { return }
            let factor = min(view.maxScaleFactor, max(view.minScaleFactor, available / pageWidth))
            isFittingWidth = true
            view.autoScales = false
            if abs(view.scaleFactor - factor) > 0.0001 { view.scaleFactor = factor }
            isFittingWidth = false
        }

        private func applyFitWidthIfNeeded() {
            guard zoomMode == .fitWidth, pendingLocation == nil, !isApplyingLocation,
                  let view, view.window != nil, let page = view.currentPage else { return }
            fitWidth(page: page, in: view)
        }

        func detach() {
            // Deliver the final native position before invalidating this installation.
            if let document = installedDocument {
                needsPageReport = true; needsZoomReport = true
                reportPendingState(for: document, installation: installationID)
            }
            inputAdapter.detach()
            cancelPendingLocation()
            configureOverlay(nil)
            scrollObservations.removeAll()
            installationID = UUID()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            if let annotationTap { view?.removeGestureRecognizer(annotationTap) }
            for gesture in observedInteractionGestures { gesture.removeTarget(self, action: #selector(userInteracted(_:))) }
            observedInteractionGestures.removeAll()
            (view as? UIKitReaderPDFView)?.onLayout = nil
            if let native = view as? UIKitReaderPDFView {
                native.onReaderKey = nil
                native.onWindowDetached = nil
                native.releaseReaderFocus()
                native.clearSelectionPresentation()
            }
            if view?.delegate === self { view?.delegate = nil }
            annotationTap = nil
            view = nil
            installedDocument = nil
            reportScheduled = false
            needsPageReport = false
            needsSelectionReport = false
            needsZoomReport = false
        }

        private func observe(_ name: Notification.Name, object: AnyObject?, action: @escaping @MainActor () -> Void) {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
                MainActor.assumeIsolated { action() }
            })
        }

        private func synchronizeSelectionPresentation() {
            guard let view = view as? UIKitReaderPDFView, let document = installedDocument,
                  view.document === document else { return }
            view.synchronizeSelectionPresentation(in: document)
        }

        func configureOverlay(_ target: PDFReaderUIKitOverlayTarget?) {
            if let old = overlayTarget, let target,
               old.document === target.document, old.page === target.page, old.bounds == target.bounds { return }
            if overlayTarget == nil && target == nil { return }
            let previous = overlayTarget
            overlayTarget = target; overlayRevision = UUID(); overlayScheduled = false
            lastOverlayLayout = nil; hasReportedOverlay = false
            let revision = overlayRevision
            if let previous, target == nil || previous.document !== target?.document || previous.page !== target?.page {
                let callback = onOverlayLayout
                DispatchQueue.main.async { [weak self] in
                    guard self?.overlayRevision == revision else { return }
                    callback(previous.document, previous.page, nil)
                }
            }
            scheduleOverlayReport()
        }

        private func scheduleOverlayReport() {
            guard overlayTarget != nil, !overlayScheduled else { return }
            overlayScheduled = true
            let revision = overlayRevision, installation = installationID
            DispatchQueue.main.async { [weak self] in
                guard let self, self.overlayRevision == revision, self.installationID == installation,
                      let target = self.overlayTarget else { return }
                self.overlayScheduled = false
                let layout = self.overlayLayout(for: target)
                guard !self.hasReportedOverlay || layout != self.lastOverlayLayout else { return }
                self.hasReportedOverlay = true; self.lastOverlayLayout = layout
                self.onOverlayLayout(target.document, target.page, layout)
            }
        }

        private func overlayLayout(for target: PDFReaderUIKitOverlayTarget) -> PDFReaderUIKitOverlayLayout? {
            guard let view, view.window != nil, pendingLocation == nil,
                  installedDocument === target.document, view.document === target.document,
                  target.page.document === target.document, target.document.index(for: target.page) != NSNotFound,
                  !target.bounds.isEmpty, !target.bounds.isNull, !target.bounds.isInfinite else { return nil }
            let frame = view.convert(target.bounds, from: target.page)
            guard !frame.isEmpty, !frame.isNull, !frame.isInfinite, frame.intersects(view.bounds),
                  view.scaleFactor.isFinite, view.scaleFactor > 0 else { return nil }
            let anchor = CGPoint(x: target.bounds.minX, y: target.bounds.maxY)
            let origin = view.convert(anchor, from: target.page)
            let x = view.convert(CGPoint(x: anchor.x + 1, y: anchor.y), from: target.page)
            let y = view.convert(CGPoint(x: anchor.x, y: anchor.y - 1), from: target.page)
            let transform = CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y,
                c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y)
            return .init(viewportFrame: frame, scale: view.scaleFactor, pageToViewportTransform: transform)
        }

        private func scheduleReport(page: Bool = false, selection: Bool = false, zoom: Bool = false) {
            guard let document = installedDocument, view?.document === document else { return }
            needsPageReport = needsPageReport || page
            needsSelectionReport = needsSelectionReport || selection
            needsZoomReport = needsZoomReport || zoom
            guard !reportScheduled else { return }
            reportScheduled = true
            let installation = installationID
            // Native notifications can arrive during updateUIView. Publish only
            // after that transaction, and reject events from an old installation.
            DispatchQueue.main.async { [weak self, weak document] in
                guard let self, let document, self.installationID == installation,
                      self.installedDocument === document, self.view?.document === document else { return }
                self.reportScheduled = false
                self.applyPendingLocationIfReady()
                self.reportPendingState(for: document, installation: installation)
            }
        }

        private func reportPendingState(for document: PDFDocument, installation: UUID) {
            guard !isReportingState else { return }
            isReportingState = true
            defer { isReportingState = false }
            guard pendingLocation == nil, installationID == installation, let view, view.document === document else { return }
            let positionReady = !(view is UIKitReaderPDFView) || (view.window != nil && view.bounds.width > 0 && view.bounds.height > 0)
            if needsPageReport && positionReady {
                needsPageReport = false
                if let page = view.currentPage, page.document === document {
                    let index = document.index(for: page)
                    if index != NSNotFound, index != lastReportedPageIndex {
                        lastReportedPageIndex = index
                        onPageChanged(document, index)
                    }
                }
                guard installationID == installation, installedDocument === document, self.view === view else { return }
                if let page = view.currentPage, page.document === document {
                    let index = document.index(for: page)
                    let point = view.convert(CGPoint(x: view.bounds.minX, y: view.bounds.minY), to: page)
                    let offset = PDFPageOffset(x: point.x, y: point.y)
                    if index != NSNotFound, offset.x.isFinite, offset.y.isFinite,
                       lastReportedPosition?.page != index || lastReportedPosition?.offset != offset {
                        lastReportedPosition = (index, offset)
                        onReadingPositionChanged(document, index, offset)
                    }
                }
            }
            // The page callback may have caused a document switch or dismantle.
            guard installationID == installation, installedDocument === document,
                  self.view === view, view.document === document else { return }
            if needsZoomReport && positionReady {
                needsZoomReport = false
                let percent = Double(view.scaleFactor) * 100
                let isFit = zoomMode != .custom
                let state: PDFZoomState = zoomMode == .fitWidth ? .fitWidth : (view.autoScales ? .fitPage : .custom(scaleFactor: Double(view.scaleFactor)))
                if state != lastReportedZoomMode {
                    lastReportedZoomMode = state
                    onZoomModeChanged(document, state)
                }
                guard installationID == installation, installedDocument === document, self.view === view else { return }
                if percent.isFinite, percent > 0,
                   (lastReportedZoomPercent.map({ abs($0 - percent) > 0.0001 }) ?? true)
                    || lastReportedZoomIsFit != isFit {
                    lastReportedZoomPercent = percent
                    lastReportedZoomIsFit = isFit
                    onZoomChanged(document, percent, isFit)
                }
            }
            guard installationID == installation, installedDocument === document,
                  self.view === view, view.document === document else { return }
            if needsSelectionReport {
                needsSelectionReport = false
                let selection = view.currentSelection?.copy() as? PDFSelection
                let snapshot = selection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) }
                if !hasReportedSelection || snapshot != lastReportedSelection {
                    hasReportedSelection = true
                    lastReportedSelection = snapshot
                    onSelectionChanged(document, snapshot == nil ? nil : selection, snapshot)
                }
            }
        }

        @objc private func annotationTapped(_ gesture: UITapGestureRecognizer) {
            guard gesture === annotationTap, gesture.state == .ended, let view else { return }
            _ = activateAnnotation(at: gesture.location(in: view))
        }

        /// Shares the recognizer's exact-document validation with real PDFKit
        /// fixtures; no fixture constructs or pretends to deliver a UITouch.
        @discardableResult
        func activateAnnotation(at point: CGPoint) -> Bool {
            guard isPresentationActive, point.x.isFinite, point.y.isFinite, inputAdapter.mode != .addNote,
                  let view, let document = installedDocument, view.document === document else { return false }
            let installation = installationID
            inputAdapter.cancelSelection(restoring: true)
            guard reportUserInteraction(), installationID == installation,
                  installedDocument === document, self.view === view, view.document === document,
                  inputAdapter.mode != .addNote,
                  let page = view.page(for: point, nearest: false),
                  page.document === document, document.index(for: page) != NSNotFound,
                  let annotation = page.annotation(at: view.convert(point, to: page)),
                  annotation.page === page, annotation.shouldDisplay,
                  page.annotations.contains(where: { $0 === annotation }),
                  ["Highlight", "Text", "FreeText"].contains(annotation.type ?? "") else { return false }
            onAnnotationTapped(document, annotation)
            return true
        }

        @discardableResult
        private func reportUserInteraction() -> Bool {
            guard isPresentationActive, let view, let document = installedDocument,
                  view.document === document else { return false }
            let installation = installationID
            cancelPendingLocation(consumingRequest: true)
            onUserInteraction()
            guard installationID == installation, installedDocument === document,
                  self.view === view, view.document === document else { return false }
            (view as? UIKitReaderPDFView)?.requestReaderFocus()
            return true
        }

        @discardableResult
        func performKeyboardCommand(_ command: PDFReaderUIKitKeyboardCommand, in sender: PDFView) -> Bool {
            guard isPresentationActive, sender === view, (sender as? UIKitReaderPDFView)?.hasReaderKeyboardFocus == true,
                  sender.window?.isKeyWindow == true,
                  let document = installedDocument,
                  sender.document === document else { return false }
            let installation = installationID
            if command == .cancel { inputAdapter.cancelSelection(restoring: true) }
            guard reportUserInteraction(), installationID == installation, installedDocument === document,
                  self.view === sender, sender.document === document,
                  (sender as? UIKitReaderPDFView)?.hasReaderKeyboardFocus == true,
                  sender.window?.isKeyWindow == true else { return false }
            onKeyboardCommand(document, command)
            return true
        }

        private func observeNativeInteractionGestures() {
            guard let view else { return }
            var current: [UIGestureRecognizer] = []
            func visit(_ native: UIView) {
                for gesture in native.gestureRecognizers ?? [] where gesture !== annotationTap
                    && gesture !== inputAdapter.selectionPan && gesture !== inputAdapter.selectionTap
                    && gesture !== inputAdapter.noteTap && gesture !== inputAdapter.selectionDismissTap {
                    guard gesture is UIPanGestureRecognizer || gesture is UIPinchGestureRecognizer
                            || gesture is UILongPressGestureRecognizer else { continue }
                    current.append(gesture)
                }
                native.subviews.forEach(visit)
            }
            visit(view)
            let scrolls = current.compactMap { $0.view as? UIScrollView }
            let scrollIDs = Set(scrolls.map(ObjectIdentifier.init))
            for id in scrollObservations.keys where !scrollIDs.contains(id) { scrollObservations[id] = nil }
            for scroll in scrolls where scrollObservations[ObjectIdentifier(scroll)] == nil {
                scrollObservations[ObjectIdentifier(scroll)] = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        self?.scheduleOverlayReport()
                        self?.scheduleReport(page: true, zoom: true)
                    }
                }
            }
            let currentIDs = Set(current.map(ObjectIdentifier.init))
            let previousIDs = Set(observedInteractionGestures.map(ObjectIdentifier.init))
            for gesture in observedInteractionGestures where !currentIDs.contains(ObjectIdentifier(gesture)) {
                gesture.removeTarget(self, action: #selector(userInteracted(_:)))
            }
            for gesture in current where !previousIDs.contains(ObjectIdentifier(gesture)) {
                // Add a target to the existing recognizer; its delegate,
                // cancellation and failure relationships remain PDFKit's.
                gesture.addTarget(self, action: #selector(userInteracted(_:)))
            }
            observedInteractionGestures = current
        }

        @objc private func userInteracted(_ gesture: UIGestureRecognizer) {
            scheduleOverlayReport()
            guard gesture.state == .began else { return }
            if gesture is UIPinchGestureRecognizer {
                zoomMode = .custom; view?.autoScales = false
            }
            _ = reportUserInteraction()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // PDFKit owns touch selection, panning and zooming. Annotation intent
            // must never cancel the recognizers that implement those operations.
            true
        }

        func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            guard inputAdapter.mode == .read, sender === view,
                  let document = installedDocument, sender.document === document else { return }
            let installation = installationID
            guard reportUserInteraction(), installationID == installation,
                  inputAdapter.mode == .read, sender === view,
                  installedDocument === document, sender.document === document else { return }
            onOpenURL(url)
        }
    }
}

@MainActor
final class UIKitReaderPDFView: PDFView {
    var isReaderInputActive = true
    var onLayout: (() -> Void)?
    var onReaderKey: ((PDFReaderUIKitKeyboardCommand) -> Void)?
    var onWindowDetached: (() -> Void)?
    private let keyboardFocusView = PDFReaderUIKitKeyboardFocusView(frame: .zero)
    private var isSynchronizingSelectionPresentation = false

    /// PDFKit can hide its active-selection drawing when keyboard focus moves
    /// to the Reader's command responder. Its public highlightedSelections
    /// channel renders a separate colored copy without changing the selection
    /// that native Copy and the document Store consume. This reader exclusively
    /// owns that per-view presentation channel.
    func synchronizeSelectionPresentation(in expectedDocument: PDFDocument) {
        guard document === expectedDocument, !isSynchronizingSelectionPresentation else { return }
        isSynchronizingSelectionPresentation = true
        defer { isSynchronizingSelectionPresentation = false }
        guard let selection = currentSelection,
              PDFTextSelectionService.snapshot(of: selection, in: expectedDocument) != nil,
              let displaySelection = selection.copy() as? PDFSelection else {
            clearSelectionPresentation(); return
        }
        displaySelection.color = UIColor.systemBlue.withAlphaComponent(0.28)
        highlightedSelections = [displaySelection]
    }

    func clearSelectionPresentation() { highlightedSelections = nil }

    /// PDFKit may focus its text-selection responder rather than PDFView.
    /// This public UIView gives the Reader a concrete, verifiable keyboard
    /// responder without relying on PDFKit's private view classes.
    var hasReaderKeyboardFocus: Bool {
        isReaderInputActive && window?.isKeyWindow == true && readerKeyboardResponder != nil
    }

    var readerKeyboardResponder: UIResponder? {
        if isFirstResponder { return self }
        return keyboardFocusView.isFirstResponder ? keyboardFocusView : nil
    }

    override var canBecomeFirstResponder: Bool { true }

    /// Becoming first responder is tied to an explicit native reader gesture,
    /// never representable updates. Text fields retain typing, Undo and IME.
    @discardableResult
    func requestReaderFocus(allowPDFSelectionResponder: Bool = false) -> Bool {
        guard isReaderInputActive, let window, window.isKeyWindow else { return false }
        if let responder = firstResponder(in: window), responder !== self, let input = responder as? any UITextInput {
            // A successful explicit page-text selection can take over PDFKit's
            // own nonediting selection responder. Native editors and any marked
            // text retain focus, including editors inside the PDF's subtree.
            guard input.markedTextRange == nil, responder.isDescendant(of: self), allowPDFSelectionResponder,
                  !(responder is UITextField), (responder as? UITextView)?.isEditable != true else { return false }
        }
        if hasReaderKeyboardFocus { return true }
        if keyboardFocusView.superview !== self {
            keyboardFocusView.isAccessibilityElement = false
            addSubview(keyboardFocusView)
        }
        _ = keyboardFocusView.acquireFocus(in: self)
        return hasReaderKeyboardFocus
    }

    func releaseReaderFocus() {
        keyboardFocusView.invalidateAcquisition()
        if keyboardFocusView.isFirstResponder { keyboardFocusView.resignFirstResponder() }
        if isFirstResponder { resignFirstResponder() }
    }

    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews {
            if let responder = firstResponder(in: child) { return responder }
        }
        return nil
    }

    override var keyCommands: [UIKeyCommand]? {
        guard hasReaderKeyboardFocus, onReaderKey != nil else { return super.keyCommands }
        let commands = Self.readerKeys.map { input, modifiers, _ in
            let key = UIKeyCommand(input: input, modifierFlags: modifiers, action: #selector(readerKeyPressed(_:)))
            key.wantsPriorityOverSystemBehavior = true
            return key
        }
        // Keep native PDFKit copy and other standard responder actions on the
        // same chain. The zero-frame focus view's next responder is this PDFView.
        return commands + (super.keyCommands ?? [])
    }

    private static let readerKeys: [(String, UIKeyModifierFlags, PDFReaderUIKitKeyboardCommand)] = [
        ("h", [], .addHighlight), ("z", .command, .undo), ("z", [.command, .shift], .redo),
        (UIKeyCommand.inputLeftArrow, [], .previousPage), (UIKeyCommand.inputRightArrow, [], .nextPage),
        ("f", .command, .find), ("g", .command, .nextMatch), ("g", [.command, .shift], .previousMatch),
        (UIKeyCommand.inputEscape, [], .cancel),
        ("s", [.command, .shift], .selectText), ("n", [.command, .shift], .placeNote)
    ]

    @objc private func readerKeyPressed(_ key: UIKeyCommand) {
        guard hasReaderKeyboardFocus, let command = Self.readerKeys.first(where: {
            $0.0 == key.input && $0.1 == key.modifierFlags
        })?.2 else { return }
        onReaderKey?(command)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            onWindowDetached?(); releaseReaderFocus(); clearSelectionPresentation()
        } else { onLayout?() }
    }
}

@MainActor
private final class PDFReaderUIKitKeyboardFocusView: UIView {
    private var isAcquisitionAuthorized = false

    private var hasActiveReaderHost: Bool {
        guard let reader = superview as? UIKitReaderPDFView, reader.isReaderInputActive,
              reader.document != nil, let window, window.isKeyWindow,
              reader.window === window else { return false }
        return true
    }

    override var canBecomeFirstResponder: Bool {
        hasActiveReaderHost && (isFirstResponder || isAcquisitionAuthorized)
    }

    /// A layout or responder-chain restoration cannot reacquire an old Reader
    /// proxy after another native editor received focus. Only the synchronous
    /// request that already passed the Reader's input guards may acquire it.
    func acquireFocus(in reader: UIKitReaderPDFView) -> Bool {
        guard superview === reader, hasActiveReaderHost, let document = reader.document,
              let expectedWindow = window else { return false }
        isAcquisitionAuthorized = true
        defer { isAcquisitionAuthorized = false }
        let acquired = becomeFirstResponder()
        guard reader.document === document, reader.window === expectedWindow,
              window === expectedWindow, hasActiveReaderHost else {
            if isFirstResponder { resignFirstResponder() }
            return false
        }
        return acquired && isFirstResponder
    }

    func invalidateAcquisition() { isAcquisitionAuthorized = false }

    override func becomeFirstResponder() -> Bool {
        #if DEBUG
        let ownerClass = window.flatMap { firstResponder(in: $0) }
            .map { String(reflecting: type(of: $0)) } ?? "none"
        #endif
        let permitted = isAcquisitionAuthorized && hasActiveReaderHost
        let result = permitted && super.becomeFirstResponder()
        #if DEBUG
        NSLog("DogearReaderFocus %@", "proxy-become explicitPermit=\(isAcquisitionAuthorized) hostValid=\(hasActiveReaderHost) currentOwnerClass=\(ownerClass) active=\((superview as? UIKitReaderPDFView)?.isReaderInputActive == true) key=\(window?.isKeyWindow == true) result=\(result)")
        #endif
        return result
    }

    #if DEBUG
    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews {
            if let responder = firstResponder(in: child) { return responder }
        }
        return nil
    }
    #endif

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil { invalidateAcquisition() }
        if newWindow == nil, isFirstResponder { resignFirstResponder() }
        super.willMove(toWindow: newWindow)
    }
}
#endif
