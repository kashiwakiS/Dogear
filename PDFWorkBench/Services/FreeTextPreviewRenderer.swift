import CoreGraphics
import PDFKit

@MainActor
enum FreeTextPreviewStyle {
    static func copyExplicitColors(from source: PDFAnnotation, to preview: PDFAnnotation) {
        // PDFKit's color getter returns yellow when /C is absent. Copy the
        // dictionary state so transparent notes remain transparent in preview.
        for key in [PDFAnnotationKey.color, .interiorColor] {
            if let value = source.value(forAnnotationKey: key) {
                _ = preview.setValue(value, forAnnotationKey: key)
            } else {
                preview.removeValue(forAnnotationKey: key)
            }
        }
    }
}

/// PDFKit draws into a shared bitmap context so SwiftUI's graphics color pipeline
/// cannot change translucent annotation colors. Only the detached annotation
/// receives draft changes; previewing never edits the page or its annotations.
@MainActor
enum FreeTextPreviewRenderer {
    static func image(draft: FreeTextEditDraft, values: FreeTextEditValues,
                      size: CGSize, displayScale: CGFloat) -> CGImage? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              displayScale.isFinite, displayScale > 0 else { return nil }
        let width = ceil(size.width * displayScale), height = ceil(size.height * displayScale)
        // The editor normally needs a 396×140pt image. Reject pathological
        // layouts before integer conversion or bitmap allocation.
        guard width.isFinite, height.isFinite, width <= 8192, height <= 8192,
              width * height <= 16_777_216,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(width), height: Int(height),
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: width / size.width, y: height / size.height)
        draw(draft: draft, values: values, size: size, in: context)
        return context.makeImage()
    }

    /// The bitmap uses native bottom-left PDF coordinates; SwiftUI Image handles
    /// its display orientation without an AppKit or UIKit graphics context.
    static func draw(draft: FreeTextEditDraft, values: FreeTextEditValues, size: CGSize, in context: CGContext) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let viewport = CGRect(origin: .zero, size: size)
        context.clip(to: viewport)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(viewport)
        guard size.width > 16, size.height > 16,
              values.width.isFinite, values.height.isFinite, values.width > 0, values.height > 0,
              values.fontSize.isFinite, (4...144).contains(values.fontSize),
              usable(draft.originalBounds), usable(draft.page.bounds(for: .cropBox)) else { return }

        let note = PDFAnnotation(bounds: draft.originalBounds, forType: .freeText, withProperties: nil)
        note.font = draft.annotation.font
        note.fontColor = draft.annotation.fontColor
        note.alignment = draft.annotation.alignment
        note.border = draft.annotation.border
        FreeTextPreviewStyle.copyExplicitColors(from: draft.annotation, to: note)
        let previewDraft = FreeTextEditDraft(document: draft.document, page: draft.page, annotation: note, isNew: true)
        FreeTextAnnotationEditing.apply(values, draft: previewDraft)
        let noteBounds = note.bounds
        guard usable(noteBounds) else { return }
        let scale = min(1, (size.width - 16) / noteBounds.width, (size.height - 16) / noteBounds.height)
        guard scale.isFinite, scale > 0 else { return }
        context.translateBy(x: (size.width - noteBounds.width * scale) / 2,
                            y: (size.height - noteBounds.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -noteBounds.minX, y: -noteBounds.minY)
        context.setStrokeColor(CGColor(gray: 2.0 / 3.0, alpha: 1))
        context.setLineWidth(1 / scale)
        context.stroke(noteBounds)
        FreeTextAnnotationEditing.draw(note, in: context)
    }

    private static func usable(_ bounds: CGRect) -> Bool {
        !bounds.isEmpty && !bounds.isNull && !bounds.isInfinite
            && bounds.origin.x.isFinite && bounds.origin.y.isFinite
            && bounds.width.isFinite && bounds.height.isFinite
    }
}
