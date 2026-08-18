import AppKit
import PDFKit

/// A page overlay view that draws the Dog-ear folded corner directly in the
/// top-right corner of a PDF page. PDFKit sizes this view to the page bounds,
/// so the corner scrolls and zooms together with the page content instead of
/// being positioned as a floating container-level control.
final class DogearPageOverlayView: NSView {
    var pageIndex: Int = -1
    var marker: DogearMarker? {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var isNightMode = false {
        didSet {
            needsDisplay = true
        }
    }
    var onToggle: (() -> Void)?

    private let foldSize: CGFloat = 34

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard marker != nil else { return }

        let foldRect = NSRect(
            x: bounds.maxX - foldSize,
            y: bounds.maxY - foldSize,
            width: foldSize,
            height: foldSize
        )

        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: foldRect.minX + 4, y: foldRect.maxY - 4))
        triangle.line(to: NSPoint(x: foldRect.maxX - 4, y: foldRect.maxY - 4))
        triangle.line(to: NSPoint(x: foldRect.maxX - 4, y: foldRect.minY + 4))
        triangle.close()

        (isNightMode ? NSColor.yellow.withAlphaComponent(0.86) : NSColor.yellow.withAlphaComponent(0.78))
            .setFill()
        triangle.fill()

        let crease = NSBezierPath()
        crease.move(to: NSPoint(x: foldRect.minX + 4, y: foldRect.maxY - 4))
        crease.line(to: NSPoint(x: foldRect.maxX - 4, y: foldRect.minY + 4))
        crease.lineWidth = 1
        NSColor.orange.withAlphaComponent(0.7).setStroke()
        crease.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard marker != nil else { return nil }

        let foldRect = NSRect(
            x: bounds.maxX - foldSize,
            y: bounds.maxY - foldSize,
            width: foldSize,
            height: foldSize
        )
        return foldRect.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard marker != nil else {
            super.mouseDown(with: event)
            return
        }
        onToggle?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard marker != nil else { return }

        let foldRect = NSRect(
            x: bounds.maxX - foldSize,
            y: bounds.maxY - foldSize,
            width: foldSize,
            height: foldSize
        )
        addCursorRect(foldRect, cursor: .pointingHand)
    }
}

final class DogearPageOverlayViewProvider: NSObject, PDFPageOverlayViewProvider {
    var dogears: [DogearMarker] = []
    var isNightMode = false
    var onToggleDogearAtPage: ((Int) -> Void)?

    private let activeOverlays = NSHashTable<DogearPageOverlayView>.weakObjects()

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let pageIndex = view.document?.index(for: page) ?? -1
        let overlay = DogearPageOverlayView()
        overlay.pageIndex = pageIndex
        overlay.marker = dogears.first { $0.pageIndex == pageIndex }
        overlay.isNightMode = isNightMode
        overlay.onToggle = { [weak self] in
            self?.onToggleDogearAtPage?(pageIndex)
        }
        activeOverlays.add(overlay)
        return overlay
    }

    func update(dogears: [DogearMarker], isNightMode: Bool) {
        self.dogears = dogears
        self.isNightMode = isNightMode

        for overlay in activeOverlays.allObjects {
            overlay.marker = dogears.first { $0.pageIndex == overlay.pageIndex }
            overlay.isNightMode = isNightMode
        }
    }
}
