import Foundation
import PDFKit

nonisolated struct HighlightAnnotationEditingDiagnosticReport {
    let checkCount: Int
    let failures: [String]
}

/// Native PDF objects exercise the shared edit boundary directly. Document
/// store diagnostics separately cover its write lease, Undo and persistence.
@MainActor
enum HighlightAnnotationEditingDiagnostics {
    static func run() -> HighlightAnnotationEditingDiagnosticReport {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }
        let document = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
        document.insert(page, at: 0)
        let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 60, width: 80, height: 20),
            forType: .highlight, withProperties: nil)
        annotation.color = PDFPlatformStyle.color(.init(red: 0.3, green: 0.4, blue: 0.5, alpha: 0.25))
        annotation.contents = nil
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        annotation.modificationDate = date
        annotation.quadrilateralPoints = [CGPoint(x: 0, y: 20), CGPoint(x: 80, y: 20),
            CGPoint.zero, CGPoint(x: 80, y: 0)].map(PDFPlatformStyle.pointValue)
        _ = annotation.setValue("shared-edit-fixture", forAnnotationKey: .name)
        page.addAnnotation(annotation)
        let draft = HighlightEditDraft(document: document, annotation: annotation, quote: "Exact quote",
            color: annotation.color, comment: "")
        let original = HighlightAnnotationEditing.Snapshot(annotation)
        let originalBounds = annotation.bounds
        let originalPoints = annotation.quadrilateralPoints
        check(HighlightAnnotationEditing.isCurrent(draft, in: document),
            "A live native highlight was rejected.")
        check(!HighlightAnnotationEditing.isCurrent(draft, in: nil)
            && !HighlightAnnotationEditing.isCurrent(draft, in: PDFDocument()),
            "A missing or replaced document accepted a delayed editor.")
        check(HighlightAnnotationEditing.preparedEdit(draft, color: draft.color, comment: "") == nil
            && annotation.contents == nil && annotation.modificationDate == date,
            "Saving identical visible values mutated a nil comment or modification date.")

        check(HighlightAnnotationEditing.matchesBaseline(draft, in: document), "A fresh Highlight baseline must match.")
        annotation.contents = "Other editor"
        check(!HighlightAnnotationEditing.matchesBaseline(draft, in: document), "A competing comment invalidates the captured editor on both platforms.")
        annotation.contents = nil
        annotation.bounds.origin.x += 1
        check(!HighlightAnnotationEditing.matchesBaseline(draft, in: document), "A moved annotation invalidates the captured geometry.")
        annotation.bounds = originalBounds
        annotation.quadrilateralPoints = nil
        check(!HighlightAnnotationEditing.matchesBaseline(draft, in: document), "Changed native quads invalidate the captured geometry.")
        annotation.quadrilateralPoints = originalPoints
        check(HighlightAnnotationEditing.matchesBaseline(draft, in: document), "Restoring the native baseline permits editing again.")

        let proposed = PDFPlatformStyle.color(.init(red: 0.8, green: 0.2, blue: 0.4, alpha: 1))
        guard let edit = HighlightAnnotationEditing.preparedEdit(draft, color: proposed,
                comment: "Changed comment\n中文 😀") else {
            failures.append("A changed highlight could not be prepared.")
            return .init(checkCount: checks, failures: failures)
        }
        check(annotation.color.isEqual(original.color) && annotation.contents == nil
            && annotation.modificationDate == date,
            "Preparing an edit changed the native annotation before application.")
        check(PDFPlatformStyle.alphaComponent(of: edit.color) == PDFPlatformStyle.alphaComponent(of: draft.color),
            "A hue change altered highlight opacity.")
        edit.apply(to: annotation)
        check(annotation.color.isEqual(edit.color) && annotation.contents == "Changed comment\n中文 😀"
            && annotation.modificationDate == edit.modificationDate && annotation.modificationDate != date,
            "The prepared color, comment or date did not apply together.")
        check(annotation.page === page && annotation.bounds == originalBounds
            && annotation.quadrilateralPoints == originalPoints
            && (annotation.value(forAnnotationKey: .name) as? String) == "shared-edit-fixture"
            && draft.quote == "Exact quote",
            "Editing changed highlight identity, geometry, page or captured quote.")
        original.apply(to: annotation)
        check(annotation.color.isEqual(original.color) && annotation.contents == nil
            && annotation.modificationDate == date,
            "Restoring the exact snapshot lost a nil comment, native color or date.")

        page.removeAnnotation(annotation)
        check(!HighlightAnnotationEditing.isCurrent(draft, in: document),
            "A removed annotation remained a valid editor target.")
        let replacementPage = PDFPage()
        let replacementDocument = PDFDocument()
        replacementDocument.insert(replacementPage, at: 0)
        replacementPage.addAnnotation(annotation)
        check(!HighlightAnnotationEditing.isCurrent(draft, in: document),
            "A highlight moved into another document accepted its old editor.")

        let note = PDFAnnotation(bounds: originalBounds, forType: .freeText, withProperties: nil)
        page.addAnnotation(note)
        let wrongType = HighlightEditDraft(document: document, annotation: note, quote: "",
            color: note.color, comment: "")
        check(!HighlightAnnotationEditing.isCurrent(wrongType, in: document),
            "The highlight edit boundary accepted a FreeText annotation.")
        let point = CGPoint(x: -12.5, y: 34.25)
        check(PDFPlatformStyle.point(from: PDFPlatformStyle.pointValue(point)) == point,
            "The platform boxed point round trip changed PDF geometry.")
        return .init(checkCount: checks, failures: failures)
    }
}
