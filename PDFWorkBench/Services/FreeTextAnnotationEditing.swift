import Foundation
import PDFKit

struct FreeTextEditValues: Equatable {
    var text: String
    var width: Double
    var height: Double
    var fontSize: Double
    /// Nil keeps the annotation's existing text color until the user chooses one.
    var fontColor: PDFColorComponents? = nil
    /// Nil preserves the native font descriptor, including its family and traits.
    var fontName: String? = nil
}

struct FreeTextEditDraft: Identifiable {
    let id: UUID
    let document: PDFDocument
    let page: PDFPage
    let annotation: PDFAnnotation
    let isNew: Bool
    let values: FreeTextEditValues
    let originalBounds: CGRect
    let originalPageBounds: CGRect
    let originalPageRotation: Int
    let originalFontColor: PDFColorComponents?
    let originalFontName: String?
    let baseline: FreeTextAnnotationEditing.Snapshot

    init(document: PDFDocument, page: PDFPage, annotation: PDFAnnotation, isNew: Bool = false, id: UUID = UUID()) {
        self.id = id
        self.document = document
        self.page = page
        self.annotation = annotation
        self.isNew = isNew
        baseline = FreeTextAnnotationEditing.Snapshot(annotation)
        originalBounds = annotation.bounds
        originalPageBounds = page.bounds(for: .cropBox)
        originalPageRotation = page.rotation
        originalFontColor = FreeTextAnnotationEditing.textColorComponents(of: annotation.fontColor ?? .black)
        originalFontName = annotation.font?.fontName
        values = FreeTextEditValues(text: annotation.contents ?? "", width: annotation.bounds.width,
            height: annotation.bounds.height, fontSize: (annotation.font ?? FreeTextAnnotationEditing.defaultFont).pointSize)
    }
}

@MainActor
enum FreeTextAnnotationEditing {
    static let defaultFont = PDFPlatformFont.systemFont(ofSize: 14)
    static let richTextKey = PDFAnnotationKey(rawValue: "/RC")
    static let commonFontNames = ["Helvetica", "Georgia", "Menlo"]

    static func isCurrent(_ draft: FreeTextEditDraft, in document: PDFDocument?) -> Bool {
        guard document === draft.document, draft.page.document === document,
              draft.document.index(for: draft.page) != NSNotFound,
              draft.page.bounds(for: .cropBox) == draft.originalPageBounds,
              draft.page.rotation == draft.originalPageRotation else { return false }
        if draft.isNew { return draft.annotation.page == nil }
        return draft.annotation.page === draft.page
            && draft.page.annotations.contains { $0 === draft.annotation }
            && draft.baseline.matches(draft.annotation)
    }

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
        if values.fontName != nil, explicitFont(values) == nil {
            return L10n.string("The selected font is not available on this device.")
        }
        if let color = values.fontColor,
           [color.red, color.green, color.blue, color.alpha].contains(where: { !$0.isFinite || !(0...1).contains($0) }) {
            return L10n.string("Text color components must be between 0 and 1.")
        }
        let pageBounds = draft.page.bounds(for: .cropBox)
        if pageBounds.isEmpty || !pageBounds.width.isFinite || !pageBounds.height.isFinite {
            return L10n.string("The page no longer has usable bounds.")
        }
        return nil
    }

    static func resolvedBounds(_ values: FreeTextEditValues, draft: FreeTextEditDraft) -> CGRect {
        resolvedBounds(values, originalBounds: draft.originalBounds, pageBounds: draft.page.bounds(for: .cropBox))
    }

    static func resolvedBounds(_ values: FreeTextEditValues, originalBounds: CGRect, pageBounds: CGRect) -> CGRect {
        let width = min(pageBounds.width, max(24, CGFloat(values.width)))
        let height = min(pageBounds.height, max(24, CGFloat(values.height)))
        return CGRect(x: min(max(originalBounds.minX, pageBounds.minX), pageBounds.maxX - width),
            y: min(max(originalBounds.maxY - height, pageBounds.minY), pageBounds.maxY - height), width: width, height: height)
    }

    static func resizedFont(_ values: FreeTextEditValues, annotation: PDFAnnotation) -> PDFPlatformFont {
        explicitFont(values) ?? PDFPlatformStyle.resizedFont(annotation.font ?? defaultFont, size: CGFloat(values.fontSize))
    }

    static func explicitFont(_ values: FreeTextEditValues) -> PDFPlatformFont? {
        guard let name = values.fontName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              values.fontSize.isFinite, (4...144).contains(values.fontSize) else { return nil }
        return PDFPlatformFont(name: name, size: CGFloat(values.fontSize))
    }

    static func resolvedTextColor(_ values: FreeTextEditValues, draft: FreeTextEditDraft) -> PDFPlatformColor {
        values.fontColor.map(PDFPlatformStyle.color) ?? draft.baseline.fontColor ?? .black
    }

    static func textColorComponents(of color: PDFPlatformColor) -> PDFColorComponents? {
        #if canImport(AppKit)
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
        return .init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return .init(red: red, green: green, blue: blue, alpha: alpha)
        #endif
    }

    static func matchesTextColor(_ color: PDFColorComponents, annotation: PDFAnnotation) -> Bool {
        guard let actual = textColorComponents(of: annotation.fontColor ?? .black),
              let expected = textColorComponents(of: PDFPlatformStyle.color(color)) else { return false }
        let actualValues = [actual.red, actual.green, actual.blue, actual.alpha]
        let expectedValues = [expected.red, expected.green, expected.blue, expected.alpha]
        return zip(actualValues, expectedValues).allSatisfy { pair in abs(pair.0 - pair.1) < 0.00001 }
    }

    struct Snapshot {
        let contents: String?
        let bounds: CGRect
        let font: PDFPlatformFont?
        let fontColor: PDFPlatformColor?
        let modificationDate: Date?
        let appearance: Any?
        let defaultAppearance: Any?

        init(_ annotation: PDFAnnotation) {
            contents = annotation.contents
            bounds = annotation.bounds
            font = annotation.font
            fontColor = annotation.fontColor
            modificationDate = annotation.modificationDate
            appearance = annotation.value(forAnnotationKey: .appearanceDictionary)
            defaultAppearance = annotation.value(forAnnotationKey: .defaultAppearance)
        }

        func matches(_ annotation: PDFAnnotation) -> Bool {
            contents == annotation.contents && bounds == annotation.bounds
                && font == annotation.font && fontColor == annotation.fontColor
                && modificationDate == annotation.modificationDate
        }

        func restore(to annotation: PDFAnnotation) {
            annotation.contents = contents
            annotation.bounds = bounds
            annotation.font = font
            annotation.fontColor = fontColor
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
        if let color = values.fontColor { annotation.fontColor = PDFPlatformStyle.color(color) }
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
