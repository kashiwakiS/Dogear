import CoreGraphics
import PDFKit

/// Standard FreeText defaults shared by every native reader. Placement and
/// temporary overlay visibility remain the reader's presentation decisions.
@MainActor
enum FreeTextAnnotationFactory {
    static func make(bounds: CGRect) -> PDFAnnotation {
        let note = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        note.font = FreeTextAnnotationEditing.defaultFont
        note.fontColor = PDFPlatformStyle.color(.init(red: 0.84, green: 0.05, blue: 0.07, alpha: 1))
        note.alignment = .left
        note.shouldDisplay = true
        note.shouldPrint = true
        note.border = PDFBorder()
        note.border?.lineWidth = 0
        note.removeValue(forAnnotationKey: .color)
        note.removeValue(forAnnotationKey: .interiorColor)
        return note
    }
}
