import Foundation
import PDFKit

/// Retain actual PDF objects so a delayed editor cannot target a replacement
/// document or a different unnamed annotation after page indexes change.
struct HighlightEditDraft: Identifiable {
    let id = UUID()
    let document: PDFDocument
    let annotation: PDFAnnotation
    let page: PDFPage?
    let quote: String
    let color: PDFPlatformColor
    let comment: String
    let baselineBounds: CGRect
    let baselinePoints: [CGPoint]?

    init(document: PDFDocument, annotation: PDFAnnotation, quote: String, color: PDFPlatformColor, comment: String) {
        self.document = document; self.annotation = annotation; page = annotation.page
        self.quote = quote; self.color = color; self.comment = comment
        baselineBounds = annotation.bounds
        baselinePoints = annotation.quadrilateralPoints?.map { PDFPlatformStyle.point(from: $0) }
    }

    var values: HighlightEditValues { .init(comment: comment, color: color) }
}

struct HighlightEditValues: Equatable {
    var comment: String
    var color: PDFPlatformColor
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.comment == rhs.comment && lhs.color.isEqual(rhs.color)
    }
}

/// Native annotation editing values and validation are shared. The owning
/// document store retains its write lease, UndoManager and save lifecycle.
@MainActor
enum HighlightAnnotationEditing {
    struct Snapshot {
        let color: PDFPlatformColor
        let comment: String?
        let modificationDate: Date?

        init(_ annotation: PDFAnnotation) {
            color = annotation.color
            comment = annotation.contents
            modificationDate = annotation.modificationDate
        }

        init(color: PDFPlatformColor, comment: String?, modificationDate: Date?) {
            self.color = color
            self.comment = comment
            self.modificationDate = modificationDate
        }

        func apply(to annotation: PDFAnnotation) {
            annotation.color = color
            annotation.contents = comment
            annotation.modificationDate = modificationDate
        }
    }

    static func isCurrent(_ draft: HighlightEditDraft, in document: PDFDocument?) -> Bool {
        guard document === draft.document,
              let page = draft.annotation.page, page.document === document,
              page.annotations.contains(where: { $0 === draft.annotation }),
              draft.annotation.type == "Highlight" else { return false }
        return true
    }

    static func matchesBaseline(_ draft: HighlightEditDraft, in document: PDFDocument?) -> Bool {
        isCurrent(draft, in: document)
            && draft.annotation.page === draft.page
            && draft.annotation.bounds == draft.baselineBounds
            && draft.annotation.quadrilateralPoints?.map({ PDFPlatformStyle.point(from: $0) }) == draft.baselinePoints
            && draft.annotation.color.isEqual(draft.color)
            && (draft.annotation.contents ?? "") == draft.comment
    }

    /// Preparing a change never mutates the annotation. Nil means its visible
    /// color/comment already match; the caller validates the target first.
    static func preparedEdit(
        _ draft: HighlightEditDraft, color: PDFPlatformColor, comment: String
    ) -> Snapshot? {
        // Choosing a hue must preserve the highlight's existing PDF opacity.
        let newColor = color.withAlphaComponent(PDFPlatformStyle.alphaComponent(of: draft.color))
        guard !draft.annotation.color.isEqual(newColor)
                || (draft.annotation.contents ?? "") != comment else { return nil }
        return Snapshot(color: newColor, comment: comment, modificationDate: Date())
    }
}
