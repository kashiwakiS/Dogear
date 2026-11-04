import AppKit
import Combine
import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// Exercises the Mac input adapter and actual owning Store/Undo path using
/// native PDF text and isolated working copies; never opens a user document.
@MainActor
enum PDFManualHighlightHostDiagnostics {
    static func run() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }

        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearManualHighlight-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let defaultsName = "DogearManualHighlight-\(UUID())"
            let defaults = try require(UserDefaults(suiteName: defaultsName))
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("recovery"))
            defer { queue.waitUntilDrained() }
            let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
            let feedback = OperationFeedbackCenter(userDefaults: defaults)
            let store = PDFDocumentStore(feedbackCenter: feedback,
                metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("metadata.json")),
                aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("groups.json")),
                workingCopyStore: copies, saveQueue: queue, accessCoordinator: DocumentAccessCoordinator(saveQueue: queue))
            defer { store.releaseEditorAccess() }
            let originalURL = root.appendingPathComponent("original.pdf")
            let originalBytes = try require(try makeDocument().dataRepresentation())
            try originalBytes.write(to: originalURL)
            check(store.openPDF(from: originalURL), "The Store could not open the native fixture.")
            let document = try require(store.document)
            let pages = try (0..<document.pageCount).map { try require(document.page(at: $0)) }
            let selection = try require(pages[0].selection(for: NSRange(location: 0, length: pages[0].numberOfCharacters)))
            selection.add(try require(pages[1].selection(for: NSRange(location: 0, length: pages[1].numberOfCharacters))))
            let view = HighlightingPDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
            let undo = UndoManager()
            undo.groupsByEvent = false
            store.setUndoManager(undo)
            view.workspaceUndoManager = undo
            view.document = document
            defer { view.document = nil; undo.removeAllActions() }
            var createdTriggers: [FeedbackTrigger] = []
            var legacyMutationCount = 0
            var storeMutationCount = 0
            view.onCommitHighlight = { document, selection, trigger in
                let committed = store.addHighlights(from: selection, in: document, trigger: trigger)
                if committed { createdTriggers.append(trigger) }
                return committed
            }
            view.onUndoableAnnotationMutation = { _ in legacyMutationCount += 1 }
            let mutationObserver = NotificationCenter.default.publisher(for: .dogearAnnotationsChanged, object: document)
                .sink { _ in storeMutationCount += 1 }
            defer { mutationObserver.cancel() }
            view.setCurrentSelection(selection, animate: false)
            check(view.currentSelection?.string?.contains("Alpha") == true, "The native host did not retain the fixture selection.")
            check(pages.allSatisfy { $0.annotations.isEmpty }, "Selection presentation created an annotation.")
            undo.beginUndoGrouping()
            let committed = view.addHighlightToCurrentSelection(trigger: .toolbar)
            undo.endUndoGrouping()
            check(committed, "The native host rejected the shared multi-page highlight preparation.")
            let highlights = pages.flatMap(\.annotations)
            check(highlights.count == 2 && pages.allSatisfy { $0.annotations.count == 1 }, "The host did not create exactly one highlight per selected page.")
            check(highlights.allSatisfy { $0.type == "Highlight" }, "A manual selection was not written as standard highlights.")
            check(highlights.allSatisfy { ($0.contents ?? "").isEmpty }, "Manual creation placed its quote in the note comment.")
            check(highlights.map { $0.quadrilateralPoints?.count } == [8, 4], "The host lost multiline or cross-page quadrilateral geometry.")
            let quotes = zip(highlights, pages).map { PDFHighlightText.text(of: $0.0, on: $0.1) }
            check(quotes == ["Alpha selected line.\nBeta selected line.", "Gamma selected line."], "The host lost the selected source quotes.")
            check(view.currentSelection == nil, "A successful commit did not clear the native selection.")
            check(createdTriggers == [.toolbar] && storeMutationCount == 1 && feedback.currentFeedback?.trigger == .toolbar,
                "Creation feedback lost or duplicated its originating trigger or Store mutation.")
            check(undo.canUndo && undo.undoActionName == "Add Highlight", "The host did not register the original highlight Undo action.")
            let bounds = highlights.map(\.bounds)
            let points = highlights.map(\.quadrilateralPoints)
            undo.undo()
            check(pages.allSatisfy { $0.annotations.isEmpty } && highlights.allSatisfy { $0.page == nil }, "One Undo did not remove the whole cross-page batch.")
            check(!undo.canUndo && undo.canRedo, "The cross-page batch registered more than one Undo action.")
            check(storeMutationCount == 2 && legacyMutationCount == 0,
                "Undo did not notify its owning Store once or repeated the legacy view callback.")
            undo.redo()
            check(zip(pages, highlights).allSatisfy { page, highlight in page.annotations.first === highlight }, "Redo replaced or misplaced the native annotation objects.")
            check(highlights.map(\.bounds) == bounds && highlights.map(\.quadrilateralPoints) == points, "Redo changed the prepared highlight geometry.")
            check(createdTriggers == [.toolbar] && storeMutationCount == 3 && legacyMutationCount == 0,
                "Redo sent a second creation event or lost the Store mutation notification.")
            let copy = try require(document.dataRepresentationWithAIAnnotationsDisplayed().flatMap(PDFDocument.init(data:)))
            let copiedItems = AnnotationExtractor.annotationItems(in: copy)
            check(copiedItems.count == 2 && copiedItems.allSatisfy { $0.kind == .highlight && !$0.isAIGenerated && $0.note.isEmpty }, "Native serialization changed manual annotation kind, provenance or comment.")
            check(copiedItems.map(\.text) == quotes, "Native serialization or extraction lost the exact selected quotes.")
            check(pages.map { $0.string ?? "" } == (0..<copy.pageCount).map { copy.page(at: $0)?.string ?? "" }, "Highlight creation changed underlying page text.")
            queue.waitUntilDrained()
            let workingCopy = try require(PDFDocument(url: copies.workingCopyURL(forOriginalURL: originalURL)))
            check(AnnotationExtractor.annotationItems(in: workingCopy).map(\.text) == quotes,
                "The owning Store did not save the whole highlight batch to its working copy.")
            let finalOriginalBytes = try Data(contentsOf: originalURL)
            check(finalOriginalBytes == originalBytes, "Manual highlighting rewrote the original PDF.")
            undo.removeAllActions()
            let otherDocument = try makeDocument()
            let otherPage = try require(otherDocument.page(at: 0))
            let otherSelection = try require(otherPage.selection(for: NSRange(location: 0, length: otherPage.numberOfCharacters)))
            view.document = otherDocument
            view.setCurrentSelection(otherSelection, animate: false)
            check(!view.addHighlightToCurrentSelection(trigger: .keyboard(shortcut: "H"))
                && otherPage.annotations.isEmpty && !undo.canUndo,
                "A stale reader committed highlights into a document outside its Store.")
            view.document = document
            view.setCurrentSelection(selection, animate: false)
            store.releaseEditorAccess()
            check(!view.addHighlightToCurrentSelection(trigger: .keyboard(shortcut: "H"))
                && pages.flatMap(\.annotations).count == 2 && !undo.canUndo,
                "The native H shortcut bypassed a released write lease.")
            check(createdTriggers == [.toolbar] && storeMutationCount == 3 && legacyMutationCount == 0,
                "Rejected highlight attempts emitted creation or mutation callbacks.")
        } catch {
            failures.append("Native highlight fixture: \(error.localizedDescription)")
        }
        return (checks, failures)
    }

    private static func makeDocument() throws -> PDFDocument {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try require(CGDataConsumer(data: data as CFMutableData))
        let context = try require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        for lines in [["Alpha selected line.", "Beta selected line."], ["Gamma selected line."]] {
            context.beginPDFPage(nil)
            for (index, text) in lines.enumerated() {
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: 72, y: 700 - index * 30)
                let string = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
                CTLineDraw(CTLineCreateWithAttributedString(string), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return try require(PDFDocument(data: data as Data))
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw FixtureError.missing }
        return value
    }

    private enum FixtureError: Error { case missing }
}
