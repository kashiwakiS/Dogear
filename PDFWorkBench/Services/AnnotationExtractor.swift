import Foundation
import PDFKit

enum AnnotationExtractor {
    static func annotationItems(in document: PDFDocument) -> [PDFAnnotationItem] {
        var items: [PDFAnnotationItem] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                continue
            }

            for (annotationIndex, annotation) in page.annotations.enumerated() {
                guard let kind = kind(for: annotation) else {
                    continue
                }

                let contents = annotationContents(annotation, on: page, kind: kind)
                let text = kind == .highlight ? contents : ""
                let note = kind == .note ? contents : ""

                items.append(
                    PDFAnnotationItem(
                        id: PDFAnnotationItem.id(
                            pageIndex: pageIndex,
                            annotationIndex: annotationIndex,
                            annotation: annotation
                        ),
                        pageIndex: pageIndex,
                        annotationIndex: annotationIndex,
                        kind: kind,
                        text: text,
                        note: note
                    )
                )
            }
        }

        return items
    }

    static func annotation(matching item: PDFAnnotationItem, in document: PDFDocument) -> PDFAnnotation? {
        guard let page = document.page(at: item.pageIndex) else {
            return nil
        }

        return page.annotations.enumerated().first { annotationIndex, annotation in
            PDFAnnotationItem.id(
                pageIndex: item.pageIndex,
                annotationIndex: annotationIndex,
                annotation: annotation
            ) == item.id
        }?.element
    }

    private static func kind(for annotation: PDFAnnotation) -> PDFAnnotationItem.Kind? {
        switch annotation.type {
        case "Highlight":
            return .highlight
        case "Text", "FreeText":
            return .note
        default:
            return nil
        }
    }

    private static func annotationContents(
        _ annotation: PDFAnnotation,
        on page: PDFPage,
        kind: PDFAnnotationItem.Kind
    ) -> String {
        let storedContents = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !storedContents.isEmpty {
            return storedContents
        }

        guard kind == .highlight else {
            return ""
        }

        let quadrilateralText = annotationQuadrilateralText(annotation, on: page)
        if !quadrilateralText.isEmpty {
            return quadrilateralText
        }

        return page.selection(for: annotation.bounds)?
            .string?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func annotationQuadrilateralText(
        _ annotation: PDFAnnotation,
        on page: PDFPage
    ) -> String {
        guard let points = annotation.quadrilateralPoints,
              points.count >= 4
        else {
            return ""
        }

        let lines: [String] = stride(from: 0, through: points.count - 4, by: 4).compactMap { index in
            let quadPoints = points[index..<(index + 4)].map(\.pointValue)
            let xCoordinates = quadPoints.map(\.x)
            let yCoordinates = quadPoints.map(\.y)
            guard let minX = xCoordinates.min(),
                  let maxX = xCoordinates.max(),
                  let minY = yCoordinates.min(),
                  let maxY = yCoordinates.max()
            else {
                return nil
            }

            let quadBounds = NSRect(
                x: annotation.bounds.minX + minX,
                y: annotation.bounds.minY + minY,
                width: maxX - minX,
                height: maxY - minY
            )
            return page.selection(for: quadBounds)?
                .string?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

extension PDFDocument {
    typealias FreeTextDisplayState = (annotation: PDFAnnotation, shouldDisplay: Bool)

    @discardableResult
    func setFreeTextAnnotationsShouldDisplay(_ shouldDisplay: Bool) -> [FreeTextDisplayState] {
        var states: [FreeTextDisplayState] = []

        for pageIndex in 0..<pageCount {
            guard let page = page(at: pageIndex) else {
                continue
            }

            for annotation in page.annotations where annotation.type == "FreeText" {
                states.append((annotation, annotation.shouldDisplay))
                annotation.shouldDisplay = shouldDisplay
            }
        }

        return states
    }

    func restoreFreeTextAnnotationDisplayStates(_ states: [FreeTextDisplayState]) {
        for state in states {
            state.annotation.shouldDisplay = state.shouldDisplay
        }
    }

    @MainActor
    func dataRepresentationWithFreeTextAnnotationsDisplayed() -> Data? {
        let states = setFreeTextAnnotationsShouldDisplay(true)
        defer {
            restoreFreeTextAnnotationDisplayStates(states)
        }

        return QuietLinkDisplayRegistry.shared
            .dataRepresentationPreservingOriginalLinkAppearance(for: self)
    }
}
