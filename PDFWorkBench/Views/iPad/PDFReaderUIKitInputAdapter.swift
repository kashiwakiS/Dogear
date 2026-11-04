#if os(iOS)
import PDFKit
import UIKit

/// Presentation state only. Every mutation still belongs to PDFDocumentStore.
enum PDFReaderUIKitInputMode: Equatable {
    case read, selectText, addNote
}

enum PDFReaderUIKitKeyboardCommand: Equatable {
    case addHighlight, undo, redo, previousPage, nextPage, find, nextMatch, previousMatch, cancel, selectText, placeNote
}

/// Converts native Pencil/touch/pointer events into selection and note-placement
/// intent. It never creates annotations or owns persistence/Undo.
@MainActor
final class PDFReaderUIKitInputAdapter: NSObject, UIGestureRecognizerDelegate {
    var onInteraction: () -> Void = {}
    var onPlaceNote: (PDFDocument, PDFPage, CGRect) -> Void = { _, _, _ in }
    var onSelectionApplied: (PDFDocument) -> Void = { _ in }
    private(set) var mode: PDFReaderUIKitInputMode = .read
    private(set) var selectionPan: UIPanGestureRecognizer!
    private(set) var selectionTap: UITapGestureRecognizer!
    private(set) var noteTap: UITapGestureRecognizer!
    private(set) var selectionDismissTap: UITapGestureRecognizer!
    weak var annotationTapRecognizer: UITapGestureRecognizer?
    private weak var view: PDFView?
    private weak var document: PDFDocument?
    private var transaction: SelectionTransaction?
    private var nativeOrigin: NativeSelectionOrigin?
    private var nativeDragInputID: UUID?
    private var nativeTouchID: ObjectIdentifier?
    private weak var nativeOriginTouch: UITouch?
    private var nativeGestures: [ObjectIdentifier: NativeGesture] = [:]
    private var inputID = UUID()

    var isSelecting: Bool { transaction != nil }

    private struct SelectionTransaction {
        let document: PDFDocument
        let startPage: PDFPage
        let start: CGPoint
        let startCharacterIndex: Int
        let previous: PDFSelection?
        let inputID: UUID
        let pageIndex: Int
        let pageCount: Int
        let rotation: Int
    }
    private struct NativeGesture {
        let recognizer: UIGestureRecognizer
        let allowedTouchTypes: [NSNumber]
        let scrollMinimumTouches: Int?
    }
    private struct NativeSelectionOrigin {
        let document: PDFDocument
        let page: PDFPage
        let point: CGPoint
        let pagePoint: CGPoint
        let characterIndex: Int
        let pageIndex: Int
        let pageCount: Int
        let rotation: Int
        let inputID: UUID
        let mode: PDFReaderUIKitInputMode
        let touchID: ObjectIdentifier
        let viewID: ObjectIdentifier
        let windowID: ObjectIdentifier?
        let bounds: CGRect
        let frame: CGRect
        let transform: CGAffineTransform
        let scale: CGFloat
        let displayBox: PDFDisplayBox
    }
    private static let nativeTouchTypes = [UITouch.TouchType.direct, .indirect, .indirectPointer]
        .map { NSNumber(value: $0.rawValue) }
    private static let pencilTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    private static let selectingTouchTypes = [UITouch.TouchType.direct, .pencil, .indirectPointer]
        .map { NSNumber(value: $0.rawValue) }

