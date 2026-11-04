#if os(iOS)
import PDFKit
import SwiftUI
import UIKit

/// The capture's source catalog and native reader identity are frozen before
/// presenting. A detached PDF supplies pixels; the editable PDF is never drawn
/// or modified by the capture surface.
@MainActor
struct IPadResearchRegionCaptureRequest: Identifiable {
    let id = UUID()
    let sessionID: UUID
    let source: ResearchSourceSnapshot
    let document: PDFDocument
    let pageIndex: Int
    let editorDocument: PDFDocument
    private let snapshotVersion: String

    init(sessionID: UUID, source: ResearchSourceSnapshot, document: PDFDocument,
         pageIndex: Int, editorDocument: PDFDocument) {
        self.sessionID = sessionID
        self.source = source
        self.document = document
        self.pageIndex = pageIndex
        self.editorDocument = editorDocument
        snapshotVersion = DocumentAccessCoordinator.contentVersion(of: document)
    }

    func validate(library: LibraryStore, storage: ResearchStore, store: PDFDocumentStore,
                  access: DocumentAccessCoordinator? = nil) throws {
        guard store.document === editorDocument, store.currentPageIndex == pageIndex,
              library.file(for: store.selectedPDFURL)?.id == source.fileID,
              document.page(at: pageIndex) != nil,
              snapshotVersion == DocumentAccessCoordinator.contentVersion(of: document),
              let session = storage.session(id: sessionID),
              let file = library.allFiles.first(where: { $0.id == source.fileID }) else {
            throw ResearchRuntimeError.sourceChanged(source.displayName)
        }
        let members = session.sourceSelection.groupID.map { library.files(in: $0).map(\.id) } ?? []
        guard session.sourceSelection.expandedFileIDs(groupMembers: members).contains(file.id) else {
            throw ResearchRuntimeError.sourceOutsideScope
        }
        let latest = try (access ?? .shared).readSnapshot(fileID: file.id, originalURL: library.resolvedURL(for: file),
            workingCopyURL: file.workingCopyURL)
        guard latest.contentVersion == source.fingerprint,
              DocumentAccessCoordinator.contentVersion(of: latest.document) == snapshotVersion else {
            throw ResearchRuntimeError.sourceChanged(source.displayName)
        }
    }

    func add(region: CGRect, library: LibraryStore, storage: ResearchStore, store: PDFDocumentStore,
             access: DocumentAccessCoordinator? = nil) throws {
        try validate(library: library, storage: storage, store: store, access: access)
        guard let page = document.page(at: pageIndex), !region.isNull, !region.isInfinite,
              region.width >= 1, region.height >= 1, page.bounds(for: .cropBox).contains(region) else {
            throw ResearchImageError.invalidRegion
        }
        let image = try ResearchImagePipeline.renderRegion(page: page, rect: region)
        let anchor = ResearchPageAnchor(pageIndex: pageIndex, x: region.minX, y: region.minY,
            width: region.width, height: region.height)
        let evidence = ResearchEvidence(source: source, kind: .image, anchor: anchor,
            excerpt: L10n.string("Page region") + " \(pageIndex + 1)")
        try ResearchImagePipeline.importImage(data: image,
            displayName: source.displayName + " – \(pageIndex + 1)", source: evidence,
            sessionID: sessionID, store: storage)
    }
}

