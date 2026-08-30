import CoreGraphics
import CoreText
import Foundation
import PDFKit

@MainActor
enum AIHighlightApplicationDiagnostics {
    static func run() -> AIHighlightFoundationDiagnosticReport {
        var checks = 0
        var failures: [String] = []

        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }

        do {
            let document = try makeTextPDF("First evidence sentence. Second sentence.")
            let snapshot = try NativePDFTextSnapshotBuilder(document: document)
                .makeTextSnapshot()
            let registry = try AISegmentRegistry(snapshot: snapshot)
            guard let record = registry.records.first else {
                throw AIHighlightApplicationDiagnosticError.noSegments
            }
            let staged = StagedAIHighlight(
                candidate: AIHighlightCandidate(
                    candidateID: "application-diagnostic",
                    segmentIDs: [record.id],
                    category: .evidence,
                    importance: 4,
                    note: "Verified evidence note"
                ),
                pageNumber: 1,
                sourceKind: .nativeText
            )
            let anchors = try AIHighlightNativeAnchorResolver().resolve(
                [staged],
                registry: registry,
                in: document
            )

            let defaults = UserDefaults(suiteName: "AIHighlightApplicationDiagnostics")!
            let store = PDFDocumentStore(
                feedbackCenter: OperationFeedbackCenter(userDefaults: defaults)
            )
            store.document = document
            let undoManager = UndoManager()
            undoManager.groupsByEvent = false
            store.setUndoManager(undoManager)

            undoManager.beginUndoGrouping()
            let applied = try store.applyAIHighlights(
                stagedHighlights: [staged],
                anchors: anchors
            )
            undoManager.endUndoGrouping()
            check(applied == 1, "The application transaction did not add one annotation.")
            check(document.page(at: 0)?.annotations.count == 1, "The PDF page did not receive the annotation.")
            check(
                store.annotations.first?.text.contains("First evidence sentence") == true
                    && store.annotations.first?.note == "Verified evidence note",
                "The extractor did not separate highlight geometry text from Contents note."
            )
            check(
                store.annotations.first?.aiCategory == .evidence,
                "The annotation list did not expose AI provenance/category."
            )

            let originalAnnotation = document.page(at: 0)?.annotations.first
            let originalName = originalAnnotation.flatMap(AIAnnotationProvenance.uniqueName)
            store.showsAIGeneratedContent = false
            check(
                originalAnnotation?.shouldDisplay == false
                    && store.filteredAnnotations.isEmpty,
                "The display toggle did not hide both page and list presentation."
            )
            let serialized = document.dataRepresentationWithAIAnnotationsDisplayed()
            check(
                serialized.flatMap(PDFDocument.init(data:))?
                    .page(at: 0)?.annotations.first?.shouldDisplay == true
                    && originalAnnotation?.shouldDisplay == false,
                "Working-copy serialization leaked or retained the temporary hidden state."
            )

            undoManager.undo()
            check(document.page(at: 0)?.annotations.isEmpty == true, "Undo did not remove the complete AI batch.")
            undoManager.redo()
            let restoredAnnotation = document.page(at: 0)?.annotations.first
            check(
                restoredAnnotation === originalAnnotation
                    && restoredAnnotation.flatMap(AIAnnotationProvenance.uniqueName) == originalName
                    && restoredAnnotation?.shouldDisplay == false,
                "Redo did not restore the same annotation identity, provenance, and group visibility."
            )

            let duplicateCount = try store.applyAIHighlights(
                stagedHighlights: [staged],
                anchors: anchors
            )
            check(
                duplicateCount == 0 && document.page(at: 0)?.annotations.count == 1,
                "A duplicate AI geometry was added."
            )
        } catch {
            failures.append(error.localizedDescription)
        }

        return AIHighlightFoundationDiagnosticReport(
            checkCount: checks,
            failures: failures
        )
    }

    private static func makeTextPDF(_ text: String) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw AIHighlightApplicationDiagnosticError.cannotCreatePDF
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw AIHighlightApplicationDiagnosticError.cannotCreatePDF
        }
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: CTFontCreateWithName("Helvetica" as CFString, 14, nil),
                .foregroundColor: CGColor(gray: 0, alpha: 1)
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else {
            throw AIHighlightApplicationDiagnosticError.cannotCreatePDF
        }
        return document
    }
}

nonisolated private enum AIHighlightApplicationDiagnosticError: LocalizedError {
    case cannotCreatePDF
    case noSegments

    var errorDescription: String? {
        switch self {
        case .cannotCreatePDF:
            return "Could not create the application transaction PDF fixture."
        case .noSegments:
            return "The application transaction fixture had no native-text segments."
        }
    }
}