    func attach(to view: PDFView) {
        detach()
        self.view = view
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        pan.minimumNumberOfTouches = 1; pan.maximumNumberOfTouches = 1
        pan.delegate = self; view.addGestureRecognizer(pan); selectionPan = pan
        let tap = UITapGestureRecognizer(target: self, action: #selector(selectedWord(_:)))
        tap.delegate = self; tap.require(toFail: pan)
        view.addGestureRecognizer(tap); selectionTap = tap
        let note = UITapGestureRecognizer(target: self, action: #selector(placedNote(_:)))
        note.delegate = self; view.addGestureRecognizer(note); noteTap = note
        let dismiss = UITapGestureRecognizer(target: self, action: #selector(dismissedSelection(_:)))
        dismiss.delegate = self; dismiss.cancelsTouchesInView = false; dismiss.require(toFail: pan)
        view.addGestureRecognizer(dismiss); selectionDismissTap = dismiss
        configure(mode: mode)
        refreshNativeGestures()
    }

    func install(_ document: PDFDocument) {
        // Even reinstalling the same object is a new native installation after
        // PDFView was replaced or externally rebound. Its old touch must end.
        cancelSelection(restoring: false)
        guard self.document !== document else { return }
        inputID = UUID()
        resetRecognizers()
        self.document = document
        refreshNativeGestures()
        configure(mode: mode)
    }

    func configure(mode: PDFReaderUIKitInputMode) {
        trace("configure-before", "requestedMode=\(mode) \(recognizerDescription())")
        if self.mode != mode {
            cancelSelection(restoring: true)
            inputID = UUID()
            resetRecognizers()
        }
        self.mode = mode
        selectionPan?.allowedTouchTypes = mode == .selectText ? Self.selectingTouchTypes : Self.pencilTouchTypes
        selectionTap?.allowedTouchTypes = mode == .selectText ? Self.selectingTouchTypes : Self.pencilTouchTypes
        selectionPan?.isEnabled = mode != .addNote
        selectionTap?.isEnabled = mode != .addNote
        noteTap?.allowedTouchTypes = Self.selectingTouchTypes
        noteTap?.isEnabled = mode == .addNote
        selectionDismissTap?.allowedTouchTypes = [UITouch.TouchType.direct, .indirectPointer].map { NSNumber(value: $0.rawValue) }
        selectionDismissTap?.isEnabled = mode == .read
        updateNativeTouchTypes()
        trace("configure-after", "\(recognizerDescription())")
    }

    /// PDFKit may create/recreate its scroll recognizers during layout. Record
    /// only input policy; retain its delegates, enabled state and relationships.
    func refreshNativeGestures() {
        guard let view else { return }
        var current: [UIGestureRecognizer] = []
        func visit(_ child: UIView) {
            for gesture in child.gestureRecognizers ?? [] {
                guard gesture !== selectionPan, gesture !== selectionTap, gesture !== noteTap, gesture !== selectionDismissTap,
                      gesture !== annotationTapRecognizer,
                      gesture is UIPanGestureRecognizer || gesture is UIPinchGestureRecognizer
                        || gesture is UILongPressGestureRecognizer || gesture is UITapGestureRecognizer else { continue }
                current.append(gesture)
            }
            child.subviews.forEach(visit)
        }
        visit(view)
        let currentIDs = Set(current.map(ObjectIdentifier.init))
        for (id, record) in nativeGestures where !currentIDs.contains(id) {
            restore(record); nativeGestures[id] = nil
        }
        for gesture in current where nativeGestures[ObjectIdentifier(gesture)] == nil {
            nativeGestures[ObjectIdentifier(gesture)] = NativeGesture(recognizer: gesture,
                allowedTouchTypes: gesture.allowedTouchTypes,
                scrollMinimumTouches: isScrollPan(gesture) ? (gesture as? UIPanGestureRecognizer)?.minimumNumberOfTouches : nil)
            gesture.addTarget(self, action: #selector(nativeNavigationBegan(_:)))
        }
        updateNativeTouchTypes()
    }

    private func updateNativeTouchTypes() {
        for record in nativeGestures.values {
            var allowed = record.allowedTouchTypes.isEmpty ? Self.nativeTouchTypes : record.allowedTouchTypes
            allowed.removeAll { $0.intValue == UITouch.TouchType.pencil.rawValue }
            if mode == .addNote, record.recognizer is UITapGestureRecognizer {
                allowed.removeAll { $0.intValue == UITouch.TouchType.direct.rawValue
                    || $0.intValue == UITouch.TouchType.indirectPointer.rawValue }
            } else if mode == .selectText, !(record.recognizer is UIPinchGestureRecognizer) {
                allowed.removeAll { $0.intValue == UITouch.TouchType.indirectPointer.rawValue }
                if record.scrollMinimumTouches == nil {
                    allowed.removeAll { $0.intValue == UITouch.TouchType.direct.rawValue }
                }
            }
            if let minimum = record.scrollMinimumTouches, let pan = record.recognizer as? UIPanGestureRecognizer {
                // Only the public UIScrollView pan is changed. Its pointer
                // wheel/trackpad scroll mask, delegate and enabled state stay native.
                let required = mode == .selectText ? max(2, minimum) : minimum
                if pan.minimumNumberOfTouches != required { pan.minimumNumberOfTouches = required }
            }
            // An empty allowedTouchTypes has UIKit's unrestricted meaning.
            if allowed.isEmpty { allowed = [NSNumber(value: UITouch.TouchType.indirect.rawValue)] }
            if record.recognizer.allowedTouchTypes != allowed { record.recognizer.allowedTouchTypes = allowed }
        }
    }

    private func restore(_ record: NativeGesture) {
        record.recognizer.allowedTouchTypes = record.allowedTouchTypes
        if let minimum = record.scrollMinimumTouches, let pan = record.recognizer as? UIPanGestureRecognizer {
            pan.minimumNumberOfTouches = minimum
        }
        record.recognizer.removeTarget(self, action: #selector(nativeNavigationBegan(_:)))
    }

    private func isScrollPan(_ gesture: UIGestureRecognizer) -> Bool {
        guard let scroll = gesture.view as? UIScrollView else { return false }
        return gesture === scroll.panGestureRecognizer
    }

    private func resetRecognizers() {
        // A disabled recognizer cancels the old touch sequence. Re-enabling it
        // cannot complete that sequence under a different document or mode.
        for gesture in [selectionPan, selectionTap, noteTap, selectionDismissTap].compactMap({ $0 }) { gesture.isEnabled = false }
    }

    func detach() {
        cancelSelection(restoring: true)
        inputID = UUID()
        for record in nativeGestures.values { restore(record) }
        nativeGestures.removeAll()
        for gesture in [selectionPan, selectionTap, noteTap, selectionDismissTap].compactMap({ $0 }) { view?.removeGestureRecognizer(gesture) }
        selectionPan = nil; selectionTap = nil; noteTap = nil
        selectionDismissTap = nil
        annotationTapRecognizer = nil
        view = nil; document = nil
    }

    /// Fixture-callable intent entry points also serve real recognizer callbacks.
    /// Points are in PDFView coordinates and converted by PDFKit, including zoom
    /// and page rotation. A transaction retains exact document/page ownership.
    @discardableResult
    func captureNativeSelectionOrigin(at point: CGPoint, touchIdentifier: ObjectIdentifier,
                                      touchType: UITouch.TouchType) -> Bool {
        // Excluded fingers must not disturb a reading-mode Pencil sequence.
        let allowed = mode == .selectText ? Self.selectingTouchTypes : Self.pencilTouchTypes
        guard mode != .addNote, allowed.contains(NSNumber(value: touchType.rawValue)) else { return false }
        if let nativeTouchID {
            if nativeTouchID == touchIdentifier { return nativeOrigin != nil || nativeDragInputID != nil }
            // The one-touch selection recognizer may now fail in favor of
            // native two-finger navigation. Never replace the first anchor.
            cancelSelection(restoring: true)
            trace("capture-origin", "accepted=false reason=second-touch mode=\(mode)")
            return false
        }
        nativeTouchID = touchIdentifier
        guard point.x.isFinite, point.y.isFinite, let view, let document, view.document === document,
              let page = view.page(for: point, nearest: false), owns(page, in: document) else { return false }
        let pagePoint = view.convert(point, to: page)
        guard let characterIndex = textCharacter(at: pagePoint, on: page, in: view) else { return false }
        nativeOrigin = NativeSelectionOrigin(document: document, page: page, point: point, pagePoint: pagePoint,
            characterIndex: characterIndex, pageIndex: document.index(for: page), pageCount: document.pageCount,
            rotation: page.rotation, inputID: inputID, mode: mode, touchID: touchIdentifier,
            viewID: ObjectIdentifier(view), windowID: view.window.map(ObjectIdentifier.init), bounds: view.bounds,
            frame: view.frame, transform: view.transform, scale: view.scaleFactor, displayBox: view.displayBox)
        trace("capture-origin", "accepted=true mode=\(mode) touchType=\(touchType.rawValue) \(hitDescription(at: point))")
        return true
    }

    /// UIGestureRecognizer can report zero translation when it first recognizes
    /// a completed pointer drag. Only the actual touch-down owns the origin.
    @discardableResult
    func beginNativeDrag(at point: CGPoint) -> Bool {
        guard let origin = nativeOrigin, nativeOriginIsValid(origin) else {
            cancelSelection(restoring: true)
            trace("native-begin", "accepted=false reason=missing-or-stale-origin mode=\(mode)")
            return false
        }
        let touch = nativeOriginTouch
        guard beginSelection(at: origin.point), nativeOriginIsValid(origin) else {
            cancelSelection(restoring: true); return false
        }
        nativeDragInputID = origin.inputID
        nativeTouchID = origin.touchID
        nativeOriginTouch = touch
        trace("native-begin", "accepted=true originCharacter=\(origin.characterIndex) originPoint=\(origin.point) recognitionPoint=\(point)")
        return updateNativeDrag(to: point)
    }

    @discardableResult
    func updateNativeDrag(to point: CGPoint, finished: Bool = false) -> Bool {
        guard nativeDragInputID == inputID, transaction != nil else {
            if finished { clearNativeOrigin() }
            return false
        }
        let accepted = updateSelection(to: point, finished: finished)
        if finished { clearNativeOrigin() }
        return accepted
    }

    private func nativeOriginIsValid(_ origin: NativeSelectionOrigin) -> Bool {
        guard let view, document === origin.document, view.document === origin.document,
              inputID == origin.inputID, mode == origin.mode, mode != .addNote,
              owns(origin.page, in: origin.document), origin.document.pageCount == origin.pageCount,
              origin.document.index(for: origin.page) == origin.pageIndex, origin.page.rotation == origin.rotation,
              ObjectIdentifier(view) == origin.viewID, view.window.map(ObjectIdentifier.init) == origin.windowID,
              view.bounds == origin.bounds, view.frame == origin.frame, view.transform == origin.transform,
              view.scaleFactor == origin.scale, view.displayBox == origin.displayBox else { return false }
        let mapped = view.convert(origin.pagePoint, from: origin.page)
        return abs(mapped.x - origin.point.x) <= 0.5 && abs(mapped.y - origin.point.y) <= 0.5
            && view.page(for: origin.point, nearest: false) === origin.page
            && textCharacter(at: view.convert(origin.point, to: origin.page), on: origin.page, in: view) == origin.characterIndex
    }

    private func clearNativeOrigin() {
        nativeOrigin = nil; nativeDragInputID = nil; nativeTouchID = nil; nativeOriginTouch = nil
    }

    @discardableResult
    func beginSelection(at point: CGPoint) -> Bool {
        var accepted = false
        defer { trace("begin", "accepted=\(accepted) mode=\(mode) active=\(isSelecting) \(hitDescription(at: point))") }
        guard point.x.isFinite, point.y.isFinite, mode != .addNote,
              let view, let document, view.document === document,
              let page = view.page(for: point, nearest: false), owns(page, in: document) else { return false }
        let start = view.convert(point, to: page)
        guard let startCharacter = textCharacter(at: start, on: page, in: view) else { return false }
        cancelSelection(restoring: true)
        let id = inputID
        let previous = permittedSelection(view.currentSelection, in: document)
        onInteraction()
        guard inputID == id, mode != .addNote, self.document === document,
              self.view === view, view.document === document, owns(page, in: document) else { return false }
        transaction = SelectionTransaction(document: document, startPage: page, start: start,
            startCharacterIndex: startCharacter, previous: previous, inputID: id, pageIndex: document.index(for: page),
            pageCount: document.pageCount, rotation: page.rotation)
        accepted = true
        return true
    }

    @discardableResult
    func updateSelection(to point: CGPoint, finished: Bool = false) -> Bool {
        var accepted = false
        defer { trace("update", "accepted=\(accepted) finished=\(finished) mode=\(mode) active=\(isSelecting) \(hitDescription(at: point))") }
        guard let transaction, let view, document === transaction.document,
              inputID == transaction.inputID, mode != .addNote,
              view.document === transaction.document, owns(transaction.startPage, in: transaction.document),
              transaction.pageCount == transaction.document.pageCount,
              transaction.pageIndex == transaction.document.index(for: transaction.startPage),
              transaction.rotation == transaction.startPage.rotation else {
            cancelSelection(restoring: false); return false
        }
        guard point.x.isFinite, point.y.isFinite,
              let page = view.page(for: point, nearest: true), owns(page, in: transaction.document) else {
            if finished { cancelSelection(restoring: true) }
            return false
        }
        let box = page.bounds(for: view.displayBox)
        let converted = view.convert(point, to: page)
        guard !box.isEmpty, !box.isNull, !box.isInfinite, converted.x.isFinite, converted.y.isFinite else {
            if finished { cancelSelection(restoring: true) }
            return false
        }
        let end = CGPoint(x: min(box.maxX, max(box.minX, converted.x)), y: min(box.maxY, max(box.minY, converted.y)))
        let endPageIndex = transaction.document.index(for: page)
        let proposed: PDFSelection?
        if let endCharacter = textCharacter(at: end, on: page, in: view) {
            // PDFKit's point API treats a glyph midpoint as a caret and can
            // exclude that glyph. Exact character indices include both touched
            // glyphs; normalize document order for backwards and cross-page drag.
            let backwards = endPageIndex < transaction.pageIndex
                || (endPageIndex == transaction.pageIndex && endCharacter < transaction.startCharacterIndex)
            proposed = backwards
                ? transaction.document.selection(from: page, atCharacterIndex: endCharacter,
                    to: transaction.startPage, atCharacterIndex: transaction.startCharacterIndex)
                : transaction.document.selection(from: transaction.startPage, atCharacterIndex: transaction.startCharacterIndex,
                    to: page, atCharacterIndex: endCharacter)
        } else {
            // Once a drag has a real text anchor, native caret resolution may
            // extend it through whitespace or the nearest page edge. Keep the
            // actual anchor character even when the point API excludes it.
            let native = endPageIndex < transaction.pageIndex
                ? transaction.document.selection(from: page, at: end, to: transaction.startPage, at: transaction.start)
                : transaction.document.selection(from: transaction.startPage, at: transaction.start, to: page, at: end)
            let combined = native ?? PDFSelection(document: transaction.document)
            if let anchor = transaction.startPage.selection(for: NSRange(location: transaction.startCharacterIndex, length: 1)) {
                combined.add(anchor)
            }
            proposed = combined
        }
        guard let selection = proposed,
              PDFTextSelectionService.snapshot(of: selection, in: transaction.document) != nil else {
            if finished { cancelSelection(restoring: true) }
            return false
        }
        view.setCurrentSelection(selection, animate: false)
        if finished { self.transaction = nil }
        onSelectionApplied(transaction.document)
        accepted = true
        return true
    }

    func cancelSelection(restoring: Bool) {
        clearNativeOrigin()
        guard let transaction else { return }
        trace("cancel", "restoring=\(restoring) sameDocument=\(document === transaction.document && view?.document === transaction.document) mode=\(mode) startPage=\(transaction.pageIndex) startCharacter=\(transaction.startCharacterIndex)")
        self.transaction = nil
        if restoring, document === transaction.document, view?.document === transaction.document {
            view?.setCurrentSelection(permittedSelection(transaction.previous, in: transaction.document), animate: false)
        }
    }

    @discardableResult
    func selectWord(at point: CGPoint) -> Bool {
        var accepted = false
        defer { trace("word", "accepted=\(accepted) mode=\(mode) \(hitDescription(at: point))") }
        guard point.x.isFinite, point.y.isFinite, mode != .addNote,
              let view, let document, view.document === document,
              let page = view.page(for: point, nearest: false), owns(page, in: document),
              !protectedAnnotation(at: view.convert(point, to: page), on: page),
              textCharacter(at: view.convert(point, to: page), on: page, in: view) != nil,
              let selection = page.selectionForWord(at: view.convert(point, to: page)),
              PDFTextSelectionService.snapshot(of: selection, in: document) != nil else { return false }
        cancelSelection(restoring: true)
        let id = inputID
        onInteraction()
        guard inputID == id, mode != .addNote, self.document === document,
              self.view === view, view.document === document, owns(page, in: document),
              PDFTextSelectionService.snapshot(of: selection, in: document) != nil else { return false }
        view.setCurrentSelection(selection, animate: false)
        onSelectionApplied(document)
        accepted = true
        return true
    }

    /// The selection tap keeps text intent in both Pencil reading and explicit
    /// selection mode, and dismisses an existing selection on a blank tap.
    @discardableResult
    func tapSelection(at point: CGPoint) -> Bool {
        selectWord(at: point) || dismissSelection(at: point)
    }

    @discardableResult
    func placeNote(at point: CGPoint) -> Bool {
        var accepted = false
        defer { trace("note", "accepted=\(accepted) mode=\(mode) \(hitDescription(at: point))") }
        guard point.x.isFinite, point.y.isFinite, mode == .addNote,
              let view, let document, view.document === document,
              let page = view.page(for: point, nearest: false), owns(page, in: document) else { return false }
        let target = view.convert(point, to: page), crop = page.bounds(for: .cropBox)
        guard crop.contains(target), crop.width > 0, crop.height > 0 else { return false }
        let width = min(240, crop.width), height = min(120, crop.height)
        // Align the displayed box's top-left with the tap through PDFKit's
        // transform, including rotated pages. Crop-edge placement is clamped.
        let proposed = CGRect(x: target.x, y: target.y, width: width, height: height)
        let displayed = view.convert(proposed, from: page)
        let originInView = view.convert(target, from: page)
        let aligned = view.convert(CGPoint(x: originInView.x + point.x - displayed.minX,
            y: originInView.y + point.y - displayed.minY), to: page)
        let bounds = CGRect(x: min(crop.maxX - width, max(crop.minX, aligned.x)),
            y: min(crop.maxY - height, max(crop.minY, aligned.y)), width: width, height: height)
        let id = inputID
        onInteraction()
        guard inputID == id, mode == .addNote, self.document === document,
              self.view === view, view.document === document, owns(page, in: document) else { return false }
        onPlaceNote(document, page, bounds)
        accepted = true
        return true
    }

    /// Read-mode fingers dismiss outside a selected line. Explicit Select Text
    /// uses this only where no glyph was touched; annotations retain their taps.
    @discardableResult
    func dismissSelection(at point: CGPoint) -> Bool {
        guard point.x.isFinite, point.y.isFinite, mode != .addNote, !isSelecting,
              !nativeGestures.values.contains(where: { ($0.recognizer is UIPinchGestureRecognizer || isScrollPan($0.recognizer))
                  && ($0.recognizer.state == .began || $0.recognizer.state == .changed) }),
              let view, let document, view.document === document, let selection = view.currentSelection,
              PDFTextSelectionService.snapshot(of: selection, in: document) != nil else { return false }
        if let page = view.page(for: point, nearest: false) {
            guard owns(page, in: document) else { return false }
            let pdfPoint = view.convert(point, to: page)
            if protectedAnnotation(at: pdfPoint, on: page) { return false }
            if mode == .selectText, textCharacter(at: pdfPoint, on: page, in: view) != nil { return false }
            if selection.selectionsByLine().contains(where: { $0.pages.contains(where: { $0 === page }) && $0.bounds(for: page).contains(pdfPoint) }) {
                return false
            }
        }
        let id = inputID, intendedMode = mode
        onInteraction()
        guard id == inputID, self.view === view, self.document === document, view.document === document,
              mode == intendedMode, mode != .addNote, !isSelecting,
              view.currentSelection === selection else { return false }
        cancelSelection(restoring: false)
        view.clearSelection()
        return true
    }

    private func protectedAnnotation(at point: CGPoint, on page: PDFPage) -> Bool {
        page.annotations.contains { $0.page === page && $0.shouldDisplay && $0.bounds.contains(point) }
    }

    private func permittedSelection(_ selection: PDFSelection?, in document: PDFDocument) -> PDFSelection? {
        guard let selection, PDFTextSelectionService.snapshot(of: selection, in: document) != nil else { return nil }
        return selection.copy() as? PDFSelection
    }

    private func textCharacter(at point: CGPoint, on page: PDFPage, in view: PDFView) -> Int? {
        guard point.x.isFinite, point.y.isFinite, page.bounds(for: view.displayBox).contains(point) else { return nil }
        let index = page.characterIndex(at: point)
        guard index != NSNotFound, index >= 0, index < page.numberOfCharacters else { return nil }
        let bounds = page.characterBounds(at: index)
        let tolerance = 3 / max(view.scaleFactor, 0.01)
        guard !bounds.isEmpty, !bounds.isNull, !bounds.isInfinite,
              bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return nil }
        return index
    }

    private func owns(_ page: PDFPage, in document: PDFDocument) -> Bool {
        page.document === document && document.index(for: page) != NSNotFound
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        guard gesture === selectionPan, selectionPan.isEnabled, let view else { return }
        let point = gesture.location(in: view)
        trace("pan-callback", "state=\(gesture.state.rawValue) touches=\(gesture.numberOfTouches) mode=\(mode) point=\(point) translation=\(gesture.translation(in: view))")
        switch gesture.state {
        case .began: _ = beginNativeDrag(at: point)
        case .changed: _ = updateNativeDrag(to: point)
        case .ended: _ = updateNativeDrag(to: point, finished: true)
        case .cancelled, .failed: cancelSelection(restoring: true)
        default: break
        }
    }
    @objc private func selectedWord(_ gesture: UITapGestureRecognizer) {
        trace("tap-callback", "state=\(gesture.state.rawValue) enabled=\(gesture.isEnabled) mode=\(mode)")
        guard gesture === selectionTap, selectionTap.isEnabled, gesture.state == .ended, let view else { return }
        defer { clearNativeOrigin() }
        let point = gesture.location(in: view)
        _ = tapSelection(at: point)
    }
    @objc private func dismissedSelection(_ gesture: UITapGestureRecognizer) {
        guard gesture === selectionDismissTap, gesture.isEnabled, gesture.state == .ended, let view else { return }
        _ = dismissSelection(at: gesture.location(in: view))
    }
    @objc private func placedNote(_ gesture: UITapGestureRecognizer) {
        trace("note-callback", "state=\(gesture.state.rawValue) enabled=\(gesture.isEnabled) mode=\(mode)")
        guard gesture === noteTap, noteTap.isEnabled, gesture.state == .ended, let view else { return }
        _ = placeNote(at: gesture.location(in: view))
    }
    @objc private func nativeNavigationBegan(_ gesture: UIGestureRecognizer) {
        if gesture.state == .began {
            trace("native-navigation", "recognizer=\(type(of: gesture)) scrollPan=\(isScrollPan(gesture)) active=\(isSelecting) mode=\(mode)")
            nativeNavigationDidBegin()
        }
    }

    /// The same interruption path serves native scroll/pinch callbacks and
    /// real PDFKit fixtures without synthesizing a gesture recognizer state.
    func nativeNavigationDidBegin() { cancelSelection(restoring: true) }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        var accepted = false
        var reason = "installed-document"
        defer {
            trace("should-begin", "recognizer=\(recognizerName(gestureRecognizer)) accepted=\(accepted) reason=\(reason) state=\(gestureRecognizer.state.rawValue) touches=\(gestureRecognizer.numberOfTouches) mode=\(mode) \(hitDescription(at: gestureRecognizer.location(in: view)))")
        }
        guard let view, let document, view.document === document else { return false }
        if gestureRecognizer === noteTap {
            reason = "note-mode"; accepted = mode == .addNote
            return accepted
        }
        if gestureRecognizer === selectionDismissTap { reason = "read-dismiss"; accepted = mode == .read; return accepted }
        reason = "selection-mode"
        guard mode != .addNote else { return false }
        reason = "touch-count"
        if gestureRecognizer === selectionPan {
            if gestureRecognizer.numberOfTouches > 1 {
                cancelSelection(restoring: true); return false
            }
            reason = "captured-origin"
            guard let origin = nativeOrigin, nativeOriginIsValid(origin) else {
                cancelSelection(restoring: true); return false
            }
        }
        // Standard annotation taps keep the editor entry. Selecting text over an
        // annotation is available by dragging, rather than competing tap intents.
        if gestureRecognizer === selectionTap,
           let page = view.page(for: gestureRecognizer.location(in: view), nearest: false),
           owns(page, in: document), protectedAnnotation(at: view.convert(gestureRecognizer.location(in: view), to: page), on: page) {
            reason = "annotation-hit"; return false
        }
        reason = "eligible"; accepted = true
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        trace("receive-touch", "recognizer=\(recognizerName(gestureRecognizer)) state=\(gestureRecognizer.state.rawValue) mode=\(mode) touchType=\(touch.type.rawValue) phase=\(touch.phase.rawValue) touchView=\(touch.view.map { String(describing: type(of: $0)) } ?? "nil") \(hitDescription(at: touch.location(in: view)))")
        if gestureRecognizer === selectionPan, touch.phase == .began,
           selectionPan.allowedTouchTypes.contains(NSNumber(value: touch.type.rawValue)) {
            // A failed tap recognizer need not send a target callback. A weak
            // touch and its public phase distinguish that completed sequence
            // from a second touch belonging to the current sequence.
            if nativeOriginTouch == nil || nativeOriginTouch?.phase == .ended || nativeOriginTouch?.phase == .cancelled {
                cancelSelection(restoring: true)
            }
            let firstTouch = nativeOriginTouch
            _ = captureNativeSelectionOrigin(at: touch.location(in: view), touchIdentifier: ObjectIdentifier(touch), touchType: touch.type)
            if firstTouch == nil { nativeOriginTouch = touch }
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === selectionDismissTap || otherGestureRecognizer === selectionDismissTap { return true }
        // Fingers can pinch while Pencil selects. A native navigation start
        // restores the old selection before the viewport moves.
        let accepted = otherGestureRecognizer is UIPinchGestureRecognizer || isScrollPan(otherGestureRecognizer)
        trace("simultaneous", "recognizer=\(recognizerName(gestureRecognizer)) other=\(type(of: otherGestureRecognizer)) otherState=\(otherGestureRecognizer.state.rawValue) accepted=\(accepted)")
        return accepted
    }

    /// Native-event diagnostics deliberately omit document paths and text bodies.
    /// Autoclosure keeps hit inspection and string formatting out of Release.
    private func trace(_ event: String, _ details: @autoclosure () -> String) {
        #if DEBUG
        NSLog("DogearReaderInput %@ %@", event, details())
        #endif
    }

    private func recognizerName(_ gesture: UIGestureRecognizer) -> String {
        if gesture === selectionPan { return "selectionPan" }
        if gesture === selectionTap { return "selectionTap" }
        if gesture === noteTap { return "noteTap" }
        if gesture === selectionDismissTap { return "selectionDismissTap" }
        return String(describing: type(of: gesture))
    }

    private func recognizerDescription() -> String {
        let gestures = [selectionPan, selectionTap, noteTap].compactMap { $0 }.map {
            "\(recognizerName($0)){state=\($0.state.rawValue),enabled=\($0.isEnabled),types=\($0.allowedTouchTypes)}"
        }.joined(separator: " ")
        return "mode=\(mode) active=\(isSelecting) \(gestures)"
    }

    private func hitDescription(at point: CGPoint) -> String {
        guard point.x.isFinite, point.y.isFinite, let view else { return "point=\(point) view=false" }
        guard let page = view.page(for: point, nearest: false) else {
            return "point=\(point) scale=\(view.scaleFactor) page=-1"
        }
        let converted = view.convert(point, to: page)
        let index = page.characterIndex(at: converted)
        let validIndex = index != NSNotFound && index >= 0 && index < page.numberOfCharacters
        let bounds = validIndex ? page.characterBounds(at: index) : .null
        let pageIndex = document.map { $0.index(for: page) } ?? NSNotFound
        return "point=\(point) pagePoint=\(converted) scale=\(view.scaleFactor) page=\(pageIndex == NSNotFound ? -1 : pageIndex) documentMatch=\(view.document === document) character=\(validIndex ? index : -1) characters=\(page.numberOfCharacters) bounds=\(bounds) textHit=\(textCharacter(at: converted, on: page, in: view) != nil)"
    }
}
#endif
