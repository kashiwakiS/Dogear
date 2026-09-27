import AppKit
import PDFKit

/// Real PDFKit page notifications and disposable Library stores. The fixture
/// exercises the same coordinator navigation entry points as the reader.
@MainActor
enum ReadingNavigationDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        func settle() async {
            for _ in 0..<3 {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearReadingNavigation-\(UUID())")
        let domain = "Dogear.ReadingNavigation.\(UUID())"
        guard let defaults = UserDefaults(suiteName: domain) else {
            return (1, ["Could not create isolated reading-navigation defaults."])
        }
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: domain)
        }
        do {
            let storage = try LibraryJSONStore(stateURL: root.appendingPathComponent("library.json"))
            let source = LibraryFile(displayName: "navigation.pdf", canonicalPath: root.appendingPathComponent("navigation.pdf").path,
                lastPageIndex: 6)
            let other = LibraryFile(displayName: "other.pdf", canonicalPath: root.appendingPathComponent("other.pdf").path,
                lastPageIndex: 5)
            try storage.save(LibraryState(files: [source, other]))
            let library = LibraryStore(userDefaults: defaults, storage: storage,
                readingPositionSaveDelay: 60)
            defer { library.flushPendingPersistence() }
            let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("recovery"))
            defer { queue.waitUntilDrained() }
            let store = PDFDocumentStore(feedbackCenter: OperationFeedbackCenter(userDefaults: defaults),
                metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("metadata.json")),
                aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("groups.json")),
                workingCopyStore: try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies")),
                saveQueue: queue, accessCoordinator: DocumentAccessCoordinator(saveQueue: queue))
            let document = fixtureDocument()
            store.document = document
            store.selectedPDFURL = source.url
            store.currentPageIndex = source.lastPageIndex
            let container = PDFReaderContainerView(frame: NSRect(x: 0, y: 0, width: 720, height: 500))
            let view = container.pdfView
            view.frame = container.bounds
            view.displayMode = .singlePageContinuous
            view.autoScales = false
            view.scaleFactor = 1
            var reported: [Int] = []
            let coordinator = PDFKitView.Coordinator(displayStyle: .continuous,
                onPageChanged: { page in
                    reported.append(page)
                    store.recordCurrentPage(page)
                    if let url = store.selectedPDFURL { library.updateLastPage(for: url, pageIndex: page) }
                }, onScaleChanged: { _, _ in }, onSelectionChanged: { _ in })
            coordinator.observePageChanges(for: view, in: container)
            defer { coordinator.stopObserving() }
            coordinator.beginViewUpdate()
            coordinator.installDocument(document, targetPageIndex: source.lastPageIndex, in: container)
            view.layoutDocumentView()
            coordinator.observeLiveScrolling(for: view, in: container)
            coordinator.endViewUpdate(in: container)
            await settle()
            check(reported.isEmpty && view.currentPage === document.page(at: 6)
                    && library.state.files.first(where: { $0.id == source.id })?.lastPageIndex == 6,
                  "Restoring a saved PDF position published a transient first page or lost the destination.")

            func libraryPage(_ file: LibraryFile? = nil) -> Int? {
                library.state.files.first(where: { $0.id == (file?.id ?? source.id) })?.lastPageIndex
            }
            func navigatePage() async {
                coordinator.beginViewUpdate()
                coordinator.navigate(to: store.currentPageIndex, in: container)
                coordinator.endViewUpdate(in: container)
                await settle()
            }
            store.goToPageNumber(4)
            coordinator.beginViewUpdate()
            coordinator.navigate(to: store.currentPageIndex, in: container)
            check(reported.isEmpty && libraryPage() == 6,
                  "Programmatic native notifications published Library state inside a representable update.")
            coordinator.endViewUpdate(in: container)
            await settle()
            check(reported == [3] && store.currentPageIndex == 3 && libraryPage() == 3
                    && view.currentPage === document.page(at: 3),
                  "A manually entered page updated the reader but did not notify Library exactly once.")
            let saved = library.flushPendingPersistence()
            let diskPage = try storage.load()?.files.first(where: { $0.id == source.id })?.lastPageIndex
            check(saved && diskPage == 3, "The manual page destination did not survive a Library reload.")

            store.goToRelativePage(offset: -1)
            await navigatePage()
            check(libraryPage() == 2 && reported.suffix(1) == [2], "Previous-page navigation did not save its destination.")
            store.goToRelativePage(offset: 1)
            await navigatePage()
            check(libraryPage() == 3 && reported.suffix(2) == [2, 3], "Next-page navigation did not save its destination.")
            store.goToFirstPage()
            await navigatePage()
            store.goToPageNumber(document.pageCount)
            await navigatePage()
            check(libraryPage() == 7 && reported.suffix(2) == [0, 7], "First/last-page navigation did not save both destinations.")

            store.navigate(to: DogearMarker(documentID: UUID(), pageIndex: 1, title: "Fixture", sortIndex: 0))
            await navigatePage()
            check(libraryPage() == 1 && reported.last == 1, "Dog-ear navigation did not update Library.")
            let outline = DocumentOutlineEntry(id: "fixture", title: "Outline", level: 0,
                target: PDFNavigationTarget(pageIndex: 4, point: CGPoint(x: 50, y: 850), relativePagePosition: nil),
                source: .pdfBookmark)
            store.navigate(to: outline)
            coordinator.navigate(to: outline.target, in: container)
            await settle()
            check(libraryPage() == 4 && reported.last == 4, "Outline destination navigation did not update Library.")

            let researchTarget = PDFNavigationTarget(pageIndex: 2, point: CGPoint(x: 70, y: 800), relativePagePosition: nil)
            coordinator.navigate(to: researchTarget, in: container)
            await settle()
            check(libraryPage() == 2 && store.currentPageIndex == 2 && reported.last == 2,
                  "A Research page-space destination did not update the reader and Library together.")
            let beforeRepeated = reported.count
            for _ in 0..<100 {
                NotificationCenter.default.post(name: .PDFViewPageChanged, object: view)
                coordinator.navigate(to: 2, in: container)
            }
            await settle()
            check(reported.count == beforeRepeated,
                  "Repeated same-page notifications or representable navigation caused a callback loop.")
            for y in stride(from: 790, through: 740, by: -10) {
                view.goToOutlineTarget(PDFNavigationTarget(pageIndex: 2, point: CGPoint(x: 70, y: y), relativePagePosition: nil))
            }
            await settle()
            check(reported.count == beforeRepeated && libraryPage() == 2,
                  "Scrolling within one page republished Library page state.")

            let beforeRapid = reported.count
            coordinator.navigate(to: 6, in: container)
            coordinator.navigate(to: 4, in: container)
            await settle()
            check(reported.count == beforeRapid + 1 && reported.last == 4 && libraryPage() == 4,
                  "Superseded commands published intermediate pages instead of their final native destination.")
            coordinator.navigate(to: researchTarget, in: container)
            await settle()

            let replacement = fixtureDocument()
            let beforeReplacement = reported.count
            // Leave an old-document confirmation queued while switching both
            // the callback's source URL and the native document immediately.
            coordinator.navigate(to: 7, in: container)
            store.document = replacement
            store.selectedPDFURL = other.url
            store.currentPageIndex = other.lastPageIndex
            coordinator.beginViewUpdate()
            coordinator.installDocument(replacement, targetPageIndex: other.lastPageIndex, in: container)
            view.layoutDocumentView()
            coordinator.observeLiveScrolling(for: view, in: container)
            coordinator.endViewUpdate(in: container)
            await settle()
            check(reported.count == beforeReplacement && view.currentPage === replacement.page(at: 5)
                    && libraryPage(other) == 5 && libraryPage(source) == 2,
                  "Switching/restoring PDFs wrote the old or transient page into either Library file.")
            coordinator.navigate(to: 3, in: container)
            await settle()
            check(libraryPage(other) == 3 && libraryPage(source) == 2,
                  "Navigation after document replacement updated the wrong file.")
            let beforeStop = reported.count
            coordinator.navigate(to: 7, in: container)
            coordinator.stopObserving()
            await settle()
            check(reported.count == beforeStop && libraryPage(other) == 3,
                  "A dismantled reader delivered a pending page callback after its owner was released.")
        } catch {
            check(false, "Reading-navigation fixture failed: \(error.localizedDescription)")
        }
        return (checks, failures)
    }

    private static func fixtureDocument() -> PDFDocument {
        let document = PDFDocument()
        for _ in 0..<8 {
            let page = PDFPage()
            page.setBounds(NSRect(x: 0, y: 0, width: 600, height: 900), for: .mediaBox)
            page.setBounds(NSRect(x: 0, y: 0, width: 600, height: 900), for: .cropBox)
            document.insert(page, at: document.pageCount)
        }
        return document
    }
}