@MainActor
struct IPadResearchRegionCapture: View {
    let request: IPadResearchRegionCaptureRequest
    @ObservedObject var library: LibraryStore
    @ObservedObject var storage: ResearchStore
    @ObservedObject var documentStore: PDFDocumentStore
    @Environment(\.dismiss) private var dismiss
    @State private var region: CGRect?
    @State private var error: String?
    @State private var pendingSave = false
    @State private var selectionMode = false
    @State private var captureInProgress = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: request.source.displayName + " · " + L10n.string("Page") + " \(request.pageIndex + 1)")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Read with touch or mouse. Draw a region with Pencil, or turn on Select region to use touch, mouse or keyboard. Two fingers zoom; Escape cancels the current rectangle.")
                    .font(.caption)
                Button(selectionMode ? "Finish selecting" : "Select region") { selectionMode.toggle() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(pendingSave)
                if selectionMode {
                    Text("Drag to select. With a keyboard, use arrows to position the corner and Return to start or finish the rectangle.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                IPadRegionCaptureSurface(document: request.document, pageIndex: request.pageIndex,
                    region: region, selectionMode: selectionMode, onRegion: { region = $0 },
                    onInteraction: { captureInProgress = $0 }, onSelectionMode: { selectionMode = $0 })
                    .allowsHitTesting(!pendingSave)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .border(Color.secondary.opacity(0.2))
                    .accessibilityLabel("PDF page region")
                Button("Use whole page") { region = request.document.page(at: request.pageIndex)?.bounds(for: .cropBox) }
                    .disabled(pendingSave || captureInProgress)
                if let error { Text(verbatim: error).font(.caption).foregroundStyle(.orange) }
            }
            .padding()
            .navigationTitle("Add page region to question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pendingSave ? "Retry saving" : "Add to question", action: addRegion)
                        .disabled(region == nil || captureInProgress)
                }
            }
        }
    }

    private func addRegion() {
        if pendingSave {
            storage.retryFailedSaves()
            if storage.saveFailures["sessions/\(request.sessionID.uuidString)"] == nil { dismiss() }
            else { error = ResearchImageError.saveFailed.localizedDescription }
            return
        }
        guard let region else { return }
        do {
            try request.add(region: region, library: library, storage: storage, store: documentStore)
            dismiss()
        } catch ResearchImageError.saveFailed {
            pendingSave = storage.saveFailures["sessions/\(request.sessionID.uuidString)"] != nil
            error = ResearchImageError.saveFailed.localizedDescription
        } catch { self.error = error.localizedDescription }
    }
}

/// This recognizer owns one precise rectangle input, rather than a transparent
/// view intercepting PDFKit's reading gestures. Pencil is always available;
/// direct touch and a mouse are enabled only by the explicit selection mode.
@MainActor
final class IPadRegionInputGestureRecognizer: UIGestureRecognizer {
    private var trackedTouch: UITouch?
    private(set) var inputPoint = CGPoint.zero
    private(set) var inputOrigin = CGPoint.zero

    init(pencilOnly: Bool, target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = (pencilOnly ? [UITouch.TouchType.pencil] : [.direct, .indirectPointer])
            .map { NSNumber(value: $0.rawValue) }
        requiresExclusiveTouchType = true
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    func accepts(_ type: UITouch.TouchType) -> Bool {
        isEnabled && allowedTouchTypes.contains(NSNumber(value: type.rawValue))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        // A second direct touch belongs to zooming. It cancels only the draft;
        // the pinch recognizer is never prevented by this recognizer.
        guard trackedTouch == nil, touches.count == 1, let touch = touches.first else {
            state = state == .possible ? .failed : .cancelled
            return
        }
        trackedTouch = touch
        inputOrigin = touch.location(in: view)
        inputPoint = inputOrigin
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = trackedTouch, touches.contains(touch), state == .began || state == .changed else { return }
        inputPoint = touch.location(in: view)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let touch = trackedTouch, touches.contains(touch), state == .began || state == .changed else { return }
        inputPoint = touch.location(in: view)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        if state == .began || state == .changed { state = .cancelled }
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        let normal = super.canPrevent(preventedGestureRecognizer)
        return preventedGestureRecognizer is UIPinchGestureRecognizer ? false : normal
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        _ = super.canBePrevented(by: preventingGestureRecognizer)
        return preventingGestureRecognizer is UIPinchGestureRecognizer
    }
}

/// PDFKit supplies all PDF/view coordinate transforms, including rotated crop
/// boxes. Pixel size and image limits remain in ResearchImagePipeline.
struct IPadRegionCaptureSurface: UIViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int
    let region: CGRect?
    let selectionMode: Bool
    let onRegion: (CGRect?) -> Void
    let onInteraction: (Bool) -> Void
    let onSelectionMode: (Bool) -> Void

