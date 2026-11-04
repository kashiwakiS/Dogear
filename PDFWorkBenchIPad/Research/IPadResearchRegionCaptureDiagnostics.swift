#if os(iOS)
import PDFKit
import UIKit

/// Runs within the workflow's real isolated document/library fixture. Capture
/// policy, rendering, import and durable Research storage are the production
/// implementations; this suite changes only that disposable fixture.
@MainActor
enum IPadResearchRegionCaptureDiagnostics {
    static func run(library: LibraryStore, store: PDFDocumentStore,
                    access: DocumentAccessCoordinator, root: URL) -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        func rejects(_ message: String, _ operation: () throws -> Void) {
            do { try operation(); expect(false, message) }
            catch { expect(true, "") }
        }
        let input = runNativeInput()
        checks += input.checks
        failures += input.failures
        do {
            guard let editor = store.document, let file = library.file(for: store.selectedPDFURL) else {
                throw DocumentAccessError.snapshotUnavailable
            }
            let storageRoot = root.appendingPathComponent("region-research", isDirectory: true)
            let storage = ResearchStore(rootURL: storageRoot)
            let sessionID = storage.createSession(title: "Synthetic page region",
                sourceSelection: ResearchSourceSelection(fileIDs: [file.id]))
            let read = try access.readSnapshot(fileID: file.id, originalURL: library.resolvedURL(for: file),
                workingCopyURL: file.workingCopyURL)
            let index = store.currentPageIndex
            guard let page = read.document.page(at: index) else { throw DocumentAccessError.snapshotUnavailable }
            let source = ResearchSourceSnapshot(fileID: file.id, displayName: file.displayName, fingerprint: read.contentVersion)
            let request = IPadResearchRegionCaptureRequest(sessionID: sessionID, source: source,
                document: read.document, pageIndex: index, editorDocument: editor)
            try request.validate(library: library, storage: storage, store: store, access: access)
            expect(true, "A capture validates its original source, page, session and reader identity.")
            let crop = page.bounds(for: .cropBox)
            rejects("An out-of-page capture must be rejected before creating an attachment.") {
                try request.add(region: crop.insetBy(dx: -1, dy: -1), library: library, storage: storage, store: store, access: access)
            }
            expect(storage.attachments.isEmpty, "Rejected regions create no Research attachment.")
            try request.add(region: crop, library: library, storage: storage, store: store, access: access)
            let block = storage.session(id: sessionID)?.draft.blocks.last
            let evidence = block?.evidence
            expect(block?.kind == .image && evidence?.source == source && evidence?.anchor?.pageIndex == index,
                "Whole-page capture keeps the frozen source and PDF page anchor in an image block.")
            expect(evidence?.anchor?.x == crop.minX && evidence?.anchor?.y == crop.minY
                && evidence?.anchor?.width == crop.width && evidence?.anchor?.height == crop.height,
                "A region anchor remains in original PDF crop-box coordinates.")
            let reloaded = ResearchStore(rootURL: storageRoot)
            expect(reloaded.session(id: sessionID)?.draft == storage.session(id: sessionID)?.draft
                && evidence?.attachmentID.flatMap { reloaded.attachmentURL(id: $0) } != nil,
                "A rendered region and its source-bearing draft survive durable reload.")
            expect(storage.session(id: sessionID)?.sourceSelection.fileIDs == [file.id],
                "Capture does not expand or reorder the session's sources.")

            store.currentPageIndex = (index + 1) % max(1, editor.pageCount)
            if store.currentPageIndex != index {
                rejects("A capture from a previous reader page must be rejected.") {
                    try request.validate(library: library, storage: storage, store: store, access: access)
                }
            }
            store.currentPageIndex = index
            let wrongReader = IPadResearchRegionCaptureRequest(sessionID: sessionID, source: source,
                document: read.document, pageIndex: index, editorDocument: read.document)
            rejects("A detached or replaced editor identity must not authorize a capture.") {
                try wrongReader.validate(library: library, storage: storage, store: store, access: access)
            }
            if let bytes = read.document.dataRepresentation(), let differentDocument = PDFDocument(data: bytes),
               let differentPage = differentDocument.page(at: index) {
                differentPage.addAnnotation(PDFAnnotation(bounds: CGRect(x: crop.midX, y: crop.midY, width: 20, height: 20),
                    forType: .square, withProperties: nil))
                let mismatchedPixels = IPadResearchRegionCaptureRequest(sessionID: sessionID, source: source,
                    document: differentDocument, pageIndex: index, editorDocument: editor)
                rejects("A current source fingerprint cannot authorize pixels from a different detached PDF.") {
                    try mismatchedPixels.validate(library: library, storage: storage, store: store, access: access)
                }
            } else {
                expect(false, "The mismatched-pixels fixture could not load.")
            }
            let rotation = page.rotation
            page.rotation = (rotation + 90) % 360
            rejects("Changing the captured detached PDF must invalidate its rectangle.") {
                try request.validate(library: library, storage: storage, store: store, access: access)
            }
            page.rotation = rotation
            if let livePage = editor.page(at: index) {
                let liveRotation = livePage.rotation
                livePage.rotation = (liveRotation + 90) % 360
                rejects("A changed current PDF source must invalidate a captured region.") {
                    try request.validate(library: library, storage: storage, store: store, access: access)
                }
                livePage.rotation = liveRotation
            }
            if var session = storage.session(id: sessionID) {
                session.sourceSelection.fileIDs = []
                _ = storage.updateSession(session)
            }
            rejects("Removing the captured file from the session's sources must reject the capture.") {
                try request.add(region: crop, library: library, storage: storage, store: store, access: access)
            }
            expect(storage.attachments.count == 1 && storage.session(id: sessionID)?.sourceSelection.fileIDs.isEmpty == true,
                "Rejected stale captures neither add an image nor silently restore source membership.")
        } catch {
            expect(false, "Region fixture could not complete: \(error.localizedDescription)")
        }
        return (checks, failures)
    }

    /// Exercises production transactions and native PDFKit transforms. It does
    /// not manufacture UITouch events or establish Pencil/keyboard hardware QA.
    static func runNativeInput() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        func close(_ actual: CGRect?, _ expected: CGRect) -> Bool {
            guard let actual else { return false }
            return abs(actual.minX - expected.minX) < 0.01 && abs(actual.minY - expected.minY) < 0.01
                && abs(actual.width - expected.width) < 0.01 && abs(actual.height - expected.height) < 0.01
        }
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        let finger = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let pointer = NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        for rotation in [0, 90, 180, 270] {
            guard let document = PDFDocument(data: nativeFixtureData()), let page = document.page(at: 0) else {
                expect(false, "The authored native region fixture could not load.")
                continue
            }
            page.setBounds(CGRect(x: 24, y: 40, width: 500, height: 680), for: .cropBox)
            page.rotation = rotation
            let frozenVersion = DocumentAccessCoordinator.contentVersion(of: document)
            let surface = IPadRegionCaptureSurface.Surface(document: document, pageIndex: 0)
            defer { surface.detach() }
            var publications: [CGRect?] = []
            var interactions: [Bool] = []
            surface.onRegion = { publications.append($0) }
            surface.onInteraction = { interactions.append($0) }
            surface.layoutSubviews()
            expect(surface.navigationCount == 0, "Zero-size region installation defers its page navigation (\(rotation)°).")
            surface.frame = CGRect(x: 0, y: 0, width: 900, height: 1100)
            surface.layoutSubviews()
            surface.pdf.layoutDocumentView()
            surface.layoutSubviews()
            expect(surface.navigationCount == 1 && surface.pdf.currentPage === page,
                "Region layout navigates the real PDFView once (\(rotation)°).")
            expect(!surface.overlay.isUserInteractionEnabled && surface.pencilInput.accepts(.pencil)
                && !surface.pencilInput.accepts(.direct) && !surface.pencilInput.accepts(.indirectPointer)
                && !surface.directInput.isEnabled,
                "The passive overlay and Pencil-only input leave ordinary touch/pointer reading available (\(rotation)°).")
            let expected = CGRect(x: 90, y: 125, width: 185, height: 120)
            let start = surface.pdf.convert(CGPoint(x: expected.minX, y: expected.minY), from: page)
            let end = surface.pdf.convert(CGPoint(x: expected.maxX, y: expected.maxY), from: page)
            expect(surface.beginRegionInput(at: start), "Region input starts at a real PDFKit crop-box coordinate (\(rotation)°).")
            surface.updateRegionInput(at: end)
            surface.show(nil)
            expect(close(surface.draftRegion, expected) && publications.isEmpty && surface.region == nil,
                "A precise rotated/cropped draft survives parent updates without early publication (\(rotation)°).")
            surface.commitRegionInput()
            expect(close(surface.region, expected) && publications.count == 1 && interactions == [true, false],
                "Commit publishes one PDF-coordinate rectangle and balances interaction state (\(rotation)°).")
            expect(close(surface.selectionLayer.path?.boundingBoxOfPath, surface.pdf.convert(expected, from: page)),
                "The committed overlay follows PDFKit's actual rotated page transform (\(rotation)°).")
            _ = surface.beginRegionInput(at: start)
            surface.updateRegionInput(at: end)
            surface.cancelInput()
            surface.commitRegionInput()
            expect(close(surface.region, expected) && publications.count == 1 && !surface.isSelecting,
                "Escape/cancel discards only the uncommitted rectangle (\(rotation)°).")
            let outside = surface.pdf.convert(CGPoint(x: -100, y: -100), from: page)
            expect(!surface.beginRegionInput(at: outside), "Region input rejects points outside the frozen crop box (\(rotation)°).")
            _ = surface.beginRegionInput(at: start)
            surface.updateRegionInput(at: surface.pdf.convert(CGPoint(x: expected.minX + 0.2, y: expected.minY + 0.2), from: page))
            surface.commitRegionInput()
            expect(publications.count == 1 && !surface.isSelecting && close(surface.region, expected),
                "Sub-point rectangles do not erase or replace the last committed region (\(rotation)°).")
            let crop = page.bounds(for: .cropBox)
            expect(surface.beginRegionInput(at: start), "Clipping starts a real crop-box transaction (\(rotation)°).")
            surface.updateRegionInput(at: surface.pdf.convert(CGPoint(x: crop.maxX + 100, y: crop.maxY + 100), from: page))
            expect(close(surface.draftRegion, CGRect(x: expected.minX, y: expected.minY,
                width: crop.maxX - expected.minX, height: crop.maxY - expected.minY)),
                "Dragging outside the page clamps the draft to original PDF crop coordinates (\(rotation)°).")
            surface.cancelRegionInput()

            // Native recognizers are inspected after PDFKit creates its actual
            // scroll hierarchy. These policy checks are not synthesized gestures.
            let navigation = gestures(in: surface.pdf)
            let pans = navigation.compactMap { $0 as? UIPanGestureRecognizer }
            let pinches = navigation.compactMap { $0 as? UIPinchGestureRecognizer }
            expect(!pans.isEmpty && pans.allSatisfy { !$0.allowedTouchTypes.contains(pencil) }
                && pans.contains { $0.allowedTouchTypes.contains(finger) },
                "Real PDFKit panning accepts fingers without competing for Pencil input (\(rotation)°).")
            expect(!pinches.isEmpty && pinches.allSatisfy { !$0.allowedTouchTypes.contains(pencil) }
                && pinches.contains { $0.allowedTouchTypes.contains(finger) },
                "Real PDFKit pinch retains fingers and excludes Pencil (\(rotation)°).")
            if let pan = pans.first, let pinch = pinches.first {
                expect(surface.gestureRecognizer(surface.pencilInput, shouldRecognizeSimultaneouslyWith: pan)
                    && surface.gestureRecognizer(surface.directInput, shouldRecognizeSimultaneouslyWith: pinch)
                    && !surface.pencilInput.canPrevent(pinch) && surface.pencilInput.canBePrevented(by: pinch),
                    "Separate Pencil/pan ownership and pinch priority are explicit (\(rotation)°).")
            }
            expect(surface.beginRegionInput(at: start), "Mode-switch cancellation starts with an active PDF transaction (\(rotation)°).")
            surface.updateRegionInput(at: end)
            surface.setSelectionMode(true)
            expect(!surface.isSelecting && surface.directInput.accepts(.direct) && surface.directInput.accepts(.indirectPointer)
                && !surface.directInput.accepts(.pencil) && publications.count == 1,
                "Entering touch/pointer selection cancels an old draft and owns only its explicit input types (\(rotation)°).")
            expect(pans.allSatisfy { !$0.allowedTouchTypes.contains(finger) && !$0.allowedTouchTypes.contains(pointer) }
                && pinches.contains { $0.allowedTouchTypes.contains(finger) },
                "Explicit touch selection owns single-finger dragging while native pinch remains available (\(rotation)°).")
            let commands = surface.keyCommands ?? []
            expect(commands.contains { $0.input == UIKeyCommand.inputEscape }
                && commands.contains { $0.input == "\r" }
                && commands.contains { $0.input == UIKeyCommand.inputRightArrow && $0.modifierFlags == [.shift] }
                && commands.allSatisfy { surface.responds(to: $0.action) },
                "Keyboard selection exposes Escape, Return, arrows and precise Shift-arrow actions (\(rotation)°).")
            surface.confirmKeyboardPoint()
            if let right = commands.first(where: { $0.input == UIKeyCommand.inputRightArrow && $0.modifierFlags.isEmpty }),
               let down = commands.first(where: { $0.input == UIKeyCommand.inputDownArrow && $0.modifierFlags.isEmpty }) {
                surface.moveKeyboardPoint(right)
                surface.moveKeyboardPoint(down)
                surface.confirmKeyboardPoint()
                expect(publications.count == 2 && !surface.isSelecting && (surface.region?.width ?? 0) >= 1
                    && (surface.region?.height ?? 0) >= 1,
                    "Keyboard corner transactions commit through the same real PDFView conversion (\(rotation)°).")
            } else {
                expect(false, "Keyboard movement commands are missing (\(rotation)°).")
            }
            let keyboardRegion = surface.region
            surface.confirmKeyboardPoint()
            expect(surface.isSelecting, "Focus cancellation starts with an active keyboard transaction (\(rotation)°).")
            _ = surface.resignFirstResponder()
            expect(!surface.isSelecting && surface.region == keyboardRegion && publications.count == 2,
                "Leaving focus cancels a keyboard draft while retaining committed evidence (\(rotation)°).")
            surface.setSelectionMode(false)
            expect(!surface.directInput.isEnabled && pans.contains { $0.allowedTouchTypes.contains(finger) },
                "Leaving Select region returns direct touch and pointer panning to PDFKit (\(rotation)°).")

            expect(surface.beginRegionInput(at: start), "Zoom cancellation starts with an active PDF transaction (\(rotation)°).")
            surface.updateRegionInput(at: end)
            surface.pdf.autoScales = false
            surface.pdf.scaleFactor *= 1.25
            surface.updateRegionInput(at: end)
            surface.commitRegionInput()
            expect(!surface.isSelecting && publications.count == 2 && surface.region == keyboardRegion,
                "Native zoom invalidates an in-progress rectangle before publication (\(rotation)°).")
            surface.layoutSubviews()
            let zoomedStart = surface.pdf.convert(CGPoint(x: expected.minX, y: expected.minY), from: page)
            let zoomedEnd = surface.pdf.convert(CGPoint(x: expected.maxX, y: expected.maxY), from: page)
            expect(surface.beginRegionInput(at: zoomedStart), "Scroll cancellation starts with an active zoomed PDF transaction (\(rotation)°).")
            surface.updateRegionInput(at: zoomedEnd)
            if let scroll = scrollViews(in: surface.pdf).first {
                let outerBounds = surface.pdf.bounds
                let scale = surface.pdf.scaleFactor
                let previous = scroll.bounds
                scroll.bounds = previous.offsetBy(dx: 3, dy: 2)
                surface.commitRegionInput()
                expect(!surface.isSelecting && publications.count == 2 && surface.pdf.bounds == outerBounds
                    && surface.pdf.scaleFactor == scale,
                    "An actual inner UIScrollView bounds change cancels the draft even when outer PDFView bounds/scale stay fixed (\(rotation)°).")
                scroll.bounds = previous
            } else {
                expect(false, "PDFKit supplied no native scroll view for the viewport fixture (\(rotation)°).")
            }
            surface.layoutSubviews()
            let currentStart = surface.pdf.convert(CGPoint(x: expected.minX, y: expected.minY), from: page)
            let currentEnd = surface.pdf.convert(CGPoint(x: expected.maxX, y: expected.maxY), from: page)
            expect(surface.beginRegionInput(at: currentStart), "Focus cancellation starts with an active PDF transaction (\(rotation)°).")
            surface.updateRegionInput(at: currentEnd)
            NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
            surface.commitRegionInput()
            expect(!surface.isSelecting && publications.count == 2,
                "Application focus loss cancels capture through its installed native notification (\(rotation)°).")
            expect(DocumentAccessCoordinator.contentVersion(of: document) == frozenVersion,
                "Region input, navigation and keyboard selection leave the detached PDF unchanged (\(rotation)°).")
            if let otherPage = document.page(at: 1) {
                expect(surface.beginRegionInput(at: currentStart), "Page-change cancellation starts with an active PDF transaction (\(rotation)°).")
                surface.updateRegionInput(at: currentEnd)
                surface.pdf.go(to: otherPage)
                surface.updateRegionInput(at: currentEnd)
                surface.commitRegionInput()
                expect(!surface.isSelecting && publications.count == 2 && !surface.beginRegionInput(at: currentStart),
                    "Native navigation away from the frozen page cannot publish old-page coordinates (\(rotation)°).")
                surface.pdf.go(to: page)
                surface.layoutSubviews()
            }
            let restoredStart = surface.pdf.convert(CGPoint(x: expected.minX, y: expected.minY), from: page)
            let restoredEnd = surface.pdf.convert(CGPoint(x: expected.maxX, y: expected.maxY), from: page)
            expect(surface.beginRegionInput(at: restoredStart), "Version cancellation starts with an active PDF transaction (\(rotation)°).")
            surface.updateRegionInput(at: restoredEnd)
            page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 100, y: 100, width: 20, height: 20),
                forType: .square, withProperties: nil))
            surface.commitRegionInput()
            expect(publications.count == 2 && !surface.beginRegionInput(at: restoredStart),
                "Mutating detached snapshot content rejects both an old draft and new input (\(rotation)°).")
            surface.detach()
            surface.show(expected)
            surface.setSelectionMode(true)
            surface.confirmKeyboardPoint()
            expect(surface.isDetached && !surface.beginRegionInput(at: restoredStart) && surface.keyCommands == nil
                && !surface.pencilInput.isEnabled && !surface.directInput.isEnabled && publications.count == 2,
                "Dismantled surfaces cannot retain focus, accept input or publish late evidence (\(rotation)°).")
        }
        return (checks, failures)
    }

    private static func gestures(in view: UIView) -> [UIGestureRecognizer] {
        (view.gestureRecognizers ?? []) + view.subviews.flatMap { gestures(in: $0) }
    }

    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private static func nativeFixtureData() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).pdfData { context in
            for index in 0..<2 {
                context.beginPage()
                ("Authored region input fixture \(index + 1)" as NSString).draw(at: CGPoint(x: 50, y: 90),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            }
        }
    }
}
#endif
