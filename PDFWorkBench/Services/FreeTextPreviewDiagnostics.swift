import CoreGraphics
import PDFKit
import SwiftUI

/// Exercises the actual SwiftUI preview against the former native PDF-space
/// drawing, using detached fixtures rather than a user's document or window.
@MainActor
enum FreeTextPreviewDiagnostics {
    static func run() -> AIHighlightFoundationDiagnosticReport {
        var checks = 0
        var failures: [String] = []
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !value() { failures.append("FreeText preview: " + message) }
        }

        do {
            let document = PDFDocument()
            let page = PDFPage()
            page.setBounds(CGRect(x: 20, y: 30, width: 400, height: 500), for: .cropBox)
            document.insert(page, at: 0)
            let annotation = PDFAnnotation(bounds: CGRect(x: 65, y: 210, width: 240, height: 100),
                                           forType: .freeText, withProperties: nil)
            annotation.font = PDFPlatformStyle.font(.init(pointSize: 20, bold: true, italic: true))
            annotation.fontColor = PDFPlatformStyle.color(.init(red: 0.05, green: 0.15, blue: 0.85, alpha: 1))
            annotation.contents = "First line\nSecond line"
            annotation.removeValue(forAnnotationKey: .color)
            annotation.removeValue(forAnnotationKey: .interiorColor)
            page.addAnnotation(annotation)
            let draft = FreeTextEditDraft(document: document, page: page, annotation: annotation)
            let original = FreeTextAnnotationEditing.Snapshot(annotation)
            let size = CGSize(width: 360, height: 140)
            let transparent = try canvasPixels(draft, values: draft.values, size: size)
            let originalReference = try nativePixels(draft, values: draft.values, size: size)
            check(similar(transparent, originalReference), "SwiftUI changed native text orientation, font, positioning or clipping")
            check(coloredPixels(transparent, blue: true) > 50, "SwiftUI lost the annotation's blue font")
            check(coloredPixels(transparent, blue: false) == 0, "an absent fill became PDFKit's default yellow")

            var clippedValues = draft.values
            clippedValues.text = Array(repeating: "A long line that must stay inside the note bounds", count: 8).joined(separator: "\n")
            clippedValues.height = 24
            clippedValues.width = 120
            let clipped = try canvasPixels(draft, values: clippedValues, size: size)
            let clippedReference = try nativePixels(draft, values: clippedValues, size: size)
            check(similar(clipped, clippedReference),
                  "multiline overflow escaped the native clipping bounds")
            check(clipped != transparent, "SwiftUI did not update after editing draft text and size")

            var oversized = draft.values
            oversized.width = 900
            oversized.height = 800
            oversized.fontSize = 36
            for rotation in [0, 90, 180, 270] {
                page.rotation = rotation
                let actual = try canvasPixels(draft, values: oversized, size: size)
                let reference = try nativePixels(draft, values: oversized, size: size)
                check(similar(actual, reference), "nonzero crop origin or page rotation \(rotation) changed the fitted note")
            }
            page.rotation = 0
            check(annotation.contents == original.contents && annotation.bounds == original.bounds
                  && annotation.font?.isEqual(original.font) == true && annotation.modificationDate == original.modificationDate,
                  "previewing edited values mutated the original annotation")
            check(page.annotations.count == 1 && page.annotations.first === annotation,
                  "previewing inserted or replaced a page annotation")
            check(annotation.value(forAnnotationKey: .color) == nil && annotation.value(forAnnotationKey: .interiorColor) == nil,
                  "previewing changed the original transparent color dictionary")

            annotation.alignment = .right
            annotation.color = PDFPlatformStyle.color(.init(red: 0, green: 0.65, blue: 0, alpha: 0.35))
            annotation.interiorColor = PDFPlatformStyle.color(.init(red: 0.8, green: 0.9, blue: 1, alpha: 0.3))
            let coloredDraft = FreeTextEditDraft(document: document, page: page, annotation: annotation)
            let colored = try canvasPixels(coloredDraft, values: coloredDraft.values, size: size)
            let coloredReference = try nativePixels(coloredDraft, values: coloredDraft.values, size: size)
            check(similar(colored, coloredReference),
                  "SwiftUI lost explicit colors, transparency or right alignment")
            check(colored != transparent, "explicit native colors did not affect the preview")

            for invalid in [
                FreeTextEditValues(text: "invalid", width: .nan, height: 100, fontSize: 20),
                FreeTextEditValues(text: "invalid", width: 240, height: 0, fontSize: 20),
                FreeTextEditValues(text: "invalid", width: 240, height: .infinity, fontSize: 20),
                FreeTextEditValues(text: "invalid", width: 240, height: 100, fontSize: .infinity),
                FreeTextEditValues(text: "invalid", width: 240, height: 100, fontSize: 145)
            ] {
                let bytes = try canvasPixels(draft, values: invalid, size: size)
                check(bytes.allSatisfy { $0 == 255 }, "invalid dimensions or font painted an unsafe preview")
            }
            let tiny = try canvasPixels(draft, values: draft.values, size: CGSize(width: 16, height: 16))
            check(tiny.allSatisfy { $0 == 255 }, "a tiny viewport generated a negative or zero drawing scale")
            for scale in [1.0, 2.0, 3.0] {
                let image = FreeTextPreviewRenderer.image(draft: draft, values: draft.values, size: size, displayScale: scale)
                check(image?.width == Int(size.width * scale) && image?.height == Int(size.height * scale),
                      "preview bitmap ignored display scale \(scale)")
            }
            for invalidSize in [CGSize(width: CGFloat.infinity, height: 140), CGSize(width: -1, height: 140),
                                CGSize(width: 100_000, height: 100_000)] {
                check(FreeTextPreviewRenderer.image(draft: draft, values: draft.values, size: invalidSize, displayScale: 2) == nil,
                      "unbounded or invalid dimensions attempted a bitmap allocation")
            }
            for invalidScale in [CGFloat.nan, .infinity, 0, -1] {
                check(FreeTextPreviewRenderer.image(draft: draft, values: draft.values, size: size, displayScale: invalidScale) == nil,
                      "invalid display scale attempted a bitmap allocation")
            }
            _ = try bitmap(size: size) { context in
                context.translateBy(x: 7, y: 11)
                let transform = context.ctm
                let clip = context.boundingBoxOfClipPath
                FreeTextPreviewRenderer.draw(draft: draft, values: draft.values, size: size, in: context)
                check(context.ctm == transform && context.boundingBoxOfClipPath == clip,
                      "rendering leaked its transform or clipping into the caller's context")
            }
        } catch {
            failures.append("FreeText preview fixture: \(error.localizedDescription)")
        }
        return .init(checkCount: checks, failures: failures)
    }

    private static func canvasPixels(_ draft: FreeTextEditDraft, values: FreeTextEditValues, size: CGSize) throws -> [UInt8] {
        let renderer = ImageRenderer(content: FreeTextPreview(draft: draft, values: values)
            .frame(width: size.width, height: size.height)
            .environment(\.displayScale, 1))
        renderer.scale = 1
        guard let image = renderer.cgImage else { throw FixtureError.missingImage }
        return try bitmap(size: size) { $0.draw(image, in: CGRect(origin: .zero, size: size)) }
    }

    private static func nativePixels(_ draft: FreeTextEditDraft, values: FreeTextEditValues, size: CGSize) throws -> [UInt8] {
        // Reference the original NSView's bottom-left PDF transform, independent
        // of the new SwiftUI Image entry point and its display orientation.
        let note = PDFAnnotation(bounds: draft.originalBounds, forType: .freeText, withProperties: nil)
        note.font = draft.annotation.font
        note.fontColor = draft.annotation.fontColor
        note.alignment = draft.annotation.alignment
        note.border = draft.annotation.border
        FreeTextPreviewStyle.copyExplicitColors(from: draft.annotation, to: note)
        let copy = FreeTextEditDraft(document: draft.document, page: draft.page, annotation: note, isNew: true)
        FreeTextAnnotationEditing.apply(values, draft: copy)
        return try bitmap(size: size) { context in
            let bounds = note.bounds
            let scale = min(1, (size.width - 16) / bounds.width, (size.height - 16) / bounds.height)
            context.translateBy(x: (size.width - bounds.width * scale) / 2,
                                y: (size.height - bounds.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.setStrokeColor(CGColor(gray: 2.0 / 3.0, alpha: 1))
            context.setLineWidth(1 / scale)
            context.stroke(bounds)
            FreeTextAnnotationEditing.draw(note, in: context)
        }
    }

    private static func bitmap(size: CGSize, draw: (CGContext) -> Void) throws -> [UInt8] {
        let width = Int(size.width), height = Int(size.height)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FixtureError.missingImage }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            draw(context)
        }
        return bytes
    }

    private static func similar(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference = 0, ink = 0
        for offset in lhs.indices where offset % 4 != 3 {
            difference += abs(Int(lhs[offset]) - Int(rhs[offset]))
            ink += 255 - min(Int(lhs[offset]), Int(rhs[offset]))
        }
        // SwiftUI and bitmap contexts may antialias glyph edges differently;
        // compare error against actual ink, not the surrounding blank canvas.
        return ink > 0 && Double(difference) / Double(ink) < 0.03
    }

    private static func coloredPixels(_ bytes: [UInt8], blue: Bool) -> Int {
        stride(from: 0, to: bytes.count, by: 4).filter { offset in
            let red = Int(bytes[offset]), green = Int(bytes[offset + 1]), value = Int(bytes[offset + 2])
            return blue ? value > red + 50 && value > green + 50 : red > value + 50 && green > value + 50
        }.count
    }

    private enum FixtureError: Error { case missingImage }
}
