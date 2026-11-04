import CoreGraphics
import CoreText
import Foundation
import PDFKit

#if canImport(AppKit)
import AppKit
#endif

/// Actual PDFKit selection, geometry and serialization fixtures. No reader,
/// application store, preferences, user files or provider is involved.
@MainActor
enum PDFTextSelectionServiceDiagnostics {
    static func run() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        @MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }

        do {
            let document = try makeDocument()
            guard let firstPage = document.page(at: 0), let secondPage = document.page(at: 1) else { throw FixtureError.pdf }
            let firstSelection = try allText(on: firstPage)
            let secondSelection = try allText(on: secondPage)
            let combined = PDFSelection(document: document)
            combined.add(secondSelection)
            combined.add(firstSelection)
            let beforeVersion = PDFDocumentContentVersion.value(of: document)
            let originalSelectionText = combined.string
            let originalSelectionBounds = combined.pages.map { combined.bounds(for: $0) }

            guard let snapshot = PDFTextSelectionService.snapshot(of: combined, in: document) else { throw FixtureError.selection }
            check(snapshot.text == combined.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  "The shared snapshot changed selected native text.")
            check(snapshot.pageNumbers == [1, 2], "Selected pages lost their sorted unique physical page numbers.")
            check(snapshot.passages.count == 2 && snapshot.passages.map(\.pageNumber) == [1, 2],
                  "Cross-page passages did not retain native PDF page order.")
            check(snapshot.passages.map(\.bounds) == originalSelectionBounds,
                  "Passage rectangles changed from native page-space selection bounds.")
            check(snapshot.passages.allSatisfy { !$0.text.isEmpty }, "A selected page lost its passage text.")
            check(!snapshot.isEmpty && PDFTextSelectionSnapshot(text: " \n", pageNumbers: []).isEmpty,
                  "Selection value emptiness changed its whitespace contract.")
            for passage in snapshot.passages {
                let page = passage.pageNumber == 1 ? firstPage : secondPage
                let expected = combined.selectionsByLine().filter { $0.pages.contains { $0 === page } }
                    .compactMap(\.string).joined(separator: "\n")
                check(passage.text == expected, "A passage mixed another page's text or changed native line order.")
            }

            let single = PDFTextSelectionService.prepareHighlights(from: firstSelection, in: document)
            check(single.count == 1 && single.first?.page === firstPage,
                  "A multiline selection did not prepare exactly one highlight on its page.")
            check((single.first?.annotation.quadrilateralPoints?.count ?? 0) >= 8,
                  "The multiline highlight lost a line quadrilateral.")
            let prepared = PDFTextSelectionService.prepareHighlights(from: combined, in: document)
            check(prepared.count == 2, "A cross-page selection did not prepare one highlight per page.")
            check(prepared.map { document.index(for: $0.page) } == [0, 1],
                  "Prepared highlights changed first-encounter page order.")
            check(prepared.allSatisfy { $0.annotation.page == nil }, "Preparation attached an annotation to a page.")
            check(firstPage.annotations.isEmpty && secondPage.annotations.isEmpty,
                  "Highlight preparation mutated the source PDF annotations.")
            check(PDFDocumentContentVersion.value(of: document) == beforeVersion,
                  "Selection snapshot or highlight preparation changed the PDF content version.")
            check(combined.string == originalSelectionText
                  && combined.pages.map { combined.bounds(for: $0) } == originalSelectionBounds,
                  "Preparation changed the caller's selection text or geometry.")

            for record in prepared {
                let lineSelections = combined.selectionsByLine().filter { $0.pages.contains { $0 === record.page } }
                let lineBounds = lineSelections.map { $0.bounds(for: record.page).insetBy(dx: -1, dy: -1) }
                let bounds = lineBounds.reduce(CGRect.null) { $0.union($1) }
                let expectedPoints = lineBounds.flatMap { line in
                    [CGPoint(x: line.minX - bounds.minX, y: line.maxY - bounds.minY),
                     CGPoint(x: line.maxX - bounds.minX, y: line.maxY - bounds.minY),
                     CGPoint(x: line.minX - bounds.minX, y: line.minY - bounds.minY),
                     CGPoint(x: line.maxX - bounds.minX, y: line.minY - bounds.minY)]
                }
                let exactQuote = lineSelections.compactMap { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                check(record.annotation.type == "Highlight", "The prepared annotation is not a standard PDF Highlight.")
                check(record.annotation.bounds == bounds, "Highlight bounds lost the original one-point per-line inset.")
                check(record.annotation.quadrilateralPoints?.map { PDFPlatformStyle.point(from: $0) } == expectedPoints,
                      "Highlight quadrilaterals lost line order or annotation-relative coordinates.")
                check(PDFHighlightText.text(of: record.annotation, on: record.page) == exactQuote,
                      "The exact highlighted quote changed during preparation.")
                check(record.annotation.contents?.isEmpty != false,
                      "A prepared manual highlight wrote note Contents.")
                check(PDFPlatformStyle.alphaComponent(of: record.annotation.color) == 1,
                      "The established manual highlight opacity changed.")
                check(record.annotation.color.isEqual(PDFPlatformStyle.color(.init(red: 1, green: 0.92, blue: 0.24, alpha: 1))),
                      "The established native manual highlight palette changed.")
                check(record.annotation.shouldDisplay && record.annotation.shouldPrint,
                      "Prepared highlights lost standard display or print visibility.")
            }

            #if canImport(AppKit)
            check(snapshot == legacySnapshot(combined, in: document), "The shared snapshot changed the legacy Mac selection result.")
            check(equivalent(single, legacyHighlights(firstSelection)),
                  "Shared multiline highlight preparation changed the legacy Mac annotation result.")
            check(equivalent(prepared, legacyHighlights(combined)),
                  "Shared cross-page highlight preparation changed the legacy Mac annotation result.")
            #endif

            firstPage.setBounds(CGRect(x: 25, y: 30, width: 500, height: 700), for: .cropBox)
            firstPage.rotation = 90
            let transformed = PDFTextSelectionService.prepareHighlights(from: firstSelection, in: document)
            check(transformed.count == 1 && transformed.first?.annotation.page == nil,
                  "A rotated page with a nonzero crop origin lost its detached highlight.")
            check(PDFTextSelectionService.snapshot(of: firstSelection, in: document)?.passages.first?.bounds == firstSelection.bounds(for: firstPage),
                  "Rotation or crop origin changed native passage-space rectangles.")
            #if canImport(AppKit)
            check(equivalent(transformed, legacyHighlights(firstSelection)),
                  "Rotated/cropped highlight preparation changed the legacy Mac geometry.")
            #endif

            let empty = PDFSelection(document: document)
            check(PDFTextSelectionService.snapshot(of: empty, in: document) == nil,
                  "An empty native selection produced a reading context.")
            check(PDFTextSelectionService.prepareHighlights(from: empty, in: document).isEmpty,
                  "An empty native selection prepared annotations.")
            let otherDocument = try makeDocument()
            check(PDFTextSelectionService.snapshot(of: combined, in: otherDocument) == nil,
                  "A foreign-document selection produced a reading context.")
            check(PDFTextSelectionService.prepareHighlights(from: combined, in: otherDocument).isEmpty,
                  "A foreign-document selection prepared annotations.")
            guard let foreignPage = otherDocument.page(at: 0) else { throw FixtureError.pdf }
            let foreignSelection = try allText(on: foreignPage)
            check(PDFTextSelectionService.snapshot(of: foreignSelection, in: document) == nil,
                  "A selection from another PDF reached the current document.")
            check(PDFTextSelectionService.prepareHighlights(from: foreignSelection, in: document).isEmpty,
                  "A selection from another PDF prepared a current-document annotation.")

            // Explicit fixture-only commit permits independent standard PDF
            // readback; production preparation itself never writes pages.
            for record in prepared { record.page.addAnnotation(record.annotation) }
            guard let data = document.dataRepresentation(), let reloaded = PDFDocument(data: data) else { throw FixtureError.pdf }
            check(reloaded.pageCount == 2, "Highlight serialization changed the fixture's page count.")
            for (index, record) in prepared.enumerated() {
                guard let page = reloaded.page(at: index), let annotation = page.annotations.first else { throw FixtureError.pdf }
                check(annotation.type == "Highlight", "Serialized highlights did not use the standard native annotation type.")
                check(annotation.quadrilateralPoints?.count == record.annotation.quadrilateralPoints?.count,
                      "PDF serialization lost line quadrilaterals.")
                check(PDFHighlightText.text(of: annotation, on: page) == PDFHighlightText.text(of: record.annotation, on: record.page),
                      "The exact multiline quote did not survive independent PDF readback.")
                check(annotation.contents?.isEmpty != false,
                      "PDF readback turned the manual quote into note Contents.")
            }

            document.removePage(at: 1)
            check(PDFTextSelectionService.snapshot(of: secondSelection, in: document) == nil,
                  "A selection retained from a removed page produced a reading context.")
            check(PDFTextSelectionService.prepareHighlights(from: secondSelection, in: document).isEmpty,
                  "A selection retained from a removed page prepared annotations.")
            check(PDFTextSelectionService.snapshot(of: combined, in: document) == nil,
                  "A mixed selection silently dropped its stale page.")
            check(PDFTextSelectionService.prepareHighlights(from: combined, in: document).isEmpty,
                  "A mixed stale selection prepared a partial batch.")
        } catch { check(false, "Selection fixture failed: \(error)") }
        return (checks, failures)
    }

    private enum FixtureError: Error { case pdf, selection }

    private static func allText(on page: PDFPage) throws -> PDFSelection {
        guard let text = page.string, !text.isEmpty,
              let selection = page.selection(for: NSRange(location: 0, length: (text as NSString).length)) else {
            throw FixtureError.selection
        }
        return selection
    }

    private static func makeDocument() throws -> PDFDocument {
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw FixtureError.pdf }
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for lines in [["Alpha selected first line.", "Beta selected second line."],
                      ["Gamma next-page line.", "Delta next-page second line."]] {
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            for (index, line) in lines.enumerated() {
                context.textPosition = CGPoint(x: 50, y: 700 - index * 25)
                let text = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data), document.pageCount == 2 else { throw FixtureError.pdf }
        return document
    }

    #if canImport(AppKit)
    /// Frozen observer result before extraction, independently assembled.
    private static func legacySnapshot(_ selection: PDFSelection, in document: PDFDocument) -> PDFTextSelectionSnapshot? {
        guard let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let pages = selection.pages.map { document.index(for: $0) }.filter { $0 != NSNotFound }.map { $0 + 1 }
        return PDFTextSelectionSnapshot(text: text, pageNumbers: Array(Set(pages)).sorted(),
            passages: selection.pages.compactMap { page in
                let index = document.index(for: page)
                guard index != NSNotFound else { return nil }
                let lines = selection.selectionsByLine().filter { $0.pages.contains { $0 === page } }
                let selectedText = lines.compactMap(\.string).joined(separator: "\n")
                return PDFSelectedPassage(pageNumber: index + 1, text: selectedText.isEmpty ? text : selectedText,
                    bounds: selection.bounds(for: page))
            })
    }

    /// Frozen geometry/palette/quote algorithm from the native Mac reader.
    /// This prepares annotations only so equivalence never mutates a fixture.
    private static func legacyHighlights(_ selection: PDFSelection) -> [PreparedPDFSelectionHighlight] {
        var geometries: [(page: PDFPage, bounds: [CGRect], text: [String])] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard !bounds.isEmpty else { continue }
                let inset = bounds.insetBy(dx: -1, dy: -1)
                let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let index = geometries.firstIndex(where: { $0.page === page }) {
                    geometries[index].bounds.append(inset)
                    if !text.isEmpty { geometries[index].text.append(text) }
                } else {
                    geometries.append((page, [inset], text.isEmpty ? [] : [text]))
                }
            }
        }
        return geometries.compactMap { geometry in
            guard let bounds = geometry.bounds.reduce(nil, { partial, line in partial?.union(line) ?? line }) else { return nil }
            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = NSColor(calibratedRed: 1, green: 0.92, blue: 0.24, alpha: 1)
            annotation.quadrilateralPoints = geometry.bounds.flatMap { line in
                [NSValue(point: CGPoint(x: line.minX - bounds.minX, y: line.maxY - bounds.minY)),
                 NSValue(point: CGPoint(x: line.maxX - bounds.minX, y: line.maxY - bounds.minY)),
                 NSValue(point: CGPoint(x: line.minX - bounds.minX, y: line.minY - bounds.minY)),
                 NSValue(point: CGPoint(x: line.maxX - bounds.minX, y: line.minY - bounds.minY))]
            }
            let quote = geometry.text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !quote.isEmpty { _ = annotation.setValue(quote, forAnnotationKey: PDFAnnotationKey(rawValue: "/DogearText")) }
            return PreparedPDFSelectionHighlight(page: geometry.page, annotation: annotation)
        }
    }

    private static func equivalent(_ actual: [PreparedPDFSelectionHighlight], _ expected: [PreparedPDFSelectionHighlight]) -> Bool {
        guard actual.count == expected.count else { return false }
        return zip(actual, expected).allSatisfy { actual, expected in
            actual.page === expected.page && actual.annotation.type == expected.annotation.type
                && actual.annotation.bounds == expected.annotation.bounds
                && actual.annotation.quadrilateralPoints == expected.annotation.quadrilateralPoints
                && actual.annotation.color.isEqual(expected.annotation.color)
                && actual.annotation.contents == expected.annotation.contents
                && (actual.annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DogearText")) as? String)
                    == (expected.annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DogearText")) as? String)
        }
    }
    #endif
}