    func makeUIView(context: Context) -> Surface {
        Surface(document: document, pageIndex: pageIndex)
    }
    func updateUIView(_ view: Surface, context: Context) {
        let wasSelecting = view.isSelecting
        view.onRegion = onRegion
        // Mode synchronization can cancel an active draft. Deliver that state
        // change after SwiftUI's update; native event callbacks stay immediate.
        view.onInteraction = nil
        view.onSelectionMode = onSelectionMode
        view.setSelectionMode(selectionMode)
        view.show(region)
        view.onInteraction = onInteraction
        if wasSelecting != view.isSelecting {
            let selecting = view.isSelecting
            DispatchQueue.main.async { [weak view] in
                guard let view, !view.isDetached, view.isSelecting == selecting else { return }
                onInteraction(selecting)
            }
        }
    }
    static func dismantleUIView(_ view: Surface, coordinator: Void) {
        view.onRegion = nil
        view.onInteraction = nil
        view.onSelectionMode = nil
        view.detach()
    }

    @MainActor
    final class Surface: UIView, UIGestureRecognizerDelegate {
        let pdf = PDFView()
        let overlay = UIView()
        let selectionLayer = CAShapeLayer()
        let keyboardCursorLayer = CAShapeLayer()
        private let document: PDFDocument
        private let page: PDFPage?
        private let pageIndex: Int
        private let initialRotation: Int
        private let initialCrop: CGRect
        private let snapshotVersion: String
        private var didNavigate = false
        private(set) var navigationCount = 0
        private(set) var region: CGRect?
        private(set) var draftRegion: CGRect?
        private(set) var isSelecting = false
        private(set) var selectionMode = false
        private var start: CGPoint?
        private var inputScale: CGFloat?
        private var inputBounds: CGRect?
        private var inputPageFrame: CGRect?
        private var keyboardPoint: CGPoint?
        private var keyboardSelecting = false
        private var viewportObservations: [NSKeyValueObservation] = []
        private var observedScrollViews: [UIScrollView] = []
        private struct NativeGesture {
            let recognizer: UIGestureRecognizer
            let allowedTouchTypes: [NSNumber]
        }
        private var nativeGestures: [ObjectIdentifier: NativeGesture] = [:]
        private(set) var isDetached = false
        private(set) lazy var pencilInput = IPadRegionInputGestureRecognizer(pencilOnly: true,
            target: self, action: #selector(dragged(_:)))
        private(set) lazy var directInput = IPadRegionInputGestureRecognizer(pencilOnly: false,
            target: self, action: #selector(dragged(_:)))
        var onRegion: ((CGRect?) -> Void)?
        var onInteraction: ((Bool) -> Void)?
        var onSelectionMode: ((Bool) -> Void)?

        init(document: PDFDocument, pageIndex: Int) {
            self.document = document
            self.pageIndex = pageIndex
            page = document.page(at: pageIndex)
            initialRotation = page?.rotation ?? 0
            initialCrop = page?.bounds(for: .cropBox) ?? .null
            snapshotVersion = DocumentAccessCoordinator.contentVersion(of: document)
            super.init(frame: .zero)
            pdf.document = document
            pdf.displayMode = .singlePage
            pdf.displayBox = .cropBox
            pdf.autoScales = true
            pdf.displaysPageBreaks = false
            pdf.setValue(false, forKey: "enableDataDetectors")
            addSubview(pdf)
            overlay.isUserInteractionEnabled = false
            overlay.isAccessibilityElement = false
            addSubview(overlay)
            selectionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.15).cgColor
            selectionLayer.strokeColor = UIColor.systemBlue.cgColor
            selectionLayer.lineWidth = 2
            overlay.layer.addSublayer(selectionLayer)
            keyboardCursorLayer.fillColor = nil
            keyboardCursorLayer.strokeColor = UIColor.systemBlue.cgColor
            keyboardCursorLayer.lineWidth = 2
            overlay.layer.addSublayer(keyboardCursorLayer)
            pencilInput.delegate = self
            directInput.delegate = self
            directInput.isEnabled = false
            pdf.addGestureRecognizer(pencilInput)
            pdf.addGestureRecognizer(directInput)
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                name: .PDFViewScaleChanged, object: pdf)
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                name: .PDFViewVisiblePagesChanged, object: pdf)
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                name: .PDFViewPageChanged, object: pdf)
            NotificationCenter.default.addObserver(self, selector: #selector(cancelInput),
                name: UIApplication.willResignActiveNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        deinit { NotificationCenter.default.removeObserver(self) }

        override var canBecomeFirstResponder: Bool { !isDetached }

        override func resignFirstResponder() -> Bool {
            cancelInput()
            keyboardPoint = nil
            refreshOverlay()
            return super.resignFirstResponder()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { cancelInput() }
        }

        override var keyCommands: [UIKeyCommand]? {
            guard !isDetached else { return nil }
            var commands = [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelInput)),
                UIKeyCommand(input: "r", modifierFlags: [.command, .shift], action: #selector(toggleSelectionMode))]
            if selectionMode {
                for input in [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow,
                              UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow] {
                    commands.append(UIKeyCommand(input: input, modifierFlags: [], action: #selector(moveKeyboardPoint(_:))))
                    commands.append(UIKeyCommand(input: input, modifierFlags: [.shift], action: #selector(moveKeyboardPoint(_:))))
                }
                commands.append(UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(confirmKeyboardPoint)))
                commands.append(UIKeyCommand(input: " ", modifierFlags: [], action: #selector(confirmKeyboardPoint)))
            }
            commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
            return commands
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            pdf.frame = bounds
            overlay.frame = bounds
            if !didNavigate, !bounds.isEmpty, let page, isCurrentDocument {
                pdf.layoutIfNeeded()
                pdf.go(to: page)
                didNavigate = true
                navigationCount += 1
            }
            observeViewport()
            refreshOverlay()
        }

        func show(_ value: CGRect?) {
            // A parent re-render cannot erase a rectangle being drawn. External
            // committed changes still apply when no input transaction is active.
            guard !isSelecting else { return }
            region = value
            refreshOverlay()
        }

        func setSelectionMode(_ enabled: Bool) {
            guard !isDetached else { return }
            guard selectionMode != enabled else { return }
            cancelInput()
            selectionMode = enabled
            directInput.isEnabled = enabled
            updateNativeTouchTypes()
            if enabled {
                _ = becomeFirstResponder()
            } else {
                keyboardPoint = nil
                _ = resignFirstResponder()
            }
            refreshOverlay()
        }

        var isCurrentDocument: Bool {
            guard !isDetached, let page else { return false }
            return pdf.document === document && page.document === document
                && document.page(at: pageIndex) === page && page.rotation == initialRotation
                && page.bounds(for: .cropBox) == initialCrop
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let input = gestureRecognizer as? IPadRegionInputGestureRecognizer else {
                return super.gestureRecognizerShouldBegin(gestureRecognizer)
            }
            guard super.gestureRecognizerShouldBegin(gestureRecognizer),
                  input === pencilInput || input === directInput,
                  !isSelecting, isCurrentDocument, let page,
                  pdf.currentPage === page, input === pencilInput || selectionMode else { return false }
            return page.bounds(for: .cropBox).contains(pdf.convert(input.inputOrigin, to: page))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Native navigation has separate touch types. Fingers can pan or
            // pinch while Pencil is down; navigation cancels the draft before
            // another coordinate is accepted.
            let input = gestureRecognizer is IPadRegionInputGestureRecognizer ? gestureRecognizer : otherGestureRecognizer
            let native = input === gestureRecognizer ? otherGestureRecognizer : gestureRecognizer
            guard input === pencilInput || input === directInput else { return false }
            return native is UIPinchGestureRecognizer || (input === pencilInput && native is UIPanGestureRecognizer)
        }

        @objc private func dragged(_ gesture: IPadRegionInputGestureRecognizer) {
            switch gesture.state {
            case .began:
                _ = beginRegionInput(at: gesture.inputOrigin)
            case .changed, .ended:
                updateRegionInput(at: gesture.inputPoint)
                if gesture.state == .ended { commitRegionInput() }
            case .cancelled, .failed:
                cancelRegionInput()
            default: break
            }
        }

        /// Both native gestures and keyboard commands use this transaction.
        /// Diagnostics exercise it with a real PDFView, never substitute math.
        @discardableResult
        func beginRegionInput(at viewPoint: CGPoint) -> Bool {
            guard !isSelecting, isCurrentDocument, let page,
                  pdf.currentPage === page,
                  snapshotVersion == DocumentAccessCoordinator.contentVersion(of: document) else { return false }
            let point = pdf.convert(viewPoint, to: page)
            guard initialCrop.contains(point) else { return false }
            start = point
            inputScale = pdf.scaleFactor
            inputBounds = pdf.bounds
            inputPageFrame = pdf.convert(initialCrop, from: page)
            isSelecting = true
            draftRegion = nil
            _ = becomeFirstResponder()
            onInteraction?(true)
            refreshOverlay()
            return true
        }

        func updateRegionInput(at viewPoint: CGPoint) {
            guard isSelecting else { return }
            guard inputViewportIsCurrent, let page, let start else { cancelRegionInput(); return }
            let point = pdf.convert(viewPoint, to: page)
            guard point.x.isFinite, point.y.isFinite else { cancelRegionInput(); return }
            let rectangle = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                width: abs(point.x - start.x), height: abs(point.y - start.y)).intersection(initialCrop)
            draftRegion = !rectangle.isNull && rectangle.width >= 1 && rectangle.height >= 1 ? rectangle : nil
            refreshOverlay()
        }

        func commitRegionInput() {
            guard isSelecting else { return }
            guard inputViewportIsCurrent,
                  snapshotVersion == DocumentAccessCoordinator.contentVersion(of: document),
                  let draftRegion else { cancelRegionInput(); return }
            region = draftRegion
            finishRegionInput()
            onRegion?(region)
        }

        func cancelRegionInput() {
            guard isSelecting else { return }
            finishRegionInput()
            // No temporary rectangle was published; Cancel leaves the last
            // committed PDF region and Add button binding intact.
        }

        private func finishRegionInput() {
            start = nil
            draftRegion = nil
            inputScale = nil
            inputBounds = nil
            inputPageFrame = nil
            isSelecting = false
            keyboardSelecting = false
            refreshOverlay()
            onInteraction?(false)
        }

        private var inputViewportIsCurrent: Bool {
            guard isCurrentDocument, let page else { return false }
            return pdf.currentPage === page && inputScale == pdf.scaleFactor && inputBounds == pdf.bounds
                && inputPageFrame == pdf.convert(initialCrop, from: page)
        }

        @objc func cancelInput() {
            cancelRegionInput()
            // End native input as well, so an old touch cannot resume after Esc.
            pencilInput.isEnabled = false
            pencilInput.isEnabled = !isDetached
            directInput.isEnabled = false
            directInput.isEnabled = !isDetached && selectionMode
        }

        @objc private func toggleSelectionMode() {
            let enabled = !selectionMode
            setSelectionMode(enabled)
            onSelectionMode?(enabled)
        }

        @objc func moveKeyboardPoint(_ command: UIKeyCommand) {
            guard selectionMode, isCurrentDocument, let page,
                  pdf.currentPage === page,
                  !isSelecting || keyboardSelecting else { return }
            let pageRect = pdf.convert(initialCrop, from: page)
            let visible = pageRect.intersection(pdf.bounds)
            guard !visible.isNull, !visible.isEmpty else { return }
            var point = keyboardPoint ?? CGPoint(x: visible.midX, y: visible.midY)
            let step: CGFloat = command.modifierFlags.contains(.shift) ? 1 : 10
            switch command.input {
            case UIKeyCommand.inputLeftArrow: point.x -= step
            case UIKeyCommand.inputRightArrow: point.x += step
            case UIKeyCommand.inputUpArrow: point.y -= step
            case UIKeyCommand.inputDownArrow: point.y += step
            default: return
            }
            point.x = min(max(point.x, visible.minX), visible.maxX)
            point.y = min(max(point.y, visible.minY), visible.maxY)
            keyboardPoint = point
            if keyboardSelecting { updateRegionInput(at: point) }
            refreshOverlay()
        }

        @objc func confirmKeyboardPoint() {
            guard selectionMode, isCurrentDocument, let page,
                  pdf.currentPage === page,
                  !isSelecting || keyboardSelecting else { return }
            if keyboardSelecting { commitRegionInput(); return }
            let visible = pdf.convert(initialCrop, from: page).intersection(pdf.bounds)
            guard !visible.isNull, !visible.isEmpty else { return }
            let point = keyboardPoint ?? CGPoint(x: visible.midX, y: visible.midY)
            keyboardPoint = point
            keyboardSelecting = beginRegionInput(at: point)
            refreshOverlay()
        }

        @objc private func viewportChanged() {
            if isSelecting, !inputViewportIsCurrent { cancelRegionInput() }
            refreshOverlay()
        }

        @objc private func nativeNavigationChanged(_ gesture: UIGestureRecognizer) {
            if gesture.state == .began { cancelInput() }
            refreshOverlay()
        }

        func detach() {
            guard !isDetached else { return }
            isDetached = true
            cancelInput()
            _ = resignFirstResponder()
            viewportObservations.removeAll()
            observedScrollViews.removeAll()
            for record in nativeGestures.values { restore(record) }
            nativeGestures.removeAll()
            NotificationCenter.default.removeObserver(self)
            pdf.removeGestureRecognizer(pencilInput)
            pdf.removeGestureRecognizer(directInput)
            onRegion = nil
            onInteraction = nil
            onSelectionMode = nil
        }

        private func refreshOverlay() {
            if isSelecting, !inputViewportIsCurrent { cancelRegionInput(); return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if isCurrentDocument, let value = isSelecting ? draftRegion : region, let page, pdf.currentPage === page {
                selectionLayer.path = CGPath(rect: pdf.convert(value, from: page), transform: nil)
            } else {
                selectionLayer.path = nil
            }
            if selectionMode, isCurrentDocument, pdf.currentPage === page, let point = keyboardPoint {
                let cross = UIBezierPath()
                cross.move(to: CGPoint(x: point.x - 8, y: point.y)); cross.addLine(to: CGPoint(x: point.x + 8, y: point.y))
                cross.move(to: CGPoint(x: point.x, y: point.y - 8)); cross.addLine(to: CGPoint(x: point.x, y: point.y + 8))
                keyboardCursorLayer.path = cross.cgPath
            } else { keyboardCursorLayer.path = nil }
            CATransaction.commit()
        }

        private func observeViewport() {
            guard !isDetached else { return }
            var scrollViews: [UIScrollView] = []
            var navigation: [UIGestureRecognizer] = []
            func visit(_ view: UIView) {
                if let scroll = view as? UIScrollView { scrollViews.append(scroll) }
                navigation += (view.gestureRecognizers ?? []).filter { $0 is UIPanGestureRecognizer || $0 is UIPinchGestureRecognizer }
                view.subviews.forEach(visit)
            }
            visit(pdf)
            if scrollViews.map(ObjectIdentifier.init) != observedScrollViews.map(ObjectIdentifier.init) {
                viewportObservations.removeAll()
                observedScrollViews = scrollViews
                viewportObservations = scrollViews.map { scroll in
                    scroll.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                        MainActor.assumeIsolated {
                            self?.cancelRegionInput()
                            self?.viewportChanged()
                        }
                    }
                }
            }
            let current = Set(navigation.map(ObjectIdentifier.init))
            for (id, record) in nativeGestures where !current.contains(id) {
                restore(record)
                nativeGestures[id] = nil
            }
            for gesture in navigation where nativeGestures[ObjectIdentifier(gesture)] == nil {
                nativeGestures[ObjectIdentifier(gesture)] = NativeGesture(recognizer: gesture,
                    allowedTouchTypes: gesture.allowedTouchTypes)
                gesture.addTarget(self, action: #selector(nativeNavigationChanged(_:)))
            }
            updateNativeTouchTypes()
        }

        private func updateNativeTouchTypes() {
            for record in nativeGestures.values {
                var allowed = record.allowedTouchTypes.isEmpty
                    ? [UITouch.TouchType.direct, .indirect, .indirectPointer, .pencil].map { NSNumber(value: $0.rawValue) }
                    : record.allowedTouchTypes
                allowed.removeAll { $0.intValue == UITouch.TouchType.pencil.rawValue }
                if selectionMode, !(record.recognizer is UIPinchGestureRecognizer) {
                    allowed.removeAll { $0.intValue == UITouch.TouchType.direct.rawValue
                        || $0.intValue == UITouch.TouchType.indirectPointer.rawValue }
                }
                // UIKit interprets an empty array as unrestricted input.
                if allowed.isEmpty { allowed = [NSNumber(value: UITouch.TouchType.indirect.rawValue)] }
                if record.recognizer.allowedTouchTypes != allowed { record.recognizer.allowedTouchTypes = allowed }
            }
        }

        private func restore(_ record: NativeGesture) {
            record.recognizer.allowedTouchTypes = record.allowedTouchTypes
            record.recognizer.removeTarget(self, action: #selector(nativeNavigationChanged(_:)))
        }
    }
}
#endif
