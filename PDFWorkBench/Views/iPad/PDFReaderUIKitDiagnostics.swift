#if os(iOS)
import PDFKit
import UIKit

/// Real UIKit/PDFKit host fixtures use generated in-memory documents. Retained
/// workspace dependencies use disposable paths/defaults, never user state.
@MainActor
enum PDFReaderUIKitDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        let document = fixture()
        let replacement = fixture()
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 768, height: 900))
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        let coordinator = PDFReaderUIKitView.Coordinator()
        var pageReports: [(PDFDocument, Int)] = []
        var selections: [(PDFDocument, PDFSelection?, PDFTextSelectionSnapshot?)] = []
        var userInteractions = 0
        var zoomReports: [Double] = []
        coordinator.onUserInteraction = { userInteractions += 1 }
        coordinator.onZoomChanged = { _, percent, _ in zoomReports.append(percent) }
        coordinator.onPageChanged = { pageReports.append(($0, $1)) }
        coordinator.onSelectionChanged = { selections.append(($0, $1, $2)) }
        coordinator.attach(to: view)
        coordinator.install(document, in: view)
        view.layoutDocumentView()
        await settle()
        expect(view.document === document, "The reader installs the exact document instance.")
        expect(selections.last?.0 === document, "Initial selection reporting belongs to the installed document.")
        expect(selections.last?.2 == nil, "An initial empty selection does not invent reading context.")

        let navigation = PDFReaderUIKitNavigation(document: document, pageIndex: 1)
        expect(coordinator.navigate(navigation, in: view), "A new page navigation is accepted.")
        await settle()
        expect(view.currentPage === document.page(at: 1), "PDFKit navigates to the requested second page.")
        expect(pageReports.last?.0 === document && pageReports.last?.1 == 1,
               "Programmatic navigation reports the actual PDFKit page to persistence.")
        let reportsAfterNavigation = pageReports.count
        expect(!coordinator.navigate(navigation, in: view), "A consumed request does not navigate repeatedly.")
        await settle()
        expect(pageReports.count == reportsAfterNavigation, "Repeated navigation does not duplicate page feedback.")
        expect(userInteractions == 0, "Programmatic navigation does not revoke the AI command lease.")
        expect(coordinator.navigate(PDFReaderUIKitNavigation(document: document, pageIndex: 1, zoom: .percent(125)), in: view),
               "A native percentage zoom request is accepted.")
        expect(!view.autoScales && abs(view.scaleFactor - 1.25) < 0.01,
               "Percentage zoom is applied through PDFKit's native scale limits.")
        await settle()
        expect(zoomReports.last.map { abs($0 - 125) < 0.01 } == true,
               "A zoom command reports the actual native zoom percentage.")
        expect(coordinator.navigate(PDFReaderUIKitNavigation(document: document, pageIndex: 1, zoom: .fit), in: view)
               && view.autoScales, "Fit zoom restores native automatic scaling.")
        expect(!coordinator.navigate(PDFReaderUIKitNavigation(document: document, pageIndex: 1, zoom: .percent(.nan)), in: view),
               "A non-finite zoom request cannot reach PDFKit.")
        expect(!coordinator.navigate(PDFReaderUIKitNavigation(document: document, pageIndex: 50), in: view),
               "An out-of-range page request is rejected.")

        if let selection = document.findString("Second page passage", withOptions: []).first {
            view.setCurrentSelection(selection, animate: false)
            await settle()
            expect(selections.last?.2?.text == "Second page passage", "Native selection reports the exact selected text.")
            expect(selections.last?.2?.pageNumbers == [2], "Selection context contains a one-based page number.")
            expect(selections.last?.1 !== selection, "The host returns a copied selection, independent of PDFView changes.")
            NotificationCenter.default.post(name: .dogearAnnotationsChanged, object: replacement)
            expect(view.currentSelection != nil, "An unrelated workspace's annotation update preserves this selection.")
            NotificationCenter.default.post(name: .dogearAnnotationsChanged, object: document)
            expect(view.currentSelection != nil, "Annotation-only display refresh preserves reading selection.")
            NotificationCenter.default.post(name: .dogearDocumentStructureChanged, object: replacement)
            expect(view.currentSelection != nil, "An unrelated document's page structure change preserves this selection.")
            NotificationCenter.default.post(name: .dogearDocumentStructureChanged, object: document)
            expect(view.currentSelection == nil, "A mutation of the displayed PDF clears its old native selection.")
            await settle()
            expect(selections.last?.2 == nil, "Clearing the native selection clears research context.")
        } else {
            expect(false, "The generated PDF must expose selectable text.")
        }

        // Queue a report from A, then replace A before it can publish. The
        // pending closure must never bind A's position or selection to B.
        let firstDocumentReports = pageReports.filter { $0.0 === document }.count
        view.go(to: document.page(at: 0)!)
        coordinator.install(replacement, in: view)
        view.layoutDocumentView()
        await settle()
        expect(view.document === replacement, "A replacement document becomes the installed source.")
        expect(pageReports.filter { $0.0 === document }.count == firstDocumentReports,
               "A queued page callback from the old document is cancelled.")
        expect(selections.last?.0 === replacement, "The replacement emits its own selection reset.")
        expect(!coordinator.navigate(navigation, in: view), "An old document's navigation cannot reach the new document.")
        if let foreignSelection = document.findString("First page passage", withOptions: []).first {
            let foreignRequest = PDFReaderUIKitNavigation(document: replacement, pageIndex: 0, selection: foreignSelection)
            expect(!coordinator.navigate(foreignRequest, in: view), "A selection from a different PDF is rejected.")
        }
        let reportsBeforeDetach = pageReports.count
        let selectionsBeforeDetach = selections.count
        coordinator.detach()
        NotificationCenter.default.post(name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: view)
        await settle()
        expect(pageReports.count == reportsBeforeDetach && selections.count == selectionsBeforeDetach,
               "A detached reader never reports late native notifications.")
        expect((0..<document.pageCount).allSatisfy { document.page(at: $0)?.annotations.isEmpty == true },
               "Installing, navigating and selecting never create annotations.")
        await verifyReentrantReports(expect: expect)
        await verifyRemounts(expect: expect)
        await verifyLateWindowLocations(expect: expect)
        await verifyOverlayGeometry(expect: expect)
        await verifyOffsetsAndWidth(expect: expect)
        return (checks, failures)
    }

    private static func verifyReentrantReports(expect: (Bool, String) -> Void) async {
        let document = fixture(), replacement = fixture()
        let firstView = PDFView(frame: CGRect(x: 0, y: 0, width: 768, height: 900))
        firstView.displayMode = .singlePageContinuous
        let coordinator = PDFReaderUIKitView.Coordinator()
        var oldZoomReports = 0, oldSelectionReports = 0
        var didReplace = false
        coordinator.onPageChanged = { pdf, _ in
            guard pdf === document, !didReplace else { return }
            didReplace = true
            coordinator.install(replacement, in: firstView)
        }
        coordinator.onZoomChanged = { pdf, _, _ in if pdf === document { oldZoomReports += 1 } }
        coordinator.onSelectionChanged = { pdf, _, _ in if pdf === document { oldSelectionReports += 1 } }
        coordinator.attach(to: firstView); coordinator.install(document, in: firstView)
        firstView.layoutDocumentView()
        await settle()
        expect(didReplace && firstView.document === replacement && oldZoomReports == 0 && oldSelectionReports == 0,
               "Replacing a PDF inside its page callback stops the same report batch's old zoom and selection callbacks.")
        coordinator.detach()

        guard let oldSelection = document.findString("First page passage", withOptions: []).first,
              let newSelection = document.findString("Second page passage", withOptions: []).first else {
            expect(false, "Reentrant native fixtures require real selectable PDF text."); return
        }
        let secondView = PDFView(frame: firstView.frame)
        secondView.displayMode = .singlePageContinuous
        var didRemount = false
        var scales: [Double] = [], texts: [String?] = []
        coordinator.onPageChanged = { _, _ in
            guard !didRemount else { return }
            didRemount = true
            coordinator.attach(to: secondView)
            coordinator.install(document, in: secondView, initialReadingState: .init(
                document: document, pageIndex: 1, selection: newSelection, zoom: .percent(150)))
            secondView.layoutDocumentView()
        }
        coordinator.onZoomChanged = { _, percent, _ in scales.append(percent) }
        coordinator.onSelectionChanged = { _, _, snapshot in texts.append(snapshot?.text) }
        coordinator.attach(to: firstView)
        coordinator.install(document, in: firstView, initialReadingState: .init(
            document: document, pageIndex: 0, selection: oldSelection, zoom: .percent(125)))
        firstView.layoutDocumentView()
        await settle()
        expect(didRemount && secondView.document === document && !scales.isEmpty
               && scales.allSatisfy { abs($0 - 150) < 0.01 },
               "Remounting the same PDF inside a page callback rejects the previous installation's zoom.")
        expect(!texts.isEmpty && texts.allSatisfy { $0 == "Second page passage" },
               "Document identity alone cannot permit the previous native view's selection after a same-PDF remount.")
        let foreignView = PDFView(frame: firstView.frame)
        coordinator.install(replacement, in: foreignView)
        expect(foreignView.document == nil && secondView.document === document,
               "Installation cannot mutate a PDFView outside this coordinator's attached host.")
        expect(!coordinator.navigate(.init(document: document, pageIndex: 0), in: foreignView),
               "Navigation cannot operate through a different native view with the same document argument.")
        coordinator.detach()
    }

    private static func verifyRemounts(expect: (Bool, String) -> Void) async {
        let document = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearReaderRemount-\(UUID())")
        let suiteName = "DogearReaderRemount.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            expect(false, "The remount fixture requires isolated defaults."); return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let workspace: IPadGroupWorkspace
        do {
            let feedback = OperationFeedbackCenter(userDefaults: defaults)
            let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("recovery"))
            let store = PDFDocumentStore(feedbackCenter: feedback,
                metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("metadata.json")),
                aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("groups.json")),
                workingCopyStore: try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies")),
                saveQueue: queue, accessCoordinator: DocumentAccessCoordinator(saveQueue: queue),
                exportPresenter: IPadDocumentExportPresenter())
            workspace = IPadGroupWorkspace(id: UUID(), groupID: UUID(), documentStore: store, feedbackCenter: feedback)
        } catch {
            expect(false, "The remount fixture could not isolate its services: \(error.localizedDescription)")
            return
        }
        workspace.document.document = document
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 768, height: 900))
        view.autoScales = true; view.displayMode = .singlePageContinuous
        let coordinator = PDFReaderUIKitView.Coordinator()
        var accepted: [UUID] = []
        var scales: [(Double, Bool)] = []
        coordinator.onPageChanged = { pdf, page in
            if workspace.document.document === pdf { workspace.document.recordCurrentPage(page) }
        }
        coordinator.onZoomChanged = { pdf, percent, isFit in
            guard workspace.document.document === pdf else { return }
            workspace.zoomPercent = percent; workspace.zoomIsFit = isFit
            scales.append((percent, isFit))
        }
        coordinator.onSelectionChanged = { pdf, selection, snapshot in
            guard workspace.document.document === pdf else { return }
            workspace.selection = selection; workspace.document.recordTextSelection(snapshot)
        }
        coordinator.onNavigationAccepted = { pdf, id in
            accepted.append(id); workspace.acknowledgeNavigation(in: pdf, requestID: id)
        }
        coordinator.attach(to: view)
        coordinator.install(document, in: view)
        view.layoutDocumentView()
        await settle()
        workspace.navigate(pageIndex: 0)
        let original = workspace.pendingNavigation!
        expect(coordinator.navigate(original, in: view), "The workspace's initial navigation is accepted.")
        expect(original.isAccepted && workspace.pendingNavigation == nil,
               "A non-observable receipt immediately stops an accepted request being redelivered.")
        expect(accepted.isEmpty && workspace.navigation?.id == original.id,
               "Native acceptance does not publish its acknowledgement synchronously.")
        await settle()
        expect(accepted == [original.id] && workspace.navigation == nil,
               "Deferred acceptance clears only the matching workspace request.")

        guard let firstPageSelection = document.findString("First page passage", withOptions: []).first else {
            expect(false, "The remount fixture must expose selectable text.")
            coordinator.detach(); return
        }
        view.autoScales = false; view.scaleFactor = 1.25
        view.go(to: document.page(at: 1)!)
        view.setCurrentSelection(firstPageSelection, animate: false)
        await settle()
        expect(workspace.document.currentPageIndex == 1 && !workspace.zoomIsFit
               && abs(workspace.zoomPercent - 125) < 0.01,
               "User reading position and actual custom zoom replace the initial command state.")
        expect(workspace.document.currentTextSelection?.pageNumbers == [1],
               "A selection may remain on a different page from the current reading position.")
        let state = workspace.readingState(for: document)
        coordinator.detach()

        // A representable may install before UIKit assigns its final dimensions.
        let remountedView = PDFView(frame: .zero)
        remountedView.autoScales = true; remountedView.displayMode = .singlePageContinuous
        let remounted = PDFReaderUIKitView.Coordinator()
        remounted.attach(to: remountedView)
        remounted.install(document, in: remountedView, initialReadingState: state)
        if let pending = workspace.pendingNavigation { remounted.navigate(pending, in: remountedView) }
        remountedView.frame = view.frame
        remountedView.layoutDocumentView()
        await settle()
        expect(remountedView.currentPage === document.page(at: 1),
               "A reader mounted before layout resumes the actual page instead of the historical command.")
        expect(!remountedView.autoScales && abs(remountedView.scaleFactor - 1.25) < 0.01,
               "A reader mounted before layout resumes the actual percentage zoom.")
        expect(remountedView.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) }
               == workspace.document.currentTextSelection,
               "Remount restores the permitted native selection without navigating to its earlier page.")
        remounted.install(document, in: remountedView,
                          initialReadingState: .init(document: document, pageIndex: 0, zoom: .fit))
        expect(remountedView.currentPage === document.page(at: 1) && !remountedView.autoScales,
               "Ordinary updates do not reapply initial reading state over user navigation.")
        workspace.document.recordTextSelection(nil)
        expect(workspace.readingState(for: document).selection == nil,
               "A cleared shared selection cannot be resurrected from a retained native selection.")
        remounted.detach()

        // Keep the production owner's newer request while an earlier acceptance
        // is awaiting delivery; then accept two requests in the same transaction.
        workspace.navigate(pageIndex: 0)
        let older = workspace.pendingNavigation!
        coordinator.attach(to: view); coordinator.install(document, in: view)
        coordinator.navigate(older, in: view)
        workspace.navigate(pageIndex: 1)
        let newer = workspace.pendingNavigation!
        await settle()
        expect(workspace.navigation?.id == newer.id && workspace.pendingNavigation?.id == newer.id,
               "An older deferred acknowledgement cannot clear a newer workspace request.")
        coordinator.navigate(newer, in: view)
        workspace.navigate(pageIndex: 1, zoom: .fit)
        let latest = workspace.pendingNavigation!
        coordinator.navigate(latest, in: view)
        await settle()
        expect(!accepted.contains(newer.id) && accepted.filter { $0 == latest.id }.count == 1,
               "Only the latest accepted request in an installation receives deferred acknowledgement.")
        let fittedPercent = Double(view.scaleFactor) * 100
        workspace.navigate(pageIndex: 1, zoom: .percent(fittedPercent))
        coordinator.navigate(workspace.pendingNavigation!, in: view)
        await settle()
        expect(scales.last?.1 == false && scales.last.map { abs($0.0 - fittedPercent) < 0.01 } == true,
               "Native fit mode changes are reported even when the percentage is unchanged.")

        workspace.navigate(pageIndex: 0)
        let replaced = workspace.pendingNavigation!
        coordinator.navigate(replaced, in: view)
        let replacement = fixture()
        workspace.document.document = replacement
        workspace.navigate(pageIndex: 1)
        let replacementRequest = workspace.pendingNavigation!
        coordinator.install(replacement, in: view)
        await settle()
        expect(!accepted.contains(replaced.id) && workspace.navigation?.id == replacementRequest.id,
               "A replaced document rejects an old acceptance without clearing the new document's request.")
        workspace.acknowledgeNavigation(in: document, requestID: replaced.id)
        expect(workspace.navigation?.id == replacementRequest.id,
               "The workspace also rejects a stale document acknowledgement independently of the native host.")
        coordinator.navigate(replacementRequest, in: view)
        coordinator.detach()
        await settle()
        expect(!accepted.contains(replacementRequest.id) && replacementRequest.isAccepted
               && workspace.pendingNavigation == nil,
               "Detaching before acknowledgement prevents callbacks while the receipt still prevents replay.")

        let previewView = PDFView(frame: view.frame)
        previewView.displayMode = .singlePageContinuous
        let preview = PDFReaderUIKitView.Coordinator()
        preview.attach(to: previewView); preview.install(replacement, in: previewView)
        expect(preview.navigate(replacementRequest, in: previewView),
               "A detached preview retains navigation acceptance scoped to its own native installation.")
        await settle()
        expect(previewView.currentPage === replacement.page(at: 1),
               "A detached preview still opens its explicit evidence anchor.")
        let invalid = PDFReaderUIKitNavigation(document: replacement, pageIndex: 99)
        expect(!preview.navigate(invalid, in: previewView) && !invalid.isAccepted,
               "Rejected navigation never consumes a request receipt.")
        let foreign = PDFReaderUIKitNavigation(document: document, pageIndex: 0)
        expect(!preview.navigate(foreign, in: previewView) && !foreign.isAccepted,
               "A foreign document request remains unaccepted.")
        preview.detach()
        workspace.document.releaseEditorAccess()
        _ = workspace.state.finishClosing()
    }

    private static func verifyOffsetsAndWidth(expect: (Bool, String) -> Void) async {
        for text in ["", "0", "-1", "4", "1.5", "abc", "999999999999999999999"] {
            expect(PDFPageNumberInput.pageIndex(text, pageCount: 3) == nil, "Page entry rejects invalid input: \(text)")
        }
        expect(PDFPageNumberInput.pageIndex(" 2 ", pageCount: 3) == 1, "Page input accepts a valid one-based page, including surrounding whitespace.")
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            expect(false, "Offset fixtures require an actual scene."); return
        }
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.frame = CGRect(x: 0, y: 0, width: 700, height: 700); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKey?.makeKey() }
        for rotation in [0, 90, 180, 270] {
            let document = fixture(), page = document.page(at: 1)!
            page.setBounds(CGRect(x: 30, y: 40, width: 530, height: 660), for: .cropBox); page.rotation = rotation
            let view = UIKitReaderPDFView(frame: CGRect(x: 0, y: 0, width: 480, height: 440))
            view.displayMode = .singlePageContinuous; view.displayBox = .cropBox
            controller.view.addSubview(view)
            let host = PDFReaderUIKitView.Coordinator()
            var observed: (Int, PDFPageOffset)?, mode: PDFZoomState?
            host.onReadingPositionChanged = { pdf, index, offset in if pdf === document { observed = (index, offset) } }
            host.onZoomModeChanged = { pdf, zoom in if pdf === document { mode = zoom } }
            host.attach(to: view)
            host.install(document, in: view, initialReadingState: .init(document: document, pageIndex: 1, zoom: .percent(200), pageOffset: .init(x: 150, y: 450)))
            view.layoutIfNeeded(); await settle(); view.layoutIfNeeded(); await settle()
            guard let position = observed else { expect(false, "No offset report at rotation \(rotation)"); host.detach(); view.removeFromSuperview(); continue }
            expect(position.0 == 1 && mode?.mode == .custom && abs(view.scaleFactor - 2) < 0.01, "Native crop/rotation \(rotation) reports page-point position and custom zoom.")
            host.detach(); view.removeFromSuperview()
            let restored = UIKitReaderPDFView(frame: .zero), restore = PDFReaderUIKitView.Coordinator()
            restored.displayMode = .singlePageContinuous; restored.displayBox = .cropBox
            var recovered: PDFPageOffset?
            restore.onReadingPositionChanged = { pdf, index, offset in if pdf === document && index == position.0 { recovered = offset } }
            restore.attach(to: restored)
            restore.install(document, in: restored, initialReadingState: .init(document: document, pageIndex: position.0, zoom: .percent(200), pageOffset: position.1))
            await settle()
            expect(recovered == nil, "Zero layout cannot publish a premature offset at rotation \(rotation).")
            restored.frame = CGRect(x: 0, y: 0, width: 480, height: 440); controller.view.addSubview(restored)
            restored.layoutIfNeeded(); await settle(); restored.layoutIfNeeded(); await settle()
            expect(recovered.map { abs($0.x - position.1.x) < 1 && abs($0.y - position.1.y) < 1 } == true,
                "Page-point restore retains horizontal/vertical viewport at rotation \(rotation). expected=\(position.1), actual=\(String(describing: recovered))")
            restore.onZoomModeChanged = { _, value in mode = value }
            _ = restore.navigate(.init(document: document, pageIndex: 1, zoom: .fitWidth), in: restored)
            await settle(); restored.layoutIfNeeded(); await settle()
            let expectedWidth = restored.bounds.width - restored.pageBreakMargins.left - restored.pageBreakMargins.right
            expect(mode?.mode == .fitWidth && !restored.autoScales && abs(restored.convert(page.bounds(for: .cropBox), from: page).width - expectedWidth) < 1,
                "Fit Width uses actual rotated CropBox width rather than Fit Page at rotation \(rotation). mode=\(String(describing: mode))")
            restored.frame.size.width = 420; restored.setNeedsLayout(); restored.layoutIfNeeded(); await settle()
            expect(mode?.mode == .fitWidth && abs(restored.convert(page.bounds(for: .cropBox), from: page).width - (420 - restored.pageBreakMargins.left - restored.pageBreakMargins.right)) < 1,
                "Fit Width follows a native viewport resize at rotation \(rotation).")
            _ = restore.navigate(.init(document: document, pageIndex: 1, zoom: .percent(187)), in: restored)
            await settle(); restored.frame.size.width = 460; restored.setNeedsLayout(); restored.layoutIfNeeded(); await settle()
            expect(mode?.mode == .custom && abs(restored.scaleFactor - 1.87) < 0.01, "Resize does not reset custom zoom at rotation \(rotation).")
            restore.detach(); restored.removeFromSuperview()
        }
        let view = UIKitReaderPDFView(frame: .zero), coordinator = PDFReaderUIKitView.Coordinator(), document = fixture()
        coordinator.attach(to: view)
        coordinator.install(document, in: view, initialReadingState: .init(document: document, pageIndex: 2, pageOffset: .init(x: 90, y: 400)))
        let search = PDFReaderUIKitNavigation(document: document, pageIndex: 1, selection: document.findString("Second", withOptions: []).first)
        _ = coordinator.navigate(search, in: view); search.cancel(); coordinator.cancelRevokedNavigation()
        let latest = PDFReaderUIKitNavigation(document: document, pageIndex: 0, zoom: .percent(150))
        _ = coordinator.navigate(latest, in: view)
        view.frame = CGRect(x: 0, y: 0, width: 480, height: 440); controller.view.addSubview(view)
        view.layoutIfNeeded(); await settle(); view.layoutIfNeeded(); await settle()
        expect(search.isCancelled && latest.isAccepted && view.currentPage === document.page(at: 0),
            "Cancelled search and old initial offset cannot override the newest explicit navigation after late layout.")
        coordinator.detach(); view.removeFromSuperview()
    }

    private static func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private static func verifyLateWindowLocations(expect: (Bool, String) -> Void) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearLateReader-\(UUID())")
        let suite = "DogearLateReader.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite),
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            expect(false, "Late-window fixtures require isolated defaults and the real application scene."); return
        }
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.frame = CGRect(x: 0, y: 0, width: 768, height: 700); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKey?.makeKey() }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let document = fixture(), url = root.appendingPathComponent("late.pdf")
            let data = document.dataRepresentation()!; try data.write(to: url)
            let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
            let storage = try LibraryJSONStore(stateURL: root.appendingPathComponent("library.json"))
            let library = LibraryStore(userDefaults: defaults, storage: storage, workingCopyStore: copies)
            let file = library.upsertOpenedURLs([url], refreshBookmark: false)[0]
            for index in [1, 2] {
                library.updateLastPage(for: url, pageIndex: index)
                let view = UIKitReaderPDFView(frame: .zero), coordinator = PDFReaderUIKitView.Coordinator()
                view.autoScales = true; view.displayMode = .singlePageContinuous
                var reports: [Int] = []
                coordinator.onPageChanged = { pdf, page in
                    guard pdf === document else { return }
                    reports.append(page); library.updateLastPage(for: url, pageIndex: page)
                }
                coordinator.attach(to: view)
                coordinator.install(document, in: view, initialReadingState: .init(document: document, pageIndex: index, zoom: .fit))
                await settle()
                expect(view.bounds.isEmpty && view.window == nil && reports.isEmpty
                    && library.state.files.first(where: { $0.id == file.id })?.lastPageIndex == index,
                    "A zero-frame, windowless fit installation does not publish transient page zero over saved page \(index + 1). reports=\(reports)")
                view.frame = window.bounds; controller.view.addSubview(view); view.layoutIfNeeded(); view.layoutDocumentView()
                await settle(); view.layoutIfNeeded(); await settle()
                expect(view.currentPage === document.page(at: index) && view.autoScales
                    && !reports.isEmpty && reports.allSatisfy { $0 == index },
                    "Late window layout restores actual fit page \(index + 1) before publishing any saved reading position. reports=\(reports), actual=\(view.currentPage.map { document.index(for: $0) } ?? -1)")
                expect(library.flushPendingPersistence()
                    && LibraryStore(userDefaults: defaults, storage: storage, workingCopyStore: copies).state.files.first(where: { $0.id == file.id })?.lastPageIndex == index,
                    "Library JSON reload retains the real restored fit page \(index + 1).")
                let firstPage = PDFReaderUIKitNavigation(document: document, pageIndex: 0)
                let queued = coordinator.navigate(firstPage, in: view)
                await settle()
                expect(queued && firstPage.isAccepted && view.currentPage === document.page(at: 0) && reports.last == 0
                    && library.state.files.first(where: { $0.id == file.id })?.lastPageIndex == 0,
                    "A subsequent legitimate first-page command still reports and saves page zero.")
                coordinator.detach(); view.removeFromSuperview()
            }
            library.updateLastPage(for: url, pageIndex: 1)
            let view = UIKitReaderPDFView(frame: .zero), coordinator = PDFReaderUIKitView.Coordinator()
            view.autoScales = true; view.displayMode = .singlePageContinuous
            var reports: [Int] = [], acknowledgements: [UUID] = []
            coordinator.onPageChanged = { pdf, page in
                guard pdf === document else { return }
                reports.append(page); library.updateLastPage(for: url, pageIndex: page)
            }
            coordinator.onNavigationAccepted = { pdf, id in if pdf === document { acknowledgements.append(id) } }
            coordinator.attach(to: view)
            coordinator.install(document, in: view, initialReadingState: .init(document: document, pageIndex: 0, zoom: .percent(125)))
            let older = PDFReaderUIKitNavigation(document: document, pageIndex: 2)
            let latest = PDFReaderUIKitNavigation(document: document, pageIndex: 1)
            let olderQueued = coordinator.navigate(older, in: view), latestQueued = coordinator.navigate(latest, in: view)
            await settle()
            expect(olderQueued && latestQueued && !older.isAccepted && !latest.isAccepted && acknowledgements.isEmpty && reports.isEmpty,
                "Zero-frame explicit navigation replaces the pending initial location without prematurely accepting or reporting either request.")
            view.frame = window.bounds; controller.view.addSubview(view); view.layoutIfNeeded(); view.layoutDocumentView()
            await settle(); view.layoutIfNeeded(); await settle()
            expect(view.currentPage === document.page(at: 1) && !view.autoScales && abs(view.scaleFactor - 1.25) < 0.01
                && !older.isAccepted && latest.isAccepted && acknowledgements == [latest.id]
                && !reports.isEmpty && reports.allSatisfy { $0 == 1 },
                "The latest delayed request wins after window layout and inherits the saved percentage zoom when its own zoom is absent. reports=\(reports)")
            expect(library.flushPendingPersistence()
                && LibraryStore(userDefaults: defaults, storage: storage, workingCopyStore: copies).state.files.first(where: { $0.id == file.id })?.lastPageIndex == 1,
                "Initial page zero plus a delayed Library page-two navigation cannot rewrite the saved JSON to page zero.")
            coordinator.detach(); view.removeFromSuperview()

            let interruptedView = UIKitReaderPDFView(frame: .zero), interrupted = PDFReaderUIKitView.Coordinator()
            interruptedView.autoScales = true; interruptedView.displayMode = .singlePageContinuous
            var interruptedAcks: [UUID] = []
            interrupted.onNavigationAccepted = { pdf, id in if pdf === document { interruptedAcks.append(id) } }
            interrupted.attach(to: interruptedView); interrupted.install(document, in: interruptedView)
            let cancelled = PDFReaderUIKitNavigation(document: document, pageIndex: 1, zoom: .fit)
            _ = interrupted.navigate(cancelled, in: interruptedView)
            interruptedView.frame = window.bounds; controller.view.addSubview(interruptedView); interruptedView.layoutIfNeeded()
            let secondPage = document.page(at: 1)!, glyph = secondPage.characterBounds(at: 0)
            let tapped = interrupted.inputAdapter.selectWord(at: interruptedView.convert(CGPoint(x: glyph.midX, y: glyph.midY), from: secondPage))
            interruptedView.go(to: document.page(at: 0)!); interruptedView.layoutDocumentView(); await settle()
            expect(tapped && cancelled.isAccepted && interruptedAcks == [cancelled.id]
                && interruptedView.currentPage === document.page(at: 0),
                "Native reading interaction consumes a queued request and later layout cannot replay its old destination.")
            interrupted.detach(); interruptedView.removeFromSuperview()

            let detachedView = UIKitReaderPDFView(frame: .zero), detached = PDFReaderUIKitView.Coordinator()
            detached.attach(to: detachedView); detached.install(document, in: detachedView)
            let retained = PDFReaderUIKitNavigation(document: document, pageIndex: 2)
            _ = detached.navigate(retained, in: detachedView); detached.detach(); await settle()
            expect(!retained.isAccepted, "Detaching an unready reader preserves its unexecuted request for the next installation.")
            expect(try Data(contentsOf: url) == data && (0..<document.pageCount).allSatisfy { document.page(at: $0)?.annotations.isEmpty == true },
                "Layout readiness, request consumption and saved reading-position reports preserve PDF bytes and annotations.")
        } catch { expect(false, "Late-window fixture failed: \(error.localizedDescription)") }
    }

    private static func verifyOverlayGeometry(expect: (Bool, String) -> Void) async {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            expect(false, "Native overlay fixtures require the current application scene."); return
        }
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.frame = CGRect(x: 0, y: 0, width: 768, height: 700); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKey?.makeKey() }
        let document = fixture(), page = document.page(at: 0)!
        let view = UIKitReaderPDFView(frame: window.bounds), coordinator = PDFReaderUIKitView.Coordinator()
        controller.view.addSubview(view); view.displayMode = .singlePageContinuous
        var layouts: [(PDFDocument, PDFPage, PDFReaderUIKitOverlayLayout?)] = []
        coordinator.onOverlayLayout = { layouts.append(($0, $1, $2)) }
        coordinator.attach(to: view); coordinator.install(document, in: view)
        let bounds = CGRect(x: 100, y: 560, width: 120, height: 80)
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation; view.autoScales = false; view.scaleFactor = 1.1; view.layoutDocumentView(); view.go(to: bounds, on: page)
            coordinator.configureOverlay(.init(document: document, page: page, bounds: bounds))
            await settle(); view.layoutIfNeeded(); await settle()
            let layout = layouts.last?.2
            let midpoint = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
            let mapped = layout.map { midpoint.applying($0.pageToViewportTransform) }
            let expected = view.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: page)
            expect(layouts.last?.0 === document && layouts.last?.1 === page && layout?.viewportFrame == view.convert(bounds, from: page)
                && mapped.map { abs($0.x - expected.x) < 0.01 && abs($0.y - expected.y) < 0.01 } == true
                && layout?.scale == view.scaleFactor,
                "Native overlay frame and top-left-unit transform follow real PDFKit rotation \(rotation) and custom zoom.")
        }
        page.rotation = 0; view.layoutDocumentView(); view.go(to: bounds, on: page); await settle()
        let larger = bounds.insetBy(dx: -15, dy: -10)
        coordinator.configureOverlay(.init(document: document, page: page, bounds: bounds))
        coordinator.configureOverlay(.init(document: document, page: page, bounds: larger))
        await settle()
        expect(layouts.last?.2?.viewportFrame == view.convert(larger, from: page),
            "A superseded overlay size cannot deliver its old deferred frame over the latest target bounds.")
        if let scroll = nativeScroll(in: view) {
            scroll.contentOffset.y += 20; await settle()
            expect(layouts.last?.2?.viewportFrame == view.convert(larger, from: page),
                "Native scroll content-offset observation keeps the overlay in the PDFView viewport coordinate space.")
        } else { expect(false, "The overlay fixture must expose PDFKit's public UIScrollView.") }
        coordinator.configureOverlay(.init(document: document, page: document.page(at: 2)!, bounds: larger)); await settle()
        expect(layouts.last?.1 === document.page(at: 2) && layouts.last?.2 == nil,
            "A target wholly outside the current viewport reports a nil overlay frame.")
        coordinator.configureOverlay(.init(document: document, page: page, bounds: bounds)); await settle()
        coordinator.detach(); await settle()
        expect(layouts.last?.0 === document && layouts.last?.1 === page && layouts.last?.2 == nil,
            "Detach explicitly clears the previous target's view-only overlay frame.")
        expect((0..<document.pageCount).allSatisfy { document.page(at: $0)?.annotations.isEmpty == true },
            "Overlay geometry never creates, hides or edits PDF annotations.")
    }

    private static func nativeScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews { if let scroll = nativeScroll(in: child) { return scroll } }
        return nil
    }

    private static func fixture() -> PDFDocument {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            for text in ["First page passage", "Second page passage", "Third page passage"] {
                context.beginPage()
                (text as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
        return PDFDocument(data: data)!
    }
}
#endif
