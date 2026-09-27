import Foundation
import PDFKit

struct FreeTextEditValues: Equatable {
    var text: String
    var width: Double
    var height: Double
    var fontSize: Double
}

struct FreeTextEditDraft: Identifiable {
    let id = UUID()
    let document: PDFDocument
    let page: PDFPage
    let annotation: PDFAnnotation
    let isNew: Bool
    let values: FreeTextEditValues
    let originalBounds: CGRect

    init(document: PDFDocument, page: PDFPage, annotation: PDFAnnotation, isNew: Bool = false) {
        self.document = document
        self.page = page
        self.annotation = annotation
        self.isNew = isNew
        originalBounds = annotation.bounds
        values = FreeTextEditValues(text: annotation.contents ?? "", width: annotation.bounds.width,
            height: annotation.bounds.height, fontSize: (annotation.font ?? FreeTextAnnotationEditing.defaultFont).pointSize)
    }
}

@MainActor
enum FreeTextAnnotationEditing {
    static let defaultFont = PDFPlatformFont.systemFont(ofSize: 14)
    static let richTextKey = PDFAnnotationKey(rawValue: "/RC")

    static func validationMessage(_ values: FreeTextEditValues, draft: FreeTextEditDraft) -> String? {
        if let richText = draft.annotation.value(forAnnotationKey: richTextKey),
           !String(describing: richText).isEmpty {
            return L10n.string("This note contains rich text formatting that this editor cannot preserve yet.")
        }
        if draft.annotation.hasAppearanceStream, draft.annotation.font == nil {
            return L10n.string("This note has a custom appearance that this editor cannot preserve yet.")
        }
        if values.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.string("Enter note text before saving.")
        }
        if !values.width.isFinite || !values.height.isFinite || values.width <= 0 || values.height <= 0 {
            return L10n.string("Width and height must be positive numbers.")
        }
        if !values.fontSize.isFinite || !(4...144).contains(values.fontSize) {
            return L10n.string("Font size must be between 4 and 144 points.")
        }
        let pageBounds = draft.page.bounds(for: .cropBox)
        if pageBounds.isEmpty || !pageBounds.width.isFinite || !pageBounds.height.isFinite {
            return L10n.string("The page no longer has usable bounds.")
        }
        return nil
    }

    static func resolvedBounds(_ values: FreeTextEditValues, draft: FreeTextEditDraft) -> CGRect {
        let page = draft.page.bounds(for: .cropBox)
        let width = min(page.width, max(24, CGFloat(values.width)))
        let height = min(page.height, max(24, CGFloat(values.height)))
        return CGRect(x: min(max(draft.originalBounds.minX, page.minX), page.maxX - width),
            y: min(max(draft.originalBounds.maxY - height, page.minY), page.maxY - height), width: width, height: height)
    }

    static func resizedFont(_ values: FreeTextEditValues, annotation: PDFAnnotation) -> PDFPlatformFont {
        PDFPlatformStyle.resizedFont(annotation.font ?? defaultFont, size: CGFloat(values.fontSize))
    }

    struct Snapshot {
        let contents: String?
        let bounds: CGRect
        let font: PDFPlatformFont?
        let modificationDate: Date?
        let appearance: Any?
        let defaultAppearance: Any?

        init(_ annotation: PDFAnnotation) {
            contents = annotation.contents
            bounds = annotation.bounds
            font = annotation.font
            modificationDate = annotation.modificationDate
            appearance = annotation.value(forAnnotationKey: .appearanceDictionary)
            defaultAppearance = annotation.value(forAnnotationKey: .defaultAppearance)
        }

        func restore(to annotation: PDFAnnotation) {
            annotation.contents = contents
            annotation.bounds = bounds
            annotation.font = font
            restore(defaultAppearance, key: .defaultAppearance, to: annotation)
            restore(appearance, key: .appearanceDictionary, to: annotation)
            FreeTextAnnotationEditing.preserveDefaultAppearanceString(in: annotation)
            annotation.modificationDate = modificationDate
        }

        private func restore(_ value: Any?, key: PDFAnnotationKey, to annotation: PDFAnnotation) {
            if let value { _ = annotation.setValue(value, forAnnotationKey: key) }
            else { annotation.removeValue(forAnnotationKey: key) }
        }
    }

    static func apply(_ values: FreeTextEditValues, draft: FreeTextEditDraft) {
        let annotation = draft.annotation
        annotation.contents = values.text
        annotation.bounds = resolvedBounds(values, draft: draft)
        annotation.font = resizedFont(values, annotation: annotation)
        // PDFKit regenerates ordinary FreeText appearances from its properties.
        // Remove any remaining imported stream so it cannot paint stale text.
        // Undo restores the original parameters and regenerates that appearance.
        // Opaque streams are not exposed by PDFKit; the form discloses this.
        annotation.removeValue(forAnnotationKey: .appearanceDictionary)
        preserveDefaultAppearanceString(in: annotation)
        annotation.modificationDate = Date()
    }

    private static func preserveDefaultAppearanceString(in annotation: PDFAnnotation) {
        guard let appearance = annotation.value(forAnnotationKey: .defaultAppearance) as? String,
              appearance.hasPrefix("/") else { return }
        // PDFKit's writer for loaded FreeText mistakes a leading slash in /DA
        // for a PDF Name, so readback loses the font and color. A leading space
        // is valid PDF content-stream whitespace and keeps /DA a PDF String.
        _ = annotation.setValue(" " + appearance, forAnnotationKey: .defaultAppearance)
    }

    static func draw(_ annotation: PDFAnnotation, bounds: CGRect? = nil, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        if let bounds {
            // Dragging translates the preview, without changing the annotation
            // or invalidating its native appearance until the gesture commits.
            context.translateBy(x: bounds.minX - annotation.bounds.minX, y: bounds.minY - annotation.bounds.minY)
        }
        context.clip(to: annotation.bounds)
        // PDFAnnotation.draw also draws annotations with shouldDisplay=false;
        // the PDFView hides native notes only to avoid drawing them twice.
        // This retains font, color, alignment, border and existing appearances.
        annotation.draw(with: .mediaBox, in: context)
    }
}
