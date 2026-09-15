import AppKit
import Foundation
import PDFKit

@MainActor
enum PDFReadingPositionDiagnostics {
    static func run() async -> AIHighlightFoundationDiagnosticReport {
        var count = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            count += 1
            if !value { failures.append(message) }
        }
        func nextMainTurn() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        func near(_ lhs: PDFNavigationTarget?, _ rhs: PDFNavigationTarget?, tolerance: CGFloat = 2) -> Bool {
            guard let lhs, let rhs, lhs.pageIndex == rhs.pageIndex, let lp = lhs.point, let rp = rhs.point else { return false }
            return abs(lp.x - rp.x) <= tolerance && abs(lp.y - rp.y) <= tolerance
        }

        let container = PDFReaderContainerView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let view = container.pdfView
        view.frame = container.bounds
        let document = PDFDocument()
        for _ in 0..<3 {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 1_200, height: 1_600), for: .mediaBox)
            page.setBounds(CGRect(x: 0, y: 0, width: 1_200, height: 1_600), for: .cropBox)
            document.insert(page, at: document.pageCount)
        }
        view.displayMode = .singlePageContinuous
        view.document = document
        view.layoutDocumentView()
        view.applyZoomCommand(.custom(150))
        check(abs(view.scaleFactor - 1.5) < 0.001 && view.currentZoomState.mode == .custom,
              "Custom zoom did not treat 150 as a percentage.")
        view.applyZoomCommand(.custom(1))
        check(abs(view.scaleFactor - 0.25) < 0.001, "Custom zoom did not clamp to 25 percent.")
        view.applyZoomCommand(.custom(900))
        check(abs(view.scaleFactor - 5) < 0.001, "Custom zoom did not clamp to 500 percent.")
        view.applyZoomCommand(.custom(.nan))
        check(abs(view.scaleFactor - 5) < 0.001, "Non-finite custom zoom changed the current zoom.")
        view.applyZoomCommand(.fitWidth)
        view.applyZoomCommand(.custom(175))
        view.updateActiveFitScaleIfNeeded()
        check(view.currentZoomState.mode == .custom && abs(view.scaleFactor - 1.75) < 0.001,
              "Fit reclaimed the zoom after an explicit custom command.")
        for mode in [PDFZoomState.fitWidth, .fitPage] {
            view.applyZoomState(mode)
            check(view.currentZoomState.mode == mode.mode, "Restoring a Fit preset degraded it to a custom percentage.")
        }
        view.applyZoomState(.custom(scaleFactor: 1.5))
        check(view.currentZoomState.mode == .custom && abs(view.scaleFactor - 1.5) < 0.001,
              "Restoring a custom zoom state changed its scale or mode.")

        var positions: [PDFNavigationTarget] = []
        let coordinator = PDFKitView.Coordinator(displayStyle: .continuous, onPageChanged: { _ in },
            onScaleChanged: { _, _ in }, onSelectionChanged: { _ in }, onReadingPositionChanged: { positions.append($0) })
        coordinator.observePageChanges(for: view, in: container)
        coordinator.observeScaleChanges(for: view, in: container)
        coordinator.observeLiveScrolling(for: view, in: container)
        coordinator.reportReadingPosition(from: view)
        await nextMainTurn()
        check(!positions.isEmpty, "Initial layout did not report a native reading position.")
        check(positions.last?.point?.x.isFinite == true && positions.last?.point?.y.isFinite == true,
              "Initial reading coordinates were not finite page-space points.")
        view.goToOutlineTarget(PDFNavigationTarget(pageIndex: 1, point: CGPoint(x: 250, y: 1_100), relativePagePosition: nil))
        await nextMainTurn()
        await nextMainTurn()
        let saved = view.currentReadingPosition
        let savedZoom = view.currentZoomState
        check(saved?.pageIndex == 1, "Destination capture used a different PDF page.")
        check(near(positions.last, saved), "Page/scroll notifications did not report the current viewport offset.")
        view.goToOutlineTarget(PDFNavigationTarget(pageIndex: 2, point: CGPoint(x: 450, y: 900), relativePagePosition: nil))
        if let saved { view.goToOutlineTarget(saved) }
        await nextMainTurn()
        check(near(view.currentReadingPosition, saved), "Returning to a captured destination did not restore its page-space position.")
        check(view.currentZoomState == savedZoom, "Position restoration changed the stored zoom mode or factor.")

        let oldCount = positions.count
        if let clipView = view.documentView?.enclosingScrollView?.contentView {
            clipView.setBoundsOrigin(CGPoint(x: clipView.bounds.origin.x + 20, y: clipView.bounds.origin.y + 45))
            await nextMainTurn()
            await nextMainTurn()
            check(positions.count > oldCount, "Scrolling within the same page did not report a new offset.")
            check(near(positions.last, view.currentReadingPosition), "Scroll callbacks used stale viewport coordinates.")
        } else { check(false, "The native reading-position fixture had no scroll view.") }

        coordinator.resetNavigationState(targetPageIndex: 1)
        let beforeReset = positions.count
        coordinator.reportReadingPosition(from: view)
        await nextMainTurn()
        check(positions.count == beforeReset + 1, "A new document/navigation reset suppressed an identical initial position.")
        coordinator.stopObserving()
        let stoppedCount = positions.count
        view.goToOutlineTarget(PDFNavigationTarget(pageIndex: 0, point: CGPoint(x: 100, y: 1_200), relativePagePosition: nil))
        coordinator.reportReadingPosition(from: view)
        await nextMainTurn()
        await nextMainTurn()
        check(positions.count == stoppedCount, "A dismantled reader continued publishing position callbacks.")
        return AIHighlightFoundationDiagnosticReport(checkCount: count, failures: failures)
    }
}
