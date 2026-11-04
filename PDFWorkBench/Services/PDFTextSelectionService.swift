import CoreGraphics
import Foundation
import PDFKit

/// Prepared standard annotations have not been added to any page. The native
/// reader retains commit, Undo, display and interaction responsibilities.
@MainActor
struct PreparedPDFSelectionHighlight {
    let page: PDFPage
    let annotation: PDFAnnotation
}

/// Native PDFKit selection values and highlight geometry, independent of the
/// platform reader, keyboard, pointer, window or drawing implementation.
@MainActor
enum PDFTextSelectionService {
    private static let highlightColor = PDFColorComponents(red: 1, green: 0.92, blue: 0.24, alpha: 1)

    static func snapshot(of selection: PDFSelection, in document: PDFDocument) -> PDFTextSelectionSnapshot? {
        guard validTarget(selection, in: document),
              let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }

        let lines = selection.selectionsByLine()
        guard lines.allSatisfy({ line in line.pages.allSatisfy { belongs($0, to: document) } }) else { return nil }
        let pages = selection.pages.map { document.index(for: $0) + 1 }
        return PDFTextSelectionSnapshot(
            text: text,
            pageNumbers: Array(Set(pages)).sorted(),
            passages: selection.pages.map { page in
                let selectedText = lines.filter { $0.pages.contains { $0 === page } }
                    .compactMap(\.string).joined(separator: "\n")
                return PDFSelectedPassage(pageNumber: document.index(for: page) + 1,
                    text: selectedText.isEmpty ? text : selectedText, bounds: selection.bounds(for: page))
            }
        )
    }

    static func prepareHighlights(from selection: PDFSelection, in document: PDFDocument) -> [PreparedPDFSelectionHighlight] {
        guard validTarget(selection, in: document),
              selection.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return [] }

        var geometries: [PageGeometry] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                guard belongs(page, to: document) else { return [] }
                let bounds = line.bounds(for: page)
                guard !bounds.isEmpty, !bounds.isNull, !bounds.isInfinite else { continue }
                let lineBounds = bounds.insetBy(dx: -1, dy: -1)
                let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let index = geometries.firstIndex(where: { $0.page === page }) {
                    geometries[index].lineBounds.append(lineBounds)
                    if !text.isEmpty { geometries[index].textFragments.append(text) }
                } else {
                    geometries.append(PageGeometry(page: page, lineBounds: [lineBounds],
                        textFragments: text.isEmpty ? [] : [text]))
                }
            }
        }

        return geometries.compactMap { geometry in
            guard let bounds = geometry.lineBounds.reduce(nil, { partial, line in partial?.union(line) ?? line }) else {
                return nil
            }
            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = PDFPlatformStyle.color(highlightColor)
            annotation.quadrilateralPoints = geometry.lineBounds.flatMap { line in
                [CGPoint(x: line.minX - bounds.minX, y: line.maxY - bounds.minY),
                 CGPoint(x: line.maxX - bounds.minX, y: line.maxY - bounds.minY),
                 CGPoint(x: line.minX - bounds.minX, y: line.minY - bounds.minY),
                 CGPoint(x: line.maxX - bounds.minX, y: line.minY - bounds.minY)]
                    .map(PDFPlatformStyle.pointValue)
            }
            _ = PDFHighlightText.storeExactText(geometry.textFragments.joined(separator: "\n"), in: annotation)
            // Keep Contents absent: manual highlights do not open note popovers.
            return PreparedPDFSelectionHighlight(page: geometry.page, annotation: annotation)
        }
    }

    private static func validTarget(_ selection: PDFSelection, in document: PDFDocument) -> Bool {
        !selection.pages.isEmpty && selection.pages.allSatisfy { belongs($0, to: document) }
    }

    private static func belongs(_ page: PDFPage, to document: PDFDocument) -> Bool {
        page.document === document && document.index(for: page) != NSNotFound
    }

    private struct PageGeometry {
        let page: PDFPage
        var lineBounds: [CGRect]
        var textFragments: [String]
    }
}
