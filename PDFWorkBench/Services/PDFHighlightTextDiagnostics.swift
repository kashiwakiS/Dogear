import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// Actual native-text pages and standard PDF highlights exercise the shared
/// quote boundary without an application, reader view or user document.
@MainActor
enum PDFHighlightTextDiagnostics {
    static func run() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }
        do {
            let firstLine = "First café line."
            let secondLine = "Second Ω line."
            let document = try textPDF(lines: [firstLine, secondLine])
            let page = try require(document.page(at: 0))
            let firstBounds = try bounds(of: firstLine, on: page)
            let secondBounds = try bounds(of: secondLine, on: page)
            let multilineBounds = firstBounds.union(secondBounds)
            check(normalized(page.selection(for: firstBounds)?.string) == firstLine
                && normalized(page.selection(for: secondBounds)?.string) == secondLine,
                "The native Unicode text fixture did not provide exact line selections.")

            let external = highlight(bounds: multilineBounds, lineBounds: [firstBounds, secondBounds])
            external.contents = "Explanation only; this is not the quoted source."
            _ = external.setValue("external-quad-fixture", forAnnotationKey: .name)
            page.addAnnotation(external)
            check(external.type == "Highlight" && external.page === page,
                "The quote fixture is not a standard native PDF Highlight.")
            check(PDFHighlightText.text(of: external, on: page) == "\(firstLine)\n\(secondLine)",
                "External relative quads lost Unicode or multiline quote geometry.")
            check(external.contents == "Explanation only; this is not the quoted source."
                && external.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DogearText")) == nil,
                "Reading an external quote changed its comment or stored private text.")

            let reversed = highlight(bounds: multilineBounds, lineBounds: [secondBounds, firstBounds])
            check(PDFHighlightText.text(of: reversed, on: page) == "\(secondLine)\n\(firstLine)",
                "Quad extraction reordered the PDF's native quadrilateral sequence.")

            let fallback = highlight(bounds: firstBounds)
            fallback.contents = "A distinct comment."
            check(PDFHighlightText.text(of: fallback, on: page) == firstLine
                && fallback.contents == "A distinct comment.",
                "The bounds fallback replaced the source quote with the comment.")
            _ = fallback.setValue(" \n\t ", forAnnotationKey: PDFAnnotationKey(rawValue: "/DogearText"))
            check(PDFHighlightText.text(of: fallback, on: page) == firstLine,
                "An empty stored quote prevented native geometry fallback.")
            let emptyQuads = highlight(bounds: firstBounds,
                lineBounds: [CGRect(x: -200, y: -200, width: 20, height: 20)])
            check(PDFHighlightText.text(of: emptyQuads, on: page) == firstLine,
                "Empty quadrilateral text prevented the annotation-bounds fallback.")

            let exact = highlight(bounds: firstBounds, lineBounds: [firstBounds])
            exact.contents = "Exact annotation comment."
            _ = exact.setValue("exact-quote-fixture", forAnnotationKey: .name)
            let exactQuote = "  Selected quote — 中文 😀\nSecond exact line.  \n"
            let expectedExact = "Selected quote — 中文 😀\nSecond exact line."
            check(PDFHighlightText.storeExactText(exactQuote, in: exact),
                "PDFKit rejected an exact Unicode quote.")
            page.addAnnotation(exact)
            check(PDFHighlightText.text(of: exact, on: page) == expectedExact
                && exact.contents == "Exact annotation comment.",
                "Exact quotes lost trimming, Unicode, line breaks or priority over geometry.")
            check(!PDFHighlightText.storeExactText(" \n\t ", in: exact)
                && PDFHighlightText.text(of: exact, on: page) == expectedExact,
                "An empty quote replaced an existing exact quote.")

            let empty = highlight(bounds: CGRect(x: -200, y: -200, width: 20, height: 20))
            empty.contents = "This comment must never become source text."
            check(!PDFHighlightText.storeExactText(" \n\t ", in: empty)
                && empty.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DogearText")) == nil
                && PDFHighlightText.text(of: empty, on: page).isEmpty,
                "Empty source geometry or quote was filled from the note.")

            page.setBounds(CGRect(x: 20, y: 30, width: 560, height: 740), for: .cropBox)
            page.rotation = 90
            check(PDFHighlightText.text(of: external, on: page) == "\(firstLine)\n\(secondLine)"
                && PDFHighlightText.text(of: fallback, on: page) == firstLine,
                "Rotation/crop changed native page-space quad or bounds text.")
            check(PDFHighlightText.text(of: exact, on: page) == expectedExact,
                "Rotation/crop changed an exact stored quote.")

            let data = try require(document.dataRepresentation())
            let restored = try require(PDFDocument(data: data))
            let restoredPage = try require(restored.page(at: 0))
            let restoredExternal = try require(restoredPage.annotations.first {
                ($0.value(forAnnotationKey: .name) as? String) == "external-quad-fixture"
            })
            let restoredExact = try require(restoredPage.annotations.first {
                ($0.value(forAnnotationKey: .name) as? String) == "exact-quote-fixture"
            })
            check(restoredPage.rotation == 90 && restoredPage.bounds(for: .cropBox) == page.bounds(for: .cropBox),
                "The native PDF round trip lost fixture rotation or crop geometry.")
            check(restoredExternal.type == "Highlight" && restoredExact.type == "Highlight",
                "The native PDF round trip lost standard Highlight annotations.")
            check(PDFHighlightText.text(of: restoredExternal, on: restoredPage) == "\(firstLine)\n\(secondLine)",
                "External multiline quad quotes changed after native PDF serialization.")
            check(PDFHighlightText.text(of: restoredExact, on: restoredPage) == expectedExact
                && restoredExact.contents == "Exact annotation comment.",
                "Exact Unicode quote/comment separation changed after native PDF serialization.")
            check(PDFHighlightText.text(of: external, on: page) == "\(firstLine)\n\(secondLine)"
                && external.contents == "Explanation only; this is not the quoted source.",
                "Native serialization changed the live highlight's quote or comment.")
        } catch { failures.append("Highlight text fixture: \(error.localizedDescription)") }
        return (checks, failures)
    }

    private static func normalized(_ text: String?) -> String {
        text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func bounds(of text: String, on page: PDFPage) throws -> CGRect {
        let source = try require(page.string) as NSString
        let range = source.range(of: text)
        guard range.location != NSNotFound else { throw FixtureError.missingText }
        let selection = try require(page.selection(for: range))
        let bounds = selection.bounds(for: page)
        guard !bounds.isEmpty else { throw FixtureError.missingText }
        return bounds
    }

    private static func highlight(bounds: CGRect, lineBounds: [CGRect] = []) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        if !lineBounds.isEmpty {
            annotation.quadrilateralPoints = lineBounds.flatMap { line in
                [CGPoint(x: line.minX - bounds.minX, y: line.maxY - bounds.minY),
                 CGPoint(x: line.maxX - bounds.minX, y: line.maxY - bounds.minY),
                 CGPoint(x: line.minX - bounds.minX, y: line.minY - bounds.minY),
                 CGPoint(x: line.maxX - bounds.minX, y: line.minY - bounds.minY)]
                    .map(PDFPlatformStyle.pointValue)
            }
        }
        return annotation
    }

    private static func textPDF(lines: [String]) throws -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw FixtureError.cannotCreatePDF
        }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for (index, text) in lines.enumerated() {
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 72, y: 700 - index * 40)
            let attributedText = NSAttributedString(string: text,
                attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
            CTLineDraw(CTLineCreateWithAttributedString(attributedText), context)
        }
        context.endPDFPage()
        context.closePDF()
        return try require(PDFDocument(data: data as Data))
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw FixtureError.missingText }
        return value
    }

    private enum FixtureError: LocalizedError {
        case cannotCreatePDF, missingText

        var errorDescription: String? {
            "Could not create or read the isolated native highlight quote fixture."
        }
    }
}
