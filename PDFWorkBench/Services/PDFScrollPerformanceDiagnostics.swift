import AppKit
import PDFKit

@MainActor
enum PDFScrollPerformanceDiagnostics {
    static func run() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        let document = PDFDocument()
        let page = ScrollTextProbePage()
        page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 900), for: .mediaBox)
        document.insert(page, at: 0)
        let cache = PDFReadingPositionCache()
        for y in 0..<120 {
            cache.update(PDFNavigationTarget(pageIndex: 0, point: CGPoint(x: 10, y: y),
                relativePagePosition: nil), for: document)
        }
        check(cache.position(for: document)?.point == CGPoint(x: 10, y: 119),
              "The command snapshot lost the latest same-page scroll offset.")
        check(cache.position(for: PDFDocument()) == nil && cache.position(for: nil) == nil,
              "A different/closed PDF inherited the previous document's offset.")

        let container = PDFReaderContainerView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        container.pdfView.document = document
        container.layoutSubtreeIfNeeded()
        container.pdfView.layoutDocumentView()
        func refreshRail(pageIndex: Int = 0, night: Bool = false) {
            container.updateOutlineOverlay(entries: [], aiHighlights: [], currentPageIndex: pageIndex,
                isLoading: false, isNightMode: night, onSelect: { _ in }, onSelectAIHighlight: { _ in })
            container.updateDogears([], currentPageIndex: pageIndex, pageCount: 1,
                isNightMode: night, onSelect: { _ in }, onToggleAtPage: { _ in })
        }
        refreshRail()
        let initialRenders = container.outlineRenderCount
        for _ in 0..<120 { refreshRail() }
        check(container.outlineRenderCount == initialRenders,
              "Unchanged reader updates rebuilt the outline hosting tree.")
        refreshRail(night: true)
        check(container.outlineRenderCount == initialRenders + 1,
              "Night appearance did not update the rail exactly once.")
        container.updateCurrentPageIndex(1)
        let afterPage = container.outlineRenderCount
        container.updateCurrentPageIndex(1)
        check(afterPage == initialRenders + 2 && container.outlineRenderCount == afterPage,
              "Page changes did not invalidate the rail once.")

        container.updateMarginCanvas(isVisible: true, isSupported: true,
            isNightMode: false, selectedAnnotationID: nil)
        page.textReadCount = 0
        for _ in 0..<120 { container.layoutMarginCanvas() }
        check(page.textReadCount == 0,
              "Scrolling pages without margin notes extracted full-page text.")
        check(container.marginCanvasView.isHidden,
              "An empty page displayed a margin canvas.")

        let note = PDFAnnotation(bounds: CGRect(x: 200, y: 500, width: 80, height: 20),
            forType: .freeText, withProperties: nil)
        note.contents = "Scrolling fixture note"
        page.addAnnotation(note)
        let coordinator = PDFKitView.Coordinator(displayStyle: .continuous,
            onPageChanged: { _ in }, onScaleChanged: { _, _ in }, onSelectionChanged: { _ in })
        coordinator.observeAnnotationChanges(for: container.pdfView, in: container)
        NotificationCenter.default.post(name: .dogearAnnotationsChanged, object: document)
        check(!note.shouldDisplay, "Annotation invalidation did not hide PDFKit's duplicate native note.")
        check(!container.marginCanvasView.isHidden, "A new note did not invalidate the margin presentation.")
        page.removeAnnotation(note)
        NotificationCenter.default.post(name: .dogearAnnotationsChanged, object: document)
        check(container.marginCanvasView.isHidden, "Removing the last note left a stale card.")

        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearScrollVisibility-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let defaultsName = "DogearScrollVisibility-\(UUID())"
            let defaults = UserDefaults(suiteName: defaultsName)!
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("recovery"))
            defer { queue.waitUntilDrained() }
            let store = PDFDocumentStore(
                feedbackCenter: OperationFeedbackCenter(userDefaults: defaults),
                metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("metadata.json")),
                aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("groups.json")),
                workingCopyStore: try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies")),
                saveQueue: queue, accessCoordinator: DocumentAccessCoordinator(saveQueue: queue))
            // Reuse the native view fixture; stores/persistence remain isolated.
            // URL-less documents are an existing supported store injection path.
            store.document = document
            let groupID = UUID()
            let highlight = PDFAnnotation(bounds: CGRect(x: 200, y: 500, width: 80, height: 20),
                forType: .highlight, withProperties: nil)
            highlight.contents = "AI visibility fixture comment"
            _ = highlight.setValue(AIAnnotationProvenance.makeUniqueName(groupID: groupID), forAnnotationKey: .name)
            page.addAnnotation(highlight)
            store.bindLibraryFile(UUID())
            let undo = UndoManager()
            undo.groupsByEvent = false
            store.setUndoManager(undo)
            check(!container.marginCanvasView.isHidden && store.selectedAnnotationID == nil,
                "The store visibility fixture did not show an unselected AI comment card.")
            store.setAIHighlightGroupVisible(groupID, isVisible: false)
            check(container.marginCanvasView.isHidden && container.marginCanvasView.cachedTextMeasurementCount == 0,
                "Hiding an unselected AI group left its comment card until the next scroll/layout.")
            store.setAIHighlightGroupVisible(groupID, isVisible: true)
            check(!container.marginCanvasView.isHidden && container.marginCanvasView.cachedTextMeasurementCount == 1,
                "Showing an AI group did not immediately restore its comment card.")
            store.setAllAIHighlightGroupsVisible(false)
            check(container.marginCanvasView.isHidden, "The AI master visibility toggle left a stale comment card.")
            store.setAllAIHighlightGroupsVisible(true)
            check(!container.marginCanvasView.isHidden && !undo.canUndo && !store.hasUnsavedChanges,
                "The AI master toggle failed to refresh, or added PDF dirty/Undo state.")
            if let item = store.annotations.first(where: { $0.aiGroupID == groupID }),
               let draft = store.highlightEditDraft(for: item) {
                undo.beginUndoGrouping()
                _ = store.updateHighlight(draft, color: draft.color, comment: "")
                undo.endUndoGrouping()
                check(container.marginCanvasView.isHidden, "Removing a highlight comment did not immediately remove its card.")
                undo.undo()
                check(!container.marginCanvasView.isHidden && highlight.contents == draft.comment,
                    "Undo of a comment edit did not immediately restore its card.")
                undo.redo()
                check(container.marginCanvasView.isHidden, "Redo of a comment edit left a stale card.")
                undo.undo()
            } else {
                check(false, "The AI comment fixture did not provide a real store edit target.")
            }
            undo.removeAllActions()
            page.addAnnotation(note)
            store.markAnnotationsChanged()
            check(!note.shouldDisplay && container.marginCanvasView.cachedTextMeasurementCount == 2,
                "A store note mutation did not hide the duplicate native note and show its card.")
            if let item = store.annotations.first(where: { $0.kind == .note }) {
                undo.beginUndoGrouping()
                store.removeAnnotation(item)
                undo.endUndoGrouping()
                check(container.marginCanvasView.cachedTextMeasurementCount == 1,
                    "Store note deletion left its margin card visible.")
                undo.undo()
                check(!note.shouldDisplay && container.marginCanvasView.cachedTextMeasurementCount == 2,
                    "Note Undo did not restore its card while keeping PDFKit's duplicate note hidden.")
                undo.redo()
                check(container.marginCanvasView.cachedTextMeasurementCount == 1,
                    "Note Redo left a stale margin card.")
            } else {
                check(false, "The note fixture did not provide a real store deletion target.")
            }
        } catch {
            check(false, "Isolated store visibility fixture failed: \(error)")
        }
        coordinator.stopObserving()
        return (checks, failures)
    }
}

private final class ScrollTextProbePage: PDFPage {
    var textReadCount = 0
    override var string: String? {
        textReadCount += 1
        return super.string
    }
}
